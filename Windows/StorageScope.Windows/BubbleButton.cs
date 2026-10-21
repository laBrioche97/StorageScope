using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace StorageScope.Windows;

// A bounded native button per visible circle gives real keyboard focus and UI
// Automation invocation without introducing a web runtime or a giant visual tree.
internal sealed class BubbleButton : Button
{
    internal required FolderCircle Circle { get; set; }
    internal bool Highlighted { get; set; }
    internal bool HasChildren { get; init; }
    protected override void OnGotKeyboardFocus(System.Windows.Input.KeyboardFocusChangedEventArgs e) { base.OnGotKeyboardFocus(e); InvalidateVisual(); }
    protected override void OnLostKeyboardFocus(System.Windows.Input.KeyboardFocusChangedEventArgs e) { base.OnLostKeyboardFocus(e); InvalidateVisual(); }
    protected override HitTestResult? HitTestCore(PointHitTestParameters hitTestParameters)
    {
        var point = hitTestParameters.HitPoint;
        return Math.Pow(point.X - ActualWidth / 2, 2) + Math.Pow(point.Y - ActualHeight / 2, 2) <= Math.Pow(ActualWidth / 2, 2) ? new PointHitTestResult(this, point) : null;
    }
    protected override void OnRender(DrawingContext dc)
    {
        var r = ActualWidth / 2;
        var color = Circle.Aggregate ? Color.FromRgb(95, 103, 120) : (Circle.IsDirectory ? 0 : 1) switch
        { 0 => Color.FromRgb(131, 40, 99), 1 => Color.FromRgb(45, 91, 134), _ => Color.FromRgb(36, 111, 105) };
        var contrast = SystemParameters.HighContrast;
        dc.DrawEllipse(contrast ? SystemColors.WindowBrush : new SolidColorBrush(color), new Pen(contrast ? SystemColors.WindowTextBrush : Highlighted || IsKeyboardFocused ? Brushes.White : new SolidColorBrush(Color.FromArgb(170, 220, 225, 235)), Highlighted || IsKeyboardFocused ? 3 : 1), new(r, r), Math.Max(0, r - 2), Math.Max(0, r - 2));
        if (r < 32) return;
        var ink = contrast ? SystemColors.WindowTextBrush : Brushes.White;
        if (!HasChildren) {
            var name = new FormattedText(Circle.Aggregate ? "Autres éléments" : Circle.Name, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), Math.Clamp(r / 4, 12, 14), ink, VisualTreeHelper.GetDpi(this).PixelsPerDip)
            { MaxTextWidth = r * 1.45, MaxLineCount = 1, Trimming = TextTrimming.CharacterEllipsis, TextAlignment = TextAlignment.Center };
            var bytes = new FormattedText(SizeFormatter.Format(Circle.Bytes), CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 12, ink, VisualTreeHelper.GetDpi(this).PixelsPerDip)
            { MaxTextWidth = r * 1.45, MaxLineCount = 1, Trimming = TextTrimming.CharacterEllipsis, TextAlignment = TextAlignment.Center };
            dc.DrawText(name, new Point(r - name.MaxTextWidth / 2, r - 17));
            dc.DrawText(bytes, new Point(r - bytes.MaxTextWidth / 2, r + 2));
            return;
        }
        var text = new FormattedText(HasChildren ? Circle.Name : Circle.Name + "\n" + SizeFormatter.Format(Circle.Bytes), CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), Math.Clamp(r / 4, 12, 14), ink, VisualTreeHelper.GetDpi(this).PixelsPerDip)
        { MaxTextWidth = r * 1.45, MaxTextHeight = Math.Min(r * .7, 52), Trimming = TextTrimming.CharacterEllipsis, TextAlignment = TextAlignment.Center };
        dc.DrawText(text, new Point(r - text.MaxTextWidth / 2, HasChildren ? r * .12 : r - text.Height / 2));
        if (HasChildren)
        {
            var size = new FormattedText(SizeFormatter.Format(Circle.Bytes), CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), Math.Min(12, r / 5), ink, VisualTreeHelper.GetDpi(this).PixelsPerDip) { TextAlignment = TextAlignment.Center };
            dc.DrawText(size, new Point(r, 2 * r - size.Height - r * .10));
        }
    }
}
