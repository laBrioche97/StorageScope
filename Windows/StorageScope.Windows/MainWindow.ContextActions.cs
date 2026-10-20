using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;

namespace StorageScope.Windows;

public partial class MainWindow
{
    private void InitializeContextActions()
    {
        foreach (var grid in new[] { LargestFilesGrid, ExplorerGrid, CategoryFilesGrid, CleanupGrid, ApplicationsGrid })
        {
            var style = new Style(typeof(DataGridRow), (Style)FindResource(typeof(DataGridRow)));
            style.Setters.Add(new Setter(AutomationProperties.NameProperty, new System.Windows.Data.Binding("Name")));
            grid.RowStyle = style;
            grid.PreviewMouseRightButtonDown += (_, e) =>
            {
                var row = e.OriginalSource is DependencyObject source ? ItemsControl.ContainerFromElement(grid, source) as DataGridRow : null;
                if (row is null) grid.SelectedItems.Clear();
                else if (!row.IsSelected) { grid.SelectedItems.Clear(); row.IsSelected = true; }
            };
            grid.ContextMenu = new ContextMenu();
            grid.ContextMenu.Opened += (_, _) => PopulateContextMenu(grid);
        }
        OptionsButton.Visibility = Visibility.Visible;
        var menu = OptionsButton.ContextMenu;
        menu.Items.Add(new Separator());
        var open = new MenuItem { Header = "Ouvrir les diagnostics" }; open.Click += (_, _) => OpenDiagnostics(); menu.Items.Add(open);
        var export = new MenuItem { Header = "Exporter les diagnostics…" }; export.Click += (_, _) => ExportDiagnostics(); menu.Items.Add(export);
    }

    private static string? ItemPath(object? item) => item switch { ScanEntry entry => entry.Path, CleanupCandidate candidate => candidate.Path, InstalledApplication app => app.InstallLocation, _ => null };

    private void PopulateContextMenu(DataGrid grid)
    {
        var menu = grid.ContextMenu;
        menu.Items.Clear();
        var item = grid.SelectedItem;
        var path = ItemPath(item);
        var exists = path is not null && (File.Exists(path) || Directory.Exists(path));
        var single = grid.SelectedItems.Count == 1;
        void Add(string title, Action action, bool enabled)
        {
            var option = new MenuItem { Header = title, IsEnabled = enabled };
            option.Click += (_, _) => { try { Diagnostics.Action = title; Diagnostics.Write("action"); action(); } catch (Exception error) { ShowError("Action indisponible.", error); } };
            menu.Items.Add(option);
        }
        Add("Ouvrir", () => SafeOpen(path!), exists && single && !_busy);
        Add("Ouvrir le dossier", () => SafeOpen(Directory.Exists(path) ? path! : Path.GetDirectoryName(path!)!), exists && single && !_busy);
        Add("Afficher dans l’Explorateur", () => ExplorerService.ShowInExplorer(path!), exists && single && !_busy);
        Add("Copier le chemin", () => Clipboard.SetText(string.Join(Environment.NewLine, grid.SelectedItems.Cast<object>().Select(ItemPath).Where(value => value is not null))), path is not null);
        Add("Propriétés", () => ExplorerService.Properties(path!), exists && single && !_busy);
        menu.Items.Add(new Separator());
        if (item is InstalledApplication application) Add(application is { Provider: "Epic", ManifestPath: not null, UninstallCommand: null or "" } ? "Désinstaller avec Epic…" : "Vérifier la désinstallation…", () => UninstallApplication_Click(grid, new RoutedEventArgs()), single && !_busy);
        else
        {
            var trash = new MenuItem { Header = "Mettre à la corbeille…", IsEnabled = grid.SelectedItems.Count > 0 && !_busy && ScanButton.IsEnabled };
            trash.Click += async (_, _) =>
            {
                var selected = grid.SelectedItems.Cast<object>().ToArray();
                var candidates = selected.OfType<CleanupCandidate>().ToArray();
                var entries = selected.Select(value => value switch { ScanEntry entry => entry, CleanupCandidate candidate => new ScanEntry(candidate.Path, candidate.Name, candidate.Size, candidate.IsDirectory, null, CategoryClassifier.Classify(candidate.Path)), _ => null }).OfType<ScanEntry>().ToList();
                await TrashEntriesAsync(entries, candidates);
            };
            menu.Items.Add(trash);
        }
    }

    private static void OpenDiagnostics()
    {
        try { Directory.CreateDirectory(Diagnostics.DirectoryPath); ExplorerService.Open(Diagnostics.DirectoryPath); }
        catch (Exception error) { ShowError("Diagnostics inaccessibles.", error); }
    }
    private void ExportDiagnostics()
    {
        var dialog = new SaveFileDialog { FileName = "StorageScope-diagnostics.log", Filter = "Journal de diagnostic (*.log)|*.log" };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            if (DeletionSafetyPolicy.IsWithin(dialog.FileName, Diagnostics.DirectoryPath)) throw new IOException("Choisissez un autre dossier pour conserver les journaux d’origine.");
            Diagnostics.Write("export-diagnostics");
            using var output = new StreamWriter(dialog.FileName);
            foreach (var file in Enumerable.Range(1, 5).Reverse().Select(i => Diagnostics.LogPath + "." + i).Append(Diagnostics.LogPath).Where(File.Exists))
                output.Write(File.ReadAllText(file));
        }
        catch (Exception error) { ShowError("Export impossible.", error); }
    }
}
