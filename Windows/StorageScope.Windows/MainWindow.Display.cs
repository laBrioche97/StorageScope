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
        var order = (ResultSort.SelectedItem as SortChoice)?.Order ?? ResultOrder.Largest;
        var source = ApplicationSourceFilter.SelectedItem as string;
        var active = (filter.Category is null ? 0 : 1) + (filter.MinimumBytes == 0 ? 0 : 1) + (filter.Kind == EntryKind.All ? 0 : 1) + (source is null or "Toutes les sources" ? 0 : 1);
        FilterToggleButton.Content = active == 0 ? "Filtres" : $"Filtres ({active})";
        void Refresh(IEnumerable items, Predicate<object> predicate, bool applications = false)
        {
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
        Refresh(_largestFiles, item => item is ScanEntry entry && filter.Matches(entry));
        Refresh(_explorer, item => item is ScanEntry entry && filter.Matches(entry));
        Refresh(_categoryFiles, item => item is ScanEntry entry && filter.Matches(entry));
        Refresh(_cleanup, item => item is CleanupCandidate candidate && filter.Matches(candidate));
        Refresh(_applications, item => item is InstalledApplication app && filter.Matches(app) && (source is null or "Toutes les sources" || app.Provider == source), true);
        if (!_syncCategory)
        {
            _syncCategory = true;
            CategorySummary.SelectedItem = CategorySummary.Items.OfType<CategoryChoice>().FirstOrDefault(item => item.Category == filter.Category);
            _syncCategory = false;
        }
    }

    private void ListSearch_Changed(object sender, TextChangedEventArgs e) => ApplyDisplayFilters();
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
        CategoryFilter.SelectedItem = CategoryFilter.Items.OfType<CategoryChoice>().First(item => item.Category == selected.Category);
        ResultSort.SelectedIndex = 0;
    }
    private void RevealCategory_Click(object sender, RoutedEventArgs e) { if (CategoryFilesGrid.SelectedItem is ScanEntry entry) ExplorerService.ShowInExplorer(entry.Path); }
}
