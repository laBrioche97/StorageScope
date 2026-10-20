using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace StorageScope.Windows;

// A bounded native button per visible circle gives real keyboard focus and UI
// Automation invocation without introducing a web runtime or a giant visual tree.
internal sealed class BubbleButton : Button
{
    internal required FolderCircle Circle { get; init; }
    internal bool Highlighted { get; init; }
    protected override HitTestResult? HitTestCore(PointHitTestParameters hitTestParameters)
    {
        var point = hitTestParameters.HitPoint;
        return Math.Pow(point.X - ActualWidth / 2, 2) + Math.Pow(point.Y - ActualHeight / 2, 2) <= Math.Pow(ActualWidth / 2, 2) ? new PointHitTestResult(this, point) : null;
    }
    protected override void OnRender(DrawingContext dc)
    {
        var r = ActualWidth / 2;
        var color = Circle.Aggregate ? Color.FromRgb(95, 103, 120) : (Circle.Depth % 3) switch
        { 0 => Color.FromRgb(131, 40, 99), 1 => Color.FromRgb(45, 91, 134), _ => Color.FromRgb(36, 111, 105) };
        dc.DrawEllipse(new SolidColorBrush(color), new Pen(Highlighted || IsKeyboardFocused ? Brushes.White : new SolidColorBrush(Color.FromArgb(170, 220, 225, 235)), Highlighted || IsKeyboardFocused ? 3 : 1), new(r, r), Math.Max(0, r - 2), Math.Max(0, r - 2));
        if (r < 32) return;
        var text = new FormattedText(Circle.Name + "\n" + SizeFormatter.Format(Circle.Bytes), CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), Math.Min(14, r / 4), Brushes.White, VisualTreeHelper.GetDpi(this).PixelsPerDip)
        { MaxTextWidth = r * 1.45, MaxTextHeight = Math.Min(r * .7, 52), Trimming = TextTrimming.CharacterEllipsis, TextAlignment = TextAlignment.Center };
        dc.DrawText(text, new Point(r - text.MaxTextWidth / 2, r - text.Height / 2));
    }
}
