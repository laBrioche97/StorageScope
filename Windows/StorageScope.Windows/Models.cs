using System.Collections.ObjectModel;

namespace StorageScope.Windows;

public enum StorageCategory
{
    Applications,
    ApplicationData,
    Images,
    Videos,
    Audio,
    Documents,
    ArchivesInstallers,
    Development,
    VirtualMachines,
    Backups,
    MailMessages,
    CachesLogs,
    SystemLibraries,
    Other
}

public sealed record ScanEntry(
    string Path,
    string Name,
    long Size,
    bool IsDirectory,
    DateTime? Modified,
    StorageCategory Category)
{
    public string DisplaySize => SizeFormatter.Format(Size);
    public string Type => IsDirectory ? "Dossier" : CategoryLabels.Name(Category);
}

public sealed record CategoryResult(StorageCategory Category, long Bytes, long FileCount)
{
    public string Name => CategoryLabels.Name(Category);
    public string DisplaySize => SizeFormatter.Format(Bytes);
    public string Details => $"{FileCount:N0} fichiers";
}

public sealed record CategoryTile(CategoryResult Result, double Percent)
{
    public string Name => Result.Name;
    public string DisplaySize => Result.DisplaySize;
    public string Details => $"{Percent:N1} % · {Result.FileCount:N0} fichiers";
}

public sealed record CleanupCandidate(string Path, string Reason, long Size, bool IsDirectory)
{
    public string Name => System.IO.Path.GetFileName(Path.TrimEnd('\\'));
    public string DisplaySize => SizeFormatter.Format(Size);
}

public sealed record InstalledApplication(string Name, string? Publisher, string? Version, string? InstallLocation, string? UninstallCommand)
{
    public string Details => string.Join(" · ", new[] { Publisher, Version }.Where(value => !string.IsNullOrWhiteSpace(value)));
}

public sealed class ScanResult
{
    public required string Root { get; init; }
    public required IReadOnlyDictionary<string, long> DirectorySizes { get; init; }
    public required IReadOnlyList<ScanEntry> LargestFiles { get; init; }
    public required IReadOnlyList<CategoryResult> Categories { get; init; }
    public required IReadOnlyList<CleanupCandidate> CleanupCandidates { get; init; }
    public required long IdentifiedBytes { get; init; }
    public required long FilesScanned { get; init; }
    public required long DirectoriesScanned { get; init; }
    public required long AccessErrors { get; init; }
}

public sealed record ScanProgress(long Files, long Directories, long Bytes, long Errors, string CurrentPath, double Fraction);

public static class SizeFormatter
{
    public static string Format(long bytes)
    {
        string[] units = ["octets", "Ko", "Mo", "Go", "To", "Po"];
        var value = Math.Max(0, bytes);
        var index = 0;
        double display = value;
        while (display >= 1024 && index < units.Length - 1)
        {
            display /= 1024;
            index++;
        }
        return index == 0 ? $"{display:N0} {units[index]}" : $"{display:N1} {units[index]}";
    }
}

public static class CategoryLabels
{
    public static string Name(StorageCategory category) => category switch
    {
        StorageCategory.Applications => "Applications",
        StorageCategory.ApplicationData => "Données d’applications",
        StorageCategory.Images => "Images",
        StorageCategory.Videos => "Vidéos",
        StorageCategory.Audio => "Audio",
        StorageCategory.Documents => "Documents",
        StorageCategory.ArchivesInstallers => "Archives et installateurs",
        StorageCategory.Development => "Développement",
        StorageCategory.VirtualMachines => "VM et conteneurs",
        StorageCategory.Backups => "Sauvegardes",
        StorageCategory.MailMessages => "Mail et messages",
        StorageCategory.CachesLogs => "Caches et journaux",
        StorageCategory.SystemLibraries => "Système et bibliothèques",
        _ => "Autres fichiers identifiés"
    };
}
