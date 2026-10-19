using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam
{
    /// <summary>A job that cannot go on, with the sentence the server (and the Discord thread) shows for it.</summary>
    internal sealed class JobFailure : Exception
    {
        public JobFailure(string message) : base(message) { }
    }

    internal sealed class RunResult
    {
        public bool Ok;
        /// <summary>Why it stopped, in plain words (also what the server was told). Empty when Ok.</summary>
        public string Error = "";
        public string Log = "";
        /// <summary>The names uploaded (`low_bag-open.png`).</summary>
        public List<string> Files = new List<string>();
        public double DownloadS, RunS;
    }

    internal interface IJobRunner
    {
        /// <summary>Runs a claimed job to the end: downloads, game runs, uploads, then done or fail. <paramref name="progress"/> may be called from any thread.</summary>
        Task<RunResult> RunAsync(string jobId, JobPlan plan, Action<string> progress, CancellationToken ct);
    }

    /// <summary>
    /// The `shots` job from a claim to done: download (checked, resumable, the art pack and the Godot template kept in cache\), start the game once per preset with
    /// its folders pointed into the job's folder, watch it (10 minutes at most, stop if the player starts Death Muffin), upload the pictures as
    /// `&lt;preset&gt;_&lt;shot&gt;.png`, then done. Anything else ends in fail with a readable error and the end of the log. Never throws.
    /// </summary>
    internal sealed class JobRunner : IJobRunner
    {
        readonly ITeamApi api;
        readonly TeamFolders folders;
        readonly FileFetcher fetcher;
        readonly IGameHost host;
        readonly IPlayerGameWatch watch;
        readonly Func<string, string, bool> linker;

        public TimeSpan RunLimit = TeamLogic.RunLimit;
        public int PollMs = 500;
        public int ApiAttempts = 3;
        public TimeSpan ApiRetryDelay = TimeSpan.FromSeconds(2);

        /// <param name="linker">Makes the second path a hard link to the first (Windows: CreateHardLink); false makes the runner copy the file. Null always copies.</param>
        public JobRunner(ITeamApi api, TeamFolders folders, FileFetcher fetcher, IGameHost host, IPlayerGameWatch watch, Func<string, string, bool> linker)
        {
            this.api = api;
            this.folders = folders;
            this.fetcher = fetcher;
            this.host = host;
            this.watch = watch;
            this.linker = linker;
        }

        public async Task<RunResult> RunAsync(string jobId, JobPlan plan, Action<string> progress, CancellationToken ct)
        {
            var log = new StringBuilder();
            Action<string> note = s => { lock (log) log.Append(DateTime.UtcNow.ToString("HH:mm:ss", CultureInfo.InvariantCulture)).Append(' ').Append(s).Append('\n'); };
            var result = new RunResult();
            var uploaded = new List<string>();
            string error = null;
            try
            {
                note("job " + jobId + ", build " + (plan.Rev.Length > 0 ? plan.Rev : "?") + ", Godot " + (plan.GodotVersion.Length > 0 ? plan.GodotVersion : "?") + ", presets " + string.Join(",", plan.Presets));
                string gameDir = folders.GameDir(jobId), outDir = folders.OutDir(jobId), appData = folders.AppDataDir(jobId), localAppData = folders.LocalAppDataDir(jobId);
                Directory.CreateDirectory(gameDir);
                Directory.CreateDirectory(outDir);
                Directory.CreateDirectory(appData);
                Directory.CreateDirectory(localAppData);
                folders.PruneJobs(TeamLogic.KeepJobFolders, jobId);
                watch.Begin();

                // ---- 1. The files -------------------------------------------------------------------------------------------------
                var clock = Stopwatch.StartNew();
                var usedKeys = new HashSet<string>();
                int fileNo = 0;
                foreach (PlanFile f in plan.Files)
                {
                    ct.ThrowIfCancellationRequested();
                    CheckPlayer(0);
                    fileNo++;
                    string gamePath = Path.Combine(gameDir, f.Name);
                    string target = gamePath;
                    if (f.IsCached)
                    {
                        Directory.CreateDirectory(folders.CacheDir(f.CacheKey));
                        target = Path.Combine(folders.CacheDir(f.CacheKey), f.Name);
                        usedKeys.Add(f.CacheKey);
                    }
                    int lastPct = -1;
                    Action<long> report = n =>
                    {
                        int pct = (int)Math.Min(100, n * 100 / Math.Max(1, f.Bytes));
                        if (pct != lastPct) { lastPct = pct; progress("Downloading " + f.Name + " (" + fileNo + " of " + plan.Files.Count + "): " + pct + "%"); }
                    };
                    bool fresh;
                    try { fresh = await fetcher.EnsureAsync(f, target, report, ct).ConfigureAwait(false); }
                    catch (IOException ex) { throw new JobFailure(ex.Message); }
                    note((fresh ? "downloaded " : f.IsCached ? "kept from an earlier job: " : "already here: ") + f.Name + " (" + Mb(f.Bytes) + (f.IsCached ? ", cache " + f.CacheKey : "") + ")");
                    if (f.IsCached)
                    {
                        folders.TouchCache(f.CacheKey);
                        Place(target, gamePath);
                    }
                }
                folders.PruneCache(TeamLogic.KeepCacheKeys, usedKeys);
                result.DownloadS = clock.Elapsed.TotalSeconds;

                string planPath = folders.PlanFile(jobId);
                File.WriteAllText(planPath, plan.PlanJson, new UTF8Encoding(false));

                // ---- 2. The game, once per preset ---------------------------------------------------------------------------------
                var pictures = new List<KeyValuePair<string, string>>();
                var usedNames = new HashSet<string>();
                var runClock = new Stopwatch();
                for (int i = 0; i < plan.Presets.Count; i++)
                {
                    ct.ThrowIfCancellationRequested();
                    CheckPlayer(0);
                    string preset = plan.Presets[i];
                    string shotsDir = Path.Combine(outDir, preset);
                    Directory.CreateDirectory(shotsDir);
                    foreach (string old in Directory.GetFiles(shotsDir, "*.png")) File.Delete(old);   // a picture left by an earlier try is not this run's
                    progress("Taking pictures on " + JobPlan.PresetLabel(preset) + " (" + (i + 1) + " of " + plan.Presets.Count + ")");
                    runClock.Start();
                    try { await RunGameAsync(plan, preset, planPath, shotsDir, gameDir, appData, localAppData, note, ct).ConfigureAwait(false); }
                    finally { runClock.Stop(); }
                    var found = JobPlan.UploadNames(preset, Directory.GetFiles(shotsDir, "*.png"), usedNames);
                    if (found.Count == 0) { AppendGodotLog(appData, note); throw new JobFailure("The game finished on " + JobPlan.PresetLabel(preset) + " but made no pictures."); }
                    note(JobPlan.PresetLabel(preset) + ": " + found.Count + " picture(s)");
                    pictures.AddRange(found);
                }
                result.RunS = runClock.Elapsed.TotalSeconds;
                if (pictures.Count > JobPlan.MaxUploads)
                {
                    note("more than " + JobPlan.MaxUploads + " pictures: only the first " + JobPlan.MaxUploads + " are sent");
                    pictures.RemoveRange(JobPlan.MaxUploads, pictures.Count - JobPlan.MaxUploads);
                }

                // ---- 3. Upload, then done -------------------------------------------------------------------------------------------
                for (int i = 0; i < pictures.Count; i++)
                {
                    ct.ThrowIfCancellationRequested();
                    progress("Uploading pictures (" + (i + 1) + " of " + pictures.Count + ")");
                    byte[] png = File.ReadAllBytes(pictures[i].Key);
                    if (png.Length == 0 || png.Length > JobPlan.MaxUploadBytes) throw new JobFailure("The picture " + pictures[i].Value + " is " + (png.Length == 0 ? "empty" : "too big (" + Mb(png.Length) + ")") + ".");
                    ApiResult up = await WithRetry(() => api.UploadAsync(jobId, pictures[i].Value, png, ct), ct).ConfigureAwait(false);
                    if (!up.Ok) throw new JobFailure("The server did not take the picture " + pictures[i].Value + ": " + up.Error);
                    uploaded.Add(pictures[i].Value);
                    note("uploaded " + pictures[i].Value + " (" + png.Length + " bytes)");
                }
                note("finished: " + uploaded.Count + " picture(s), download " + result.DownloadS.ToString("0.0", CultureInfo.InvariantCulture) + " s, run " + result.RunS.ToString("0.0", CultureInfo.InvariantCulture) + " s");
                string text = Snapshot(log);
                ApiResult done = await WithRetry(() => api.DoneAsync(jobId, uploaded, text, result.DownloadS, result.RunS, ct), ct).ConfigureAwait(false);
                result.Files = uploaded;
                result.Log = text;
                if (!done.Ok)
                {
                    result.Error = "The pictures were uploaded, but the server did not accept the finished job: " + done.Error;
                    note(result.Error);
                    WriteLog(jobId, log);
                    return result;
                }
                result.Ok = true;
                WriteLog(jobId, log);
                progress("Done: " + uploaded.Count + " picture(s) uploaded");
                return result;
            }
            catch (JobFailure jf) { error = jf.Message; }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { error = "stopped: the team app was closed"; }
            catch (Exception ex) { error = "The job stopped because of a problem on this PC: " + ex.Message; }

            note("FAILED: " + error);
            result.Error = error;
            result.Log = Snapshot(log);
            WriteLog(jobId, log);
            try
            {
                using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
                    await api.FailAsync(jobId, error, result.Log, cts.Token).ConfigureAwait(false);
            }
            catch (Exception) { /* the server's sweep puts the job back or fails it when this PC goes quiet */ }
            return result;

            void CheckPlayer(int ownPid)
            {
                if (watch.PlayerStarted(ownPid)) throw new JobFailure("stopped: the game started");
            }
        }

        async Task RunGameAsync(JobPlan plan, string preset, string planPath, string shotsDir, string gameDir, string appData, string localAppData, Action<string> note, CancellationToken ct)
        {
            string label = JobPlan.PresetLabel(preset);
            var launch = new GameLaunch
            {
                ExePath = Path.Combine(gameDir, JobPlan.GameExe),
                WorkingDir = gameDir,
                AppData = appData,
                LocalAppData = localAppData,
                Args = plan.CommandArgs(preset, planPath, shotsDir),
            };
            note("start " + label + ": " + JobPlan.GameExe + " " + CommandLineText.Join(launch.Args));
            IGameProcess proc;
            try { proc = host.Start(launch); }
            catch (Exception ex) { throw new JobFailure("The game could not be started for " + label + ": " + ex.Message); }
            string failure = null;
            int exit = 0;
            using (proc)
            {
                var sw = Stopwatch.StartNew();
                try
                {
                    while (!proc.HasExited)
                    {
                        if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
                        if (watch.PlayerStarted(proc.Id)) { failure = "stopped: the game started"; break; }
                        if (sw.Elapsed > RunLimit) { failure = "The game took longer than " + Limit(RunLimit) + " on " + label + " and was stopped."; break; }
                        proc.Tend();
                        await Task.Delay(PollMs, ct).ConfigureAwait(false);
                    }
                }
                finally
                {
                    if (!proc.HasExited) proc.Kill();
                }
                if (failure == null) exit = proc.ExitCode;
                string output = proc.Output();
                if (output.Length > 0) note("game output (" + label + "):\n" + TextClip.Tail(output, 16000));
                note(label + ": the game ran " + sw.Elapsed.TotalSeconds.ToString("0.0", CultureInfo.InvariantCulture) + " s" + (failure == null ? ", exit code " + exit : ", " + failure));
            }
            if (failure != null) { AppendGodotLog(appData, note); throw new JobFailure(failure); }
            if (exit != 0)
            {
                AppendGodotLog(appData, note);
                throw new JobFailure("The game stopped with code " + exit + " on " + label + " before it took every picture.");
            }
        }

        // ---- Helpers -------------------------------------------------------------------------------------------------------------

        /// <summary>The same file in the game's folder: a hard link when Windows allows it (no second 500 MB copy), else a copy.</summary>
        void Place(string cacheFile, string gameFile)
        {
            if (File.Exists(gameFile)) File.Delete(gameFile);
            bool linked = false;
            try { linked = linker != null && linker(gameFile, cacheFile) && File.Exists(gameFile) && new FileInfo(gameFile).Length == new FileInfo(cacheFile).Length; }
            catch (Exception) { linked = false; }
            if (!linked)
            {
                if (File.Exists(gameFile)) File.Delete(gameFile);
                File.Copy(cacheFile, gameFile, true);
            }
        }

        async Task<ApiResult> WithRetry(Func<Task<ApiResult>> call, CancellationToken ct)
        {
            ApiResult r = null;
            for (int attempt = 1; attempt <= ApiAttempts; attempt++)
            {
                r = await call().ConfigureAwait(false);
                bool retry = r.Network || r.Status >= 500 || r.Status == 429;
                if (r.Ok || !retry || attempt == ApiAttempts) return r;
                await Task.Delay(TimeSpan.FromMilliseconds(ApiRetryDelay.TotalMilliseconds * attempt), ct).ConfigureAwait(false);
            }
            return r;
        }

        /// <summary>Godot's own log from the job's APPDATA folder, when the game failed: it often says what the console did not.</summary>
        static void AppendGodotLog(string appData, Action<string> note)
        {
            try
            {
                foreach (string file in Directory.GetFiles(appData, "godot*.log", SearchOption.AllDirectories))
                {
                    string text = File.ReadAllText(file);
                    note("Godot's log (" + Path.GetFileName(file) + "):\n" + TextClip.Tail(text, 8000));
                    return;
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        static string Snapshot(StringBuilder log) { lock (log) return log.ToString(); }

        void WriteLog(string jobId, StringBuilder log)
        {
            try { File.WriteAllText(folders.LogFile(jobId), Snapshot(log), new UTF8Encoding(false)); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        static string Mb(long bytes) { return Math.Max(1, (long)Math.Round(bytes / 1048576.0)).ToString(CultureInfo.InvariantCulture) + " MB"; }

        static string Limit(TimeSpan t)
        {
            if (t.TotalMinutes >= 1)
            {
                long m = (long)Math.Round(t.TotalMinutes);
                return m == 1 ? "1 minute" : m.ToString(CultureInfo.InvariantCulture) + " minutes";
            }
            long sec = Math.Max(1, (long)Math.Round(t.TotalSeconds));
            return sec == 1 ? "1 second" : sec.ToString(CultureInfo.InvariantCulture) + " seconds";
        }
    }
}
