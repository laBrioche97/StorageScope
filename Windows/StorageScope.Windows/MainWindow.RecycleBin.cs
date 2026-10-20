using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;

namespace StorageScope.Windows;

public partial class MainWindow
{
    private RecycleSummary? _recycleSummary;
    private Task? _recycleRefresh;
    private bool _recycleNeedsRefresh;
    private DateTime _recycleChecked = DateTime.MinValue;
    private string? _recycleError;
    private Task RefreshRecycleBinAsync(bool force)
    {
        if (_closing || IsPreviewMode) return Task.CompletedTask;
        if (_recycleRefresh is { IsCompleted: false }) { if (force) _recycleNeedsRefresh = true; return _recycleRefresh; }
        if (!force && DateTime.UtcNow - _recycleChecked < TimeSpan.FromSeconds(30)) return Task.CompletedTask;
        return _recycleRefresh = Refresh();
        async Task Refresh()
        {
            try
            {
                _recycleError = null;
                _recycleSummary = await RecycleBinService.QueryAsync();
                RecycleBinButton.Content = _recycleSummary.Available ? $"Corbeille · {(_recycleSummary.Partial ? "≈ " : "")}{SizeFormatter.Format(_recycleSummary.Bytes)}" : "Corbeille · Indisponible";
            }
            catch (Exception error) { _recycleError = error.Message; RecycleBinButton.Content = "Corbeille · Indisponible"; Diagnostics.Write("inventaire-corbeille", error); }
            finally { _recycleChecked = DateTime.UtcNow; if (_recycleNeedsRefresh) { _recycleNeedsRefresh = false; _ = Dispatcher.BeginInvoke(() => { _ = RefreshRecycleBinAsync(true); }); } }
        }
    }
    private async void RecycleBin_Click(object sender, RoutedEventArgs e)
    {
        await RefreshRecycleBinAsync(true);
        if (_closing) return;
        var dialog = new Window { Owner = this, Title = "Corbeille", Width = 480, Height = 310, MinWidth = 400, MinHeight = 280, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var panel = new StackPanel { Margin = new Thickness(20) }; dialog.Content = panel;
        panel.Children.Add(new TextBlock { Text = "Corbeille de votre compte", FontSize = 22, FontWeight = FontWeights.SemiBold });
        var summary = _recycleSummary;
        panel.Children.Add(new TextBlock { Text = summary is { Available: true } ? $"{SizeFormatter.Format(summary.Bytes)} · {summary.Items:N0} élément(s)" + (summary.Partial ? " · Estimation partielle" : "") : "Taille indisponible", FontSize = 18, Margin = new Thickness(0, 16, 0, 8) });
        panel.Children.Add(new TextBlock { Text = "Volumes locaux montés · seuls les éléments de votre compte sont concernés." + (_recycleError is null ? "" : "\n" + _recycleError), TextWrapping = TextWrapping.Wrap });
        var open = new Button { Content = "Ouvrir la corbeille", Margin = new Thickness(0, 12, 0, 4) };
        open.Click += (_, _) => { try { Process.Start(new ProcessStartInfo("explorer.exe", "shell:RecycleBinFolder") { UseShellExecute = true }); } catch (Exception error) { ShowError("Corbeille indisponible.", error); } };
        panel.Children.Add(open);
        var empty = new Button { Content = "Vider la corbeille…", IsEnabled = summary is { Available: true, Items: > 0 } && !_busy && !_scanning };
        empty.Click += async (_, _) =>
        {
            empty.IsEnabled = false;
            await RefreshRecycleBinAsync(true);
            if (_busy || _scanning || _recycleSummary is not { Available: true, Items: > 0 } current) { dialog.Close(); return; }
            var roots = current.Volumes.Where(v => v.Error is null && v.Items > 0).Select(v => v.Root).ToArray();
            if (!ConfirmEmptyBin(dialog, $"Vider la corbeille de votre compte sur {string.Join(", ", roots)} ?\n\n{current.Items:N0} élément(s) · {SizeFormatter.Format(current.Bytes)}{(current.Partial ? " (estimation partielle ; volumes inaccessibles exclus)" : "")}\n\nCette suppression est définitive. Elle concerne le contenu présent au moment du vidage.")) { empty.IsEnabled = true; return; }
            dialog.Close(); SetBusy(true); CancelButton.IsEnabled = false;
            Diagnostics.Action = "vidage-corbeille"; Diagnostics.Write("action");
            ScanStatusText.Text = "Vidage de la corbeille en cours…"; ScanProgressBar.IsIndeterminate = true;
            try
            {
                var result = await RecycleBinService.EmptyAsync(new(roots, true));
                _recycleSummary = result.Summary;
                var complete = result.Errors.Count == 0 && result.Summary.Available && result.Summary.Items == 0;
                OperationHistory.Append(new CleanupOutcome("Corbeille du compte courant", complete ? "vidée" : "vidage partiel", Math.Max(0, current.Bytes - result.Summary.Bytes), string.Join("\n", result.Errors)));
                MessageBox.Show(this, (complete ? "Corbeille vidée." : "Vidage partiel : certains éléments restent dans la corbeille.") + $"\n\nTaille retirée estimée : {SizeFormatter.Format(Math.Max(0, current.Bytes - result.Summary.Bytes))}\nEspace libre : {(result.ObservedFreeChange is long gain ? (gain < 0 ? "variation négative de " : "variation observée de ") + SizeFormatter.Format(Math.Abs(gain)) : "variation indisponible")}\n\n" + string.Join("\n", result.Errors.Take(5)), "Bilan du vidage");
            }
            catch (Exception error) { ShowError("Vidage interrompu. Vérifiez la corbeille ; aucune action ne sera relancée automatiquement.", error); }
            finally { ScanProgressBar.IsIndeterminate = false; SetBusy(false); await RefreshRecycleBinAsync(true); RefreshSpaceStatus(); }
        };
        panel.Children.Add(empty);
        dialog.ShowDialog();
    }
    private static bool ConfirmEmptyBin(Window owner, string message)
    {
        var confirmation = new Window { Owner = owner, Title = "Vider définitivement", Width = 480, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var content = new StackPanel { Margin = new Thickness(20) };
        content.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 16) });
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Annuler", IsCancel = true };
        var accept = new Button { Content = "Vider définitivement" };
        accept.Click += (_, _) => confirmation.DialogResult = true;
        actions.Children.Add(cancel); actions.Children.Add(accept); content.Children.Add(actions);
        confirmation.Content = content; confirmation.Loaded += (_, _) => cancel.Focus();
        return confirmation.ShowDialog() == true;
    }

}
