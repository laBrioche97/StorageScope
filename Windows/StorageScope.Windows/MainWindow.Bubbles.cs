using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace StorageScope.Windows;

public partial class MainWindow
{
    private readonly SessionIconCache _iconCache = new();
    private Dictionary<string, System.Windows.Media.ImageSource> _activeIcons = [];
    private CancellationTokenSource? _bubbleCancellation;
    private readonly HashSet<string> _autoScanAttempts = new(StringComparer.OrdinalIgnoreCase);
    private FolderIndex? _folderIndex;
    private FolderFrame? _folderFrame;
    private int _bubbleGeneration;
    private bool _bubbleMode = true;
    private enum ExplorerScope { All, DirectFiles, Remainder }
    private ExplorerScope _explorerScope;
    private HashSet<string>? _explorerRemainder;
    private bool ExplorerShowsGraph => _bubbleMode && _explorerScope == ExplorerScope.All;

    private void ResetExplorerScope()
    {
        _explorerScope = ExplorerScope.All; _explorerRemainder = null;
        if (EntryKindFilter.SelectedIndex != 0) EntryKindFilter.SelectedIndex = 0;
        LayoutExplorer();
    }

    private void EnsureBubbleAnalysis()
    {
        if (!IsLoaded || IsPreviewMode || _choosingStorage || CurrentSection != Section.Explorer || !_bubbleMode || _result is not null || _scanning || _busy || DrivePicker.SelectedItem is not DriveChoice drive) return;
        if (_autoScanAttempts.Contains(drive.Root))
        {
            BubbleStatus.Text = "Analyse non disponible. Cliquez sur Analyser pour réessayer, ou utilisez la Liste.";
            return;
        }
        ScanButton_Click(this, new RoutedEventArgs());
    }
    private void UpdateBubbleFilters()
    {
        if (!_viewsReady) return;
        ResultSort.Visibility = FilterToggleButton.Visibility = Visibility.Visible;
    }
    private void ShowBubbles_Click(object sender, RoutedEventArgs e)
    {
        _bubbleMode = true; ResetExplorerScope();
        ApplyExplorerFilter(); UpdateBubbleFilters(); UpdateResponsiveColumns(); EnsureBubbleAnalysis();
        if (!_navigationPending && _currentDirectory is not null) _ = LoadBubblesAsync(_currentDirectory);
    }
    private void ShowExplorerList_Click(object sender, RoutedEventArgs e)
    {
        _bubbleMode = false; ResetExplorerScope();
        UpdateBubbleFilters(); UpdateResponsiveColumns(); ApplyExplorerFilter();
    }
    private void DirectFiles_Click(object sender, RoutedEventArgs e)
    {
        _explorerScope = ExplorerScope.DirectFiles; _explorerRemainder = null; LayoutExplorer();
        ListSearch.Clear(); CategoryFilter.SelectedIndex = MinimumSizeFilter.SelectedIndex = 0;
        EntryKindFilter.SelectedIndex = 1;
        ApplyExplorerFilter();
    }
    private async void ExplorerRoot_Click(object sender, RoutedEventArgs e)
    {
        _navigationBack = true;
        if (DrivePicker.SelectedItem is DriveChoice drive) await BrowseAsync(drive.Root);
    }
    private async Task LoadBubblesAsync(string path)
    {
        // Keep a failed folder-read explanation visible until the next navigation;
        // a deferred resize must not replace it with the previous folder's graph.
        if (_explorerNavigationError is not null) return;
        _bubbleCancellation?.Cancel();
        var cancellation = new CancellationTokenSource(); _bubbleCancellation = cancellation;
        var generation = ++_bubbleGeneration; var index = _folderIndex;
        var entries = _allExplorerItems.ToArray();
        var availableDiameter = Math.Max(100, Math.Min(BubbleCanvas.ActualWidth, BubbleCanvas.ActualHeight) - 12);
        var maximum = Math.Clamp((int)(Math.Max(200, BubbleCanvas.ActualWidth) * Math.Max(200, BubbleCanvas.ActualHeight) / 18000), 4, 24);
        SetExplorerLoading(true, _scanning && index is null ? "Analyse du disque… Les tailles se précisent en arrière-plan." : "Préparation du graphique…");
        try
        {
            var frame = await Task.Run(() => index is not null ? index.Frame(path, entries, maximum, cancellation.Token, availableDiameter) : FolderIndex.BuildFrame(path, entries, null, true, maximum, cancellation.Token, availableDiameter), cancellation.Token);
            if (_closing || cancellation.IsCancellationRequested || generation != _bubbleGeneration || _currentDirectory != path || !ReferenceEquals(index, _folderIndex)) return;
            _folderFrame = frame;
            BubbleStatus.Text = $"{path} · {(frame.Total is long total ? SizeFormatter.Format(total) + (frame.Partial ? " identifiés · analyse partielle" : " identifiés") : "Taille inconnue")}" + (frame.Circles.Count == 0 ? " · Aucun élément mesuré. Les tailles inconnues restent dans la liste." : " · Dossiers et fichiers de ce niveau · cliquez sur un dossier pour l’ouvrir.");
            DirectFilesButton.Content = $"Fichiers dans ce dossier{(frame.DirectFiles is long direct ? " · " + (frame.Partial ? "estimation " : "") + SizeFormatter.Format(direct) : "")} — Voir la liste";
            RenderBubbles();
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (generation == _bubbleGeneration) { Diagnostics.Write("graphique-dossiers", error); BubbleStatus.Text = "Graphique indisponible. La Liste reste accessible."; } }
        finally { if (ReferenceEquals(_bubbleCancellation, cancellation)) { _bubbleCancellation = null; SetExplorerLoading(_scanning && _folderIndex is null, "Analyse du disque… Vous pouvez annuler à tout moment."); } cancellation.Dispose(); }
    }
    private System.Windows.Threading.DispatcherTimer? _resizeTimer;
    private void BubbleCanvas_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        RenderBubbles();
        _resizeTimer ??= new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        _resizeTimer.Stop(); _resizeTimer.Tick -= ResizeLayout; _resizeTimer.Tick += ResizeLayout; _resizeTimer.Start();
    }
    private async void ResizeLayout(object? sender, EventArgs e)
    {
        _resizeTimer?.Stop();
        if (_currentDirectory is not null && !_closing && !_scanning && _browseCancellation is null && ExplorerShowsGraph) await LoadBubblesAsync(_currentDirectory);
    }
    private void RenderBubbles()
    {
        if (_explorerNavigationError is not null) {
            BubbleEmptyState.Text = _explorerNavigationError; BubbleEmptyState.Visibility = Visibility.Visible;
            return;
        }
        if (BubbleCanvas is null || _folderFrame is null) return;
        var existing = BubbleCanvas.Children.OfType<BubbleButton>().ToDictionary(button => button.Circle.Path, StringComparer.OrdinalIgnoreCase);
        var wanted = _folderFrame.Circles.Select(circle => circle.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var stale in existing.Values.Where(button => !wanted.Contains(button.Circle.Path)).ToArray()) BubbleCanvas.Children.Remove(stale);
        BubbleEmptyState.Text = _allExplorerItems.Count == 0 ? "Ce dossier est vide." : "Aucun élément mesuré. Les tailles inconnues restent dans la liste ; analysez le disque pour préparer les bulles.";
        BubbleEmptyState.Visibility = _folderFrame.Circles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var diameter = Math.Max(0, Math.Min(BubbleCanvas.ActualWidth, BubbleCanvas.ActualHeight) - 8);
        if (diameter < 1) return;
        var query = ListSearch.Text.Trim();
        foreach (var circle in _folderFrame.Circles.OrderBy(c => c.Depth))
        {
            if (existing.TryGetValue(circle.Path, out var changed) && changed.Circle.Aggregate != circle.Aggregate) { BubbleCanvas.Children.Remove(changed); existing.Remove(circle.Path); }
            var created = !existing.TryGetValue(circle.Path, out var button);
            button ??= new BubbleButton { Circle = circle, HasChildren = false, Highlighted = query.Length > 0 && circle.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase), Width = diameter * circle.Radius, Height = diameter * circle.Radius, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Brushes.Transparent, FocusVisualStyle = null, Template = new ControlTemplate(typeof(Button)) };
            button.Circle = circle; button.Width = diameter * circle.Radius; button.Height = diameter * circle.Radius; button.Highlighted = query.Length > 0 && circle.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase);
            var total = _folderFrame.Total;
            button.ToolTip = $"{circle.Name}\n{circle.Path}\n{SizeFormatter.Format(circle.Bytes)}" + (total > 0 ? $" · {circle.Bytes * 100d / total:N1} % du dossier parent" : "") + (_folderFrame.Partial ? "\nAnalyse partielle" : "");
            AutomationProperties.SetName(button, circle.Name + " · " + SizeFormatter.Format(circle.Bytes));
            AutomationProperties.SetHelpText(button, button.ToolTip.ToString());
            Canvas.SetLeft(button, BubbleCanvas.ActualWidth / 2 + circle.X * diameter / 2 - button.Width / 2);
            Canvas.SetTop(button, BubbleCanvas.ActualHeight / 2 + circle.Y * diameter / 2 - button.Height / 2);
            button.InvalidateVisual();
            if (!created) continue;
            button.Click += async (_, _) =>
            {
                if (button.Circle.Aggregate)
                {
                    ListSearch.Clear(); CategoryFilter.SelectedIndex = MinimumSizeFilter.SelectedIndex = EntryKindFilter.SelectedIndex = 0;
                    var remainder = _allExplorerItems.Where(item => item.HasKnownSize && item.Size > 0).OrderByDescending(item => item.Size).ThenBy(item => item.Path, StringComparer.OrdinalIgnoreCase).Skip(button.Circle.SkipCount).ToHashSet();
                    _explorerRemainder = remainder.Select(item => item.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
                    _explorerScope = ExplorerScope.Remainder; LayoutExplorer(); ApplyExplorerFilter();
                    BubbleStatus.Text = "Autres éléments du dossier courant · Liste et bulles pour revenir à tous les éléments.";
                }
                else if (button.Circle.IsDirectory) { _navigationAnchor = new Point(Math.Clamp((Canvas.GetLeft(button) + button.Width / 2) / Math.Max(1, BubbleCanvas.ActualWidth), 0, 1), Math.Clamp((Canvas.GetTop(button) + button.Height / 2) / Math.Max(1, BubbleCanvas.ActualHeight), 0, 1)); await BrowseAsync(button.Circle.Path); }
                else {
                    ExplorerGrid.SelectedItem = _allExplorerItems.FirstOrDefault(entry => entry.Path == button.Circle.Path);
                    if (ExplorerGrid.SelectedItem is not null) ExplorerGrid.ScrollIntoView(ExplorerGrid.SelectedItem);
                }

            };
            if (!button.Circle.Aggregate)
            {
                var menu = new ContextMenu();
                void Add(string title, RoutedEventHandler action) { var item = new MenuItem { Header = title }; item.Click += (source, args) => { if (!_navigationPending) action(source, args); }; menu.Items.Add(item); }
                Add(button.Circle.IsDirectory ? "Ouvrir le dossier" : "Ouvrir", async (_, _) => { if (button.Circle.IsDirectory) await BrowseAsync(button.Circle.Path); else SafeOpen(button.Circle.Path); });
                Add("Afficher dans l’Explorateur", (_, _) => SafeReveal(button.Circle.Path));
                Add("Copier le chemin", (_, _) => { try { Clipboard.SetText(button.Circle.Path); } catch (Exception error) { ShowError("Copie impossible.", error); } });
                Add("Propriétés", (_, _) => { try { ExplorerService.Properties(button.Circle.Path); } catch (Exception error) { ShowError("Propriétés indisponibles.", error); } });
                Add("Mettre à la corbeille…", async (_, _) => await TrashEntriesAsync([new(button.Circle.Path, button.Circle.Name, button.Circle.Bytes, button.Circle.IsDirectory, null, StorageCategory.Other)]));
                button.ContextMenu = menu;
            }
            button.MouseEnter += (_, _) => { if (!button.Circle.Aggregate) { var entry = _allExplorerItems.FirstOrDefault(item => item.Path == button.Circle.Path); if (entry is not null) ExplorerGrid.ScrollIntoView(entry); } HighlightExplorer(button.Circle.Path); };
            button.MouseLeave += (_, _) => HighlightExplorer((ExplorerGrid.SelectedItem as ScanEntry)?.Path);
            button.GotKeyboardFocus += (_, _) => HighlightExplorer(button.Circle.Path);
            BubbleCanvas.Children.Add(button);
        }
    }
}
