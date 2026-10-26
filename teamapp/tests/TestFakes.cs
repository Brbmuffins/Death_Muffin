using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam.Tests
{
    /// <summary>The test harness: Ok / Eq count passes and failures, Done prints the total.</summary>
    static class T
    {
        static int pass, fail;
        public static void Ok(bool c, string name) { if (c) pass++; else { fail++; Console.WriteLine("FAIL: " + name); } }
        public static void Eq<X>(X a, X b, string name) { Ok(Equals(a, b), name + " (got " + Show(a) + ", want " + Show(b) + ")"); }
        public static void Has(string text, string part, string name) { Ok(text != null && text.Contains(part), name + " (\"" + part + "\" not in \"" + Cut(text) + "\")"); }
        public static void Throws<E>(Action a, string name) where E : Exception
        {
            try { a(); Ok(false, name + " (no exception)"); }
            catch (Exception ex)
            {
                Exception inner = ex is AggregateException ? ((AggregateException)ex).Flatten().InnerExceptions.FirstOrDefault() : ex;
                Ok(inner is E, name + (inner is E ? "" : " (got " + (inner == null ? "nothing" : inner.GetType().Name) + ")"));
            }
        }
        static string Show(object o) { return o == null ? "null" : Cut(o.ToString()); }
        static string Cut(string s) { s = s ?? "null"; return s.Length > 300 ? s.Substring(0, 300) + "..." : s; }
        public static int Done() { Console.WriteLine(pass + " passed, " + fail + " failed"); return fail == 0 ? 0 : 1; }
    }

    static class Util
    {
        public static string Sha(byte[] b) { using (var s = SHA256.Create()) return string.Concat(s.ComputeHash(b).Select(x => x.ToString("x2"))); }
        public static byte[] Blob(int n, int seed) { var r = new Random(seed); var b = new byte[n]; r.NextBytes(b); return b; }
        public static string TempDir(string tag)
        {
            string d = Path.Combine(Path.GetTempPath(), "dmteam-test-" + tag + "-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(d);
            return d;
        }
        public static void Rm(string dir) { try { Directory.Delete(dir, true); } catch (Exception) { } }

        /// <summary>A valid PNG signature plus an IHDR (not a real picture: the server's checks are not under test here).</summary>
        public static byte[] FakePng(int seed)
        {
            var b = new byte[200];
            new Random(seed).NextBytes(b);
            byte[] sig = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
            Array.Copy(sig, b, 8);
            return b;
        }

        public static R Wait<R>(Task<R> t) { if (!t.Wait(TimeSpan.FromSeconds(60))) throw new TimeoutException("a test step took more than 60 s"); return t.Result; }
        public static void Wait(Task t) { if (!t.Wait(TimeSpan.FromSeconds(60))) throw new TimeoutException("a test step took more than 60 s"); }
    }

    // A file server with Range support and fault injection (the launcher's tests' server, under the job files' path).
    sealed class TestServer : IDisposable
    {
        public readonly HttpListener L = new HttpListener();
        public readonly Uri SiteBase;
        public readonly string FilesBase;
        public readonly Dictionary<string, byte[]> Files = new Dictionary<string, byte[]>();
        public readonly List<string> RangeHeaders = new List<string>();
        public readonly Dictionary<string, int> Hits = new Dictionary<string, int>();
        public readonly Dictionary<string, int> DropFirstAfter = new Dictionary<string, int>();
        public readonly Dictionary<string, int> CorruptFirst = new Dictionary<string, int>();
        public bool AlwaysCorrupt;
        public bool IgnoreRange;

        public TestServer()
        {
            int port;
            using (var s = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0)) { s.Start(); port = ((IPEndPoint)s.LocalEndpoint).Port; s.Stop(); }
            SiteBase = new Uri("http://127.0.0.1:" + port + "/death-muffin/");
            FilesBase = SiteBase + "team-files/";
            L.Prefixes.Add("http://127.0.0.1:" + port + "/");
            L.Start();
            Task.Run(Loop);
        }

        /// <summary>Publishes bytes at team-files/&lt;folder&gt;/&lt;name&gt; and returns its payload entry.</summary>
        public Dictionary<string, object> Publish(string folder, string name, byte[] data, string cacheKey = null)
        {
            Files["death-muffin/team-files/" + folder + "/" + name] = data;
            var d = new Dictionary<string, object> { { "name", name }, { "url", FilesBase + folder + "/" + name }, { "sha256", Util.Sha(data) }, { "bytes", (double)data.Length } };
            if (cacheKey != null) d["cacheKey"] = cacheKey;
            return d;
        }

        public int HitsFor(string pathPart) { lock (Hits) return Hits.Where(h => h.Key.Contains(pathPart)).Sum(h => h.Value); }

        async Task Loop()
        {
            while (L.IsListening)
            {
                HttpListenerContext c;
                try { c = await L.GetContextAsync(); } catch (Exception) { return; }
                var ignored = Task.Run(() => Handle(c));
            }
        }

        void Handle(HttpListenerContext c)
        {
            string path = c.Request.Url.AbsolutePath.TrimStart('/');
            try
            {
                byte[] data;
                lock (Hits) { Hits[path] = Hits.ContainsKey(path) ? Hits[path] + 1 : 1; }
                if (!Files.TryGetValue(path, out data)) { c.Response.StatusCode = 404; c.Response.Close(); return; }
                int hit; lock (Hits) hit = Hits[path];
                string range = c.Request.Headers["Range"];
                if (range != null) lock (RangeHeaders) RangeHeaders.Add(path + " " + range);
                long start = 0;
                if (range != null && !IgnoreRange && range.StartsWith("bytes=") && range.EndsWith("-")) start = long.Parse(range.Substring(6, range.Length - 7));
                byte[] body = data.Skip((int)start).ToArray();
                if (AlwaysCorrupt || (CorruptFirst.ContainsKey(path) && hit <= CorruptFirst[path])) body = body.Select(b => (byte)(b ^ 0xFF)).ToArray();
                c.Response.StatusCode = start > 0 ? 206 : 200;
                c.Response.ContentLength64 = body.Length;
                if (DropFirstAfter.ContainsKey(path) && hit == 1)
                {
                    int n = DropFirstAfter[path];
                    c.Response.OutputStream.Write(body, 0, n);
                    c.Response.OutputStream.Flush();
                    c.Response.Abort();
                    return;
                }
                c.Response.OutputStream.Write(body, 0, body.Length);
                c.Response.Close();
            }
            catch (Exception) { try { c.Response.Abort(); } catch (Exception) { } }
        }

        public void Dispose() { try { L.Stop(); L.Close(); } catch (Exception) { } }
    }

    // ---- The server's team routes, as a stand-in the tests script ------------------------------------------------------------------

    sealed class FakeApi : ITeamApi
    {
        public string Token { get; set; }
        public readonly List<string> Calls = new List<string>();
        public readonly List<string> Uploaded = new List<string>();
        public readonly Dictionary<string, byte[]> UploadedBytes = new Dictionary<string, byte[]>();
        public string DoneLog, FailLog, FailError, DoneJob, FailJob;
        public IList<string> DoneFiles;
        /// <summary>What a `bench` job's done carried.</summary>
        public List<Dictionary<string, object>> DoneRuns;
        public double DoneDownloadS, DoneRunS;
        public readonly List<string> Declines = new List<string>();
        public PcState LastState;
        public OfferMode LastMode;
        /// <summary>The `wait` of the last heartbeat (0 for a heartbeat that asks to be answered at once) and of every one.</summary>
        public int LastWait;
        public readonly List<int> Waits = new List<int>();
        public string LastPcId, LastName, LastVersion, LastGpu, LastClaimToken, LastLoginUser, LastLoginPassword, LastLoginPcId, LastLoginPcName;

        public Func<ApiResult> Login = () => Ok(new Dictionary<string, object> { { "token", "tok-1" }, { "expiresAt", "2027-01-17T12:00:00Z" }, { "accountId", 100.0 }, { "username", "Helix" } });
        public Func<ApiResult> Logout = () => Ok(new Dictionary<string, object>());
        public Func<ApiResult> Heartbeat = () => Ok(new Dictionary<string, object> { { "serverTime", "2026-10-19T12:00:00Z" }, { "offer", null } });
        public Func<string, ApiResult> Claim = id => Ok(new Dictionary<string, object> { { "id", id }, { "kind", "shots" }, { "title", "t" }, { "payload", new Dictionary<string, object>() } });
        public Func<string, ApiResult> Upload = name => Ok(new Dictionary<string, object> { { "name", name } });
        public Func<ApiResult> Done = () => Ok(new Dictionary<string, object>());
        public Func<ApiResult> Fail = () => Ok(new Dictionary<string, object>());

        public static ApiResult Ok(Dictionary<string, object> data) { return new ApiResult { Ok = true, Status = 200, Data = data }; }
        public static ApiResult Err(int status, string code, string error) { return new ApiResult { Ok = false, Status = status, Code = code, Error = error }; }
        public static ApiResult NetErr() { return new ApiResult { Ok = false, Network = true, Error = "Could not reach the server. Check the internet connection." }; }

        public static ApiResult OfferReply(string id, string kind = "shots", string title = "Screenshots of a change", int weightS = 60)
        {
            return Ok(new Dictionary<string, object>
            {
                { "serverTime", "2026-10-19T12:00:00Z" },
                { "offer", new Dictionary<string, object> { { "id", id }, { "kind", kind }, { "title", title }, { "weightS", (double)weightS }, { "expiresAt", "2026-10-19T13:00:00Z" } } },
            });
        }

        void Log(string s) { lock (Calls) Calls.Add(s); }
        public int Count(string prefix) { lock (Calls) return Calls.Count(c => c.StartsWith(prefix)); }

        public Task<ApiResult> LoginAsync(string u, string p, string pcId, string pcName, CancellationToken ct)
        {
            Log("login " + u); LastLoginUser = u; LastLoginPassword = p; LastLoginPcId = pcId; LastLoginPcName = pcName;
            return Task.FromResult(Login());
        }
        public Task<ApiResult> LogoutAsync(CancellationToken ct) { Log("logout " + Token); return Task.FromResult(Logout()); }
        public Task<ApiResult> HeartbeatAsync(string pcId, string name, string version, string gpu, OfferMode mode, PcState state, CancellationToken ct)
        {
            return HeartbeatAsync(pcId, name, version, gpu, mode, state, 0, ct);
        }
        public Task<ApiResult> HeartbeatAsync(string pcId, string name, string version, string gpu, OfferMode mode, PcState state, int waitS, CancellationToken ct)
        {
            Log("heartbeat"); LastPcId = pcId; LastName = name; LastVersion = version; LastGpu = gpu; LastMode = mode; LastState = state; LastWait = waitS;
            lock (Waits) Waits.Add(waitS);
            var answer = Heartbeat();
            ct.ThrowIfCancellationRequested();   // a heartbeat in flight when the app closes ends with the cancellation, as an HTTP request would
            return Task.FromResult(answer);
        }
        public Task<ApiResult> ClaimAsync(string jobId, string pcId, CancellationToken ct) { Log("claim " + jobId); LastClaimToken = Token; return Task.FromResult(Claim(jobId)); }
        public Task<ApiResult> DeclineAsync(string jobId, string pcId, string reason, CancellationToken ct) { Log("decline " + jobId + " " + reason); lock (Declines) Declines.Add(jobId + ":" + reason); return Task.FromResult(Ok(new Dictionary<string, object>())); }
        public Task<ApiResult> UploadAsync(string jobId, string name, byte[] png, CancellationToken ct)
        {
            Log("upload " + name);
            var r = Upload(name);
            if (r.Ok) { lock (Uploaded) { Uploaded.Add(name); UploadedBytes[name] = png; } }
            return Task.FromResult(r);
        }
        public Task<ApiResult> DoneAsync(string jobId, IList<string> files, string log, double downloadS, double runS, CancellationToken ct)
        {
            Log("done " + jobId); DoneJob = jobId; DoneFiles = files.ToList(); DoneLog = log; DoneDownloadS = downloadS; DoneRunS = runS;
            return Task.FromResult(Done());
        }
        public Task<ApiResult> DoneBenchAsync(string jobId, IList<Dictionary<string, object>> runs, string log, double downloadS, double runS, CancellationToken ct)
        {
            Log("done " + jobId); DoneJob = jobId; DoneFiles = new List<string>(); DoneRuns = runs.ToList(); DoneLog = log; DoneDownloadS = downloadS; DoneRunS = runS;
            return Task.FromResult(Done());
        }
        public Task<ApiResult> FailAsync(string jobId, string error, string log, CancellationToken ct) { return FailAsync(jobId, error, log, null, ct); }
        public Task<ApiResult> FailAsync(string jobId, string error, string log, IList<StepReport> steps, CancellationToken ct)
        {
            Log("fail " + jobId); FailJob = jobId; FailError = error; FailLog = log; FailSteps = steps == null ? null : steps.ToList();
            return Task.FromResult(Fail());
        }
        /// <summary>What a `release` job's done carried: how each step went, the files it uploaded, the bench step's runs.</summary>
        public List<StepReport> DoneSteps;
        public List<StepReport> FailSteps;
        public Task<ApiResult> DoneReleaseAsync(string jobId, IList<StepReport> steps, IList<string> files, IList<Dictionary<string, object>> runs, string log, double downloadS, double runS, CancellationToken ct)
        {
            Log("done " + jobId); DoneJob = jobId; DoneSteps = steps.ToList(); DoneFiles = files.ToList(); DoneRuns = runs == null ? null : runs.ToList(); DoneLog = log; DoneDownloadS = downloadS; DoneRunS = runS;
            return Task.FromResult(Done());
        }
    }

    // ---- The game, as a stand-in that writes pictures ---------------------------------------------------------------------------------

    sealed class FakeGameHost : IGameHost
    {
        public readonly List<GameLaunch> Launches = new List<GameLaunch>();
        /// <summary>What a run does: gets the launch and its shots folder; returns the exit code, or null to keep running until killed.</summary>
        public Func<GameLaunch, string, int?> Behaviour;
        public bool ThrowOnStart;
        public int Killed;
        /// <summary>How many times a process is asked whether it has exited before it says yes (0: at once), for the processes started after this is set (a Behaviour may set it for its own run).
        /// A run that has to last a while for the PC to be read during it.</summary>
        public int RunPolls;
        static int nextPid = 5000;

        public FakeGameHost() { Behaviour = (l, dir) => { File.WriteAllBytes(Path.Combine(dir, "bag-open.png"), Util.FakePng(1)); File.WriteAllBytes(Path.Combine(dir, "hero view.png"), Util.FakePng(2)); return 0; }; }

        static string ArgValue(GameLaunch l, params string[] names)
        {
            string a = l.Args.First(x => names.Any(n => x.StartsWith(n + "=")));
            return a.Substring(a.IndexOf('=') + 1);
        }

        /// <summary>What a run prints (what the app reads `BOOT OK` from): the same for every run unless a test sets this.</summary>
        public Func<GameLaunch, string> OutputFor;

        /// <summary>Where the run puts its files: the shots folder, a clip run's `--clips` folder, a benchmark's `--bench-dir`, a QA scenario's `--stutter-out` or `--soak-out`; a run with none (a boot check) has its LOCALAPPDATA.</summary>
        public static string ShotsDir(GameLaunch l)
        {
            string a = l.Args.FirstOrDefault(x => new[] { "--shots", "--clips", "--bench-dir", "--stutter-out", "--soak-out" }.Any(n => x.StartsWith(n + "=")));
            return a == null ? l.LocalAppData : a.Substring(a.IndexOf('=') + 1);
        }

        public static string Preset(GameLaunch l) { return ArgValue(l, "--preset", "--bench-preset"); }

        public IGameProcess Start(GameLaunch l)
        {
            if (ThrowOnStart) throw new InvalidOperationException("Access is denied");
            lock (Launches) Launches.Add(l);
            string dir = ShotsDir(l);
            Directory.CreateDirectory(dir);
            int? code = Behaviour(l, dir);
            return new FakeProcess(this, Interlocked.Increment(ref nextPid), code, l);
        }

        sealed class FakeProcess : IGameProcess
        {
            readonly FakeGameHost host;
            readonly int? code;
            readonly int runPolls;
            bool killed;
            int polls;
            readonly GameLaunch launch;
            public FakeProcess(FakeGameHost host, int pid, int? code, GameLaunch launch) { this.host = host; Id = pid; this.code = code; runPolls = host.RunPolls; this.launch = launch; }
            public int Id { get; private set; }
            public bool HasExited { get { return killed || (code.HasValue && ++polls > runPolls); } }
            public int ExitCode { get { return killed ? -1 : code ?? -1; } }
            public void Kill() { if (!killed) { killed = true; host.Killed++; } }
            public void Tend() { }
            public string Output() { return host.OutputFor == null ? "QA-SHOTS fake game output" : host.OutputFor(launch); }
            public void Dispose() { }
        }
    }

    sealed class FakeWatch : IPlayerGameWatch
    {
        public volatile bool Started;
        public int Begins;
        public void Begin() { Begins++; }
        public bool PlayerStarted(int ownPid) { return Started; }
        public string LastSeen { get { return Started ? "DeathMuffin.exe pid 1 at C:/Games/DeathMuffin.exe" : ""; } }
    }

    /// <summary>
    /// The PC as a script on a clock of its own: every Read advances <see cref="Step"/> and returns <see cref="Script"/>'s answer for it, so a minute of quiet is 60 reads and no waiting.
    /// The default PC is quiet: nothing else running, long idle, the job's game using 40%.
    /// </summary>
    sealed class FakePcProbe : IPcProbe
    {
        public TimeSpan Step = TimeSpan.FromSeconds(1);
        public TimeSpan Clock = TimeSpan.FromSeconds(1000);
        public int Reads;
        public readonly List<int> Pids = new List<int>();
        /// <summary>(read number, clock, game pid) -> the reading. The reading's own time and the game's share are filled in after when left at their defaults.</summary>
        public Func<int, TimeSpan, int, PcSample> Script;
        /// <summary>When the last key or mouse input was, on the same clock (the default is long ago).</summary>
        public TimeSpan LastInput = TimeSpan.FromSeconds(-100000);

        public FakePcProbe() { Script = (n, t, pid) => new PcSample { CpuTotal = 3 + (pid > 0 ? 40 : 0), CpuGame = pid > 0 ? 40 : 0 }; }

        public PcSample Read(int gamePid)
        {
            Reads++;
            Pids.Add(gamePid);
            Clock += Step;
            PcSample s = Script(Reads, Clock, gamePid);
            s.At = Clock;
            s.IdleS = (Clock - LastInput).TotalSeconds;
            return s;
        }

        /// <summary>Someone presses a key now (the next reading says so).</summary>
        public void Touch() { LastInput = Clock + Step; }
    }

    sealed class FakeProtector : ITokenProtector
    {
        public bool Fail;
        public string Protect(string plain) { return Convert.ToBase64String(Encoding.UTF8.GetBytes("protected:" + plain)); }
        public string Unprotect(string text)
        {
            if (Fail) return null;
            try
            {
                string s = Encoding.UTF8.GetString(Convert.FromBase64String(text));
                return s.StartsWith("protected:") ? s.Substring("protected:".Length) : null;
            }
            catch (FormatException) { return null; }
        }
    }

    sealed class FakePlatform : ITeamPlatform
    {
        public bool IsFullscreen, IsGame, IsBattery;
        public string Gpu = "NVIDIA GeForce GTX 970";
        public long Vram = 4096;
        public bool Fullscreen() { return IsFullscreen; }
        public long VramMb() { return Vram; }
        public bool OnBattery() { return IsBattery; }
        public bool GameRunning() { return IsGame; }
        public string GpuName() { return Gpu; }
    }

    sealed class FakeUi : ITeamUi
    {
        public readonly List<string> Events = new List<string>();
        public readonly List<OfferView> Shown = new List<OfferView>();
        public string Status = "";
        public StatusLevel Level;
        public bool BoxVisible;
        public string SignInReason; public bool SignInOpenNow; public int SignInCalls;
        public string StoppedMessage;
        public readonly List<string> Notices = new List<string>();

        public void ShowOffer(OfferView v) { BoxVisible = true; Shown.Add(v); Events.Add("show"); }
        public void HideOffer() { BoxVisible = false; Events.Add("hide"); }
        public void SetStatus(string text, StatusLevel level) { Status = text; Level = level; }
        public void Notify(string title, string text, bool error) { Notices.Add(title + ": " + text); }
        public void NeedSignIn(string reason, bool openNow) { SignInReason = reason; SignInOpenNow = openNow; SignInCalls++; }
        public void Stopped(string message) { StoppedMessage = message; }
        public bool Afk;
        public readonly List<bool> AfkChanges = new List<bool>();
        public void SetAfk(bool on) { Afk = on; AfkChanges.Add(on); }
        public List<string> JobLines = new List<string>();
        public int JobUpdates;
        readonly object jobsLock = new object();
        public void SetJobs(IList<string> lines) { lock (jobsLock) { JobLines = new List<string>(lines); JobUpdates++; } }
    }

    /// <summary>A stand-in for ffmpeg: the "mp4" is MP4: and the clip's bytes; each call is noted as `<clip file>@<fps>`. <see cref="Fail"/> makes it fail, <see cref="Big"/> makes an mp4 past the server's limit.</summary>
    sealed class FakeEncoder : IVideoEncoder
    {
        public readonly List<string> Calls = new List<string>();
        public string Ffmpeg;
        public string Fail;
        public bool Big;

        public static byte[] Mp4Of(byte[] mjpeg) { return Encoding.ASCII.GetBytes("MP4:").Concat(mjpeg).ToArray(); }

        public Task<EncodeResult> EncodeAsync(string ffmpeg, string mjpeg, int fps, string mp4, CancellationToken ct)
        {
            lock (Calls) Calls.Add(Path.GetFileName(mjpeg) + "@" + fps);
            Ffmpeg = ffmpeg;
            if (Fail != null) return Task.FromResult(new EncodeResult { Error = Fail });
            if (Big) using (var fs = new FileStream(mp4, FileMode.Create)) fs.SetLength(JobPlan.MaxMp4Bytes + 1);
            else File.WriteAllBytes(mp4, Mp4Of(File.ReadAllBytes(mjpeg)));
            return Task.FromResult(new EncodeResult { Ok = true, Bytes = new FileInfo(mp4).Length, Crf = 20, Seconds = 0.1 });
        }
    }

    sealed class FakeRunner : IJobRunner
    {
        public readonly List<string> Ran = new List<string>();
        public JobPlan LastPlan;
        public RunResult Result = new RunResult { Ok = true, Files = new List<string> { "low_a.png" } };
        public TaskCompletionSource<int> Gate;
        public CancellationToken LastToken, LastCancel;
        public Exception Throw;

        public async Task<RunResult> RunAsync(string jobId, JobPlan plan, Action<string> progress, CancellationToken ct, CancellationToken cancelled)
        {
            Ran.Add(jobId);
            LastPlan = plan;
            LastToken = ct;
            LastCancel = cancelled;
            progress("running " + jobId);
            if (Throw != null) throw Throw;
            if (Gate != null)
            {
                var done = await Task.WhenAny(Gate.Task, Task.Delay(Timeout.Infinite, ct), Task.Delay(Timeout.Infinite, cancelled)).ConfigureAwait(false);
                if (cancelled.IsCancellationRequested) return new RunResult { Ok = false, Cancelled = true, Error = "The job was cancelled." };
                if (ct.IsCancellationRequested) return new RunResult { Ok = false, Error = "stopped: the team app was closed" };
            }
            return Result;
        }
    }
}
