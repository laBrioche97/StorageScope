namespace StorageScope.Windows;

internal sealed record ExplorerViewSnapshot(IReadOnlyList<ScanEntry> Entries, FolderFrame? Frame, string Layout,
    string[] Selection, double Scroll, long Cost)
{
    private IReadOnlyList<ScanEntry>? Largest { get; init; }
    private IReadOnlyList<ScanEntry>? Smallest { get; init; }
    private IReadOnlyList<ScanEntry>? Names { get; init; }
    internal IReadOnlyList<ScanEntry> Ordered(ResultOrder order) => (order switch { ResultOrder.Smallest => Smallest, ResultOrder.Name => Names, _ => Largest }) ?? Entries;
    internal static ExplorerViewSnapshot Create(IReadOnlyList<ScanEntry> entries, FolderFrame? frame, string layout, string[] selection, double scroll) => new(entries, frame, layout, selection, scroll, Estimate(entries)) {
        Largest = entries.OrderByDescending(item => item.Size).ThenBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase).ToArray(),
        Smallest = entries.OrderBy(item => item.Size).ThenBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase).ToArray(),
        Names = entries.OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase).ToArray()
    };
    internal static long Estimate(IReadOnlyList<ScanEntry> entries) => 512L + entries.Sum(item => 288L + (item.Path.Length + item.Name.Length) * 2L);
}

internal sealed class ExplorerSessionCache
{
    internal const long Capacity = 64L * 1024 * 1024;
    private readonly Dictionary<string, (ExplorerViewSnapshot Value, long Used)> _items = new(StringComparer.OrdinalIgnoreCase);
    private long _clock;
    internal long Bytes { get; private set; }
    internal int Count => _items.Count;
    internal ExplorerViewSnapshot? Get(string key)
    {
        if (!_items.TryGetValue(key, out var found)) return null;
        _items[key] = (found.Value, ++_clock); return found.Value;
    }
    internal void Put(string key, ExplorerViewSnapshot value)
    {
        if (_items.Remove(key, out var old)) Bytes -= old.Value.Cost;
        // Reserve half of the 64 MiB navigation budget for the transient transition image.
        if (value.Cost > Capacity / 2) return;
        _items[key] = (value, ++_clock); Bytes += value.Cost;
        while (Bytes > Capacity / 2 || _items.Count > 32) { var victim = _items.MinBy(item => item.Value.Used); Bytes -= victim.Value.Value.Cost; _items.Remove(victim.Key); }
    }
    internal void Clear() { _items.Clear(); Bytes = 0; }
}
