namespace StorageScope.Windows;

public static class CategoryClassifier
{
    private static readonly HashSet<string> Images = new(StringComparer.OrdinalIgnoreCase) { ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tif", ".tiff", ".heic", ".raw", ".svg" };
    private static readonly HashSet<string> Videos = new(StringComparer.OrdinalIgnoreCase) { ".mp4", ".mkv", ".mov", ".avi", ".wmv", ".webm", ".m4v", ".mts" };
    private static readonly HashSet<string> Audio = new(StringComparer.OrdinalIgnoreCase) { ".mp3", ".wav", ".flac", ".aac", ".m4a", ".ogg", ".wma" };
    private static readonly HashSet<string> Documents = new(StringComparer.OrdinalIgnoreCase) { ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".txt", ".rtf", ".odt", ".ods", ".epub" };
    private static readonly HashSet<string> Archives = new(StringComparer.OrdinalIgnoreCase) { ".zip", ".7z", ".rar", ".tar", ".gz", ".bz2", ".iso", ".msi", ".msix", ".appx" };
    private static readonly HashSet<string> Development = new(StringComparer.OrdinalIgnoreCase) { ".cs", ".cpp", ".c", ".h", ".swift", ".rs", ".go", ".java", ".kt", ".js", ".ts", ".tsx", ".py", ".rb", ".php", ".sql", ".json", ".yaml", ".yml" };
    private static readonly HashSet<string> Executables = new(StringComparer.OrdinalIgnoreCase) { ".exe", ".dll", ".sys", ".com" };
    private static readonly HashSet<string> VirtualMachines = new(StringComparer.OrdinalIgnoreCase) { ".vhd", ".vhdx", ".vmdk", ".vdi", ".qcow", ".qcow2", ".wsl" };

    public static StorageCategory Classify(string path)
    {
        var extension = Path.GetExtension(path);
        var normalized = path.Replace('/', '\\').ToLowerInvariant();
        if (normalized.Contains("\\windows\\") || normalized.Contains("\\program files\\windowsapps\\")) return StorageCategory.SystemLibraries;
        if (normalized.Contains("\\appdata\\") || normalized.Contains("\\programdata\\"))
        {
            if (normalized.Contains("\\cache") || normalized.Contains("\\temp\\") || normalized.Contains("\\logs\\")) return StorageCategory.CachesLogs;
            return StorageCategory.ApplicationData;
        }
        if (normalized.Contains("\\mail\\") || normalized.Contains("\\outlook\\") || extension.Equals(".pst", StringComparison.OrdinalIgnoreCase) || extension.Equals(".ost", StringComparison.OrdinalIgnoreCase)) return StorageCategory.MailMessages;
        if (normalized.Contains("\\backup") || normalized.Contains("filehistory") || extension.Equals(".bak", StringComparison.OrdinalIgnoreCase)) return StorageCategory.Backups;
        if (normalized.Contains("node_modules") || normalized.Contains("\\.git\\") || normalized.Contains("\\packages\\") || Development.Contains(extension)) return StorageCategory.Development;
        if (VirtualMachines.Contains(extension) || normalized.Contains("\\virtual machines\\") || normalized.Contains("\\docker\\") || normalized.Contains("\\wsl\\")) return StorageCategory.VirtualMachines;
        if (Images.Contains(extension)) return StorageCategory.Images;
        if (Videos.Contains(extension)) return StorageCategory.Videos;
        if (Audio.Contains(extension)) return StorageCategory.Audio;
        if (Documents.Contains(extension)) return StorageCategory.Documents;
        if (Archives.Contains(extension)) return StorageCategory.ArchivesInstallers;
        if (Executables.Contains(extension) || normalized.Contains("\\program files\\") || normalized.Contains("\\program files (x86)\\")) return StorageCategory.Applications;
        if (extension.Equals(".log", StringComparison.OrdinalIgnoreCase) || extension.Equals(".tmp", StringComparison.OrdinalIgnoreCase) || extension.Equals(".dmp", StringComparison.OrdinalIgnoreCase)) return StorageCategory.CachesLogs;
        return StorageCategory.Other;
    }
}
