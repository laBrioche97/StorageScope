using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace StorageScope.Windows;

/// <summary>Offline help. Only the provider's local verification can confirm removal.</summary>
public sealed class EpicGuideWindow : Window
{
    private readonly IInstalledProductProvider? _provider;
    private readonly ProductUninstallPlan? _plan;
    private readonly CancellationTokenSource _monitor;
    private readonly TaskCompletionSource<ProductUninstallResult> _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8) };
    private readonly StackPanel _steps = new();
    private readonly Button _open = new() { Content = "Ouvrir Epic" };
    private readonly Button _verify = new() { Content = "Vérifier maintenant" };
    private readonly ComboBox _presentation = new() { ItemsSource = new[] { "Interface classique", "Nouvelle interface" }, SelectedIndex = 0, Margin = new Thickness(4) };
    private bool _started, _finished, _verifying;
    public EpicGuideWindow(string gameName, IInstalledProductProvider? provider = null, ProductUninstallPlan? plan = null, CancellationToken token = default)
    {
        _provider = provider; _plan = plan; _monitor = CancellationTokenSource.CreateLinkedTokenSource(token);
        Title = "Désinstaller avec Epic · " + gameName; Width = 800; Height = 730; MinWidth = 460; MinHeight = 420;
        SetResourceReference(BackgroundProperty, "PanelBrush"); SetResourceReference(ForegroundProperty, "TextBrush");
        var root = new DockPanel { Margin = new Thickness(16) }; Content = root;
        var header = new StackPanel(); DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        header.Children.Add(new TextBlock { Text = gameName, FontSize = 24, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        header.Children.Add(new TextBlock { Text = "Confirmez la désinstallation dans Epic. Cette aide reste ouverte pendant l’utilisation du launcher. Les sauvegardes et composants partagés ne sont pas nettoyés par StorageScope.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 8, 4, 8) });
        AutomationProperties.SetName(_presentation, "Présentation d’Epic Games Launcher"); header.Children.Add(_presentation);
        var bottom = new StackPanel(); DockPanel.SetDock(bottom, Dock.Bottom); root.Children.Add(bottom);
        bottom.Children.Add(_status);
        var actions = new WrapPanel(); bottom.Children.Add(actions); actions.Children.Add(_open); actions.Children.Add(_verify);
        var stop = new Button { Content = "Arrêter le suivi" }; actions.Children.Add(stop);
        bottom.Children.Add(new TextBlock { Text = "Fermer ou arrêter le suivi ne supprime aucun fichier et n’annule pas une désinstallation déjà acceptée dans Epic.", FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 8, 4, 0) });
        root.Children.Add(new ScrollViewer { Content = _steps, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        _presentation.SelectionChanged += (_, _) => BuildSteps();
        _open.Click += async (_, _) => await StartAsync();
        _verify.Click += async (_, _) => await VerifyAsync();
        stop.Click += (_, _) => { Finish(new(false, "Suivi arrêté. Actualisez ensuite l’inventaire pour vérifier le résultat dans Epic.", "suivi annulé")); _monitor.Cancel(); };
        Closed += (_, _) => { _monitor.Cancel(); Finish(new(false, "Aide fermée · désinstallation non confirmée. Aucun fichier supprimé par StorageScope.", "suivi annulé")); };
        _status.Text = "Prêt · ouvrez Epic, puis suivez les trois étapes.";
        _monitor.Token.Register(() => Dispatcher.BeginInvoke(new Action(() => Finish(new(false, "Suivi arrêté. Une désinstallation déjà acceptée dans Epic peut continuer.", "suivi annulé")))));
        BuildSteps();
    }
    public Task<ProductUninstallResult> ShowGuideAsync() { Show(); return _completion.Task; }
    private void BuildSteps()
    {
        _steps.Children.Clear(); var modern = _presentation.SelectedIndex == 1;
        AddStep(1, "Bibliothèque", modern ? "Cliquez sur Library / Bibliothèque dans la barre supérieure." : "Cliquez sur Library / Bibliothèque dans la colonne gauche.", modern ? "new-library" : "classic-library", modern ? new Rect(.25, .095, .06, .04) : new Rect(.005, .13, .15, .065), modern ? new Int32Rect(300, 250, 1250, 1000) : new Int32Rect(0, 95, 700, 600));
        AddStep(2, "Menu ⋯ du jeu", "Retrouvez votre jeu et ouvrez son menu à trois points. Dans la nouvelle interface, ouvrez d’abord la fiche du jeu.", modern ? "new-game" : "classic-menu", modern ? new Rect(.60, .195, .10, .08) : new Rect(.025, .75, .91, .16), modern ? new Int32Rect(330, 290, 630, 830) : null);
        AddStep(3, "Désinstaller et confirmer", "Choisissez Uninstall / Désinstaller, puis confirmez dans la fenêtre d’Epic. Exemple du menu classique ci-dessous ; le libellé est également Désinstaller dans la nouvelle interface.", "classic-menu", new Rect(.025, .75, .91, .16), null);
    }
    private void AddStep(int number, string title, string caption, string asset, Rect highlight, Int32Rect? crop)
    {
        var panel = new StackPanel { Margin = new Thickness(4, 12, 4, 8) };
        panel.Children.Add(new TextBlock { Text = $"{number}. {title}", FontSize = 19, FontWeight = FontWeights.SemiBold });
        panel.Children.Add(new TextBlock { Text = caption, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 5, 0, 8) });
        var bitmap = new BitmapImage(new Uri($"pack://application:,,,/StorageScope;component/Resources/EpicGuide/{asset}.png")); bitmap.Freeze();
        BitmapSource shown = crop is Int32Rect region ? new CroppedBitmap(bitmap, region) : bitmap; shown.Freeze();
        // Overlay coordinates are converted from the real source screenshot into the displayed crop.
        var box = crop ?? new Int32Rect(0, 0, bitmap.PixelWidth, bitmap.PixelHeight);
        var canvas = new Canvas { Width = shown.PixelWidth, Height = shown.PixelHeight };
        canvas.Children.Add(new Image { Source = shown, Width = shown.PixelWidth, Height = shown.PixelHeight });
        var rect = new System.Windows.Shapes.Rectangle { Width = highlight.Width * bitmap.PixelWidth, Height = highlight.Height * bitmap.PixelHeight, Stroke = Brushes.DeepPink, StrokeThickness = Math.Max(3, shown.PixelWidth / 140.0), IsHitTestVisible = false };
        Canvas.SetLeft(rect, highlight.X * bitmap.PixelWidth - box.X); Canvas.SetTop(rect, highlight.Y * bitmap.PixelHeight - box.Y); canvas.Children.Add(rect);
        var imageButton = new Button { Content = new Viewbox { Child = canvas, Stretch = Stretch.Uniform, MaxHeight = 260 }, HorizontalContentAlignment = HorizontalAlignment.Center, Padding = new Thickness(0), ToolTip = "Agrandir la capture officielle" };
        AutomationProperties.SetName(imageButton, $"Étape {number} : {title}. {caption} Agrandir la capture.");
        imageButton.Click += (_, _) => { var zoom = new Window { Title = title + " · capture officielle Epic", Owner = this, Width = 960, Height = 720, Content = new ScrollViewer { Content = new Image { Source = shown, Stretch = Stretch.None }, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } }; zoom.Show(); };
        panel.Children.Add(imageButton); _steps.Children.Add(panel);
    }
    private async Task StartAsync()
    {
        if (_started || _finished || _provider is null || _plan is null) return;
        _started = true; _open.IsEnabled = false; _status.Text = "Intervention dans Epic · vérification locale en cours…";
        try { Finish(await _provider.ExecuteAsync(_plan, _monitor.Token)); }
        catch (OperationCanceledException) { Finish(new(false, "Suivi arrêté. La désinstallation dans Epic peut continuer.", "suivi annulé")); }
        catch (Exception error) { Diagnostics.Write("guide-Epic", error); Finish(new(false, "Résultat non confirmé : " + error.Message)); }
    }
    private async Task VerifyAsync()
    {
        if (_verifying || _finished || _provider is null || _plan is null) return;
        _verifying = true; _verify.IsEnabled = false;
        try
        {
            if (await _provider.VerifyAsync(_plan.Product, _monitor.Token))
            {
                OperationHistory.Append(new { operation = "désinstallation Epic", product = _plan.Product.Name, status = "confirmée", verified = true });
                Finish(new(true, "Désinstallation confirmée localement. Les sauvegardes sont conservées.")); _monitor.Cancel();
            }
            else _status.Text = "Installation encore enregistrée ou résultat non confirmé. Terminez les étapes dans Epic, puis réessayez.";
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { _status.Text = "Vérification impossible : " + error.Message; Diagnostics.Write("vérification-guide-Epic", error); }
        finally { _verifying = false; _verify.IsEnabled = !_finished; }
    }
    private void Finish(ProductUninstallResult result)
    {
        if (_finished) return;
        _finished = true; _status.Text = result.Message; _open.IsEnabled = _verify.IsEnabled = false; _completion.TrySetResult(result);
    }
}
