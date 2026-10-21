using System.Collections;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;

namespace StorageScope.Windows;

public partial class MainWindow
{
    private bool _viewsReady;
    private bool _syncCategory;
    private bool _compactFiltersOpen;
    private sealed record FilterState(string Search = "", int Category = 0, int Size = 0, int Kind = 0, int Sort = 0, string Source = "Toutes les sources");
    private enum Section { Applications, Overview, Explorer, Categories, Cleanup }
    private Section CurrentSection => Enum.TryParse<Section>((MainTabs.SelectedItem as TabItem)?.Tag as string, out var section) ? section : Section.Applications;
    private readonly Dictionary<Section, FilterState> _sectionFilters = [];
    private Section _filterSection = Section.Applications;
    private FilterState CaptureFilter() => new(ListSearch.Text, CategoryFilter.SelectedIndex, MinimumSizeFilter.SelectedIndex, EntryKindFilter.SelectedIndex, ResultSort.SelectedIndex, ApplicationSourceFilter.SelectedItem as string ?? "Toutes les sources");
    private DisplayFilter SectionFilter(Section section)
    {
        if (section == CurrentSection) return CurrentDisplayFilter;
        var state = _sectionFilters.GetValueOrDefault(section) ?? new();
        return new(state.Search, (CategoryFilter.Items[Math.Max(0, state.Category)] as CategoryChoice)?.Category,
            (MinimumSizeFilter.Items[Math.Max(0, state.Size)] as SizeChoice)?.Bytes ?? 0,
            (EntryKindFilter.Items[Math.Max(0, state.Kind)] as KindChoice)?.Kind ?? EntryKind.All);
    }
    private void MainTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_viewsReady || e.Source != MainTabs || CurrentSection == _filterSection) return;
        _sectionFilters[_filterSection] = CaptureFilter();
        _filterSection = CurrentSection;
        var state = _sectionFilters.GetValueOrDefault(_filterSection) ?? new();
        _viewsReady = false;
        try
        {
            ListSearch.Text = state.Search; CategoryFilter.SelectedIndex = state.Category; MinimumSizeFilter.SelectedIndex = state.Size;
            EntryKindFilter.SelectedIndex = state.Kind; ResultSort.SelectedIndex = state.Sort;
            ApplicationSourceFilter.SelectedItem = state.Source;
        }
        finally { _viewsReady = true; }
        ApplyDisplayFilters();
        if (CurrentSection == Section.Explorer && !IsPreviewMode) _ = EnterExplorerAsync();
        UpdateBubbleFilters();
        UpdateResponsiveColumns();
        RefreshSectionHeading();
    }

    private void InitializeDisplayFilters()
    {
        CategoryFilter.ItemsSource = new[] { new CategoryChoice("Toutes les catégories", null) }.Concat(Enum.GetValues<StorageCategory>().Select(category => new CategoryChoice(CategoryLabels.Name(category), category))).ToArray();
        CategoryFilter.SelectedIndex = 0;
        MinimumSizeFilter.ItemsSource = new[] { new SizeChoice("Toutes les tailles", 0), new SizeChoice("Au moins 10 Mo", 10L * 1024 * 1024), new SizeChoice("Au moins 100 Mo", 100L * 1024 * 1024), new SizeChoice("Au moins 1 Go", 1024L * 1024 * 1024) };
        MinimumSizeFilter.SelectedIndex = 0;
        EntryKindFilter.ItemsSource = new[] { new KindChoice("Fichiers et dossiers", EntryKind.All), new KindChoice("Fichiers seulement", EntryKind.Files), new KindChoice("Dossiers seulement", EntryKind.Directories) };
        EntryKindFilter.SelectedIndex = 0;
        ResultSort.ItemsSource = new[] { new SortChoice("Taille décroissante", ResultOrder.Largest), new SortChoice("Taille croissante", ResultOrder.Smallest), new SortChoice("Nom : A à Z", ResultOrder.Name) };
        ResultSort.SelectedIndex = 0;
        ApplicationSourceFilter.ItemsSource = new[] { "Toutes les sources" }; ApplicationSourceFilter.SelectedIndex = 0;
        PopulateCategorySummary(null);
        foreach (var grid in new[] { LargestFilesGrid, ExplorerGrid, CategoryFilesGrid, CleanupGrid, ApplicationsGrid }) grid.CanUserSortColumns = false;
        _viewsReady = true;
        ApplyDisplayFilters();
    }

    private DisplayFilter CurrentDisplayFilter => new(ListSearch.Text, (CategoryFilter.SelectedItem as CategoryChoice)?.Category,
        (MinimumSizeFilter.SelectedItem as SizeChoice)?.Bytes ?? 0, (EntryKindFilter.SelectedItem as KindChoice)?.Kind ?? EntryKind.All);

    private void PopulateCategorySummary(ScanResult? result)
    {
        _syncCategory = true;
        CategorySummary.ItemsSource = new[] { new CategoryChoice("Toutes les catégories — fichiers classés par taille", null) }.Concat(result?.Categories.Select(category => new CategoryChoice($"{category.Name} — {category.DisplaySize} · {category.Details}", category.Category)) ?? []);
        CategorySummary.SelectedItem = CategorySummary.Items.OfType<CategoryChoice>().FirstOrDefault(item => item.Category == (CategoryFilter.SelectedItem as CategoryChoice)?.Category) ?? CategorySummary.Items[0];
        _syncCategory = false;
    }

    private void ApplyDisplayFilters()
    {
        if (!_viewsReady) return;
        var filter = CurrentDisplayFilter;
        var source = ApplicationSourceFilter.SelectedItem as string;
        var active = (filter.Category is null ? 0 : 1) + (filter.MinimumBytes == 0 ? 0 : 1) + (filter.Kind == EntryKind.All ? 0 : 1) + (source is null or "Toutes les sources" ? 0 : 1);
        FilterToggleButton.Content = active == 0 ? "Filtres" : $"Filtres ({active})";
        void Refresh(IEnumerable items, Predicate<object> predicate, Section section, bool applications = false)
        {
            var order = section == CurrentSection ? (ResultSort.SelectedItem as SortChoice)?.Order ?? ResultOrder.Largest
                : (ResultSort.Items[(_sectionFilters.GetValueOrDefault(section) ?? new()).Sort] as SortChoice)?.Order ?? ResultOrder.Largest;
            var view = CollectionViewSource.GetDefaultView(items);
            using (view.DeferRefresh())
            {
                view.Filter = predicate;
                view.SortDescriptions.Clear();
                if (order != ResultOrder.Name)
                {
                    if (applications) view.SortDescriptions.Add(new(nameof(InstalledApplication.HasKnownSize), ListSortDirection.Descending));
                    view.SortDescriptions.Add(new(applications ? nameof(InstalledApplication.SortSize) : nameof(ScanEntry.Size), order == ResultOrder.Smallest ? ListSortDirection.Ascending : ListSortDirection.Descending));
                }
                view.SortDescriptions.Add(new("Name", ListSortDirection.Ascending));
            }
        }
        var overviewFilter = SectionFilter(Section.Overview);
        var explorerFilter = SectionFilter(Section.Explorer);
        var categoryFilter = SectionFilter(Section.Categories);
        var cleanupFilter = SectionFilter(Section.Cleanup);
        var applicationFilter = SectionFilter(Section.Applications);
        Refresh(_largestFiles, item => item is ScanEntry entry && overviewFilter.Matches(entry), Section.Overview);
        Refresh(_explorer, item => item is ScanEntry entry && explorerFilter.Matches(entry), Section.Explorer);
        Refresh(_categoryFiles, item => item is ScanEntry entry && categoryFilter.Matches(entry), Section.Categories);
        Refresh(_cleanup, item => item is CleanupCandidate candidate && cleanupFilter.Matches(candidate), Section.Cleanup);
        var appSource = CurrentSection == Section.Applications ? source : (_sectionFilters.GetValueOrDefault(Section.Applications) ?? new()).Source;
        Refresh(_applications, item => item is InstalledApplication app && applicationFilter.Matches(app) && (appSource is null or "Toutes les sources" || app.Provider == appSource), Section.Applications, true);
        RefreshSectionHeading();
        var count = CategoryFilesGrid.Items.OfType<ScanEntry>().Count();
        var total = _result?.Categories.Where(category => categoryFilter.Category is null || category.Category == categoryFilter.Category).Sum(category => category.FileCount) ?? 0;
        CategoryStatusText.Text = $"{(categoryFilter.Category is StorageCategory category ? CategoryLabels.Name(category) : "Toutes les catégories")} · {count:N0} affiché(s) / {total:N0} détecté(s) · 500 plus gros fichiers maximum par catégorie." + (count == 0 ? (_result is null ? " Lancez une analyse pour voir les fichiers." : " Aucun résultat : modifiez les filtres.") : "");
        if (!_syncCategory)
        {
            _syncCategory = true;
            CategorySummary.SelectedItem = CategorySummary.Items.OfType<CategoryChoice>().FirstOrDefault(item => item.Category == categoryFilter.Category);
            _syncCategory = false;
        }
    }

    private void ListSearch_Changed(object sender, TextChangedEventArgs e) { ApplyDisplayFilters(); RenderBubbles(); }
    private void DisplayFilter_Changed(object sender, SelectionChangedEventArgs e) => ApplyDisplayFilters();
    private void ShowFilters_Click(object sender, RoutedEventArgs e) { _compactFiltersOpen = !_compactFiltersOpen; ExtraFilters.Visibility = Visibility.Visible; UpdateResponsiveColumns(); }
    private void ToggleFilters_Click(object sender, RoutedEventArgs e) { if (ActualHeight < 620) ShowFilters_Click(sender, e); else ExtraFilters.Visibility = ExtraFilters.IsVisible ? Visibility.Collapsed : Visibility.Visible; }
    private void ResetFilters_Click(object sender, RoutedEventArgs e)
    {
        ListSearch.Clear(); CategoryFilter.SelectedIndex = MinimumSizeFilter.SelectedIndex = EntryKindFilter.SelectedIndex = ResultSort.SelectedIndex = ApplicationSourceFilter.SelectedIndex = 0;
        ApplyDisplayFilters();
        _compactFiltersOpen = false; UpdateResponsiveColumns();
    }
    private void CategorySummary_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!_viewsReady || _syncCategory || CategorySummary.SelectedItem is not CategoryChoice selected) return;
        MainTabs.SelectedItem = CategoriesTab;
        _syncCategory = true;
        ListSearch.Clear(); MinimumSizeFilter.SelectedIndex = EntryKindFilter.SelectedIndex = 0;
        CategoryFilter.SelectedItem = CategoryFilter.Items.OfType<CategoryChoice>().First(item => item.Category == selected.Category);
        ResultSort.SelectedIndex = 0;
        _syncCategory = false;
        ApplyDisplayFilters();
    }
    private void CategoryHeader_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || button.DataContext is not CollectionViewGroup group) return;
        CategorySummary.SelectedItem = CategorySummary.Items.OfType<CategoryChoice>().FirstOrDefault(item => item.Category is StorageCategory category && CategoryLabels.Name(category) == group.Name?.ToString());
    }
    private void RevealCategory_Click(object sender, RoutedEventArgs e) { if (CategoryFilesGrid.SelectedItem is ScanEntry entry) SafeReveal(entry.Path); }
}
