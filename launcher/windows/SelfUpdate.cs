using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinLauncher
{
    /// <summary>
    /// The launcher's own manifest (`launcher/manifest.json`, written by server/death-muffin/publish-launcher.sh):
    /// {"version": "0.9.0", "url": ".../launcher/0.9.0/DeathMuffinLauncher.exe", "size": 123, "sha256": "..."}.
    /// </summary>
    internal sealed class LauncherManifest
    {
        public const string ExeName = "DeathMuffinLauncher.exe";

        public string Version = "";
        public Uri Url;
        public long Size;
        public string Sha256 = "";

        /// <summary>Parses and validates it. The exe must be on the manifest's scheme and host, like the game files.</summary>
        public static bool TryParse(string json, Uri manifestUrl, out LauncherManifest manifest, out string error)
        {
            manifest = null;
            error = null;
            try
            {
                var root = MiniJson.Parse(json) as Dictionary<string, object>;
                if (root == null) { error = "launcher manifest is not an object"; return false; }
                var m = new LauncherManifest { Version = Str(root, "version"), Sha256 = Str(root, "sha256").ToLowerInvariant() };
                Version parsed;
                if (!System.Version.TryParse(m.Version, out parsed) || m.Version.Split('.').Length != 3) { error = "bad launcher version"; return false; }
                if (!ClientManifest.IsHex64(m.Sha256)) { error = "bad launcher sha256"; return false; }
                object sz = root.ContainsKey("size") ? root["size"] : null;
                if (!(sz is double) || (double)sz <= 0 || (double)sz != Math.Floor((double)sz) || (double)sz > 1e9) { error = "bad launcher size"; return false; }
                m.Size = (long)(double)sz;
                Uri u;
                if (!Uri.TryCreate(manifestUrl, Str(root, "url"), out u) || Str(root, "url").Length == 0) { error = "bad launcher url"; return false; }
                if (u.Scheme != manifestUrl.Scheme || !string.Equals(u.Host, manifestUrl.Host, StringComparison.OrdinalIgnoreCase) || u.Port != manifestUrl.Port)
                { error = "launcher url leaves the server"; return false; }
                m.Url = u;
                manifest = m;
                return true;
            }
            catch (FormatException ex) { error = "invalid launcher manifest: " + ex.Message; return false; }
        }

        static string Str(Dictionary<string, object> d, string k)
        {
            object v;
            return d.TryGetValue(k, out v) && v is string ? (string)v : "";
        }
    }

    internal enum SelfUpdateAction
    {
        /// <summary>No newer launcher (or no manifest).</summary>
        None,
        /// <summary>A newer launcher exists, but the game is running or downloading: try again on a later check.</summary>
        Wait,
        /// <summary>Download it, swap the exe and restart.</summary>
        Apply,
        /// <summary>A newer launcher exists but this folder cannot be updated in place (not writable, or it failed too often): show the download link.</summary>
        LinkOnly,
    }

    /// <summary>
    /// The launcher updates itself (owner 2026-10-15). Windows will not overwrite a running exe but will rename it, so:
    /// download `DeathMuffinLauncher.exe.new` and check its size and SHA-256, rename the running exe to `.old`, move `.new` into its place,
    /// start it, exit. The new launcher removes `.old` when it starts. Nothing here touches the UI; LauncherForm drives it.
    /// </summary>
    internal static class SelfUpdate
    {
        /// <summary>After this many failed attempts in one session the launcher stops trying and shows the download link.</summary>
        public const int MaxFailures = 3;

        public static SelfUpdateAction Decide(LauncherManifest live, string currentVersion, bool gameRunning, bool downloading, bool folderWritable, int failures)
        {
            if (live == null || VersionCompare.Compare(live.Version, currentVersion) <= 0) return SelfUpdateAction.None;
            if (!folderWritable || failures >= MaxFailures) return SelfUpdateAction.LinkOnly;
            if (gameRunning || downloading) return SelfUpdateAction.Wait;
            return SelfUpdateAction.Apply;
        }

        public static string NewPath(string exePath) { return exePath + ".new"; }
        public static string OldPath(string exePath) { return exePath + ".old"; }
        static string PartPath(string exePath) { return exePath + ".new.part"; }

        /// <summary>True when the launcher may create and rename files next to its exe (false under Program Files without admin rights).</summary>
        public static bool FolderWritable(string exePath)
        {
            try
            {
                string probe = Path.Combine(Path.GetDirectoryName(exePath), ".write-test-" + Guid.NewGuid().ToString("N"));
                File.WriteAllBytes(probe, new byte[0]);
                File.Delete(probe);
                return true;
            }
            catch (Exception) { return false; }
        }

        /// <summary>Removes what an earlier update left behind (the previous exe, a half download). Called at start; never throws.</summary>
        public static void CleanUp(string exePath)
        {
            foreach (string p in new[] { OldPath(exePath), PartPath(exePath), NewPath(exePath) })
            {
                // The previous launcher may still be closing for a moment after it started this one.
                for (int i = 0; i < 10 && File.Exists(p); i++)
                {
                    try { File.Delete(p); }
                    catch (Exception) { Thread.Sleep(300); }
                }
            }
        }

        /// <summary>Downloads the new exe next to the running one as `.new`, checked by size and SHA-256. Throws on any failure (nothing is swapped).</summary>
        public static async Task DownloadAsync(HttpClient http, LauncherManifest m, string exePath, CancellationToken ct)
        {
            string part = PartPath(exePath), next = NewPath(exePath);
            if (File.Exists(part)) File.Delete(part);
            using (var resp = await http.GetAsync(m.Url, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false))
            {
                resp.EnsureSuccessStatusCode();
                using (var src = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false))
                using (var dst = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
                {
                    var buf = new byte[1 << 16];
                    long total = 0;
                    int n;
                    while ((n = await src.ReadAsync(buf, 0, buf.Length, ct).ConfigureAwait(false)) > 0)
                    {
                        total += n;
                        if (total > m.Size) throw new InvalidDataException("launcher download is larger than the manifest says");
                        await dst.WriteAsync(buf, 0, n, ct).ConfigureAwait(false);
                    }
                }
            }
            if (!Hashing.Verify(part, m.Size, m.Sha256))
            {
                try { File.Delete(part); } catch (Exception) { }
                throw new InvalidDataException("launcher download failed its SHA-256 check");
            }
            if (File.Exists(next)) File.Delete(next);
            File.Move(part, next);
        }

        /// <summary>
        /// Puts the downloaded `.new` in place of the running exe: running -> `.old`, `.new` -> exe. If the second step fails the first is undone,
        /// so the folder always holds a working launcher. Throws when it could not swap.
        /// </summary>
        public static void Swap(string exePath)
        {
            string next = NewPath(exePath), old = OldPath(exePath);
            if (!File.Exists(next)) throw new FileNotFoundException("no downloaded launcher to install", next);
            if (File.Exists(old)) File.Delete(old);
            File.Move(exePath, old);
            try { File.Move(next, exePath); }
            catch (Exception)
            {
                try { File.Move(old, exePath); } catch (Exception) { }
                throw;
            }
        }
    }
}
