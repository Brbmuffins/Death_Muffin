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
        /// <summary>The server cancelled the job while it ran: the game was stopped and nothing was sent, not even a fail (the server knows).</summary>
        public bool Cancelled;
        /// <summary>Why it stopped, in plain words (also what the server was told, except for a cancelled job). Empty when Ok.</summary>
        public string Error = "";
        public string Log = "";
        /// <summary>The names uploaded (`low_bag-open.png`).</summary>
        public List<string> Files = new List<string>();
        /// <summary>A `bench` job: how many benchmark runs were sent.</summary>
        public int Runs;
        public double DownloadS, RunS;
    }

    internal interface IJobRunner
    {
        /// <summary>
        /// Runs a claimed job to the end: downloads, game runs, uploads, then done or fail. <paramref name="progress"/> may be called from any thread. <paramref name="appClosing"/> stops the job
        /// and tells the server it failed; <paramref name="serverCancelled"/> (the server's heartbeat said so) stops it and tells the server nothing: the job is dropped.
        /// </summary>
        Task<RunResult> RunAsync(string jobId, JobPlan plan, Action<string> progress, CancellationToken appClosing, CancellationToken serverCancelled);
    }

    /// <summary>
    /// A job from a claim to done. `shots`: download (checked, resumable, the art pack and the Godot template kept in cache\), start the game once per preset with
    /// its folders pointed into the job's folder, watch it (10 minutes at most, stop if the player starts Death Muffin), upload the pictures as
    /// `&lt;preset&gt;_&lt;shot&gt;.png`, then done. `bench`: the same download, then for each setup wait for a quiet PC, run the game's benchmark at normal priority (15 minutes at most),
    /// throw the run away and try again (3 tries) when the PC was touched, and send the runs with done. Anything else ends in fail with a readable error and the end of the log. Never throws.
    /// </summary>
    internal sealed class JobRunner : IJobRunner
    {
        readonly ITeamApi api;
        readonly TeamFolders folders;
        readonly FileFetcher fetcher;
        readonly IGameHost host;
        readonly IPlayerGameWatch watch;
        readonly Func<string, string, bool> linker;
        readonly IPcProbe probe;

        public TimeSpan RunLimit = TeamLogic.RunLimit;
        public TimeSpan BenchRunLimit = TeamLogic.BenchRunLimit;
        public int PollMs = 500;
        /// <summary>A `bench` job reads the PC this often (the CPU numbers are averages over it).</summary>
        public int SampleMs = 1000;
        public int BenchTries = 3;
        public QuietRules Rules = new QuietRules();
        /// <summary>Where a screenshot job's game window goes (`--position X,Y`, outside every monitor: Platform computes it from the virtual screen each time, JobPlan.OffscreenPosition); null leaves it to Godot.</summary>
        public Func<string> ShotsPosition;
        /// <summary>How long a `bench` job waits for a quiet PC when the plan does not say when the job's life ends (the server keeps a job 3 days).</summary>
        public TimeSpan QuietWaitLimit = TimeSpan.FromDays(3);
        public int ApiAttempts = 3;
        public TimeSpan ApiRetryDelay = TimeSpan.FromSeconds(2);

        /// <param name="linker">Makes the second path a hard link to the first (Windows: CreateHardLink); false makes the runner copy the file. Null always copies.</param>
        /// <param name="probe">Reads the PC (CPU, keyboard and mouse, battery, full screen, the player's game): what a `bench` job needs to know whether the PC is quiet.</param>
        public JobRunner(ITeamApi api, TeamFolders folders, FileFetcher fetcher, IGameHost host, IPlayerGameWatch watch, Func<string, string, bool> linker, IPcProbe probe)
        {
            this.api = api;
            this.folders = folders;
            this.fetcher = fetcher;
            this.host = host;
            this.watch = watch;
            this.linker = linker;
            this.probe = probe;
        }

        public async Task<RunResult> RunAsync(string jobId, JobPlan plan, Action<string> progress, CancellationToken appClosing, CancellationToken serverCancelled)
        {
            using (var both = CancellationTokenSource.CreateLinkedTokenSource(appClosing, serverCancelled))
                return await RunLinkedAsync(jobId, plan, progress, both.Token, serverCancelled).ConfigureAwait(false);
        }

        /// <param name="ct">Either of the two: the app closing or the server's cancel.</param>
        async Task<RunResult> RunLinkedAsync(string jobId, JobPlan plan, Action<string> progress, CancellationToken ct, CancellationToken serverCancelled)
        {
            var log = new StringBuilder();
            Action<string> note = s => { lock (log) log.Append(DateTime.UtcNow.ToString("HH:mm:ss", CultureInfo.InvariantCulture)).Append(' ').Append(s).Append('\n'); };
            var result = new RunResult();
            var uploaded = new List<string>();
            string error = null;
            bool cancelled = false;
            try
            {
                string what = plan.Kind == JobPlan.BenchKind ? "benchmark, " + plan.Setups.Count + " setup(s)" : "presets " + string.Join(",", plan.Presets);
                note("job " + jobId + ", build " + (plan.Rev.Length > 0 ? plan.Rev : "?") + ", Godot " + (plan.GodotVersion.Length > 0 ? plan.GodotVersion : "?") + ", " + what);
                string gameDir = folders.GameDir(jobId), outDir = folders.OutDir(jobId);
                Directory.CreateDirectory(gameDir);
                Directory.CreateDirectory(outDir);
                folders.PruneJobs(TeamLogic.KeepJobFolders, jobId);
                watch.Begin();

                // ---- 1. The files -------------------------------------------------------------------------------------------------
                var clock = Stopwatch.StartNew();
                var usedKeys = new HashSet<string>();
                int fileNo = 0;
                foreach (PlanFile f in plan.Files)
                {
                    ct.ThrowIfCancellationRequested();
                    if (plan.Kind == JobPlan.ShotsKind) CheckPlayer(0);   // a benchmark waits for a quiet PC instead (the PC's readings, not this watch, say whether Death Muffin is open)
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
                if (plan.Kind == JobPlan.BenchKind) return await RunBenchAsync(jobId, plan, result, log, note, progress, ct).ConfigureAwait(false);

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
                    string appData = await FreshRunFoldersAsync(jobId, i + 1, ct).ConfigureAwait(false), localAppData = folders.LocalAppDataDir(jobId, i + 1);
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
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                if (serverCancelled.IsCancellationRequested) cancelled = true;
                else error = "stopped: the team app was closed";
            }
            catch (Exception ex) { error = "The job stopped because of a problem on this PC: " + ex.Message; }

            if (cancelled)
            {
                // The server cancelled the job (the game is already stopped): it knows, so nothing is sent, not even a fail.
                note("CANCELLED by the server: the job is dropped");
                result.Cancelled = true;
                result.Error = "The job was cancelled.";
                result.Log = Snapshot(log);
                WriteLog(jobId, log);
                return result;
            }
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
                Args = plan.CommandArgs(preset, planPath, shotsDir, ShotsPosition == null ? null : ShotsPosition()),
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

        // ---- The `bench` job -------------------------------------------------------------------------------------------------------

        /// <summary>
        /// A `bench` job with its files in place: for each setup wait until the PC is quiet, run the game's benchmark (a trial in the setup's own `bench-n` folder that sends nothing),
        /// and read the run it queued. A run during which the PC was touched is thrown away with its folder, and the setup starts over once the PC is quiet again (at most
        /// <see cref="BenchTries"/> tries); then done with every run.
        /// </summary>
        async Task<RunResult> RunBenchAsync(string jobId, JobPlan plan, RunResult result, StringBuilder log, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            string gameDir = folders.GameDir(jobId);
            int runNo = 0;
            DateTime deadline = plan.ExpiresAtUtc ?? DateTime.UtcNow + QuietWaitLimit;
            var runs = new List<Dictionary<string, object>>();
            var runClock = new Stopwatch();
            for (int i = 0; i < plan.Setups.Count; i++)
            {
                BenchSetup setup = plan.Setups[i];
                string label = JobPlan.PresetLabel(setup.Preset);
                string where = label + " (" + (i + 1) + " of " + plan.Setups.Count + ")";
                string benchDir = folders.BenchDir(jobId, i + 1);
                note("setup " + (i + 1) + ": " + label + ", " + setup.Describe());
                for (int attempt = 1; ; attempt++)
                {
                    ct.ThrowIfCancellationRequested();
                    await WaitQuietAsync(deadline, note, progress, ct).ConfigureAwait(false);
                    await ResetDirAsync(benchDir, ct).ConfigureAwait(false);
                    runNo++;
                    string appData = await FreshRunFoldersAsync(jobId, runNo, ct).ConfigureAwait(false), localAppData = folders.LocalAppDataDir(jobId, runNo);
                    progress("Benchmark on " + where + (attempt > 1 ? ", try " + attempt + " of " + BenchTries : ""));
                    string disturbed;
                    runClock.Start();
                    try { disturbed = await RunBenchGameAsync(plan, setup, label, benchDir, gameDir, appData, localAppData, note, ct).ConfigureAwait(false); }
                    finally { runClock.Stop(); }
                    if (disturbed.Length == 0) break;
                    note(label + ": the run was disturbed (" + disturbed + ") and thrown away");
                    await ResetDirAsync(benchDir, ct).ConfigureAwait(false);
                    if (attempt >= BenchTries)
                        throw new JobFailure("The benchmark on " + label + " was disturbed " + BenchTries + " times (" + disturbed + "), so no numbers were sent. Leave the PC alone while it runs.");
                }
                Dictionary<string, object> run;
                string err;
                if (!JobPlan.TryReadBenchRun(benchDir, label, out run, out err)) { AppendGodotLog(folders.AppDataDir(jobId, runNo), note); throw new JobFailure(err); }
                note(label + ": the run was recorded (" + MiniJson.Write(run).Length + " bytes of JSON)");
                runs.Add(run);
            }
            result.RunS = runClock.Elapsed.TotalSeconds;
            note("finished: " + runs.Count + " run(s), download " + result.DownloadS.ToString("0.0", CultureInfo.InvariantCulture) + " s, run " + result.RunS.ToString("0.0", CultureInfo.InvariantCulture) + " s");
            string text = Snapshot(log);
            ct.ThrowIfCancellationRequested();
            ApiResult done = await WithRetry(() => api.DoneBenchAsync(jobId, runs, text, result.DownloadS, result.RunS, ct), ct).ConfigureAwait(false);
            result.Runs = runs.Count;
            result.Log = text;
            if (!done.Ok)
            {
                result.Error = "The benchmark ran, but the server did not accept the results: " + done.Error;
                note(result.Error);
                WriteLog(jobId, log);
                return result;
            }
            result.Ok = true;
            WriteLog(jobId, log);
            progress("Done: " + runs.Count + " benchmark run(s) sent");
            return result;
        }

        /// <summary>Returns when the PC has been quiet for long enough (Quiet.WhyNotQuiet), reading it once a <see cref="SampleMs"/>; fails the job when the job's life ends first.</summary>
        async Task WaitQuietAsync(DateTime deadline, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            var samples = new List<PcSample>();
            string why = "", seen = null, statusShape = null;
            var statusClock = new Stopwatch();
            probe.Read(0);   // the CPU numbers are averages since the previous reading: this one only sets the start
            while (true)
            {
                await Task.Delay(SampleMs, ct).ConfigureAwait(false);
                if (DateTime.UtcNow > deadline) throw new JobFailure("The PC never went quiet for long enough" + (why.Length > 0 ? ": " + why : "") + ".");
                PcSample s = probe.Read(0);
                samples.Add(s);
                while (samples.Count > 1 && s.At - samples[0].At > Rules.QuietFor + Rules.QuietFor) samples.RemoveAt(0);
                why = Quiet.WhyNotQuiet(samples, Rules);
                string shape = Shape(why);
                if (shape != seen) { seen = shape; note(why.Length == 0 ? "the PC is quiet" : "waiting for a quiet PC: " + why); }
                if (why.Length == 0) return;
                // the status changes with the reason, and for its counters ("12 s ago") every 5 s: not once a reading
                if (!statusClock.IsRunning || statusClock.ElapsedMilliseconds >= 5000 || shape != statusShape) { statusShape = shape; statusClock.Restart(); progress("Waiting for a quiet PC: " + why); }
            }
        }

        /// <summary>
        /// One run of the game's benchmark at normal priority, watched. Returns "" when the PC was left alone and the game ended with code 0 (its run is in the folder), or why the run was
        /// disturbed (the game is stopped then). Anything else (the game not starting, 15 minutes, a code other than 0) is a JobFailure.
        /// </summary>
        async Task<string> RunBenchGameAsync(JobPlan plan, BenchSetup setup, string label, string benchDir, string gameDir, string appData, string localAppData, Action<string> note, CancellationToken ct)
        {
            var launch = new GameLaunch
            {
                ExePath = Path.Combine(gameDir, JobPlan.BenchExe),
                WorkingDir = gameDir,
                AppData = appData,
                LocalAppData = localAppData,
                Args = plan.BenchCommandArgs(setup, benchDir),
                Priority = ProcessPriorityClass.Normal,
            };
            note("start " + label + ": " + JobPlan.BenchExe + " " + CommandLineText.Join(launch.Args));
            TimeSpan runStart = probe.Read(0).At;
            IGameProcess proc;
            try { proc = host.Start(launch); }
            catch (Exception ex) { throw new JobFailure("The game could not be started for " + label + ": " + ex.Message); }
            string failure = null, disturbed = "";
            int exit = 0;
            var samples = new List<PcSample>();
            using (proc)
            {
                var sw = Stopwatch.StartNew();
                var sampleClock = Stopwatch.StartNew();
                try
                {
                    while (!proc.HasExited)
                    {
                        if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
                        if (sampleClock.ElapsedMilliseconds >= SampleMs)
                        {
                            sampleClock.Restart();
                            samples.Add(probe.Read(proc.Id));
                            disturbed = Quiet.Disturbance(samples, runStart, Rules);
                            if (disturbed.Length > 0) break;
                        }
                        if (sw.Elapsed > BenchRunLimit) { failure = "The benchmark took longer than " + Limit(BenchRunLimit) + " on " + label + " and was stopped."; break; }
                        proc.Tend();
                        await Task.Delay(PollMs, ct).ConfigureAwait(false);
                    }
                }
                finally
                {
                    if (!proc.HasExited) proc.Kill();
                }
                if (failure == null && disturbed.Length == 0) exit = proc.ExitCode;
                string output = proc.Output();
                if (output.Length > 0) note("game output (" + label + "):\n" + TextClip.Tail(output, 16000));
                double others = 0;
                foreach (PcSample s in samples) others += s.CpuOthers;
                note(label + ": the game ran " + sw.Elapsed.TotalSeconds.ToString("0.0", CultureInfo.InvariantCulture) + " s" + (failure == null && disturbed.Length == 0 ? ", exit code " + exit : ", stopped")
                    + (samples.Count > 0 ? "; other programs used about " + ((int)Math.Round(others / samples.Count)).ToString(CultureInfo.InvariantCulture) + "% of the CPU (" + samples.Count + " readings)" : ""));
            }
            if (disturbed.Length > 0) return disturbed;
            if (failure != null) { AppendGodotLog(appData, note); throw new JobFailure(failure); }
            if (exit != 0) { AppendGodotLog(appData, note); throw new JobFailure(BenchExitText(exit, label)); }
            return "";
        }

        /// <summary>What the game's exit code says (main.gd: 0 a run was recorded, 1 it was cancelled or failed, 2 a setup it refuses).</summary>
        static string BenchExitText(int exit, string label)
        {
            if (exit == 2) return "The game refused the benchmark setup on " + label + " (code 2).";
            if (exit == 1) return "The game did not finish the benchmark on " + label + " (it was cancelled or failed, code 1).";
            return "The game stopped with code " + exit + " on " + label + " before the benchmark was done.";
        }

        /// <summary>
        /// The n-th run of the game gets its own APPDATA and LOCALAPPDATA, empty (Godot's user:// lives there: a Low run's offline save must not be the Ultra run's start, nor a disturbed
        /// run's the retry's). Returns the APPDATA path.
        /// </summary>
        async Task<string> FreshRunFoldersAsync(string jobId, int run, CancellationToken ct)
        {
            await ResetDirAsync(folders.RunDir(jobId, run), ct).ConfigureAwait(false);
            Directory.CreateDirectory(folders.AppDataDir(jobId, run));
            Directory.CreateDirectory(folders.LocalAppDataDir(jobId, run));
            return folders.AppDataDir(jobId, run);
        }

        /// <summary>The folder emptied and made again (the game wants `--bench-dir` to exist); a killed game may still hold a file for a moment.</summary>
        static async Task ResetDirAsync(string dir, CancellationToken ct)
        {
            for (int tries = 1; ; tries++)
            {
                try
                {
                    if (Directory.Exists(dir)) Directory.Delete(dir, true);
                    Directory.CreateDirectory(dir);
                    return;
                }
                catch (IOException) when (tries < 5) { }
                catch (UnauthorizedAccessException) when (tries < 5) { }
                await Task.Delay(250, ct).ConfigureAwait(false);
            }
        }

        /// <summary>The words with every number as "#": "used 12 s ago" and "used 13 s ago" are one reason (the log says it once).</summary>
        static string Shape(string text)
        {
            var sb = new StringBuilder();
            bool digit = false;
            foreach (char c in text)
            {
                if (c >= '0' && c <= '9') { if (!digit) sb.Append('#'); digit = true; }
                else { sb.Append(c); digit = false; }
            }
            return sb.ToString();
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
                    string text = GodotLog.Clean(File.ReadAllText(file));
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
