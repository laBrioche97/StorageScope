using Microsoft.Win32;
using Microsoft.VisualBasic.FileIO;
using System.Diagnostics;
using System.IO;

namespace StorageScope.Windows;

public static class DirectoryBrowser
{
    public static Task<IReadOnlyList<ScanEntry>> BrowseAsync(string path, IReadOnlyDictionary<string, long>? sizes, CancellationToken token) => Task.Run(() =>
    {
        var result = new List<ScanEntry>();
        var options = new EnumerationOptions { IgnoreInaccessible = true, RecurseSubdirectories = false, ReturnSpecialDirectories = false };
        try
        {
            foreach (var directory in new DirectoryInfo(path).EnumerateDirectories("*", options))
            {
                token.ThrowIfCancellationRequested();
                if ((directory.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                result.Add(new ScanEntry(directory.FullName, directory.Name, sizes?.GetValueOrDefault(directory.FullName) ?? 0, true, SafeModified(directory), StorageCategory.Other));
            }
            foreach (var file in new DirectoryInfo(path).EnumerateFiles("*", options))
            {
                token.ThrowIfCancellationRequested();
                long length;
                try { length = file.Length; } catch { length = 0; }
                result.Add(new ScanEntry(file.FullName, file.Name, length, false, SafeModified(file), CategoryClassifier.Classify(file.FullName)));
            }
        }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException or System.Security.SecurityException) { }
        return (IReadOnlyList<ScanEntry>)result.OrderByDescending(item => item.Size).ThenBy(item => item.Name).ToList();
    }, token);

    private static DateTime? SafeModified(FileSystemInfo info) { try { return info.LastWriteTime; } catch { return null; } }
}

public static class RecycleBinService
{
    public static void MoveToRecycleBin(IEnumerable<ScanEntry> entries)
    {
        foreach (var entry in Normalize(entries))
        {
            if (IsProtected(entry.Path)) throw new InvalidOperationException($"Chemin protégé : {entry.Path}");
            if (entry.IsDirectory)
                FileSystem.DeleteDirectory(entry.Path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
            else
                FileSystem.DeleteFile(entry.Path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
        }
    }

    private static IEnumerable<ScanEntry> Normalize(IEnumerable<ScanEntry> entries)
    {
        var ordered = entries.DistinctBy(item => item.Path, StringComparer.OrdinalIgnoreCase).OrderBy(item => item.Path.Length).ToList();
        return ordered.Where(item => !ordered.Any(parent => parent.Path.Length < item.Path.Length && item.Path.StartsWith(parent.Path.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)));
    }

    private static bool IsProtected(string path)
    {
        var full = Path.GetFullPath(path).TrimEnd('\\');
        var root = Path.GetPathRoot(full)?.TrimEnd('\\');
        if (string.Equals(full, root, StringComparison.OrdinalIgnoreCase)) return true;
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows).TrimEnd('\\');
        return string.Equals(full, windows, StringComparison.OrdinalIgnoreCase) || full.StartsWith(windows + "\\", StringComparison.OrdinalIgnoreCase);
    }
}

public static class InstalledApplicationService
{
    private static readonly string[] RegistryPaths =
    [
        @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    ];

    public static Task<IReadOnlyList<InstalledApplication>> LoadAsync(CancellationToken token) => Task.Run(() =>
    {
        var applications = new Dictionary<string, InstalledApplication>(StringComparer.OrdinalIgnoreCase);
        foreach (var hive in new[] { Registry.LocalMachine, Registry.CurrentUser })
        foreach (var registryPath in RegistryPaths)
        {
            token.ThrowIfCancellationRequested();
            using var parent = hive.OpenSubKey(registryPath);
            if (parent is null) continue;
            foreach (var childName in parent.GetSubKeyNames())
            {
                using var child = parent.OpenSubKey(childName);
                var name = child?.GetValue("DisplayName") as string;
                if (string.IsNullOrWhiteSpace(name) || Convert.ToInt32(child?.GetValue("SystemComponent") ?? 0) == 1) continue;
                var application = new InstalledApplication(
                    name.Trim(),
                    child?.GetValue("Publisher") as string,
                    child?.GetValue("DisplayVersion") as string,
                    child?.GetValue("InstallLocation") as string,
                    (child?.GetValue("QuietUninstallString") ?? child?.GetValue("UninstallString")) as string);
                var key = $"{application.Name}|{application.Version}|{application.Publisher}";
                applications.TryAdd(key, application);
            }
        }
        return (IReadOnlyList<InstalledApplication>)applications.Values.OrderBy(item => item.Name).ToList();
    }, token);

    public static void LaunchOfficialUninstaller(InstalledApplication application)
    {
        var command = application.UninstallCommand;
        if (string.IsNullOrWhiteSpace(command)) throw new InvalidOperationException("Cette application ne fournit pas de désinstalleur officiel.");
        var (fileName, arguments) = SplitCommand(command);
        Process.Start(new ProcessStartInfo(fileName, arguments) { UseShellExecute = true, WorkingDirectory = application.InstallLocation ?? "" });
    }

    private static (string FileName, string Arguments) SplitCommand(string command)
    {
        command = command.Trim();
        if (command.StartsWith('"'))
        {
            var end = command.IndexOf('"', 1);
            if (end > 1) return (command[1..end], command[(end + 1)..].Trim());
        }
        var exe = command.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
        if (exe >= 0) return (command[..(exe + 4)].Trim(), command[(exe + 4)..].Trim());
        throw new InvalidOperationException("Commande de désinstallation non reconnue.");
    }
}

public static class ExplorerService
{
    public static void ShowInExplorer(string path)
    {
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
    }

    public static void Open(string path)
    {
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }
}
