using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam
{
    /// <summary>
    /// The team app's own manifest (`teamapp/version.json` on the game's site): {"version": "0.1.1", "url": ".../teamapp/0.1.1/DeathMuffinTeam.exe", "sha256": "...", "size": 123}.
    /// `size` is optional. The exe must be on the manifest's scheme, host and port.
    /// </summary>
    internal sealed class TeamManifest
    {
        public const string ExeName = "DeathMuffinTeam.exe";

        public string Version = "";
        public Uri Url;
        public string Sha256 = "";
        public long Size;

        public static bool TryParse(string json, Uri manifestUrl, out TeamManifest manifest, out string error)
        {
            manifest = null;
            error = null;
            var root = MiniJson.TryObject(json);
            if (root == null) { error = "the update manifest is not an object"; return false; }
            var m = new TeamManifest { Version = MiniJson.Str(root, "version"), Sha256 = MiniJson.Str(root, "sha256").ToLowerInvariant() };
            Version parsed;
            if (!System.Version.TryParse(m.Version, out parsed) || m.Version.Split('.').Length != 3) { error = "bad update version"; return false; }
            if (!Hashing.IsHex64(m.Sha256)) { error = "bad update sha256"; return false; }
            object sz;
            if (root.TryGetValue("size", out sz))
            {
                long? n = MiniJson.Int(root, "size");
                if (n == null || n.Value <= 0 || n.Value > 1000000000L) { error = "bad update size"; return false; }
                m.Size = n.Value;
            }
            string url = MiniJson.Str(root, "url");
            Uri u;
            if (url.Length == 0 || !Uri.TryCreate(manifestUrl, url, out u)) { error = "bad update url"; return false; }
            if (u.Scheme != manifestUrl.Scheme || !string.Equals(u.Host, manifestUrl.Host, StringComparison.OrdinalIgnoreCase) || u.Port != manifestUrl.Port)
            { error = "the update url leaves the server"; return false; }
            m.Url = u;
            manifest = m;
            return true;
        }
    }

    internal enum SelfUpdateAction
    {
        /// <summary>No newer version (or no manifest).</summary>
        None,
        /// <summary>A newer version exists, but a job is running: try again on a later check.</summary>
        Wait,
        /// <summary>Download it, swap the exe and restart.</summary>
        Apply,
        /// <summary>A newer version exists but this folder cannot be updated in place, or it failed too often: say so and keep running.</summary>
        GiveUp,
    }

    /// <summary>
    /// The app updates itself the way the launcher does (launcher/windows/SelfUpdate.cs): download `DeathMuffinTeam.exe.new`, check its SHA-256, rename the running exe
    /// to `.old` (Windows allows renaming a running exe, not overwriting it), move `.new` in, start it, exit. The new copy removes `.old` when it starts.
    /// Never while a job runs.
    /// </summary>
    internal static class SelfUpdate
    {
        /// <summary>After this many failed attempts in one session the app stops trying.</summary>
        public const int MaxFailures = 3;

        public static SelfUpdateAction Decide(TeamManifest live, string currentVersion, bool jobRunning, bool folderWritable, int failures)
        {
            if (live == null || VersionCompare.Compare(live.Version, currentVersion) <= 0) return SelfUpdateAction.None;
            if (!folderWritable || failures >= MaxFailures) return SelfUpdateAction.GiveUp;
            if (jobRunning) return SelfUpdateAction.Wait;
            return SelfUpdateAction.Apply;
        }

        public static string NewPath(string exePath) { return exePath + ".new"; }
        public static string OldPath(string exePath) { return exePath + ".old"; }
        static string PartPath(string exePath) { return exePath + ".new.part"; }

        /// <summary>True when the app may create and rename files next to its exe (false under Program Files without admin rights).</summary>
        public static bool FolderWritable(string exePath)
        {
            try
            {
                string probe = Path.Combine(Path.GetDirectoryName(exePath), ".write-test-" + Guid.NewGuid().ToString("N"));
                File.WriteAllBytes(probe, new byte[0]);
                File.Delete(probe);
                return true;
            }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }

        /// <summary>Removes what an earlier update left behind (the previous exe, a half download). Called at start; never throws.</summary>
        public static void CleanUp(string exePath)
        {
            foreach (string p in new[] { OldPath(exePath), PartPath(exePath), NewPath(exePath) })
            {
                // The previous copy may still be closing for a moment after it started this one.
                for (int i = 0; i < 10 && File.Exists(p); i++)
                {
                    try { File.Delete(p); }
                    catch (IOException) { Thread.Sleep(300); }
                    catch (UnauthorizedAccessException) { Thread.Sleep(300); }
                }
            }
        }

        /// <summary>Downloads the new exe next to the running one as `.new`, checked by SHA-256 (and size when the manifest gives one). Throws on any failure (nothing is swapped).</summary>
        public static async Task DownloadAsync(HttpClient http, TeamManifest m, string exePath, CancellationToken ct)
        {
            string part = PartPath(exePath), next = NewPath(exePath);
            if (File.Exists(part)) File.Delete(part);
            long limit = m.Size > 0 ? m.Size : 200L << 20;
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
                timeout.CancelAfter(TimeSpan.FromMinutes(5));   // the client has no timeout of its own (it also downloads the big job files)
                using (var resp = await http.GetAsync(m.Url, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false))
                {
                    resp.EnsureSuccessStatusCode();
                    using (var src = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false))
                    using (var dst = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
                    {
                        var buf = new byte[1 << 16];
                        long total = 0;
                        int n;
                        while ((n = await src.ReadAsync(buf, 0, buf.Length, timeout.Token).ConfigureAwait(false)) > 0)
                        {
                            total += n;
                            if (total > limit) throw new InvalidDataException("the update download is larger than expected");
                            await dst.WriteAsync(buf, 0, n, timeout.Token).ConfigureAwait(false);
                        }
                    }
                }
            }
            if (!Hashing.Verify(part, m.Size, m.Sha256))
            {
                try { File.Delete(part); } catch (IOException) { }
                throw new InvalidDataException("the update download failed its SHA-256 check");
            }
            if (File.Exists(next)) File.Delete(next);
            File.Move(part, next);
        }

        /// <summary>
        /// Puts the downloaded `.new` in place of the running exe: running -> `.old`, `.new` -> exe. If the second step fails the first is undone, so the folder
        /// always holds a working app. Throws when it could not swap.
        /// </summary>
        public static void Swap(string exePath)
        {
            string next = NewPath(exePath), old = OldPath(exePath);
            if (!File.Exists(next)) throw new FileNotFoundException("no downloaded update to install", next);
            if (File.Exists(old)) File.Delete(old);
            File.Move(exePath, old);
            try { File.Move(next, exePath); }
            catch (Exception)
            {
                try { File.Move(old, exePath); } catch (Exception) { }
                throw;
            }
        }

        /// <summary>The manifest at <paramref name="url"/>, or null (not published yet, offline, or invalid).</summary>
        public static async Task<TeamManifest> FetchAsync(HttpClient http, string url)
        {
            try
            {
                using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
                using (var resp = await http.GetAsync(url + "?t=" + DateTime.UtcNow.Ticks, timeout.Token).ConfigureAwait(false))
                {
                    if (!resp.IsSuccessStatusCode) return null;
                    string json = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    TeamManifest m;
                    string err;
                    return TeamManifest.TryParse(json, new Uri(url), out m, out err) ? m : null;
                }
            }
            catch (HttpRequestException) { return null; }
            catch (TaskCanceledException) { return null; }
            catch (UriFormatException) { return null; }
        }
    }
}
