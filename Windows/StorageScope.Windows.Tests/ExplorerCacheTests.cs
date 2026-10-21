using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using StorageScope.Windows;

internal static class ExplorerCacheTests
{
    internal static void Run(MainWindow window, string root, string? destination, Action<string, Action> test)
    {
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
        object? Get(string key) => typeof(MainWindow).GetField(key, flags)!.GetValue(window);
        void Set(string key, object? value) => typeof(MainWindow).GetField(key, flags)!.SetValue(window, value);
        object? Invoke(string name, params object[] arguments) => typeof(MainWindow).GetMethod(name, flags)!.Invoke(window, arguments);
        var context = SynchronizationContext.Current; SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(window.Dispatcher));
        void Pump(Func<bool> done) { var until = DateTime.UtcNow.AddSeconds(10); while (!done()) { Require(DateTime.UtcNow < until, "dispatcher timeout"); window.Dispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle); Thread.Sleep(1); } window.UpdateLayout(); }
        Task Browse(string path) => (Task)Invoke("BrowseAsync", path, true)!;
        var oldRead = window.ReadExplorerDirectory; var oldResult = Get("_result"); var oldIndex = Get("_folderIndex");
        var tabs = (TabControl)window.FindName("MainTabs"); var grid = (DataGrid)window.FindName("ExplorerGrid"); var canvas = (Canvas)window.FindName("BubbleCanvas");
        var a = Path.Combine(root, "cache-a"); var b = Path.Combine(root, "cache-b"); Directory.CreateDirectory(a); Directory.CreateDirectory(b);
        var items = Enumerable.Range(0, 1000).Select(i => new ScanEntry(Path.Combine(a, $"file-{i:D4}.txt"), $"file-{i:D4}.txt", 1000-i, false, null, StorageCategory.Documents)).ToArray();
        var other = new[] { new ScanEntry(Path.Combine(b,"child.txt"), "child.txt", 50, false, null, StorageCategory.Documents) };
        var hold = new Dictionary<string, TaskCompletionSource<IReadOnlyList<ScanEntry>>>();
        try {
            Motion.TestEnabled = false;
            tabs.SelectedItem = window.FindName("ExplorerTab"); Set("_result", null); Set("_folderIndex", null); Invoke("InvalidateExplorerCache");
            window.ReadExplorerDirectory = (path, _, _) => hold.TryGetValue(path, out var source) ? source.Task : Task.FromResult<IReadOnlyList<ScanEntry>>(path == a ? items : other);
            test("explorer cache keeps 32 LRU folders and reserves transition image memory", () => {
                var cache = new ExplorerSessionCache(); var view = new ExplorerViewSnapshot(items, null, "layout", [items[0].Path], 123, ExplorerViewSnapshot.Estimate(items));
                for (var i=0; i<32; i++) cache.Put(i.ToString(), view);
                Require(cache.Get("0") is not null, "cache missing"); cache.Put("32", view);
                Require(cache.Count == 32 && cache.Get("1") is null && cache.Get("0")?.Scroll == 123, "LRU or view state lost");
                for (var i=0; i<32; i++) cache.Put(i.ToString(), view with { Cost = 8*1024*1024 });
                Require(cache.Bytes <= ExplorerSessionCache.Capacity / 2, "cache memory budget exceeded");
                cache.Clear(); Require(cache.Count == 0 && cache.Bytes == 0, "invalidation failed");
            });
            var initial = Browse(a); Pump(() => initial.IsCompleted); initial.GetAwaiter().GetResult();
            test("cold navigation retains old path list and circles while disabling old actions", () => {
                var previousCircle = canvas.Children.OfType<BubbleButton>().First();
                hold[b] = new(); var task = Browse(b);
                Require((string?)Get("_currentDirectory") == a && grid.Items.Count == 1000 && !grid.IsEnabled && !canvas.IsEnabled, "old view cleared or actionable");
                Require(((TextBlock)window.FindName("BubbleStatus")).Text.Contains(b), "destination missing");
                Require(!((FrameworkElement)window.FindName("ExplorerLoadingPanel")).IsVisible, "loader flashes immediately");
                var delay = Stopwatch.StartNew(); Pump(() => delay.ElapsedMilliseconds > 180);
                Require(((FrameworkElement)window.FindName("ExplorerLoadingPanel")).IsVisible, "slow navigation has no loader");
                hold[b].SetResult(other); Pump(() => task.IsCompleted); task.GetAwaiter().GetResult(); hold.Remove(b);
                Require((string?)Get("_currentDirectory") == b && grid.IsEnabled && grid.Items.Count == 1, "view not published together");
                Require(!canvas.Children.Contains(previousCircle), "old circle retained after commit");
            });
            test("cached 1000-item navigation restores selection instantly and revalidates in background", () => {
                var task = Browse(a); Pump(() => task.IsCompleted); grid.SelectedItem = items[10];
                var leave = Browse(b); Pump(() => leave.IsCompleted);
                hold[a] = new(); var watch = Stopwatch.StartNew(); var back = Browse(a); watch.Stop();
                Require((string?)Get("_currentDirectory") == a && grid.SelectedItems.OfType<ScanEntry>().Any(item => item.Path == items[10].Path) && !back.IsCompleted && grid.IsEnabled, "cache not immediate or selection lost");
                hold[a].SetResult(items); Pump(() => back.IsCompleted); back.GetAwaiter().GetResult(); hold.Remove(a);
                Console.WriteLine($"Cache first 1000-item view: {watch.Elapsed.TotalMilliseconds:N2} ms");
            });
            test("rapid cache navigation rejects obsolete reads and observes external changes", () => {
                hold[a] = new(); var stale = Browse(a); var latest = Browse(b); Pump(() => latest.IsCompleted);
                hold[a].SetResult([]); Pump(() => stale.IsCompleted); hold.Remove(a);
                Require((string?)Get("_currentDirectory") == b && grid.Items.Count == 1, "stale read published");
                hold[a] = new(); var refresh = Browse(a); Require(grid.Items.Count == 1000, "cached contents unavailable");
                hold[a].SetResult(items.Take(999).ToArray()); Pump(() => refresh.IsCompleted); hold.Remove(a);
                Require(grid.Items.Count == 999, "external modification ignored");
                Invoke("InvalidateExplorerCache"); hold[b] = new(); var cold = Browse(b); Require((bool)Get("_navigationPending")!, "invalidated cache reused");
                Invoke("CancelExplorer_Click", window, new RoutedEventArgs()); hold[b].SetResult(other); Pump(() => cold.IsCompleted); hold.Remove(b);
                Require((string?)Get("_currentDirectory") == a, "cancelled destination published");
            });
            test("bubble controls retain identity during highlight changes", () => {
                var bubble = canvas.Children.OfType<BubbleButton>().First(); Invoke("RenderBubbles");
                Require(canvas.Children.Contains(bubble), "unchanged bubble rebuilt");
            });
            test("warm 1000-item views render below 50 ms at the 95th percentile", () => {
                var values = new List<double>();
                for (var i=0; i<25; i++) { var leave = Browse(b); Pump(() => leave.IsCompleted); hold[a] = new(); var watch = Stopwatch.StartNew(); var warm = Browse(a); watch.Stop(); values.Add(watch.Elapsed.TotalMilliseconds); hold[a].SetResult(items); Pump(() => warm.IsCompleted); hold.Remove(a); }
                values.Sort(); var p95 = values[(int)Math.Ceiling(values.Count*.95)-1]; Console.WriteLine($"Cached 1000 items: p95 {p95:N2} ms, max {values[^1]:N2} ms");
                if (destination is not null) { Directory.CreateDirectory(destination); File.WriteAllText(Path.Combine(destination,"navigation-performance.json"), System.Text.Json.JsonSerializer.Serialize(new { items=1000, samples=values.Count, p95Milliseconds=p95, animationDisabled=true, cacheBytes=((ExplorerSessionCache)Get("_explorerCache")!).Bytes })); }
                Require(p95 < 50, "cached view exceeds 50ms p95");
            });
            test("motion interruption and reduced motion release temporary snapshots", () => {
                var incoming = (FrameworkElement)window.FindName("ExplorerSplit"); var image = (Image)window.FindName("ExplorerTransitionSnapshot");
                Motion.TestEnabled = true; var snapshot = Motion.Capture(incoming); Require(snapshot is not null, "snapshot unavailable");
                Motion.Swap(incoming, image, snapshot, false, new(.5,.5)); Motion.Swap(incoming, image, snapshot, true, new(.5,.5));
                var timer=Stopwatch.StartNew(); Pump(() => timer.ElapsedMilliseconds > 300);
                Require(image.Source is null && image.Visibility == Visibility.Collapsed && incoming.Opacity == 1, "interrupted animation leaked snapshot");
                Motion.TestEnabled = false; Motion.Swap(incoming,image,snapshot,false,new(.5,.5)); Require(image.Source is null && incoming.RenderTransform == Transform.Identity, "reduced motion animated");
            });
        }
        finally { window.ReadExplorerDirectory = oldRead; Set("_result", oldResult); Set("_folderIndex", oldIndex); Invoke("InvalidateExplorerCache"); Motion.TestEnabled = null; tabs.SelectedItem = window.FindName("OverviewTab"); SynchronizationContext.SetSynchronizationContext(context); }
    }
    private static void Require(bool value, string reason) { if (!value) throw new InvalidOperationException(reason); }
}
