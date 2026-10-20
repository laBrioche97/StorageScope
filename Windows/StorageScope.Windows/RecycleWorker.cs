using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace StorageScope.Windows;

internal static class RecycleWorker
{
    internal static int Run()
    {
        using var input = new StreamReader(Console.OpenStandardInput());
        using var output = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
        try
        {
            var line = input.ReadLine() ?? throw new IOException("Sélection absente.");
            if (line.Length > 256 * 1024) throw new IOException("Sélection trop volumineuse.");
            var item = JsonSerializer.Deserialize<CleanupSelection>(line) ?? throw new IOException("Sélection invalide.");
            DeletionSafetyPolicy.Revalidate(item.Entry.Path, item.Identity, default, item.GameCache);
            if (item.Keeper is not null)
            {
                if (item.KeeperIdentity is null) throw new IOException("Identité de la copie conservée absente.");
                DeletionSafetyPolicy.Revalidate(item.Keeper, item.KeeperIdentity);
                if (DuplicateAnalysis.Hash(item.Entry.Path, default) != DuplicateAnalysis.Hash(item.Keeper, default)) throw new IOException("Les copies ont changé.");
            }
            DeletionSafetyPolicy.Revalidate(item.Entry.Path, item.Identity, default, item.GameCache);
            ShellRecycle.Move(item.Entry.Path);
            output.WriteLine(JsonSerializer.Serialize(new CleanupOutcome(item.Entry.Path, "corbeille", item.Entry.Size)));
            return 0;
        }
        catch (Exception error)
        {
            Diagnostics.Write("corbeille-worker", error);
            output.WriteLine(JsonSerializer.Serialize(new CleanupOutcome("", "échec", 0, error.Message)));
            return 1;
        }
    }

    internal static void Move(CleanupSelection item)
    {
        var executable = Environment.ProcessPath!;
        // Tests host a different executable; locate the built application explicitly.
        if (!Path.GetFileNameWithoutExtension(executable).Equals("StorageScope", StringComparison.OrdinalIgnoreCase)) executable = Path.Combine(AppContext.BaseDirectory, "StorageScope.exe");
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        info.ArgumentList.Add("--recycle-worker");
        using var process = Process.Start(info) ?? throw new IOException("Le moteur de corbeille n’a pas démarré.");
        process.StandardInput.WriteLine(JsonSerializer.Serialize(item)); process.StandardInput.Close();
        var response = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        process.WaitForExit(); // Never kill or retry a shell operation already in progress.
        var text = response.GetAwaiter().GetResult();
        _ = stderr.GetAwaiter().GetResult();
        if (process.ExitCode != 0 || string.IsNullOrWhiteSpace(text))
        {
            var exists = File.Exists(item.Entry.Path) || Directory.Exists(item.Entry.Path);
            var error = new IOException($"Moteur interrompu (0x{process.ExitCode:X8}). " + (exists ? "L’élément est encore présent ; examinez-le avant une nouvelle tentative." : "L’élément n’est plus à cet emplacement : vérifiez la Corbeille. Résultat incertain, aucune nouvelle tentative automatique."));
            Diagnostics.Write("corbeille-interrompue", error); throw error;
        }
        var result = JsonSerializer.Deserialize<CleanupOutcome>(text) ?? throw new IOException("Résultat de corbeille absent.");
        if (result.Status != "corbeille" || result.Path != item.Entry.Path) throw new IOException(result.Error ?? "La corbeille n’a pas confirmé l’opération.");
    }
}
