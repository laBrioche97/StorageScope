using System.Collections.ObjectModel;
using System.IO;
using System.Windows.Media;

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
    public bool HasKnownSize { get; init; } = true;
    public override string ToString() => Name;
    public string DisplaySize => HasKnownSize ? SizeFormatter.Format(Size) : "Taille inconnue";
    [System.Text.Json.Serialization.JsonIgnore]
    public string IconGlyph => IsDirectory ? "\uE8B7" : CategoryVisuals.Glyph(Category);
    [System.Text.Json.Serialization.JsonIgnore]
    public Brush IconBrush => CategoryVisuals.Ink(Category);
    public string Type => IsDirectory ? "Dossier" : CategoryLabels.Name(Category);
    public string CategoryName => CategoryLabels.Name(Category);
}

public sealed record CategoryResult(StorageCategory Category, long Bytes, long FileCount)
{
    public override string ToString() => Name;
    [System.Text.Json.Serialization.JsonIgnore]
    public string IconGlyph => CategoryVisuals.Glyph(Category);
    [System.Text.Json.Serialization.JsonIgnore]
    public Brush IconBrush => CategoryVisuals.Ink(Category);
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

public sealed record CleanupCandidate(string Path, string Reason, long Size, bool IsDirectory,
    string Group = "À examiner", string Consequence = "Vérifiez le contenu avant de le déplacer vers la Corbeille.",
    bool Recommended = false, string? DuplicateKeeper = null, FileSnapshot? Snapshot = null,
    FileSnapshot? KeeperSnapshot = null, GameCacheAuthorization? GameCache = null)
{
    public override string ToString() => Name;
    private StorageCategory IconCategory => Group.Contains("Cache", StringComparison.OrdinalIgnoreCase) || Group.Contains("temporaire", StringComparison.OrdinalIgnoreCase) ? StorageCategory.CachesLogs : CategoryClassifier.Classify(Path);
    [System.Text.Json.Serialization.JsonIgnore]
    public string IconGlyph => CategoryVisuals.Glyph(IconCategory);
    [System.Text.Json.Serialization.JsonIgnore]
    public Brush IconBrush => CategoryVisuals.Ink(IconCategory);
    public string Name => System.IO.Path.GetFileName(Path.TrimEnd('\\'));
    public string DisplaySize => SizeFormatter.Format(Size);
}

public sealed record InstalledApplication(string Name, string? Publisher, string? Version, string? InstallLocation, string? UninstallCommand,
    string Provider = "Application", string? ProductId = null, string? RegistrationPath = null, string? PackageFullName = null,
    string? ManifestPath = null, FileSnapshot? ManifestSnapshot = null, long? EstimatedBytes = null, string? IconLocation = null,
    string? EpicNamespace = null, string? EpicCatalogId = null)
{
    public string Details => string.Join(" · ", new[] { Publisher, Version }.Where(value => !string.IsNullOrWhiteSpace(value)));
    public string Source => Provider;
    public long SortSize => EstimatedBytes ?? 0;
    public bool HasKnownSize => EstimatedBytes.HasValue;
    public string SizeStatus { get; init; } = EstimatedBytes.HasValue ? "Taille déclarée" : "Calcul en cours";
    public string DisplaySize => EstimatedBytes is long size ? $"{SizeFormatter.Format(size)} · {SizeStatus}" : SizeStatus;
    public ImageSource Icon { get; init; } = ApplicationIcons.Fallback;
    // UI Automation must never stringify a decoder owned by an inventory worker.
    public override string ToString() => Name;
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
    public bool CleanupTruncated { get; init; }
    public IReadOnlyDictionary<StorageCategory, IReadOnlyList<ScanEntry>> CategoryFiles { get; init; } = new Dictionary<StorageCategory, IReadOnlyList<ScanEntry>>();
}

public sealed record ScanProgress(long Files, long Directories, long Bytes, long Errors, string CurrentPath, double Fraction, string? Stage = null);

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
