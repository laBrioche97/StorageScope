using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Windows.Data;
using StorageScope.Windows;

internal static class Program
{
    private static int _passed;
    private static string _root = "";
    [STAThread]
    private static int Main(string[] args)
    {
        _root = Path.Combine(Environment.CurrentDirectory, ".test-data", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
        try
        {
            Test("protected system and profile roots", () =>
            {
                Check(DeletionSafetyPolicy.BlockReason(Path.GetPathRoot(_root)!) is not null);
                Check(DeletionSafetyPolicy.BlockReason(DeletionSafetyPolicy.Home) is not null);
                Check(DeletionSafetyPolicy.BlockReason(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)) is not null);
                Check(DeletionSafetyPolicy.BlockReason(Path.Combine(_root, "steamapps", "common", "game")) is not null);
            });
            Test("browser cache rules exclude passwords bookmarks and arbitrary folders", () =>
            {
                var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                Check(DeletionSafetyPolicy.CacheKind(Path.Combine(local,@"Google\Chrome\User Data\Default\Cache\Cache_Data\payload")) == "browser");
                Check(DeletionSafetyPolicy.CacheKind(Path.Combine(local,@"Microsoft\Edge\User Data\Profile 1\Code Cache\js\payload")) == "browser");
                Check(DeletionSafetyPolicy.CacheKind(Path.Combine(local,@"Google\Chrome\User Data\Default\Login Data")) is null);
                Check(DeletionSafetyPolicy.CacheKind(Path.Combine(local,@"Google\Chrome\User Data\Default\Bookmarks")) is null);
                Check(DeletionSafetyPolicy.CacheKind(Path.Combine(local,@"Arbitrary\Cache\payload")) is null);
            });
            Test("cloud locations excluded", () =>
            {
                var previous = Environment.GetEnvironmentVariable("OneDrive");
                try { Environment.SetEnvironmentVariable("OneDrive", _root); Check(DeletionSafetyPolicy.BlockReason(Path.Combine(_root, "document")) is not null); }
                finally { Environment.SetEnvironmentVariable("OneDrive", previous); }
            });
            Test("game residue authorization stays scoped and expires on reinstall", () =>
            {
                var apps = Path.Combine(_root,"steamapps"); var cache = Path.Combine(apps,"shadercache","123");
                Directory.CreateDirectory(cache);
                var manifest = Path.Combine(apps,"appmanifest_123.acf"); File.WriteAllText(manifest,"registered");
                var authorization = new GameCacheAuthorization(apps,"123",DeletionSafetyPolicy.ReadIdentity(manifest));
                Check(!authorization.Allows(cache));
                File.Delete(manifest);
                Check(authorization.Allows(cache));
                Check(DeletionSafetyPolicy.BlockReason(cache, gameCache:authorization) is null);
                Check(!authorization.Allows(Path.Combine(apps,"common","123")));
                Check(!authorization.Allows(Path.Combine(apps,"shadercache","123-other")));
                File.WriteAllText(manifest,"reinstalled");
                Check(DeletionSafetyPolicy.BlockReason(cache, gameCache:authorization) is not null);
            });
            Test("identity detects content changes and replacement", () =>
            {
                var path = Fixture("identity.bin", "before");
                var before = DeletionSafetyPolicy.Capture(path);
                File.WriteAllText(path, "after with different length");
                Throws(() => DeletionSafetyPolicy.Revalidate(path, before));
                File.Delete(path); File.WriteAllText(path, "before");
                Throws(() => DeletionSafetyPolicy.Revalidate(path, before));
            });
            Test("directory snapshot detects nested changes", () =>
            {
                var directory = Path.Combine(_root, "nested"); Directory.CreateDirectory(directory);
                File.WriteAllText(Path.Combine(directory, "item"), "before");
                var before = DeletionSafetyPolicy.Capture(directory);
                File.WriteAllText(Path.Combine(directory, "item"), "after longer");
                Throws(() => DeletionSafetyPolicy.Revalidate(directory, before));
            });
            Test("parent child selections counted once with path boundaries", () =>
            {
                var parent = Entry(Path.Combine(_root, "folder"), true);
                var child = Entry(Path.Combine(parent.Path, "child"));
                var adjacent = Entry(Path.Combine(_root, "folder-other"));
                Check(DeletionSafetyPolicy.Normalize([child, parent, adjacent, child]).Count == 2);
            });
            Test("hard links excluded from reclaimable counts", () =>
            {
                var original = Fixture("hard-original", "same"); var link = Path.Combine(_root, "hard-link");
                if (!CreateHardLink(link, original, IntPtr.Zero)) throw new IOException("Hard-link fixture could not be created.");
                Throws(() => DeletionSafetyPolicy.Capture(link));
            });
            Test("SHA256 confirms duplicates and keeps one", () =>
            {
                var directory = Path.Combine(_root, "duplicates"); Directory.CreateDirectory(directory);
                File.WriteAllText(Path.Combine(directory, "a"), "identical data"); File.WriteAllText(Path.Combine(directory, "b"), "identical data"); File.WriteAllText(Path.Combine(directory, "c"), "different data");
                var result = DuplicateAnalysis.AnalyzeAsync(directory, new Progress<string>(), CancellationToken.None).GetAwaiter().GetResult();
                Check(result.Count == 1 && result[0].DuplicateKeeper == Path.Combine(directory, "a") && !result[0].Recommended);
            });
            Test("partial failures report only successful bytes", () =>
            {
                var first = Fixture("operation-first", "abc"); var second = Fixture("operation-second", "def");
                var selection = new[] { Select(first), Select(second) };
                var result = CleanupOperations.ExecuteAsync(selection, new Progress<int>(), CancellationToken.None,
                    path => { if (path == second) throw new IOException("locked"); File.Move(path, path + ".recycled"); }, _ => { }).GetAwaiter().GetResult();
                Check(result.Count(item => item.Status == "corbeille") == 1 && result.Sum(item => item.Bytes) == 3 && File.Exists(second));
            });
            Test("a changed candidate does not block other verified files", () =>
            {
                var changed = Fixture("changed-candidate","before"); var ready = Fixture("ready-candidate","before");
                var candidates = new[] { new CleanupCandidate(changed,"fixture",6,false,Snapshot:DeletionSafetyPolicy.Capture(changed)),new CleanupCandidate(ready,"fixture",6,false,Snapshot:DeletionSafetyPolicy.Capture(ready)) };
                File.WriteAllText(changed,"changed with a different size");
                var preparation = CleanupOperations.Prepare([Entry(changed),Entry(ready)],candidates,CancellationToken.None);
                Check(preparation.Ready.Count == 1 && preparation.Ready[0].Entry.Path == ready && preparation.Skipped.Count == 1);
            });
            Test("changed keeper prevents duplicate deletion", () =>
            {
                var keeper = Fixture("keeper", "same"); var copy = Fixture("copy", "same");
                var selection = new CleanupSelection(Entry(copy), DeletionSafetyPolicy.Capture(copy), keeper, DeletionSafetyPolicy.Capture(keeper));
                File.WriteAllText(keeper, "changed");
                var called = false;
                var result = CleanupOperations.ExecuteAsync([selection], new Progress<int>(), CancellationToken.None, _ => called = true, _ => { }).GetAwaiter().GetResult();
                Check(!called && result[0].Status == "échec" && File.Exists(copy));
            });
            Test("journal failure prevents mutation", () =>
            {
                var path = Fixture("journal", "abc"); var called = false;
                var result = CleanupOperations.ExecuteAsync([Select(path)], new Progress<int>(), CancellationToken.None, _ => called = true, _ => throw new IOException("journal unavailable")).GetAwaiter().GetResult();
                Check(!called && result[0].Status == "échec");
            });
            Test("a journal failure after recycling does not report duplicate outcomes", () =>
            {
                var path = Fixture("journal-after","abc"); var recorded = 0;
                var result = CleanupOperations.ExecuteAsync([Select(path)],new Progress<int>(),CancellationToken.None,
                    item => File.Move(item,item+".recycled"), _ => { if (++recorded > 1) throw new IOException("journal full"); }).GetAwaiter().GetResult();
                Check(result.Count == 1 && result[0].Status == "corbeille" && result[0].Error is not null && !File.Exists(path));
            });
            Test("cancellation never invokes deletion", () =>
            {
                var called = false; var path = Fixture("cancelled", "abc");
                var result = CleanupOperations.ExecuteAsync([Select(path)], new Progress<int>(), new CancellationToken(true), _ => called = true, _ => { }).GetAwaiter().GetResult();
                Check(!called && result[0].Status == "annulé");
            });
            Test("uninstaller commands reject interpreters and relative paths", () =>
            {
                Throws(() => RegisteredProductProvider.ParseCommand("cmd.exe /c anything"));
                Throws(() => RegisteredProductProvider.ParseCommand("relative.exe /uninstall"));
                var product = new InstalledApplication("Game", null, null, _root, null, "Epic");
                Check(!new RegisteredProductProvider().Prepare(product).CanProceed);
                Check(!new RegisteredProductProvider().VerifyAsync(product, CancellationToken.None).GetAwaiter().GetResult());
            });
            Test("replaced uninstaller is rejected before execution", () =>
            {
                var executable = Fixture("fixture-uninstaller.exe","original fixture, never executed");
                var provider = new RegisteredProductProvider();
                var product = new InstalledApplication("Test fixture",null,null,_root,"\""+executable+"\" /uninstall");
                var plan = provider.Prepare(product);
                Check(plan.CanProceed && plan.UninstallerIdentity is not null);
                File.WriteAllText(executable,"modified fixture with a different length");
                try { provider.ExecuteAsync(plan,CancellationToken.None).GetAwaiter().GetResult(); throw new InvalidOperationException("Replacement accepted"); }
                catch (IOException error) { Check(error.Message.Contains("changé")); }
            });
            Test("signed manifests reject tampering replay and foreign packages", () =>
            {
                using var rsa = RSA.Create(3072);
                var manifest = new UpdateManifest(1, "3.1.0", 19041, "Release notes", "https://github.com/laBrioche97/StorageScope/releases/download/v3.1.0/StorageScope-Windows-Setup.exe", new string('a', 64), 12345, "universal");
                var bytes = JsonSerializer.SerializeToUtf8Bytes(manifest);
                var signature = rsa.SignData(bytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pss);
                Check(UpdateService.ValidateManifest(bytes, signature, rsa.ExportSubjectPublicKeyInfoPem(), "v3.1.0", new Version(3,0,0)).Version == "3.1.0");
                var changed = bytes.ToArray(); changed[changed.Length - 3] ^= 1;
                Throws(() => UpdateService.ValidateManifest(changed, signature, rsa.ExportSubjectPublicKeyInfoPem(), "v3.1.0", new Version(3,0,0)));
                Throws(() => UpdateService.ValidateManifest(bytes, signature, rsa.ExportSubjectPublicKeyInfoPem(), "v3.1.0", new Version(3,1,0)));
                foreach (var invalid in new[] { manifest with { DownloadUrl = "https://evil.example/setup.exe" }, manifest with { Architecture = "x86" }, manifest with { Size = 0 }, manifest with { Sha256 = "bad" }, manifest with { SchemaVersion = 9 } })
                {
                    var invalidBytes = JsonSerializer.SerializeToUtf8Bytes(invalid);
                    Throws(() => UpdateService.ValidateManifest(invalidBytes, rsa.SignData(invalidBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pss), rsa.ExportSubjectPublicKeyInfoPem(), "v3.1.0", new Version(3,0,0)));
                }
            });
            Test("unsigned executable cannot be trusted", () => Throws(() => Authenticode.Verify(Fixture("unsigned.exe", "not an executable"), "CN=La Brioche")));
            Test("offline window construction and responsive rendering", () => Render(args.FirstOrDefault()));
            Console.WriteLine($"PASS: {_passed} Windows safety, update and rendering scenarios.");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally
        {
            var expected = Path.GetFullPath(Path.Combine(Environment.CurrentDirectory, ".test-data")) + Path.DirectorySeparatorChar;
            if (Path.GetFullPath(_root).StartsWith(expected, StringComparison.OrdinalIgnoreCase)) Directory.Delete(_root, true);
        }
    }

    private static void Render(string? destination)
    {
        var app = new App(); app.InitializeComponent();
        var window = new MainWindow { IsPreviewMode = true, ShowActivated = false, ShowInTaskbar = false, WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = -20000 };
        var tab = (TabControl)window.FindName("MainTabs");
        var largest = (DataGrid)window.FindName("LargestFilesGrid");
        largest.ItemsSource = new[] { Entry(Path.Combine(_root, "Mes vidéos", "Vacances.mp4")) with { Size = 2_800_000_000 }, Entry(Path.Combine(_root, "Documents", "Projet personnel.zip")) with { Size = 650_000_000 } };
        var cleanup = (DataGrid)window.FindName("CleanupGrid");
        cleanup.ItemsSource = new[] { new CleanupCandidate(Path.Combine(_root,"cache.tmp"), "Temporaire reconnu", 120_000_000, false, "Caches et temporaires", "Peut être recréé", true), new CleanupCandidate(Path.Combine(_root,"photo.jpg"), "Fichier personnel", 200_000_000, false, "À examiner") };
        CollectionViewSource.GetDefaultView(cleanup.ItemsSource).GroupDescriptions.Add(new PropertyGroupDescription(nameof(CleanupCandidate.Group)));
        ((DataGrid)window.FindName("ApplicationsGrid")).ItemsSource = new[] { new InstalledApplication("Jeu Steam — exemple", "Steam", "1.0", "D:/Jeux/Steam", "steam://uninstall/123", "Steam"), new InstalledApplication("Jeu Epic — exemple", "Epic Games", "1.0", "D:/Jeux/Epic", null, "Epic"), new InstalledApplication("Application personnelle", "Éditeur", "2.0", "C:/Applications/Exemple", null) };
        var content = (Grid)window.Content;
        var drive = (ComboBox)window.FindName("DrivePicker");
        drive.ItemsSource = new[] { new DriveChoice(new DriveInfo(Path.GetPathRoot(_root)!)) }; drive.SelectedIndex = 0;
        window.Show();
        foreach (var (name, width, height, index, scale, dark, contrast) in new[] { ("windows-overview",1120,800,0,1d,true,false), ("windows-cleanup-small",740,700,3,1d,true,false), ("windows-minimum",740,560,3,1d,true,false), ("windows-cleanup-200",1120,800,3,2d,true,false), ("windows-games-light",1120,800,4,1d,false,false), ("windows-contrast",1120,800,0,1d,false,true) })
        {
            app.ApplyPalette(dark,contrast);
            content.Background = (Brush)app.Resources["PageBrush"];
            window.Width = width; window.Height = height;
            tab.SelectedIndex = index;
            window.UpdateLayout();
            window.Dispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);
            window.UpdateLayout();
            Check(((SolidColorBrush)window.Foreground).Color == ((SolidColorBrush)app.Resources["TextBrush"]).Color);
            Check(content.ActualWidth > 600 && content.ActualHeight > 400);
            if (index == 3)
            {
                Check(cleanup.ActualHeight >= 120);
                var clean = (Button)window.FindName("CleanButton");
                Check(clean.TransformToAncestor(content).Transform(new Point(0,clean.ActualHeight)).Y <= content.ActualHeight);
            }
            if (destination is null) continue;
            Directory.CreateDirectory(destination);
            var image = new RenderTargetBitmap((int)Math.Ceiling((content.ActualWidth+36)*scale), (int)Math.Ceiling((content.ActualHeight+36)*scale),96*scale,96*scale,PixelFormats.Pbgra32);
            var background = new DrawingVisual();
            using (var drawing = background.RenderOpen()) drawing.DrawRectangle((Brush)app.Resources["PageBrush"],null,new Rect(0,0,content.ActualWidth+36,content.ActualHeight+36));
            image.Render(background);
            image.Render(content);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
            using var file = File.Create(Path.Combine(destination,name + ".png")); encoder.Save(file);
        }
        window.Close();
        app.Shutdown();
    }
    private static string Fixture(string name, string content) { var path = Path.Combine(_root,name); File.WriteAllText(path,content); return path; }
    private static ScanEntry Entry(string path, bool directory=false) => new(path,Path.GetFileName(path),3,directory,DateTime.Now,StorageCategory.Other);
    private static CleanupSelection Select(string path) => new(Entry(path),DeletionSafetyPolicy.Capture(path));
    private static void Check(bool condition) { if (!condition) throw new InvalidOperationException("Assertion failed"); }
    private static void Throws(Action action) { try { action(); } catch { return; } throw new InvalidOperationException("Expected operation to be rejected"); }
    private static void Test(string name, Action test) { test(); _passed++; Console.WriteLine("PASS " + name); }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="CreateHardLinkW")]
    [return:MarshalAs(UnmanagedType.Bool)] private static extern bool CreateHardLink(string link,string existing,IntPtr security);
}
