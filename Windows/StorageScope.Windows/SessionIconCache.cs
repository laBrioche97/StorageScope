using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace StorageScope.Windows;

// Process lifetime only. Failed loads are not cached, and cancellation of a view
// does not cancel a shared decode that the next inventory can reuse.
internal sealed class SessionIconCache
{
    private const long Capacity = 64L * 1024 * 1024;
    private readonly object _gate = new();
    private readonly Dictionary<string, (ImageSource Image, long Cost, long Used)> _images = [];
    private readonly Dictionary<string, Task<ImageSource>> _pending = [];
    private long _clock, _bytes;
    internal static string Key(InstalledApplication app)
    {
        var stamp = "";
        try
        {
            var path = ApplicationIcons.ParseLocation(app.IconLocation ?? "")?.Path;
            if (path is not null && ApplicationEnrichment.SafeLocal(path))
            {
                var info = new FileInfo(path);
                stamp = $"{info.Length}:{info.LastWriteTimeUtc.Ticks}";
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { }
        return string.Join('|', app.Provider, app.ProductId, app.Name, app.RegistrationPath, app.PackageFullName, app.InstallLocation, app.IconLocation, app.Version, stamp);
    }
    internal ImageSource? Peek(string key)
    {
        lock (_gate)
        {
            if (!_images.TryGetValue(key, out var entry)) return null;
            _images[key] = (entry.Image, entry.Cost, ++_clock);
            return entry.Image;
        }
    }
    internal Task<ImageSource> GetAsync(string key, Func<Task<ImageSource>> load)
    {
        lock (_gate)
        {
            if (Peek(key) is { } image) return Task.FromResult(image);
            if (_pending.TryGetValue(key, out var pending)) return pending;
            // Scheduling also prevents a synchronously completed load from removing
            // its pending entry before that entry has been registered.
            return _pending[key] = Task.Run(async () =>
            {
                try
                {
                    var value = await load().ConfigureAwait(false);
                    if (ReferenceEquals(value, ApplicationIcons.Fallback)) return value;
                    if (value is BitmapSource bitmap && Math.Max(bitmap.PixelWidth, bitmap.PixelHeight) > 128)
                    {
                        var scale = 128d / Math.Max(bitmap.PixelWidth, bitmap.PixelHeight);
                        var thumbnail = new TransformedBitmap(bitmap, new ScaleTransform(scale, scale));
                        thumbnail.Freeze(); value = thumbnail;
                    }
                    var cost = value is BitmapSource b ? (long)b.PixelWidth * b.PixelHeight * 4 : 128L * 128 * 4;
                    lock (_gate)
                    {
                        _images[key] = (value, cost, ++_clock); _bytes += cost;
                        while (_bytes > Capacity && _images.Count > 1)
                        {
                            var oldest = _images.MinBy(pair => pair.Value.Used);
                            _images.Remove(oldest.Key); _bytes -= oldest.Value.Cost;
                        }
                    }
                    return value;
                }
                finally { lock (_gate) _pending.Remove(key); }
            });
        }
    }
}
