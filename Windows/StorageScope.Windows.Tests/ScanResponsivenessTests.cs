using System.Collections.Concurrent;
using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using StorageScope.Windows;

internal static class ScanResponsivenessTests
{
    internal static void Run(string fixtureRoot, Action<string, Action> test)
    {
        var root = Path.Combine(fixtureRoot, "scan-responsiveness");
        Directory.CreateDirectory(root);
        for (var i = 0; i < 4_000; i++) File.WriteAllText(Path.Combine(root, $"item-{i:D5}.bin"), "fixture");
        var nested = Path.Combine(root, "nested"); Directory.CreateDirectory(nested);
        File.WriteAllText(Path.Combine(nested, "nested.bin"), "fixture");

        test("root traversal and finalization stay off the dispatcher while it handles input", () =>
        {
            var uiThread = Environment.CurrentManagedThreadId;
            var threads = new ConcurrentBag<int>();
            var slowReport = 0;
            var finalizing = false;
            ScanResult? result = null;
            var heartbeat = new Heartbeat();
            heartbeat.Run(async () =>
            {
                result = await new ScanService().ScanAsync(root, new CallbackProgress<ScanProgress>(value =>
                {
                    threads.Add(Environment.CurrentManagedThreadId);
                    if (Interlocked.Exchange(ref slowReport, 1) == 0) Thread.Sleep(1_200);
                    if (value.Stage is not null) finalizing = true;
                }), CancellationToken.None);
            });
            Require(result?.FilesScanned == 4_001 && result.IdentifiedBytes == 4_001 * 7);
            Require(threads.Count > 0 && threads.All(thread => thread != uiThread) && finalizing);
            Require(heartbeat.Ticks >= 10 && heartbeat.MaximumGap < TimeSpan.FromSeconds(1));
            Console.WriteLine($"Scan heartbeat: {heartbeat.Ticks} input ticks, max gap {heartbeat.MaximumGap.TotalMilliseconds:N0} ms.");
        });

        test("cancellation interrupts an in-progress root scan without blocking input", () =>
        {
            using var cancellation = new CancellationTokenSource();
            using var entered = new ManualResetEventSlim();
            var cancelled = false;
            var heartbeat = new Heartbeat();
            heartbeat.Run(async () =>
            {
                var task = new ScanService().ScanAsync(root, new CallbackProgress<ScanProgress>(_ =>
                {
                    entered.Set();
                    cancellation.Token.WaitHandle.WaitOne();
                    cancellation.Token.ThrowIfCancellationRequested();
                }), cancellation.Token);
                Require(await Task.Run(() => entered.Wait(TimeSpan.FromSeconds(10))));
                await Task.Delay(250);
                cancellation.Cancel();
                try { await task; }
                catch (OperationCanceledException) { cancelled = true; }
            });
            Require(cancelled && heartbeat.Ticks >= 3 && heartbeat.MaximumGap < TimeSpan.FromSeconds(1));
            Require(File.Exists(Path.Combine(root, "item-00000.bin")));
        });

        test("large grouped results publish once per list and finish without a UI hang", () =>
        {
            var entries = Enumerable.Range(0, 7_000).Select(i => new ScanEntry(Path.Combine(root, $"result-{i:D5}.bin"), $"result-{i:D5}.bin", 10_000_000 - i, false, DateTime.Now, (StorageCategory)(i / 500))).ToArray();
            var result = new ScanResult
            {
                Root = root, FilesScanned = 2_000_000, DirectoriesScanned = 200_000, AccessErrors = 131,
                IdentifiedBytes = 900_000_000_000, DirectorySizes = new Dictionary<string, long>(),
                LargestFiles = entries.Take(2_000).ToArray(),
                Categories = Enum.GetValues<StorageCategory>().Select(category => new CategoryResult(category, 10_000_000, 140_000)).ToArray(),
                CategoryFiles = entries.GroupBy(item => item.Category).ToDictionary(group => group.Key, group => (IReadOnlyList<ScanEntry>)group.ToArray()),
                CleanupCandidates = Enumerable.Range(0, 10_000).Select(i => new CleanupCandidate(Path.Combine(root, $"cache-{i:D5}.tmp"), "Disposable display fixture", 10_000_000 - i, false, "Group " + i % 4)).ToArray()
            };
            var window = new MainWindow { IsPreviewMode = true, ShowActivated = false, ShowInTaskbar = false, WindowStartupLocation = WindowStartupLocation.Manual, Left = -20_000, Top = -20_000 };
            try
            {
                window.Show();
                var tabs = (TabControl)window.FindName("MainTabs"); tabs.SelectedIndex = 3;
                var grids = new[] { "LargestFilesGrid", "CategoryFilesGrid", "CleanupGrid" }.Select(name => (DataGrid)window.FindName(name)).ToArray();
                var notifications = new List<NotifyCollectionChangedAction>();
                foreach (var grid in grids) ((INotifyCollectionChanged)grid.ItemsSource).CollectionChanged += (_, change) => notifications.Add(change.Action);
                typeof(MainWindow).GetField("_result", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(window, result);
                var heartbeat = new Heartbeat();
                var elapsed = Stopwatch.StartNew();
                heartbeat.Run(async () =>
                {
                    typeof(MainWindow).GetMethod("PopulateResult", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, [result]);
                    await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                    tabs.SelectedIndex = 2;
                    await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                });
                elapsed.Stop();
                Require(notifications.Count == 3 && notifications.All(action => action == NotifyCollectionChangedAction.Reset));
                Require(grids[0].Items.Count == 2_000 && grids[1].Items.Count == 7_000 && grids[2].Items.Count == 10_000);
                Require(grids[1].Items.OfType<ScanEntry>().First().Size == entries[0].Size);
                Require(heartbeat.MaximumGap < TimeSpan.FromSeconds(2.5));
                Console.WriteLine($"Large-result display: {elapsed.ElapsedMilliseconds} ms; max dispatcher gap {heartbeat.MaximumGap.TotalMilliseconds:N0} ms; {notifications.Count} list notifications.");
            }
            finally { window.Close(); }
        });
    }

    internal static void AuditVolume(Action<string, Action> test)
    {
        test("read-only real volume scan remains responsive and accepts cancellation", () =>
        {
            var volume = Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))!;
            using var cancellation = new CancellationTokenSource();
            var heartbeat = new Heartbeat();
            ScanProgress? last = null;
            var watch = Stopwatch.StartNew(); var reportedAt = TimeSpan.Zero;
            var completed = false; var cancellationLatency = TimeSpan.Zero;
            heartbeat.Run(async () =>
            {
                var scan = new ScanService().ScanAsync(volume, new CallbackProgress<ScanProgress>(value =>
                {
                    last = value;
                    if (watch.Elapsed - reportedAt >= TimeSpan.FromSeconds(10))
                    {
                        reportedAt = watch.Elapsed;
                        Console.WriteLine($"Real scan: {value.Files:N0} files, {value.Directories:N0} directories, {value.Bytes:N0} bytes.");
                    }
                }), cancellation.Token);
                if (await Task.WhenAny(scan, Task.Delay(TimeSpan.FromSeconds(45))) != scan)
                {
                    var cancelledAt = Stopwatch.StartNew(); cancellation.Cancel();
                    try { await scan; } catch (OperationCanceledException) { }
                    cancellationLatency = cancelledAt.Elapsed;
                }
                else { await scan; completed = true; }
            });
            Require(last is { Files: > 0 } && heartbeat.Ticks > 10 && heartbeat.MaximumGap < TimeSpan.FromSeconds(1));
            Require(completed || cancellationLatency < TimeSpan.FromSeconds(2));
            Console.WriteLine($"Real volume: complete={completed}, files={last!.Files}, max input gap={heartbeat.MaximumGap.TotalMilliseconds:N0} ms, cancellation={cancellationLatency.TotalMilliseconds:N0} ms.");
        });
    }

    private sealed class CallbackProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }

    private sealed class Heartbeat
    {
        public int Ticks { get; private set; }
        public TimeSpan MaximumGap { get; private set; }
        public void Run(Func<Task> action)
        {
            var watch = Stopwatch.StartNew(); var last = TimeSpan.Zero;
            void Tick() { var now = watch.Elapsed; var gap = now - last; if (gap > MaximumGap) MaximumGap = gap; last = now; Ticks++; }
            var timer = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(20) };
            timer.Tick += (_, _) => Tick(); timer.Start();
            var frame = new DispatcherFrame(); Exception? failure = null;
            Dispatcher.CurrentDispatcher.BeginInvoke(new Action(async () =>
            {
                try { await action(); } catch (Exception error) { failure = error; }
                finally { frame.Continue = false; }
            }));
            try { Dispatcher.PushFrame(frame); Tick(); }
            finally { timer.Stop(); }
            if (failure is not null) throw failure;
        }
    }
    private static void Require(bool value) { if (!value) throw new InvalidOperationException("Scan responsiveness regression."); }
}
