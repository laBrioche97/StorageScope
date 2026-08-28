using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace StorageScope.Windows;

public partial class MainWindow : Window
{
    private readonly ScanService _scanner = new();
    private readonly ObservableCollection<ScanEntry> _largestFiles = [];
    private readonly ObservableCollection<CategoryTile> _categories = [];
    private readonly ObservableCollection<CleanupCandidate> _cleanup = [];
    private readonly ObservableCollection<InstalledApplication> _applications = [];
    private readonly ObservableCollection<ScanEntry> _explorer = [];
    private List<ScanEntry> _allExplorerItems = [];
    private ScanResult? _result;
    private CancellationTokenSource? _scanCancellation;
    private CancellationTokenSource? _browseCancellation;
    private string? _currentDirectory;
    private long _recoverableBytes;

    public MainWindow()
    {
        InitializeComponent();
        LargestFilesGrid.ItemsSource = _largestFiles;
        CategoriesList.ItemsSource = _categories;
        CleanupGrid.ItemsSource = _cleanup;
        ApplicationsGrid.ItemsSource = _applications;
        ExplorerGrid.ItemsSource = _explorer;
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        RefreshDrives();
        try
        {
            var applications = await InstalledApplicationService.LoadAsync(CancellationToken.None);
            foreach (var application in applications) _applications.Add(application);
        }
        catch (Exception error) { ShowError("Les applications installées n’ont pas pu être inventoriées.", error); }
    }

    private void RefreshDrives()
    {
        var selectedRoot = (DrivePicker.SelectedItem as DriveChoice)?.Root;
        var drives = DriveInfo.GetDrives().Where(drive => drive.IsReady && drive.DriveType is DriveType.Fixed or DriveType.Removable)
            .Select(drive => new DriveChoice(drive)).ToList();
        DrivePicker.ItemsSource = drives;
        DrivePicker.SelectedItem = drives.FirstOrDefault(item => string.Equals(item.Root, selectedRoot, StringComparison.OrdinalIgnoreCase)) ?? drives.FirstOrDefault(item => item.Root.Equals(@"C:\", StringComparison.OrdinalIgnoreCase)) ?? drives.FirstOrDefault();
        UpdateVolumeHeader();
    }

    private async void ScanButton_Click(object sender, RoutedEventArgs e)
    {
        if (DrivePicker.SelectedItem is not DriveChoice drive) return;
        _scanCancellation?.Cancel();
        _scanCancellation = new CancellationTokenSource();
        SetScanning(true);
        ClearResults();
        ScanStatusText.Text = "Préparation de l’analyse…";
        ScanProgressBar.Value = 0;
        var progress = new Progress<ScanProgress>(value =>
        {
            ScanProgressBar.Value = value.Fraction * 100;
            ScanStatusText.Text = $"{value.Files:N0} fichiers · {SizeFormatter.Format(value.Bytes)} identifiés · {value.Errors:N0} refus — {value.CurrentPath}";
        });
        try
        {
            _result = await _scanner.ScanAsync(drive.Root, progress, _scanCancellation.Token);
            PopulateResult(_result);
            ScanStatusText.Text = $"Analyse terminée : {_result.FilesScanned:N0} fichiers, {_result.AccessErrors:N0} refus d’accès";
            await BrowseAsync(drive.Root);
        }
        catch (OperationCanceledException) { ScanStatusText.Text = "Analyse annulée"; }
        catch (Exception error)
        {
            ScanStatusText.Text = "L’analyse a échoué";
            ShowError("Impossible de terminer l’analyse.", error);
        }
        finally { SetScanning(false); RefreshSpaceStatus(); }
    }

    private void PopulateResult(ScanResult result)
    {
        _largestFiles.Clear();
        foreach (var item in result.LargestFiles) _largestFiles.Add(item);
        _categories.Clear();
        foreach (var category in result.Categories)
            _categories.Add(new CategoryTile(category, result.IdentifiedBytes == 0 ? 0 : category.Bytes * 100d / result.IdentifiedBytes));
        _cleanup.Clear();
        foreach (var candidate in result.CleanupCandidates) _cleanup.Add(candidate);
        IdentifiedText.Text = SizeFormatter.Format(result.IdentifiedBytes);
        FilesText.Text = result.FilesScanned.ToString("N0");
        DirectoriesText.Text = result.DirectoriesScanned.ToString("N0");
        ErrorsText.Text = result.AccessErrors.ToString("N0");
    }

    private void ClearResults()
    {
        _result = null;
        _largestFiles.Clear();
        _categories.Clear();
        _cleanup.Clear();
        _explorer.Clear();
        _allExplorerItems.Clear();
        IdentifiedText.Text = FilesText.Text = DirectoriesText.Text = ErrorsText.Text = "—";
    }

    private void SetScanning(bool scanning)
    {
        ScanButton.IsEnabled = !scanning;
        CancelButton.IsEnabled = scanning;
        DrivePicker.IsEnabled = !scanning;
        ScanProgressBar.IsIndeterminate = false;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) => _scanCancellation?.Cancel();
    private void RefreshButton_Click(object sender, RoutedEventArgs e) { RefreshDrives(); RefreshSpaceStatus(); }

    private async void DrivePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded || DrivePicker.SelectedItem is not DriveChoice drive) return;
        _scanCancellation?.Cancel();
        ClearResults();
        UpdateVolumeHeader();
        await BrowseAsync(drive.Root);
    }

    private void UpdateVolumeHeader()
    {
        if (DrivePicker.SelectedItem is not DriveChoice drive) return;
        VolumeTitle.Text = $"Vue d’ensemble — {drive.VolumeLabel}";
        RefreshSpaceStatus();
    }

    private void RefreshSpaceStatus()
    {
        if (DrivePicker.SelectedItem is not DriveChoice drive) return;
        try
        {
            drive.Refresh();
            SpaceStatusText.Text = $"{SizeFormatter.Format(drive.AvailableBytes)} disponibles" + (_recoverableBytes > 0 ? $" · {SizeFormatter.Format(_recoverableBytes)} récupérables après vidage de la Corbeille" : "");
        }
        catch { SpaceStatusText.Text = "Espace disponible inconnu"; }
    }

    private async Task BrowseAsync(string path)
    {
        _browseCancellation?.Cancel();
        _browseCancellation = new CancellationTokenSource();
        _currentDirectory = path;
        ExplorerPathBox.Text = path;
        try
        {
            var entries = await DirectoryBrowser.BrowseAsync(path, _result?.DirectorySizes, _browseCancellation.Token);
            _allExplorerItems = entries.ToList();
            ApplyExplorerFilter();
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { ShowError("Impossible d’ouvrir ce dossier.", error); }
    }

    private void ApplyExplorerFilter()
    {
        var query = ExplorerSearchBox.Text.Trim();
        _explorer.Clear();
        foreach (var item in _allExplorerItems.Where(item => query.Length == 0 || item.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase) || item.Path.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
            _explorer.Add(item);
    }

    private async void ExplorerGrid_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (ExplorerGrid.SelectedItem is ScanEntry { IsDirectory: true } item) await BrowseAsync(item.Path);
        else if (ExplorerGrid.SelectedItem is ScanEntry file) SafeOpen(file.Path);
    }

    private async void ParentButton_Click(object sender, RoutedEventArgs e)
    {
        if (_currentDirectory is null) return;
        var parent = Directory.GetParent(_currentDirectory)?.FullName;
        if (parent is not null) await BrowseAsync(parent);
    }

    private async void ExplorerPathBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Directory.Exists(ExplorerPathBox.Text)) await BrowseAsync(ExplorerPathBox.Text);
    }

    private void ExplorerSearchBox_TextChanged(object sender, TextChangedEventArgs e) => ApplyExplorerFilter();

    private void OpenSelection_Click(object sender, RoutedEventArgs e)
    {
        if (ExplorerGrid.SelectedItem is ScanEntry item) SafeOpen(item.Path);
    }

    private void RevealSelection_Click(object sender, RoutedEventArgs e)
    {
        if (ExplorerGrid.SelectedItem is ScanEntry item) ExplorerService.ShowInExplorer(item.Path);
    }

    private async void TrashSelection_Click(object sender, RoutedEventArgs e)
    {
        var selected = ExplorerGrid.SelectedItems.Cast<ScanEntry>().ToList();
        if (selected.Count == 0) return;
        await TrashEntriesAsync(selected);
    }

    private void RevealCleanup_Click(object sender, RoutedEventArgs e)
    {
        if (CleanupGrid.SelectedItem is CleanupCandidate candidate) ExplorerService.ShowInExplorer(candidate.Path);
    }

    private async void TrashCleanup_Click(object sender, RoutedEventArgs e)
    {
        var entries = CleanupGrid.SelectedItems.Cast<CleanupCandidate>()
            .Select(item => new ScanEntry(item.Path, item.Name, item.Size, item.IsDirectory, null, StorageCategory.CachesLogs)).ToList();
        if (entries.Count > 0) await TrashEntriesAsync(entries);
    }

    private async Task TrashEntriesAsync(List<ScanEntry> entries)
    {
        var bytes = entries.Sum(item => item.Size);
        var answer = MessageBox.Show($"Déplacer {entries.Count:N0} élément(s) ({SizeFormatter.Format(bytes)}) vers la Corbeille ?\n\nL’espace ne sera réellement libéré qu’après avoir vidé la Corbeille.", "Confirmer la mise à la Corbeille", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (answer != MessageBoxResult.Yes) return;
        try
        {
            await Task.Run(() => RecycleBinService.MoveToRecycleBin(entries));
            _recoverableBytes += bytes;
            if (_currentDirectory is not null) await BrowseAsync(_currentDirectory);
            foreach (var entry in entries)
            {
                var cleanup = _cleanup.FirstOrDefault(item => string.Equals(item.Path, entry.Path, StringComparison.OrdinalIgnoreCase));
                if (cleanup is not null) _cleanup.Remove(cleanup);
            }
            RefreshSpaceStatus();
        }
        catch (Exception error) { ShowError("Certains éléments n’ont pas pu être déplacés vers la Corbeille.", error); }
    }

    private void UninstallApplication_Click(object sender, RoutedEventArgs e)
    {
        if (ApplicationsGrid.SelectedItem is not InstalledApplication application) return;
        if (MessageBox.Show($"Lancer le désinstalleur officiel de « {application.Name} » ?\n\nStorageScope ne supprimera aucun fichier directement.", "Désinstaller une application", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        try { InstalledApplicationService.LaunchOfficialUninstaller(application); }
        catch (Exception error) { ShowError("Le désinstalleur officiel n’a pas pu être lancé.", error); }
    }

    private static void SafeOpen(string path)
    {
        try { ExplorerService.Open(path); }
        catch (Exception error) { MessageBox.Show(error.Message, "Impossible d’ouvrir l’élément", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private static void ShowError(string title, Exception error) => MessageBox.Show($"{title}\n\n{error.Message}", "StorageScope", MessageBoxButton.OK, MessageBoxImage.Error);
}

public sealed class DriveChoice
{
    private readonly DriveInfo _drive;
    public DriveChoice(DriveInfo drive) => _drive = drive;
    public string Root => _drive.RootDirectory.FullName;
    public long AvailableBytes => _drive.AvailableFreeSpace;
    public string VolumeLabel => string.IsNullOrWhiteSpace(_drive.VolumeLabel) ? $"Disque local ({Root.TrimEnd('\\')})" : $"{_drive.VolumeLabel} ({Root.TrimEnd('\\')})";
    public string FreeLabel => $"{SizeFormatter.Format(_drive.AvailableFreeSpace)} libres";
    public void Refresh() => _drive.Refresh();
}
