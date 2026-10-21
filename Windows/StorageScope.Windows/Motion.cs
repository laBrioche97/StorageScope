using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace StorageScope.Windows;

internal static class Motion
{
    internal const int Feedback = 120, Section = 180, Navigation = 220;
    internal static bool Enabled => SystemParameters.ClientAreaAnimation && !SystemParameters.HighContrast;
    internal static bool? TestEnabled { get; set; }
    private static bool Animate => TestEnabled ?? Enabled;
    private static readonly DependencyProperty GenerationProperty = DependencyProperty.RegisterAttached("Generation", typeof(int), typeof(Motion), new PropertyMetadata(0));
    internal static BitmapSource? Capture(FrameworkElement element)
    {
        if (!Animate || !element.IsLoaded || element.ActualWidth < 1 || element.ActualHeight < 1) return null;
        var dpi = VisualTreeHelper.GetDpi(element); var width = (int)Math.Ceiling(element.ActualWidth * dpi.DpiScaleX); var height = (int)Math.Ceiling(element.ActualHeight * dpi.DpiScaleY);
        if ((long)width * height * 4 > 32L * 1024 * 1024) return null;
        var bitmap = new RenderTargetBitmap(width, height, dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32); bitmap.Render(element); bitmap.Freeze(); return bitmap;
    }
    private static DoubleAnimation Tween(double from, double to, int milliseconds) => new(from, to, TimeSpan.FromMilliseconds(milliseconds)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
    internal static void Swap(FrameworkElement incoming, Image outgoing, BitmapSource? previous, bool back, Point anchor)
    {
        var generation = (int)incoming.GetValue(GenerationProperty) + 1; incoming.SetValue(GenerationProperty, generation);
        incoming.BeginAnimation(UIElement.OpacityProperty, null); incoming.Opacity = 1; incoming.RenderTransform = Transform.Identity;
        outgoing.BeginAnimation(UIElement.OpacityProperty, null); outgoing.Source = null; outgoing.Visibility = Visibility.Collapsed;
        if (!Animate || previous is null) return;
        incoming.RenderTransformOrigin = outgoing.RenderTransformOrigin = anchor;
        var entrance = new ScaleTransform(1, 1); incoming.RenderTransform = entrance;
        var exit = new ScaleTransform(1, 1); outgoing.RenderTransform = exit;
        outgoing.Source = previous; outgoing.Visibility = Visibility.Visible;
        entrance.BeginAnimation(ScaleTransform.ScaleXProperty, Tween(back ? 1.06 : .97, 1, Navigation)); entrance.BeginAnimation(ScaleTransform.ScaleYProperty, Tween(back ? 1.06 : .97, 1, Navigation));
        exit.BeginAnimation(ScaleTransform.ScaleXProperty, Tween(1, back ? .97 : 1.08, Navigation)); exit.BeginAnimation(ScaleTransform.ScaleYProperty, Tween(1, back ? .97 : 1.08, Navigation));
        incoming.BeginAnimation(UIElement.OpacityProperty, Tween(0, 1, Navigation));
        var fade = Tween(1, 0, Navigation); fade.Completed += (_, _) => { if ((int)incoming.GetValue(GenerationProperty) != generation) return; outgoing.Source = null; outgoing.Visibility = Visibility.Collapsed; incoming.BeginAnimation(UIElement.OpacityProperty, null); incoming.Opacity = 1; incoming.RenderTransform = Transform.Identity; };
        outgoing.BeginAnimation(UIElement.OpacityProperty, fade);
    }
    internal static void Reveal(FrameworkElement element, int milliseconds = Section)
    {
        element.BeginAnimation(UIElement.OpacityProperty, null);
        if (Animate) element.BeginAnimation(UIElement.OpacityProperty, Tween(.85, 1, milliseconds));
    }
    internal static void Attach(Window window) => window.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler((_, e) => { if (Animate && e.OriginalSource is ButtonBase button) Reveal(button, Feedback); }), true);
}
