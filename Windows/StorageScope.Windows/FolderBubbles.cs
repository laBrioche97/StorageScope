using System.IO;

namespace StorageScope.Windows;

internal sealed record FolderCircle(string Path, string Name, long Bytes, double X, double Y, double Radius, int Depth, bool Aggregate = false, int SkipCount = 0, long ParentBytes = 0) { public bool IsDirectory { get; init; } = true; }
internal sealed record FolderFrame(IReadOnlyList<FolderCircle> Circles, long? Total, long? DirectFiles, bool Partial);

internal sealed class FolderIndex
{
    private readonly IReadOnlyDictionary<string, long> _sizes;
    private readonly Dictionary<string, List<(string Path, long Bytes)>> _children = new(StringComparer.OrdinalIgnoreCase);
    private readonly bool _partial;
    internal FolderIndex(ScanResult result)
    {
        _sizes = result.DirectorySizes; _partial = result.AccessErrors > 0;
        foreach (var (path, bytes) in _sizes)
        {
            var parent = System.IO.Path.GetDirectoryName(path.TrimEnd('\\'));
            if (parent is null) continue;
            if (!_children.TryGetValue(parent, out var children)) _children[parent] = children = [];
            children.Add((path, bytes));
        }
        foreach (var children in _children.Values)
            children.Sort((a, b) => a.Bytes != b.Bytes ? b.Bytes.CompareTo(a.Bytes) : StringComparer.OrdinalIgnoreCase.Compare(a.Path, b.Path));
    }
    internal IReadOnlyList<string> Remainder(string path, int skip = 31) => Children(path).Where(item => item.Bytes > 0).Skip(skip).Select(item => item.Path).ToArray();
    private List<(string Path, long Bytes)> Children(string path) => _children.GetValueOrDefault(path.TrimEnd('\\')) ?? _children.GetValueOrDefault(path) ?? [];
    internal FolderFrame Frame(string path, CancellationToken token)
    {
        var frame = Frame(path, Children(path).Select(item => new ScanEntry(item.Path, Path.GetFileName(item.Path), item.Bytes, true, null, StorageCategory.Other)).ToArray(), 24, token);
        return frame with { DirectFiles = frame.Total is long total ? Math.Max(0, total - Children(path).Sum(item => item.Bytes)) : null };
    }

    internal FolderFrame Frame(string path, IReadOnlyList<ScanEntry> entries, int maximum, CancellationToken token, double availableDiameter = double.PositiveInfinity)
    {
        token.ThrowIfCancellationRequested();
        var known = entries.Where(entry => entry.HasKnownSize && entry.Size > 0).OrderByDescending(entry => entry.Size).ThenBy(entry => entry.Path, StringComparer.OrdinalIgnoreCase).ToArray();
        var total = _sizes.TryGetValue(path, out var bytes) || _sizes.TryGetValue(path.TrimEnd('\\'), out bytes) ? (long?)bytes : null;
        return BuildFrame(path, known, total, entries.Any(entry => !entry.HasKnownSize) || _partial, maximum, token, availableDiameter);
    }
    internal static FolderFrame BuildFrame(string path, IReadOnlyList<ScanEntry> entries, long? total, bool partial, int maximum, CancellationToken token, double availableDiameter = double.PositiveInfinity)
    {
        var known = entries.Where(entry => entry.HasKnownSize && entry.Size > 0).OrderByDescending(entry => entry.Size).ThenBy(entry => entry.Path, StringComparer.OrdinalIgnoreCase).ToArray();
        maximum = Math.Clamp(maximum, 2, 24);
        IReadOnlyList<CirclePacking.Circle> layout = [];
        List<(ScanEntry Entry, bool Aggregate)> visible;
        int take;
        do {
        token.ThrowIfCancellationRequested();
        take = known.Length > maximum ? maximum - 1 : known.Length;
        visible = known.Take(take).Select(entry => (Entry: entry, Aggregate: false)).ToList();
        if (known.Length > take) visible.Add((new ScanEntry(path, $"Autres éléments ({known.Length - take})", known.Skip(take).Sum(entry => entry.Size), true, null, StorageCategory.Other), true));
        token.ThrowIfCancellationRequested();
        layout = CirclePacking.Pack(visible.Select(item => (double)item.Entry.Size).ToArray());
        if (maximum <= 2 || layout.All(circle => circle.Radius * availableDiameter * .97 >= 80)) break;
        maximum--;
        } while (true);
        var circles = layout;
        var output = visible.Select((item, i) => new FolderCircle(item.Entry.Path, item.Entry.Name, item.Entry.Size, circles[i].X * .97, circles[i].Y * .97, circles[i].Radius * .97, 0, item.Aggregate, take, total ?? known.Sum(entry => entry.Size)) { IsDirectory = item.Entry.IsDirectory }).ToArray();
        return new(output, total, known.Where(entry => !entry.IsDirectory).Sum(entry => entry.Size), partial);
    }

}

internal static class CirclePacking
{
    internal readonly record struct Circle(double X, double Y, double Radius);
    // Deterministic bounded tangent sampling; one common scale preserves sibling areas.
    internal static IReadOnlyList<Circle> Pack(IReadOnlyList<double> weights)
    {
        if (weights.Count == 0) return [];
        var maximum = weights.Max();
        if (maximum <= 0 || !double.IsFinite(maximum)) return [];
        var placed = new List<Circle>();
        foreach (var weight in weights)
        {
            var r = Math.Sqrt(Math.Max(0, weight) / maximum);
            if (placed.Count == 0) { placed.Add(new(0, 0, r)); continue; }
            Circle? best = null; var bestScore = double.MaxValue;
            foreach (var anchor in placed)
                for (var angle = 0; angle < 48; angle++)
                {
                    var theta = angle * Math.PI / 24;
                    var candidate = new Circle(anchor.X + (anchor.Radius + r + .002) * Math.Cos(theta), anchor.Y + (anchor.Radius + r + .002) * Math.Sin(theta), r);
                    if (placed.Any(p => Math.Pow(p.X - candidate.X, 2) + Math.Pow(p.Y - candidate.Y, 2) < Math.Pow(p.Radius + r + .001, 2))) continue;
                    var score = Math.Sqrt(candidate.X * candidate.X + candidate.Y * candidate.Y) + r;
                    if (score < bestScore) { best = candidate; bestScore = score; }
                }
            placed.Add(best ?? new Circle(placed.Max(p => p.X + p.Radius) + r + .002, 0, r));
        }
        var left = placed.Min(p => p.X - p.Radius); var right = placed.Max(p => p.X + p.Radius);
        var top = placed.Min(p => p.Y - p.Radius); var bottom = placed.Max(p => p.Y + p.Radius);
        var cx = (left + right) / 2; var cy = (top + bottom) / 2;
        var enclosing = placed.Max(p => Math.Sqrt(Math.Pow(p.X - cx, 2) + Math.Pow(p.Y - cy, 2)) + p.Radius);
        return placed.Select(p => new Circle((p.X - cx) / enclosing, (p.Y - cy) / enclosing, p.Radius / enclosing)).ToArray();
    }
}
