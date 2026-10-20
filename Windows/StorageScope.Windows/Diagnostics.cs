using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace StorageScope.Windows;

internal static class Diagnostics
{
    internal static string? TestDirectory { get; set; }
    internal static string DirectoryPath => TestDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StorageScope", "Diagnostics");
    internal static string LogPath => Path.Combine(DirectoryPath, "StorageScope-crashes.log");
    internal static string Session { get; } = Guid.NewGuid().ToString("N");
    internal static string Action { get; set; } = "démarrage";
    internal static bool PreviousCrash { get; private set; }
    internal static void Start()
    {
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            PreviousCrash = File.Exists(Path.Combine(DirectoryPath, "previous-crash"));
            File.Delete(Path.Combine(DirectoryPath, "previous-crash"));
            File.WriteAllText(Marker(Session), "running");
            using var current = Process.GetCurrentProcess();
            var info = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var arg in new[] { "--watch-session", current.Id.ToString(), current.StartTime.ToUniversalTime().Ticks.ToString(), Session }) info.ArgumentList.Add(arg);
            Process.Start(info)?.Dispose();
        }
        catch (Exception error) { Write("diagnostic-start", error); }
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Write("fatal-managed", e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) => { Write("background-task", e.Exception); e.SetObserved(); };
    }
    internal static void Finish()
    {
        try { File.Delete(Marker(Session)); } catch { }
    }
    private static string Marker(string session) => Path.Combine(DirectoryPath, session + ".session");
    internal static int Watch(string[] args)
    {
        if (args.Length != 4 || !int.TryParse(args[1], out var pid) || !long.TryParse(args[2], out var ticks) || !Guid.TryParseExact(args[3], "N", out _)) return 2;
        try
        {
            using var parent = Process.GetProcessById(pid);
            var handle = parent.SafeHandle; // Keep a query handle alive before the parent exits.
            if (parent.StartTime.ToUniversalTime().Ticks != ticks) return 2;
            parent.WaitForExit();
            if (File.Exists(Marker(args[3])))
            {
                if (!GetExitCodeProcess(handle, out var exitCode)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                Write("arrêt-anormal", new IOException($"Session {args[3]} ; code de sortie 0x{exitCode:X8}. Consultez la dernière action enregistrée. Aucun nettoyage ne sera réessayé automatiquement."));
                File.WriteAllText(Path.Combine(DirectoryPath, "previous-crash"), args[3]);
                File.Delete(Marker(args[3]));
            }
        }
        catch (ArgumentException) { }
        catch (Exception error) { Write("surveillance", error); }
        return 0;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint exitCode);
    internal static void Write(string action, Exception? error = null)
    {
        try
        {
            if (action.StartsWith("fatal-", StringComparison.Ordinal)) { Directory.CreateDirectory(DirectoryPath); File.WriteAllText(Path.Combine(DirectoryPath, "previous-crash"), Session); }
            using var mutex = new Mutex(false, @"Local\StorageScope.Diagnostics." + Environment.UserName);
            var acquired = false;
            try
            {
                try { acquired = mutex.WaitOne(TimeSpan.FromSeconds(2)); } catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) return;
                Directory.CreateDirectory(DirectoryPath);
                if (File.Exists(LogPath) && new FileInfo(LogPath).Length >= 2 * 1024 * 1024)
                {
                    for (var i = 4; i >= 1; i--) if (File.Exists(LogPath + "." + i)) File.Move(LogPath + "." + i, LogPath + "." + (i + 1), true);
                    File.Move(LogPath, LogPath + ".1", true);
                }
                var message = error?.ToString().Replace(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);
                File.AppendAllText(LogPath, JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, version = AppIdentity.Version, os = Environment.OSVersion.VersionString, architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(), session = Session, action, currentAction = Action, error = message }) + Environment.NewLine);
            }
            finally { if (acquired) mutex.ReleaseMutex(); }
        }
        catch { /* A full disk or denied log directory must not cause another crash. */ }
    }
}

internal static class EntryPoint
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.FirstOrDefault() == "--watch-session") return Diagnostics.Watch(args);
        if (args.FirstOrDefault() == "--recycle-worker") return RecycleWorker.Run();
        if (args.FirstOrDefault() == "--query-recycle-bin") return RecycleBinService.Worker(false);
        if (args.FirstOrDefault() == "--empty-recycle-bin") return RecycleBinService.Worker(true);
        Diagnostics.Start();
        try
        {
            using var instance = new Mutex(false, @"Local\StorageScope.Application");
            bool ownsInstance;
            try { ownsInstance = args.Contains("--verify-installation") || instance.WaitOne(0); }
            catch (AbandonedMutexException) { ownsInstance = true; }
            if (!ownsInstance) { System.Windows.MessageBox.Show("StorageScope est déjà ouvert.", "StorageScope"); return 0; }
            var app = new App(); app.InitializeComponent();
            app.DispatcherUnhandledException += (_, e) =>
            {
                Diagnostics.Write("fatal-interface", e.Exception);
                System.Windows.MessageBox.Show("StorageScope doit se fermer après une erreur. Le diagnostic a été enregistré localement. Les actions interrompues ne seront pas relancées automatiquement.", "StorageScope");
                e.Handled = true;
                app.Shutdown(1);
            };
            return app.Run();
        }
        catch (Exception error) { Diagnostics.Write("fatal-startup", error); return 1; }
        finally { Diagnostics.Finish(); }
    }
}
