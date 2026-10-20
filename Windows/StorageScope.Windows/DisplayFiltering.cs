using System.IO;

namespace StorageScope.Windows;

public enum ResultOrder { Largest, Smallest, Name }
public enum EntryKind { All, Files, Directories }
public sealed record CategoryChoice(string Label, StorageCategory? Category) { public System.Windows.Media.Brush IconBrush => CategoryVisuals.Ink(Category ?? StorageCategory.Other); public string IconGlyph => Category is StorageCategory category ? CategoryVisuals.Glyph(category) : "\uE80A"; public override string ToString() => Label; }
public sealed record SizeChoice(string Label, long Bytes) { public override string ToString() => Label; }
public sealed record SortChoice(string Label, ResultOrder Order) { public override string ToString() => Label; }
public sealed record KindChoice(string Label, EntryKind Kind) { public override string ToString() => Label; }

public sealed record DisplayFilter(string Search, StorageCategory? Category, long MinimumBytes, EntryKind Kind)
{
    public bool Matches(string name, string? path, long? size, bool directory, StorageCategory category)
    {
        if (Category is not null && Category != category) return false;
        if (MinimumBytes > 0 && (size is null || size < MinimumBytes)) return false;
        if (Kind == EntryKind.Files && directory || Kind == EntryKind.Directories && !directory) return false;
        return string.IsNullOrWhiteSpace(Search) || (name + " " + path).Contains(Search.Trim(), StringComparison.CurrentCultureIgnoreCase);
    }
    public bool Matches(ScanEntry item) => Matches(item.Name, item.Path, item.Size, item.IsDirectory, item.Category);
    public bool Matches(CleanupCandidate item) => Matches(item.Name, item.Path, item.Size, item.IsDirectory, CategoryClassifier.Classify(item.Path));
    public bool Matches(InstalledApplication item) => Matches(item.Name + " " + item.Provider + " " + item.Publisher, item.InstallLocation, item.EstimatedBytes, true, StorageCategory.Applications);
}

// Retention is independent for every category; small categories cannot be displaced by large videos.
internal sealed class CategoryFileIndex
{
    public const int Limit = 500;
    private readonly object _gate = new();
    private readonly Dictionary<StorageCategory, PriorityQueue<ScanEntry, (long, string)>> _queues = [];
    public void Observe(ScanEntry entry)
    {
        lock (_gate)
        {
            if (!_queues.TryGetValue(entry.Category, out var queue)) _queues[entry.Category] = queue = new();
            queue.Enqueue(entry, (entry.Size, entry.Path));
            if (queue.Count > Limit) queue.Dequeue();
        }
    }
    public IReadOnlyDictionary<StorageCategory, IReadOnlyList<ScanEntry>> Results()
    {
        lock (_gate) return _queues.ToDictionary(pair => pair.Key, pair => (IReadOnlyList<ScanEntry>)pair.Value.UnorderedItems
            .Select(item => item.Element).OrderByDescending(item => item.Size).ThenBy(item => item.Path, StringComparer.OrdinalIgnoreCase).ToArray());
    }
}
