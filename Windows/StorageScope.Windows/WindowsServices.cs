using Microsoft.Win32;
using Microsoft.VisualBasic.FileIO;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace StorageScope.Windows;

public static class DirectoryBrowser
{
    public static Task<IReadOnlyList<ScanEntry>> BrowseAsync(string path, IReadOnlyDictionary<string, long>? sizes, CancellationToken token) => Task.Run(() =>
    {
        var result = new List<ScanEntry>();
        var options = new EnumerationOptions { IgnoreInaccessible = true, RecurseSubdirectories = false, ReturnSpecialDirectories = false };
        try
        {
            foreach (var directory in new DirectoryInfo(path).EnumerateDirectories("*", options))
            {
                token.ThrowIfCancellationRequested();
                if ((directory.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                result.Add(new ScanEntry(directory.FullName, directory.Name, sizes?.GetValueOrDefault(directory.FullName) ?? 0, true, SafeModified(directory), StorageCategory.Other));
            }
            foreach (var file in new DirectoryInfo(path).EnumerateFiles("*", options))
            {
                token.ThrowIfCancellationRequested();
                long length;
                try { length = file.Length; } catch { length = 0; }
                result.Add(new ScanEntry(file.FullName, file.Name, length, false, SafeModified(file), CategoryClassifier.Classify(file.FullName)));
            }
        }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException or System.Security.SecurityException) { }
        return (IReadOnlyList<ScanEntry>)result.OrderByDescending(item => item.Size).ThenBy(item => item.Name).ToList();
    }, token);

    private static DateTime? SafeModified(FileSystemInfo info) { try { return info.LastWriteTime; } catch { return null; } }
}

public static class ExplorerService
{
    public static void Properties(string path)
    {
        var info = new ShellExecuteInfo { Size = Marshal.SizeOf<ShellExecuteInfo>(), Mask = 0x0000000C, Verb = "properties", File = path, Show = 1 };
        if (!ShellExecuteEx(ref info)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ShellExecuteInfo
    {
        public int Size; public uint Mask; public IntPtr Window;
        [MarshalAs(UnmanagedType.LPWStr)] public string Verb;
        [MarshalAs(UnmanagedType.LPWStr)] public string File;
        public IntPtr Parameters, Directory; public int Show; public IntPtr Instance, IdList, Class; public IntPtr ClassKey; public uint HotKey; public IntPtr Icon, Process;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShellExecuteEx(ref ShellExecuteInfo info);
    public static void ShowInExplorer(string path)
    {
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
    }

    public static void Open(string path)
    {
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }
}
