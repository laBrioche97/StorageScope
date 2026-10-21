using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;

namespace StorageScope.Windows;

public partial class MainWindow
{
    private bool _refreshingDrives;
    private bool _choosingStorage;
    private int _storageGeneration;
    private int _driveRefreshGeneration;
    private string? _storageIdentity;
    private readonly Dictionary<string, ScanResult> _storageResults = [];
    private DispatcherTimer? _deviceRefresh;
    private HwndSource? _deviceSource;
    internal Func<IReadOnlyList<DriveChoice>> StorageReader { get; set; } = () => DriveChoice.Mounted();

    private void ObserveStorageChanges()
    {
        _deviceSource = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
        _deviceSource?.AddHook(StorageMessage);
        _deviceRefresh = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
        _deviceRefresh.Tick += async (_, _) => { _deviceRefresh.Stop(); await RefreshDrivesAsync(); };
        Closed += (_, _) => { _deviceRefresh.Stop(); _deviceSource?.RemoveHook(StorageMessage); };
    }
    private IntPtr StorageMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == 0x0219 && _deviceRefresh is not null) { _deviceRefresh.Stop(); _deviceRefresh.Start(); }
        return IntPtr.Zero;
    }

    private async Task RefreshDrivesAsync()
    {
        var generation = ++_driveRefreshGeneration;
        IReadOnlyList<DriveChoice> drives;
        try { drives = await Task.Run(StorageReader); }
        catch (Exception error) { Diagnostics.Write("stockages", error); drives = []; }
        if (_closing || generation != _driveRefreshGeneration) return;
        var previous = DrivePicker.SelectedItem as DriveChoice;
        _refreshingDrives = true;
        try
        {
            DrivePicker.ItemsSource = drives;
            DrivePicker.SelectedItem = drives.FirstOrDefault(drive => drive.Identity == previous?.Identity) ?? drives.FirstOrDefault();
            StorageChoices.ItemsSource = drives;
        }
        finally { _refreshingDrives = false; }
        if (_storageIdentity is not null && !drives.Any(drive => drive.Identity == _storageIdentity))
        {
            _storageIdentity = null;
            InvalidateStorageReads(); ClearResults();
            ShowStorageChooser("Le stockage actif a été déconnecté. Choisissez un autre stockage.");
        }
        UpdateVolumeHeader();
    }

    private void InvalidateStorageReads()
    {
        ++_storageGeneration;
        _scanCancellation?.Cancel(); _browseCancellation?.Cancel(); _bubbleCancellation?.Cancel();
        ++_browseGeneration; ++_bubbleGeneration;
        SetExplorerLoading(false);
    }
    private void ShowStorageChooser(string message)
    {
        _choosingStorage = true;
        _browseCancellation?.Cancel(); _bubbleCancellation?.Cancel(); ++_browseGeneration; ++_bubbleGeneration;
        SetExplorerLoading(false);
        StorageChooserMessage.Text = message;
        StorageChooser.Visibility = Visibility.Visible;
        StorageChoices.ItemsSource = DrivePicker.ItemsSource;
    }
    private async Task EnterExplorerAsync()
    {
        var generation = ++_storageGeneration;
        await RefreshDrivesAsync();
        if (_closing || generation != _storageGeneration || CurrentSection != Section.Explorer) return;
        var drives = DrivePicker.Items.OfType<DriveChoice>().ToArray();
        if (drives.Length == 1) await OpenStorageRootAsync(drives[0]);
        else ShowStorageChooser(drives.Length == 0 ? "Aucun stockage local accessible. Branchez un disque puis actualisez." : "Choisissez le stockage à explorer. Il s’ouvrira à sa racine.");
    }
    private async void ChangeStorage_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) { ScanStatusText.Text = "Terminez l’opération en cours avant de changer de stockage."; return; }
        ShowStorageChooser("Recherche des stockages locaux…");
        await RefreshDrivesAsync();
        if (_choosingStorage) StorageChooserMessage.Text = "Choisissez le stockage à explorer à sa racine.";
    }
    private async void StorageChoice_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.DataContext is DriveChoice drive) await OpenStorageRootAsync(drive);
    }
    private async Task OpenStorageRootAsync(DriveChoice drive)
    {
        if (_busy) { ScanStatusText.Text = "Terminez l’opération en cours avant de changer de stockage."; return; }
        if (!DrivePicker.Items.OfType<DriveChoice>().Any(item => item.Identity == drive.Identity)) return;
        var previousIdentity = _storageIdentity;
        if (_result is not null && previousIdentity is not null) _storageResults[previousIdentity] = _result;
        InvalidateStorageReads();
        var generation = _storageGeneration;
        _storageIdentity = drive.Identity;
        _refreshingDrives = true;
        try { DrivePicker.SelectedItem = drive; } finally { _refreshingDrives = false; }
        _choosingStorage = false; StorageChooser.Visibility = Visibility.Collapsed;
        _browseHistory.Clear(); _historyPosition = -1;
        ResetExplorerScope();
        _sectionFilters[Section.Explorer] = new();
        if (CurrentSection == Section.Explorer) ResetFilters_Click(this, new());
        if (previousIdentity != drive.Identity) ClearResults();
        if (_storageResults.TryGetValue(drive.Identity, out var cached))
        {
            _result = cached;
            var index = await Task.Run(() => new FolderIndex(cached));
            if (generation != _storageGeneration || _closing) return;
            _folderIndex = index;
        }
        UpdateVolumeHeader();
        ScanStatusText.Text = "Racine du stockage ouverte · historique et filtres de l’explorateur réinitialisés.";
        await BrowseAsync(drive.Root);
        if (generation == _storageGeneration && !_choosingStorage) EnsureBubbleAnalysis();
    }
}

public sealed class DriveChoice
{
    private readonly DriveInfo? _drive;
    public string Root { get; }
    public string Identity { get; }
    public string VolumeLabel { get; }
    public long? Capacity { get; }
    public long? Free { get; }
    public long AvailableBytes => _drive?.AvailableFreeSpace ?? Free ?? throw new IOException("Espace libre indisponible.");
    public string FreeLabel => Free is long bytes ? $"{SizeFormatter.Format(bytes)} libres" : "Espace libre indisponible";
    public string CapacityLabel => Capacity is long bytes ? $"Capacité : {SizeFormatter.Format(bytes)}" : "Capacité indisponible";
    public DriveChoice(DriveInfo drive)
    {
        _drive = drive; Root = drive.RootDirectory.FullName;
        var name = new StringBuilder(1024);
        Identity = GetVolumeNameForVolumeMountPoint(Root, name, name.Capacity) ? name.ToString() : Root;
        try { VolumeLabel = string.IsNullOrWhiteSpace(drive.VolumeLabel) ? $"Disque local ({Root.TrimEnd('\\')})" : $"{drive.VolumeLabel} ({Root.TrimEnd('\\')})"; }
        catch (IOException) { VolumeLabel = Root; }
        try { Capacity = drive.TotalSize; Free = drive.AvailableFreeSpace; } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
    internal DriveChoice(string root, string identity, string name, long? capacity, long? free)
    { Root = root; Identity = identity; VolumeLabel = name; Capacity = capacity; Free = free; }
    internal static IReadOnlyList<DriveChoice> Mounted()
    {
        var drives = new List<DriveChoice>();
        foreach (var drive in DriveInfo.GetDrives())
            try { if (drive.IsReady && drive.DriveType is DriveType.Fixed or DriveType.Removable) drives.Add(new(drive)); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Diagnostics.Write("stockage-inaccessible", error); }
        return drives;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetVolumeNameForVolumeMountPointW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumeNameForVolumeMountPoint(string root, StringBuilder name, int length);
}
