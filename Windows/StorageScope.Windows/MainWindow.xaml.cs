using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Data;
using System.Diagnostics;
using Microsoft.Win32;

namespace StorageScope.Windows;

public partial class MainWindow : Window
{
    private readonly ScanService _scanner = new();
    private readonly ObservableCollection<ScanEntry> _largestFiles = [];
    private readonly ObservableCollection<ScanEntry> _categoryFiles = [];
    private readonly ObservableCollection<CleanupCandidate> _cleanup = [];
    private readonly ObservableCollection<InstalledApplication> _applications = [];
    private readonly ObservableCollection<ScanEntry> _explorer = [];
    private List<ScanEntry> _allExplorerItems = [];
    private ScanResult? _result;
    private CancellationTokenSource? _scanCancellation;
    private CancellationTokenSource? _browseCancellation;
    private string? _currentDirectory;
    private long _recoverableBytes;
    private readonly InstalledProductCatalog _products = new();
    private readonly UpdateService _updates = new();
    private CancellationTokenSource? _operationCancellation;
    private IReadOnlyList<InstalledApplication> _allApplications = [];
    private UpdateManifest? _availableUpdate;
    private bool _busy;
    internal bool IsPreviewMode { get; set; }

    public MainWindow()
    {
        InitializeComponent();
        LargestFilesGrid.ItemsSource = _largestFiles;
        CategoryFilesGrid.ItemsSource = _categoryFiles;
        CleanupGrid.ItemsSource = _cleanup;
        ApplicationsGrid.ItemsSource = _applications;
        ExplorerGrid.ItemsSource = _explorer;
        CollectionViewSource.GetDefaultView(_cleanup).GroupDescriptions.Add(new PropertyGroupDescription(nameof(CleanupCandidate.Group)));
        CollectionViewSource.GetDefaultView(_categoryFiles).GroupDescriptions.Add(new PropertyGroupDescription(nameof(ScanEntry.CategoryName)));
        InitializeDisplayFilters();
        SizeChanged += (_, _) => UpdateResponsiveColumns();
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        if (IsPreviewMode) return;
        RefreshDrives();
        try
        {
            await ReloadApplicationsAsync();
        }
        catch (Exception error) { ShowError("Les applications installées n’ont pas pu être inventoriées.", error); }
        _ = CheckForUpdatesAsync(false);
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
            ScanStatusText.Text = $"Analyse {(_result.AccessErrors > 0 ? "partielle" : "terminée")} : {_result.FilesScanned:N0} fichiers · {_result.AccessErrors:N0} accès non disponibles" + (_result.CleanupTruncated ? " · suggestions limitées à 10 000 éléments" : "") + " · Choisissez Nettoyage conseillé pour continuer.";
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
        _categoryFiles.Clear();
        foreach (var item in result.CategoryFiles.Values.SelectMany(items => items)) _categoryFiles.Add(item);
        PopulateCategorySummary(result);
        _cleanup.Clear();
        foreach (var candidate in result.CleanupCandidates) _cleanup.Add(candidate);
        IdentifiedText.Text = SizeFormatter.Format(result.IdentifiedBytes);
        FilesText.Text = result.FilesScanned.ToString("N0");
        DirectoriesText.Text = result.DirectoriesScanned.ToString("N0");
        ErrorsText.Text = result.AccessErrors.ToString("N0");
        ApplyApplicationFilter();
    }

    private void ClearResults()
    {
        _result = null;
        _largestFiles.Clear();
        _categoryFiles.Clear();
        PopulateCategorySummary(null);
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
        MainTabs.IsEnabled = !scanning;
        InstallUpdateButton.IsEnabled = !scanning;
    }

    private void UpdateResponsiveColumns()
    {
        if (LargestFilesGrid is null) return;
        CheckUpdateButton.Visibility = HistoryButton.Visibility = ActualWidth >= 950 ? Visibility.Visible : Visibility.Collapsed;
        OptionsButton.Visibility = ActualWidth < 950 ? Visibility.Visible : Visibility.Collapsed;
        ApplicationTitle.Visibility = WorkflowSteps.Visibility = ActualHeight >= 760 ? Visibility.Visible : Visibility.Collapsed;
        StatusPanel.Visibility = PrivacyFooter.Visibility = ActualHeight >= 620 ? Visibility.Visible : Visibility.Collapsed;
        CompactStatus.Visibility = ActualHeight < 620 ? Visibility.Visible : Visibility.Collapsed;
        CleanupIntro.Visibility = ActualHeight >= 620 ? Visibility.Visible : Visibility.Collapsed;
        DisplayFilterPanel.Visibility = ActualHeight >= 620 || _compactFiltersOpen ? Visibility.Visible : Visibility.Collapsed;
        void Show(DataGrid grid, int column, bool visible) { grid.Columns[column].Visibility = visible ? Visibility.Visible : Visibility.Collapsed; }
        Show(LargestFilesGrid, 3, ActualWidth >= 1000);
        Show(ExplorerGrid, 4, ActualWidth >= 1100);
        Show(ExplorerGrid, 3, ActualWidth >= 1000);
        Show(ExplorerGrid, 2, ActualWidth >= 850);
        Show(CleanupGrid, 3, ActualWidth >= 1000);
        Show(CleanupGrid, 4, ActualWidth >= 1250);
        Show(ApplicationsGrid, 4, ActualWidth >= 1150);
        Show(ApplicationsGrid, 3, ActualWidth >= 1000);
        Show(ApplicationsGrid, 1, ActualWidth >= 850);
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) { _scanCancellation?.Cancel(); _operationCancellation?.Cancel(); }
    private async void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        RefreshDrives(); RefreshSpaceStatus();
        try { await ReloadApplicationsAsync(); } catch (Exception error) { ShowError("Inventaire indisponible.", error); }
    }

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
            SpaceStatusText.Text = $"{SizeFormatter.Format(drive.AvailableBytes)} libres";
            SpaceStatusText.ToolTip = _recoverableBytes > 0 ? $"{SizeFormatter.Format(_recoverableBytes)} déplacés vers la Corbeille pendant cette session. L’espace dépend du vidage de la Corbeille." : "Espace libre mesuré sur le disque.";
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
        var candidates = CleanupGrid.SelectedItems.Cast<CleanupCandidate>().ToList();
        var entries = candidates
            .Select(item => new ScanEntry(item.Path, item.Name, item.Size, item.IsDirectory, null, StorageCategory.CachesLogs)).ToList();
        if (entries.Count > 0) await TrashEntriesAsync(entries, candidates);
    }

    private async Task TrashEntriesAsync(List<ScanEntry> entries, IReadOnlyList<CleanupCandidate>? candidates = null)
    {
        if (_busy || _scanCancellation is { IsCancellationRequested: false } && !ScanButton.IsEnabled) return;
        SetBusy(true);
        _operationCancellation = new();
        try
        {
            ScanStatusText.Text = "Vérification des chemins et de l’identité des éléments…";
            var preparation = await Task.Run(() => CleanupOperations.Prepare(entries,candidates,_operationCancellation.Token),_operationCancellation.Token);
            var selection = preparation.Ready;
            if (selection.Count == 0)
            {
                MessageBox.Show("Aucun élément ne peut être traité. Aucun fichier n’a été supprimé.\n\n" + string.Join("\n",preparation.Skipped.Take(5).Select(item => Path.GetFileName(item.Path) + " : " + item.Error)),"Vérification du nettoyage");
                return;
            }
            var bytes = selection.Sum(item => item.Entry.Size);
            var preview = string.Join("\n", selection.Take(8).Select(item => "• " + item.Entry.Name));
            var answer = MessageBox.Show($"Déplacer {selection.Count:N0} élément(s) (jusqu’à {SizeFormatter.Format(bytes)}) vers la Corbeille ?\n\n{preview}" + (selection.Count > 8 ? $"\n… et {selection.Count - 8} autres." : "") + (preparation.Skipped.Count > 0 ? $"\n\n{preparation.Skipped.Count} élément(s) modifié(s) ou protégé(s) sont exclus. Leur détail apparaîtra dans le bilan." : "") + "\n\nRestauration possible depuis la Corbeille. L’espace ne sera réellement libéré qu’après son vidage. Aucune suppression définitive automatique.", "3. Vérifier le nettoyage", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (answer != MessageBoxResult.Yes) return;
            var executed = await CleanupOperations.ExecuteAsync(selection, new Progress<int>(count =>
            {
                ScanStatusText.Text = $"4. Nettoyage : {count} / {selection.Count}";
                ScanProgressBar.Value = count * 100d / selection.Count;
            }), _operationCancellation.Token);
            var result = executed.Concat(preparation.Skipped).ToList();
            foreach (var skipped in preparation.Skipped) { try { OperationHistory.Append(skipped); } catch (IOException) { } }
            var succeeded = result.Where(item => item.Status == "corbeille").ToList();
            _recoverableBytes += succeeded.Sum(item => item.Bytes);
            if (_currentDirectory is not null) await BrowseAsync(_currentDirectory);
            foreach (var item in succeeded)
            {
                foreach (var candidate in _cleanup.Where(candidate => DeletionSafetyPolicy.IsWithin(candidate.Path, item.Path)).ToList()) _cleanup.Remove(candidate);
            }
            var failures = result.Where(item => item.Status != "corbeille").ToList();
            var historyWarnings = result.Where(item => item.Status == "corbeille" && item.Error is not null).ToList();
            ScanStatusText.Text = $"Nettoyage terminé : {succeeded.Count} déplacé(s), {failures.Count} non traité(s).";
            MessageBox.Show($"{succeeded.Count} élément(s) dans la Corbeille · jusqu’à {SizeFormatter.Format(succeeded.Sum(item => item.Bytes))} récupérables après vidage.\n\n" + (failures.Count == 0 ? "Tous les éléments sélectionnés ont été traités." : string.Join("\n", failures.Take(8).Select(item => Path.GetFileName(item.Path) + " : " + (item.Error ?? item.Status)))) + (historyWarnings.Count > 0 ? "\n\nCertains résultats n’ont pas pu être ajoutés à l’historique ; les éléments concernés sont bien dans la Corbeille." : "\n\nLe détail est disponible dans l’historique local."), "Bilan du nettoyage", MessageBoxButton.OK, failures.Count == 0 ? MessageBoxImage.Information : MessageBoxImage.Warning);
            RefreshSpaceStatus();
        }
        catch (OperationCanceledException) { ScanStatusText.Text = "Vérification annulée."; }
        catch (Exception error) { ShowError("Le nettoyage a été interrompu. Consultez l’historique pour les éléments déjà traités.", error); }
        finally { SetBusy(false); _operationCancellation.Dispose(); _operationCancellation = null; }
    }

    private async void UninstallApplication_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || ApplicationsGrid.SelectedItem is not InstalledApplication application) return;
        var provider = _products.ProviderFor(application);
        var plan = provider.Prepare(application);
        if (!plan.CanProceed) { MessageBox.Show(plan.Explanation, "Désinstallation indisponible", MessageBoxButton.OK, MessageBoxImage.Information); return; }
        if (MessageBox.Show($"Désinstaller « {application.Name} » ?\n\n{plan.Explanation}\n\nStorageScope ne supprime ni sauvegardes ni bibliothèques partagées.", "Vérifier la désinstallation", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        SetBusy(true); _operationCancellation = new();
        try
        {
            ScanStatusText.Text = "Désinstallation officielle en cours…";
            var result = await provider.ExecuteAsync(plan, _operationCancellation.Token);
            if (result.Verified)
            {
                var residuals = await GameResiduals.FindAsync(application);
                foreach (var residual in residuals) _cleanup.Add(residual);
                if (residuals.Count > 0) MessageBox.Show($"{residuals.Count} cache(s) attribué(s) à ce jeu peuvent être examinés dans Nettoyage conseillé. Les sauvegardes restent conservées.", "Résidus du jeu");
            }
            MessageBox.Show(result.Message, result.Verified ? "Désinstallation confirmée" : "Vérification nécessaire", MessageBoxButton.OK, result.Verified ? MessageBoxImage.Information : MessageBoxImage.Warning);
            await ReloadApplicationsAsync();
            RefreshSpaceStatus();
            ScanStatusText.Text = result.Verified ? "Désinstallation confirmée." : "Terminez l’étape officielle puis actualisez l’inventaire.";
        }
        catch (Exception error) { ShowError("La désinstallation n’a pas pu être confirmée.", error); }
        finally { SetBusy(false); _operationCancellation.Dispose(); _operationCancellation = null; }
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        MainTabs.IsEnabled = !busy;
        ScanButton.IsEnabled = !busy;
        DrivePicker.IsEnabled = !busy;
        CancelButton.IsEnabled = busy;
        InstallUpdateButton.IsEnabled = !busy;
    }
    private async Task ReloadApplicationsAsync()
    {
        _allApplications = await _products.DetectAsync(CancellationToken.None);
        var selectedSource = ApplicationSourceFilter.SelectedItem as string;
        ApplicationSourceFilter.ItemsSource = new[] { "Toutes les sources" }.Concat(_allApplications.Select(item => item.Provider).Distinct().Order());
        ApplicationSourceFilter.SelectedItem = selectedSource is not null && _allApplications.Any(item => item.Provider == selectedSource) ? selectedSource : "Toutes les sources";
        ApplyApplicationFilter();
    }
    private void ApplyApplicationFilter()
    {
        _applications.Clear();
        foreach (var application in _allApplications)
        {
            var measured = application.InstallLocation is string location && _result is not null && _result.DirectorySizes.TryGetValue(location.TrimEnd('\\'), out var bytes) ? (long?)bytes : null;
            _applications.Add(measured is long size ? application with { EstimatedBytes = size } : application);
        }
    }
    private void SelectRecommended_Click(object sender, RoutedEventArgs e) { CleanupGrid.SelectedItems.Clear(); foreach (var item in CleanupGrid.Items.OfType<CleanupCandidate>().Where(item => item.Recommended)) CleanupGrid.SelectedItems.Add(item); }
    private void ClearCleanup_Click(object sender, RoutedEventArgs e) => CleanupGrid.SelectedItems.Clear();
    private void CleanupGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CleanupSelectionText is null) return;
        var selected = CleanupGrid.SelectedItems.Cast<CleanupCandidate>().ToList();
        CleanupSelectionText.Text = $"{selected.Count} sélectionné(s) · {SizeFormatter.Format(selected.Sum(item => item.Size))}";
        CleanButton.IsEnabled = selected.Count > 0;
        CleanupDetails.Text = CleanupGrid.SelectedItem is CleanupCandidate candidate ? candidate.Reason + " " + candidate.Consequence : "Choisissez un élément pour comprendre les conséquences du nettoyage.";
    }
    private async void AnalyzeDuplicates_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        var dialog = new OpenFolderDialog { Title = "Choisir un dossier personnel pour rechercher les doublons", InitialDirectory = Path.Combine(DeletionSafetyPolicy.Home, "Downloads") };
        if (dialog.ShowDialog(this) != true) return;
        SetBusy(true); _operationCancellation = new();
        try
        {
            var duplicates = await DuplicateAnalysis.AnalyzeAsync(dialog.FolderName, new Progress<string>(status => ScanStatusText.Text = status), _operationCancellation.Token);
            foreach (var old in _cleanup.Where(item => item.Group == "Doublons vérifiés").ToList()) _cleanup.Remove(old);
            foreach (var item in duplicates) { var old = _cleanup.FirstOrDefault(candidate => candidate.Path == item.Path); if (old is not null) _cleanup.Remove(old); _cleanup.Add(item); }
            ScanStatusText.Text = $"{duplicates.Count} copie(s) identique(s) vérifiée(s). Les exemplaires à conserver sont indiqués dans le détail.";
        }
        catch (OperationCanceledException) { ScanStatusText.Text = "Recherche des doublons annulée."; }
        catch (Exception error) { ShowError("Analyse des doublons indisponible.", error); }
        finally { SetBusy(false); _operationCancellation.Dispose(); _operationCancellation = null; }
    }
    private void History_Click(object sender, RoutedEventArgs e)
    {
        try { Directory.CreateDirectory(OperationHistory.DirectoryPath); ExplorerService.Open(OperationHistory.DirectoryPath); }
        catch (Exception error) { ShowError("L’historique local n’est pas accessible.",error); }
    }
    private void Options_Click(object sender, RoutedEventArgs e) { OptionsButton.ContextMenu.PlacementTarget = OptionsButton; OptionsButton.ContextMenu.IsOpen = true; }
    private async void CheckUpdate_Click(object sender, RoutedEventArgs e) => await CheckForUpdatesAsync(true);
    private async Task CheckForUpdatesAsync(bool manual)
    {
        CheckUpdateButton.IsEnabled = false;
        try
        {
            _availableUpdate = await _updates.CheckAsync(manual, CancellationToken.None);
            if (_availableUpdate is not null)
            {
                UpdateText.Text = $"StorageScope {_availableUpdate.Version} est disponible.\n{_availableUpdate.Notes}";
                UpdateBanner.Visibility = Visibility.Visible;
            }
            else if (manual) MessageBox.Show("Vous disposez de la dernière version compatible publiée.", "Mises à jour");
        }
        catch (Exception error) { if (manual) MessageBox.Show("Vérification indisponible. Vous pouvez continuer à utiliser StorageScope hors ligne.\n\n" + error.Message, "Mises à jour"); }
        finally { CheckUpdateButton.IsEnabled = true; }
    }
    private void DismissUpdate_Click(object sender, RoutedEventArgs e) => UpdateBanner.Visibility = Visibility.Collapsed;
    private async void InstallUpdate_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || !ScanButton.IsEnabled || _availableUpdate is null) return;
        SetBusy(true); _operationCancellation = new();
        try
        {
            var path = await _updates.DownloadVerifiedAsync(_availableUpdate, new Progress<double>(fraction => ScanStatusText.Text = $"Téléchargement vérifié : {fraction:P0}"), _operationCancellation.Token);
            using var guard = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            await Task.Run(() => UpdateService.VerifyInstaller(path, _availableUpdate), _operationCancellation.Token);
            Process.Start(new ProcessStartInfo(path, "/UPDATE /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS") { UseShellExecute = false });
            Application.Current.Shutdown();
        }
        catch (OperationCanceledException) { ScanStatusText.Text = "Mise à jour annulée. La version actuelle reste utilisable."; }
        catch (Exception error) { ShowError("Mise à jour refusée ou interrompue. La version actuelle reste en place.", error); }
        finally { SetBusy(false); _operationCancellation.Dispose(); _operationCancellation = null; }
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
}
