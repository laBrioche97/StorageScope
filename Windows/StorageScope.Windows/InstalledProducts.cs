using Microsoft.Win32;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using Windows.Management.Deployment;

namespace StorageScope.Windows;

public sealed record ProductUninstallPlan(InstalledApplication Product, string Explanation, bool CanProceed, bool ExternalStep,
    string? Executable = null, string? Arguments = null, string? BlockReason = null, FileSnapshot? UninstallerIdentity = null)
{
    public IProgress<string>? Progress { get; init; }
    public bool EpicGuided { get; init; }
    public NvidiaCudaTarget? NvidiaTarget { get; init; }
}
public sealed record ProductUninstallResult(bool Verified, string Message, string State = "non confirmé");

public interface IInstalledProductProvider
{
    string Name { get; }
    Task<IReadOnlyList<InstalledApplication>> DetectAsync(CancellationToken token);
    ProductUninstallPlan Prepare(InstalledApplication product);
    Task<ProductUninstallResult> ExecuteAsync(ProductUninstallPlan plan, CancellationToken token);
    Task<bool> VerifyAsync(InstalledApplication product, CancellationToken token);
}

public sealed class RegisteredProductProvider : IInstalledProductProvider
{
    public string Name => "Applications et jeux enregistrés";
    public Task<IReadOnlyList<InstalledApplication>> DetectAsync(CancellationToken token) => Task.Run<IReadOnlyList<InstalledApplication>>(() =>
    {
        var result = new List<InstalledApplication>();
        foreach (var hive in new[] { RegistryHive.LocalMachine, RegistryHive.CurrentUser })
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            using var registry = RegistryKey.OpenBaseKey(hive, view);
            using var parent = registry.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall");
            if (parent is null) continue;
            foreach (var keyName in parent.GetSubKeyNames())
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    using var key = parent.OpenSubKey(keyName);
                    if (key?.GetValue("DisplayName") is not string name || string.IsNullOrWhiteSpace(name) || Convert.ToInt32(key.GetValue("SystemComponent") ?? 0) == 1) continue;
                    var command = (key.GetValue("UninstallString") as string)?.Trim();
                    var location = key.GetValue("InstallLocation") as string;
                    var provider = IdentifyProvider(keyName, command, location, key.GetValue("Publisher") as string);
                    result.Add(new(name.Trim(), key.GetValue("Publisher") as string, key.GetValue("DisplayVersion") as string,
                        location, command, provider, keyName, $"{hive}|{view}|{keyName}",
                        EstimatedBytes: DeclaredSize(key.GetValue("EstimatedSize")), IconLocation: key.GetValue("DisplayIcon") as string));
                }
                catch (Exception error) when (error is UnauthorizedAccessException or System.Security.SecurityException or FormatException) { }
            }
        }
        return result.DistinctBy(item => item.RegistrationPath).ToList();
    }, token);

    public static string IdentifyProvider(string key, string? command, string? path, string? publisher)
    {
        var value = string.Join(" ", key, command, path, publisher);
        if (Regex.IsMatch(key, @"^Steam App \d+$", RegexOptions.IgnoreCase)) return "Steam";
        if (value.Contains("Epic Games", StringComparison.OrdinalIgnoreCase)) return "Epic";
        if (value.Contains("GOG", StringComparison.OrdinalIgnoreCase)) return "GOG";
        if (value.Contains("Electronic Arts", StringComparison.OrdinalIgnoreCase) || value.Contains("EA Games", StringComparison.OrdinalIgnoreCase) || value.Contains("Origin Games", StringComparison.OrdinalIgnoreCase)) return "EA";
        if (value.Contains("Ubisoft", StringComparison.OrdinalIgnoreCase) || value.Contains("Uplay", StringComparison.OrdinalIgnoreCase)) return "Ubisoft";
        if (value.Contains("Battle.net", StringComparison.OrdinalIgnoreCase) || value.Contains("Blizzard", StringComparison.OrdinalIgnoreCase)) return "Battle.net";
        return "Application";
    }

    internal static long? DeclaredSize(object? kilobytes)
    {
        if (kilobytes is null || !long.TryParse(kilobytes.ToString(), out var value) || value <= 0 || value > long.MaxValue / 1024) return null;
        return value * 1024;
    }

    public ProductUninstallPlan Prepare(InstalledApplication product)
    {
        if (product.Name.Equals("StorageScope", StringComparison.OrdinalIgnoreCase)) return new(product, "Quittez StorageScope puis utilisez son entrée de désinstallation dans les réglages Windows.", false, false, BlockReason: "StorageScope est en cours d’exécution.");
        if (string.IsNullOrWhiteSpace(product.UninstallCommand)) return new(product,
            "Aucune méthode de désinstallation vérifiable n’est déclarée. Les fichiers restent en place.", false, false, BlockReason: "Désinstalleur non disponible.");
        if (Regex.IsMatch(product.UninstallCommand, @"^steam://uninstall/\d+/?$", RegexOptions.IgnoreCase))
            return new(product, "Steam demandera confirmation. StorageScope vérifiera ensuite que le jeu n’est plus enregistré. Les sauvegardes et composants partagés ne sont pas nettoyés.", true, true, product.UninstallCommand);
        try
        {
            var (executable, arguments) = ParseCommand(product.UninstallCommand);
            return new(product, "Le désinstalleur officiel peut ouvrir une fenêtre ou demander une autorisation. Les sauvegardes ne sont jamais supprimées par StorageScope ; vérifiez aussi les options affichées par le désinstalleur.", true, true, executable, arguments,
                UninstallerIdentity: DeletionSafetyPolicy.ReadIdentity(executable, allowHardLinks: true));
        }
        catch (IOException error) { return new(product, error.Message, false, false, BlockReason: error.Message); }
    }

    public static (string Executable, string Arguments) ParseCommand(string command)
    {
        var match = Regex.Match(command.Trim(), "^(?:\"(?<exe>[^\"]+\\.exe)\"|(?<exe>.+?\\.exe))(?:\\s+(?<args>.*))?$", RegexOptions.IgnoreCase);
        if (!match.Success) throw new IOException("Commande de désinstallation non reconnue. Aucun shell ne sera exécuté.");
        var executable = Environment.ExpandEnvironmentVariables(match.Groups["exe"].Value);
        var arguments = match.Groups["args"].Value;
        if (string.Equals(executable, "msiexec.exe", StringComparison.OrdinalIgnoreCase)) executable = Path.Combine(Environment.SystemDirectory, "msiexec.exe");
        if (executable.StartsWith(@"\\", StringComparison.Ordinal) || executable[2..].Contains(':')) throw new IOException("Les désinstalleurs réseau et les flux alternatifs sont exclus.");
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable)) throw new IOException("Le désinstalleur doit être un exécutable existant avec un chemin absolu.");
        var blocked = new[] { "cmd.exe", "powershell.exe", "pwsh.exe", "wscript.exe", "cscript.exe", "mshta.exe", "rundll32.exe", "regsvr32.exe" };
        if (blocked.Contains(Path.GetFileName(executable), StringComparer.OrdinalIgnoreCase)) throw new IOException("Cette commande nécessite un interpréteur et doit être examinée dans les réglages Windows.");
        if (Path.GetFileName(executable).Equals("msiexec.exe", StringComparison.OrdinalIgnoreCase))
        {
            var product = Regex.Match(arguments, @"^/[IX]\s*(\{[0-9A-Fa-f-]{36}\})(?:\s.*)?$", RegexOptions.IgnoreCase);
            if (!product.Success) throw new IOException("Identifiant MSI invalide.");
            arguments = "/x " + product.Groups[1].Value;
        }
        return (executable, arguments);
    }

    public async Task<ProductUninstallResult> ExecuteAsync(ProductUninstallPlan plan, CancellationToken token)
    {
        if (!plan.CanProceed) return new(false, plan.BlockReason ?? "Opération indisponible.");
        var fresh = Prepare(plan.Product);
        if (!fresh.CanProceed || fresh.Executable != plan.Executable || fresh.Arguments != plan.Arguments || fresh.UninstallerIdentity != plan.UninstallerIdentity) throw new IOException("La méthode de désinstallation a changé.");
        if (plan.Product.RegistrationPath is string registration)
        {
            var parts = registration.Split('|');
            using var registry = RegistryKey.OpenBaseKey(Enum.Parse<RegistryHive>(parts[0]), Enum.Parse<RegistryView>(parts[1]));
            using var key = registry.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" + parts[2]);
            if ((key?.GetValue("UninstallString") as string)?.Trim() != plan.Product.UninstallCommand) throw new IOException("L’enregistrement de l’application a changé. Actualisez l’inventaire.");
        }
        OperationHistory.Append(new { operation = "désinstallation", product = plan.Product.Name, provider = plan.Product.Provider, status = "démarré" });
        Process? process;
        using (var guard = plan.UninstallerIdentity is null ? null : new FileStream(plan.Executable!, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            if (plan.UninstallerIdentity is not null && DeletionSafetyPolicy.ReadIdentity(plan.Executable!, allowHardLinks: true) != plan.UninstallerIdentity) throw new IOException("Le désinstalleur a été remplacé.");
            process = Process.Start(new ProcessStartInfo(plan.Executable!, plan.Arguments ?? "") { UseShellExecute = true });
        }
        using var processLifetime = process;
        if (process is not null)
        {
            try { await process.WaitForExitAsync(token); }
            catch (OperationCanceledException) { return new(false, "Suivi interrompu. Le désinstalleur officiel peut toujours être ouvert."); }
        }
        var verified = await VerifyAsync(plan.Product, token);
        OperationHistory.Append(new { operation = "désinstallation", product = plan.Product.Name, verified });
        return new(verified, verified ? "Désinstallation confirmée. Les données personnelles n’ont pas été nettoyées par StorageScope." : "Le désinstalleur a été lancé, mais la désinstallation n’est pas encore confirmée. Terminez l’étape officielle puis actualisez l’inventaire.");
    }

    public Task<bool> VerifyAsync(InstalledApplication product, CancellationToken token) => Task.Run(() =>
    {
        token.ThrowIfCancellationRequested();
        if (product.RegistrationPath is null) return product.ManifestPath is not null && !File.Exists(product.ManifestPath);
        var pieces = product.RegistrationPath.Split('|');
        if (pieces.Length != 3) return false;
        using var registry = RegistryKey.OpenBaseKey(Enum.Parse<RegistryHive>(pieces[0]), Enum.Parse<RegistryView>(pieces[1]));
        using var key = registry.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" + pieces[2]);
        return key is null && (product.ManifestPath is null || !File.Exists(product.ManifestPath));
    }, token);
}

public sealed class LauncherManifestProvider : IInstalledProductProvider
{
    public string Name => "Bibliothèques Steam et Epic";
    private readonly RegisteredProductProvider _registered = new();
    public Task<IReadOnlyList<InstalledApplication>> DetectAsync(CancellationToken token) => Task.Run<IReadOnlyList<InstalledApplication>>(() =>
    {
        var products = new List<InstalledApplication>();
        var steam = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) as string;
        if (steam is not null)
        {
            var libraries = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { steam };
            var libraryFile = Path.Combine(steam, "steamapps", "libraryfolders.vdf");
            if (File.Exists(libraryFile))
                foreach (Match match in Regex.Matches(File.ReadAllText(libraryFile), "\"path\"\\s+\"([^\"]+)\"")) libraries.Add(match.Groups[1].Value.Replace("\\\\", "\\"));
            foreach (var library in libraries)
            {
                var apps = Path.Combine(library, "steamapps");
                if (!Directory.Exists(apps)) continue;
                foreach (var file in Directory.EnumerateFiles(apps, "appmanifest_*.acf"))
                {
                    token.ThrowIfCancellationRequested();
                    if (new FileInfo(file).Length > 2_000_000) continue;
                    var manifestSnapshot = DeletionSafetyPolicy.ReadIdentity(file);
                    var text = File.ReadAllText(file);
                    if (DeletionSafetyPolicy.ReadIdentity(file) != manifestSnapshot) continue;
                    string Value(string field) => Regex.Match(text, "\"" + field + "\"\\s+\"([^\"]+)\"").Groups[1].Value;
                    var id = Value("appid");
                    var directory = Value("installdir");
                    if (!Regex.IsMatch(id, @"^\d+$") || Path.GetFileName(file) != "appmanifest_" + id + ".acf" || string.IsNullOrWhiteSpace(directory) || directory.IndexOfAny(['\\', '/', ':']) >= 0 || directory is "." or "..") continue;
                    products.Add(new(Value("name"), "Valve / Steam", null, Path.Combine(apps, "common", directory), "steam://uninstall/" + id, "Steam", "Steam App " + id, ManifestPath: file, ManifestSnapshot: manifestSnapshot,
                        EstimatedBytes: long.TryParse(Value("SizeOnDisk"), out var size) && size >= 0 ? size : null));
                }
            }
        }
        products.AddRange(DetectRegisteredLibraries(token));
        return products;
    }, token);
    private static IEnumerable<InstalledApplication> DetectRegisteredLibraries(CancellationToken token)
    {
        var roots = new[] {
            (Path: @"SOFTWARE\GOG.com\Games", Provider: "GOG"),
            (Path: @"SOFTWARE\EA Games", Provider: "EA"),
            (Path: @"SOFTWARE\Origin Games", Provider: "EA"),
            (Path: @"SOFTWARE\Ubisoft\Launcher\Installs", Provider: "Ubisoft"),
            (Path: @"SOFTWARE\Blizzard Entertainment", Provider: "Battle.net")
        };
        var products = new List<InstalledApplication>();
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        foreach (var hive in new[] { RegistryHive.LocalMachine, RegistryHive.CurrentUser })
        foreach (var root in roots)
        {
            try
            {
                using var registry = RegistryKey.OpenBaseKey(hive, view);
                using var parent = registry.OpenSubKey(root.Path);
                if (parent is null) continue;
                foreach (var id in parent.GetSubKeyNames())
                {
                    token.ThrowIfCancellationRequested();
                    using var key = parent.OpenSubKey(id);
                    var location = new[] { "InstallLocation", "InstallDir", "InstallPath", "path" }.Select(name => key?.GetValue(name) as string).FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
                    if (location is null || !Path.IsPathFullyQualified(location) || location.StartsWith(@"\\",StringComparison.Ordinal) || !Directory.Exists(location)) continue;
                    var title = (key?.GetValue("gameName") ?? key?.GetValue("DisplayName")) as string;
                    title = string.IsNullOrWhiteSpace(title) ? Path.GetFileName(location.TrimEnd('\\')) : title;
                    products.Add(new(title,root.Provider,key?.GetValue("Version") as string,location,key?.GetValue("uninstallCommand") as string,root.Provider,id));
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
        }
        return products;
    }
    public ProductUninstallPlan Prepare(InstalledApplication product) => _registered.Prepare(product);
    public Task<ProductUninstallResult> ExecuteAsync(ProductUninstallPlan plan, CancellationToken token) => _registered.ExecuteAsync(plan, token);
    public Task<bool> VerifyAsync(InstalledApplication product, CancellationToken token)
    {
        if (product.RegistrationPath is not null) return _registered.VerifyAsync(product, token);
        return Task.FromResult(product.ManifestPath is not null && !File.Exists(product.ManifestPath));
    }
}

public sealed class WindowsPackageProvider : IInstalledProductProvider
{
    public string Name => "Xbox / Microsoft Store";
    public Task<IReadOnlyList<InstalledApplication>> DetectAsync(CancellationToken token) => Task.Run<IReadOnlyList<InstalledApplication>>(() =>
    {
        var manager = new PackageManager();
        var products = new List<InstalledApplication>();
        foreach (var package in manager.FindPackagesForUser(string.Empty))
        {
            token.ThrowIfCancellationRequested();
            if (package.IsFramework || package.IsResourcePackage || package.IsBundle || package.SignatureKind == global::Windows.ApplicationModel.PackageSignatureKind.System) continue;
            try { products.Add(new(package.DisplayName, package.PublisherDisplayName, package.Id.Version.Major + "." + package.Id.Version.Minor, package.InstalledLocation.Path, null, "Xbox / Microsoft Store", package.Id.FamilyName, PackageFullName: package.Id.FullName,
                IconLocation: package.Logo.IsFile ? package.Logo.LocalPath : Path.Combine(package.InstalledLocation.Path, Uri.UnescapeDataString(package.Logo.AbsolutePath.TrimStart('/'))))); }
            catch (Exception error) when (error is UnauthorizedAccessException or COMException) { }
        }
        return products;
    }, token);
    public ProductUninstallPlan Prepare(InstalledApplication product) => new(product,
        "Windows retirera le paquet pour votre compte. Si d’autres comptes l’utilisent, l’espace pourra rester occupé. Les données locales du paquet peuvent être retirées par Windows : sauvegardez-les avant de continuer.", product.PackageFullName is not null, false);
    public async Task<ProductUninstallResult> ExecuteAsync(ProductUninstallPlan plan, CancellationToken token)
    {
        if (!plan.CanProceed || plan.Product.PackageFullName is null) return new(false, "Paquet non identifié.");
        token.ThrowIfCancellationRequested();
        OperationHistory.Append(new { operation = "désinstallation Windows", package = plan.Product.PackageFullName });
        var operation = new PackageManager().RemovePackageAsync(plan.Product.PackageFullName, RemovalOptions.PreserveApplicationData);
        var result = await operation;
        if (result.ExtendedErrorCode is not null) return new(false, result.ErrorText);
        return new(await VerifyAsync(plan.Product, CancellationToken.None), "Paquet retiré pour ce compte ; les données d’application ont été conservées.");
    }
    public async Task<bool> VerifyAsync(InstalledApplication product, CancellationToken token) => !(await DetectAsync(token)).Any(item => item.PackageFullName == product.PackageFullName);
}

public sealed class InstalledProductCatalog
{
    private readonly IInstalledProductProvider[] _providers = [new RegisteredProductProvider(), new LauncherManifestProvider(), new WindowsPackageProvider(), new EpicProductProvider()];
    public async Task<IReadOnlyList<InstalledApplication>> DetectAsync(CancellationToken token)
    {
        var result = new List<InstalledApplication>();
        foreach (var provider in _providers)
        {
            try { result.AddRange(await provider.DetectAsync(token)); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException or COMException) { }
        }
        return Merge(result);
    }
    internal static IReadOnlyList<InstalledApplication> Merge(List<InstalledApplication> result)
    {
        static bool EpicComponent(InstalledApplication item) => Regex.IsMatch(item.Name, @"^Epic (Games Launcher|Online Services)(?:\s|$)", RegexOptions.IgnoreCase);
        static string? Canonical(string? path)
        {
            try { return path is not null && Path.IsPathFullyQualified(path) ? Path.GetFullPath(path).TrimEnd('\\') : path; }
            catch (ArgumentException) { return path; }
        }
        result = result.Select(item => item with { InstallLocation = Canonical(item.InstallLocation), ManifestPath = Canonical(item.ManifestPath) }).ToList();
        foreach (var manifest in result.Where(item => item.ManifestPath is not null).ToList())
        {
            var registrations = result.Where(item => item.RegistrationPath is not null && !(manifest.Provider == "Epic" && EpicComponent(item)) && (
                item.Provider == manifest.Provider && string.Equals(item.ProductId, manifest.ProductId, StringComparison.OrdinalIgnoreCase)
                    && (string.IsNullOrWhiteSpace(item.InstallLocation) || item.InstallLocation.TrimEnd('\\').Equals(manifest.InstallLocation?.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                || manifest.Provider == "Epic" && item.Provider is "Epic" or "Application" && !EpicComponent(item) && !string.IsNullOrWhiteSpace(item.InstallLocation)
                    && item.InstallLocation.Equals(manifest.InstallLocation, StringComparison.OrdinalIgnoreCase)
                    && result.Count(other => other.ManifestPath is not null && string.Equals(other.InstallLocation, manifest.InstallLocation, StringComparison.OrdinalIgnoreCase)) == 1
            )).ToList();
            var registration = registrations.OrderByDescending(item => !string.IsNullOrWhiteSpace(item.IconLocation)).FirstOrDefault();
            if (registration is null) continue;
            foreach (var item in registrations) result.Remove(item);
            result.Remove(manifest);
            result.Add(registration with { ManifestPath = manifest.ManifestPath, ManifestSnapshot = manifest.ManifestSnapshot, InstallLocation = manifest.InstallLocation, EstimatedBytes = manifest.EstimatedBytes ?? registration.EstimatedBytes,
                Provider = manifest.Provider, ProductId = manifest.ProductId, EpicNamespace = manifest.EpicNamespace, EpicCatalogId = manifest.EpicCatalogId, IconLocation = registration.IconLocation ?? manifest.IconLocation });
        }
        var unique = result.GroupBy(item => item.PackageFullName ?? (item.Provider == "Epic" && item.ManifestPath is not null ? $"epic:{item.EpicNamespace}:{item.EpicCatalogId}:{item.ProductId}:{item.InstallLocation}" : EpicComponent(item) ? "epic-component:" + (item.RegistrationPath ?? item.Name) : item.InstallLocation is { Length: > 0 } location && Path.IsPathFullyQualified(location) ? location.TrimEnd('\\') : item.Provider + ":" + item.ProductId + ":" + item.Name), StringComparer.OrdinalIgnoreCase)
            .Select(group => group.OrderByDescending(item => item.RegistrationPath is not null).First()).ToList();
        var shared = unique.Where(item => !string.IsNullOrWhiteSpace(item.InstallLocation)).GroupBy(item => item.InstallLocation!, StringComparer.OrdinalIgnoreCase).Where(group => group.Count() > 1).Select(group => group.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return unique.Select(item => item with { SharedInstallLocation = item.InstallLocation is not null && shared.Contains(item.InstallLocation) }).ToList();
    }
    private readonly NvidiaCudaProvider _cuda = new();
    public IInstalledProductProvider ProviderFor(InstalledApplication product) => NvidiaCudaProvider.IsCandidate(product) ? _cuda : product.PackageFullName is not null ? _providers[2] : product.Provider == "Epic" && product.ManifestPath is not null ? _providers[3] : product.RegistrationPath is not null ? _providers[0] : _providers[1];
}
