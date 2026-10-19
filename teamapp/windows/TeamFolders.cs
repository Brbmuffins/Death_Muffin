using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;

namespace DeathMuffinTeam
{
    /// <summary>
    /// The app's folder, %LOCALAPPDATA%\DeathMuffinTeam\: cache\&lt;cacheKey&gt;\ (files kept across jobs), jobs\&lt;id&gt;\ (one job: game\, run-&lt;n&gt;\appdata\ and run-&lt;n&gt;\localappdata\ (a fresh pair for each
    /// run of the game), out\&lt;preset&gt;\ or bench-&lt;n&gt;\ for each benchmark setup, plan.json, job.log), settings.json and app.log.
    /// </summary>
    internal sealed class TeamFolders
    {
        static readonly Regex JobIdRe = new Regex("^[A-Za-z0-9]{1,24}$", RegexOptions.CultureInvariant);

        public readonly string Root;

        public TeamFolders(string root) { Root = root; }

        public string CacheRoot { get { return Path.Combine(Root, "cache"); } }
        public string JobsRoot { get { return Path.Combine(Root, "jobs"); } }
        public string CacheDir(string key) { return Path.Combine(CacheRoot, key); }
        public string JobDir(string id) { return Path.Combine(JobsRoot, id); }
        public string GameDir(string id) { return Path.Combine(JobDir(id), "game"); }
        public string OutDir(string id) { return Path.Combine(JobDir(id), "out"); }
        /// <summary>The n-th run of the game in a job (1, 2, ...): each preset of a `shots` job, each try of each `bench` setup.</summary>
        public string RunDir(string id, int run) { return Path.Combine(JobDir(id), "run-" + Num(run)); }
        /// <summary>
        /// The game's APPDATA and LOCALAPPDATA for one run, so Godot's user:// never touches the player's own game, settings or account, and one run never finds another's offline save,
        /// settings or log (JobRunner empties them before the run).
        /// </summary>
        public string AppDataDir(string id, int run) { return Path.Combine(RunDir(id, run), "appdata"); }
        public string LocalAppDataDir(string id, int run) { return Path.Combine(RunDir(id, run), "localappdata"); }
        /// <summary>A `bench` job's folder for its n-th setup (1, 2, ...): the game's `--bench-dir`, where its `pending.json` is left.</summary>
        public string BenchDir(string id, int n) { return Path.Combine(JobDir(id), "bench-" + Num(n)); }
        static string Num(int n) { return n.ToString(System.Globalization.CultureInfo.InvariantCulture); }
        public string PlanFile(string id) { return Path.Combine(JobDir(id), "plan.json"); }
        public string LogFile(string id) { return Path.Combine(JobDir(id), "job.log"); }

        /// <summary>The newest job folder that has a log, or null.</summary>
        public string LatestLog()
        {
            try
            {
                if (!Directory.Exists(JobsRoot)) return null;
                string best = null;
                DateTime bestTime = DateTime.MinValue;
                foreach (string dir in Directory.GetDirectories(JobsRoot))
                {
                    string log = Path.Combine(dir, "job.log");
                    if (!File.Exists(log)) continue;
                    DateTime t = File.GetLastWriteTimeUtc(log);
                    if (best == null || t > bestTime) { best = log; bestTime = t; }
                }
                return best;
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }

        /// <summary>Removes the oldest job folders so that <paramref name="keep"/> are left (the one named in <paramref name="protectId"/> is always one of them). Never throws.</summary>
        public void PruneJobs(int keep, string protectId)
        {
            try
            {
                if (!Directory.Exists(JobsRoot)) return;
                var dirs = new List<DirectoryInfo>();
                foreach (string d in Directory.GetDirectories(JobsRoot))
                {
                    var di = new DirectoryInfo(d);
                    if (JobIdRe.IsMatch(di.Name)) dirs.Add(di);
                }
                dirs.Sort((a, b) => b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc));
                var keepSet = new HashSet<string>();
                if (protectId != null && Directory.Exists(JobDir(protectId))) keepSet.Add(protectId);
                foreach (var di in dirs)
                {
                    if (keepSet.Count >= keep) break;
                    keepSet.Add(di.Name);
                }
                foreach (var di in dirs)
                    if (!keepSet.Contains(di.Name)) TryDelete(di.FullName);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        /// <summary>Marks a cache folder as used now (the cache keeps the most recently used keys).</summary>
        public void TouchCache(string key)
        {
            try { Directory.SetLastWriteTimeUtc(CacheDir(key), DateTime.UtcNow); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        /// <summary>Keeps <paramref name="keep"/> cache folders in all: first every key in <paramref name="protectKeys"/> (the current job's), then the most recently used others. The rest are deleted. Never throws.</summary>
        public void PruneCache(int keep, ICollection<string> protectKeys)
        {
            try
            {
                if (!Directory.Exists(CacheRoot)) return;
                var dirs = new List<DirectoryInfo>();
                foreach (string d in Directory.GetDirectories(CacheRoot)) dirs.Add(new DirectoryInfo(d));
                dirs.Sort((a, b) => b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc));
                var keepSet = new HashSet<string>();
                foreach (var di in dirs) if (protectKeys != null && protectKeys.Contains(di.Name)) keepSet.Add(di.Name);
                foreach (var di in dirs)
                {
                    if (keepSet.Count >= keep) break;
                    keepSet.Add(di.Name);
                }
                foreach (var di in dirs)
                    if (!keepSet.Contains(di.Name)) TryDelete(di.FullName);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        static void TryDelete(string dir)
        {
            try { Directory.Delete(dir, true); }
            catch (IOException) { /* a file still in use: the next job's cleanup tries again */ }
            catch (UnauthorizedAccessException) { }
        }
    }
}
