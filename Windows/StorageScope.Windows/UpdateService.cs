using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net;
using System.Net.Http.Headers;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace StorageScope.Windows;

public sealed record UpdateManifest(int SchemaVersion, string Version, int MinimumWindowsBuild, string Notes,
    string DownloadUrl, string Sha256, long Size, string Architecture, string? AuthenticodePublisher = null)
{
    internal byte[]? SignedPayload { get; init; }
    internal byte[]? Signature { get; init; }
}

public sealed class UpdateService
{
    private const string Repository = "https://github.com/laBrioche97/StorageScope/releases/download/";
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(12) };
    private readonly string _state = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StorageScope", "update-check.txt");
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly string? _testVerificationKey;
    private string? VerificationKey => _testVerificationKey ?? PublicKey;
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
    public bool IsConfigured => !string.IsNullOrWhiteSpace(PublicKey);
    public string Status { get; private set; } = "Vérification non effectuée.";
    public string? ManualDownloadUrl { get; private set; }

    public bool IsOffline { get; private set; }
    public bool UsingCachedOffer { get; private set; }
    public DateTimeOffset? LastVerified { get; private set; }
    private sealed record CachedOffer(byte[] Payload, byte[] Signature, DateTimeOffset Verified);
    public UpdateService() { _http.DefaultRequestHeaders.UserAgent.ParseAdd("StorageScope/" + CurrentVersion); }

    internal UpdateService(HttpClient client, string state, string? verificationKey = null) { _http = client; _state = state; _testVerificationKey = verificationKey; _http.DefaultRequestHeaders.UserAgent.ParseAdd("StorageScope/" + CurrentVersion); }

    public async Task<UpdateManifest?> CheckAsync(bool manual, CancellationToken token)
    {
        IsOffline = UsingCachedOffer = false;
        try { return await CheckOnlineAsync(token); }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException && !token.IsCancellationRequested)
        {
            IsOffline = true;
            var cached = await LoadOfferAsync(token);
            UsingCachedOffer = cached is not null;
            Status = cached is null ? "Connexion indisponible · réessayer lorsque vous serez en ligne."
                : $"StorageScope {cached.Version} disponible · dernière vérification le {LastVerified:g}. Connexion requise pour revalider avant installation.";
            return cached;
        }
    }

    private string OfferPath => _state + ".offer.json";
    private async Task<UpdateManifest?> LoadOfferAsync(CancellationToken token)
    {
        try
        {
            if (!File.Exists(OfferPath) || new FileInfo(OfferPath).Length > 100 * 1024) return null;
            var cached = JsonSerializer.Deserialize<CachedOffer>(await File.ReadAllBytesAsync(OfferPath, token));
            if (cached is null || VerificationKey is null) return null;
            var version = JsonSerializer.Deserialize<UpdateManifest>(cached.Payload, JsonOptions)?.Version ?? "";
            var offer = ValidateManifest(cached.Payload, cached.Signature, VerificationKey, "v" + version, CurrentVersion);
            if (Environment.OSVersion.Version.Build < offer.MinimumWindowsBuild) return null;
            LastVerified = cached.Verified;
            return offer;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or CryptographicException) { Diagnostics.Write("offre-mise-à-jour", error); return null; }
    }

    public async Task<UpdateManifest> RevalidateAsync(UpdateManifest offered, CancellationToken token)
    {
        var fresh = await CheckOnlineAsync(token);
        if (fresh is null || fresh.Version != offered.Version || fresh.Sha256 != offered.Sha256 || fresh.DownloadUrl != offered.DownloadUrl)
            throw new IOException("L’offre a changé. Recherchez à nouveau les mises à jour avant de l’installer.");
        return fresh;
    }

    private async Task<UpdateManifest?> CheckOnlineAsync(CancellationToken token)
    {
        Status = "Recherche d’une mise à jour…"; ManualDownloadUrl = null;
        var releaseBytes = await ReadReleaseAsync(token);
        using var release = JsonDocument.Parse(releaseBytes);
        var root = release.RootElement;
        if (root.GetProperty("draft").GetBoolean() || root.GetProperty("prerelease").GetBoolean()) throw new IOException("Aucune release stable vérifiable.");
        var tag = root.GetProperty("tag_name").GetString() ?? "";
        if (!Version.TryParse(tag.TrimStart('v'), out var version)) throw new IOException("Version de release invalide.");
        async Task Checked()
        {
            LastVerified = DateTimeOffset.UtcNow;
            try { Directory.CreateDirectory(Path.GetDirectoryName(_state)!); await File.WriteAllTextAsync(_state, DateTimeOffset.UtcNow.ToString("O"), token); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Diagnostics.Write("état-mise-à-jour", error); }
        }
        if (version <= CurrentVersion) { Status = "Vous disposez de la dernière version compatible publiée."; await Checked(); TryDeleteOffer(); return null; }
        var assets = root.GetProperty("assets").EnumerateArray().ToArray();
        string? Asset(string name) => assets.FirstOrDefault(item => item.GetProperty("name").GetString() == name).ValueKind == JsonValueKind.Undefined ? null
            : assets.First(item => item.GetProperty("name").GetString() == name).GetProperty("browser_download_url").GetString();
        var manifestUrl = Asset("windows-update.json");
        var signatureUrl = Asset("windows-update.json.sig");
        if (!IsConfigured || manifestUrl is null || signatureUrl is null)
        {
            Status = $"StorageScope {version} est disponible. L’installation automatique n’est pas configurée pour cette distribution. Téléchargez l’installateur depuis la release officielle.";
            ManualDownloadUrl = "https://github.com/laBrioche97/StorageScope/releases/tag/" + Uri.EscapeDataString(tag);
            await Checked(); return null;
        }
        if (!IsReleaseUrl(manifestUrl, tag, "windows-update.json") || !IsReleaseUrl(signatureUrl, tag, "windows-update.json.sig")) throw new IOException("Source de mise à jour inattendue.");
        var manifest = await ReadLimitedAsync(manifestUrl, 64 * 1024, token);
        var signature = await ReadLimitedAsync(signatureUrl, 1024, token);
        var validated = ValidateManifest(manifest, signature, VerificationKey!, tag, CurrentVersion);
        if (Environment.OSVersion.Version.Build < validated.MinimumWindowsBuild) { Status = "La nouvelle version demande une version plus récente de Windows."; await Checked(); return null; }
        Status = $"StorageScope {validated.Version} est disponible."; await Checked();
        try { await File.WriteAllBytesAsync(OfferPath, JsonSerializer.SerializeToUtf8Bytes(new CachedOffer(manifest, signature, LastVerified!.Value)), token); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Diagnostics.Write("cache-offre", error); }
        return validated;
    }

    private void TryDeleteOffer() { try { File.Delete(OfferPath); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Diagnostics.Write("cache-offre", error); } }

    private async Task<byte[]> ReadReleaseAsync(CancellationToken token)
    {
        var path = _state + ".release.json";
        var etagPath = _state + ".etag";
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/repos/laBrioche97/StorageScope/releases/latest");
        if (File.Exists(path) && new FileInfo(path).Length <= 256 * 1024 && File.Exists(etagPath) && new FileInfo(etagPath).Length < 512
            && EntityTagHeaderValue.TryParse(await File.ReadAllTextAsync(etagPath, token), out var tag)) request.Headers.IfNoneMatch.Add(tag);
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        if (response.StatusCode == HttpStatusCode.NotModified) return await File.ReadAllBytesAsync(path, token);
        response.EnsureSuccessStatusCode();
        var bytes = await ReadBodyAsync(response, 256 * 1024, token);
        // Cache only well-formed release JSON. The offer still needs its own signature.
        using var parsed = JsonDocument.Parse(bytes);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_state)!);
            await File.WriteAllBytesAsync(path, bytes, token);
            if (response.Headers.ETag is not null) await File.WriteAllTextAsync(etagPath, response.Headers.ETag.ToString(), token);
            else File.Delete(etagPath);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Diagnostics.Write("cache-release", error); }
        return bytes;
    }

    public static UpdateManifest ValidateManifest(byte[] bytes, byte[] signature, string publicKey, string tag, Version current)
    {
        using var rsa = RSA.Create();
        rsa.ImportFromPem(publicKey);
        if (rsa.KeySize < 3072 || !rsa.VerifyData(bytes, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)) throw new CryptographicException("Signature du manifeste invalide.");
        var manifest = JsonSerializer.Deserialize<UpdateManifest>(bytes, JsonOptions) ?? throw new IOException("Manifeste absent.");
        if (manifest.SchemaVersion is not (1 or 2) || !Version.TryParse(manifest.Version, out var version) || version <= current || tag != "v" + manifest.Version
            || manifest.Architecture != "universal" || manifest.MinimumWindowsBuild < 19041 || manifest.Size <= 0 || manifest.Size > 512L * 1024 * 1024
            || !System.Text.RegularExpressions.Regex.IsMatch(manifest.Sha256 ?? "", "^[a-fA-F0-9]{64}$")
            || !(IsReleaseUrl(manifest.DownloadUrl, tag, "StorageScope-Windows-Setup.exe") || manifest.SchemaVersion == 2 && IsReleaseUrl(manifest.DownloadUrl, tag, "StorageScope-Windows-Setup-DEVELOPMENT.exe"))) throw new IOException("Métadonnées de mise à jour incompatibles.");
        return manifest with { SignedPayload = bytes.ToArray(), Signature = signature.ToArray() };
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
        if (manifest.SignedPayload is null || manifest.Signature is null || PublicKey is null) throw new CryptographicException("Preuve de signature du manifeste absente.");
        var verified = ValidateManifest(manifest.SignedPayload, manifest.Signature, PublicKey, "v" + manifest.Version, CurrentVersion);
        if (!JsonSerializer.SerializeToUtf8Bytes(verified).SequenceEqual(JsonSerializer.SerializeToUtf8Bytes(manifest))) throw new CryptographicException("Le manifeste a changé après sa vérification.");
        VerifyContents(path, manifest);
        var policyPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StorageScope", "update-publisher.txt");
        var pinnedPublisher = File.Exists(policyPath) ? File.ReadAllText(policyPath) : null;
        var publisher = !string.IsNullOrWhiteSpace(ExpectedPublisher) ? ExpectedPublisher : !string.IsNullOrWhiteSpace(pinnedPublisher) ? pinnedPublisher : manifest.AuthenticodePublisher;
        if (!string.IsNullOrWhiteSpace(publisher))
        {
            if (!string.IsNullOrWhiteSpace(manifest.AuthenticodePublisher) && manifest.AuthenticodePublisher != publisher) throw new CryptographicException("Changement d’éditeur refusé.");
            Authenticode.Verify(path, publisher);
            Directory.CreateDirectory(Path.GetDirectoryName(policyPath)!); File.WriteAllText(policyPath, publisher);
        }
        else if (manifest.SchemaVersion == 1) throw new CryptographicException("Identité de l’éditeur non configurée.");
    }

    internal static void VerifyContents(string path, UpdateManifest manifest)
    {
        using var stream = File.OpenRead(path);
        if (stream.Length != manifest.Size) throw new CryptographicException("Taille du paquet invalide.");
        var hash = Convert.ToHexString(SHA256.HashData(stream));
        if (!hash.Equals(manifest.Sha256, StringComparison.OrdinalIgnoreCase)) throw new CryptographicException("Intégrité du paquet invalide.");
    }

    internal static void CleanupDownloads()
    {
        try
        {
            var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StorageScope", "Updates");
            if (!Directory.Exists(root) || !ApplicationEnrichment.SafeLocal(root)) return;
            foreach (var directory in Directory.EnumerateDirectories(root))
            {
                if (!Guid.TryParseExact(Path.GetFileName(directory), "N", out _) || !ApplicationEnrichment.SafeLocal(directory)) continue;
                foreach (var path in Directory.EnumerateFiles(directory))
                    if (Path.GetFileName(path) == "StorageScope-Windows-Setup.exe" && ApplicationEnrichment.SafeLocal(path))
                        try { File.Delete(path); } catch (IOException) { }
                if (!Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { Diagnostics.Write("cache-mise-à-jour", error); }
    }

    private async Task<byte[]> ReadLimitedAsync(string url, int limit, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        using var response = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        response.EnsureSuccessStatusCode();
        return await ReadBodyAsync(response, limit, timeout.Token);
    }

    private static async Task<byte[]> ReadBodyAsync(HttpResponseMessage response, int limit, CancellationToken token)
    {
        await using var input = await response.Content.ReadAsStreamAsync(token);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        int count;
        while ((count = await input.ReadAsync(buffer, token)) > 0)
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
