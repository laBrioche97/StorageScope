using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace StorageScope.Windows;

internal sealed record RecycleVolume(string Root, long Bytes, long Items, string? Error = null);
internal sealed record RecycleSummary(IReadOnlyList<RecycleVolume> Volumes)
{
    public long Bytes => Volumes.Sum(v => v.Bytes);
    public long Items => Volumes.Sum(v => v.Items);
    public bool Partial => Volumes.Any(v => v.Error is not null);
    public bool Available => Volumes.Any(v => v.Error is null);
}
internal sealed record EmptyRecycleRequest(string[] Roots, bool Confirmed);
internal sealed record EmptyRecycleResult(RecycleSummary Summary, IReadOnlyList<string> Errors, long? ObservedFreeChange);

internal static class RecycleBinService
{
    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct QueryInfo { public uint Size; public long Bytes; public long Items; }
    [DllImport("shell32.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern int SHQueryRecycleBinW(string root, ref QueryInfo info);
    [DllImport("shell32.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern int SHEmptyRecycleBinW(nint owner, string root, uint flags);
    internal static string[] Roots() => DriveInfo.GetDrives().Where(d => d.IsReady && d.DriveType is DriveType.Fixed or DriveType.Removable).Select(d => d.RootDirectory.FullName).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    private static RecycleSummary Query(string[] roots) => new(roots.Select(root =>
    {
        try
        {
            var info = new QueryInfo { Size = (uint)Marshal.SizeOf<QueryInfo>() };
            Marshal.ThrowExceptionForHR(SHQueryRecycleBinW(root, ref info));
            return new RecycleVolume(root, Math.Max(0, info.Bytes), Math.Max(0, info.Items));
        }
        catch (Exception error) { return new RecycleVolume(root, 0, 0, error.Message); }
    }).ToArray());
    internal static int Worker(bool empty)
    {
        try
        {
            var roots = Roots();
            if (!empty) { Console.WriteLine(JsonSerializer.Serialize(Query(roots))); return 0; }
            var line = Console.ReadLine();
            if (line is null || line.Length > 16384) throw new IOException("Confirmation absente.");
            var request = JsonSerializer.Deserialize<EmptyRecycleRequest>(line);
            if (request is not { Confirmed: true } || request.Roots.Length == 0 || request.Roots.Any(r => !roots.Contains(r, StringComparer.OrdinalIgnoreCase))) throw new IOException("Périmètre de corbeille invalide ou volume déconnecté.");
            var before = Free(request.Roots); var errors = new List<string>();
            foreach (var root in request.Roots.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                // Only the OS user's recycle bin. Never enumerate/delete $Recycle.Bin.
                var hr = SHEmptyRecycleBinW(0, root, 1 | 2 | 4);
                if (hr < 0) errors.Add(root + " : " + Marshal.GetExceptionForHR(hr)?.Message);
            }
            var after = Free(request.Roots);
            Console.WriteLine(JsonSerializer.Serialize(new EmptyRecycleResult(Query(roots), errors, before.HasValue && after.HasValue ? after - before : null)));
            return 0;
        }
        catch (Exception error) { Diagnostics.Write("corbeille-système", error); Console.Error.WriteLine(error.Message); return 1; }
    }
    private static long? Free(string[] roots)
    {
        try { return roots.Sum(root => new DriveInfo(root).AvailableFreeSpace); } catch (IOException) { return null; }
    }
    internal static Task<RecycleSummary> QueryAsync() => RunAsync<RecycleSummary>(false, null);
    internal static Task<EmptyRecycleResult> EmptyAsync(EmptyRecycleRequest request) => RunAsync<EmptyRecycleResult>(true, request);
    private static async Task<T> RunAsync<T>(bool empty, EmptyRecycleRequest? request)
    {
        var executable = Environment.ProcessPath!;
        if (!Path.GetFileNameWithoutExtension(executable).Equals("StorageScope", StringComparison.OrdinalIgnoreCase)) executable = Path.Combine(AppContext.BaseDirectory, "StorageScope.exe");
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        info.ArgumentList.Add(empty ? "--empty-recycle-bin" : "--query-recycle-bin");
        using var process = Process.Start(info) ?? throw new IOException("Le moteur de corbeille n’a pas démarré.");
        if (request is not null) await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(request));
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        if (empty) await process.WaitForExitAsync(); // A destructive OS call is never killed/retried.
        else
        {
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30)); }
            catch (TimeoutException) { process.Kill(); throw new IOException("Lecture de la corbeille trop longue. Réessayez avec Actualiser."); }
        }
        var message = await error;
        if (process.ExitCode != 0) throw new IOException($"Corbeille interrompue (0x{process.ExitCode:X8}). Résultat à vérifier ; aucune nouvelle tentative automatique. " + message);
        return JsonSerializer.Deserialize<T>(await output) ?? throw new IOException("Réponse de la corbeille absente.");
    }
}
