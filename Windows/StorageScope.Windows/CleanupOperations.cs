using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace StorageScope.Windows;

public sealed record CleanupSelection(ScanEntry Entry, FileSnapshot Identity, string? Keeper = null, FileSnapshot? KeeperIdentity = null, GameCacheAuthorization? GameCache = null);
public sealed record CleanupOutcome(string Path, string Status, long Bytes, string? Error = null);
public sealed record CleanupPreparation(IReadOnlyList<CleanupSelection> Ready, IReadOnlyList<CleanupOutcome> Skipped);

public static class OperationHistory
{
    public static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StorageScope", "History");
    private static readonly object Gate = new();
    public static void Append(object entry)
    {
        lock (Gate)
        {
            Directory.CreateDirectory(DirectoryPath);
            var path = Path.Combine(DirectoryPath, "operations.jsonl");
            if (File.Exists(path) && new FileInfo(path).Length > 4 * 1024 * 1024) File.Move(path, path + ".previous", true);
            using var file = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough);
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, entry }) + "\n");
            file.Write(bytes);
            file.Flush(true);
        }
    }
}

public static class CleanupOperations
{
    public static CleanupPreparation Prepare(IReadOnlyList<ScanEntry> entries, IReadOnlyList<CleanupCandidate>? candidates, CancellationToken token)
    {
        var ready = new List<CleanupSelection>();
        var skipped = new List<CleanupOutcome>();
        foreach (var entry in DeletionSafetyPolicy.Normalize(entries))
        {
            token.ThrowIfCancellationRequested();
            try
            {
                var candidate = candidates?.FirstOrDefault(item => item.Path.Equals(entry.Path,StringComparison.OrdinalIgnoreCase));
                var identity = DeletionSafetyPolicy.Capture(entry.Path,token,candidate?.GameCache);
                if (candidate?.Snapshot is not null && candidate.Snapshot != identity) throw new IOException("L’élément a changé depuis l’analyse ; examinez-le de nouveau.");
                ready.Add(new(entry with { Size = identity.IsDirectory ? entry.Size : identity.Length },identity,candidate?.DuplicateKeeper,candidate?.KeeperSnapshot,candidate?.GameCache));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            { skipped.Add(new(entry.Path,"exclu à la vérification",0,error.Message)); }
        }
        return new(ready,skipped);
    }
    // Shell operations require an STA thread. No operation runs on the UI thread.
    public static Task<IReadOnlyList<CleanupOutcome>> ExecuteAsync(IReadOnlyList<CleanupSelection> selection, IProgress<int> progress, CancellationToken token,
        Action<string>? recycle = null, Action<object>? record = null)
    {
        var completion = new TaskCompletionSource<IReadOnlyList<CleanupOutcome>>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var results = new List<CleanupOutcome>();
            try
            {
                foreach (var item in selection)
                {
                    if (token.IsCancellationRequested) { results.Add(new(item.Entry.Path, "annulé", 0)); continue; }
                    try
                    {
                        DeletionSafetyPolicy.Revalidate(item.Entry.Path, item.Identity, token, item.GameCache);
                        if (item.Keeper is not null)
                        {
                            if (selection.Any(other => DeletionSafetyPolicy.IsWithin(item.Keeper, other.Entry.Path))) throw new IOException("L’exemplaire à conserver fait partie de la sélection.");
                            DeletionSafetyPolicy.Revalidate(item.Keeper, item.KeeperIdentity!, token);
                            if (DuplicateAnalysis.Hash(item.Entry.Path, token) != DuplicateAnalysis.Hash(item.Keeper, token)) throw new IOException("Les copies ne sont plus identiques.");
                        }
                        (record ?? OperationHistory.Append)(new { operation = "corbeille", status = "préparé", path = item.Entry.Path, identity = item.Identity });
                        DeletionSafetyPolicy.Revalidate(item.Entry.Path, item.Identity, token, item.GameCache);
                        if (recycle is not null) recycle(item.Entry.Path); else RecycleWorker.Move(item);
                        var result = new CleanupOutcome(item.Entry.Path, "corbeille", item.Entry.Size);
                        results.Add(result);
                        try { (record ?? OperationHistory.Append)(result); }
                        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
                        { results[^1] = result with { Error = "L’élément est dans la Corbeille ; son résultat n’a pas pu être ajouté à l’historique." }; }
                    }
                    catch (OperationCanceledException) { results.Add(new(item.Entry.Path, "annulé", 0)); }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException or COMException or System.Security.SecurityException)
                    {
                        var result = new CleanupOutcome(item.Entry.Path, "échec", 0, error.Message);
                        results.Add(result);
                        try { (record ?? OperationHistory.Append)(result); } catch (Exception journalError) when (journalError is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
                    }
                    progress.Report(results.Count);
                }
                completion.SetResult(results);
            }
            catch (Exception error) { completion.SetException(error); }
        }) { IsBackground = true, Name = "StorageScope recycle" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return completion.Task;
    }
}

internal static class ShellRecycle
{
    public static void Move(string path)
    {
        if (new DriveInfo(Path.GetPathRoot(path)!).DriveType != DriveType.Fixed) throw new IOException("La Corbeille ne peut pas être garantie sur ce volume. Aucun fichier n’a été supprimé.");
        var operation = (IFileOperation)new FileOperation();
        IShellItem? shellItem = null;
        try
        {
            var iid = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
            Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out shellItem));
            operation.SetOperationFlags(0x00080000 | 0x00100000 | 0x20000000 | 0x0400 | 0x0004 | 0x4000);
            operation.DeleteItem(shellItem, IntPtr.Zero);
            operation.PerformOperations();
            operation.GetAnyOperationsAborted(out var aborted);
            if (aborted || File.Exists(path) || Directory.Exists(path)) throw new IOException("La mise à la Corbeille a été annulée ou refusée.");
        }
        finally
        {
            if (shellItem is not null) Marshal.FinalReleaseComObject(shellItem);
            Marshal.FinalReleaseComObject(operation);
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr bind, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IShellItem item);
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr bind, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint name, out IntPtr result);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }
    [ComImport, Guid("3AD05575-8857-4850-9277-11B85BDB8E09")]
    private class FileOperation { }
    [ComImport, Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOperation
    {
        void Advise(IntPtr sink, out uint cookie);
        void Unadvise(uint cookie);
        void SetOperationFlags(uint flags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
        void SetProgressDialog(IntPtr dialog);
        void SetProperties(IntPtr properties);
        void SetOwnerWindow(IntPtr window);
        void ApplyPropertiesToItem(IntPtr item);
        void ApplyPropertiesToItems(IntPtr items);
        void RenameItem(IntPtr item, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        void RenameItems(IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void MoveItem(IntPtr item, IntPtr destination, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        void MoveItems(IntPtr items, IntPtr destination);
        void CopyItem(IntPtr item, IntPtr destination, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        void CopyItems(IntPtr items, IntPtr destination);
        void DeleteItem([MarshalAs(UnmanagedType.Interface)] IShellItem item, IntPtr sink);
        void DeleteItems(IntPtr items);
        void NewItem(IntPtr destination, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string template, IntPtr sink);
        void PerformOperations();
        void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }
}
