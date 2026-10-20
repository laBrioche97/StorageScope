using System.Collections.Concurrent;
using System.IO;
using System.Security.Cryptography;

namespace StorageScope.Windows;

public sealed class CleanupAnalysis
{
    private readonly ConcurrentDictionary<string, CleanupCandidate> _candidates = new(StringComparer.OrdinalIgnoreCase);
    public bool IsTruncated { get; private set; }

    public void Observe(ScanEntry file)
    {
        if (_candidates.Count >= 10_000) { IsTruncated = true; return; }
        CleanupCandidate? candidate = null;
        var cache = DeletionSafetyPolicy.CacheKind(file.Path);
        if (cache == "temporary" && file.Modified < DateTime.Now.AddDays(-7))
            candidate = new(file.Path, "Temporaire ou diagnostic dans un emplacement reconnu, inchangé depuis plus de 7 jours.", file.Size, false,
                "Caches et temporaires", "Peut être recréé ; une application ouverte peut verrouiller ce fichier.", true);
        else if (cache is "browser" or "tools")
            candidate = new(file.Path, cache == "browser" ? "Cache de navigateur dans un profil explicitement reconnu ; les mots de passe, cookies et favoris sont exclus." : "Cache de téléchargement npm ou pip explicitement reconnu.", file.Size, false,
                cache == "browser" ? "Caches des navigateurs" : "Caches des outils", "Fermez l’application concernée avant de nettoyer. Ces données seront retéléchargées si nécessaire ; une connexion Internet pourra être requise.");
        else if (DeletionSafetyPolicy.IsWithin(file.Path, Path.Combine(DeletionSafetyPolicy.Home, "Downloads")))
            candidate = new(file.Path, "Fichier de Téléchargements à examiner ; sa présence ne signifie pas qu’il est inutile.", file.Size, false,
                "Téléchargements et archives", "Conservez les archives et installateurs dont vous pourriez encore avoir besoin.");
        else if (file.Size >= 100 * 1024 * 1024)
            candidate = new(file.Path, "Fichier personnel volumineux, conservé tant que vous ne le sélectionnez pas.", file.Size, false,
                "Fichiers volumineux", "Vérifiez son contenu ; il peut s’agir d’un document, d’une vidéo ou d’une sauvegarde.");
        if (candidate is null) return;
        if (DeletionSafetyPolicy.BlockReason(file.Path) is not null) return;
        try { _candidates.TryAdd(file.Path, candidate with { Snapshot = DeletionSafetyPolicy.ReadIdentity(file.Path) }); }
        catch (IOException) { }
    }

    public IReadOnlyList<CleanupCandidate> Results() => _candidates.Values.OrderBy(item => item.Group).ThenByDescending(item => item.Size).ToList();
}

public sealed record DuplicateSearchResult(IReadOnlyList<CleanupCandidate> Candidates, int Excluded, int Unreadable) : IReadOnlyList<CleanupCandidate>
{
    public int Count => Candidates.Count;
    public CleanupCandidate this[int index] => Candidates[index];
    public IEnumerator<CleanupCandidate> GetEnumerator() => Candidates.GetEnumerator();
    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
}

public static class DuplicateAnalysis
{
    public static Task<DuplicateSearchResult> AnalyzeAsync(string root, IProgress<string> progress, CancellationToken token) => Task.Run(() =>
    {
        if (DeletionSafetyPolicy.BlockReason(root) is not null) throw new IOException("Choisissez un dossier personnel accessible hors des emplacements protégés et du cloud.");
        var bySize = new Dictionary<long, List<(string Path, FileSnapshot Snapshot)>>();
        var directories = new Stack<string>();
        directories.Push(root);
        var count = 0;
        var lastProgress = System.Diagnostics.Stopwatch.StartNew();
        var skipped = 0;
        var unreadable = 0;
        progress.Report("Recherche des fichiers…");
        while (directories.TryPop(out var directory))
        {
            token.ThrowIfCancellationRequested();
            try
            {
                foreach (var path in Directory.EnumerateFileSystemEntries(directory))
                {
                    token.ThrowIfCancellationRequested();
                    if (DeletionSafetyPolicy.BlockReason(path) is not null) { skipped++; continue; }
                    if (lastProgress.ElapsedMilliseconds >= 200) { progress.Report($"Recherche : {count:N0} fichiers examinés · {skipped:N0} exclusions"); lastProgress.Restart(); }
                    FileSnapshot info;
                    try { info = DeletionSafetyPolicy.ReadIdentity(path); }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { unreadable++; continue; }
                    if (info.IsDirectory) { directories.Push(path); continue; }
                    if (++count > 100_000) throw new InvalidOperationException("Ce dossier contient plus de 100 000 fichiers. Choisissez un sous-dossier pour une vérification complète.");
                    if (info.Length == 0) continue;
                    if (!bySize.TryGetValue(info.Length, out var group)) bySize[info.Length] = group = [];
                    group.Add((path, info));
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { unreadable++; }
        }
        var results = new List<CleanupCandidate>();
        foreach (var sizeGroup in bySize.Values.Where(group => group.Count > 1))
        {
            var hashes = new Dictionary<string, List<(string Path, FileSnapshot Snapshot)>>();
            foreach (var item in sizeGroup)
            {
                token.ThrowIfCancellationRequested();
                if (lastProgress.ElapsedMilliseconds >= 200) { progress.Report("Vérification du contenu : " + Path.GetFileName(item.Path)); lastProgress.Restart(); }
                try
                {
                    var hash = Hash(item.Path, token);
                    DeletionSafetyPolicy.Revalidate(item.Path, item.Snapshot, token);
                    if (!hashes.TryGetValue(hash, out var group)) hashes[hash] = group = [];
                    group.Add(item);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { unreadable++; }
            }
            foreach (var group in hashes.Values.Where(group => group.Count > 1))
            {
                var ordered = group.OrderBy(item => item.Path, StringComparer.OrdinalIgnoreCase).ToList();
                var keeper = ordered[0];
                foreach (var copy in ordered.Skip(1))
                    results.Add(new(copy.Path, "Contenu identique vérifié par SHA-256. Un exemplaire reste conservé.", copy.Snapshot.Length, false,
                        "Doublons vérifiés", "Exemplaire conservé : " + keeper.Path, false, keeper.Path, copy.Snapshot, keeper.Snapshot));
            }
        }
        return new DuplicateSearchResult(results, skipped, unreadable);
    }, token);

    public static string Hash(string path, CancellationToken token)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[128 * 1024];
        int length;
        while ((length = stream.Read(buffer)) > 0) { token.ThrowIfCancellationRequested(); hash.AppendData(buffer.AsSpan(0, length)); }
        return Convert.ToHexString(hash.GetHashAndReset());
    }
}
