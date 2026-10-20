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

    private void EnsureBubbleAnalysis()
    {
        if (!IsLoaded || IsPreviewMode || CurrentSection != Section.Explorer || !_bubbleMode || _result is not null || _scanning || _busy || DrivePicker.SelectedItem is not DriveChoice drive) return;
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
        _bubbleMode = true; LayoutExplorer();
        ApplyExplorerFilter(); UpdateBubbleFilters(); UpdateResponsiveColumns(); EnsureBubbleAnalysis();
        if (_currentDirectory is not null) _ = LoadBubblesAsync(_currentDirectory);
    }
    private void ShowExplorerList_Click(object sender, RoutedEventArgs e)
    {
        _bubbleMode = false; LayoutExplorer();
        UpdateBubbleFilters(); UpdateResponsiveColumns(); ApplyExplorerFilter();
    }
    private void DirectFiles_Click(object sender, RoutedEventArgs e)
    {
        ShowExplorerList_Click(sender, e);
        ListSearch.Clear(); CategoryFilter.SelectedIndex = MinimumSizeFilter.SelectedIndex = 0;
        EntryKindFilter.SelectedIndex = 1;
    }
    private async void ExplorerRoot_Click(object sender, RoutedEventArgs e)
    {
        if (DrivePicker.SelectedItem is DriveChoice drive) await BrowseAsync(drive.Root);
    }
    private async Task LoadBubblesAsync(string path)
    {
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
            if (_closing || generation != _bubbleGeneration || _currentDirectory != path || !ReferenceEquals(index, _folderIndex)) return;
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
        if (_currentDirectory is not null && !_closing && !_scanning && _bubbleMode) await LoadBubblesAsync(_currentDirectory);
    }
    private void RenderBubbles()
    {
        if (BubbleCanvas is null || _folderFrame is null) return;
        BubbleCanvas.Children.Clear();
        var diameter = Math.Max(0, Math.Min(BubbleCanvas.ActualWidth, BubbleCanvas.ActualHeight) - 8);
        if (diameter < 1) return;
        var query = string.Join(' ', new[] { ListSearch.Text.Trim(), ExplorerSearchBox.Text.Trim() }.Where(s => s.Length > 0));
        foreach (var circle in _folderFrame.Circles.OrderBy(c => c.Depth))
        {
            var button = new BubbleButton { Circle = circle, HasChildren = false, Highlighted = query.Length > 0 && circle.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase), Width = diameter * circle.Radius, Height = diameter * circle.Radius, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Brushes.Transparent, FocusVisualStyle = null, Template = new ControlTemplate(typeof(Button)) };
            var total = _folderFrame.Total;
            button.ToolTip = $"{circle.Name}\n{circle.Path}\n{SizeFormatter.Format(circle.Bytes)}" + (total > 0 ? $" · {circle.Bytes * 100d / total:N1} % du dossier parent" : "") + (_folderFrame.Partial ? "\nAnalyse partielle" : "");
            AutomationProperties.SetName(button, circle.Name + " · " + SizeFormatter.Format(circle.Bytes));
            AutomationProperties.SetHelpText(button, button.ToolTip.ToString());
            Canvas.SetLeft(button, BubbleCanvas.ActualWidth / 2 + circle.X * diameter / 2 - button.Width / 2);
            Canvas.SetTop(button, BubbleCanvas.ActualHeight / 2 + circle.Y * diameter / 2 - button.Height / 2);
            button.Click += async (_, _) =>
            {
                if (circle.Aggregate)
                {
                    ListSearch.Clear(); CategoryFilter.SelectedIndex = MinimumSizeFilter.SelectedIndex = EntryKindFilter.SelectedIndex = 0;
                    var remainder = _allExplorerItems.Where(item => item.HasKnownSize && item.Size > 0).OrderByDescending(item => item.Size).ThenBy(item => item.Path, StringComparer.OrdinalIgnoreCase).Skip(circle.SkipCount).ToHashSet();
                    _explorer.ReplaceAll(_allExplorerItems.Where(remainder.Contains)); ShowExplorerList_Click(this, new());
                    BubbleStatus.Text = "Autres éléments du dossier courant · Liste et bulles pour revenir à tous les éléments.";
                }
                else if (circle.IsDirectory) await BrowseAsync(circle.Path);
                else {
                    ExplorerGrid.SelectedItem = _allExplorerItems.FirstOrDefault(entry => entry.Path == circle.Path);
                    if (ExplorerGrid.SelectedItem is not null) ExplorerGrid.ScrollIntoView(ExplorerGrid.SelectedItem);
                }

            };
            if (!circle.Aggregate)
            {
                var menu = new ContextMenu();
                void Add(string title, RoutedEventHandler action) { var item = new MenuItem { Header = title }; item.Click += action; menu.Items.Add(item); }
                Add(circle.IsDirectory ? "Ouvrir le dossier" : "Ouvrir", async (_, _) => { if (circle.IsDirectory) await BrowseAsync(circle.Path); else SafeOpen(circle.Path); });
                Add("Afficher dans l’Explorateur", (_, _) => SafeReveal(circle.Path));
                Add("Copier le chemin", (_, _) => { try { Clipboard.SetText(circle.Path); } catch (Exception error) { ShowError("Copie impossible.", error); } });
                Add("Propriétés", (_, _) => { try { ExplorerService.Properties(circle.Path); } catch (Exception error) { ShowError("Propriétés indisponibles.", error); } });
                Add("Mettre à la corbeille…", async (_, _) => await TrashEntriesAsync([new(circle.Path, circle.Name, circle.Bytes, circle.IsDirectory, null, StorageCategory.Other)]));
                button.ContextMenu = menu;
            }
            button.MouseEnter += (_, _) => { if (!circle.Aggregate) { var entry = _allExplorerItems.FirstOrDefault(item => item.Path == circle.Path); if (entry is not null) ExplorerGrid.ScrollIntoView(entry); } HighlightExplorer(circle.Path); };
            button.MouseLeave += (_, _) => HighlightExplorer((ExplorerGrid.SelectedItem as ScanEntry)?.Path);
            button.GotKeyboardFocus += (_, _) => HighlightExplorer(circle.Path);
            BubbleCanvas.Children.Add(button);
        }
    }
}
