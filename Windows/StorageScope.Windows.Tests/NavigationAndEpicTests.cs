using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using StorageScope.Windows;
using Microsoft.Win32;

internal static class NavigationAndEpicTests
{
    internal static void Run(MainWindow window, string root, Action<string, Action> test)
    {
        var previous = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(window.Dispatcher));
        var flags = BindingFlags.Instance | BindingFlags.NonPublic;
        object? Get(string name) => typeof(MainWindow).GetField(name, flags)!.GetValue(window);
        void Set(string name, object? value) => typeof(MainWindow).GetField(name, flags)!.SetValue(window, value);
        object? Invoke(string name, params object[] arguments) => typeof(MainWindow).GetMethod(name, flags)!.Invoke(window, arguments);
        void Pump(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done()) { Require(DateTime.UtcNow < deadline); window.Dispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle); Thread.Sleep(2); }
            window.UpdateLayout();
        }
        void Browse(string path) { var task = (Task)Invoke("BrowseAsync", path, true)!; Pump(() => task.IsCompleted); task.GetAwaiter().GetResult(); }
        void Click(string name) => ((Button)window.FindName(name)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var directory = Path.Combine(root, "navigation-342");
        var child = Path.Combine(directory, "Child"); var grandchild = Path.Combine(child, "Grandchild");
        Directory.CreateDirectory(grandchild); File.WriteAllText(Path.Combine(child, "file.txt"), "navigation fixture");
        var sibling = Path.Combine(directory, "Sibling"); Directory.CreateDirectory(sibling);
        var sizes = new Dictionary<string, long> { [directory] = 4096, [child] = 3072, [grandchild] = 2048, [sibling] = 1024 };
        var result = new ScanResult { Root = directory, DirectorySizes = sizes, LargestFiles = [], Categories = [], CleanupCandidates = [], IdentifiedBytes = 4096, FilesScanned = 1, DirectoriesScanned = 4, AccessErrors = 0 };
        var oldResult = Get("_result"); var oldIndex = Get("_folderIndex");
        var tabs = (TabControl)window.FindName("MainTabs"); var grid = (DataGrid)window.FindName("ExplorerGrid");
        try
        {
            Set("_result", result); Set("_folderIndex", new FolderIndex(result)); tabs.SelectedItem = window.FindName("ExplorerTab");
            test("folder bubble click retains combined mode, renders child and supports history", () => {
                Click("ExplorerCombinedButton"); Browse(directory);
                var button = ((Canvas)window.FindName("BubbleCanvas")).Children.OfType<BubbleButton>().Single(item => item.Circle.Path == child);
                button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Require(((Grid)window.FindName("BubblePanel")).Visibility == Visibility.Visible);
                Require(((TextBlock)window.FindName("BubbleStatus")).Text.Contains("Ouverture") || (string?)Get("_currentDirectory") == child);
                Pump(() => Get("_browseCancellation") is null);
                Require((string?)Get("_currentDirectory") == child && (bool)Get("_bubbleMode")!);
                Require(((Canvas)window.FindName("BubbleCanvas")).Children.OfType<BubbleButton>().Any(item => item.Circle.Path == grandchild));
                Invoke("ExplorerBack_Click", window, new RoutedEventArgs()); Pump(() => Get("_browseCancellation") is null);
                Require((string?)Get("_currentDirectory") == directory && (bool)Get("_bubbleMode")!);
                Invoke("ExplorerForward_Click", window, new RoutedEventArgs()); Pump(() => Get("_browseCancellation") is null);
                Require((string?)Get("_currentDirectory") == child && (bool)Get("_bubbleMode")!);
                Invoke("ParentButton_Click", window, new RoutedEventArgs()); Pump(() => Get("_browseCancellation") is null);
                Require((string?)Get("_currentDirectory") == directory);
            });
            test("list double click and temporary lists preserve the preferred explorer mode", () => {
                Click("DirectFilesButton"); Require((bool)Get("_bubbleMode")! && ((Grid)window.FindName("BubblePanel")).Visibility == Visibility.Collapsed);
                Browse(directory); Require(((Grid)window.FindName("BubblePanel")).Visibility == Visibility.Visible);
                Set("_folderFrame", new FolderFrame([new FolderCircle(directory, "Autres éléments", 1024, 0, 0, .8, 0, Aggregate: true, SkipCount: 1)], 4096, 0, false));
                Invoke("RenderBubbles"); ((Canvas)window.FindName("BubbleCanvas")).Children.OfType<BubbleButton>().Single().RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Require((bool)Get("_bubbleMode")! && grid.Items.Count == 1);
                Require(grid.Items.OfType<ScanEntry>().Single().Path == sibling);
                grid.SelectedItem = grid.Items[0]; grid.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = Control.MouseDoubleClickEvent });
                Pump(() => Get("_browseCancellation") is null);
                Require((string?)Get("_currentDirectory") == sibling && ((Grid)window.FindName("BubblePanel")).Visibility == Visibility.Visible);
                Click("ExplorerListButton"); Browse(directory);
                grid.SelectedItem = grid.Items.OfType<ScanEntry>().First(entry => entry.Path == child);
                grid.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = Control.MouseDoubleClickEvent });
                Pump(() => Get("_browseCancellation") is null);
                Require(!(bool)Get("_bubbleMode")! && ((Grid)window.FindName("BubblePanel")).Visibility == Visibility.Collapsed);
            });
            test("rapid navigation, unknown sizes and inaccessible folders never switch the mode", () => {
                Click("ExplorerCombinedButton");
                var first = (Task)Invoke("BrowseAsync", child, true)!;
                var last = (Task)Invoke("BrowseAsync", sibling, true)!;
                Pump(() => first.IsCompleted && last.IsCompleted); first.GetAwaiter().GetResult(); last.GetAwaiter().GetResult();
                Require((string?)Get("_currentDirectory") == sibling && (bool)Get("_bubbleMode")!);
                // Without an index, directory sizes remain unknown. An empty
                // bubble frame is allowed but its explanatory text is shown.
                Set("_result", null); Set("_folderIndex", null); Invoke("InvalidateExplorerCache"); Browse(directory);
                Require(((TextBlock)window.FindName("BubbleStatus")).Text.Contains("Tailles inconnues"));
                Require(((Grid)window.FindName("BubblePanel")).Visibility == Visibility.Visible);
                Browse(Path.Combine(directory, "Missing"));
                Require(((TextBlock)window.FindName("BubbleEmptyState")).Text.Contains("pas pu être lu"));
                Require((bool)Get("_bubbleMode")! && ((Grid)window.FindName("BubblePanel")).Visibility == Visibility.Visible);
            });
            test("scan completion refreshes the latest folder instead of the scan starting location", () => {
                Set("_result", result); Set("_folderIndex", new FolderIndex(result));
                Browse(directory); Browse(child); Browse(grandchild);
                var completion = (Task)Invoke("RefreshExplorerAfterScanAsync", directory)!;
                Pump(() => completion.IsCompleted); completion.GetAwaiter().GetResult();
                Require((string?)Get("_currentDirectory") == grandchild && (bool)Get("_bubbleMode")!);
            });
        }
        finally { Set("_result", oldResult); Set("_folderIndex", oldIndex); Click("ExplorerCombinedButton"); tabs.SelectedItem = window.FindName("OverviewTab"); SynchronizationContext.SetSynchronizationContext(previous); }
        EpicTests(root, test);
    }

    private static void EpicTests(string root, Action<string, Action> test)
    {
        var manifests = Path.Combine(root, "epic-manifests"); var gameRoot = Path.Combine(root, "epic-game");
        Directory.CreateDirectory(manifests); Directory.CreateDirectory(gameRoot);
        var file = Path.Combine(manifests, "game.item");
        var launcher = Path.Combine(root, "epic-launcher-fixture.exe"); File.WriteAllText(launcher, "fixture: never executed");
        void WriteManifest(string target = "game.item", string id = "fixture") => File.WriteAllText(Path.Combine(manifests, target), JsonSerializer.Serialize(new { AppName = id, DisplayName = "Fixture game", CatalogNamespace = "namespace", CatalogItemId = "catalog-id", InstallLocation = gameRoot, InstallSize = 4096, bIsApplication = true, LaunchExecutable = "game.exe" }));
        EpicProductProvider Provider(Action<string>? launch = null, Func<string?>? resolve = null, Func<CancellationToken, Task>? wait = null) => new(manifests, resolve ?? (() => launcher), launch ?? (_ => { }), wait ?? (_ => Task.CompletedTask));
        InstalledApplication Game(EpicProductProvider provider) => provider.DetectAsync(default).GetAwaiter().GetResult().Single();
        test("Epic manifests retain trusted identity and route to their own provider", () => {
            WriteManifest(); var game = Game(Provider());
            Require(game.ManifestPath == file && game.ManifestSnapshot is not null && game.EpicNamespace == "namespace" && game.EpicCatalogId == "catalog-id");
            Require(new InstalledProductCatalog().ProviderFor(game) is EpicProductProvider);
            var registration = game with { ManifestPath = null, ManifestSnapshot = null, ProductId = "registry-key", RegistrationPath = "CurrentUser|Registry64|fixture", UninstallCommand = "\"" + launcher + "\" /uninstall", Provider = "Application" };
            var launcherProduct = new InstalledApplication("Epic Games Launcher", "Epic", "1", Path.Combine(root, "launcher"), "launcher-uninstall.exe", "Epic");
            var merged = InstalledProductCatalog.Merge([game, registration, launcherProduct]);
            var product = merged.Single(item => item.ManifestPath is not null);
            Require(merged.Count == 2 && product.ProductId == game.ProductId && product.RegistrationPath == registration.RegistrationPath && product.UninstallCommand == registration.UninstallCommand);
            Require(Provider().Prepare(product) is { CanProceed: true, EpicGuided: false });
        });
        test("Epic guided uninstall opens only the launcher and never claims success on launch", () => {
            WriteManifest(); var launches = 0; var provider = Provider(_ => launches++); var game = Game(provider); var plan = provider.Prepare(game);
            Require(plan.CanProceed && plan.EpicGuided && plan.Arguments is null);
            var outcome = provider.ExecuteAsync(plan, default).GetAwaiter().GetResult();
            Require(launches == 1 && !outcome.Verified && File.Exists(file) && Directory.Exists(gameRoot));
            var unavailable = Provider(resolve: () => null).Prepare(game);
            Require(!unavailable.CanProceed && unavailable.Explanation.Contains("absent"));
        });
        test("Epic multiple libraries stay distinct and launcher components never merge into games", () => {
            WriteManifest(); var provider = Provider(); var game = Game(provider);
            var otherRoot = Path.Combine(root, "another-library", "Epic Fixture"); Directory.CreateDirectory(otherRoot);
            var otherManifest = Path.Combine(manifests, "other.item");
            File.WriteAllText(otherManifest, JsonSerializer.Serialize(new { AppName = "other-game", DisplayName = "Other game", CatalogNamespace = "namespace", CatalogItemId = "other-catalog", InstallLocation = otherRoot, bIsApplication = true }));
            try
            {
                var detected = provider.DetectAsync(default).GetAwaiter().GetResult(); Require(detected.Count == 2);
                var component = new InstalledApplication("Epic Games Launcher", "Epic", "1", game.InstallLocation, "\"" + launcher + "\" /uninstall", "Epic", game.ProductId, "CurrentUser|Registry64|launcher");
                var merged = InstalledProductCatalog.Merge([.. detected, component]);
                Require(merged.Count == 3 && merged.Single(item => item.ProductId == game.ProductId && item.ManifestPath is not null).UninstallCommand is null);
            }
            finally { File.Delete(otherManifest); }
        });
        test("Epic verification detects completion, renamed manifests and reinstallation", () => {
            WriteManifest(); var provider = Provider(); var game = Game(provider);
            File.Move(file, Path.Combine(manifests, "renamed.item"));
            Require(!provider.VerifyAsync(game, default).GetAwaiter().GetResult());
            File.Delete(Path.Combine(manifests, "renamed.item"));
            Require(provider.VerifyAsync(game, default).GetAwaiter().GetResult());
            WriteManifest(); Require(!provider.VerifyAsync(game, default).GetAwaiter().GetResult());
            Require(!provider.Prepare(game).CanProceed);
        });
        test("Epic replaced manifests and launchers are rejected before launch", () => {
            WriteManifest(); var launches = 0; var provider = Provider(_ => launches++); var game = Game(provider); var plan = provider.Prepare(game);
            WriteManifest(id: "different-game"); Require(!provider.Prepare(game).CanProceed);
            try { provider.ExecuteAsync(plan, default).GetAwaiter().GetResult(); throw new InvalidOperationException("Changed manifest accepted"); } catch (IOException) { }
            WriteManifest(); game = Game(provider); plan = provider.Prepare(game);
            File.AppendAllText(launcher, " changed");
            try { provider.ExecuteAsync(plan, default).GetAwaiter().GetResult(); throw new InvalidOperationException("Changed launcher accepted"); } catch (IOException) { }
            Require(launches == 0);
        });
        test("Epic cancellation stops only monitoring and completed removal is verified", () => {
            WriteManifest(); using var cancellation = new CancellationTokenSource();
            var provider = Provider(wait: token => { cancellation.Cancel(); return Task.FromCanceled(cancellation.Token); }); var game = Game(provider);
            var cancelled = provider.ExecuteAsync(provider.Prepare(game), cancellation.Token).GetAwaiter().GetResult();
            Require(!cancelled.Verified && cancelled.State == "suivi annulé" && File.Exists(file));
            using var completedCancellation = new CancellationTokenSource();
            provider = Provider(wait: token => { File.Delete(file); completedCancellation.Cancel(); return Task.FromCanceled(completedCancellation.Token); });
            game = Game(provider);
            var completed = provider.ExecuteAsync(provider.Prepare(game), completedCancellation.Token).GetAwaiter().GetResult();
            Require(completed.Verified && completed.State == "confirmée");
            WriteManifest();
            provider = Provider(_ => File.Delete(file)); game = Game(provider);
            Require(provider.ExecuteAsync(provider.Prepare(game), default).GetAwaiter().GetResult().Verified);
            Require(Directory.Exists(gameRoot));
        });
        if (Environment.GetEnvironmentVariable("CI") == "true") test("isolated Epic official executable removes its own registration and is verified", () => {
            WriteManifest();
            var keyName = "StorageScope-Epic-Fixture-" + Guid.NewGuid().ToString("N");
            var keyPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + keyName;
            try
            {
                var command = "\"" + Environment.ProcessPath + "\" --epic-uninstall-fixture \"" + file + "\" \"" + keyName + "\"";
                using (var key = Registry.CurrentUser.CreateSubKey(keyPath)) { key.SetValue("DisplayName", "StorageScope disposable game fixture"); key.SetValue("UninstallString", command); key.SetValue("InstallLocation", gameRoot); }
                var provider = new EpicProductProvider(manifests, () => launcher, _ => throw new InvalidOperationException("Guided launcher must not open"), token => Task.Delay(20, token), 150);
                var game = Game(provider) with { RegistrationPath = "CurrentUser|Registry64|" + keyName, UninstallCommand = command };
                var plan = provider.Prepare(game); Require(plan.CanProceed && !plan.EpicGuided);
                var outcome = provider.ExecuteAsync(plan, default).GetAwaiter().GetResult();
                Require(outcome.Verified && !File.Exists(file) && Directory.Exists(gameRoot));
            }
            finally { Registry.CurrentUser.DeleteSubKeyTree(keyPath, throwOnMissingSubKey: false); }
        });
    }
    internal static int RunOfficialFixture(string[] args)
    {
        var index = Array.IndexOf(args, "--epic-uninstall-fixture");
        if (Environment.GetEnvironmentVariable("CI") != "true" || index < 0 || args.Length != index + 3) return 64;
        var manifest = Path.GetFullPath(args[index + 1]); var keyName = args[index + 2];
        if (!DeletionSafetyPolicy.IsWithin(manifest, Path.Combine(Environment.CurrentDirectory, ".test-data")) || Path.GetExtension(manifest) != ".item" || !keyName.StartsWith("StorageScope-Epic-Fixture-", StringComparison.Ordinal) || !Guid.TryParseExact(keyName[26..], "N", out _)) return 65;
        File.Delete(manifest);
        Registry.CurrentUser.DeleteSubKeyTree(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + keyName, throwOnMissingSubKey: false);
        Thread.Sleep(1000); // The monitor must not wait for a persistent launcher to exit.
        return 0;
    }
    private static void Require(bool condition) { if (!condition) throw new InvalidOperationException("Navigation/Epic regression"); }
}
