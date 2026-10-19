using Microsoft.Win32.SafeHandles;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace StorageScope.Windows;

public sealed record FileSnapshot(uint Volume, ulong FileId, long Length, long LastWrite, bool IsDirectory, string TreeDigest = "");

public static class DeletionSafetyPolicy
{
    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    private static readonly string[] ProtectedSegments = ["WindowsApps", "Windows", "$Recycle.Bin", "System Volume Information", "steamapps", "Epic Games", "XboxGames", ".ssh", ".gnupg", ".aws", ".kube", ".codex", ".git"];
    private static readonly string[] PersonalRoots = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos", "Saved Games", "Contacts", "Favorites"];
    private static readonly Regex BrowserCache = new(@"^(?:(?:Google/Chrome|Microsoft/Edge|BraveSoftware/Brave-Browser)/User Data/(?:Default|Profile [0-9]+)/(?:Cache|Code Cache|GPUCache)/|Mozilla/Firefox/Profiles/[^/]+/cache2/entries/)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public static bool IsWithin(string path, string root) =>
        string.Equals(Path.GetFullPath(path).TrimEnd('\\'), Path.GetFullPath(root).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)
        || Path.GetFullPath(path).StartsWith(Path.GetFullPath(root).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);

    public static string? BlockReason(string path, bool inspectAncestors = true, GameCacheAuthorization? gameCache = null)
    {
        try
        {
            var full = Path.GetFullPath(path);
            var verifiedGameCache = gameCache?.Allows(full) == true;
            if (full.StartsWith(@"\\", StringComparison.Ordinal) || full[2..].Contains(':')) return "Les chemins réseau et flux alternatifs sont exclus du nettoyage.";
            if (string.Equals(full.TrimEnd('\\'), Path.GetPathRoot(full)?.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return "La racine du disque est protégée.";
            if (full.Split('\\', StringSplitOptions.RemoveEmptyEntries).Any(part => ProtectedSegments.Contains(part, StringComparer.OrdinalIgnoreCase)
                && !(verifiedGameCache && part.Equals("steamapps", StringComparison.OrdinalIgnoreCase)))) return "Emplacement système, bibliothèque de jeux ou données sensibles protégés.";
            var protectedRoots = new[] {
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StorageScope")
            };
            if (protectedRoots.Where(root => !string.IsNullOrWhiteSpace(root)).Any(root => IsWithin(full, root)
                && !(verifiedGameCache && (root == Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) || root == Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86))))) return "Les programmes et composants système doivent passer par leur désinstalleur.";
            if (string.Equals(full.TrimEnd('\\'), Home.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)
                || PersonalRoots.Any(name => string.Equals(full.TrimEnd('\\'), Path.Combine(Home, name), StringComparison.OrdinalIgnoreCase))) return "Le dossier personnel principal est protégé ; sélectionnez son contenu.";
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (!verifiedGameCache && (IsWithin(full, appData) || IsWithin(full, localData)) && !IsRecognizedCache(full)) return "Données d’application : une association vérifiée est nécessaire.";
            var cloudRoots = new[] { Environment.GetEnvironmentVariable("OneDrive"), Environment.GetEnvironmentVariable("OneDriveCommercial"), Environment.GetEnvironmentVariable("OneDriveConsumer"), Path.Combine(Home, "Dropbox"), Path.Combine(Home, "iCloudDrive"), Path.Combine(Home, "Google Drive") };
            if (cloudRoots.Where(root => !string.IsNullOrWhiteSpace(root)).Any(root => IsWithin(full, root!))) return "Emplacement synchronisé exclu : la suppression pourrait se répercuter dans le cloud.";
            for (var current = full; !string.IsNullOrEmpty(current); current = inspectAncestors ? Path.GetDirectoryName(current) : null)
            {
                var attributes = File.GetAttributes(current);
                if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Offline | (FileAttributes)0x00400000 | (FileAttributes)0x00040000)) != 0) return "Lien, jonction ou fichier cloud exclu.";
                if ((attributes & FileAttributes.System) != 0 && string.Equals(current, full, StringComparison.OrdinalIgnoreCase)) return "Un élément système ne peut pas être nettoyé directement.";
            }
            return null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException) { return "Impossible de vérifier ce chemin : " + error.Message; }
    }

    public static bool IsRecognizedCache(string path)
        => CacheKind(path) is not null;

    public static string? CacheKind(string path)
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] roots = [Path.Combine(local, "Temp"), Path.Combine(local, "CrashDumps"), Path.Combine(local, "Microsoft", "Windows", "WER", "ReportArchive")];
        if (roots.Any(root => IsWithin(path, root) && !string.Equals(Path.GetFullPath(path).TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))) return "temporary";
        if (!IsWithin(path, local)) return null;
        var relative = Path.GetRelativePath(local, Path.GetFullPath(path)).Replace('\\','/');
        if (BrowserCache.IsMatch(relative)) return "browser";
        string[] tools = [Path.Combine(local,"pip","Cache"),Path.Combine(local,"npm-cache","_cacache")];
        return tools.Any(root => IsWithin(path,root) && !Path.GetFullPath(path).Equals(root,StringComparison.OrdinalIgnoreCase)) ? "tools" : null;
    }

    public static FileSnapshot Capture(string path, CancellationToken token = default, GameCacheAuthorization? gameCache = null)
    {
        var reason = BlockReason(path, gameCache: gameCache);
        if (reason is not null) throw new IOException(reason);
        var root = ReadIdentity(path);
        if (!root.IsDirectory) return root;
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var stack = new Stack<string>();
        stack.Push(path);
        while (stack.TryPop(out var directory))
        {
            token.ThrowIfCancellationRequested();
            foreach (var child in Directory.EnumerateFileSystemEntries(directory).Order(StringComparer.OrdinalIgnoreCase))
            {
                reason = BlockReason(child, gameCache: gameCache);
                if (reason is not null) throw new IOException(reason);
                var identity = ReadIdentity(child);
                digest.AppendData(Encoding.UTF8.GetBytes($"{child}\0{identity.Volume}:{identity.FileId}:{identity.Length}:{identity.LastWrite}\n"));
                if (identity.IsDirectory) stack.Push(child);
            }
        }
        return root with { TreeDigest = Convert.ToHexString(digest.GetHashAndReset()) };
    }

    public static void Revalidate(string path, FileSnapshot expected, CancellationToken token = default, GameCacheAuthorization? gameCache = null)
    {
        if (Capture(path, token, gameCache) != expected) throw new IOException("L’élément a changé depuis la vérification. Relancez l’analyse.");
    }

    public static FileSnapshot ReadIdentity(string path, bool allowHardLinks = false)
    {
        using var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid || !GetFileInformationByHandle(handle, out var info)) throw new IOException("Identité du fichier inaccessible.");
        if ((info.Attributes & (uint)FileAttributes.ReparsePoint) != 0) throw new IOException("Liens et jonctions exclus.");
        if (info.Links > 1 && !allowHardLinks) throw new IOException("Lien physique exclu pour éviter un calcul d’espace trompeur.");
        return new(info.Volume, ((ulong)info.IndexHigh << 32) | info.IndexLow,
            ((long)info.SizeHigh << 32) | info.SizeLow, ((long)info.WriteHigh << 32) | info.WriteLow,
            (info.Attributes & (uint)FileAttributes.Directory) != 0);
    }

    public static IReadOnlyList<ScanEntry> Normalize(IEnumerable<ScanEntry> entries)
    {
        var ordered = entries.Select(item => item with { Path = Path.GetFullPath(item.Path) })
            .DistinctBy(item => item.Path, StringComparer.OrdinalIgnoreCase).OrderBy(item => item.Path.Length).ToList();
        return ordered.Where(item => !ordered.Any(parent => parent.IsDirectory && parent.Path.Length < item.Path.Length && IsWithin(item.Path, parent.Path))).ToList();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeInfo
    {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out NativeInfo information);
}
