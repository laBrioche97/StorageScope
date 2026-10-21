using Microsoft.Win32;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace StorageScope.Windows;

/// Uses only an installed game's official registration, or guides the user through
/// Epic's own UI. No guessed uninstall URI, credentials, or manifest edits.
public sealed class EpicProductProvider : IInstalledProductProvider
{
    public string Name => "Jeux Epic";
    private readonly RegisteredProductProvider _registered = new();
    private readonly string _manifestRoot;
    private readonly Func<string?> _launcher;
    private readonly Action<string> _open;
    private readonly Func<CancellationToken, Task> _wait;
    private readonly int _checks;

    public EpicProductProvider() : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Epic", "EpicGamesLauncher", "Data", "Manifests"), ResolveLauncher,
        path => { using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(path) }); },
        token => Task.Delay(TimeSpan.FromSeconds(2), token), 150) { }

    internal EpicProductProvider(string manifestRoot, Func<string?> launcher, Action<string> open, Func<CancellationToken, Task> wait, int checks = 2)
    { _manifestRoot = manifestRoot; _launcher = launcher; _open = open; _wait = wait; _checks = checks; }

    public Task<IReadOnlyList<InstalledApplication>> DetectAsync(CancellationToken token) => Task.Run<IReadOnlyList<InstalledApplication>>(() =>
    {
        var result = new List<InstalledApplication>();
        if (!Directory.Exists(_manifestRoot)) return result;
        foreach (var file in Directory.EnumerateFiles(_manifestRoot, "*.item"))
        {
            token.ThrowIfCancellationRequested();
            try { var game = ReadManifest(file); if (game is not null && Directory.Exists(game.InstallLocation)) result.Add(game); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
        }
        return result;
    }, token);

    internal static InstalledApplication? ReadManifest(string file)
    {
        if (new FileInfo(file).Length > 2_000_000 || HasLinkAncestor(file)) return null;
        var identity = DeletionSafetyPolicy.ReadIdentity(file);
        using var json = JsonDocument.Parse(File.ReadAllText(file));
        if (DeletionSafetyPolicy.ReadIdentity(file) != identity) throw new IOException("Le manifeste Epic a changé pendant sa lecture.");
        var root = json.RootElement;
        string? Get(string key) => root.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        var id = Get("AppName"); var name = Get("DisplayName"); var location = Get("InstallLocation");
        if (string.IsNullOrWhiteSpace(name) || !ValidId(id) || !ValidId(Get("CatalogNamespace")) || !ValidId(Get("CatalogItemId")) || string.IsNullOrWhiteSpace(location)) return null;
        if (root.TryGetProperty("bIsApplication", out var application) && application.ValueKind == JsonValueKind.False) return null;
        if (Get("MainGameAppName") is { Length: > 0 } main && main != id) return null;
        if (!Path.IsPathFullyQualified(location) || location.StartsWith(@"\\", StringComparison.Ordinal) || location[2..].Contains(':')) return null;
        location = Path.GetFullPath(location).TrimEnd('\\');
        if (Path.GetPathRoot(location)?.TrimEnd('\\').Equals(location, StringComparison.OrdinalIgnoreCase) != false || HasLinkAncestor(location)) return null;
        string? icon = null;
        if (Get("LaunchExecutable") is { Length: > 0 } executable && !Path.IsPathRooted(executable))
        {
            var candidate = Path.GetFullPath(Path.Combine(location, executable));
            if (DeletionSafetyPolicy.IsWithin(candidate, location)) icon = candidate;
        }
        return new(name, "Epic Games", Get("AppVersionString"), location, null, "Epic", id,
            ManifestPath: Path.GetFullPath(file), ManifestSnapshot: identity,
            EstimatedBytes: root.TryGetProperty("InstallSize", out var size) && size.ValueKind == JsonValueKind.Number && size.TryGetInt64(out var bytes) && bytes >= 0 ? bytes : null,
            IconLocation: icon, EpicNamespace: Get("CatalogNamespace"), EpicCatalogId: Get("CatalogItemId"));
    }

    private static bool ValidId(string? value) => value is not null && Regex.IsMatch(value, @"^[A-Za-z0-9_.-]{1,256}$");
    private static bool HasLinkAncestor(string path)
    {
        for (var current = path; current is not null; current = Path.GetDirectoryName(current))
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) return true;
        return false;
    }
    private static bool SameInstallation(InstalledApplication a, InstalledApplication b) =>
        a.ProductId == b.ProductId && a.EpicNamespace == b.EpicNamespace && a.EpicCatalogId == b.EpicCatalogId &&
        string.Equals(a.InstallLocation, b.InstallLocation, StringComparison.OrdinalIgnoreCase);

    public ProductUninstallPlan Prepare(InstalledApplication product)
    {
        try
        {
            if (product.ManifestPath is null || product.ManifestSnapshot is null || !DeletionSafetyPolicy.IsWithin(product.ManifestPath, _manifestRoot))
                return Block(product, "Le manifeste de ce jeu n’est pas identifié. Actualisez l’inventaire.");
            var current = ReadManifest(product.ManifestPath);
            if (current is null || !SameInstallation(product, current) || current.ManifestSnapshot != product.ManifestSnapshot)
                return Block(product, "L’installation Epic a changé. Actualisez l’inventaire avant de continuer.");
            if (!string.IsNullOrWhiteSpace(product.UninstallCommand))
            {
                // Only an exact game registration merged with this manifest may execute.
                if (product.RegistrationPath is null) return Block(product, "La commande officielle du jeu n’est pas enregistrée.");
                return _registered.Prepare(product);
            }
            var executable = _launcher();
            if (executable is null) return Block(product, "Epic Games Launcher est absent ou son emplacement n’est pas valide. Réinstallez le launcher officiel pour désinstaller ce jeu ; les fichiers restent en place.");
            return new(product,
                "Epic Games Launcher va s’ouvrir. Dans Bibliothèque, retrouvez « " + product.Name + " », ouvrez son menu ⋯, puis choisissez Désinstaller et confirmez dans Epic. StorageScope suivra le résultat pendant cinq minutes. Aucune suppression ne sera exécutée directement par StorageScope. Vérifiez les options du launcher concernant vos sauvegardes.",
                true, true, executable, UninstallerIdentity: DeletionSafetyPolicy.ReadIdentity(executable, allowHardLinks: true)) { EpicGuided = true };
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or System.Security.SecurityException or ArgumentException)
        { return Block(product, "Méthode Epic indisponible : " + error.Message); }
    }
    private static ProductUninstallPlan Block(InstalledApplication product, string reason) => new(product, reason, false, false, BlockReason: reason);

    public async Task<ProductUninstallResult> ExecuteAsync(ProductUninstallPlan plan, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var fresh = Prepare(plan.Product);
        if (!fresh.CanProceed || fresh.EpicGuided != plan.EpicGuided || fresh.Executable != plan.Executable || fresh.Arguments != plan.Arguments || fresh.UninstallerIdentity != plan.UninstallerIdentity)
            throw new IOException(fresh.BlockReason ?? "La méthode Epic a changé. Actualisez l’inventaire.");
        OperationHistory.Append(new { operation = "désinstallation Epic", product = plan.Product.Name, status = "préparation" });
        using var monitoring = CancellationTokenSource.CreateLinkedTokenSource(token);
        Task<ProductUninstallResult>? officialTask = null;
        try
        {
            if (!plan.EpicGuided)
            {
                plan.Progress?.Report("Désinstalleur officiel du jeu en cours…");
                officialTask = _registered.ExecuteAsync(plan, monitoring.Token);
            }
            else
            {
                using var guard = new FileStream(plan.Executable!, FileMode.Open, FileAccess.Read, FileShare.Read);
                if (DeletionSafetyPolicy.ReadIdentity(plan.Executable!, allowHardLinks: true) != plan.UninstallerIdentity) throw new IOException("Le launcher Epic a été remplacé.");
                _open(plan.Executable!);
            }
            OperationHistory.Append(new { operation = "désinstallation Epic", product = plan.Product.Name, status = "intervention officielle et vérification" });
            plan.Progress?.Report("Intervention dans Epic : Bibliothèque → ⋯ → Désinstaller. StorageScope vérifie le résultat. Annuler arrête uniquement le suivi.");
            for (var i = 0; i < _checks; i++)
            {
                token.ThrowIfCancellationRequested();
                if (officialTask?.IsFaulted == true) await officialTask;
                if (await VerifyAsync(plan.Product, token)) return Finish(plan, true, "confirmée", "Désinstallation Epic confirmée. Les sauvegardes et composants partagés n’ont pas été nettoyés par StorageScope.");
                await _wait(token);
            }
            if (await VerifyAsync(plan.Product, token)) return Finish(plan, true, "confirmée", "Désinstallation Epic confirmée. Les sauvegardes n’ont pas été nettoyées par StorageScope.");
            return Finish(plan, false, "non confirmé", "La désinstallation Epic n’est pas confirmée. Terminez-la dans le launcher, puis actualisez l’inventaire. Aucun fichier n’a été supprimé par StorageScope.");
        }
        catch (OperationCanceledException)
        {
            // Cancellation can race with the manual "Verify now" confirmation.
            // Record the actual local result instead of overwriting success with cancellation.
            if (await VerifyAsync(plan.Product, CancellationToken.None))
                return Finish(plan, true, "confirmée", "Désinstallation Epic confirmée localement. Les sauvegardes restent conservées.");
            return Finish(plan, false, "suivi annulé", "Suivi annulé dans StorageScope. Une désinstallation déjà acceptée dans Epic peut continuer ; actualisez ensuite l’inventaire. Aucun fichier n’a été supprimé par StorageScope.");
        }
        catch (Exception error)
        {
            OperationHistory.Append(new { operation = "désinstallation Epic", product = plan.Product.Name, status = "échec", error = error.GetType().Name });
            throw;
        }
        finally
        {
            monitoring.Cancel();
            if (officialTask is not null)
            {
                try { await officialTask; }
                catch (Exception error) { Diagnostics.Write("suivi-désinstalleur-Epic", error); }
            }
        }
    }
    private static ProductUninstallResult Finish(ProductUninstallPlan plan, bool verified, string state, string message)
    {
        OperationHistory.Append(new { operation = "désinstallation Epic", product = plan.Product.Name, status = state, verified });
        return new(verified, message, state);
    }

    public Task<bool> VerifyAsync(InstalledApplication product, CancellationToken token) => Task.Run(async () =>
    {
        token.ThrowIfCancellationRequested();
        if (product.ManifestPath is null) return false;
        try
        {
            // Enumerating the accessible root distinguishes a missing manifest from denied access.
            if (HasLinkAncestor(_manifestRoot)) return false;
            foreach (var file in Directory.EnumerateFiles(_manifestRoot, "*.item"))
            {
                token.ThrowIfCancellationRequested();
                if (string.Equals(Path.GetFullPath(file), product.ManifestPath, StringComparison.OrdinalIgnoreCase)) return false;
                var current = ReadManifest(file);
                if (current is not null && SameInstallation(product, current)) return false;
            }
            return product.RegistrationPath is null || await _registered.VerifyAsync(product, token);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or System.Security.SecurityException) { return false; }
    }, token);

    private static string? ResolveLauncher()
    {
        var candidates = new List<string>();
        try
        {
            if (Registry.GetValue(@"HKEY_CLASSES_ROOT\com.epicgames.launcher\shell\open\command", "", null) is string command)
                candidates.Add(RegisteredProductProvider.ParseCommand(command).Executable);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
        foreach (var programFiles in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) })
        foreach (var architecture in new[] { "Win64", "Win32" }) candidates.Add(Path.Combine(programFiles, "Epic Games", "Launcher", "Portal", "Binaries", architecture, "EpicGamesLauncher.exe"));
        foreach (var path in candidates)
        {
            try
            {
                if (Path.GetFileName(path).Equals("EpicGamesLauncher.exe", StringComparison.OrdinalIgnoreCase) && File.Exists(path) && !HasLinkAncestor(path)) return path;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return null;
    }
}
