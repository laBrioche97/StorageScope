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
using System.Windows.Automation.Peers;
using StorageScope.Windows;

internal static class Program
{
    private static int _passed;
    private static string _root = "";
    private static IReadOnlyList<InstalledApplication>? _auditedApplications;
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--probe-exit")) { Thread.Sleep(500); return unchecked((int)0xC0000005); }
        _root = Path.Combine(Environment.CurrentDirectory, ".test-data", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
        // Every diagnostic written by the test process stays in its disposable fixture tree.
        Diagnostics.TestDirectory = Path.Combine(_root, "diagnostics");
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
            Test("Steam manifest merges mirrored 32 and 64 bit registrations once", () =>
            {
                var registration = new InstalledApplication("Game", "Steam", null, null, "steam://uninstall/123", "Steam", "Steam App 123", "CurrentUser|Registry64|Steam App 123", IconLocation: "C:/icon.ico");
                var manifest = new InstalledApplication("Game", "Steam", null, Path.Combine(_root, "game"), "steam://uninstall/123", "Steam", "Steam App 123", ManifestPath: Path.Combine(_root, "appmanifest_123.acf"), EstimatedBytes: 1234);
                var merged = InstalledProductCatalog.Merge([registration, registration with { RegistrationPath = "CurrentUser|Registry32|Steam App 123" }, manifest, manifest with { InstallLocation = manifest.InstallLocation!.Replace('\\', '/'), ManifestPath = manifest.ManifestPath!.Replace('\\', '/') }]);
                Check(merged.Count == 1 && merged[0].ManifestPath == manifest.ManifestPath && merged[0].EstimatedBytes == 1234 && merged[0].IconLocation == registration.IconLocation);
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
            Test("package verification rejects altered bytes and incomplete downloads", () =>
            {
                var path = Fixture("package-fixture.exe", "signed package fixture");
                var hash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
                var manifest = new UpdateManifest(2, "3.3.0", 19041, "", "https://github.com/laBrioche97/StorageScope/releases/download/v3.3.0/StorageScope-Windows-Setup-DEVELOPMENT.exe", hash, new FileInfo(path).Length, "universal");
                UpdateService.VerifyContents(path, manifest);
                File.WriteAllText(path, "altered package data!!"); Throws(() => UpdateService.VerifyContents(path, manifest));
                File.WriteAllText(path, "partial"); Throws(() => UpdateService.VerifyContents(path, manifest));
                Throws(() => UpdateService.VerifyInstaller(path, manifest));
                using var rsa = RSA.Create(3072); var bytes = JsonSerializer.SerializeToUtf8Bytes(manifest);
                Check(UpdateService.ValidateManifest(bytes, rsa.SignData(bytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pss), rsa.ExportSubjectPublicKeyInfoPem(), "v3.3.0", new Version(3,2,0)).SchemaVersion == 2);
            });
            Test("diagnostics rotate redact profile paths and detect native exit codes", () =>
            {
                Diagnostics.TestDirectory = Path.Combine(_root, "diagnostics");
                try
                {
                    Directory.CreateDirectory(Diagnostics.DirectoryPath);
                    File.WriteAllText(Diagnostics.LogPath, new string('x', 2 * 1024 * 1024));
                    Diagnostics.Write("fixture", new IOException(Path.Combine(DeletionSafetyPolicy.Home, "private-name")));
                    Check(File.Exists(Diagnostics.LogPath + ".1"));
                    Check(!File.ReadAllText(Diagnostics.LogPath).Contains(DeletionSafetyPolicy.Home, StringComparison.OrdinalIgnoreCase));
                    var session = Guid.NewGuid().ToString("N");
                    File.WriteAllText(Path.Combine(Diagnostics.DirectoryPath, session + ".session"), "running");
                    var probe = new System.Diagnostics.ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
                    if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase)) probe.ArgumentList.Add(typeof(Program).Assembly.Location);
                    probe.ArgumentList.Add("--probe-exit");
                    using var process = System.Diagnostics.Process.Start(probe)!;
                    var ticks = process.StartTime.ToUniversalTime().Ticks;
                    Diagnostics.Watch(["--watch-session", process.Id.ToString(), ticks.ToString(), session]);
                    Check(File.ReadAllText(Diagnostics.LogPath).Contains("0xC0000005"));
                    Check(File.Exists(Path.Combine(Diagnostics.DirectoryPath, "previous-crash")));
                }
                finally { Diagnostics.TestDirectory = Path.Combine(_root, "diagnostics"); }
            });
            Test("category files are retained independently and bounded per category", () =>
            {
                var index = new CategoryFileIndex();
                for (var i = 0; i < 800; i++) index.Observe(Entry(Path.Combine(_root, i + ".mp4")) with { Size = i + 1000, Category = StorageCategory.Videos });
                var document = Entry(Path.Combine(_root,"small.txt")) with { Size = 1, Category = StorageCategory.Documents };
                index.Observe(document);
                var groups = index.Results();
                Check(groups[StorageCategory.Videos].Count == CategoryFileIndex.Limit);
                Check(groups[StorageCategory.Documents].Single() == document);
                Check(groups[StorageCategory.Videos].First().Size == 1799 && groups[StorageCategory.Videos].Last().Size == 1300);
            });
            Test("filters combine search category size and kind without treating unknown app sizes as zero", () =>
            {
                var filter = new DisplayFilter("photo", StorageCategory.Images, 100, EntryKind.Files);
                Check(filter.Matches(Entry(Path.Combine(_root,"Photo.JPG")) with { Size = 1000, Category = StorageCategory.Images }));
                Check(!filter.Matches(Entry(Path.Combine(_root,"Photo.JPG")) with { Size = 20, Category = StorageCategory.Images }));
                Check(!filter.Matches(Entry(Path.Combine(_root,"Photo.JPG")) with { Size = 1000, Category = StorageCategory.Documents }));
                Check(!new DisplayFilter("", null, 1, EntryKind.All).Matches(new InstalledApplication("Unknown",null,null,null,null)));
                Check(RegisteredProductProvider.DeclaredSize(100) == 102400 && RegisteredProductProvider.DeclaredSize(long.MaxValue) is null);
            });
            Test("icon references reject remote paths and malformed resources safely fall back", () =>
            {
                Check(ApplicationIcons.ParseLocation("https://example.com/icon.png") is null);
                Check(ApplicationIcons.ParseLocation(@"\\server\share\icon.ico") is null);
                Check(ApplicationIcons.ParseLocation("relative.exe,0") is null);
                var parsed = ApplicationIcons.ParseLocation("\"C:\\App, With Comma\\app.exe\",-7");
                Check(parsed?.Index == -7 && parsed?.Path == @"C:\App, With Comma\app.exe");
                var corrupt = Fixture("corrupt.png", "not a bitmap");
                Check(ReferenceEquals(ApplicationIcons.Load(new InstalledApplication("Bad",null,null,null,null,IconLocation:corrupt)),ApplicationIcons.Fallback));
                Check(!ReferenceEquals(ApplicationIcons.Load(new InstalledApplication("StorageScope",null,null,null,null,IconLocation:Path.GetFullPath("Packaging/Branding/StorageScope.ico"))),ApplicationIcons.Fallback));
            });
            Test("background decoded icons are safe for automation and UI access", () =>
            {
                var sample = new InstalledApplication("Background icon", null, null, null, null, IconLocation: Path.GetFullPath("Packaging/Branding/StorageScope.ico"));
                var decoded = Task.Run(() => sample with { Icon = ApplicationIcons.Load(sample) }).GetAwaiter().GetResult();
                Check(decoded.ToString() == "Background icon");
                Check(decoded.Icon.IsFrozen && decoded.Icon is BitmapSource);
                _ = decoded.Icon.ToString();
                _ = new ListBoxItemAutomationPeer(decoded, new ListBoxAutomationPeer(new ListBox())).GetName();
            });
            Test("application sizes measure independently without inventing zero", () =>
            {
                var folder = Path.Combine(_root, "application-size"); Directory.CreateDirectory(folder);
                File.WriteAllBytes(Path.Combine(folder, "data.bin"), new byte[4096]);
                var app = ApplicationEnrichment.Measure(new InstalledApplication("Measured", null, null, folder, null), default);
                Check(app.EstimatedBytes == 4096 && app.SizeStatus == "Mesurée");
                var unknown = ApplicationEnrichment.Measure(new InstalledApplication("Unknown", null, null, null, null), default);
                Check(!unknown.HasKnownSize && unknown.DisplaySize == "Indisponible");
            });
            if (args.Contains("--shell-integration")) Test("real isolated recycle worker and shell restoration", () =>
            {
                var path = Fixture("recycle-integration-" + Guid.NewGuid().ToString("N") + ".txt", "Disposable StorageScope test fixture");
                RecycleWorker.Move(Select(path));
                Check(!File.Exists(path));
                dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application")!)!;
                dynamic bin = shell.NameSpace(10);
                var restored = false;
                foreach (dynamic item in bin.Items())
                {
                    if ((string)item.Name != Path.GetFileName(path) && (string)item.Name != Path.GetFileNameWithoutExtension(path)) continue;
                    if (!string.Equals((string)item.ExtendedProperty("System.Recycle.DeletedFrom"), Path.GetDirectoryName(path), StringComparison.OrdinalIgnoreCase)) continue;
                    item.InvokeVerb("undelete"); restored = true; break;
                }
                Check(restored);
                Check(SpinWait.SpinUntil(() => File.Exists(path), TimeSpan.FromSeconds(10)));
            });
            if (args.Contains("--isolated-empty-bin")) Test("system recycle size, rejected confirmation and isolated permanent empty", () => RecycleBinTests.Run(_root));
            if (args.Contains("--inventory-audit")) Test("real local inventory resolves installed icons and independent footprints", () =>
            {
                _auditedApplications = Task.Run(async () =>
                {
                    var detected = await new InstalledProductCatalog().DetectAsync(default);
                    using var slots = new SemaphoreSlim(3);
                    return await Task.WhenAll(detected.Select(async (item, index) =>
                    {
                        await slots.WaitAsync();
                        try
                        {
                            var enriched = item with { Icon = await ApplicationEnrichment.IconAsync(item, default) };
                            return index < 8 || item.Provider == "Steam" ? await Task.Run(() => ApplicationEnrichment.Measure(enriched, default)) : enriched;
                        }
                        finally { slots.Release(); }
                    }));
                }).GetAwaiter().GetResult();
                var resolved = _auditedApplications.Count(item => !ReferenceEquals(item.Icon, ApplicationIcons.Fallback));
                Console.WriteLine(JsonSerializer.Serialize(new { installed = _auditedApplications.Count, logos = resolved, steamLogos = _auditedApplications.Count(item => item.Provider == "Steam" && !ReferenceEquals(item.Icon, ApplicationIcons.Fallback)), measured = _auditedApplications.Count(item => item.SizeStatus == "Mesurée"), sizesAvailable = _auditedApplications.Count(item => item.HasKnownSize) }));
                Check(_auditedApplications.Count > 0 && resolved > 0);
            });
            Test("session logo cache, bounded bubbles and unknown directory sizes", () => ExplorerFeatureTests.Run(_root));
            Test("offline window construction and responsive rendering", () => Render(args.FirstOrDefault(arg => !arg.StartsWith("--"))));
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
        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown }; app.InitializeComponent();
        var window = new MainWindow { IsPreviewMode = true, ShowActivated = false, ShowInTaskbar = false, WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = -20000 };
        var tab = (TabControl)window.FindName("MainTabs");
        Check(((TabItem)tab.Items[0]).Name == "ApplicationsTab" && tab.SelectedIndex == 0);
        var largest = (DataGrid)window.FindName("LargestFilesGrid");
        var largestSource = (IList<ScanEntry>)largest.ItemsSource;
        largestSource.Add(Entry(Path.Combine(_root,"Documents","Projet personnel.zip")) with { Size = 650_000_000, Category = StorageCategory.ArchivesInstallers });
        largestSource.Add(Entry(Path.Combine(_root,"Mes vidéos","Vacances.mp4")) with { Size = 2_800_000_000, Category = StorageCategory.Videos });
        var cleanup = (DataGrid)window.FindName("CleanupGrid");
        var cleanupSource = (IList<CleanupCandidate>)cleanup.ItemsSource;
        cleanupSource.Add(new CleanupCandidate(Path.Combine(_root,"cache.tmp"),"Temporaire reconnu",120_000_000,false,"Caches et temporaires","Peut être recréé",true));
        cleanupSource.Add(new CleanupCandidate(Path.Combine(_root,"photo.jpg"),"Fichier personnel",200_000_000,false,"À examiner"));
        var categories = (DataGrid)window.FindName("CategoryFilesGrid");
        var categorySource = (IList<ScanEntry>)categories.ItemsSource;
        categorySource.Add(Entry(Path.Combine(_root,"petite-photo.jpg")) with { Size = 20_000_000, Category = StorageCategory.Images });
        categorySource.Add(Entry(Path.Combine(_root,"grande-photo.jpg")) with { Size = 800_000_000, Category = StorageCategory.Images });
        categorySource.Add(Entry(Path.Combine(_root,"sauvegarde.zip")) with { Size = 2_000_000_000, Category = StorageCategory.ArchivesInstallers });
        var applications = (DataGrid)window.FindName("ApplicationsGrid");
        var applicationSource = (IList<InstalledApplication>)applications.ItemsSource;
        var sample = new InstalledApplication("StorageScope", "La Brioche", "3.1.0", "C:/Applications/StorageScope", null, EstimatedBytes: 120_000_000, IconLocation: Path.GetFullPath("Packaging/Branding/StorageScope.ico"));
        applicationSource.Add(new InstalledApplication("Taille non déclarée", "Éditeur", "1.0", "C:/Applications/Exemple", null));
        applicationSource.Add(sample with { Icon = ApplicationIcons.Load(sample) });
        applicationSource.Add(new InstalledApplication("Jeu Steam — exemple", "Steam", "1.0", "D:/Jeux/Steam", "steam://uninstall/123", "Steam", EstimatedBytes: 12_000_000_000));
        Test("rendered lists sort numeric sizes and keep unknown applications last", () => {
            Check(largest.Items.OfType<ScanEntry>().First().Size == 2_800_000_000);
            Check(categories.Items.OfType<ScanEntry>().Where(item => item.Category == StorageCategory.Images).First().Size == 800_000_000);
            Check(applications.Items.OfType<InstalledApplication>().First().Provider == "Steam");
            Check(!applications.Items.OfType<InstalledApplication>().Last().HasKnownSize);
            tab.SelectedItem = window.FindName("ApplicationsTab");
            ((ComboBox)window.FindName("ResultSort")).SelectedIndex = 1;
            Check(applications.Items.OfType<InstalledApplication>().First().Name == "StorageScope");
            Check(!applications.Items.OfType<InstalledApplication>().Last().HasKnownSize);
            ((ComboBox)window.FindName("ResultSort")).SelectedIndex = 0;
            tab.SelectedItem = window.FindName("OverviewTab");
        });
        Test("rendered filters refresh existing rows and preserve category boundaries", () => {
            var search = (TextBox)window.FindName("ListSearch"); search.Text = "projet";
            Check(largest.Items.OfType<ScanEntry>().Single().Name.Contains("Projet")); search.Clear();
            var size = (ComboBox)window.FindName("MinimumSizeFilter"); size.SelectedIndex = 3;
            Check(largest.Items.OfType<ScanEntry>().Count() == 1 && applications.Items.OfType<InstalledApplication>().Count() == 3); size.SelectedIndex = 0;
            var category = (ComboBox)window.FindName("CategoryFilter"); category.SelectedItem = category.Items.OfType<CategoryChoice>().Single(item => item.Category == StorageCategory.Images);
            Check(categories.Items.OfType<ScanEntry>().Count() == 3 && largest.Items.OfType<ScanEntry>().Count() == 0); category.SelectedIndex = 0;
            var kind = (ComboBox)window.FindName("EntryKindFilter"); kind.SelectedIndex = 2;
            Check(largest.Items.OfType<ScanEntry>().Count() == 0); kind.SelectedIndex = 0;
        });
        Test("category navigation clears incompatible filters and tabs retain their own search", () =>
        {
            tab.SelectedItem = window.FindName("ApplicationsTab");
            ((TextBox)window.FindName("ListSearch")).Text = "Steam";
            tab.SelectedItem = window.FindName("CategoriesTab");
            var summary = (ComboBox)window.FindName("CategorySummary");
            summary.ItemsSource = new[] { new CategoryChoice("Toutes", null), new CategoryChoice("Images", StorageCategory.Images) };
            ((TextBox)window.FindName("ListSearch")).Text = "missing";
            ((ComboBox)window.FindName("EntryKindFilter")).SelectedIndex = 2;
            summary.SelectedIndex = 1;
            Check(categories.Items.OfType<ScanEntry>().Count() == 2);
            Check(categories.Items.OfType<ScanEntry>().First().Size == 800_000_000);
            tab.SelectedItem = window.FindName("ApplicationsTab");
            Check(((TextBox)window.FindName("ListSearch")).Text == "Steam");
            ((TextBox)window.FindName("ListSearch")).Clear(); tab.SelectedItem = window.FindName("OverviewTab");
        });
        var content = (Grid)window.Content;
        if (_auditedApplications is not null) { applicationSource.Clear(); foreach (var item in _auditedApplications) applicationSource.Add(item); }
        var drive = (ComboBox)window.FindName("DrivePicker");
        drive.ItemsSource = new[] { new DriveChoice(new DriveInfo(Path.GetPathRoot(_root)!)) }; drive.SelectedIndex = 0;
        window.Show();
        window.Dispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);
        GuidedInterfaceTests.Run(window, _root, Test);
        ScanResponsivenessTests.Run(_root, Test);
        if (Environment.GetCommandLineArgs().Contains("--scan-audit")) ScanResponsivenessTests.AuditVolume(Test);
        var bubbleRoot = Path.Combine(_root, "graph-display");
        var bubbleSizes = new Dictionary<string, long> { [bubbleRoot] = 100_000_000_000 };
        var names = new[] { "Applications", "Jeux", "Documents", "Vidéos", "Archives" };
        for (var i = 0; i < names.Length; i++) {
            var folder = Path.Combine(bubbleRoot, names[i]); var bytes = (5 - i) * 5_000_000_000L;
            bubbleSizes[folder] = bytes; bubbleSizes[Path.Combine(folder, "Sous-dossier")] = bytes / 2;
        }
        var bubbleResult = new ScanResult { Root = bubbleRoot, DirectorySizes = bubbleSizes, LargestFiles = [], Categories = [], CleanupCandidates = [], IdentifiedBytes = 100_000_000_000, FilesScanned = 100, DirectoriesScanned = 10, AccessErrors = 0 };
        ((ItemsControl)window.FindName("OverviewCategories")).ItemsSource = categorySource.GroupBy(item => item.Category).Select(group => new CategoryResult(group.Key, group.Sum(item => item.Size), group.LongCount())).ToArray();
        var fixtureEntries = bubbleSizes.Where(item => Path.GetDirectoryName(item.Key) == bubbleRoot).Select(item => new ScanEntry(item.Key, Path.GetFileName(item.Key), item.Value, true, null, StorageCategory.Other)).ToList();
        fixtureEntries.Add(new ScanEntry(Path.Combine(bubbleRoot, "Vidéo.mp4"), "Vidéo.mp4", 8_000_000_000, false, null, StorageCategory.Videos));
        typeof(MainWindow).GetField("_allExplorerItems", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.SetValue(window, fixtureEntries);
        ((ResultCollection<ScanEntry>)((DataGrid)window.FindName("ExplorerGrid")).ItemsSource).ReplaceAll(fixtureEntries);
        var fixtureIndex = new FolderIndex(bubbleResult);
        typeof(MainWindow).GetField("_folderFrame", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.SetValue(window, fixtureIndex.Frame(bubbleRoot, fixtureEntries, 24, default));
        ((TextBlock)window.FindName("BubbleStatus")).Text = "100 Go identifiés · Cliquez sur un dossier pour l’ouvrir.";
        foreach (var (name, width, height, index, scale, dark, contrast) in new[] { ("windows-overview",1120,800,0,1d,true,false), ("windows-cleanup-small",740,700,3,1d,true,false), ("windows-minimum",740,560,3,1d,true,false), ("windows-cleanup-200",1120,800,3,2d,true,false), ("windows-games-light",1120,800,4,1d,false,false), ("windows-categories",1120,800,2,1d,true,false), ("windows-games-small",740,560,4,1d,true,false), ("windows-filters",1120,800,4,1d,true,false), ("windows-contrast",1120,800,0,1d,false,true), ("windows-bubbles",1120,800,1,1d,true,false), ("windows-bubbles-small",740,560,1,1d,false,false), ("windows-bubbles-200",1120,800,1,2d,true,false) })
        {
            app.ApplyPalette(dark,contrast);
            content.Background = (Brush)app.Resources["PageBrush"];
            window.Width = width; window.Height = height;
            tab.SelectedItem = window.FindName(new[] { "OverviewTab", "ExplorerTab", "CategoriesTab", "CleanupTab", "ApplicationsTab" }[index]);
            ((System.Windows.FrameworkElement)window.FindName("ExtraFilters")).Visibility = name == "windows-filters" ? Visibility.Visible : Visibility.Collapsed;
            window.UpdateLayout();
            window.Dispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);
            window.UpdateLayout();
            if (index == 1) {
                var canvas = (Canvas)window.FindName("BubbleCanvas");
                var maximum = Math.Clamp((int)(Math.Max(200, canvas.ActualWidth) * Math.Max(200, canvas.ActualHeight) / 18000), 4, 24);
                typeof(MainWindow).GetField("_folderFrame", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.SetValue(window, fixtureIndex.Frame(bubbleRoot, fixtureEntries, maximum, default));
                typeof(MainWindow).GetMethod("RenderBubbles", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.Invoke(window, null);
                window.UpdateLayout();
                Check(((Canvas)window.FindName("BubbleCanvas")).Children.Count > 0 && ((Canvas)window.FindName("BubbleCanvas")).Children.Count <= 6);
                var bubble = (Button)((Canvas)window.FindName("BubbleCanvas")).Children[0];
                Check(bubble.ActualWidth > 0 && !string.IsNullOrEmpty(new ButtonAutomationPeer(bubble).GetName()));
            }
            Check(((SolidColorBrush)window.Foreground).Color == ((SolidColorBrush)app.Resources["TextBrush"]).Color);
            Check(content.ActualWidth > 600 && content.ActualHeight > 400);
            if (index == 3)
            {
                Console.WriteLine($"Layout {width}x{height}: cleanup table {cleanup.ActualHeight}");
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
