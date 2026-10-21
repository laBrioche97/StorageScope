using Microsoft.Win32;
using System.Diagnostics;
using System.ComponentModel;
using System.IO;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;

namespace StorageScope.Windows;

public sealed record NvidiaCudaTarget(string RunnerPath, string DllPath, string PackageId, string Registration,
    FileSnapshot RunnerIdentity, FileSnapshot DllIdentity);

/// <summary>A narrowly scoped adapter, never a general-purpose rundll32 command runner.</summary>
public sealed class NvidiaCudaProvider : IInstalledProductProvider
{
    public string Name => "Composants NVIDIA CUDA";
    private static readonly Regex Package = new(@"^(CUDADevelopment|CUDADocument|CUDARuntimes|visual_studio_integration)_12\.\d+$", RegexOptions.CultureInvariant);
    private readonly RegisteredProductProvider _registered = new();
    internal string WindowsRoot { get; init; } = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
    internal string ProgramFilesRoot { get; init; } = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
    internal Action<InstalledApplication> CheckRegistration { get; init; } = ValidateRegistration;
    internal Func<InstalledApplication, CancellationToken, Task<bool>>? TestAbsent { get; init; }
    internal Func<string, string, bool> VerifyPublisher { get; init; } = TrustedPublisher;
    internal Func<ProcessStartInfo, Process?> Start { get; init; } = Process.Start;
    internal Func<CancellationToken, Task> Wait { get; init; } = token => Task.Delay(1000, token);
    internal int Checks { get; init; } = 120;
    public static bool IsCandidate(InstalledApplication product) => product.Publisher == "NVIDIA Corporation"
        && product.RegistrationPath is not null && Regex.IsMatch(product.ProductId ?? "", @"_((CUDADevelopment|CUDADocument|CUDARuntimes|visual_studio_integration)_12\.\d+)$", RegexOptions.CultureInvariant);
    public async Task<IReadOnlyList<InstalledApplication>> DetectAsync(CancellationToken token) => (await _registered.DetectAsync(token)).Where(IsCandidate).ToArray();

    internal static (string Runner, string Dll, string PackageId) Parse(string command, string productId, string? windowsRoot = null, string? programFilesRoot = null)
    {
        var match = Regex.Match(command, "^\"(?<runner>[^\"]+)\"\\s+\"(?<dll>[^\"]+)\",UninstallPackage\\s+(?<package>[A-Za-z0-9_.]+)$", RegexOptions.CultureInvariant);
        if (!match.Success || !Package.IsMatch(match.Groups["package"].Value)) throw new IOException("Commande CUDA non reconnue : seuls les composants CUDA 12 enregistrés sont autorisés.");
        var id = match.Groups["package"].Value;
        if (!Regex.IsMatch(productId, @"^\{[0-9A-Fa-f-]{36}\}_" + Regex.Escape(id) + "$", RegexOptions.CultureInvariant) || !Guid.TryParseExact(productId[..38], "B", out _)) throw new IOException("L’identifiant de la commande ne correspond pas au composant sélectionné.");
        var runner = match.Groups["runner"].Value; var dll = match.Groups["dll"].Value;
        var windows = windowsRoot ?? Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (!new[] { Path.Combine(windows, "System32", "rundll32.exe"), Path.Combine(windows, "SysWOW64", "rundll32.exe") }.Contains(runner, StringComparer.OrdinalIgnoreCase)) throw new IOException("L’hôte de désinstallation doit être celui de Windows.");
        var expected = Path.Combine(programFilesRoot ?? Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "NVIDIA Corporation", "Installer2", "InstallerCore", "NVI2.DLL");
        if (!dll.Equals(expected, StringComparison.OrdinalIgnoreCase)) throw new IOException("La bibliothèque doit provenir de l’installateur NVIDIA officiel.");
        return (runner, dll, id);
    }
    public ProductUninstallPlan Prepare(InstalledApplication product)
    {
        try
        {
            if (!IsCandidate(product) || product.UninstallCommand is null) throw new IOException("Composant CUDA non identifié.");
            CheckRegistration(product);
            var (runner, dll, id) = Parse(product.UninstallCommand, product.ProductId!, WindowsRoot, ProgramFilesRoot);
            var separator = id.LastIndexOf('_');
            var component = id[..separator] switch { "CUDADevelopment" => "Development", "CUDADocument" => "Documentation", "CUDARuntimes" => "Runtime", _ => "Visual Studio Integration" };
            if (product.Name != $"NVIDIA CUDA {component} {id[(separator + 1)..]}") throw new IOException("Le nom enregistré ne correspond pas au composant CUDA ciblé.");
            if (!ApplicationEnrichment.SafeLocal(runner) || !ApplicationEnrichment.SafeLocal(dll)) throw new IOException("Un chemin du désinstalleur est inaccessible, distant ou lié.");
            var runnerIdentity = DeletionSafetyPolicy.ReadIdentity(runner, allowHardLinks: true);
            var dllIdentity = DeletionSafetyPolicy.ReadIdentity(dll, allowHardLinks: true);
            if (Machine(runner) != Machine(dll)) throw new IOException("Les architectures de l’hôte Windows et de la bibliothèque NVIDIA ne correspondent pas.");
            if (!VerifyPublisher(runner, "Microsoft Corporation") || !VerifyPublisher(dll, "NVIDIA Corporation")) throw new CryptographicException("La signature Microsoft ou NVIDIA ne peut pas être vérifiée.");
            return new(product, $"Le désinstalleur NVIDIA retirera uniquement le composant {id}. Une fenêtre officielle et une autorisation Windows peuvent apparaître. Le dossier CUDA peut être partagé : sa taille ne représente pas l’espace qui sera libéré. Le pilote graphique et les autres composants ne sont pas sélectionnés par StorageScope.", true, true, runner, $"\"{dll}\",UninstallPackage {id}", UninstallerIdentity: runnerIdentity)
            { NvidiaTarget = new(runner, dll, id, product.RegistrationPath!, runnerIdentity, dllIdentity) };
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException or System.Security.SecurityException or ArgumentException)
        { return new(product, "Méthode CUDA non vérifiable : " + error.Message + " Vous pouvez consulter les applications installées de Windows.", false, false, BlockReason: error.Message); }
    }
    private static void ValidateRegistration(InstalledApplication product)
    {
        var parts = product.RegistrationPath?.Split('|');
        if (parts?.Length != 3 || !Enum.TryParse<RegistryHive>(parts[0], out var hive) || hive is not (RegistryHive.LocalMachine or RegistryHive.CurrentUser)
            || !Enum.TryParse<RegistryView>(parts[1], out var view) || view is not (RegistryView.Registry32 or RegistryView.Registry64) || parts[2] != product.ProductId || parts[2].Contains('\\')) throw new IOException("Enregistrement Windows invalide.");
        using var registry = RegistryKey.OpenBaseKey(hive, view);
        using var key = registry.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" + parts[2]);
        if ((key?.GetValue("UninstallString") as string)?.Trim() != product.UninstallCommand || key?.GetValue("Publisher") as string != "NVIDIA Corporation" || key?.GetValue("DisplayName") as string != product.Name) throw new IOException("L’enregistrement CUDA a changé. Actualisez l’inventaire.");
    }
    internal static ushort Machine(string path)
    {
        using var input = File.OpenRead(path); using var reader = new BinaryReader(input);
        if (input.Length < 64 || reader.ReadUInt16() != 0x5A4D) throw new IOException("Fichier PE invalide.");
        input.Position = 60; var header = reader.ReadInt32();
        if (header < 64 || header > input.Length - 24) throw new IOException("En-tête PE invalide.");
        input.Position = header; if (reader.ReadUInt32() != 0x4550) throw new IOException("Signature PE invalide.");
        var machine = reader.ReadUInt16(); if (machine is not (0x14c or 0x8664 or 0xaa64)) throw new IOException("Architecture non prise en charge."); return machine;
    }
    private static bool TrustedPublisher(string path, string organization)
    {
#pragma warning disable SYSLIB0057
        using var certificate = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
        Authenticode.Verify(path, certificate.Subject);
        return certificate.SubjectName.Decode(X500DistinguishedNameFlags.UseNewLines).Split('\n').Any(line => line.Trim() == "O=" + organization);
    }
    public async Task<ProductUninstallResult> ExecuteAsync(ProductUninstallPlan plan, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var fresh = await Task.Run(() => Prepare(plan.Product), token);
        if (!fresh.CanProceed || fresh.NvidiaTarget is null || fresh.NvidiaTarget != plan.NvidiaTarget) throw new IOException(fresh.BlockReason ?? "La méthode CUDA a changé.");
        var target = fresh.NvidiaTarget;
        OperationHistory.Append(new { operation = "désinstallation CUDA", product = plan.Product.Name, component = target.PackageId, status = "préparation" });
        try
        {
            Process? process;
            using (var runner = new FileStream(target.RunnerPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var dll = new FileStream(target.DllPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                CheckRegistration(plan.Product);
                if (DeletionSafetyPolicy.ReadIdentity(target.RunnerPath, true) != target.RunnerIdentity || DeletionSafetyPolicy.ReadIdentity(target.DllPath, true) != target.DllIdentity) throw new IOException("Le désinstalleur CUDA a été remplacé.");
                token.ThrowIfCancellationRequested();
                process = Start(new ProcessStartInfo(target.RunnerPath, fresh.Arguments!) { UseShellExecute = true, Verb = target.Registration.StartsWith("LocalMachine|", StringComparison.Ordinal) ? "runas" : "open" });
            }
            using var lifetime = process;
            plan.Progress?.Report("Désinstallation NVIDIA en cours… Annuler arrête uniquement le suivi.");
            for (var i = 0; i < Checks; i++)
            {
                token.ThrowIfCancellationRequested();
                if (await VerifyAsync(plan.Product, token)) return Finish(true, "Désinstallation du composant CUDA confirmée. Les autres composants et données n’ont pas été nettoyés par StorageScope.");
                await Wait(token);
            }
            return Finish(false, "Désinstallation non confirmée. Terminez la fenêtre NVIDIA, puis actualisez l’inventaire.");
        }
        catch (OperationCanceledException) { return Finish(false, "Suivi arrêté. Une désinstallation acceptée dans NVIDIA peut continuer."); }
        catch (Win32Exception error) when (error.NativeErrorCode == 1223) { return Finish(false, "Autorisation Windows refusée. Aucun désinstalleur n’a été lancé."); }
        catch (Exception error) { OperationHistory.Append(new { operation = "désinstallation CUDA", component = target.PackageId, status = "échec", error = error.GetType().Name }); throw; }
        ProductUninstallResult Finish(bool verified, string message) { OperationHistory.Append(new { operation = "désinstallation CUDA", component = target.PackageId, verified }); return new(verified, message); }
    }
    public Task<bool> VerifyAsync(InstalledApplication product, CancellationToken token) => TestAbsent?.Invoke(product, token) ?? Task.Run(() =>
    {
        var suffix = "_" + Parse(product.UninstallCommand!, product.ProductId!, WindowsRoot, ProgramFilesRoot).PackageId;
        try
        {
            foreach (var hive in new[] { RegistryHive.LocalMachine, RegistryHive.CurrentUser })
            foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
            {
                token.ThrowIfCancellationRequested();
                using var registry = RegistryKey.OpenBaseKey(hive, view);
                using var key = registry.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall");
                if (key?.GetSubKeyNames().Any(name => name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) == true) return false;
            }
            return true;
        }
        catch (Exception error) when (error is UnauthorizedAccessException or System.Security.SecurityException or IOException) { return false; }
    }, token);
}
