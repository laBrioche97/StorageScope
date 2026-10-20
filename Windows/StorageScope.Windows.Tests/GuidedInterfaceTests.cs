using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using StorageScope.Windows;

internal static class GuidedInterfaceTests
{
    internal static void Run(MainWindow window, string root, Action<string, Action> test)
    {
        var previousContext = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(window.Dispatcher));
        var tabs = (TabControl)window.FindName("MainTabs");
        var cleanup = (DataGrid)window.FindName("CleanupGrid");
        var source = (ResultCollection<CleanupCandidate>)cleanup.ItemsSource;
        var flags = BindingFlags.Instance | BindingFlags.NonPublic;
        void Click(string name) => ((Button)window.FindName(name)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        test("version remains visible and sidebar opens stable sections", () => {
            Require(window.Title == AppIdentity.Title && AppIdentity.Version == "3.4.0");
            var navigation = (ListBox)window.FindName("SectionNavigation");
            navigation.SelectedIndex = 4; Require(((TabItem)tabs.SelectedItem).Name == "CleanupTab");
            navigation.SelectedIndex = 0; Require(((TabItem)tabs.SelectedItem).Name == "ApplicationsTab");
        });
        test("recognized temporary selection survives filters and virtualization", () => {
            tabs.SelectedItem = window.FindName("CleanupTab");
            var original = source.ToArray();
            var result = new ScanResult { Root = root, DirectorySizes = new Dictionary<string, long>(), LargestFiles = [], Categories = [], CleanupCandidates = [], IdentifiedBytes = 0, FilesScanned = 0, DirectoriesScanned = 0, AccessErrors = 0 };
            typeof(MainWindow).GetField("_result", flags)!.SetValue(window, result);
            source.ReplaceAll(Enumerable.Range(0, 1200).Select(i => new CleanupCandidate(Path.Combine(root, "temporary-" + i), "Temporary fixture", 100, false, Recommended: true)).Append(new CleanupCandidate(Path.Combine(root, "document"), "Personal", 400, false)).ToArray());
            ((TextBox)window.FindName("ListSearch")).Text = "no matches";
            Require(cleanup.Items.Count == 0);
            Click("SelectRecommendedButton");
            Require(cleanup.SelectedItems.Count == 1200 && cleanup.SelectedItems.OfType<CleanupCandidate>().All(item => item.Recommended));
            Require(((TextBlock)window.FindName("CleanupActionStatus")).Text.Contains("réinitialisés"));
            source.ReplaceAll(original); typeof(MainWindow).GetField("_result", flags)!.SetValue(window, null);
        });
        test("duplicate button shows progress and publishes visible verified results", () => {
            tabs.SelectedItem = window.FindName("CleanupTab");
            var original = source.ToArray();
            var folder = Path.Combine(root, "duplicate-button"); Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "one.txt"), "button regression fixture"); File.WriteAllText(Path.Combine(folder, "two.txt"), "button regression fixture");
            window.DuplicateDirectoryPicker = () => folder;
            ((TextBox)window.FindName("ListSearch")).Text = "no matches";
            Click("DuplicateButton");
            Require(((TextBlock)window.FindName("CleanupActionStatus")).Text.Contains("Recherche"));
            Require(((Button)window.FindName("CancelButton")).IsEnabled);
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while ((bool)typeof(MainWindow).GetField("_busy", flags)!.GetValue(window)!) {
                Require(DateTime.UtcNow < deadline);
                window.Dispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);
                Thread.Sleep(10);
            }
            Require(cleanup.Items.OfType<CleanupCandidate>().Count(item => item.Group == "Doublons vérifiés") == 1);
            Require(((TextBlock)window.FindName("CleanupActionStatus")).Text.Contains("vérifiée"));
            Require(File.Exists(Path.Combine(folder, "one.txt")) && File.Exists(Path.Combine(folder, "two.txt")));
            window.DuplicateDirectoryPicker = null; source.ReplaceAll(original);
        });
        tabs.SelectedItem = window.FindName("OverviewTab");
        SynchronizationContext.SetSynchronizationContext(previousContext);
    }
    private static void Require(bool condition) { if (!condition) throw new InvalidOperationException("Guided interface regression"); }
}
