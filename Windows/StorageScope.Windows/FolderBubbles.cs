using System.IO;

namespace StorageScope.Windows;

internal sealed record FolderCircle(string Path, string Name, long Bytes, double X, double Y, double Radius, int Depth, bool Aggregate = false, int SkipCount = 0, long ParentBytes = 0);
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
        var output = new List<FolderCircle>(); var budget = 200;
        var total = _sizes.TryGetValue(path, out var bytes) || _sizes.TryGetValue(path.TrimEnd('\\'), out bytes) ? (long?)bytes : null;
        Add(path, total ?? 0, 0, 0, 1, 0);
        var childSum = Children(path).Sum(item => item.Bytes);
        return new(output, total, total.HasValue ? Math.Max(0, total.Value - childSum) : null, _partial);

        void Add(string parent, long parentBytes, double x, double y, double radius, int depth)
        {
            token.ThrowIfCancellationRequested();
            if (depth >= 3 || budget == 0) return;
            var all = Children(parent).Where(item => item.Bytes > 0).ToList();
            var take = Math.Min(all.Count, Math.Min(32, budget));
            if (take == 0) return;
            var group = all.Count > take;
            var visible = all.Take(group ? take - 1 : take).Select(item => (item.Path, item.Bytes, Aggregate: false)).ToList();
            if (group) visible.Add((parent, all.Skip(take - 1).Sum(item => item.Bytes), true));
            budget -= visible.Count;
            var packed = CirclePacking.Pack(visible.Select(item => (double)item.Bytes).ToArray());
            var childFraction = parentBytes > 0 ? Math.Min(1, visible.Sum(item => (double)item.Bytes) / parentBytes) : 1;
            var scale = radius * .90 * Math.Sqrt(childFraction);
            for (var i = 0; i < visible.Count; i++)
            {
                var item = visible[i]; var p = packed[i];
                var circle = new FolderCircle(item.Path, item.Aggregate ? $"Autres dossiers ({all.Count - take + 1})" : System.IO.Path.GetFileName(item.Path.TrimEnd('\\')), item.Bytes, x + p.X * scale, y + p.Y * scale, p.Radius * scale, depth, item.Aggregate, item.Aggregate ? take - 1 : 0, parentBytes);
                output.Add(circle);
            }
            // Reserve all siblings before allocating the bounded deeper levels.
            foreach (var circle in output.Where(c => c.Depth == depth && Math.Abs(c.X - x) <= radius && Math.Abs(c.Y - y) <= radius).ToArray())
                if (!circle.Aggregate && visible.Any(v => v.Path == circle.Path)) Add(circle.Path, circle.Bytes, circle.X, circle.Y, circle.Radius, depth + 1);
        }
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
