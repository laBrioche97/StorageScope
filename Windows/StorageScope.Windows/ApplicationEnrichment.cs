using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Windows.Media;
using Microsoft.Win32;

namespace StorageScope.Windows;

internal static class ApplicationEnrichment
{
    private static readonly HttpClient Images = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(5) };
    internal static bool SafeLocal(string path)
    {
        if (!Path.IsPathFullyQualified(path) || path.StartsWith(@"\\", StringComparison.Ordinal)) return false;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var clouds = new[] { Environment.GetEnvironmentVariable("OneDrive"), Environment.GetEnvironmentVariable("OneDriveCommercial"), Environment.GetEnvironmentVariable("OneDriveConsumer"), Path.Combine(home, "Dropbox"), Path.Combine(home, "iCloudDrive"), Path.Combine(home, "Google Drive") };
        if (clouds.Where(root => !string.IsNullOrWhiteSpace(root)).Any(root => DeletionSafetyPolicy.IsWithin(path, root!))) return false;
        for (var ancestor = path; !string.IsNullOrEmpty(ancestor); ancestor = Path.GetDirectoryName(ancestor))
            if ((File.GetAttributes(ancestor) & (FileAttributes.ReparsePoint | FileAttributes.Offline | (FileAttributes)0x00400000 | (FileAttributes)0x00040000)) != 0) return false;
        return true;
    }

    internal static IEnumerable<string> LocalIcons(InstalledApplication app)
    {
        if (app.IconLocation is string declared)
        {
            yield return declared;
            var parsed = ApplicationIcons.ParseLocation(declared);
            if (parsed is not null && !File.Exists(parsed.Value.Path) && Directory.Exists(Path.GetDirectoryName(parsed.Value.Path)))
            {
                var parent = Path.GetDirectoryName(parsed.Value.Path)!;
                if (SafeLocal(parent))
                    foreach (var variant in Directory.EnumerateFiles(parent, Path.GetFileNameWithoutExtension(parsed.Value.Path) + "*.png").Take(10)) yield return variant;
            }
        }
        if (app.Provider == "Steam" && SteamId(app) is string id && Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) is string steam)
        {
            var cache = Path.Combine(steam, "appcache", "librarycache");
            if (Directory.Exists(cache) && SafeLocal(cache))
            {
                foreach (var path in Directory.EnumerateFiles(cache, id + "_*.jpg").Take(10)) yield return path;
                var sub = Path.Combine(cache, id);
                if (Directory.Exists(sub) && SafeLocal(sub)) foreach (var path in Directory.EnumerateFiles(sub).Where(path => Path.GetExtension(path) is ".jpg" or ".png").Take(10)) yield return path;
            }
        }
        if (app.InstallLocation is string location && Directory.Exists(location) && SafeLocal(location))
            foreach (var executable in Directory.EnumerateFiles(location, "*.exe").Where(path => !Path.GetFileName(path).Contains("unins", StringComparison.OrdinalIgnoreCase)).Take(12)) yield return executable;
    }
    private static string? SteamId(InstalledApplication app) => app.Provider == "Steam" && app.ProductId is string product && Regex.IsMatch(product, @"^Steam App \d+$") ? product[10..] : null;

    internal static async Task<ImageSource> IconAsync(InstalledApplication app, CancellationToken token)
    {
        try
        {
            var local = await Task.Run(() =>
            {
                foreach (var path in LocalIcons(app))
                {
                    token.ThrowIfCancellationRequested();
                    var image = ApplicationIcons.Load(app with { IconLocation = path });
                    if (!ReferenceEquals(image, ApplicationIcons.Fallback)) return image;
                }
                return ApplicationIcons.Fallback;
            }, token);
            if (!ReferenceEquals(local, ApplicationIcons.Fallback) || SteamId(app) is not string id) return local;
            var cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StorageScope", "Icons");
            var path = Path.Combine(cache, "steam-" + id + ".jpg");
            if (File.Exists(path)) return await Task.Run(() => ApplicationIcons.Load(app with { IconLocation = path }), token);
            // Exact Steam app IDs only. No search by display name or third-party artwork.
            using var response = await Images.GetAsync("https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/" + id + "/header.jpg", HttpCompletionOption.ResponseHeadersRead, token);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentType?.MediaType is not ("image/jpeg" or "image/png") || response.Content.Headers.ContentLength > 1_048_576) return local;
            await using var input = await response.Content.ReadAsStreamAsync(token);
            using var buffer = new MemoryStream(); var bytes = new byte[8192]; int count;
            while ((count = await input.ReadAsync(bytes, token)) > 0) { if (buffer.Length + count > 1_048_576) return local; buffer.Write(bytes, 0, count); }
            Directory.CreateDirectory(cache);
            if (Directory.EnumerateFiles(cache).Take(513).Count() > 512) foreach (var old in new DirectoryInfo(cache).EnumerateFiles().OrderBy(file => file.LastWriteTimeUtc).Take(32)) old.Delete();
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".jpg";
            try
            {
                await File.WriteAllBytesAsync(temporary, buffer.ToArray(), token);
                var image = await Task.Run(() => ApplicationIcons.Load(app with { IconLocation = temporary }), token);
                if (ReferenceEquals(image, ApplicationIcons.Fallback)) return local;
                File.Move(temporary, path, true); return image;
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or HttpRequestException or OperationCanceledException or ArgumentException or System.Security.SecurityException)
        { Diagnostics.Write("logo-indisponible", error); return ApplicationIcons.Fallback; }
    }

    internal static InstalledApplication Measure(InstalledApplication app, CancellationToken token)
    {
        var root = app.InstallLocation;
        try
        {
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root) || !SafeLocal(root)) return app with { SizeStatus = app.HasKnownSize ? "Taille déclarée" : "Indisponible" };
            if (new[] { Path.GetPathRoot(root), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), Environment.GetFolderPath(Environment.SpecialFolder.Windows), Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) }.Where(value => !string.IsNullOrWhiteSpace(value)).Any(value => Path.GetFullPath(root).TrimEnd('\\').Equals(value!.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))) return app with { SizeStatus = app.HasKnownSize ? "Taille déclarée" : "Indisponible" };
            var watch = Stopwatch.StartNew();
            long bytes = 0; var partial = false; var files = 0;
            var seen = new HashSet<(uint, ulong)>(); var stack = new Stack<string>(); stack.Push(root);
            while (stack.TryPop(out var directory))
            {
                token.ThrowIfCancellationRequested();
                if (watch.Elapsed > TimeSpan.FromSeconds(20) || files > 200_000) { partial = true; break; }
                try
                {
                    if (!SafeLocal(directory)) { partial = true; continue; }
                    foreach (var path in Directory.EnumerateFileSystemEntries(directory))
                    {
                        token.ThrowIfCancellationRequested();
                        if (++files > 200_000 || watch.Elapsed > TimeSpan.FromSeconds(20)) { partial = true; break; }
                        try
                        {
                            if (!SafeLocal(path)) { partial = true; continue; }
                            var identity = DeletionSafetyPolicy.ReadIdentity(path, allowHardLinks: true);
                            if (!seen.Add((identity.Volume, identity.FileId))) continue;
                            if (identity.IsDirectory) stack.Push(path); else bytes = checked(bytes + identity.Length);
                        }
                        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { partial = true; }
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { partial = true; }
            }
            return app with { EstimatedBytes = bytes, SizeStatus = partial ? "Partielle (au moins)" : "Mesurée" };
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or OverflowException or System.Security.SecurityException)
        { Diagnostics.Write("taille-indisponible", error); return app with { SizeStatus = app.HasKnownSize ? "Taille déclarée" : "Indisponible" }; }
    }
}
