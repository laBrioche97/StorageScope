using System.IO;
using System.Text.RegularExpressions;

namespace StorageScope.Windows;

public sealed record GameCacheAuthorization(string SteamApps, string AppId, FileSnapshot OriginalManifest)
{
    public string CacheRoot => Path.Combine(SteamApps, "shadercache", AppId);
    public string Manifest => Path.Combine(SteamApps, "appmanifest_" + AppId + ".acf");
    public bool Allows(string path)
    {
        if (OriginalManifest.IsDirectory || OriginalManifest.FileId == 0 || !Regex.IsMatch(AppId, @"^\d+$") || !Path.GetFileName(SteamApps).Equals("steamapps", StringComparison.OrdinalIgnoreCase)
            || !Path.IsPathFullyQualified(SteamApps) || File.Exists(Manifest) || Directory.Exists(Manifest)
            || !DeletionSafetyPolicy.IsWithin(path, CacheRoot)) return false;
        return true;
    }
}

public static class GameResiduals
{
    public static Task<IReadOnlyList<CleanupCandidate>> FindAsync(InstalledApplication product) => Task.Run<IReadOnlyList<CleanupCandidate>>(() =>
    {
        if (product.Provider != "Steam" || product.ManifestPath is null || product.ManifestSnapshot is null || File.Exists(product.ManifestPath)) return [];
        var id = Regex.Match(Path.GetFileName(product.ManifestPath), @"^appmanifest_(\d+)\.acf$").Groups[1].Value;
        if (id.Length == 0) return [];
        var authorization = new GameCacheAuthorization(Path.GetDirectoryName(product.ManifestPath)!, id, product.ManifestSnapshot);
        if (!Directory.Exists(authorization.CacheRoot) || !authorization.Allows(authorization.CacheRoot)) return [];
        try
        {
            var snapshot = DeletionSafetyPolicy.Capture(authorization.CacheRoot, gameCache: authorization);
            long size = 0;
            var stack = new Stack<string>(); stack.Push(authorization.CacheRoot);
            while (stack.TryPop(out var directory))
                foreach (var path in Directory.EnumerateFileSystemEntries(directory))
                {
                    if (DeletionSafetyPolicy.BlockReason(path, gameCache: authorization) is not null) throw new IOException("Résidu inaccessible.");
                    var identity = DeletionSafetyPolicy.ReadIdentity(path);
                    if (identity.IsDirectory) stack.Push(path); else size = checked(size + identity.Length);
                }
            return [new(authorization.CacheRoot, "Cache de shaders attribué à l’identifiant exact du jeu Steam désinstallé.", size, true,
                "Résidus de jeux désinstallés", "Ce cache peut être recréé. Les sauvegardes, mods, Workshop et bibliothèques partagées restent conservés.", false, Snapshot: snapshot, GameCache: authorization)];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return []; }
    });
}
