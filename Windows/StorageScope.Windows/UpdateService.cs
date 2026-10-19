using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace StorageScope.Windows;

public sealed record UpdateManifest(int SchemaVersion, string Version, int MinimumWindowsBuild, string Notes,
    string DownloadUrl, string Sha256, long Size, string Architecture);

public sealed class UpdateService
{
    private const string Repository = "https://github.com/laBrioche97/StorageScope/releases/download/";
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(12) };
    private readonly string _state = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StorageScope", "update-check.txt");
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    public static Version CurrentVersion => Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0);
    public static string? PublicKey
    {
        get
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("StorageScope.UpdatePublicKey");
            if (stream is null) return null;
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd();
        }
    }
    public static string? ExpectedPublisher => Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(item => item.Key == "UpdatePublisher")?.Value;
    public bool IsConfigured => !string.IsNullOrWhiteSpace(PublicKey) && !string.IsNullOrWhiteSpace(ExpectedPublisher);

    public UpdateService() { _http.DefaultRequestHeaders.UserAgent.ParseAdd("StorageScope/3.0"); }

    public async Task<UpdateManifest?> CheckAsync(bool manual, CancellationToken token)
    {
        if (!IsConfigured) { if (manual) throw new IOException("Les mises à jour seront activées dans les versions signées de StorageScope. Cette version de développement fonctionne entièrement hors ligne."); return null; }
        if (!manual && File.Exists(_state) && DateTimeOffset.TryParse(await File.ReadAllTextAsync(_state, token), out var last) && DateTimeOffset.UtcNow - last < TimeSpan.FromDays(1)) return null;
        Directory.CreateDirectory(Path.GetDirectoryName(_state)!);
        await File.WriteAllTextAsync(_state, DateTimeOffset.UtcNow.ToString("O"), token);
        var releaseBytes = await ReadLimitedAsync("https://api.github.com/repos/laBrioche97/StorageScope/releases/latest", 256 * 1024, token);
        using var release = JsonDocument.Parse(releaseBytes);
        var root = release.RootElement;
        if (root.GetProperty("draft").GetBoolean() || root.GetProperty("prerelease").GetBoolean()) return null;
        var tag = root.GetProperty("tag_name").GetString() ?? "";
        if (!Version.TryParse(tag.TrimStart('v'), out var version) || version <= CurrentVersion) return null;
        var assets = root.GetProperty("assets").EnumerateArray().ToArray();
        string? Asset(string name) => assets.FirstOrDefault(item => item.GetProperty("name").GetString() == name).ValueKind == JsonValueKind.Undefined ? null
            : assets.First(item => item.GetProperty("name").GetString() == name).GetProperty("browser_download_url").GetString();
        var manifestUrl = Asset("windows-update.json");
        var signatureUrl = Asset("windows-update.json.sig");
        if (manifestUrl is null || signatureUrl is null) return null;
        if (!IsReleaseUrl(manifestUrl, tag, "windows-update.json") || !IsReleaseUrl(signatureUrl, tag, "windows-update.json.sig")) throw new IOException("Source de mise à jour inattendue.");
        var manifest = await ReadLimitedAsync(manifestUrl, 64 * 1024, token);
        var signature = await ReadLimitedAsync(signatureUrl, 1024, token);
        var validated = ValidateManifest(manifest, signature, PublicKey!, tag, CurrentVersion);
        if (Environment.OSVersion.Version.Build < validated.MinimumWindowsBuild) return null;
        return validated;
    }

    public static UpdateManifest ValidateManifest(byte[] bytes, byte[] signature, string publicKey, string tag, Version current)
    {
        using var rsa = RSA.Create();
        rsa.ImportFromPem(publicKey);
        if (rsa.KeySize < 3072 || !rsa.VerifyData(bytes, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)) throw new CryptographicException("Signature du manifeste invalide.");
        var manifest = JsonSerializer.Deserialize<UpdateManifest>(bytes, JsonOptions) ?? throw new IOException("Manifeste absent.");
        if (manifest.SchemaVersion != 1 || !Version.TryParse(manifest.Version, out var version) || version <= current || tag != "v" + manifest.Version
            || manifest.Architecture != "universal" || manifest.MinimumWindowsBuild < 19041 || manifest.Size <= 0 || manifest.Size > 512L * 1024 * 1024
            || !System.Text.RegularExpressions.Regex.IsMatch(manifest.Sha256 ?? "", "^[a-fA-F0-9]{64}$")
            || !IsReleaseUrl(manifest.DownloadUrl, tag, "StorageScope-Windows-Setup.exe")) throw new IOException("Métadonnées de mise à jour incompatibles.");
        return manifest;
    }

    private static bool IsReleaseUrl(string url, string tag, string file) => url == Repository + Uri.EscapeDataString(tag) + "/" + file;

    public async Task<string> DownloadVerifiedAsync(UpdateManifest manifest, IProgress<double> progress, CancellationToken token)
    {
        var directory = Path.Combine(Path.GetDirectoryName(_state)!, "Updates", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "StorageScope-Windows-Setup.exe");
        try
        {
            using var requestCancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
            requestCancellation.CancelAfter(TimeSpan.FromMinutes(15));
            using var response = await _http.GetAsync(manifest.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, requestCancellation.Token);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength is long expected && expected != manifest.Size) throw new IOException("La taille du téléchargement ne correspond pas au manifeste signé.");
            await using var input = await response.Content.ReadAsStreamAsync(requestCancellation.Token);
            await using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, true))
            {
                var buffer = new byte[128 * 1024];
                long received = 0;
                int count;
                while ((count = await input.ReadAsync(buffer, requestCancellation.Token)) > 0)
                {
                    received += count;
                    if (received > manifest.Size) throw new IOException("Téléchargement plus volumineux que prévu.");
                    await output.WriteAsync(buffer.AsMemory(0, count), requestCancellation.Token);
                    progress.Report(received / (double)manifest.Size);
                }
                if (received != manifest.Size) throw new IOException("Téléchargement incomplet.");
            }
            await Task.Run(() => VerifyInstaller(path, manifest), requestCancellation.Token);
            return path;
        }
        catch { if (File.Exists(path)) File.Delete(path); throw; }
    }

    public static void VerifyInstaller(string path, UpdateManifest manifest)
    {
        using var stream = File.OpenRead(path);
        var hash = Convert.ToHexString(SHA256.HashData(stream));
        if (!hash.Equals(manifest.Sha256, StringComparison.OrdinalIgnoreCase)) throw new CryptographicException("Intégrité du paquet invalide.");
        Authenticode.Verify(path, ExpectedPublisher ?? throw new CryptographicException("Identité de l’éditeur non configurée."));
    }

    private async Task<byte[]> ReadLimitedAsync(string url, int limit, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        using var response = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        response.EnsureSuccessStatusCode();
        await using var input = await response.Content.ReadAsStreamAsync(timeout.Token);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        int count;
        while ((count = await input.ReadAsync(buffer, timeout.Token)) > 0)
        {
            if (output.Length + count > limit) throw new IOException("Réponse de mise à jour trop volumineuse.");
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }
}

internal static class Authenticode
{
    public static void Verify(string path, string publisher)
    {
        var file = new TrustFile { Size = (uint)Marshal.SizeOf<TrustFile>(), Path = path };
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<TrustFile>());
        try
        {
            Marshal.StructureToPtr(file, pointer, false);
            var data = new TrustData { Size = (uint)Marshal.SizeOf<TrustData>(), UI = 2, Revocation = 1, Choice = 1, File = pointer, Flags = 0x0080 };
            var action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
            if (WinVerifyTrust(IntPtr.Zero, ref action, ref data) != 0) throw new CryptographicException("Signature Authenticode non approuvée.");
#pragma warning disable SYSLIB0057
            using var certificate = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
            if (!string.Equals(certificate.Subject, publisher, StringComparison.Ordinal)) throw new CryptographicException("L’éditeur du paquet ne correspond pas à StorageScope.");
        }
        finally { Marshal.DestroyStructure<TrustFile>(pointer); Marshal.FreeHGlobal(pointer); }
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct TrustFile { public uint Size; [MarshalAs(UnmanagedType.LPWStr)] public string Path; public IntPtr File, Subject; }
    [StructLayout(LayoutKind.Sequential)]
    private struct TrustData { public uint Size; public IntPtr Callback, Client; public uint UI, Revocation, Choice; public IntPtr File; public uint StateAction; public IntPtr State, URL; public uint Flags, UIContext; }
    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
}
