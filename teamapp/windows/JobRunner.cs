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
    internal class JobFailure : Exception
    {
        public JobFailure(string message) : base(message) { }
    }

    /// <summary>The player started Death Muffin: the whole job stops (unlike a failed step of a `release` job, which does not stop the next one).</summary>
    internal sealed class JobStopped : JobFailure
    {
        public JobStopped(string message) : base(message) { }
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
        /// <summary>A `release` job: how each step went, in the order they ran (also what a job that stops halfway tells the server).</summary>
        public List<StepReport> Steps;
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
    /// A job from a claim to done. `shots`: download (checked, resumable, the art pack and the Godot template kept in cache\; a job with a before and an after build downloads what the builds share once),
    /// start the game once per preset (and per build) with its folders pointed into the job's folder, watch it (10 minutes at most, stop if the player starts Death Muffin), upload the pictures as
    /// `&lt;preset&gt;_&lt;shot&gt;.png` (`&lt;build&gt;_&lt;preset&gt;_&lt;shot&gt;.png` with two builds), then done. `clip`: the same download, then one game run for each variant (the engine's `--fixed-fps 30`, the clip plan, the variant's
    /// tune), upload every clip as `&lt;variant&gt;_&lt;clip&gt;.mjpeg`, then done (the server makes the videos). `bench`: the same download, then for each setup wait for a quiet PC, run the game's benchmark at normal priority (15 minutes at most),
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
        /// <summary>The video encoder clips' mp4s are made with (JobPlan.Encoder: fetched once into cache\), and what runs it (tests use stand-ins).</summary>
        public PlanFile EncoderFile = JobPlan.Encoder;
        public IVideoEncoder Encoder = new FfmpegEncoder();
        /// <summary>The tray's Run benchmarks: false makes a `release` job skip its benchmark step (reported as skipped, not failed). Null: always on.</summary>
        public Func<bool> BenchmarksAllowed;
        public const string BenchSkipped = "Skipped: benchmarks are off on this PC (the team app's tray menu, Run benchmarks).";
        /// <summary>Where a screenshot job's game window goes (`--position X,Y`, outside every monitor: Platform computes it from the virtual screen each time, JobPlan.OffscreenPosition); null leaves it to Godot.</summary>
        public Func<string> ShotsPosition;
        /// <summary>The same for a window of a given width (a `release` job's screens step: 1920 to 3840 wide): the window must start left of every monitor by its own width. Null: <see cref="ShotsPosition"/> for all.</summary>
        public Func<int, string> WindowPosition;
        /// <summary>A `release` job's limits: the game reaching its first screen (the game gives up at 60 s itself), quitting while loading (20 s), the stutter scenario, and the slack added to the soak's minutes.</summary>
        public TimeSpan BootLimit = TimeSpan.FromSeconds(90);
        public TimeSpan QuitLimit = TimeSpan.FromSeconds(20);
        public TimeSpan StutterLimit = TimeSpan.FromMinutes(30);
        public TimeSpan SoakSlack = TimeSpan.FromMinutes(15);
        /// <summary>How long a `release` job's bench or soak step waits for a quiet PC before it gives up (the step fails, the next one runs).</summary>
        public TimeSpan ReleaseQuietLimit = TimeSpan.FromHours(4);
        /// <summary>How long a `bench` job waits for a quiet PC when the plan does not say when the job's life ends (the server keeps a job 3 days).</summary>
        public TimeSpan QuietWaitLimit = TimeSpan.FromDays(3);
        public int ApiAttempts = 3;
        public TimeSpan ApiRetryDelay = TimeSpan.FromSeconds(2);
        /// <summary>The ComfyUI server a `model` job runs on (Desktop's, or the app's own started for it). Null: this app runs no model jobs.</summary>
        public ComfyHost Comfy;
        /// <summary>The workflow a `model` job's runs fill in; null: the one built into the app (tests give their own).</summary>
        public ComfyWorkflow Workflow { get; set; }
        public TimeSpan ModelRunLimit = ComfyRules.RunLimit;
        public int ComfyPollMs = 2000;

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
            currentNote = note;   // CheckPlayer writes what it counted as the player's game into this job's log
            var result = new RunResult();
            string error = null;
            bool cancelled = false;
            try
            {
                var builds = plan.AllBuilds();
                string what = plan.Kind == JobPlan.BenchKind ? "benchmark, " + plan.Setups.Count + " setup(s)"
                    : plan.Kind == JobPlan.ClipKind ? "clips, " + plan.Variants.Count + " variant(s), preset " + plan.Presets[0]
                    : plan.Kind == JobPlan.ModelKind ? "3D models, " + plan.ModelRuns.Count + " run(s)"
                    : "presets " + string.Join(",", plan.Presets) + (plan.Builds.Count > 0 ? ", builds " + BuildNames(plan) : "");
                note("job " + jobId + (plan.Kind == JobPlan.ModelKind ? "" : ", build " + (plan.Rev.Length > 0 ? plan.Rev : "?") + ", Godot " + (plan.GodotVersion.Length > 0 ? plan.GodotVersion : "?")) + ", " + what);
                string outDir = folders.OutDir(jobId);
                foreach (PlanBuild b in builds) Directory.CreateDirectory(folders.GameDir(jobId, b.Label));
                Directory.CreateDirectory(outDir);
                folders.PruneJobs(TeamLogic.KeepJobFolders, jobId);
                watch.Begin();

                // ---- 1. The files -------------------------------------------------------------------------------------------------
                // A job with two builds lists each build's files; one that both have (the same checksum and size) is downloaded once and placed in the second build's folder from the first's.
                var clock = Stopwatch.StartNew();
                var fetched = new Fetched();
                foreach (PlanBuild b in builds) fetched.FileCount += b.Files.Count;
                if (plan.Kind != JobPlan.ReleaseKind)
                    foreach (PlanBuild build in builds) await FetchBuildAsync(jobId, plan, build, fetched, note, progress, ct).ConfigureAwait(false);
                // (a `release` job fetches each build when the first step that needs it runs: a download that fails fails that step, not the job)
                string encoder = plan.Kind == JobPlan.ClipKind ? await FetchEncoderAsync(fetched, note, progress, ct).ConfigureAwait(false) : null;
                fetched.UsedKeys.Add(EncoderFile.CacheKey);   // the video encoder stays in cache\ whatever job runs (105 MB, needed by every clip job)
                if (plan.Kind != JobPlan.ReleaseKind && plan.Kind != JobPlan.ModelKind) folders.PruneCache(TeamLogic.KeepCacheKeys, fetched.UsedKeys);   // (a model job's pictures are not cached)
                result.DownloadS = clock.Elapsed.TotalSeconds;
                if (plan.Kind == JobPlan.BenchKind) return await RunBenchAsync(jobId, plan, result, log, note, progress, ct).ConfigureAwait(false);
                if (plan.Kind == JobPlan.ClipKind) return await RunClipsAsync(jobId, plan, encoder, result, log, note, progress, ct).ConfigureAwait(false);
                if (plan.Kind == JobPlan.ReleaseKind) return await RunReleaseAsync(jobId, plan, fetched, result, log, note, progress, ct).ConfigureAwait(false);
                if (plan.Kind == JobPlan.ModelKind) return await RunModelAsync(jobId, plan, result, log, note, progress, ct).ConfigureAwait(false);

                string planPath = folders.PlanFile(jobId);
                File.WriteAllText(planPath, plan.PlanJson, new UTF8Encoding(false));

                // ---- 2. The game, once per preset (and per build) -----------------------------------------------------------------
                var groups = new List<List<KeyValuePair<string, string>>>();   // the pictures of each (build, preset) run, in order
                var usedNames = new HashSet<string>();
                var runClock = new Stopwatch();
                // each preset at each window size the job names (none: the one 1600x900 window), on each build
                var sizes = new List<ScreenSize>();
                if (plan.ScreenSizes.Count > 0) sizes.AddRange(plan.ScreenSizes); else sizes.Add(null);
                int runNo = 0, runTotal = builds.Count * plan.Presets.Count * sizes.Count;
                foreach (PlanBuild build in builds)
                {
                    string gameDir = folders.GameDir(jobId, build.Label);
                    for (int i = 0; i < plan.Presets.Count; i++)
                        foreach (ScreenSize size in sizes)
                        {
                            ct.ThrowIfCancellationRequested();
                            CheckPlayer(0);
                            runNo++;
                            string preset = plan.Presets[i];
                            string label = JobPlan.PresetLabel(preset) + (size != null ? " at " + size.Text : "") + (build.Label.Length > 0 ? " (" + build.Label + " build)" : "");
                            string appData = await FreshRunFoldersAsync(jobId, runNo, ct).ConfigureAwait(false), localAppData = folders.LocalAppDataDir(jobId, runNo);
                            string shotsDir = build.Label.Length > 0 ? Path.Combine(outDir, build.Label, preset) : Path.Combine(outDir, preset);
                            if (size != null) shotsDir = Path.Combine(shotsDir, size.Text);
                            Directory.CreateDirectory(shotsDir);
                            foreach (string old in Directory.GetFiles(shotsDir, "*.png")) File.Delete(old);   // a picture left by an earlier try is not this run's
                            progress("Taking pictures on " + label + " (" + runNo + " of " + runTotal + ")");
                            string position = PositionFor(size != null ? size.Width : JobPlan.ShotWidth);
                            runClock.Start();
                            try { await RunGameAsync(plan.CommandArgs(preset, planPath, shotsDir, position, size), JobPlan.GameExe, label, gameDir, appData, localAppData, "took every picture", null, note, ct).ConfigureAwait(false); }
                            finally { runClock.Stop(); }
                            string prefix = (build.Label.Length > 0 ? build.Label + "_" : "") + preset + (size != null ? "_" + size.Text : "");   // `<build>_<preset>_<w>x<h>_<shot>.png`
                            var found = JobPlan.UploadNames(prefix, Directory.GetFiles(shotsDir, "*.png"), usedNames);
                            if (found.Count == 0) { AppendGodotLog(appData, note); throw new JobFailure("The game finished on " + label + " but made no pictures."); }
                            note(label + ": " + found.Count + " picture(s)");
                            if (size != null)
                            {
                                string have = PngSize(found[0].Key);
                                if (have != null && have != size.Text) note("the pictures " + label + " are " + have + ", not " + size.Text + " (Windows held the window to the screen)");
                            }
                            groups.Add(found);
                        }
                }
                result.RunS = runClock.Elapsed.TotalSeconds;
                int all = 0;
                foreach (var g in groups) all += g.Count;
                if (all > JobPlan.MaxUploads && (builds.Count > 1 || plan.ScreenSizes.Count > 0) && groups.Count > 1)
                {
                    // the pairs must stay pairs: every (build, preset, window size) run keeps the same number of its first pictures
                    int each = Math.Max(1, JobPlan.MaxUploads / groups.Count);
                    note("more than " + JobPlan.MaxUploads + " pictures: only the first " + each + " of each build, preset and window size are sent");
                    foreach (var g in groups) if (g.Count > each) g.RemoveRange(each, g.Count - each);
                }
                var pictures = new List<KeyValuePair<string, string>>();
                foreach (var g in groups) pictures.AddRange(g);
                if (pictures.Count > JobPlan.MaxUploads)
                {
                    note("more than " + JobPlan.MaxUploads + " pictures: only the first " + JobPlan.MaxUploads + " are sent");
                    pictures.RemoveRange(JobPlan.MaxUploads, pictures.Count - JobPlan.MaxUploads);
                }

                // ---- 3. Upload, then done -------------------------------------------------------------------------------------------
                return await UploadAndFinishAsync(jobId, pictures, "picture", JobPlan.MaxUploadBytes, result, log, note, progress, ct).ConfigureAwait(false);
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
                    await api.FailAsync(jobId, error, result.Log, result.Steps, cts.Token).ConfigureAwait(false);
            }
            catch (Exception) { /* the server's sweep puts the job back or fails it when this PC goes quiet */ }
            return result;
        }

        /// <summary>What the files of a job's builds have in common while they are fetched: the cache keys in use, which file (checksum and size) is already on disk and for which build, and the progress count.</summary>
        sealed class Fetched
        {
            public readonly HashSet<string> UsedKeys = new HashSet<string>();
            public readonly Dictionary<string, string> Shared = new Dictionary<string, string>();     // checksum|size -> the file already on disk for it (a build's copy, or the cache's)
            public readonly Dictionary<string, string> SharedBy = new Dictionary<string, string>();   // checksum|size -> the build that fetched it
            public readonly Dictionary<string, string> Failed = new Dictionary<string, string>();     // build label -> why its files could not be fetched (a `release` job tries each build once)
            public readonly HashSet<string> Done = new HashSet<string>();                             // build labels fetched
            public int FileNo, FileCount;
        }

        /// <summary>The video encoder (EncoderFile), checked and kept in cache\ like the art pack: downloaded once, by the first clip job. Its path.</summary>
        async Task<string> FetchEncoderAsync(Fetched st, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            PlanFile f = EncoderFile;
            Directory.CreateDirectory(folders.CacheDir(f.CacheKey));
            string target = Path.Combine(folders.CacheDir(f.CacheKey), f.Name);
            int lastPct = -1;
            Action<long> report = n =>
            {
                int pct = (int)Math.Min(100, n * 100 / Math.Max(1, f.Bytes));
                if (pct != lastPct) { lastPct = pct; progress("Downloading the video encoder (once): " + pct + "%"); }
            };
            bool fresh;
            try { fresh = await fetcher.EnsureAsync(f, target, report, ct).ConfigureAwait(false); }
            catch (IOException ex) { throw new JobFailure("The video encoder could not be downloaded: " + ex.Message); }
            note((fresh ? "downloaded " : "kept from an earlier job: ") + f.Name + " (" + Mb(f.Bytes) + ", cache " + f.CacheKey + ")");
            folders.TouchCache(f.CacheKey);
            st.UsedKeys.Add(f.CacheKey);
            return target;
        }

        /// <summary>
        /// Fetches one build's files into its game folder: checked (SHA-256) and resumable downloads, the art pack and the Godot builds kept in cache\ and linked in, and a file an earlier build already has
        /// (the same checksum and size) placed from that copy instead of downloaded again.
        /// </summary>
        async Task FetchBuildAsync(string jobId, JobPlan plan, PlanBuild build, Fetched st, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            string gameDir = folders.GameDir(jobId, build.Label);
            Directory.CreateDirectory(gameDir);
            foreach (PlanFile f in build.Files)
            {
                ct.ThrowIfCancellationRequested();
                if (plan.Kind != JobPlan.BenchKind) CheckPlayer(0);   // a benchmark waits for a quiet PC instead (the PC's readings, not this watch, say whether Death Muffin is open)
                st.FileNo++;
                int fileNo = st.FileNo;
                string gamePath = Path.Combine(gameDir, f.Name);
                string sameFile = f.Sha256 + "|" + f.Bytes, copyOf;
                if (st.Shared.TryGetValue(sameFile, out copyOf) && File.Exists(copyOf) && new FileInfo(copyOf).Length == f.Bytes)
                {
                    Place(copyOf, gamePath);
                    if (f.IsCached) st.UsedKeys.Add(f.CacheKey);
                    note("shared with the " + st.SharedBy[sameFile] + " build: " + f.Name + " (" + Mb(f.Bytes) + ")");
                    continue;
                }
                string target = gamePath;
                if (f.IsCached)
                {
                    Directory.CreateDirectory(folders.CacheDir(f.CacheKey));
                    target = Path.Combine(folders.CacheDir(f.CacheKey), f.Name);
                    st.UsedKeys.Add(f.CacheKey);
                }
                int lastPct = -1;
                Action<long> report = n =>
                {
                    int pct = (int)Math.Min(100, n * 100 / Math.Max(1, f.Bytes));
                    if (pct != lastPct) { lastPct = pct; progress("Downloading " + f.Name + " (" + fileNo + " of " + st.FileCount + "): " + pct + "%"); }
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
                st.Shared[sameFile] = target;
                st.SharedBy[sameFile] = build.Label.Length > 0 ? build.Label : "first";
            }
            st.Done.Add(build.Label);
        }

        /// <summary>"before,after" for the log.</summary>
        static string BuildNames(JobPlan plan)
        {
            var names = new List<string>();
            foreach (PlanBuild b in plan.Builds) names.Add(b.Label);
            return string.Join(",", names);
        }

        Action<string> currentNote;

        void CheckPlayer(int ownPid)
        {
            if (watch.PlayerStarted(ownPid)) { var n = currentNote; if (n != null) n("counted as the player's game: " + watch.LastSeen); throw new JobStopped("stopped: the game started"); }
        }

        /// <summary>
        /// Uploads each result file (<paramref name="items"/>: path on disk, name on the server) and ends the job with done. <paramref name="noun"/> is "picture" or "clip": the words of the log and of a refusal.
        /// A file that is empty or over <paramref name="maxBytes"/>, or one the server will not take, fails the job. A done the server does not accept leaves the result with the error and sends nothing more.
        /// </summary>
        async Task<RunResult> UploadAndFinishAsync(string jobId, List<KeyValuePair<string, string>> items, string noun, long maxBytes, RunResult result, StringBuilder log, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            var uploaded = new List<string>();
            for (int i = 0; i < items.Count; i++)
            {
                ct.ThrowIfCancellationRequested();
                progress("Uploading " + noun + "s (" + (i + 1) + " of " + items.Count + ")");
                byte[] data = File.ReadAllBytes(items[i].Key);
                if (data.Length == 0 || data.Length > maxBytes) throw new JobFailure("The " + noun + " " + items[i].Value + " is " + (data.Length == 0 ? "empty" : "too big (" + Mb(data.Length) + ")") + ".");
                ApiResult up = await WithRetry(() => api.UploadAsync(jobId, items[i].Value, data, ct), ct).ConfigureAwait(false);
                if (!up.Ok) throw new JobFailure("The server did not take the " + noun + " " + items[i].Value + ": " + up.Error);
                uploaded.Add(items[i].Value);
                note("uploaded " + items[i].Value + " (" + data.Length + " bytes)");
            }
            note("finished: " + uploaded.Count + " " + noun + "(s), download " + result.DownloadS.ToString("0.0", CultureInfo.InvariantCulture) + " s, run " + result.RunS.ToString("0.0", CultureInfo.InvariantCulture) + " s");
            string text = Snapshot(log);
            ApiResult done = await WithRetry(() => api.DoneAsync(jobId, uploaded, text, result.DownloadS, result.RunS, ct), ct).ConfigureAwait(false);
            result.Files = uploaded;
            result.Log = text;
            if (!done.Ok)
            {
                result.Error = "The " + noun + "s were uploaded, but the server did not accept the finished job: " + done.Error;
                note(result.Error);
                WriteLog(jobId, log);
                await FailRefusedDoneAsync(jobId, done.Error, text, result.Steps).ConfigureAwait(false);
                return result;
            }
            result.Ok = true;
            WriteLog(jobId, log);
            progress("Done: " + uploaded.Count + " " + noun + "(s) uploaded");
            return result;
        }

        /// <summary>
        /// Starts the game with <paramref name="args"/> from <paramref name="gameDir"/> (its APPDATA and LOCALAPPDATA in the job's folder) and watches it: 10 minutes at most, stopped if the player starts
        /// Death Muffin. A failure is a <see cref="JobFailure"/> in plain words: <paramref name="label"/> says which run ("Low", "the slow variant"), <paramref name="doneVerb"/> what a clean run does
        /// ("took every picture"), <paramref name="refusedText"/> (when not null) what exit code 2 means: the game refused what it was given.
        /// </summary>
        async Task RunGameAsync(List<string> args, string exeName, string label, string gameDir, string appData, string localAppData, string doneVerb, string refusedText, Action<string> note, CancellationToken ct)
        {
            var launch = new GameLaunch
            {
                ExePath = Path.Combine(gameDir, exeName),
                WorkingDir = gameDir,
                AppData = appData,
                LocalAppData = localAppData,
                Args = args,
            };
            note("start " + label + ": " + exeName + " " + CommandLineText.Join(launch.Args));
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
                        if (watch.PlayerStarted(proc.Id)) { note("counted as the player's game: " + watch.LastSeen); failure = "stopped: the game started"; break; }
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
                if (exit == 2 && refusedText != null) throw new JobFailure(refusedText);
                throw new JobFailure("The game stopped with code " + exit + " on " + label + " before it " + doneVerb + ".");
            }
        }

        // ---- The `clip` job --------------------------------------------------------------------------------------------------------

        /// <summary>
        /// A `model` job with its pictures in place: a ComfyUI server (<see cref="Comfy"/>: Desktop's when it is open, else the app's own, started now), its card checked (12 GB or more), the pictures put in
        /// its input folder, then each run in turn: the workflow filled in and queued, watched (<see cref="ModelRunLimit"/> at most, stopped if the player starts Death Muffin), the model fetched and checked
        /// and kept as `&lt;label&gt;.glb`. A run that fails is noted and the next one runs; the job fails only when no run made a model. The card's memory is freed and the job's files in ComfyUI's folders
        /// removed at the end, then the models are uploaded and the job is done.
        /// </summary>
        async Task<RunResult> RunModelAsync(string jobId, JobPlan plan, RunResult result, StringBuilder log, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            if (Comfy == null) throw new JobFailure("This PC does not run model jobs.");
            string workflowError = null;
            ComfyWorkflow workflow = Workflow ?? ComfyWorkflow.Embedded(out workflowError);
            if (workflow == null) throw new JobFailure(workflowError);
            note("workflow: " + workflow.About);
            string gameDir = folders.GameDir(jobId), outDir = folders.OutDir(jobId);
            string stem = ComfyStem(jobId);
            var models = new List<KeyValuePair<string, string>>();
            var failed = new List<string>();
            var runClock = new Stopwatch();
            CheckPlayer(0);
            try
            {
                using (ComfyHost.Lease lease = await Comfy.AcquireAsync(note, progress, ct).ConfigureAwait(false))
                {
                    try
                    {
                        ComfyStats stats = await lease.Client.StatsAsync(ct).ConfigureAwait(false);
                        if (stats == null) throw new JobFailure("ComfyUI stopped answering before the first run.");
                        note("ComfyUI " + stats.Version + " on " + (stats.Device.Length > 0 ? stats.Device : "an unnamed device") + " (" + ComfyRules.Gb(stats.VramMb) + ")");
                        if (!ComfyRules.CardFits(stats.VramMb))
                            throw new JobFailure("ComfyUI runs on a graphics card with " + ComfyRules.Gb(stats.VramMb) + " of memory; model jobs need one with 12 GB or more.");

                        var images = new Dictionary<string, string>();   // the job's picture -> its name in ComfyUI ("dmteam/<stem>-concept.png")
                        foreach (ModelRun run in plan.ModelRuns)
                        {
                            if (images.ContainsKey(run.Image)) continue;
                            ct.ThrowIfCancellationRequested();
                            byte[] data = File.ReadAllBytes(Path.Combine(gameDir, run.Image));
                            images[run.Image] = await lease.Client.UploadImageAsync(data, stem + "-" + run.Image.ToLowerInvariant(), ComfyRules.Folder, ct).ConfigureAwait(false);
                            note("picture " + run.Image + " is " + images[run.Image] + " in ComfyUI");
                        }

                        string clientId = "dmteam-" + Guid.NewGuid().ToString("N");
                        for (int i = 0; i < plan.ModelRuns.Count; i++)
                        {
                            ct.ThrowIfCancellationRequested();
                            CheckPlayer(0);
                            ModelRun run = plan.ModelRuns[i];
                            progress(plan.ModelRuns.Count > 1 ? "Making 3D model " + (i + 1) + " of " + plan.ModelRuns.Count + " (" + run.Label + ")" : "Making the 3D model");
                            note("run " + run.Label + ": " + run.Describe() + ", picture " + run.Image);
                            var clock = Stopwatch.StartNew();
                            runClock.Start();
                            try
                            {
                                byte[] glb = await ModelRunAsync(lease.Client, workflow, run, images[run.Image], ComfyRules.Folder + "/" + stem + "-" + run.Label, clientId, note, ct).ConfigureAwait(false);
                                string path = Path.Combine(outDir, run.Label + ".glb");
                                File.WriteAllBytes(path, glb);
                                models.Add(new KeyValuePair<string, string>(path, run.Label + ".glb"));
                                note("run " + run.Label + ": a model of " + (glb.Length / 1e6).ToString("0.0", CultureInfo.InvariantCulture) + " MB in " + clock.Elapsed.TotalSeconds.ToString("0", CultureInfo.InvariantCulture) + " s");
                            }
                            catch (JobStopped) { throw; }
                            catch (JobFailure jf)
                            {
                                failed.Add(run.Label);
                                note("run " + run.Label + " FAILED: " + jf.Message);
                            }
                            finally { runClock.Stop(); }
                        }
                    }
                    finally
                    {
                        await lease.Client.FreeAsync().ConfigureAwait(false);   // the models leave the card (Desktop's too: the member's game must not find it full)
                        RemoveComfyFiles(lease, stem, note);
                    }
                }
            }
            catch (JobStopped)
            {
                Comfy.PlayerPlaying();   // the app's own server goes now, so the game has the whole card
                throw;
            }
            result.RunS = runClock.Elapsed.TotalSeconds;
            if (models.Count == 0) throw new JobFailure(plan.ModelRuns.Count == 1 ? "ComfyUI made no model: the reason is in the job's log." : "None of the " + plan.ModelRuns.Count + " runs made a model: the reasons are in the job's log.");
            if (failed.Count > 0) note(failed.Count + " run(s) made no model: " + string.Join(", ", failed));
            return await UploadAndFinishAsync(jobId, models, "model", ComfyRules.MaxModelBytes, result, log, note, progress, ct).ConfigureAwait(false);
        }

        /// <summary>One run: queued, watched until it ends, its model fetched and checked. A run ComfyUI refuses or fails, or one past the time limit, is a <see cref="JobFailure"/>; the player's game, the app
        /// closing or the server's cancel stop it in ComfyUI too (so it does not keep the card busy) and end the job.</summary>
        async Task<byte[]> ModelRunAsync(ComfyClient client, ComfyWorkflow workflow, ModelRun run, string image, string prefix, string clientId, Action<string> note, CancellationToken ct)
        {
            string promptId = await client.QueueAsync(workflow.Fill(run, image, prefix), clientId, ct).ConfigureAwait(false);
            var clock = Stopwatch.StartNew();
            ComfyOutcome outcome;
            try
            {
                while (true)
                {
                    outcome = await client.ResultAsync(promptId, workflow.SaveNode, ct).ConfigureAwait(false);
                    if (outcome.Finished) break;
                    CheckPlayer(0);
                    if (clock.Elapsed > ModelRunLimit) throw new JobFailure("The run took longer than " + (int)ModelRunLimit.TotalMinutes + " minutes, so it was stopped.");
                    await Task.Delay(ComfyPollMs, ct).ConfigureAwait(false);
                }
            }
            catch (Exception)
            {
                await client.StopAsync(promptId).ConfigureAwait(false);
                throw;
            }
            if (!outcome.Ok) throw new JobFailure(outcome.Error);
            byte[] glb = await client.ViewAsync(outcome.FileName, outcome.Subfolder, outcome.Type, ct).ConfigureAwait(false);
            string bad = GlbProblem(glb);
            if (bad != null) throw new JobFailure("ComfyUI's model " + outcome.FileName + " " + bad + ".");
            return glb;
        }

        /// <summary>Why a model is not a whole binary glTF of a size the server takes (the server checks it again, fully), or null.</summary>
        internal static string GlbProblem(byte[] b)
        {
            if (b == null || b.Length < 20 || b[0] != (byte)'g' || b[1] != (byte)'l' || b[2] != (byte)'T' || b[3] != (byte)'F') return "is not a binary glTF model";
            if (BitConverter.ToUInt32(b, 8) != (uint)b.Length) return "is cut off";
            if (b.Length > ComfyRules.MaxModelBytes) return "is too big (" + Mb(b.Length) + "; the server takes " + Mb(ComfyRules.MaxModelBytes) + ")";
            return null;
        }

        /// <summary>The start of every file the job puts in ComfyUI's folders: the job's id in the letters a file name may have.</summary>
        internal static string ComfyStem(string jobId)
        {
            var sb = new StringBuilder();
            foreach (char c in jobId ?? "") if (sb.Length < 40 && (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_')) sb.Append(c);
            return sb.Length > 0 ? sb.ToString() : "job";
        }

        /// <summary>Removes the job's pictures and models from ComfyUI's input and output folders (only the files of its dmteam folder that start with the job's id). Never throws.</summary>
        static void RemoveComfyFiles(ComfyHost.Lease lease, string stem, Action<string> note)
        {
            int removed = 0;
            foreach (string root in new[] { lease.InputRoot, lease.OutputRoot })
            {
                if (string.IsNullOrEmpty(root)) continue;
                try
                {
                    string dir = Path.Combine(root, ComfyRules.Folder);
                    if (!Directory.Exists(dir)) continue;
                    foreach (string f in Directory.GetFiles(dir, stem + "-*"))
                    {
                        try { File.Delete(f); removed++; }
                        catch (IOException) { }
                        catch (UnauthorizedAccessException) { }
                    }
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            if (removed > 0) note("removed the job's " + removed + " file(s) from ComfyUI's folders");
        }

        /// <summary>
        /// A `clip` job with its files in place: one game run for each variant (its own empty folders, 1080p at the engine's `--fixed-fps 60`, the clip plan, and the variant's tune when it has one), then
        /// this PC makes each clip the game wrote into an mp4 (<paramref name="encoder"/>: ffmpeg, <see cref="Encoder"/>; the motion JPEG, about 150 MB a clip, is deleted once its video is made), the mp4s
        /// (`<variant>_<clip>.mp4`) are uploaded and the job is done (Helix 2026-10-19: 1080p at 60 frames a second).
        /// </summary>
        async Task<RunResult> RunClipsAsync(string jobId, JobPlan plan, string encoder, RunResult result, StringBuilder log, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            string gameDir = folders.GameDir(jobId), outDir = folders.OutDir(jobId), planPath = folders.PlanFile(jobId), preset = plan.Presets[0];
            File.WriteAllText(planPath, plan.PlanJson, new UTF8Encoding(false));
            var clips = new List<KeyValuePair<string, string>>();
            var usedNames = new HashSet<string>();
            var runClock = new Stopwatch();
            for (int i = 0; i < plan.Variants.Count; i++)
            {
                ct.ThrowIfCancellationRequested();
                CheckPlayer(0);
                ClipVariant variant = plan.Variants[i];
                string label = variant.Label == JobPlan.ClipLabelDefault ? "the clip run" : "the " + variant.Label + " variant";
                string appData = await FreshRunFoldersAsync(jobId, i + 1, ct).ConfigureAwait(false), localAppData = folders.LocalAppDataDir(jobId, i + 1);
                string clipsDir = Path.Combine(outDir, variant.Label);
                Directory.CreateDirectory(clipsDir);
                foreach (string old in Directory.GetFiles(clipsDir)) File.Delete(old);   // a clip left by an earlier try is not this run's
                string tuneFile = null;
                if (variant.HasTune)
                {
                    tuneFile = folders.TuneFile(jobId, variant.Label);
                    File.WriteAllText(tuneFile, variant.TuneJson, new UTF8Encoding(false));
                }
                progress(plan.Variants.Count > 1 ? "Recording clips for " + label + " (" + (i + 1) + " of " + plan.Variants.Count + ")" : "Recording clips");
                runClock.Start();
                try
                {
                    await RunGameAsync(plan.ClipCommandArgs(variant, preset, planPath, clipsDir, tuneFile, PositionFor(JobPlan.ClipWidth)), JobPlan.GameExe, label, gameDir, appData, localAppData, "recorded every clip",
                        "The game refused the clip plan or the tune for " + label + " (code 2). The log says which line.", note, ct).ConfigureAwait(false);
                }
                finally { runClock.Stop(); }
                var recorded = new List<string>(Directory.GetFiles(clipsDir, "*.mjpeg"));
                recorded.Sort(StringComparer.Ordinal);
                if (recorded.Count == 0) { AppendGodotLog(appData, note); throw new JobFailure("The game finished " + label + " but recorded no clips."); }
                foreach (string planned in plan.ClipNames)
                    if (!File.Exists(Path.Combine(clipsDir, planned + ".mjpeg"))) { AppendGodotLog(appData, note); throw new JobFailure("The game did not record the clip " + planned + " on " + label + "."); }
                note(label + ": " + recorded.Count + " clip(s)");
                for (int k = 0; k < recorded.Count; k++)
                {
                    ct.ThrowIfCancellationRequested();
                    string mjpeg = recorded[k], name = Path.GetFileNameWithoutExtension(mjpeg);
                    int fps = NoteClipInfo(mjpeg, note);
                    progress("Making the video of " + name + (recorded.Count > 1 ? " (" + (k + 1) + " of " + recorded.Count + ")" : ""));
                    runClock.Start();
                    EncodeResult made;
                    try { made = await Encoder.EncodeAsync(encoder, mjpeg, fps, Path.ChangeExtension(mjpeg, ".mp4"), ct).ConfigureAwait(false); }
                    finally { runClock.Stop(); }
                    if (!made.Ok) throw new JobFailure("The video of the clip " + name + " on " + label + " could not be made: " + made.Error);
                    note("clip " + name + ": mp4 of " + (made.Bytes / 1e6).ToString("0.0", CultureInfo.InvariantCulture) + " MB at " + fps + " fps (crf " + made.Crf + ") in " + made.Seconds.ToString("0.0", CultureInfo.InvariantCulture) + " s");
                    try { File.Delete(mjpeg); } catch (IOException) { } catch (UnauthorizedAccessException) { }   // its frames are in the mp4 now
                }
                clips.AddRange(JobPlan.Mp4UploadNames(variant.Label, Directory.GetFiles(clipsDir, "*.mp4"), usedNames));
            }
            result.RunS = runClock.Elapsed.TotalSeconds;
            if (clips.Count > JobPlan.MaxUploads) clips.RemoveRange(JobPlan.MaxUploads, clips.Count - JobPlan.MaxUploads);
            return await UploadAndFinishAsync(jobId, clips, "clip", JobPlan.MaxMp4Bytes, result, log, note, progress, ct).ConfigureAwait(false);
        }

        /// <summary>The game's note about a clip (`<name>.json`: fps, frames, size, the frame the rite was cast at) in the log, when it wrote one and it is small. Returns the clip's frames a second: the note's
        /// `fps` (a game build from before 1080p clips records 30 whatever the app asks), 30 when it says none.</summary>
        static int NoteClipInfo(string mjpegPath, Action<string> note)
        {
            int fps = 30;
            try
            {
                string info = Path.ChangeExtension(mjpegPath, ".json");
                if (File.Exists(info) && new FileInfo(info).Length <= 2048)
                {
                    string text = File.ReadAllText(info);
                    note("clip " + Path.GetFileNameWithoutExtension(mjpegPath) + ": " + text.Replace('\n', ' ').Replace('\r', ' ').Trim());
                    long? said = MiniJson.Int(MiniJson.TryObject(text), "fps");
                    if (said.HasValue && said.Value >= 1 && said.Value <= 120) fps = (int)said.Value;
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return fps;
        }

        // ---- The `release` job -----------------------------------------------------------------------------------------------------

        /// <summary>How one step of a `release` job ended: whether it worked and why not, how long it took (-1: the step's own wall time), its result file (the bytes uploaded as `<step>.json`; null: a small one the runner writes
        /// from the step's name, outcome and time), more files to upload beside it, the screens' pictures (path on disk, name on the server) and the bench step's runs.</summary>
        sealed class StepOutcome
        {
            public bool Ok = true;
            public string Error = "";
            public long Ms = -1;
            public byte[] Json;
            public List<KeyValuePair<string, byte[]>> Extra = new List<KeyValuePair<string, byte[]>>();
            public List<KeyValuePair<string, string>> Pictures = new List<KeyValuePair<string, string>>();
            public List<Dictionary<string, object>> Runs;
        }

        /// <summary>One run of the game that was watched to its end, or to its limit; a non-zero exit code is for the step to judge.</summary>
        sealed class Measured
        {
            public bool TimedOut;
            public int Exit = -1;
            public string Output = "";
            public TimeSpan Elapsed;
        }

        static byte[] Utf8(string text) { return new UTF8Encoding(false).GetBytes(text); }

        /// <summary>The window position for a game window of this width: <see cref="WindowPosition"/> when set, else the screenshots' (a 1600-wide window's).</summary>
        string PositionFor(int width)
        {
            if (WindowPosition != null) return WindowPosition(width);
            return ShotsPosition == null ? null : ShotsPosition();
        }

        /// <summary>
        /// A `release` job with its plan checked: its steps run in order (install, quit-loading, screens, stutter, bench, soak, whichever the job lists), each fetching the build it needs when it
        /// first needs it. A step that fails is a result, not the end: the next one runs. Each step's result goes to the server as `<step>.json` (and the screens' pictures) the moment the step finishes,
        /// so a PC that stops halfway still has reported what it did; at the end `done` says how each step went (and carries the bench step's runs). The player starting Death Muffin, the app
        /// closing or a server cancel stop the whole job; a server that will not take a file fails it.
        /// </summary>
        async Task<RunResult> RunReleaseAsync(string jobId, JobPlan plan, Fetched fetched, RunResult result, StringBuilder log, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            var steps = new List<StepReport>();
            result.Steps = steps;   // (a job that stops halfway tells the server these)
            var uploaded = new List<string>();
            var runs = new List<Dictionary<string, object>>();
            var no = new RunNumbers();
            string planPath = null;
            if (plan.HasStep("screens"))
            {
                planPath = folders.PlanFile(jobId);
                File.WriteAllText(planPath, plan.PlanJson, new UTF8Encoding(false));
            }
            double stepsSeconds = 0;
            for (int i = 0; i < plan.Steps.Count; i++)
            {
                string step = plan.Steps[i];
                ct.ThrowIfCancellationRequested();
                if (step == "bench" && BenchmarksAllowed != null && !BenchmarksAllowed())
                {
                    note("step bench skipped: benchmarks are off on this PC");
                    steps.Add(new StepReport { Step = step, Ok = true, Skipped = true, Error = BenchSkipped });
                    continue;
                }
                CheckPlayer(0);
                progress("Release checks, step " + (i + 1) + " of " + plan.Steps.Count + ": " + step);
                note("step " + step + " begins");
                var clock = Stopwatch.StartNew();
                StepOutcome o;
                try { o = await RunStepAsync(step, jobId, plan, fetched, no, planPath, result, note, progress, ct).ConfigureAwait(false); }
                catch (JobStopped) { throw; }
                catch (JobFailure jf) { o = new StepOutcome { Ok = false, Error = jf.Message }; }
                if (o.Ms < 0) o.Ms = (long)clock.ElapsedMilliseconds;
                stepsSeconds += clock.Elapsed.TotalSeconds;
                note("step " + step + (o.Ok ? " passed" : " FAILED: " + o.Error) + " (" + (o.Ms / 1000.0).ToString("0.0", CultureInfo.InvariantCulture) + " s)");

                // the step's pictures, its other files and its result, now (not at the end)
                int shown = 0, refused = 0;
                foreach (var pic in o.Pictures)
                {
                    ct.ThrowIfCancellationRequested();
                    progress("Uploading " + step + " pictures (" + (++shown) + " of " + o.Pictures.Count + ")");
                    try
                    {
                        await UploadOneAsync(jobId, pic.Value, File.ReadAllBytes(pic.Key), "picture", JobPlan.MaxUploadBytes, note, ct).ConfigureAwait(false);
                        uploaded.Add(pic.Value);
                    }
                    catch (JobStopped) { throw; }
                    catch (JobFailure jf)
                    {
                        // a picture too big or refused fails its step, not the job: the next steps still run (Helix's 3840x2160 fight picture, 2026-10-19)
                        note(jf.Message);
                        if (refused++ == 0) { o.Error = o.Ok ? jf.Message : o.Error + " " + jf.Message; o.Ok = false; }
                    }
                }
                if (refused > 1) o.Error += " (" + refused + " pictures were not sent)";
                foreach (var extra in o.Extra)
                {
                    await UploadOneAsync(jobId, extra.Key, extra.Value, "result", MaxStepResultBytes, note, ct).ConfigureAwait(false);
                    uploaded.Add(extra.Key);
                }
                byte[] json = o.Json ?? Utf8(MiniJson.Write(new Dictionary<string, object> { { "step", step }, { "ok", o.Ok }, { "error", o.Error }, { "ms", o.Ms } }));
                await UploadOneAsync(jobId, step + ".json", json, "result", MaxStepResultBytes, note, ct).ConfigureAwait(false);
                uploaded.Add(step + ".json");
                steps.Add(new StepReport { Step = step, Ok = o.Ok, Error = o.Error, Ms = o.Ms });
                if (o.Runs != null) runs.AddRange(o.Runs);
            }
            folders.PruneCache(TeamLogic.KeepCacheKeys, fetched.UsedKeys);
            result.RunS = stepsSeconds;
            int passed = 0;
            foreach (StepReport r in steps) if (r.Ok) passed++;
            note("finished: " + passed + " of " + steps.Count + " step(s) passed, " + uploaded.Count + " file(s) uploaded, download " + result.DownloadS.ToString("0.0", CultureInfo.InvariantCulture) + " s, run " + result.RunS.ToString("0.0", CultureInfo.InvariantCulture) + " s");
            string text = Snapshot(log);
            ct.ThrowIfCancellationRequested();
            ApiResult done = await WithRetry(() => api.DoneReleaseAsync(jobId, steps, uploaded, runs, text, result.DownloadS, result.RunS, ct), ct).ConfigureAwait(false);
            result.Files = uploaded;
            result.Runs = runs.Count;
            result.Log = text;
            if (!done.Ok)
            {
                result.Error = "The checks ran, but the server did not accept the finished job: " + done.Error;
                note(result.Error);
                WriteLog(jobId, log);
                await FailRefusedDoneAsync(jobId, done.Error, text, steps).ConfigureAwait(false);
                return result;
            }
            result.Ok = true;
            WriteLog(jobId, log);
            progress("Done: " + passed + " of " + steps.Count + " release check step(s) passed");
            return result;
        }

        /// <summary>A step's result file (the server takes up to 1 MB).</summary>
        public const int MaxStepResultBytes = 1024 * 1024;

        /// <summary>Uploads one file of a release job (a picture or a step's result); a file that is empty or too big, or one the server will not take, is a <see cref="JobFailure"/> that fails the job.</summary>
        async Task UploadOneAsync(string jobId, string name, byte[] data, string noun, long maxBytes, Action<string> note, CancellationToken ct)
        {
            if (data.Length == 0 || data.Length > maxBytes) throw new JobFailure("The " + noun + " " + name + " is " + (data.Length == 0 ? "empty" : "too big (" + Mb(data.Length) + ")") + ".");
            ApiResult up = await WithRetry(() => api.UploadAsync(jobId, name, data, ct), ct).ConfigureAwait(false);
            if (!up.Ok) throw new JobFailure("The server did not take the " + noun + " " + name + ": " + up.Error);
            note("uploaded " + name + " (" + data.Length + " bytes)");
        }

        async Task<StepOutcome> RunStepAsync(string step, string jobId, JobPlan plan, Fetched fetched, RunNumbers no, string planPath, RunResult result, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            switch (step)
            {
                case "install": return await StepBootAsync("install", false, jobId, plan, fetched, no, result, note, progress, ct).ConfigureAwait(false);
                case "quit-loading": return await StepBootAsync("quit-loading", true, jobId, plan, fetched, no, result, note, progress, ct).ConfigureAwait(false);
                case "screens": return await StepScreensAsync(jobId, plan, fetched, no, planPath, result, note, progress, ct).ConfigureAwait(false);
                case "stutter": return await StepScenarioAsync("stutter", jobId, plan, fetched, no, result, note, progress, ct).ConfigureAwait(false);
                case "bench": return await StepBenchAsync(jobId, plan, fetched, no, result, note, progress, ct).ConfigureAwait(false);
                case "soak": return await StepSoakAsync(jobId, plan, fetched, no, result, note, progress, ct).ConfigureAwait(false);
                default: throw new JobFailure("This app does not know the step " + step + ".");
            }
        }

        /// <summary>The build's files are in place: fetched now when no step has needed it yet. A download that fails is the failure of every step that needs that build (it is tried once).</summary>
        async Task<string> EnsureBuildAsync(string jobId, JobPlan plan, Fetched fetched, string label, RunResult result, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            string why;
            if (fetched.Failed.TryGetValue(label, out why)) throw new JobFailure(why);
            if (!fetched.Done.Contains(label))
            {
                var clock = Stopwatch.StartNew();
                try { await FetchBuildAsync(jobId, plan, plan.BuildNamed(label), fetched, note, progress, ct).ConfigureAwait(false); }
                catch (JobStopped) { throw; }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception ex)
                {
                    string text = ex is JobFailure ? ex.Message : "The " + label + " build could not be downloaded: " + ex.Message;
                    fetched.Failed[label] = text;
                    throw new JobFailure(text);
                }
                finally { result.DownloadS += clock.Elapsed.TotalSeconds; }
            }
            return folders.GameDir(jobId, label);
        }

        /// <summary>`install` and `quit-loading`: the RELEASE exe started as `-- --boot-check` (and `--quit-while-loading`) from its own fresh folders, below normal priority, window outside every monitor.</summary>
        async Task<StepOutcome> StepBootAsync(string step, bool quitWhileLoading, string jobId, JobPlan plan, Fetched fetched, RunNumbers no, RunResult result, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            double before = result.DownloadS;
            string gameDir = await EnsureBuildAsync(jobId, plan, fetched, JobPlan.ReleaseBuild, result, note, progress, ct).ConfigureAwait(false);
            double downloadS = result.DownloadS - before;
            no.N++;
            string appData = await FreshRunFoldersAsync(jobId, no.N, ct).ConfigureAwait(false), localAppData = folders.LocalAppDataDir(jobId, no.N);
            var launch = new GameLaunch
            {
                ExePath = Path.Combine(gameDir, JobPlan.BenchExe), WorkingDir = gameDir, AppData = appData, LocalAppData = localAppData,
                Args = JobPlan.BootCheckArgs(quitWhileLoading, PositionFor(1600)), Priority = ProcessPriorityClass.BelowNormal,
            };
            TimeSpan limit = quitWhileLoading ? QuitLimit : BootLimit;
            progress(quitWhileLoading ? "Release check: the game quits while loading" : "Release check: the game starts");
            Measured m = await RunMeasuredAsync(launch, step, limit, note, ct, null).ConfigureAwait(false);
            var o = new StepOutcome { Ms = (long)m.Elapsed.TotalMilliseconds };
            var json = new Dictionary<string, object> { { "step", step }, { "exitCode", m.TimedOut ? (object)null : m.Exit }, { "seconds", Math.Round(m.Elapsed.TotalSeconds, 1) }, { "timedOut", m.TimedOut } };
            if (!quitWhileLoading)
            {
                long? boot = JobPlan.ParseBootMs(m.Output);
                json["downloadS"] = Math.Round(downloadS, 1);
                if (boot.HasValue) { json["bootMs"] = boot.Value; o.Ms = boot.Value; }
                if (m.TimedOut) Fail(o, "The game did not reach its first screen within " + Limit(limit) + " and was stopped.");
                else if (m.Exit != 0) Fail(o, "The game stopped with code " + m.Exit + " before its first screen.");
                else if (!boot.HasValue) Fail(o, "The game quit with code 0 but never said BOOT OK.");
                var files = new List<object>();
                foreach (PlanFile f in plan.BuildNamed(JobPlan.ReleaseBuild).Files) files.Add(new Dictionary<string, object> { { "name", f.Name }, { "bytes", f.Bytes } });
                json["files"] = files;
            }
            else
            {
                var markers = CrashMarkers(appData);
                json["crashReport"] = markers.Count > 0;
                json["crashFiles"] = markers;
                if (m.TimedOut) Fail(o, "The game did not quit by itself within " + Limit(limit) + " (it was stopped).");
                else if (m.Exit != 0) Fail(o, "The game quit with code " + m.Exit + " while loading.");
                else if (markers.Count > 0) Fail(o, "The game quit but left a crash report (" + string.Join(", ", markers) + ").");
            }
            if (!o.Ok) AppendGodotLog(appData, note);
            string tail = TextClip.Tail(m.Output, 1500);
            if (tail.Length > 0) json["output"] = tail;
            json["ok"] = o.Ok;
            if (!o.Ok) json["error"] = o.Error;
            o.Json = Utf8(MiniJson.Write(json));
            return o;
        }

        static void Fail(StepOutcome o, string error) { if (o.Ok) { o.Ok = false; o.Error = error; } }

        /// <summary>The files DmCrashWatch leaves when a release run does not shut down normally (`session.lock` stays, `crash_pending.json` and `core_crash_note.txt` are written at the next start or while crashing): the names found anywhere under the run's APPDATA.</summary>
        static List<object> CrashMarkers(string appData)
        {
            var found = new List<object>();
            foreach (string name in new[] { "session.lock", "crash_pending.json", "core_crash_note.txt" })
            {
                try { if (Directory.GetFiles(appData, name, SearchOption.AllDirectories).Length > 0) found.Add(name); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            return found;
        }

        /// <summary>
        /// `screens`: the debug build takes the standard shots at each window size, at the default UI scale and at each scale the job names (`--ui-scale=`), outside every monitor and silent. A run that fails does
        /// not stop the next; the pictures are uploaded as `&lt;WxH&gt;[_s&lt;scale&gt;]_&lt;shot&gt;.png`. A picture whose size is not the size asked for (Windows held the window to the screen) is reported.
        /// </summary>
        async Task<StepOutcome> StepScreensAsync(string jobId, JobPlan plan, Fetched fetched, RunNumbers no, string planPath, RunResult result, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            string gameDir = await EnsureBuildAsync(jobId, plan, fetched, JobPlan.DebugBuild, result, note, progress, ct).ConfigureAwait(false);
            var scales = new List<string> { "" };
            scales.AddRange(plan.UiScales);
            int runTotal = plan.ScreenSizes.Count * scales.Count;
            var o = new StepOutcome();
            var runsJson = new List<object>();
            var errors = new List<string>();
            var groups = new List<List<KeyValuePair<string, string>>>();
            var usedNames = new HashSet<string>();
            int runNo = 0;
            foreach (ScreenSize size in plan.ScreenSizes)
                foreach (string scale in scales)
                {
                    ct.ThrowIfCancellationRequested();
                    CheckPlayer(0);
                    runNo++;
                    string tag = JobPlan.ScreensTag(size, scale);
                    string where = "screens at " + tag.Replace("_s", ", UI scale ").Replace("-", ".");
                    no.N++;
                    string appData = await FreshRunFoldersAsync(jobId, no.N, ct).ConfigureAwait(false), localAppData = folders.LocalAppDataDir(jobId, no.N);
                    string dir = Path.Combine(folders.OutDir(jobId), "screens", tag);
                    Directory.CreateDirectory(dir);
                    foreach (string old in Directory.GetFiles(dir, "*.png")) File.Delete(old);
                    progress("Release check: " + where + " (" + runNo + " of " + runTotal + ")");
                    var launch = new GameLaunch
                    {
                        ExePath = Path.Combine(gameDir, JobPlan.GameExe), WorkingDir = gameDir, AppData = appData, LocalAppData = localAppData,
                        Args = plan.ScreensCommandArgs(size, scale, planPath, dir, PositionFor(size.Width)), Priority = ProcessPriorityClass.BelowNormal,
                    };
                    var entry = new Dictionary<string, object> { { "size", size.Text }, { "uiScale", scale.Length == 0 ? "default" : scale } };
                    string runError = "";
                    var found = new List<KeyValuePair<string, string>>();
                    try
                    {
                        Measured m = await RunMeasuredAsync(launch, where, RunLimit, note, ct, null).ConfigureAwait(false);
                        entry["exitCode"] = m.TimedOut ? (object)null : m.Exit;
                        entry["seconds"] = Math.Round(m.Elapsed.TotalSeconds, 1);
                        found = JobPlan.UploadNames(tag, Directory.GetFiles(dir, "*.png"), usedNames);
                        if (m.TimedOut) runError = "The game took longer than " + Limit(RunLimit) + " " + where + " and was stopped.";
                        else if (m.Exit != 0) runError = "The game stopped with code " + m.Exit + " " + where + ".";
                        else if (found.Count == 0) runError = "The game finished " + where + " but made no pictures.";
                        if (runError.Length > 0) AppendGodotLog(appData, note);
                        string wrong = "";
                        foreach (var pic in found)
                        {
                            string have = PngSize(pic.Key);
                            if (have != null && have != size.Text) { wrong = have; break; }
                        }
                        if (wrong.Length > 0)
                        {
                            entry["pictureSize"] = wrong;
                            if (runError.Length == 0) runError = "The pictures " + where + " are " + wrong + ", not " + size.Text + " (Windows held the window to the screen).";
                        }
                    }
                    catch (JobStopped) { throw; }
                    catch (JobFailure jf) { runError = jf.Message; }
                    var names = new List<object>();
                    foreach (var f in found) names.Add(f.Value);
                    entry["shots"] = names;
                    entry["ok"] = runError.Length == 0;
                    if (runError.Length > 0) { entry["error"] = runError; errors.Add(runError); }
                    runsJson.Add(entry);
                    note(where + ": " + found.Count + " picture(s)" + (runError.Length > 0 ? ", " + runError : ""));
                    groups.Add(found);
                }
            int all = 0;
            foreach (var g in groups) all += g.Count;
            if (all > JobPlan.MaxReleaseUploads)
            {
                int each = Math.Max(1, JobPlan.MaxReleaseUploads / groups.Count);
                note("more than " + JobPlan.MaxReleaseUploads + " pictures: only the first " + each + " of each window size and UI scale are sent");
                foreach (var g in groups) if (g.Count > each) g.RemoveRange(each, g.Count - each);
            }
            foreach (var g in groups) o.Pictures.AddRange(g);
            if (o.Pictures.Count > JobPlan.MaxReleaseUploads) o.Pictures.RemoveRange(JobPlan.MaxReleaseUploads, o.Pictures.Count - JobPlan.MaxReleaseUploads);
            if (errors.Count > 0) Fail(o, errors.Count == 1 ? errors[0] : errors[0] + " (and " + (errors.Count - 1) + " more run(s) went wrong)");
            var json = new Dictionary<string, object> { { "step", "screens" }, { "ok", o.Ok }, { "preset", plan.ScreensPreset }, { "runs", runsJson } };
            var scaleNames = new List<object> { "default" };
            foreach (string sc in plan.UiScales) scaleNames.Add(sc);
            json["uiScales"] = scaleNames;
            if (plan.UiScales.Count == 0) json["note"] = "default UI scale only: the job names no other UI scale";
            if (!o.Ok) json["error"] = o.Error;
            o.Json = Utf8(MiniJson.Write(json));
            return o;
        }

        /// <summary>"1920x1080" from a PNG's header, or null when the file is not a PNG that can be read.</summary>
        static string PngSize(string path)
        {
            try
            {
                using (var fs = File.OpenRead(path))
                {
                    var b = new byte[24];
                    if (fs.Read(b, 0, 24) < 24 || b[0] != 0x89 || b[1] != 0x50 || b[2] != 0x4E || b[3] != 0x47) return null;
                    long w = ((long)b[16] << 24) | ((long)b[17] << 16) | ((long)b[18] << 8) | b[19], h = ((long)b[20] << 24) | ((long)b[21] << 16) | ((long)b[22] << 8) | b[23];
                    return w.ToString(CultureInfo.InvariantCulture) + "x" + h.ToString(CultureInfo.InvariantCulture);
                }
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }

        /// <summary>The JSON a QA scenario wrote into its folder: `&lt;step&gt;.json` when there, else the first `*.json`; its bytes as the game wrote them, or null when there is none or it is not JSON or is too big.</summary>
        static byte[] ReadScenarioJson(string dir, string step, out string problem)
        {
            problem = "";
            string file = Path.Combine(dir, step + ".json");
            if (!File.Exists(file))
            {
                string[] any = Directory.Exists(dir) ? Directory.GetFiles(dir, "*.json") : new string[0];
                Array.Sort(any, StringComparer.Ordinal);
                if (any.Length == 0) { problem = "The game left no result file."; return null; }
                file = any[0];
            }
            try
            {
                byte[] bytes = File.ReadAllBytes(file);
                if (bytes.Length > MaxStepResultBytes) { problem = "The game's result file is too big to send (" + Mb(bytes.Length) + ")."; return null; }
                MiniJson.Parse(Encoding.UTF8.GetString(bytes));
                return bytes;
            }
            catch (FormatException) { problem = "The game's result file is not JSON."; return null; }
            catch (IOException) { problem = "The game's result file could not be read."; return null; }
            catch (UnauthorizedAccessException) { problem = "The game's result file could not be read."; return null; }
        }

        /// <summary>`stutter`: the debug build's QA scenario `--stutter` (one game run, below normal priority, up to <see cref="StutterLimit"/>); the JSON it writes is uploaded as it is.</summary>
        async Task<StepOutcome> StepScenarioAsync(string step, string jobId, JobPlan plan, Fetched fetched, RunNumbers no, RunResult result, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            string gameDir = await EnsureBuildAsync(jobId, plan, fetched, JobPlan.DebugBuild, result, note, progress, ct).ConfigureAwait(false);
            no.N++;
            string appData = await FreshRunFoldersAsync(jobId, no.N, ct).ConfigureAwait(false), localAppData = folders.LocalAppDataDir(jobId, no.N);
            string dir = Path.Combine(folders.OutDir(jobId), step);
            await ResetDirAsync(dir, ct).ConfigureAwait(false);
            var launch = new GameLaunch
            {
                ExePath = Path.Combine(gameDir, JobPlan.GameExe), WorkingDir = gameDir, AppData = appData, LocalAppData = localAppData,
                Args = plan.StutterCommandArgs(dir, PositionFor(1600)), Priority = ProcessPriorityClass.BelowNormal,
            };
            progress("Release check: the stutter test");
            Measured m = await RunMeasuredAsync(launch, "the stutter test", StutterLimit, note, ct, null).ConfigureAwait(false);
            var o = new StepOutcome { Ms = (long)m.Elapsed.TotalMilliseconds };
            string problem;
            o.Json = ReadScenarioJson(dir, step, out problem);
            if (m.TimedOut) Fail(o, "The game took longer than " + Limit(StutterLimit) + " on the stutter test and was stopped.");
            else if (m.Exit != 0) Fail(o, "The game stopped with code " + m.Exit + " on the stutter test.");
            else if (o.Json == null) Fail(o, problem);
            if (!o.Ok) AppendGodotLog(appData, note);
            return o;
        }

        /// <summary>`bench`: the benchmark setups on the RELEASE build at normal priority, each after the PC has been quiet for a minute and thrown away and retried when the PC is touched (<see cref="CollectBenchRunsAsync"/>); the runs go to the server in `done`.</summary>
        async Task<StepOutcome> StepBenchAsync(string jobId, JobPlan plan, Fetched fetched, RunNumbers no, RunResult result, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            string gameDir = await EnsureBuildAsync(jobId, plan, fetched, JobPlan.ReleaseBuild, result, note, progress, ct).ConfigureAwait(false);
            var clock = new Stopwatch();
            var runs = await CollectBenchRunsAsync(jobId, plan, gameDir, QuietDeadline(plan), no, clock, note, progress, ct).ConfigureAwait(false);
            var o = new StepOutcome { Runs = runs, Ms = (long)clock.ElapsedMilliseconds };
            if (closeCrashes.Count > 0)
            {
                o.Ok = false;   // the numbers count, the crash is the release's own failure
                o.Error = "The game crashed while closing after the benchmark (" + string.Join("; ", closeCrashes) + "); its numbers were sent.";
            }
            var summary = new List<object>();
            for (int ri = 0; ri < runs.Count; ri++)
            {
                var run = runs[ri];
                var metrics = MiniJson.Obj(run, "metrics");
                var row = new Dictionary<string, object> { { "preset", MiniJson.Str(run, "preset") }, { "room", MiniJson.Str(run, "room") }, { "size", MiniJson.Str(run, "size") }, { "length", MiniJson.Str(run, "length") }, { "gpu", MiniJson.Str(run, "gpu") } };
                foreach (string key in new[] { "avg_fps", "p95_ms", "p99_ms", "worst_ms", "hitches", "draw_calls" })
                {
                    object v;
                    if (metrics != null && metrics.TryGetValue(key, out v) && v is double) row[key] = v;
                }
                if (ri < darkReadings.Count && darkReadings[ri] > 0) row["screenOffS"] = (double)darkReadings[ri];   // readings are a second apart
                summary.Add(row);
            }
            var crashes = new List<object>(closeCrashes);
            string text = MiniJson.Write(new Dictionary<string, object> { { "step", "bench" }, { "ok", o.Ok }, { "error", o.Error }, { "crashes", crashes }, { "summary", summary }, { "runs", runs } });
            if (Encoding.UTF8.GetByteCount(text) > MaxStepResultBytes) text = MiniJson.Write(new Dictionary<string, object> { { "step", "bench" }, { "ok", o.Ok }, { "error", o.Error }, { "crashes", crashes }, { "summary", summary } });
            o.Json = Utf8(text);
            return o;
        }

        /// <summary>When a quiet-PC wait of a release step gives up: the job's life ends, or <see cref="ReleaseQuietLimit"/> from now, whichever is first (a step that never gets its quiet minute is a failed step, and the next one runs).</summary>
        DateTime QuietDeadline(JobPlan plan)
        {
            DateTime limit = DateTime.UtcNow + ReleaseQuietLimit;
            return plan.ExpiresAtUtc.HasValue && plan.ExpiresAtUtc.Value < limit ? plan.ExpiresAtUtc.Value : limit;
        }

        /// <summary>
        /// `soak`: the debug build's QA scenario `--soak=&lt;minutes&gt;`, after the PC has been quiet for a minute, at NORMAL priority. The PC is read once a second while it runs, but nothing that happens to
        /// the PC throws the run out (unlike a benchmark): a key or the mouse touched, other programs using the CPU, the battery are noted in `soak-notes.json`; the player starting Death Muffin stops the job.
        /// </summary>
        async Task<StepOutcome> StepSoakAsync(string jobId, JobPlan plan, Fetched fetched, RunNumbers no, RunResult result, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            string gameDir = await EnsureBuildAsync(jobId, plan, fetched, JobPlan.DebugBuild, result, note, progress, ct).ConfigureAwait(false);
            await WaitQuietAsync(QuietDeadline(plan), note, progress, ct).ConfigureAwait(false);
            no.N++;
            string appData = await FreshRunFoldersAsync(jobId, no.N, ct).ConfigureAwait(false), localAppData = folders.LocalAppDataDir(jobId, no.N);
            string dir = Path.Combine(folders.OutDir(jobId), "soak");
            await ResetDirAsync(dir, ct).ConfigureAwait(false);
            var launch = new GameLaunch
            {
                ExePath = Path.Combine(gameDir, JobPlan.GameExe), WorkingDir = gameDir, AppData = appData, LocalAppData = localAppData,
                Args = plan.SoakCommandArgs(dir, PositionFor(1600)), Priority = ProcessPriorityClass.Normal,
            };
            progress("Release check: the soak test (" + plan.SoakMinutes + " minutes)");
            TimeSpan runStart = probe.Read(0).At;
            var samples = new List<PcSample>();
            var notes = new List<object>();
            var seenReasons = new HashSet<string>();
            int touches = 0;
            TimeSpan lastInput = TimeSpan.MinValue;
            Action<PcSample> onSample = s =>
            {
                samples.Add(s);
                while (samples.Count > 120) samples.RemoveAt(0);
                int minute = (int)Math.Max(0, (s.At - runStart).TotalMinutes);
                TimeSpan input = s.At - TimeSpan.FromSeconds(s.IdleS);
                if (input > runStart + TimeSpan.FromSeconds(1) && input > lastInput + TimeSpan.FromSeconds(2))   // (a second's slack: the two clocks are not the same clock)
                {
                    lastInput = input;
                    touches++;
                    if (touches <= 10) notes.Add("minute " + minute + ": the keyboard or mouse was used");
                }
                string why = Quiet.Disturbance(samples, runStart, Rules);
                if (why.Length > 0 && seenReasons.Add(why) && notes.Count < 30) notes.Add("minute " + minute + ": " + why);
            };
            TimeSpan limit = TimeSpan.FromMinutes(plan.SoakMinutes) + SoakSlack;
            Measured m = await RunMeasuredAsync(launch, "the soak test", limit, note, ct, onSample).ConfigureAwait(false);
            var o = new StepOutcome { Ms = (long)m.Elapsed.TotalMilliseconds };
            string problem;
            o.Json = ReadScenarioJson(dir, "soak", out problem);
            if (m.TimedOut) Fail(o, "The game took longer than " + Limit(limit) + " on the soak test and was stopped.");
            else if (m.Exit != 0) Fail(o, "The game stopped with code " + m.Exit + " on the soak test.");
            else if (o.Json == null) Fail(o, problem);
            if (!o.Ok) AppendGodotLog(appData, note);
            if (touches > 10) notes.Add("the keyboard or mouse was used " + touches + " times in all");
            foreach (object n in notes) note("soak: " + n);
            if (notes.Count > 0)
                o.Extra.Add(new KeyValuePair<string, byte[]>("soak-notes.json", Utf8(MiniJson.Write(new Dictionary<string, object> { { "step", "soak" }, { "minutes", plan.SoakMinutes }, { "notes", notes } }))));
            return o;
        }

        /// <summary>The game run, watched to its end or its limit, with its output and exit code. The player starting Death Muffin stops the job (<see cref="JobStopped"/>); a cancel or the app closing throws as ever; anything else is the step's to judge.</summary>
        async Task<Measured> RunMeasuredAsync(GameLaunch launch, string label, TimeSpan limit, Action<string> note, CancellationToken ct, Action<PcSample> onSample)
        {
            note("start " + label + ": " + Path.GetFileName(launch.ExePath) + " " + CommandLineText.Join(launch.Args));
            IGameProcess proc;
            try { proc = host.Start(launch); }
            catch (Exception ex) { throw new JobFailure("The game could not be started for " + label + ": " + ex.Message); }
            var m = new Measured();
            bool playerStarted = false;
            using (proc)
            {
                var sw = Stopwatch.StartNew();
                var sampleClock = Stopwatch.StartNew();
                try
                {
                    while (!proc.HasExited)
                    {
                        if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
                        if (watch.PlayerStarted(proc.Id)) { playerStarted = true; break; }
                        if (onSample != null && sampleClock.ElapsedMilliseconds >= SampleMs) { sampleClock.Restart(); onSample(probe.Read(proc.Id)); }
                        if (sw.Elapsed > limit) { m.TimedOut = true; break; }
                        proc.Tend();
                        await Task.Delay(PollMs, ct).ConfigureAwait(false);
                    }
                }
                finally
                {
                    if (!proc.HasExited) proc.Kill();
                }
                m.Elapsed = sw.Elapsed;
                if (!playerStarted && !m.TimedOut) m.Exit = proc.ExitCode;
                m.Output = proc.Output();
                if (m.Output.Length > 0) note("game output (" + label + "):\n" + TextClip.Tail(m.Output, 16000));
                note(label + ": the game ran " + m.Elapsed.TotalSeconds.ToString("0.0", CultureInfo.InvariantCulture) + " s" + (playerStarted ? ", stopped: the game started" : m.TimedOut ? ", over its limit" : ", exit code " + m.Exit));
            }
            if (playerStarted) { note("counted as the player's game: " + watch.LastSeen); throw new JobStopped("stopped: the game started"); }
            return m;
        }

        // ---- The `bench` job -------------------------------------------------------------------------------------------------------

        /// <summary>
        /// A `bench` job with its files in place: for each setup wait until the PC is quiet, run the game's benchmark (a trial in the setup's own `bench-n` folder that sends nothing),
        /// and read the run it queued. A run during which the PC was touched is thrown away with its folder, and the setup starts over once the PC is quiet again (at most
        /// <see cref="BenchTries"/> tries); then done with every run.
        /// </summary>
        async Task<RunResult> RunBenchAsync(string jobId, JobPlan plan, RunResult result, StringBuilder log, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            DateTime deadline = plan.ExpiresAtUtc ?? DateTime.UtcNow + QuietWaitLimit;
            var runClock = new Stopwatch();
            var runs = await CollectBenchRunsAsync(jobId, plan, folders.GameDir(jobId), deadline, new RunNumbers(), runClock, note, progress, ct).ConfigureAwait(false);
            if (closeCrashes.Count > 0) note("the game crashed while closing after the benchmark (" + string.Join("; ", closeCrashes) + "); its numbers are sent");
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
                await FailRefusedDoneAsync(jobId, done.Error, text, null).ConfigureAwait(false);
                return result;
            }
            result.Ok = true;
            WriteLog(jobId, log);
            progress("Done: " + runs.Count + " benchmark run(s) sent");
            return result;
        }

        /// <summary>The number of the next run of the game in a job (each gets its own folders): shared by the steps of a `release` job.</summary>
        sealed class RunNumbers { public int N; }

        /// <summary>
        /// The benchmark runs of a plan's setups: for each setup wait until the PC is quiet, run the game's benchmark (a trial in the setup's own `bench-n` folder that sends nothing) and read the run it
        /// queued. A run during which the PC was touched is thrown away with its folder, and the setup starts over once the PC is quiet again (at most <see cref="BenchTries"/> tries); a setup that fails fails
        /// the lot (a <see cref="JobFailure"/>) and nothing is returned.
        /// </summary>
        async Task<List<Dictionary<string, object>>> CollectBenchRunsAsync(string jobId, JobPlan plan, string gameDir, DateTime deadline, RunNumbers runNo, Stopwatch runClock, Action<string> note, Action<string> progress, CancellationToken ct)
        {
            var runs = new List<Dictionary<string, object>>();
            closeCrashes.Clear();
            darkReadings.Clear();
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
                    runNo.N++;
                    string appData = await FreshRunFoldersAsync(jobId, runNo.N, ct).ConfigureAwait(false), localAppData = folders.LocalAppDataDir(jobId, runNo.N);
                    progress("Benchmark on " + where + (attempt > 1 ? ", try " + attempt + " of " + BenchTries : ""));
                    string disturbed;
                    runClock.Start();
                    try { disturbed = await RunBenchGameAsync(plan, setup, label, benchDir, gameDir, appData, localAppData, note, ct).ConfigureAwait(false); }
                    finally { runClock.Stop(); }
                    if (disturbed.Length == 0) break;
                    note(label + ": the run was disturbed (" + disturbed + ") and thrown away" + (disturbed.Contains("Death Muffin") && watch.LastSeen.Length > 0 ? " [counted as the player's game: " + watch.LastSeen + "]" : ""));
                    await ResetDirAsync(benchDir, ct).ConfigureAwait(false);
                    if (attempt >= BenchTries)
                        throw new JobFailure("The benchmark on " + label + " was disturbed " + BenchTries + " times (" + disturbed + "), so no numbers were sent. Keep other programs and Death Muffin closed while it runs.");
                }
                Dictionary<string, object> run;
                string err;
                if (!JobPlan.TryReadBenchRun(benchDir, label, out run, out err)) { AppendGodotLog(folders.AppDataDir(jobId, runNo.N), note); throw new JobFailure(err); }
                note(label + ": the run was recorded (" + MiniJson.Write(run).Length + " bytes of JSON)");
                runs.Add(run);
                darkReadings.Add(lastRunDarkReadings);
            }
            return runs;
        }

        /// <summary>
        /// The server did not accept a finished job: tell it the job failed, with the server's own reason, so the job never stays running (this PC's heartbeat would keep it alive for ever). Best effort: it never
        /// throws, and a server that cannot be reached is no worse off than before.
        /// </summary>
        async Task FailRefusedDoneAsync(string jobId, string reason, string log, IList<StepReport> steps)
        {
            try
            {
                using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
                    await api.FailAsync(jobId, string.IsNullOrEmpty(reason) ? "The server did not accept the finished job." : reason, log, steps, cts.Token).ConfigureAwait(false);
            }
            catch (Exception) { /* the server's sweep puts the job back or fails it when this PC goes quiet */ }
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
            int exit = 0, gamePid = proc.Id;
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
                int dark = 0;
                foreach (PcSample s in samples) { others += s.CpuOthers; if (s.DisplayOff) dark++; }
                lastRunDarkReadings = dark;
                note(label + ": the game ran " + sw.Elapsed.TotalSeconds.ToString("0.0", CultureInfo.InvariantCulture) + " s" + (failure == null && disturbed.Length == 0 ? ", exit code " + exit : ", stopped")
                    + (samples.Count > 0 ? "; other programs used about " + ((int)Math.Round(others / samples.Count)).ToString(CultureInfo.InvariantCulture) + "% of the CPU (" + samples.Count + " readings)" : "")
                    + (dark > 0 ? "; the screen was off for " + dark + " of them" : ""));
            }
            if (disturbed.Length > 0) return disturbed;
            if (failure != null) { AppendGodotLog(appData, note); throw new JobFailure(failure); }
            if (exit < 0)
            {
                // a Windows crash code: what Windows recorded, and whether the run's numbers were saved before it (Helix's PC, 2026-10-19: the release build crashed while
                // closing after a finished benchmark, 0xC0000374)
                string why = CrashText(exit, CrashRecord(gamePid));
                note(label + ": the game crashed (" + why + ")");
                Dictionary<string, object> saved;
                string unread;
                if (JobPlan.TryReadBenchRun(benchDir, label, out saved, out unread)) { closeCrashes.Add(label + ": " + why); return ""; }
                AppendGodotLog(appData, note);
                throw new JobFailure("The game crashed on " + label + " (" + why + ") before the benchmark was done.");
            }
            if (exit != 0) { AppendGodotLog(appData, note); throw new JobFailure(BenchExitText(exit, label)); }
            return "";
        }

        /// <summary>Benchmark runs of this job whose numbers were saved and then the game crashed (while closing): the runs are sent, the crash is reported beside them.</summary>
        readonly List<string> closeCrashes = new List<string>();
        /// <summary>For each recorded benchmark run of this job, how many of its once-a-second readings found the PC's screen off (Helix, 2026-10-19: are
        /// numbers from a dark screen right?). The release check's summary carries it beside the run's numbers.</summary>
        readonly List<int> darkReadings = new List<int>();
        int lastRunDarkReadings;

        /// <summary>What Windows recorded about a crashed game process (its event log's faulting module and offset), or ""; the tray app reads the Application log, tests stand in.</summary>
        public Func<int, string> CrashRecord = pid => "";

        /// <summary>A crash exit code in words: "0xC0000374, heap corruption" and what Windows recorded.</summary>
        static string CrashText(int exit, string record)
        {
            uint code = unchecked((uint)exit);
            string name = code == 0xC0000374 ? "heap corruption" : code == 0xC0000005 ? "access violation" : code == 0xC0000409 ? "stack buffer overrun" : code == 0xC00000FD ? "stack overflow" : "a crash";
            return "0x" + code.ToString("X8", CultureInfo.InvariantCulture) + ", " + name + (string.IsNullOrEmpty(record) ? "" : "; " + record);
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
