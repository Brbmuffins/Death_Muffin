using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinLauncher
{
    internal sealed class InstallProgress
    {
        public long Done, Total;
        public string File = "";
        public double Fraction { get { return Total > 0 ? Math.Min(1.0, (double)Done / Total) : 0; } }
    }

    internal sealed class InstalledClient
    {
        public string Version = "";
        public string Dir = "";
        public string ExePath { get { return Path.Combine(Dir, ClientManifest.ExeName); } }
        public ClientManifest Manifest;
    }

    /// <summary>
    /// The installed Godot client under %LOCALAPPDATA%\DeathMuffin\client: one folder per version plus current.json. Never touched in
    /// place: a new version is built in .staging-&lt;version&gt; and swapped in with one directory rename.
    /// </summary>
    internal static class ClientStore
    {
        static string CurrentFile(string root) { return Path.Combine(root, "current.json"); }

        /// <summary>The installed client if every file listed in its saved manifest is present with the right size (full hashes are checked at download time), else null.</summary>
        public static InstalledClient ReadInstalled(string root)
        {
            try
            {
                if (!Directory.Exists(root)) return null;
                var candidates = new List<string>();
                try
                {
                    string cur = CurrentFile(root);
                    if (File.Exists(cur))
                    {
                        var d = MiniJson.Parse(File.ReadAllText(cur)) as Dictionary<string, object>;
                        object v;
                        if (d != null && d.TryGetValue("version", out v) && v is string) candidates.Add((string)v);
                    }
                }
                catch (Exception) { /* fall through to the folder scan */ }
                var scan = new List<string>();
                foreach (string dir in Directory.GetDirectories(root))
                {
                    string name = Path.GetFileName(dir);
                    if (ClientManifest.SafeVersionName(name) && !candidates.Contains(name)) scan.Add(name);
                }
                scan.Sort((a, b) => VersionCompare.Compare(b, a));
                candidates.AddRange(scan);
                foreach (string name in candidates)
                {
                    var c = TryOpen(root, name);
                    if (c != null) return c;
                }
            }
            catch (Exception) { }
            return null;
        }

        static InstalledClient TryOpen(string root, string version)
        {
            if (!ClientManifest.SafeVersionName(version)) return null;
            string dir = Path.Combine(root, version);
            string mf = Path.Combine(dir, "manifest.json");
            if (!File.Exists(mf)) return null;
            ClientManifest m;
            string err;
            if (!ClientManifest.TryParse(File.ReadAllText(mf), new Uri("https://installed.invalid/"), out m, out err, false) || m.Version != version) return null;
            foreach (var f in m.Files)
            {
                var fi = new FileInfo(Path.Combine(dir, f.Path.Replace('/', Path.DirectorySeparatorChar)));
                if (!fi.Exists || fi.Length != f.Size) return null;
            }
            return new InstalledClient { Version = version, Dir = dir, Manifest = m };
        }

        public static void WriteCurrent(string root, string version)
        {
            string tmp = CurrentFile(root) + ".tmp";
            File.WriteAllText(tmp, "{\"version\":\"" + version + "\"}", new UTF8Encoding(false));
            if (File.Exists(CurrentFile(root))) File.Replace(tmp, CurrentFile(root), null);
            else File.Move(tmp, CurrentFile(root));
        }

        /// <summary>Removes old version folders (keeping the named ones) and leftover staging/old folders. Failures (a running game holding files) are ignored.</summary>
        public static void Prune(string root, params string[] keep)
        {
            try
            {
                foreach (string dir in Directory.GetDirectories(root))
                {
                    string name = Path.GetFileName(dir);
                    bool stale = name.StartsWith(".old-", StringComparison.Ordinal) || name.StartsWith(".staging-", StringComparison.Ordinal)
                        || (ClientManifest.SafeVersionName(name) && Array.IndexOf(keep, name) < 0);
                    if (!stale) continue;
                    try { Directory.Delete(dir, true); } catch (Exception) { }
                }
            }
            catch (Exception) { }
        }
    }

    /// <summary>
    /// Downloads a manifest's files into .staging-&lt;version&gt;, verifies every SHA-256, then swaps the folder in. Resumes partial files (HTTP Range),
    /// retries each file, reuses unchanged files from the installed version, and never modifies the installed version until the swap.
    /// </summary>
    internal sealed class ClientInstaller
    {
        readonly HttpClient http;
        readonly string root;
        public int MaxAttempts = 4;
        public TimeSpan RetryDelay = TimeSpan.FromSeconds(1.5);
        /// <summary>A transfer with no bytes for this long counts as failed (and is retried).</summary>
        public TimeSpan StallTimeout = TimeSpan.FromSeconds(30);

        public ClientInstaller(HttpClient http, string root) { this.http = http; this.root = root; }

        public static string StagingDir(string root, string version) { return Path.Combine(root, ".staging-" + version); }

        public async Task InstallAsync(ClientManifest m, InstalledClient previous, IProgress<InstallProgress> progress, CancellationToken ct)
        {
            Directory.CreateDirectory(root);
            string stage = StagingDir(root, m.Version);
            Directory.CreateDirectory(stage);
            long total = m.TotalBytes, done = 0;
            foreach (var f in m.Files)
            {
                ct.ThrowIfCancellationRequested();
                string dest = Path.Combine(stage, f.Path.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                long baseDone = done;
                Action<long> report = n => { if (progress != null) progress.Report(new InstallProgress { Done = baseDone + n, Total = total, File = f.Path }); };
                if (Hashing.Verify(dest, f.Size, f.Sha256)) { done += f.Size; report(f.Size); continue; }   // kept from an interrupted run
                if (TryReuse(previous, f, dest)) { done += f.Size; report(f.Size); continue; }
                await FetchAsync(f, dest, report, ct).ConfigureAwait(false);
                done += f.Size;
            }
            File.WriteAllText(Path.Combine(stage, "manifest.json"), m.Raw, new UTF8Encoding(false));

            string final = Path.Combine(root, m.Version);
            if (Directory.Exists(final))
            {
                string old = Path.Combine(root, ".old-" + Guid.NewGuid().ToString("N"));
                Directory.Move(final, old);
                try { Directory.Delete(old, true); } catch (Exception) { }
            }
            Directory.Move(stage, final);        // the atomic swap: one rename on the same volume
            ClientStore.WriteCurrent(root, m.Version);
            ClientStore.Prune(root, m.Version, previous != null ? previous.Version : m.Version);
        }

        static bool TryReuse(InstalledClient previous, ManifestFile f, string dest)
        {
            if (previous == null || previous.Manifest == null) return false;
            foreach (var pf in previous.Manifest.Files)
            {
                if (pf.Path != f.Path || pf.Size != f.Size || !string.Equals(pf.Sha256, f.Sha256, StringComparison.OrdinalIgnoreCase)) continue;
                string src = Path.Combine(previous.Dir, pf.Path.Replace('/', Path.DirectorySeparatorChar));
                try
                {
                    if (!File.Exists(src)) return false;
                    File.Copy(src, dest, true);
                    if (Hashing.Verify(dest, f.Size, f.Sha256)) return true;
                    File.Delete(dest);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                return false;
            }
            return false;
        }

        async Task FetchAsync(ManifestFile f, string dest, Action<long> report, CancellationToken ct)
        {
            string part = dest + ".part";
            for (int attempt = 1; ; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                try
                {
                    if (f.Size == 0)
                    {
                        File.WriteAllBytes(part, new byte[0]);
                    }
                    else
                    {
                        long have = File.Exists(part) ? new FileInfo(part).Length : 0;
                        if (have > f.Size) { File.Delete(part); have = 0; }
                        if (have < f.Size) await Transfer(f, part, have, report, ct).ConfigureAwait(false);
                    }
                    if (new FileInfo(part).Length != f.Size) throw new IOException("incomplete download");
                    if (!Hashing.Verify(part, f.Size, f.Sha256))
                    {
                        File.Delete(part);   // never resume on top of bad bytes
                        throw new IOException("checksum mismatch");
                    }
                    if (File.Exists(dest)) File.Delete(dest);
                    File.Move(part, dest);
                    report(f.Size);
                    return;
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception ex)
                {
                    if (attempt >= MaxAttempts) throw new IOException(f.Path + ": " + ex.Message, ex);
                    try { await Task.Delay(TimeSpan.FromMilliseconds(RetryDelay.TotalMilliseconds * attempt), ct).ConfigureAwait(false); }
                    catch (OperationCanceledException) { throw; }
                }
            }
        }

        async Task Transfer(ManifestFile f, string part, long have, Action<long> report, CancellationToken ct)
        {
            using (var req = new HttpRequestMessage(HttpMethod.Get, f.Url))
            {
                if (have > 0) req.Headers.Range = new RangeHeaderValue(have, null);
                using (var stall = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    stall.CancelAfter(StallTimeout);
                    using (var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, stall.Token).ConfigureAwait(false))
                    {
                        // Disposing the response is what actually interrupts a hung read on .NET Framework.
                        using (stall.Token.Register(() => { try { resp.Dispose(); } catch (Exception) { } }))
                        {
                            if (resp.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable) { File.Delete(part); throw new IOException("server rejected the resume range"); }
                            if (!resp.IsSuccessStatusCode) throw new IOException("HTTP " + (int)resp.StatusCode);
                            bool append = have > 0 && resp.StatusCode == HttpStatusCode.PartialContent;
                            if (!append) have = 0;   // the server ignored the Range header: start the file over
                            long got = have;
                            report(got);
                            using (var src = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false))
                            using (var dst = new FileStream(part, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, true))
                            {
                                var buf = new byte[1 << 16];
                                int n;
                                while ((n = await src.ReadAsync(buf, 0, buf.Length, stall.Token).ConfigureAwait(false)) > 0)
                                {
                                    await dst.WriteAsync(buf, 0, n, ct).ConfigureAwait(false);
                                    got += n;
                                    report(Math.Min(got, f.Size));
                                    stall.CancelAfter(StallTimeout);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
