using System.IO;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;

namespace StorageScope.Windows;

public partial class MainWindow
{
    private readonly ExplorerSessionCache _explorerCache = new();
    internal Func<string, IReadOnlyDictionary<string, long>?, CancellationToken, Task<IReadOnlyList<ScanEntry>>> ReadExplorerDirectory { get; set; } = DirectoryBrowser.BrowseAsync;
    internal Action<string, double>? NavigationTiming { get; set; }
    private string? _pendingDirectory;
    private bool _navigationPending;
    private bool _navigationBack;
    private Point _navigationAnchor = new(.5, .5);
    private DispatcherTimer? _loadingDelay;
    private string NavigationKey(string path) => (_storageIdentity ?? (DrivePicker.SelectedItem as DriveChoice)?.Identity ?? "preview") + "|" + (_folderIndex is null ? 0 : RuntimeHelpers.GetHashCode(_folderIndex)) + "|" + Path.GetFullPath(path).TrimEnd('\\');
    private string NavigationLayout => $"{Math.Round(BubbleCanvas.ActualWidth / 16)}:{Math.Round(BubbleCanvas.ActualHeight / 16)}:{VisualTreeHelper.GetDpi(BubbleCanvas).DpiScaleX}:{_bubbleMode}";
    private static ScrollViewer? GridScroll(DependencyObject parent)
    {
        if (parent is ScrollViewer scroll) return scroll;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) if (GridScroll(VisualTreeHelper.GetChild(parent, i)) is { } child) return child;
        return null;
    }
    private void SaveExplorerView()
    {
        if (_currentDirectory is null || _navigationPending) return;
        var key = NavigationKey(_currentDirectory); var existing = _explorerCache.Get(key);
        if (existing is null) return;
        _explorerCache.Put(key, existing with { Frame = _folderFrame, Layout = NavigationLayout,
            Selection = ExplorerGrid.SelectedItems.OfType<ScanEntry>().Select(item => item.Path).ToArray(), Scroll = GridScroll(ExplorerGrid)?.VerticalOffset ?? 0 });
    }
    private void InvalidateExplorerCache() { _explorerCache.Clear(); }
    private void SetNavigationPending(bool pending, string? destination = null)
    {
        _navigationPending = pending; _pendingDirectory = pending ? destination : null;
        ExplorerGrid.IsEnabled = BubbleCanvas.IsEnabled = !pending;
        AutomationProperties.SetItemStatus(ExplorerGrid, pending ? "Ouverture du dossier suivant" : "");
    }
    private async Task BrowseAsync(string path, bool addHistory = true)
    {
        path = Path.GetFullPath(path);
        _browseCancellation?.Cancel(); _bubbleCancellation?.Cancel(); _bubbleCancellation = null; ++_bubbleGeneration;
        SaveExplorerView();
        var cancellation = new CancellationTokenSource(); _browseCancellation = cancellation;
        var generation = ++_browseGeneration; var volumeGeneration = _volumeGeneration; var index = _folderIndex;
        var back = _navigationBack; _navigationBack = false;
        var anchor = _navigationAnchor; _navigationAnchor = new(.5, .5);
        var key = NavigationKey(path); var layout = NavigationLayout; var cached = _explorerCache.Get(key);
        var diameter = Math.Max(100, Math.Min(BubbleCanvas.ActualWidth, BubbleCanvas.ActualHeight) - 12);
        var maximum = Math.Clamp((int)(Math.Max(200, BubbleCanvas.ActualWidth) * Math.Max(200, BubbleCanvas.ActualHeight) / 18000), 4, 24);
        var previousPath = _currentDirectory;
        SetNavigationPending(cached is null, path);
        BubbleStatus.Text = cached is null ? $"Ouverture de {path}…" : $"{path} · Actualisation en arrière-plan…";
        SetExplorerLoading(cached is null, "Lecture du dossier…");
        bool Current() => !_closing && generation == _browseGeneration && volumeGeneration == _volumeGeneration && !cancellation.IsCancellationRequested;
        FolderFrame Build(IReadOnlyList<ScanEntry> entries) => index is not null ? index.Frame(path, entries, maximum, cancellation.Token, diameter) : FolderIndex.BuildFrame(path, entries, null, true, maximum, cancellation.Token, diameter);
        void Publish(ExplorerViewSnapshot snapshot, bool transition)
        {
            var timing = System.Diagnostics.Stopwatch.StartNew();
            void Mark(string stage) { NavigationTiming?.Invoke(stage, timing.Elapsed.TotalMilliseconds); timing.Restart(); }
            if (!Current()) return;
            var previous = transition && previousPath != path ? Motion.Capture(ExplorerSplit) : null;
            if (_explorerScope != ExplorerScope.All) ResetExplorerScope();
            _currentDirectory = path; _allExplorerItems = snapshot.Entries.ToList(); _folderFrame = snapshot.Frame;
            SetNavigationPending(false); SetExplorerLoading(false);
            Mark("state");
            if (addHistory) RecordBrowse(path);
            Mark("history");
            ((TextBlock)ExplorerPathDisplay.Content).Text = path;
            AutomationProperties.SetName(ExplorerPathDisplay, path + " · Modifier le chemin");
            ExplorerPathBox.Visibility = Visibility.Collapsed; ExplorerPathDisplay.Visibility = ActualWidth < 950 ? Visibility.Collapsed : Visibility.Visible;
            Mark("path");
            var crumbs = new Stack<string>();
            for (var ancestor = path; ancestor is not null && crumbs.Count < 32; ancestor = Directory.GetParent(ancestor)?.FullName) crumbs.Push(ancestor);
            var position = 0;
            foreach (var crumb in crumbs) {
                if (position < ExplorerBreadcrumbs.Children.Count && ExplorerBreadcrumbs.Children[position] is Button found) {
                    if (!Equals(found.Tag, crumb)) { found.Tag = found.ToolTip = crumb; found.Content = Path.GetFileName(crumb.TrimEnd('\\')) is { Length: > 0 } label ? label : crumb; }
                    position++; continue;
                }
                var button = new Button { Content = Path.GetFileName(crumb.TrimEnd('\\')) is { Length: > 0 } name ? name : crumb, Tag = crumb, ToolTip = crumb, Padding = new Thickness(8, 4, 8, 4) };
                button.Click += async (_, _) => { if (button.Tag is string target) { _navigationBack = _currentDirectory is not null && DeletionSafetyPolicy.IsWithin(_currentDirectory, target); await BrowseAsync(target); } }; ExplorerBreadcrumbs.Children.Add(button); position++;
            }
            while (ExplorerBreadcrumbs.Children.Count > position) ExplorerBreadcrumbs.Children.RemoveAt(ExplorerBreadcrumbs.Children.Count - 1);
            Mark("breadcrumbs"); ApplyExplorerFilter(); Mark("filter"); RenderBubbles(); Mark("bubbles");
            foreach (var selected in _explorer.Where(item => snapshot.Selection.Contains(item.Path, StringComparer.OrdinalIgnoreCase))) ExplorerGrid.SelectedItems.Add(selected);
            GridScroll(ExplorerGrid)?.ScrollToVerticalOffset(snapshot.Scroll);
            Mark("restore");
            var frame = snapshot.Frame;
            DirectFilesButton.Content = $"Fichiers dans ce dossier{(frame?.DirectFiles is long direct ? " · " + (frame.Partial ? "estimation " : "") + SizeFormatter.Format(direct) : "")} — Voir la liste";
            BubbleStatus.Text = frame?.Total is long bytes ? $"{path} · {SizeFormatter.Format(bytes)} identifiés" + (frame.Partial ? " · analyse partielle" : "") : $"{path} · Tailles inconnues : analysez le disque pour compléter les bulles.";
            BubbleEmptyState.Visibility = frame is null || frame.Circles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            Motion.Swap(ExplorerSplit, ExplorerTransitionSnapshot, previous, back, anchor);
            Mark("transition");
        }
        try
        {
            if (cached is not null) {
                if (cached.Layout != layout && ExplorerShowsGraph) cached = cached with { Frame = await Task.Run(() => Build(cached.Entries), cancellation.Token), Layout = layout };
                if (!Current()) return; Publish(cached, true);
            }
            var entries = await ReadExplorerDirectory(path, _result?.DirectorySizes, cancellation.Token);
            if (!Current()) return;
            if (cached is not null && cached.Entries.SequenceEqual(entries)) return;
            var fresh = await Task.Run(() => new ExplorerViewSnapshot(entries, ExplorerShowsGraph ? Build(entries) : null, layout, cached?.Selection ?? [], cached?.Scroll ?? 0, ExplorerViewSnapshot.Estimate(entries)), cancellation.Token);
            if (!Current()) return;
            _explorerCache.Put(key, fresh); Publish(fresh, cached is null);
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            if (Current()) {
                Diagnostics.Write("lecture-dossier", error); BubbleStatus.Text = "Dossier inaccessible : " + error.Message;
                if (cached is not null) { _allExplorerItems.Clear(); _explorer.Clear(); _folderFrame = null; BubbleCanvas.Children.Clear(); }
                BubbleEmptyState.Text = "Ce dossier n’a pas pu être lu. Revenez au dossier parent ou réessayez."; BubbleEmptyState.Visibility = Visibility.Visible;
            }
        }
        finally
        {
            if (generation == _browseGeneration) { SetNavigationPending(false); SetExplorerLoading(false); RefreshSectionHeading(); }
            if (ReferenceEquals(_browseCancellation, cancellation)) _browseCancellation = null;
            cancellation.Dispose();
        }
    }

    private void EditExplorerPath_Click(object sender, RoutedEventArgs e)
    {
        ExplorerPathDisplay.Visibility = Visibility.Collapsed; ExplorerPathBox.Visibility = Visibility.Visible;
        ExplorerPathBox.Text = _currentDirectory ?? ""; ExplorerPathBox.Focus(); ExplorerPathBox.SelectAll();
    }
    private void ExplorerPathBox_LostFocus(object sender, System.Windows.Input.KeyboardFocusChangedEventArgs e)
    {
        ExplorerPathBox.Visibility = Visibility.Collapsed; ExplorerPathDisplay.Visibility = ActualWidth < 950 ? Visibility.Collapsed : Visibility.Visible;
    }
}
