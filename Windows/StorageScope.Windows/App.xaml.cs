using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace StorageScope.Windows;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        ApplyTheme();
        if (e.Args.Contains("--verify-installation"))
        {
            try { var window = new MainWindow(); window.Measure(new Size(1120, 800)); window.Arrange(new Rect(0, 0, 1120, 800)); Shutdown(0); }
            catch { Shutdown(1); }
            return;
        }
        SystemEvents.UserPreferenceChanged += OnPreferenceChanged;
        base.OnStartup(e);
        new MainWindow().Show();
    }
    protected override void OnExit(ExitEventArgs e) { SystemEvents.UserPreferenceChanged -= OnPreferenceChanged; base.OnExit(e); }
    private void OnPreferenceChanged(object sender, UserPreferenceChangedEventArgs e) => Dispatcher.Invoke(ApplyTheme);
    private void ApplyTheme()
    {
        var dark = (Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) as int?) == 0;
        ApplyPalette(dark, SystemParameters.HighContrast);
    }
    internal void ApplyPalette(bool dark, bool highContrast)
    {
        var colors = dark ? new[] { "#101216", "#191C22", "#252A33", "#454C59", "#F5F6FA", "#B1B9C8", "#B92169", "#FFFFFF" }
            : new[] { "#F5F6FA", "#FFFFFF", "#EDF0F5", "#949CAC", "#182031", "#4E5B70", "#A61959", "#FFFFFF" };
        var keys = new[] { "PageBrush", "PanelBrush", "InputBrush", "BorderBrush", "TextBrush", "MutedBrush", "AccentBrush", "AccentTextBrush" };
        for (var i = 0; i < keys.Length; i++) Resources[keys[i]] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(colors[i]));
        if (!highContrast) return;
        Resources["PageBrush"] = SystemColors.WindowBrush;
        Resources["PanelBrush"] = SystemColors.WindowBrush;
        Resources["InputBrush"] = SystemColors.ControlBrush;
        Resources["BorderBrush"] = SystemColors.WindowTextBrush;
        Resources["TextBrush"] = SystemColors.WindowTextBrush;
        Resources["MutedBrush"] = SystemColors.WindowTextBrush;
        Resources["AccentBrush"] = SystemColors.HighlightBrush;
        Resources["AccentTextBrush"] = SystemColors.HighlightTextBrush;
    }
}
