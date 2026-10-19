using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;

namespace StorageScope.Windows;

public sealed class ScanService
{
    private const int LargestFileLimit = 2_000;
    private readonly record struct BranchResult(Dictionary<string, long> Directories, List<ScanEntry> LargestFiles);

    public async Task<ScanResult> ScanAsync(string root, IProgress<ScanProgress> progress, CancellationToken cancellationToken)
    {
        root = Path.GetFullPath(root);
        var drive = new DriveInfo(Path.GetPathRoot(root)!);
        var expectedBytes = Math.Max(1, drive.TotalSize - drive.AvailableFreeSpace);
        var categoryBytes = new long[Enum.GetValues<StorageCategory>().Length];
        var categoryCounts = new long[categoryBytes.Length];
        var allDirectorySizes = new ConcurrentDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        var largestFiles = new ConcurrentBag<List<ScanEntry>>();
        var cleanupAnalysis = new CleanupAnalysis();
        long files = 0, directories = 1, bytes = 0, errors = 0, nextReportTicks = 0;

        void ReportOccasionally(string currentPath)
        {
            var now = Stopwatch.GetTimestamp();
            var minimumGap = Stopwatch.Frequency / 5;
            var previous = Volatile.Read(ref nextReportTicks);
            if (now < previous || Interlocked.CompareExchange(ref nextReportTicks, now + minimumGap, previous) != previous) return;
            var discovered = Volatile.Read(ref bytes);
            progress.Report(new ScanProgress(
                Volatile.Read(ref files),
                Volatile.Read(ref directories),
                discovered,
                Volatile.Read(ref errors),
                currentPath,
                Math.Min(0.99, discovered / (double)expectedBytes)));
        }

        void AccountFile(FileInfo info, List<ScanEntry> localLargest)
        {
            cancellationToken.ThrowIfCancellationRequested();
            long length;
            try { length = Math.Max(0, info.Length); }
            catch (UnauthorizedAccessException) { Interlocked.Increment(ref errors); return; }
            catch (IOException) { Interlocked.Increment(ref errors); return; }

            var category = CategoryClassifier.Classify(info.FullName);
            Interlocked.Increment(ref files);
            Interlocked.Add(ref bytes, length);
            Interlocked.Add(ref categoryBytes[(int)category], length);
            Interlocked.Increment(ref categoryCounts[(int)category]);
            var entry = new ScanEntry(info.FullName, info.Name, length, false, SafeModified(info), category);
            cleanupAnalysis.Observe(entry);
            localLargest.Add(entry);
            if (localLargest.Count > LargestFileLimit * 2)
            {
                localLargest.Sort((a, b) => b.Size.CompareTo(a.Size));
                localLargest.RemoveRange(LargestFileLimit, localLargest.Count - LargestFileLimit);
            }
            ReportOccasionally(info.FullName);
        }

        var options = new EnumerationOptions
        {
            IgnoreInaccessible = false,
            RecurseSubdirectories = false,
            ReturnSpecialDirectories = false,
            AttributesToSkip = FileAttributes.ReparsePoint | FileAttributes.Offline | (FileAttributes)0x00400000 | (FileAttributes)0x00040000
        };

        var rootLargest = new List<ScanEntry>();
        IEnumerable<FileInfo> rootFiles;
        try { rootFiles = new DirectoryInfo(root).EnumerateFiles("*", options).ToList(); }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException) { rootFiles = []; Interlocked.Increment(ref errors); }
        foreach (var file in rootFiles) AccountFile(file, rootLargest);
        largestFiles.Add(rootLargest);

        List<DirectoryInfo> roots;
        try { roots = new DirectoryInfo(root).EnumerateDirectories("*", options).ToList(); }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException) { roots = []; Interlocked.Increment(ref errors); }

        var parallelOptions = new ParallelOptions
        {
            CancellationToken = cancellationToken,
            MaxDegreeOfParallelism = Math.Clamp(Environment.ProcessorCount / 2, 2, 6)
        };
        await Parallel.ForEachAsync(roots, parallelOptions, (directory, token) =>
        {
            var branch = ScanBranch(directory, options, AccountFile, token, ref directories, ref errors);
            foreach (var pair in branch.Directories) allDirectorySizes[pair.Key] = pair.Value;
            largestFiles.Add(branch.LargestFiles);
            return ValueTask.CompletedTask;
        });

        var rootSize = Volatile.Read(ref bytes);
        allDirectorySizes[root] = rootSize;
        var categories = Enum.GetValues<StorageCategory>()
            .Select(category => new CategoryResult(category, Volatile.Read(ref categoryBytes[(int)category]), Volatile.Read(ref categoryCounts[(int)category])))
            .OrderByDescending(item => item.Bytes)
            .ToList();
        var topFiles = largestFiles.SelectMany(item => item).OrderByDescending(item => item.Size).Take(LargestFileLimit).ToList();
        var cleanup = cleanupAnalysis.Results();
        progress.Report(new ScanProgress(files, directories, bytes, errors, root, 1));
        return new ScanResult
        {
            Root = root,
            DirectorySizes = allDirectorySizes,
            LargestFiles = topFiles,
            Categories = categories,
            CleanupCandidates = cleanup,
            IdentifiedBytes = bytes,
            FilesScanned = files,
            DirectoriesScanned = directories,
            AccessErrors = errors,
            CleanupTruncated = cleanupAnalysis.IsTruncated
        };
    }

    private static BranchResult ScanBranch(
        DirectoryInfo branchRoot,
        EnumerationOptions options,
        Action<FileInfo, List<ScanEntry>> accountFile,
        CancellationToken token,
        ref long directoryCounter,
        ref long errorCounter)
    {
        var sizes = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        var largest = new List<ScanEntry>();
        var stack = new Stack<(DirectoryInfo Directory, bool Exit)>();
        stack.Push((branchRoot, false));
        while (stack.Count > 0)
        {
            token.ThrowIfCancellationRequested();
            var (directory, exit) = stack.Pop();
            if (exit)
            {
                var total = sizes.GetValueOrDefault(directory.FullName);
                var parent = directory.Parent?.FullName;
                if (parent is not null) sizes[parent] = AddSafe(sizes.GetValueOrDefault(parent), total);
                continue;
            }

            Interlocked.Increment(ref directoryCounter);
            sizes.TryAdd(directory.FullName, 0);
            stack.Push((directory, true));
            try
            {
                foreach (var file in directory.EnumerateFiles("*", options))
                {
                    accountFile(file, largest);
                    long length;
                    try { length = Math.Max(0, file.Length); } catch { length = 0; }
                    sizes[directory.FullName] = AddSafe(sizes.GetValueOrDefault(directory.FullName), length);
                }
                foreach (var child in directory.EnumerateDirectories("*", options)) stack.Push((child, false));
            }
            catch (Exception error) when (error is UnauthorizedAccessException or IOException or System.Security.SecurityException)
            {
                Interlocked.Increment(ref errorCounter);
            }
        }
        largest.Sort((a, b) => b.Size.CompareTo(a.Size));
        if (largest.Count > LargestFileLimit) largest.RemoveRange(LargestFileLimit, largest.Count - LargestFileLimit);
        return new BranchResult(sizes, largest);
    }

    private static long AddSafe(long left, long right) => left > long.MaxValue - right ? long.MaxValue : left + right;
    private static DateTime? SafeModified(FileInfo info) { try { return info.LastWriteTime; } catch { return null; } }
}
