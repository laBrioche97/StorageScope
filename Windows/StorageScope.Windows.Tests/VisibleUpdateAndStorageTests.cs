using System.IO;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using StorageScope.Windows;

internal static class VisibleUpdateAndStorageTests
{
    internal static void Network(string root, Action<string, Action> test)
    {
        using var key = RSA.Create(3072);
        var manifest = new UpdateManifest(2, "9.9.9", 19041, "Fixture notes", "https://github.com/laBrioche97/StorageScope/releases/download/v9.9.9/StorageScope-Windows-Setup-DEVELOPMENT.exe", new string('a', 64), 8, "universal");
        var payload = JsonSerializer.SerializeToUtf8Bytes(manifest);
        var signature = key.SignData(payload, HashAlgorithmName.SHA256, RSASignaturePadding.Pss);
        var release = JsonSerializer.SerializeToUtf8Bytes(new { draft = false, prerelease = false, tag_name = "v9.9.9", assets = new[] {
            new { name = "windows-update.json", browser_download_url = "https://github.com/laBrioche97/StorageScope/releases/download/v9.9.9/windows-update.json" },
            new { name = "windows-update.json.sig", browser_download_url = "https://github.com/laBrioche97/StorageScope/releases/download/v9.9.9/windows-update.json.sig" } } });
        var state = Path.Combine(root, "updates-343", "state"); var releaseCalls = 0; var conditional = false; var offline = false; var invalid = false;
        using var client = new HttpClient(new Handler(request => {
            if (offline) throw new HttpRequestException("fixture offline");
            if (request.RequestUri!.Host == "api.github.com") {
                releaseCalls++; conditional = request.Headers.IfNoneMatch.Any(tag => tag.Tag == "\"fixture\"");
                var response = new HttpResponseMessage(conditional ? HttpStatusCode.NotModified : HttpStatusCode.OK) { Content = new ByteArrayContent(release) };
                response.Headers.ETag = new("\"fixture\""); return response;
            }
            return new(HttpStatusCode.OK) { Content = new ByteArrayContent(request.RequestUri.AbsolutePath.EndsWith(".sig") ? invalid ? new byte[384] : signature : payload) };
        }));
        UpdateService Service() => new(client, state, key.ExportSubjectPublicKeyInfoPem());
        T Await<T>(Task<T> task) => task.GetAwaiter().GetResult();
        test("each launch checks releases again using conditional HTTP and a verified offer", () => {
            var first = Service(); Require(Await(first.CheckAsync(false, default))?.Version == "9.9.9");
            var next = Service(); Require(Await(next.CheckAsync(false, default))?.Version == "9.9.9" && releaseCalls == 2 && conditional);
        });
        test("offline launch restores signed offer but installation requires fresh metadata", () => {
            offline = true; var service = Service(); var offer = Await(service.CheckAsync(false, default));
            Require(offer is not null && service.IsOffline && service.UsingCachedOffer && service.LastVerified is not null);
            try { Await(service.RevalidateAsync(offer!, default)); throw new InvalidOperationException("Offline installation accepted"); } catch (HttpRequestException) { }
            offline = false; Require(Await(service.CheckAsync(false, default)) is not null && !service.IsOffline);
        });
        test("invalid metadata signature is refused and does not become an offline success", () => {
            invalid = true; try { Await(Service().CheckAsync(false, default)); throw new InvalidOperationException("Signature accepted"); } catch (CryptographicException) { }
            invalid = false;
        });
        test("tampered persisted offer is reverified and ignored offline", () => {
            var cachedPath = state + ".offer.json";
            File.WriteAllBytes(cachedPath, JsonSerializer.SerializeToUtf8Bytes(new { Payload = payload, Signature = new byte[384], Verified = DateTimeOffset.UtcNow }));
            offline = true; var service = Service(); Require(Await(service.CheckAsync(false, default)) is null && !service.UsingCachedOffer);
            offline = false;
        });
        test("cancellation does not silently restore a cached offer", () => {
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            try { Await(Service().CheckAsync(false, cancelled.Token)); throw new InvalidOperationException("Cancellation ignored"); } catch (OperationCanceledException) { }
        });
    }

    internal static void Interface(string root, string? destination, Action<string, Action> test)
    {
        var previous = SynchronizationContext.Current;
        var window = new MainWindow { IsPreviewMode = true, ShowInTaskbar = false, ShowActivated = false, Left = -20000, Top = -20000 };
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(window.Dispatcher));
        var flags = BindingFlags.NonPublic | BindingFlags.Instance;
        Task Invoke(string name, params object[] args) => (Task)typeof(MainWindow).GetMethod(name, flags)!.Invoke(window, args)!;
        object? Get(string name) => typeof(MainWindow).GetField(name, flags)!.GetValue(window);
        void Pump(Task task) {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!task.IsCompleted) { Require(DateTime.UtcNow < deadline); window.Dispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle); Thread.Sleep(2); }
            task.GetAwaiter().GetResult(); window.UpdateLayout();
        }
        var a = Path.Combine(root, "drive-a"); var b = Path.Combine(root, "drive-b"); Directory.CreateDirectory(Path.Combine(a, "Child")); Directory.CreateDirectory(b);
        var first = new DriveChoice(a, "fixture-a", "Disque A", 100000, 50000);
        var second = new DriveChoice(b, "fixture-b", "Disque B", null, null);
        IReadOnlyList<DriveChoice> drives = [first, second]; window.StorageReader = () => drives;
        var tabs = (TabControl)window.FindName("MainTabs"); var chooser = (Border)window.FindName("StorageChooser");
        window.Show(); tabs.SelectedItem = window.FindName("ExplorerTab");
        try {
            test("multi-storage entry presents accessible cards with unknown capacity explicitly", () => {
                Pump(Invoke("EnterExplorerAsync")); Require(chooser.Visibility == Visibility.Visible && second.CapacityLabel.Contains("indisponible"));
                Require(((ItemsControl)window.FindName("StorageChoices")).Items.Count == 2);
                Capture(window, destination, "windows-storage-choice.png");
            });
            test("choosing the already selected storage reopens its exact root and resets filters but keeps mode", () => {
                Pump(Invoke("OpenStorageRootAsync", first)); Pump(Invoke("BrowseAsync", Path.Combine(a, "Child"), true));
                ((TextBox)window.FindName("ListSearch")).Text = "hidden";
                Pump(Invoke("OpenStorageRootAsync", first)); Require((string?)Get("_currentDirectory") == a);
                Require(((TextBox)window.FindName("ListSearch")).Text == "" && (bool)Get("_bubbleMode")!);
                Require(((List<string>)Get("_browseHistory")!).Count == 1 && chooser.Visibility == Visibility.Collapsed);
            });
            test("re-entering explorer shows volumes again and one volume opens directly", () => {
                Pump(Invoke("EnterExplorerAsync")); Require(chooser.Visibility == Visibility.Visible);
                drives = [second]; Pump(Invoke("RefreshDrivesAsync"));
                Pump(Invoke("EnterExplorerAsync")); Require((string?)Get("_currentDirectory") == b && chooser.Visibility == Visibility.Collapsed);
            });
            test("disconnected active storage and zero-volume inventory return to chooser", () => {
                drives = []; Pump(Invoke("RefreshDrivesAsync")); Require(chooser.Visibility == Visibility.Visible && (string?)Get("_storageIdentity") is null);
                Pump(Invoke("EnterExplorerAsync")); Require(((ItemsControl)window.FindName("StorageChoices")).Items.Count == 0);
            });
            test("rapid storage selection rejects obsolete directory results", () => {
                drives = [first, second]; Pump(Invoke("RefreshDrivesAsync"));
                var slow = Invoke("OpenStorageRootAsync", first); var latest = Invoke("OpenStorageRootAsync", second);
                Pump(Task.WhenAll(slow, latest)); Require((string?)Get("_currentDirectory") == b && (string?)Get("_storageIdentity") == second.Identity);
            });
            test("permanent update icon explains installation lock during analysis", () => {
                var offer = new UpdateManifest(2, "9.9.9", 19041, "", "", "", 1, "universal");
                typeof(MainWindow).GetField("_availableUpdate", flags)!.SetValue(window, offer);
                typeof(MainWindow).GetMethod("SetScanning", flags)!.Invoke(window, [true]);
                var icon = (Button)window.FindName("UpdateStatusButton"); Require(!icon.IsEnabled && AutomationProperties.GetName(icon).Contains("après l’analyse"));
                typeof(MainWindow).GetMethod("SetScanning", flags)!.Invoke(window, [false]); Require(icon.IsEnabled && AutomationProperties.GetName(icon).Contains("9.9.9"));
            });
            test("offline Epic guide shows both real-image presentations without launching or deleting", () => {
                var guide = new EpicGuideWindow("Jeu de démonstration") { ShowInTaskbar = false, ShowActivated = false, Left = -20000, Top = -20000, Width = 740, Height = 560 };
                guide.Show(); guide.UpdateLayout(); Capture(guide, destination, "windows-epic-guide-classic.png");
                var picker = Descendants(guide).OfType<ComboBox>().Single(); picker.SelectedIndex = 1; guide.UpdateLayout();
                Require(Descendants(guide).OfType<Image>().Count() >= 3); Capture(guide, destination, "windows-epic-guide-new.png"); guide.Close();
            });
        } finally { window.Close(); SynchronizationContext.SetSynchronizationContext(previous); }
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject item) { for (var i = 0; i < VisualTreeHelper.GetChildrenCount(item); i++) { var child = VisualTreeHelper.GetChild(item, i); yield return child; foreach (var nested in Descendants(child)) yield return nested; } }
    private static void Capture(Window window, string? destination, string name) {
        if (destination is null) return; Directory.CreateDirectory(destination); window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32); bitmap.Render(window);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var output = File.Create(Path.Combine(destination, name)); encoder.Save(output);
    }
    private static void Require(bool value) { if (!value) throw new InvalidOperationException("3.4.3 update/storage/guide regression"); }
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) { cancellationToken.ThrowIfCancellationRequested(); return Task.FromResult(respond(request)); }
    }
}
