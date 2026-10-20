using System.IO;
using System.Windows.Media;
using StorageScope.Windows;

internal static class ExplorerFeatureTests
{
    internal static void Run(string fixtureRoot)
    {
        var weights = new[] { 16d, 9, 4, 1 };
        var packed = CirclePacking.Pack(weights);
        Require(packed.SequenceEqual(CirclePacking.Pack(weights)));
        for (var i = 0; i < packed.Count; i++)
        {
            var p = packed[i];
            Require(double.IsFinite(p.X) && Math.Sqrt(p.X * p.X + p.Y * p.Y) + p.Radius <= 1.000001);
            Require(Math.Abs(Math.Pow(p.Radius / packed[0].Radius, 2) - weights[i] / weights[0]) < .000001);
            for (var j = 0; j < i; j++)
                Require(Math.Sqrt(Math.Pow(p.X - packed[j].X, 2) + Math.Pow(p.Y - packed[j].Y, 2)) >= p.Radius + packed[j].Radius - .000001);
        }
        Require(CirclePacking.Pack([]).Count == 0 && CirclePacking.Pack([0, 0]).Count == 0);
        var root = Path.Combine(fixtureRoot, "bubble-fixture");
        var sizes = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase) { [root] = 500_000 };
        for (var i = 0; i < 100; i++)
        {
            var parent = Path.Combine(root, $"folder-{i:D3}"); sizes[parent] = 1000;
            for (var j = 0; j < 40; j++) sizes[Path.Combine(parent, $"nested-{j:D3}")] = 20;
        }
        var result = new ScanResult { Root = root, DirectorySizes = sizes, LargestFiles = [], Categories = [], CleanupCandidates = [], IdentifiedBytes = 500_000, FilesScanned = 0, DirectoriesScanned = sizes.Count, AccessErrors = 1 };
        var index = new FolderIndex(result); var frame = index.Frame(root, default);
        Require(frame.Circles.Count <= 200 && frame.Circles.All(c => c.Depth < 3) && frame.Partial);
        var siblings = frame.Circles.Where(c => c.Depth == 0).ToArray();
        Require(siblings.Length == 32 && siblings.Sum(c => c.Bytes) == 100_000 && siblings.Last().Aggregate);
        Require(index.Remainder(root).Count == 69 && frame.DirectFiles == 400_000);
        Require(index.Frame(Path.Combine(root, "unknown"), default).Total is null);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        try { index.Frame(root, cancellation.Token); throw new Exception("Cancelled layout completed."); } catch (OperationCanceledException) { }

        // The cache is exercised from workers, like actual icon extraction, not only STA fixtures.
        var app = new InstalledApplication("Fixture", null, "1", root, null, ProductId: "fixture");
        var cache = new SessionIconCache(); var calls = 0;
        var drawing = new DrawingImage(new GeometryDrawing(Brushes.Blue, null, new RectangleGeometry(new System.Windows.Rect(0, 0, 32, 32)))); drawing.Freeze();
        var gate = new TaskCompletionSource<ImageSource>(TaskCreationOptions.RunContinuationsAsynchronously);
        var first = cache.GetAsync(SessionIconCache.Key(app), () => { Interlocked.Increment(ref calls); return gate.Task; });
        var second = cache.GetAsync(SessionIconCache.Key(app), () => throw new Exception("Duplicate load"));
        gate.SetResult(drawing);
        Require(ReferenceEquals(first.GetAwaiter().GetResult(), second.GetAwaiter().GetResult()) && calls == 1);
        Require(ReferenceEquals(cache.Peek(SessionIconCache.Key(app)), drawing));
        Require(cache.Peek(SessionIconCache.Key(app with { Version = "2" })) is null);
        Require(new SessionIconCache().Peek(SessionIconCache.Key(app)) is null);
        var failedKey = "failed";
        Require(ReferenceEquals(cache.GetAsync(failedKey, () => Task.FromResult(ApplicationIcons.Fallback)).Result, ApplicationIcons.Fallback));
        Require(cache.Peek(failedKey) is null);
        Require(ReferenceEquals(cache.GetAsync(failedKey, () => Task.FromResult<ImageSource>(drawing)).Result, drawing));
        var unknown = new ScanEntry(root, "unknown", 0, true, null, StorageCategory.Other) { HasKnownSize = false };
        Require(unknown.DisplaySize == "Taille inconnue");
        Directory.CreateDirectory(root); File.WriteAllBytes(Path.Combine(root, "payload"), new byte[4096]);
        var preparation = CleanupOperations.Prepare([unknown], null, default);
        Require(preparation.Ready.Single().Entry.HasKnownSize && preparation.Ready.Single().Entry.Size == 4096);
    }
    private static void Require(bool condition) { if (!condition) throw new Exception("Explorer/cache feature regression."); }
}
