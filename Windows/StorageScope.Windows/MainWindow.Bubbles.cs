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
        var bubbles = CurrentSection == Section.Explorer && _bubbleMode;
        ResultSort.Visibility = FilterToggleButton.Visibility = bubbles ? Visibility.Collapsed : Visibility.Visible;
        if (bubbles) ExtraFilters.Visibility = Visibility.Collapsed;
    }
    private void ShowBubbles_Click(object sender, RoutedEventArgs e)
    {
        _bubbleMode = true; BubblePanel.Visibility = Visibility.Visible; ExplorerGrid.Visibility = Visibility.Collapsed;
        UpdateBubbleFilters(); EnsureBubbleAnalysis();
        if (_currentDirectory is not null) _ = LoadBubblesAsync(_currentDirectory);
    }
    private void ShowExplorerList_Click(object sender, RoutedEventArgs e)
    {
        _bubbleMode = false; BubblePanel.Visibility = Visibility.Collapsed; ExplorerGrid.Visibility = Visibility.Visible;
        UpdateBubbleFilters(); ApplyExplorerFilter();
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
        if (index is null)
        {
            _folderFrame = null; BubbleCanvas.Children.Clear();
            BubbleStatus.Text = _scanning ? "Analyse en cours… Vous pouvez naviguer dans la Liste ou annuler l’analyse." : "Une analyse permet de comparer les dossiers. Cliquez sur Analyser pour réessayer.";
            cancellation.Dispose(); if (ReferenceEquals(_bubbleCancellation, cancellation)) _bubbleCancellation = null;
            return;
        }
        try
        {
            var frame = await Task.Run(() => index.Frame(path, cancellation.Token), cancellation.Token);
            if (_closing || generation != _bubbleGeneration || _currentDirectory != path || !ReferenceEquals(index, _folderIndex)) return;
            _folderFrame = frame;
            BubbleStatus.Text = $"{path} · {(frame.Total is long total ? SizeFormatter.Format(total) + (frame.Partial ? " identifiés · analyse partielle" : " identifiés") : "Taille inconnue")}" + (frame.Circles.Count == 0 ? " · Aucun sous-dossier mesuré. Consultez les fichiers dans la Liste." : " · Cliquez sur un dossier pour l’ouvrir.");
            DirectFilesButton.Content = $"Fichiers dans ce dossier{(frame.DirectFiles is long direct ? " · " + (frame.Partial ? "estimation " : "") + SizeFormatter.Format(direct) : "")} — Voir la liste";
            RenderBubbles();
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (generation == _bubbleGeneration) { Diagnostics.Write("graphique-dossiers", error); BubbleStatus.Text = "Graphique indisponible. La Liste reste accessible."; } }
        finally { if (ReferenceEquals(_bubbleCancellation, cancellation)) _bubbleCancellation = null; cancellation.Dispose(); }
    }
    private void BubbleCanvas_SizeChanged(object sender, SizeChangedEventArgs e) => RenderBubbles();
    private void RenderBubbles()
    {
        if (BubbleCanvas is null || _folderFrame is null) return;
        BubbleCanvas.Children.Clear();
        var diameter = Math.Max(0, Math.Min(BubbleCanvas.ActualWidth, BubbleCanvas.ActualHeight) - 8);
        if (diameter < 1) return;
        var query = string.Join(' ', new[] { ListSearch.Text.Trim(), ExplorerSearchBox.Text.Trim() }.Where(s => s.Length > 0));
        foreach (var circle in _folderFrame.Circles.OrderBy(c => c.Depth))
        {
            var button = new BubbleButton { Circle = circle, Highlighted = query.Length > 0 && circle.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase), Width = diameter * circle.Radius, Height = diameter * circle.Radius, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Brushes.Transparent, FocusVisualStyle = null, Template = new ControlTemplate(typeof(Button)) };
            var total = _folderFrame.Total;
            button.ToolTip = $"{circle.Name}\n{circle.Path}\n{SizeFormatter.Format(circle.Bytes)}" + (total > 0 ? $" · {circle.Bytes * 100d / total:N1} % du dossier affiché" : "") + (_folderFrame.Partial ? "\nAnalyse partielle" : "");
            AutomationProperties.SetName(button, circle.Name + " · " + SizeFormatter.Format(circle.Bytes));
            AutomationProperties.SetHelpText(button, button.ToolTip.ToString());
            Canvas.SetLeft(button, BubbleCanvas.ActualWidth / 2 + circle.X * diameter / 2 - button.Width / 2);
            Canvas.SetTop(button, BubbleCanvas.ActualHeight / 2 + circle.Y * diameter / 2 - button.Height / 2);
            button.Click += async (_, _) =>
            {
                if (circle.Aggregate)
                {
                    await BrowseAsync(circle.Path); ShowExplorerList_Click(this, new());
                    ListSearch.Clear(); CategoryFilter.SelectedIndex = MinimumSizeFilter.SelectedIndex = 0; EntryKindFilter.SelectedIndex = 2;
                    var remainder = _folderIndex?.Remainder(circle.Path, circle.SkipCount).ToHashSet(StringComparer.OrdinalIgnoreCase) ?? [];
                    _explorer.ReplaceAll(_allExplorerItems.Where(entry => remainder.Contains(entry.Path)));
                }
                else await BrowseAsync(circle.Path);
            };
            if (!circle.Aggregate)
            {
                var menu = new ContextMenu();
                void Add(string title, RoutedEventHandler action) { var item = new MenuItem { Header = title }; item.Click += action; menu.Items.Add(item); }
                Add("Ouvrir le dossier", async (_, _) => await BrowseAsync(circle.Path));
                Add("Afficher dans l’Explorateur", (_, _) => SafeReveal(circle.Path));
                Add("Copier le chemin", (_, _) => { try { Clipboard.SetText(circle.Path); } catch (Exception error) { ShowError("Copie impossible.", error); } });
                Add("Propriétés", (_, _) => { try { ExplorerService.Properties(circle.Path); } catch (Exception error) { ShowError("Propriétés indisponibles.", error); } });
                Add("Mettre à la corbeille…", async (_, _) => await TrashEntriesAsync([new(circle.Path, circle.Name, circle.Bytes, true, null, StorageCategory.Other)]));
                button.ContextMenu = menu;
            }
            BubbleCanvas.Children.Add(button);
        }
    }
}
