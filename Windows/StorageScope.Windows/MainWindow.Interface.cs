using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace StorageScope.Windows;

public partial class MainWindow
{
    private bool _navigationCollapsed;
    private string? _highlightedExplorerPath;
    private readonly List<string> _browseHistory = [];
    private int _historyPosition = -1;
    internal Func<string?>? DuplicateDirectoryPicker { get; set; }
    private void InitializeInterface()
    {
        Title = AppIdentity.Title;
        SectionNavigation.SelectedIndex = 0;
        RefreshSectionHeading();
    }
    private void SectionNavigation_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!_viewsReady || SectionNavigation.SelectedItem is not ListBoxItem selected) return;
        MainTabs.SelectedItem = MainTabs.Items.OfType<TabItem>().FirstOrDefault(tab => Equals(tab.Tag, selected.Tag));
    }
    private void ToggleNavigation_Click(object sender, RoutedEventArgs e)
    {
        _navigationCollapsed = !_navigationCollapsed;
        UpdateNavigationLayout();
    }
    private void UpdateNavigationLayout()
    {
        if (SectionNavigation is null) return;
        var compact = _navigationCollapsed || ActualWidth < 1050;
        NavigationColumn.Width = new GridLength(compact ? 64 : 190);
        foreach (var item in SectionNavigation.Items.OfType<ListBoxItem>())
            if (item.Content is StackPanel panel && panel.Children.Count > 1)
                panel.Children[1].Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
    }
    private void RefreshSectionHeading()
    {
        if (SectionHeading is null) return;
        SectionHeading.Text = (MainTabs.SelectedItem as TabItem)?.Header?.ToString() ?? "Applications et jeux";
        var count = CurrentSection switch
        {
            Section.Applications => ApplicationsGrid.Items.Count,
            Section.Overview => LargestFilesGrid.Items.Count,
            Section.Explorer => ExplorerGrid.Items.Count,
            Section.Categories => CategoryFilesGrid.Items.Count,
            _ => CleanupGrid.Items.Count
        };
        SectionSummary.Text = count == 0 ? CurrentSection switch
        {
            Section.Applications => _inventoryCancellation is not null ? "Recherche des applications et jeux…" : "Aucune application affichée. Actualisez l’inventaire ou effacez les filtres.",
            Section.Explorer => "Ouvrez un dossier ou lancez l’analyse pour comparer les tailles.",
            _ => _result is null ? "Analysez le disque pour afficher les résultats." : "Aucun résultat affiché. Vérifiez les filtres."
        } : $"{count:N0} élément(s) affiché(s)";
        RefreshApplicationsButton.Visibility = CurrentSection == Section.Applications ? Visibility.Visible : Visibility.Collapsed;
        foreach (var item in SectionNavigation.Items.OfType<ListBoxItem>())
            if (Equals(item.Tag, (MainTabs.SelectedItem as TabItem)?.Tag)) SectionNavigation.SelectedItem = item;
    }
    private void OverviewCategory_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.DataContext is not CategoryResult category) return;
        MainTabs.SelectedItem = CategoriesTab;
        ResetFilters_Click(this, new());
        CategoryFilter.SelectedItem = CategoryFilter.Items.OfType<CategoryChoice>().First(item => item.Category == category.Category);
    }
    private void SetExplorerLoading(bool loading, string message = "Lecture du dossier…")
    {
        ExplorerLoader.Message = message;
        ExplorerLoadingPanel.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
    }
    private void CancelExplorer_Click(object sender, RoutedEventArgs e)
    {
        _browseCancellation?.Cancel(); _bubbleCancellation?.Cancel(); _scanCancellation?.Cancel();
        ++_browseGeneration; ++_bubbleGeneration;
        SetExplorerLoading(false); BubbleStatus.Text = "Chargement annulé. Cliquez sur Analyser le disque ou ouvrez un dossier pour reprendre.";
    }
    private async void ExplorerBack_Click(object sender, RoutedEventArgs e) => await BrowseHistoryAsync(-1);
    private async void ExplorerForward_Click(object sender, RoutedEventArgs e) => await BrowseHistoryAsync(1);
    private async Task BrowseHistoryAsync(int direction)
    {
        var position = _historyPosition + direction;
        if (position < 0 || position >= _browseHistory.Count) return;
        _historyPosition = position; await BrowseAsync(_browseHistory[position], false);
    }
    private void RecordBrowse(string path)
    {
        if (_historyPosition >= 0 && string.Equals(_browseHistory[_historyPosition], path, StringComparison.OrdinalIgnoreCase)) return;
        _browseHistory.RemoveRange(_historyPosition + 1, _browseHistory.Count - _historyPosition - 1);
        _browseHistory.Add(path); _historyPosition = _browseHistory.Count - 1;
    }
    private void ExplorerSelection_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (ExplorerGrid.SelectedItem is not ScanEntry entry) return;
        HighlightExplorer(entry.Path);
        BubbleStatus.Text = $"{entry.Name} · {entry.DisplaySize}\n{entry.Path}" + (entry.IsDirectory ? "\nCliquez sur sa bulle ou double-cliquez pour ouvrir ce dossier." : "\nClic droit : ouvrir, afficher l’emplacement ou mettre à la corbeille.");
    }
    private void HighlightExplorer(string? path)
    {
        var old = _allExplorerItems.FirstOrDefault(item => item.Path == _highlightedExplorerPath);
        if (old is not null && ExplorerGrid.ItemContainerGenerator.ContainerFromItem(old) is DataGridRow previous) previous.ClearValue(Control.BackgroundProperty);
        _highlightedExplorerPath = path;
        var highlighted = _allExplorerItems.FirstOrDefault(item => item.Path == path);
        if (highlighted is not null && ExplorerGrid.ItemContainerGenerator.ContainerFromItem(highlighted) is DataGridRow row) row.SetResourceReference(Control.BackgroundProperty, "PanelBrush");
        foreach (var button in BubbleCanvas.Children.OfType<BubbleButton>())
        {
            button.Highlighted = button.Circle.Path == path || !string.IsNullOrWhiteSpace(ListSearch.Text) && button.Circle.Name.Contains(ListSearch.Text, StringComparison.CurrentCultureIgnoreCase);
            button.InvalidateVisual();
        }
    }
    private void ExplorerRow_Loading(object sender, DataGridRowEventArgs e)
    {
        e.Row.MouseEnter -= ExplorerRow_MouseEnter; e.Row.MouseEnter += ExplorerRow_MouseEnter;
        e.Row.MouseLeave -= ExplorerRow_MouseLeave; e.Row.MouseLeave += ExplorerRow_MouseLeave;
    }
    private void ExplorerRow_MouseEnter(object sender, System.Windows.Input.MouseEventArgs e) { if ((sender as DataGridRow)?.Item is ScanEntry entry) HighlightExplorer(entry.Path); }
    private void ExplorerRow_MouseLeave(object sender, System.Windows.Input.MouseEventArgs e) => HighlightExplorer((ExplorerGrid.SelectedItem as ScanEntry)?.Path);
    private void LayoutExplorer()
    {
        if (ExplorerSplit is null) return;
        var stacked = ExplorerSplit.ActualWidth is > 0 and < 540 && _bubbleMode;
        ExplorerGrid.Columns[2].Visibility = _bubbleMode ? Visibility.Collapsed : Visibility.Visible;
        ExplorerGrid.Columns[3].Visibility = !_bubbleMode && ActualWidth >= 1000 ? Visibility.Visible : Visibility.Collapsed;
        ExplorerGrid.Columns[4].Visibility = !_bubbleMode && ActualWidth >= 1100 ? Visibility.Visible : Visibility.Collapsed;
        ExplorerSplit.ColumnDefinitions[1].Width = new GridLength(_bubbleMode && !stacked ? 1.2 : 0, GridUnitType.Star);
        ExplorerSplit.RowDefinitions[0].Height = new GridLength(1, GridUnitType.Star);
        ExplorerSplit.RowDefinitions[1].Height = new GridLength(stacked ? 1 : 0, GridUnitType.Star);
        Grid.SetColumn(BubblePanel, stacked ? 0 : 1); Grid.SetRow(BubblePanel, 0);
        Grid.SetColumn(ExplorerGrid, 0); Grid.SetRow(ExplorerGrid, stacked ? 1 : 0);
        BubblePanel.Visibility = _bubbleMode ? Visibility.Visible : Visibility.Collapsed;
        ExplorerGrid.Visibility = Visibility.Visible;
        BubblePanel.Margin = new Thickness(stacked ? 0 : 12, 8, 0, 8);
        Grid.SetColumn(ExplorerLoadingPanel, stacked || !_bubbleMode ? 0 : 1);
        Grid.SetColumnSpan(ExplorerLoadingPanel, 1); Grid.SetRowSpan(ExplorerLoadingPanel, 1);
    }
}
