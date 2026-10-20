using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace StorageScope.Windows;

public static class AppIdentity
{
    public static string Version => UpdateService.CurrentVersion.ToString(3);
    public static string Title => "StorageScope · v" + Version;
}

public static class CategoryVisuals
{
    // Segoe MDL2 Assets is a vector system font available on supported Windows versions.
    public static string Glyph(StorageCategory category) => category switch
    {
        StorageCategory.Applications => "\uE71D", StorageCategory.ApplicationData => "\uE7B8",
        StorageCategory.Images => "\uEB9F", StorageCategory.Videos => "\uE714",
        StorageCategory.Audio => "\uE8D6", StorageCategory.Documents => "\uE8A5",
        StorageCategory.ArchivesInstallers => "\uE7B8", StorageCategory.Development => "\uE943",
        StorageCategory.VirtualMachines => "\uE977", StorageCategory.Backups => "\uE74E",
        StorageCategory.MailMessages => "\uE715", StorageCategory.CachesLogs => "\uE74D",
        StorageCategory.SystemLibraries => "\uE713", _ => "\uE8B7"
    };
}

public sealed class BriocheLoader : StackPanel
{
    private readonly Image _image;
    private readonly TextBlock _label;
    public BriocheLoader()
    {
        HorizontalAlignment = HorizontalAlignment.Center; VerticalAlignment = VerticalAlignment.Center;
        _image = new Image { Source = new BitmapImage(new Uri("pack://application:,,,/StorageScope;component/Resources/Logo.png")), Width = 64, Height = 64, Margin = new Thickness(8), RenderTransform = new TranslateTransform() };
        _label = new TextBlock { Text = "Lecture du dossier…", TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(10), MaxWidth = 380 };
        _label.SetResourceReference(TextBlock.ForegroundProperty, "TextBrush");
        Children.Add(_image); Children.Add(_label);
        System.Windows.Automation.AutomationProperties.SetName(this, "Chargement de l’explorateur");
        IsVisibleChanged += (_, _) => Animate(); Loaded += (_, _) => Animate();
    }
    public string Message { get => _label.Text; set => _label.Text = value; }
    private void Animate()
    {
        var transform = (TranslateTransform)_image.RenderTransform;
        transform.BeginAnimation(TranslateTransform.YProperty, null); _image.BeginAnimation(OpacityProperty, null);
        if (!IsVisible || !SystemParameters.ClientAreaAnimation || SystemParameters.HighContrast) return;
        var duration = new Duration(TimeSpan.FromSeconds(.9));
        transform.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, -7, duration) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() });
        _image.BeginAnimation(OpacityProperty, new DoubleAnimation(.6, 1, duration) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
    }
}
