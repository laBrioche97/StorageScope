using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace StorageScope.Windows;

internal static class ApplicationIcons
{
    public static ImageSource Fallback { get; } = CreateFallback();
    private static ImageSource CreateFallback()
    {
        var drawing = new DrawingGroup();
        using (var context = drawing.Open())
        {
            context.DrawRoundedRectangle(Brushes.SlateBlue, null, new Rect(0, 0, 32, 32), 7, 7);
            foreach (var x in new[] { 7, 18 }) foreach (var y in new[] { 7, 18 }) context.DrawRoundedRectangle(Brushes.White, null, new Rect(x, y, 7, 7), 1, 1);
        }
        var image = new DrawingImage(drawing); image.Freeze(); return image;
    }

    internal static (string Path, int Index)? ParseLocation(string? location)
    {
        if (string.IsNullOrWhiteSpace(location)) return null;
        var match = Regex.Match(location.Trim(), "^(?:\"(?<path>[^\"]+)\"|(?<path>.+?))(?:\\s*,\\s*(?<index>-?\\d+))?$");
        if (!match.Success) return null;
        var path = Environment.ExpandEnvironmentVariables(match.Groups["path"].Value.Trim());
        if (!Path.IsPathFullyQualified(path) || path.StartsWith(@"\\", StringComparison.Ordinal) || path.Length < 3 || path[2..].Contains(':')) return null;
        if (match.Groups["index"].Success && !int.TryParse(match.Groups["index"].Value, out _)) return null;
        return (path, match.Groups["index"].Success ? int.Parse(match.Groups["index"].Value) : 0);
    }

    public static ImageSource Load(InstalledApplication product)
    {
        try
        {
            var reference = ParseLocation(product.IconLocation);
            if (reference is null || !File.Exists(reference.Value.Path)) return Fallback;
            var (path, index) = reference.Value;
            for (var ancestor = path; !string.IsNullOrEmpty(ancestor); ancestor = Path.GetDirectoryName(ancestor))
                if ((File.GetAttributes(ancestor) & (FileAttributes.ReparsePoint | FileAttributes.Offline | (FileAttributes)0x00400000 | (FileAttributes)0x00040000)) != 0) return Fallback;
            if (new[] { ".png", ".jpg", ".jpeg", ".ico" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase))
            {
                if (new FileInfo(path).Length > 20_000_000) return Fallback;
                if (Path.GetExtension(path).Equals(".ico", StringComparison.OrdinalIgnoreCase))
                {
                    using var stream = File.OpenRead(path);
                    var frame = new IconBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames.MaxBy(item => item.PixelWidth)!;
                    return Detach(frame);
                }
                var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.DecodePixelWidth = 64; bitmap.UriSource = new Uri(path); bitmap.EndInit(); return Detach(bitmap);
            }
            if (!new[] { ".exe", ".dll" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase)) return Fallback;
            IntPtr large = IntPtr.Zero, small = IntPtr.Zero;
            try
            {
                if (SHDefExtractIcon(path, index, 0, out large, out small, 32) < 0 || large == IntPtr.Zero) return Fallback;
                var bitmap = Imaging.CreateBitmapSourceFromHIcon(large, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                return Detach(bitmap);
            }
            finally { if (large != IntPtr.Zero) DestroyIcon(large); if (small != IntPtr.Zero) DestroyIcon(small); }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or FormatException or System.Security.SecurityException or COMException) { return Fallback; }
    }

    internal static BitmapSource Detach(BitmapSource source)
    {
        if (source.PixelWidth > 4096 || source.PixelHeight > 4096) throw new IOException("Image trop volumineuse.");
        var converted = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        var stride = checked(converted.PixelWidth * 4);
        var pixels = new byte[checked(stride * converted.PixelHeight)];
        converted.CopyPixels(pixels, stride, 0);
        var bitmap = BitmapSource.Create(converted.PixelWidth, converted.PixelHeight, 96, 96, PixelFormats.Bgra32, null, pixels, stride);
        bitmap.Freeze();
        return bitmap;
    }

    [DllImport("shell32.dll", EntryPoint = "SHDefExtractIconW", CharSet = CharSet.Unicode)]
    private static extern int SHDefExtractIcon(string path, int index, uint flags, out IntPtr large, out IntPtr small, uint size);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr icon);
}
