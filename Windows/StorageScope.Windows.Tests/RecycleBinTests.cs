using System.IO;
using StorageScope.Windows;

internal static class RecycleBinTests
{
    internal static void Run(string root)
    {
        // Never empty a developer's or user's real recycle bin during validation.
        if (Environment.GetEnvironmentVariable("CI") != "true") throw new InvalidOperationException("Real empty-bin tests require an isolated CI account.");
        var initial = RecycleBinService.QueryAsync().GetAwaiter().GetResult();
        if (!initial.Available || initial.Partial || initial.Items != 0) throw new InvalidOperationException("The isolated account's recycle bin must be empty before this test.");
        var path = Path.Combine(root, "isolated-empty-bin-" + Guid.NewGuid().ToString("N") + ".txt");
        File.WriteAllText(path, "Disposable StorageScope recycle-bin validation fixture");
        var entry = new ScanEntry(path, Path.GetFileName(path), new FileInfo(path).Length, false, null, StorageCategory.Other);
        RecycleWorker.Move(new(entry, DeletionSafetyPolicy.Capture(path)));
        var populated = RecycleBinService.QueryAsync().GetAwaiter().GetResult();
        if (populated.Items < 1 || populated.Bytes < entry.Size || File.Exists(path)) throw new InvalidOperationException("Native recycle inventory did not observe the fixture.");
        try
        {
            RecycleBinService.EmptyAsync(new([Path.GetPathRoot(root)!], false)).GetAwaiter().GetResult();
            throw new InvalidOperationException("Missing confirmation was accepted.");
        }
        catch (IOException) { }
        var preserved = RecycleBinService.QueryAsync().GetAwaiter().GetResult();
        if (preserved.Items != populated.Items) throw new InvalidOperationException("Rejected confirmation changed the bin.");
        var emptied = RecycleBinService.EmptyAsync(new([Path.GetPathRoot(root)!], true)).GetAwaiter().GetResult();
        if (emptied.Errors.Count != 0 || emptied.Summary.Items != 0) throw new InvalidOperationException("Isolated system recycle-bin empty failed.");
    }
}
