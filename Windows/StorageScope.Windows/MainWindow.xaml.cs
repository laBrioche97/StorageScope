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
    private readonly ResultCollection<ScanEntry> _largestFiles = [];
    private readonly ResultCollection<ScanEntry> _categoryFiles = [];
    private readonly ResultCollection<CleanupCandidate> _cleanup = [];
    private readonly ResultCollection<InstalledApplication> _applications = [];
    private readonly ResultCollection<ScanEntry> _explorer = [];
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
    private bool _scanning;
    private bool _closing;
    private CancellationTokenSource? _inventoryCancellation;
    private int _inventoryGeneration;
    private int _browseGeneration;
    internal bool IsPreviewMode { get; set; }
    internal void ShowDiagnosticNotice()
    {
        ScanStatusText.Text = "La session précédente a été interrompue. Aucune action relancée. Diagnostics disponibles dans le menu ⋯.";
        ScanStatusText.ToolTip = ScanStatusText.Text;
    }

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
        InitializeContextActions();
        InitializeInterface();
        Activated += (_, _) => { if (!IsPreviewMode) _ = RefreshRecycleBinAsync(false); };
        Closing += (_, e) =>
        {
            if (_busy) { e.Cancel = true; MessageBox.Show("Annulez ou terminez l’opération en cours avant de fermer StorageScope.", "Opération en cours"); return; }
            _closing = true; _bubbleCancellation?.Cancel(); _inventoryCancellation?.Cancel(); _scanCancellation?.Cancel(); _browseCancellation?.Cancel();
        };
        SizeChanged += (_, _) => UpdateResponsiveColumns();
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        if (IsPreviewMode) return;
        _ = RefreshRecycleBinAsync(true);
        _ = Task.Run(UpdateService.CleanupDownloads);
        _ = CheckForUpdatesAsync(false);
        try
        {
            RefreshDrives();
            await ReloadApplicationsAsync();
        }
        catch (Exception error)
        {
            Diagnostics.Write("inventaire-au-démarrage", error);
            ScanStatusText.Text = "Inventaire indisponible. Vous pouvez analyser les fichiers ou réessayer avec Actualiser. Détail dans les diagnostics.";
        }
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
        if (_busy || _scanning) return;
        Diagnostics.Action = "analyse"; Diagnostics.Write("action");
        if (DrivePicker.SelectedItem is not DriveChoice drive) return;
        _scanCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _scanCancellation = cancellation;
        _browseCancellation?.Cancel(); ++_browseGeneration;
        _autoScanAttempts.Add(drive.Root);
        var destination = _currentDirectory;
        SetScanning(true);
        SetExplorerLoading(true, "Analyse du disque…");
        ClearResults();
        ScanStatusText.Text = "Préparation de l’analyse…";
        ScanProgressBar.Value = 0;
        var acceptingProgress = true;
        var progress = new Progress<ScanProgress>(value =>
        {
            if (!acceptingProgress || _closing || !_scanning || !ReferenceEquals(_scanCancellation, cancellation) || cancellation.IsCancellationRequested) return;
            ScanProgressBar.Value = value.Fraction * 100;
            ScanStatusText.Text = $"{value.Files:N0} fichiers · {SizeFormatter.Format(value.Bytes)} identifiés · {value.Errors:N0} refus — {value.Stage ?? value.CurrentPath}";
            if (CurrentSection == Section.Explorer && _folderIndex is null) ExplorerLoader.Message = $"Analyse du disque…\n{value.Files:N0} fichiers · {SizeFormatter.Format(value.Bytes)} identifiés";
            IdentifiedText.Text = SizeFormatter.Format(value.Bytes);
            FilesText.Text = value.Files.ToString("N0");
            DirectoriesText.Text = value.Directories.ToString("N0");
            ErrorsText.Text = value.Errors.ToString("N0");
        });
        try
        {
            var result = await _scanner.ScanAsync(drive.Root, progress, cancellation.Token);
            acceptingProgress = false;
            cancellation.Token.ThrowIfCancellationRequested();
            if (_closing) return;
            if ((DrivePicker.SelectedItem as DriveChoice)?.Root != drive.Root) return;
            _result = result;
            _folderIndex = await Task.Run(() => new FolderIndex(result), cancellation.Token);
            PopulateResult(_result);
            ScanStatusText.Text = $"Analyse {(_result.AccessErrors > 0 ? "partielle" : "terminée")} : {_result.FilesScanned:N0} fichiers · {_result.AccessErrors:N0} accès non disponibles" + (_result.CleanupTruncated ? " · suggestions limitées à 10 000 éléments" : "") + " · Choisissez Nettoyage conseillé pour continuer.";
            await BrowseAsync(destination is not null && Directory.Exists(destination) && DeletionSafetyPolicy.IsWithin(destination, drive.Root) ? destination : drive.Root);
        }
        catch (OperationCanceledException) { ClearResults(); ScanStatusText.Text = "Analyse annulée. Aucun fichier modifié."; }
        catch (Exception error)
        {
            ScanStatusText.Text = "L’analyse a échoué";
            ShowError("Impossible de terminer l’analyse.", error);
        }
        finally
        {
            acceptingProgress = false;
            if (ReferenceEquals(_scanCancellation, cancellation)) _scanCancellation = null;
            cancellation.Dispose();
            SetScanning(false); RefreshSpaceStatus();
            if (_folderIndex is null && _currentDirectory is not null) await LoadBubblesAsync(_currentDirectory);
        }
    }

    private void PopulateResult(ScanResult result)
    {
        _largestFiles.ReplaceAll(result.LargestFiles);
        _categoryFiles.ReplaceAll(result.CategoryFiles.Values.SelectMany(items => items));
        PopulateCategorySummary(result);
        _cleanup.ReplaceAll(result.CleanupCandidates);
        OverviewCategories.ItemsSource = result.Categories.OrderByDescending(category => category.Bytes);
        IdentifiedText.Text = SizeFormatter.Format(result.IdentifiedBytes);
        FilesText.Text = result.FilesScanned.ToString("N0");
        DirectoriesText.Text = result.DirectoriesScanned.ToString("N0");
        ErrorsText.Text = result.AccessErrors.ToString("N0");
        ApplyApplicationFilter();
        ApplyDisplayFilters();
    }

    private void ClearResults()
    {
        _bubbleCancellation?.Cancel();
        _result = null; _folderIndex = null; _folderFrame = null; ++_bubbleGeneration;
        BubbleCanvas.Children.Clear();
        _largestFiles.Clear();
        _categoryFiles.Clear();
        PopulateCategorySummary(null);
        _cleanup.Clear();
        OverviewCategories.ItemsSource = null;
        _explorer.Clear();
        _allExplorerItems.Clear();
        IdentifiedText.Text = FilesText.Text = DirectoriesText.Text = ErrorsText.Text = "—";
    }

    private void SetScanning(bool scanning)
    {
        _scanning = scanning;
        ScanButton.IsEnabled = !scanning;
        CancelButton.IsEnabled = scanning;
        DrivePicker.IsEnabled = !scanning;
        ScanProgressBar.IsIndeterminate = false;
        MainTabs.IsEnabled = !_busy;
        CleanButton.IsEnabled = UninstallButton.IsEnabled = DuplicateButton.IsEnabled = SelectRecommendedButton.IsEnabled = !scanning && !_busy;
        InstallUpdateButton.IsEnabled = !scanning;
        UpdateResponsiveColumns();
    }

    private void UpdateResponsiveColumns()
    {
        if (LargestFilesGrid is null) return;
        ((Grid)Content).Margin = new Thickness(ActualHeight < 650 ? 12 : 18);
        CheckUpdateButton.Visibility = HistoryButton.Visibility = Visibility.Collapsed;
        UpdateNavigationLayout(); LayoutExplorer();
        OptionsButton.Visibility = Visibility.Visible;
        var graphicalExplorer = CurrentSection == Section.Explorer && _bubbleMode;
        ApplicationTitle.Visibility = Visibility.Visible; WorkflowSteps.Visibility = Visibility.Collapsed;
        VolumeTitle.Visibility = Visibility.Collapsed;
        DrivePicker.Width = ActualWidth < 950 ? 200 : 260;
        CancelButton.Visibility = _busy || _scanning ? Visibility.Visible : Visibility.Collapsed;
        PrivacyFooter.Visibility = ActualHeight >= 620 ? Visibility.Visible : Visibility.Collapsed;
        StatusPanel.Visibility = ActualHeight >= 760 && (!graphicalExplorer || _scanning) ? Visibility.Visible : Visibility.Collapsed;
        CompactStatus.Visibility = ActualHeight < 760 && (_scanning || _busy) ? Visibility.Visible : Visibility.Collapsed;
        CleanupIntro.Visibility = ActualHeight >= 760 ? Visibility.Visible : Visibility.Collapsed;
        CleanupDetails.Visibility = ActualHeight >= 650 ? Visibility.Visible : Visibility.Collapsed;
        CleanupLayout.Margin = new Thickness(ActualHeight < 650 ? 6 : 12);
        BubbleLegend.Visibility = ActualHeight < 700 ? Visibility.Collapsed : Visibility.Visible;
        DirectFilesButton.ToolTip = "Fichiers dans ce dossier — Voir la liste. Les espaces entre bulles ne représentent pas l’espace libre.";
        if (ActualHeight < 700) DirectFilesButton.Content = "Voir les fichiers";
        CleanupActionStatus.TextWrapping = ActualHeight < 650 ? TextWrapping.NoWrap : TextWrapping.Wrap;
        CleanupActionStatus.TextTrimming = TextTrimming.CharacterEllipsis;
        SectionSummary.Visibility = ActualHeight >= 650 ? Visibility.Visible : Visibility.Collapsed;
        SelectRecommendedButton.Content = ActualWidth < 950 ? "Choisir les temporaires" : "Sélectionner les temporaires reconnus";
        SelectRecommendedButton.ToolTip = "Sélectionner uniquement les temporaires reconnus admissibles";
        ClearCleanupButton.Content = ActualWidth < 950 ? "Décocher" : "Tout décocher";
        DuplicateButton.Content = ActualWidth < 950 ? "Doublons…" : "Rechercher des doublons…";
        var compactExplorer = CurrentSection == Section.Explorer && ActualHeight < 700;
        DisplayFilterPanel.Visibility = compactExplorer && !_compactFiltersOpen ? Visibility.Collapsed : Visibility.Visible;
        ExplorerSearchBox.Visibility = compactExplorer && !_compactFiltersOpen ? Visibility.Visible : Visibility.Collapsed;
        ExplorerCompactFiltersButton.Visibility = compactExplorer ? Visibility.Visible : Visibility.Collapsed;
        ExplorerPathBox.Visibility = compactExplorer ? Visibility.Collapsed : Visibility.Visible;
        ExplorerNavigationBar.ColumnDefinitions[2].Width = new GridLength(compactExplorer ? 80 : 0);
        BubbleStatus.Visibility = compactExplorer ? Visibility.Collapsed : Visibility.Visible;
        BubbleCanvas.ToolTip = BubbleStatus.Text;
        void Show(DataGrid grid, int column, bool visible) { grid.Columns[column].Visibility = visible ? Visibility.Visible : Visibility.Collapsed; }
        Show(LargestFilesGrid, 3, ActualWidth >= 1000);
        Show(ExplorerGrid, 4, !_bubbleMode && ActualWidth >= 1100);
        Show(ExplorerGrid, 3, !_bubbleMode && ActualWidth >= 1000);
        Show(ExplorerGrid, 2, !_bubbleMode && ActualWidth >= 850);
        Show(CleanupGrid, 3, ActualWidth >= 1000);
        Show(CleanupGrid, 4, ActualWidth >= 1250);
        Show(ApplicationsGrid, 4, ActualWidth >= 1150);
        Show(ApplicationsGrid, 3, ActualWidth >= 1000);
        Show(ApplicationsGrid, 1, ActualWidth >= 850);
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        _scanCancellation?.Cancel(); _operationCancellation?.Cancel();
        if (_scanning) ScanStatusText.Text = "Annulation de l’analyse en cours…";
    }
    private async void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _scanning) return;
        try { _ = RefreshRecycleBinAsync(true); RefreshDrives(); RefreshSpaceStatus(); await ReloadApplicationsAsync(); } catch (Exception error) { ShowError("Inventaire indisponible.", error); }
    }

    private async void DrivePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded || DrivePicker.SelectedItem is not DriveChoice drive) return;
        _scanCancellation?.Cancel();
        if (string.Equals(_result?.Root, drive.Root, StringComparison.OrdinalIgnoreCase) || string.Equals(_currentDirectory, drive.Root, StringComparison.OrdinalIgnoreCase)) { UpdateVolumeHeader(); return; }
        _browseHistory.Clear(); _historyPosition = -1;
        ClearResults();
        UpdateVolumeHeader();
        await BrowseAsync(drive.Root);
        EnsureBubbleAnalysis();
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

    private async Task BrowseAsync(string path, bool addHistory = true)
    {
        _browseCancellation?.Cancel();
        _bubbleCancellation?.Cancel(); _bubbleCancellation = null; ++_bubbleGeneration;
        _browseCancellation = new CancellationTokenSource();
        var cancellation = _browseCancellation;
        var generation = ++_browseGeneration;
        BubbleEmptyState.Visibility = Visibility.Collapsed;
        if (_explorerScope != ExplorerScope.All) ResetExplorerScope();
        LayoutExplorer();
        if (addHistory) RecordBrowse(path);
        SetExplorerLoading(true);
        if (!string.Equals(_currentDirectory, path, StringComparison.OrdinalIgnoreCase)) {
            _allExplorerItems.Clear(); _explorer.Clear(); _folderFrame = null; BubbleCanvas.Children.Clear();
        }
        _currentDirectory = path;
        ExplorerPathBox.Text = path;
        ExplorerBreadcrumbs.Children.Clear();
        var crumbs = new Stack<string>();
        for (var ancestor = path; ancestor is not null && crumbs.Count < 32; ancestor = Directory.GetParent(ancestor)?.FullName) crumbs.Push(ancestor);
        foreach (var crumb in crumbs) {
            var button = new Button { Content = Path.GetFileName(crumb.TrimEnd('\\')) is { Length: > 0 } name ? name : crumb, ToolTip = crumb, Padding = new Thickness(8, 4, 8, 4) };
            button.Click += async (_, _) => await BrowseAsync(crumb);
            ExplorerBreadcrumbs.Children.Add(button);
        }
        try
        {
            var entries = await DirectoryBrowser.BrowseAsync(path, _result?.DirectorySizes, cancellation.Token);
            if (_closing || generation != _browseGeneration || cancellation.IsCancellationRequested) return;
            _allExplorerItems = entries.ToList();
            ApplyExplorerFilter();
            if (ExplorerShowsGraph) await LoadBubblesAsync(path);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!_closing && generation == _browseGeneration) { Diagnostics.Write("lecture-dossier", error); BubbleStatus.Text = "Dossier inaccessible : " + error.Message; BubbleEmptyState.Text = "Ce dossier n’a pas pu être lu. Vous pouvez revenir au dossier parent ou réessayer."; BubbleEmptyState.Visibility = Visibility.Visible; } }
        finally { if (generation == _browseGeneration && !_scanning) SetExplorerLoading(false); if (ReferenceEquals(_browseCancellation, cancellation)) _browseCancellation = null; cancellation.Dispose(); RefreshSectionHeading(); }
    }

    private void ApplyExplorerFilter()
    {
        _explorer.ReplaceAll(_allExplorerItems.Where(item => _explorerScope switch {
            ExplorerScope.DirectFiles => !item.IsDirectory,
            ExplorerScope.Remainder => _explorerRemainder?.Contains(item.Path) == true,
            _ => true
        }));
        ApplyDisplayFilters();
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
        if (e.Key != Key.Enter) return;
        try {
            if (DrivePicker.SelectedItem is not DriveChoice drive || !DeletionSafetyPolicy.IsWithin(ExplorerPathBox.Text, drive.Root)) { BubbleStatus.Text = "Choisissez le disque correspondant avant d’ouvrir ce dossier."; return; }
            await BrowseAsync(Path.GetFullPath(ExplorerPathBox.Text));
        } catch (Exception error) { BubbleStatus.Text = "Chemin non valide : " + error.Message; }
    }

    private void ExplorerSearchBox_TextChanged(object sender, TextChangedEventArgs e) { ApplyDisplayFilters(); RenderBubbles(); }

    private void OpenSelection_Click(object sender, RoutedEventArgs e)
    {
        if (ExplorerGrid.SelectedItem is ScanEntry item) SafeOpen(item.Path);
    }

    private void RevealSelection_Click(object sender, RoutedEventArgs e)
    {
        if (ExplorerGrid.SelectedItem is ScanEntry item) SafeReveal(item.Path);
    }

    private async void TrashSelection_Click(object sender, RoutedEventArgs e)
    {
        var selected = ExplorerGrid.SelectedItems.Cast<ScanEntry>().ToList();
        if (selected.Count == 0) return;
        await TrashEntriesAsync(selected);
    }

    private void RevealCleanup_Click(object sender, RoutedEventArgs e)
    {
        if (CleanupGrid.SelectedItem is CleanupCandidate candidate) SafeReveal(candidate.Path);
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
        if (_busy || _scanning) return;
        SetBusy(true);
        Diagnostics.Action = "nettoyage-corbeille"; Diagnostics.Write("action");
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
            _ = RefreshRecycleBinAsync(true);
            _folderIndex = null; _folderFrame = null;
            if (_currentDirectory is not null) await BrowseAsync(_currentDirectory);
            foreach (var item in succeeded)
            {
                foreach (var entry in _largestFiles.Where(entry => DeletionSafetyPolicy.IsWithin(entry.Path, item.Path)).ToList()) _largestFiles.Remove(entry);
                foreach (var entry in _categoryFiles.Where(entry => DeletionSafetyPolicy.IsWithin(entry.Path, item.Path)).ToList()) _categoryFiles.Remove(entry);
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

    private void ApplicationSelection_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (UninstallButton is null) return;
        UninstallButton.Content = ApplicationsGrid.SelectedItem is InstalledApplication { Provider: "Epic", ManifestPath: not null, UninstallCommand: null or "" }
            ? "Désinstaller avec Epic…" : "Vérifier la désinstallation…";
    }

    private async void UninstallApplication_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _scanning || ApplicationsGrid.SelectedItem is not InstalledApplication application) return;
        SetBusy(true); _operationCancellation = new();
        try
        {
            Diagnostics.Action = "désinstallation"; Diagnostics.Write("action");
            var provider = _products.ProviderFor(application);
            ScanStatusText.Text = "Préparation de la désinstallation…";
            var plan = await Task.Run(() => provider.Prepare(application), _operationCancellation.Token);
            plan = plan with { Progress = new Progress<string>(message => ScanStatusText.Text = message) };
            if (!plan.CanProceed) { MessageBox.Show(plan.Explanation, "Désinstallation indisponible", MessageBoxButton.OK, MessageBoxImage.Information); return; }
            if (MessageBox.Show($"Désinstaller « {application.Name} » ?\n\nInstallation : {application.DisplaySize}.\nCette taille ne garantit pas l’espace libéré ; des composants peuvent être partagés.\n\n{plan.Explanation}\n\nLes sauvegardes restent conservées par StorageScope. Les résidus attribués seront proposés séparément.", "Vérifier la désinstallation", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            ScanStatusText.Text = plan.EpicGuided ? "Ouverture d’Epic pour confirmer la désinstallation…" : "Désinstallation officielle en cours…";
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
            ScanStatusText.Text = result.Verified ? "Désinstallation confirmée." : result.Message;
        }
        catch (OperationCanceledException) { ScanStatusText.Text = "Suivi annulé. Actualisez l’inventaire pour vérifier le résultat dans le launcher."; }
        catch (Exception error) { ShowError("La désinstallation n’a pas pu être confirmée.", error); }
        finally { SetBusy(false); _operationCancellation.Dispose(); _operationCancellation = null; }
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        MainTabs.IsEnabled = true;
        CleanButton.IsEnabled = UninstallButton.IsEnabled = DuplicateButton.IsEnabled = SelectRecommendedButton.IsEnabled = !busy && !_scanning;
        ScanButton.IsEnabled = !busy;
        DrivePicker.IsEnabled = !busy;
        CancelButton.IsEnabled = busy;
        InstallUpdateButton.IsEnabled = !busy;
    }
    private async Task ReloadApplicationsAsync()
    {
        _inventoryCancellation?.Cancel();
        var cancellation = new CancellationTokenSource(); _inventoryCancellation = cancellation;
        var generation = ++_inventoryGeneration;
        var detected = await _products.DetectAsync(cancellation.Token);
        if (_closing || generation != _inventoryGeneration) return;
        var prepared = await Task.Run(() => detected.Select(app => (App: app, Key: SessionIconCache.Key(app))).ToArray(), cancellation.Token);
        if (_closing || generation != _inventoryGeneration) return;
        _allApplications = prepared.Select(pair => pair.App with { Icon = _activeIcons.GetValueOrDefault(pair.Key) ?? _iconCache.Peek(pair.Key) ?? pair.App.Icon }).ToArray();
        _activeIcons = prepared.Select((pair, i) => (pair.Key, Icon: _allApplications[i].Icon)).Where(pair => !ReferenceEquals(pair.Icon, ApplicationIcons.Fallback)).GroupBy(pair => pair.Key).ToDictionary(group => group.Key, group => group.First().Icon);
        var selectedSource = ApplicationSourceFilter.SelectedItem as string;
        ApplicationSourceFilter.ItemsSource = new[] { "Toutes les sources" }.Concat(_allApplications.Select(item => item.Provider).Distinct().Order());
        ApplicationSourceFilter.SelectedItem = selectedSource is not null && _allApplications.Any(item => item.Provider == selectedSource) ? selectedSource : "Toutes les sources";
        ApplyApplicationFilter();
        _ = EnrichApplicationsAsync(_allApplications, generation, cancellation);
    }
    private async Task EnrichApplicationsAsync(IReadOnlyList<InstalledApplication> detected, int generation, CancellationTokenSource cancellation)
    {
        using var limit = new SemaphoreSlim(3);
        try
        {
            await Task.WhenAll(detected.Select(async original =>
            {
                await limit.WaitAsync(cancellation.Token);
                try
                {
                    var key = await Task.Run(() => SessionIconCache.Key(original), cancellation.Token);
                    var enriched = original with { Icon = await _iconCache.GetAsync(key, () => ApplicationEnrichment.IconAsync(original, CancellationToken.None)).WaitAsync(cancellation.Token) };
                    if (generation == _inventoryGeneration && !cancellation.IsCancellationRequested && !ReferenceEquals(enriched.Icon, ApplicationIcons.Fallback)) _activeIcons[key] = enriched.Icon;
                    Publish(enriched);
                    enriched = await Task.Run(() => ApplicationEnrichment.Measure(enriched, cancellation.Token), cancellation.Token);
                    Publish(enriched);
                }
                catch (OperationCanceledException) { }
                catch (Exception error) { Diagnostics.Write("inventaire-enrichissement", error); Publish(original with { SizeStatus = original.HasKnownSize ? "Taille déclarée" : "Indisponible" }); }
                finally { limit.Release(); }
                void Publish(InstalledApplication value)
                {
                    if (_closing || generation != _inventoryGeneration || cancellation.IsCancellationRequested) return;
                    var all = _allApplications.ToList(); var index = all.FindIndex(item => item.Name == original.Name && item.ProductId == original.ProductId && item.InstallLocation == original.InstallLocation);
                    if (index >= 0) { all[index] = value; _allApplications = all; }
                    var displayed = _applications.Select((item, i) => (item, i)).FirstOrDefault(pair => pair.item.Name == original.Name && pair.item.ProductId == original.ProductId && pair.item.InstallLocation == original.InstallLocation);
                    if (displayed.item is not null) _applications[displayed.i] = value;
                }
            }));
        }
        catch (OperationCanceledException) { }
        finally { if (ReferenceEquals(_inventoryCancellation, cancellation)) _inventoryCancellation = null; cancellation.Dispose(); }
    }
    private void ApplyApplicationFilter()
    {
        _applications.ReplaceAll(_allApplications.Select(application =>
        {
            var measured = application.InstallLocation is string location && _result is not null && _result.DirectorySizes.TryGetValue(location.TrimEnd('\\'), out var bytes) ? (long?)bytes : null;
            return measured is long size ? application with { EstimatedBytes = size, SizeStatus = "Mesurée pendant l’analyse" } : application;
        }));
    }
    private void SelectRecommended_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _scanning) { CleanupActionStatus.Text = "Terminez ou annulez l’opération en cours avant de sélectionner les temporaires."; return; }
        if (_result is null) { CleanupActionStatus.Text = "Analysez le disque pour reconnaître les temporaires. Le bouton Analyser le disque est disponible en haut."; return; }
        var hidden = CurrentDisplayFilter.Search.Length > 0 || CurrentDisplayFilter.Category is not null || CurrentDisplayFilter.MinimumBytes > 0 || CurrentDisplayFilter.Kind != EntryKind.All;
        ResetFilters_Click(this, new());
        _changingCleanupSelection = true;
        try { CleanupGrid.SelectedItems.Clear(); foreach (var candidate in _cleanup.Where(item => item.Recommended)) CleanupGrid.SelectedItems.Add(candidate); }
        finally { _changingCleanupSelection = false; }
        CleanupGrid_SelectionChanged(CleanupGrid, new SelectionChangedEventArgs(System.Windows.Controls.Primitives.Selector.SelectionChangedEvent, Array.Empty<object>(), Array.Empty<object>()));
        CleanupActionStatus.Text = CleanupGrid.SelectedItems.Count == 0
            ? "Aucun temporaire reconnu admissible. Les documents et sauvegardes restent conservés."
            : $"{CleanupGrid.SelectedItems.Count:N0} temporaire(s) sélectionné(s) · {SizeFormatter.Format(CleanupGrid.SelectedItems.OfType<CleanupCandidate>().Sum(item => item.Size))}. Examinez la sélection avant de nettoyer.";
        if (hidden) CleanupActionStatus.Text += " Les filtres ont été réinitialisés pour afficher la sélection.";
    }

    private void ClearCleanup_Click(object sender, RoutedEventArgs e) => CleanupGrid.SelectedItems.Clear();
    private bool _changingCleanupSelection;
    private void CleanupGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CleanupSelectionText is null || _changingCleanupSelection) return;
        var selected = CleanupGrid.SelectedItems.Cast<CleanupCandidate>().ToList();
        CleanupSelectionText.Text = $"{selected.Count} sélectionné(s) · {SizeFormatter.Format(selected.Sum(item => item.Size))}";
        CleanButton.IsEnabled = selected.Count > 0 && !_scanning && !_busy;
        CleanupDetails.Text = CleanupGrid.SelectedItem is CleanupCandidate candidate ? candidate.Reason + " " + candidate.Consequence : "Choisissez un élément pour comprendre les conséquences du nettoyage.";
    }
    private async void AnalyzeDuplicates_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _scanning) { CleanupActionStatus.Text = "Terminez ou annulez l’opération en cours avant la recherche."; return; }
        string? folder;
        if (IsPreviewMode && DuplicateDirectoryPicker is not null) folder = DuplicateDirectoryPicker();
        else {
            var downloads = Path.Combine(DeletionSafetyPolicy.Home, "Downloads");
            var dialog = new OpenFolderDialog { Title = "Choisir un dossier personnel pour rechercher les doublons", InitialDirectory = Directory.Exists(downloads) ? downloads : DeletionSafetyPolicy.Home };
            folder = dialog.ShowDialog(this) == true ? dialog.FolderName : null;
        }
        if (folder is null) { CleanupActionStatus.Text = "Recherche non lancée. Aucun fichier modifié."; return; }
        SetBusy(true); _operationCancellation = new();
        var cancellation = _operationCancellation;
        CleanupActionStatus.Text = "Recherche des fichiers… Vous pouvez annuler en haut de la fenêtre.";
        ScanProgressBar.IsIndeterminate = true;
        try
        {
            var duplicates = await DuplicateAnalysis.AnalyzeAsync(folder, new Progress<string>(status => { if (ReferenceEquals(_operationCancellation, cancellation) && !cancellation.IsCancellationRequested) CleanupActionStatus.Text = status; }), cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            ResetFilters_Click(this, new());
            var paths = duplicates.Select(item => item.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
            _cleanup.ReplaceAll(_cleanup.Where(item => item.Group != "Doublons vérifiés" && !paths.Contains(item.Path)).Concat(duplicates).ToArray());
            ApplyDisplayFilters();
            var first = duplicates.FirstOrDefault(); if (first is not null) { CleanupGrid.SelectedItem = first; CleanupGrid.ScrollIntoView(first); CleanupGrid.SelectedItems.Clear(); }
            CleanupActionStatus.Text = duplicates.Count == 0 ? "Recherche terminée : aucun doublon vérifié parmi les fichiers accessibles. Les emplacements protégés et cloud sont exclus." : $"{duplicates.Count:N0} copie(s) identique(s) vérifiée(s) · groupe Doublons vérifiés. Un exemplaire est conservé ; rien n’a été supprimé. Les filtres ont été réinitialisés.";
            if (duplicates.Unreadable > 0) CleanupActionStatus.Text += $" Analyse partielle : {duplicates.Unreadable:N0} élément(s) inaccessible(s).";
            if (duplicates.Excluded > 0) CleanupActionStatus.Text += $" {duplicates.Excluded:N0} emplacement(s) exclu(s) par les protections.";
        }
        catch (OperationCanceledException) { CleanupActionStatus.Text = "Recherche annulée. Aucun fichier modifié ; les précédents résultats sont conservés."; }
        catch (Exception error) { Diagnostics.Write("recherche-doublons", error); CleanupActionStatus.Text = "Recherche impossible : " + error.Message; }
        finally { ScanProgressBar.IsIndeterminate = false; SetBusy(false); cancellation.Dispose(); _operationCancellation = null; }
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
        if (!CheckUpdateButton.IsEnabled) return;
        CheckUpdateButton.IsEnabled = false;
        try
        {
            _availableUpdate = await _updates.CheckAsync(manual, CancellationToken.None);
            if (_availableUpdate is not null)
            {
                UpdateText.Text = $"StorageScope {_availableUpdate.Version} est disponible.\n{_availableUpdate.Notes}" + (string.IsNullOrWhiteSpace(UpdateService.ExpectedPublisher) && string.IsNullOrWhiteSpace(_availableUpdate.AuthenticodePublisher) ? "\nPaquet vérifié par la clé de mise à jour StorageScope ; sans signature Authenticode Windows. Windows peut demander une confirmation." : "");
                InstallUpdateButton.Content = "Mettre à jour et redémarrer";
                UpdateBanner.Visibility = Visibility.Visible;
            }
            else if (_updates.ManualDownloadUrl is not null)
            {
                UpdateText.Text = _updates.Status; InstallUpdateButton.Content = "Ouvrir la release officielle"; UpdateBanner.Visibility = Visibility.Visible;
            }
            else if (manual) MessageBox.Show(_updates.Status, "Mises à jour");
            CheckUpdateButton.ToolTip = _updates.Status;
        }
        catch (Exception error)
        {
            Diagnostics.Write("vérification-mise-à-jour", error);
            CheckUpdateButton.ToolTip = "Vérification indisponible. Le logiciel reste utilisable hors ligne.";
            if (manual) MessageBox.Show("Vérification indisponible. Vous pouvez continuer à utiliser StorageScope hors ligne.\n\n" + error.Message, "Mises à jour");
        }
        finally { CheckUpdateButton.IsEnabled = true; }
    }
    private void DismissUpdate_Click(object sender, RoutedEventArgs e) => UpdateBanner.Visibility = Visibility.Collapsed;
    private async void InstallUpdate_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _scanning) { MessageBox.Show("Terminez le nettoyage ou l’analyse avant la mise à jour.", "Mise à jour reportée"); return; }
        if (_availableUpdate is null) { if (_updates.ManualDownloadUrl is string url) SafeOpen(url); return; }
        var manifest = _availableUpdate;
        SetBusy(true); _operationCancellation = new();
        try
        {
            Diagnostics.Action = "mise-à-jour"; Diagnostics.Write("action");
            var path = await _updates.DownloadVerifiedAsync(manifest, new Progress<double>(fraction => ScanStatusText.Text = $"Téléchargement : {fraction:P0}"), _operationCancellation.Token);
            using var guard = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            await Task.Run(() => UpdateService.VerifyInstaller(path, manifest), _operationCancellation.Token);
            Process.Start(new ProcessStartInfo(path, "/UPDATE=1 /SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS") { UseShellExecute = true });
            SetBusy(false);
            Application.Current.Shutdown();
        }
        catch (OperationCanceledException) { ScanStatusText.Text = "Mise à jour annulée. La version actuelle reste utilisable."; }
        catch (Exception error) { ShowError("Mise à jour refusée ou interrompue. La version actuelle reste en place.", error); }
        finally { SetBusy(false); _operationCancellation.Dispose(); _operationCancellation = null; }
    }

    private static void SafeOpen(string path)
    {
        try { ExplorerService.Open(path); }
        catch (Exception error) { ShowError("Impossible d’ouvrir l’élément.", error); }
    }
    private static void SafeReveal(string path)
    {
        try { ExplorerService.ShowInExplorer(path); } catch (Exception error) { ShowError("Explorateur indisponible.", error); }
    }
    private static void ShowError(string title, Exception error)
    {
        Diagnostics.Write(title, error);
        MessageBox.Show($"{title}\n\n{error.Message}", "StorageScope", MessageBoxButton.OK, MessageBoxImage.Error);
    }
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
