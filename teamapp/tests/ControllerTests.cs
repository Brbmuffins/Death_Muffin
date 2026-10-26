using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam.Tests
{
    sealed class CtlRig
    {
        public readonly FakeApi Api = new FakeApi();
        public readonly FakeUi Ui = new FakeUi();
        public readonly FakePlatform Plat = new FakePlatform();
        public readonly FakeRunner Runner = new FakeRunner();
        public readonly FakePcProbe Probe = new FakePcProbe();
        public readonly TeamSettings Settings;
        public readonly List<string> Log = new List<string>();
        public readonly TeamController C;
        public DateTime Now = new DateTime(2026, 10, 19, 12, 0, 0, DateTimeKind.Utc);
        public int Saves;
        public static readonly Uri Site = new Uri("https://muffindevelopment.com/death-muffin/");

        public CtlRig(bool signedIn = true, OfferMode mode = OfferMode.Ask)
        {
            Settings = new TeamSettings { Username = "Helix", Token = signedIn ? "tok-0" : "", Mode = mode, PcId = "0123456789abcdef" };
            C = new TeamController(Api, Settings, () => Saves++, Plat, Runner, Ui, () => Now, "0.1.0", "WAR-PC", Site, Log.Add, Probe) { MinReadMs = 0 };
            Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "shots" }, { "title", "Screenshots of a change" }, { "payload", Program.ValidPayload() } });
        }

        public void Start() { Util.Wait(C.StartAsync()); }
        public void Beat() { Util.Wait(C.HeartbeatAsync()); }
        public void Eval() { Util.Wait(C.EvaluateAsync()); }
        public void Offer(string id = "job000000001", string kind = "shots") { Api.Heartbeat = () => FakeApi.OfferReply(id, kind); Beat(); }
        public void Advance(double minutes) { Now = Now.AddMinutes(minutes); }
        public int Ran { get { return Runner.Ran.Count; } }
        public string LastCountdown { get { return Ui.Shown.Count == 0 ? null : Ui.Shown.Last().Countdown; } }
    }

    static class CtlStatus
    {
        public const string Waiting = "Benchmark waiting for a quiet PC";
    }

    static class ControllerTests
    {
        public static void Run()
        {
            Starting();
            SignIn();
            AskMode();
            Answers();
            Exceptions();
            OtherModes();
            ShowJobsAndPause();
            JobProblems();
            SignInTrouble();
            SignOut();
            Busy();
            BenchJobs();
            BenchOffersLikeAnyJob();
            BenchWaitsUnclaimed();
            BenchWaitingEnds();
            AfkMode();
            ServerCancel();
            JobsForTheAfkNotice();
            JobList();
            BenchmarksSwitch();
            AfkSwitch();
            ModelJobs();
        }

        /// <summary>Helix 2026-10-26: ComfyUI only on a graphics card with 12 GB or more; such a PC with ComfyUI Desktop says so in its heartbeat, and only it lists and runs model jobs.</summary>
        static void ModelJobs()
        {
            var r = new CtlRig();
            r.Start();
            T.Ok(!r.Api.LastState.Models && r.Api.LastState.VramMb == 4096, "a 4 GB card runs no model jobs, and its memory is sent");
            T.Ok(r.Log.Any(l => l.Contains("graphics card: NVIDIA GeForce GTX 970, 4.0 GB (model jobs need 12 GB or more)")), "the app's log says why");

            r = new CtlRig();
            r.Plat.Vram = 12282;
            r.Start();
            T.Ok(!r.Api.LastState.Models, "a 12 GB card without ComfyUI Desktop runs none");

            bool installed = true;
            r = new CtlRig();
            r.Plat.Vram = 11264;
            r.C.ComfyInstalled = () => installed;
            r.Start();
            T.Ok(!r.Api.LastState.Models, "an 11 GB card with ComfyUI Desktop runs none");

            r = new CtlRig(mode: OfferMode.Auto);
            r.Plat.Gpu = "NVIDIA GeForce RTX 4070 SUPER";
            r.Plat.Vram = 12282;
            r.C.ComfyInstalled = () => installed;
            r.Start();
            T.Ok(r.Api.LastState.Models && r.Api.LastState.VramMb == 12282, "a 12 GB card with ComfyUI Desktop runs model jobs, and says so");
            ListReply(r, Listed("job000000001", "model", "", 600), Listed("job000000002", "shots", "Screenshots", 60));
            r.Beat();
            T.Eq(r.C.JobsAvailable, 2, "it lists them");
            installed = false;
            r.Beat();
            T.Ok(!r.Api.LastState.Models && r.C.JobsAvailable == 1 && r.C.CurrentOffer.Id == "job000000002", "ComfyUI Desktop gone: model jobs are left out at once");
            T.Eq(r.Api.Declines.Count, 0, "and nothing is refused (the server stops offering them)");
            installed = true;

            var payload = new Dictionary<string, object>
            {
                { "files", new List<object> { Program.File_("concept.png") } },
                { "runs", new List<object> { ModelRig.Run("hound") } },
            };
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "model" }, { "title", "3D models from a picture, about 10 minutes" }, { "payload", payload } });
            r.Runner.Result = new RunResult { Ok = true, Files = new List<string> { "hound.glb" } };
            r.Runner.Gate = new TaskCompletionSource<int>();
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000001", "model");
            r.Beat();
            Task running = r.C.EvaluateAsync();
            T.Ok(WaitFor(() => r.C.IsBusy && r.Runner.Ran.Count == 1), "a model job runs like any job");
            T.Ok(r.Runner.LastPlan != null && r.Runner.LastPlan.Kind == JobPlan.ModelKind && r.Runner.LastPlan.ModelRuns.Count == 1, "with its runs");
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000003", "model");
            r.Beat(); r.Beat();
            T.Eq(r.Api.Declines.Count, 0, "a second model job offered while one runs is not declined busy (few PCs can run one: it waits for this one)");
            r.Runner.Gate.SetResult(0);
            Util.Wait(running);
            T.Ok(r.Ui.Status.StartsWith("Last job: 1 model(s) uploaded at "), "the status says models were uploaded: " + r.Ui.Status);

            int told = 0;
            r.C.PlayerPlaying = () => told++;
            r.Api.Heartbeat = () => FakeApi.Ok(new Dictionary<string, object> { { "serverTime", "2026-10-19T12:00:00Z" }, { "offer", null } });
            r.Beat();
            T.Eq(told, 0, "a heartbeat without the game says nothing to ComfyUI");
            r.Plat.IsGame = true;
            r.Beat();
            T.Ok(told == 1 && r.Api.LastState.GameRunning, "a heartbeat that sees the player's game tells the app's ComfyUI to go");
            r.C.PlayerPlaying = () => { throw new InvalidOperationException("no access"); };
            r.Beat();
            T.Ok(r.Log.Any(l => l.Contains("could not stop the app's ComfyUI for the game: no access")), "a failure there is logged, and the heartbeat still goes");
        }

        static Dictionary<string, object> Listed(string id, string kind, string title, double weightS, string who = null, string thread = null, params string[] steps)
        {
            var d = Queued(id, kind, title, weightS);
            if (who != null) d["requestedBy"] = who;
            if (thread != null) d["thread"] = thread;
            if (steps.Length > 0) d["steps"] = steps.Cast<object>().ToList();
            return d;
        }

        static void ListReply(CtlRig r, params Dictionary<string, object>[] jobs)
        {
            var list = jobs.Cast<object>().ToList();
            r.Api.Heartbeat = () =>
            {
                var a = jobs.Length == 0 ? FakeApi.Ok(new Dictionary<string, object> { { "serverTime", "x" }, { "offer", null } }) : FakeApi.OfferReply((string)jobs[0]["id"], (string)jobs[0]["kind"]);
                a.Data["queue"] = list;
                return a;
            };
        }

        /// <summary>Helix 2026-10-19: the box lists the first 10 jobs oldest first, with who started the Discord thread and its name; a click picks one; Run now runs that one only.</summary>
        static void JobList()
        {
            var r = new CtlRig();
            r.Start();
            ListReply(r, Listed("job000000001", "shots", "Screenshots of a change, about 2 minutes", 120, "War", "Bigger skull pile"),
                Listed("job000000002", "clip", "Short videos of a change: 1 option, about 2 minutes", 120, "Helix", null),
                Listed("job000000003", "release", "Checks of abc1234", 240, null, null, "install", "bench"));
            r.Beat(); r.Eval();
            OfferView v = r.Ui.Shown.Last();
            T.Eq(string.Join("|", v.Rows.Select(x => x.Id + (x.Selected ? "*" : ""))), "job000000001*|job000000002|job000000003", "every job listed oldest first, the oldest picked");
            T.Eq(string.Join("|", v.Rows.Select(x => x.Who)), "War · Bigger skull pile|Helix|takes the whole screen", "who asked and the thread; a job with a benchmark says it takes the whole screen");
            T.Eq(v.Countdown, "The selected job runs by itself in 5:00", "the countdown is the picked job's");
            r.Advance(2); r.Eval();
            r.C.Choose("job000000002");
            v = r.Ui.Shown.Last();
            T.Ok(r.C.CurrentOffer.Id == "job000000002" && v.Rows[1].Selected && !v.Rows[0].Selected, "a click picks another job, and the box shows it at once");
            T.Eq(v.Countdown, "The selected job runs by itself in 3:00", "a pick keeps the box's countdown");
            r.C.Choose("job000000009");
            T.Eq(r.C.CurrentOffer.Id, "job000000002", "a job not listed cannot be picked");
            r.Beat(); r.Eval();
            T.Eq(r.C.CurrentOffer.Id, "job000000002", "the pick stays across heartbeats");
            Util.Wait(r.C.AnswerAsync(OfferAnswer.Yes));
            T.Ok(r.Ran == 1 && r.Api.Calls.Contains("claim job000000002"), "Run now runs the picked job, and only it");
            ListReply(r, Listed("job000000001", "shots", "Screenshots of a change, about 2 minutes", 120), Listed("job000000003", "release", "Checks of abc1234", 240, null, null, "install"));
            r.Beat(); r.Eval();
            T.Ok(r.Ran == 1 && r.Ui.BoxVisible && r.C.CurrentOffer.Id == "job000000001" && r.LastCountdown == "The selected job runs by itself in 5:00",
                "the next job asks again, with its own 5 minutes (Helix: a yes in mode Ask runs one job, not all)");

            var many = new List<Dictionary<string, object>>();
            for (int i = 0; i < 14; i++) many.Add(Listed("job0000000" + (10 + i), "shots", "Screenshots " + i, 60));
            r = new CtlRig();
            r.Start(); ListReply(r, many.ToArray()); r.Beat(); r.Eval();
            v = r.Ui.Shown.Last();
            T.Ok(v.Rows.Count == TeamController.RowsShown && v.More == 4 && v.Rows[0].Id == "job000000010" && v.Rows[9].Id == "job000000019", "the first 10, oldest first, and how many more");
            T.Eq(r.C.JobsAvailable, 14, "the tray counts them all");

            // Not now puts the whole list off, Show jobs brings it back
            r = new CtlRig();
            r.Start(); ListReply(r, Listed("job000000001", "shots", "a", 60), Listed("job000000002", "shots", "b", 60)); r.Beat(); r.Eval();
            Util.Wait(r.C.AnswerAsync(OfferAnswer.NotNow));
            r.Beat(); r.Eval();
            T.Ok(!r.Ui.BoxVisible && r.C.CurrentOffer == null && r.C.JobsAvailable == 2 && r.Api.Declines.Count == 0, "Not now hides every listed job, refuses none");
            Util.Wait(r.C.ShowJobsAsync());
            T.Eq(r.Ui.Shown.Last().Rows.Count, 2, "Show jobs lists them all again");
        }

        /// <summary>Helix 2026-10-19: the tray's Run benchmarks; off, this PC leaves benchmark-only jobs alone and tells the server.</summary>
        static void BenchmarksSwitch()
        {
            var r = new CtlRig();
            r.Start();
            ListReply(r, Listed("job000000001", "bench", "Benchmark of the new release", 360), Listed("job000000002", "release", "Benchmark of the live build", 240, null, null, "bench"),
                Listed("job000000003", "release", "Checks of abc1234", 240, null, null, "install", "bench"), Listed("job000000004", "shots", "Screenshots", 60));
            Util.Wait(r.C.SetRunBenchmarksAsync(false));
            T.Ok(!r.Settings.RunBenchmarks && r.Saves > 0 && !r.Api.LastState.Benchmarks, "switched off: saved, and the server hears it at once");
            r.Eval();
            T.Eq(string.Join("|", r.Ui.Shown.Last().Rows.Select(x => x.Id)), "job000000003|job000000004", "benchmark-only jobs are not listed; a release check with other steps is (it skips its benchmark)");
            T.Eq(r.Api.Declines.Count, 0, "and nothing is refused: another PC, or this one later, takes them");
            Util.Wait(r.C.SetRunBenchmarksAsync(true));
            r.Eval();
            T.Ok(r.Api.LastState.Benchmarks && r.Ui.Shown.Last().Rows.Count == 4, "switched on again: all four listed");
            T.Eq(TeamSettings.FromJson(r.Settings.ToJson(new FakeProtector()), new FakeProtector()).RunBenchmarks, true, "the switch round-trips");
            r.Settings.RunBenchmarks = false;
            T.Eq(TeamSettings.FromJson(r.Settings.ToJson(new FakeProtector()), new FakeProtector()).RunBenchmarks, false, "off round-trips too");
            T.Ok(new TeamSettings().RunBenchmarks && new TeamSettings().AfkAllowed && TeamSettings.FromJson("{}", new FakeProtector()).RunBenchmarks, "both switches are on by default");

            // a benchmark already waiting for a quiet PC is let go
            var w = new WaitRig(OfferMode.Auto);
            w.Offers("bench0000001"); w.R.Eval();
            T.Ok(w.R.C.WaitingBench != null, "a benchmark waits");
            Util.Wait(w.R.C.SetRunBenchmarksAsync(false));
            T.Ok(w.R.C.WaitingBench == null && w.R.Ran == 0, "switching benchmarks off lets it go");
        }

        /// <summary>Helix 2026-10-19: AFK mode stays as it is, with a switch to turn it off.</summary>
        static void AfkSwitch()
        {
            var r = new CtlRig();
            r.Start();
            r.C.SetAfkAllowed(false);
            T.Ok(!r.Settings.AfkAllowed && r.Saves > 0, "switched off and saved");
            r.Offer("job000000001"); r.Eval(); r.Advance(5.1); r.Eval();
            T.Ok(r.Ran == 1 && !r.C.IsAfk && !r.Ui.Afk, "a box that runs out still runs its job, but AFK mode does not start");
            r.Offer("job000000002"); r.Eval();
            T.Ok(r.Ran == 1 && r.Ui.BoxVisible, "so the next job asks again");
            r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval(); r.Advance(5.1); r.Eval();
            T.Ok(r.C.IsAfk, "with the switch on (the default) AFK mode starts as before");
            r.C.SetAfkAllowed(false);
            T.Ok(!r.C.IsAfk && !r.Ui.Afk, "switching it off ends AFK mode");
            T.Eq(TeamSettings.FromJson(r.Settings.ToJson(new FakeProtector()), new FakeProtector()).AfkAllowed, false, "the switch round-trips");
        }

        static Dictionary<string, object> Queued(string id, string kind, string title, double weightS)
        {
            return new Dictionary<string, object> { { "id", id }, { "kind", kind }, { "title", title }, { "weightS", weightS } };
        }

        static string Lines(CtlRig r) { return string.Join("|", r.Ui.JobLines); }

        /// <summary>Helix 2026-10-19: the AFK notice shows what runs (with its step) and the queue, from the heartbeat's `queue`.</summary>
        static void JobsForTheAfkNotice()
        {
            var r = new CtlRig();
            r.Start();
            T.Eq(Lines(r), "Nothing is running|Nothing is queued", "nothing to do: the notice says so");
            var queue = new List<object> { Queued("job000000001", "shots", "Screenshots of a change", 60), Queued("job000000002", "release", "Release checks of 20261019.1", 2400) };
            r.Api.Heartbeat = () =>
            {
                var a = FakeApi.OfferReply("job000000001");
                a.Data["queue"] = queue;
                return a;
            };
            r.Beat();
            T.Eq(Lines(r), "Nothing is running|Queued: 2|· Screenshots of a change, about 1 minute|· Release checks of 20261019.1, about 40 minutes", "the queue, in the server's order, with how long each takes");
            r.Eval();
            r.Runner.Gate = new TaskCompletionSource<int>();
            Task run = r.C.AnswerAsync(OfferAnswer.Yes);
            for (int i = 0; i < 200 && !Lines(r).Contains("running job000000001"); i++) Thread.Sleep(10);
            T.Eq(Lines(r), "Running: Screenshots of a change|   running job000000001|Queued: 1|· Release checks of 20261019.1, about 40 minutes", "the running job and its latest step, and it is not queued twice");
            r.Runner.Gate.SetResult(0);
            Util.Wait(run);
            T.Eq(Lines(r), "Nothing is running|Queued: 1|· Release checks of 20261019.1, about 40 minutes", "a finished job leaves the list at once");
            var many = new List<object>();
            for (int i = 0; i < 6; i++) many.Add(Queued("job00000001" + i, "shots", "", 30));
            r.Api.Heartbeat = () => FakeApi.Ok(new Dictionary<string, object> { { "serverTime", "x" }, { "offer", null }, { "queue", many } });
            r.Beat();
            T.Eq(Lines(r), "Nothing is running|Queued: 6|· Screenshots of a change, less than a minute|· Screenshots of a change, less than a minute|· Screenshots of a change, less than a minute|· and 3 more", "three named, then how many more; a job without a title gets its kind's words");
            int updates = r.Ui.JobUpdates;
            r.Beat();
            T.Eq(r.Ui.JobUpdates, updates, "the same lines are not sent again");
            r.Api.Heartbeat = () => FakeApi.Ok(new Dictionary<string, object> { { "serverTime", "x" }, { "offer", null } });
            r.Beat();
            T.Eq(Lines(r), "Nothing is running|Nothing is queued", "a server without the list (or an empty one) means nothing queued");
        }

        static void Starting()
        {
            var r = new CtlRig(signedIn: false);
            r.Start();
            T.Ok(r.Ui.SignInCalls == 1 && r.Ui.SignInOpenNow, "first start: the sign-in box opens");
            T.Eq(r.Api.Count("heartbeat"), 0, "nothing is sent before sign-in");
            T.Ok(!r.C.SignedIn && r.Ui.Status == "Not signed in", "status: not signed in");
            T.Ok(r.Settings.PcId.Length >= 8 && r.Saves >= 1, "the pc id is made and saved at start");

            r = new CtlRig();
            r.Plat.IsBattery = true;
            r.Start();
            T.Eq(r.Api.Count("heartbeat"), 1, "a signed-in start sends a heartbeat at once");
            T.Eq(r.Api.LastPcId + "|" + r.Api.LastName + "|" + r.Api.LastVersion + "|" + r.Api.LastGpu + "|" + r.Api.LastMode, "0123456789abcdef|WAR-PC|0.1.0|NVIDIA GeForce GTX 970|Ask", "heartbeat carries pc id, name, version, gpu and mode");
            T.Ok(r.Api.LastState.OnBattery && !r.Api.LastState.GameRunning && !r.Api.LastState.Fullscreen && !r.Api.LastState.Busy && !r.Api.LastState.Paused, "heartbeat carries the PC's state");
            T.Eq(r.Api.Token, "tok-0", "the saved token is used");
            T.Eq(r.Ui.Status, "Ready (mode: Ask)", "status: ready");
            r.Plat.IsGame = true; r.Plat.IsFullscreen = true;
            r.Beat();
            T.Ok(r.Api.LastState.GameRunning && r.Api.LastState.Fullscreen, "heartbeat state follows the PC");
        }

        static void SignIn()
        {
            var r = new CtlRig(signedIn: false);
            var ok = Util.Wait(r.C.SignInAsync(" helix ", "pw"));
            T.Ok(ok.Ok, "sign-in works");
            T.Eq(string.Join(",", r.Api.Calls.Take(2).Select(c => c.Split(' ')[0])), "login,heartbeat", "sign-in is the team login, then a heartbeat (no separate team check: the login does it)");
            T.Eq(r.Api.LastLoginUser + "|" + r.Api.LastLoginPassword + "|" + r.Api.LastLoginPcId + "|" + r.Api.LastLoginPcName, "helix|pw|" + r.Settings.PcId + "|WAR-PC", "the login carries the trimmed name, the password, this PC's id and name");
            T.Ok(r.Settings.PcId.Length >= 8, "the pc id exists before the login");
            T.Ok(r.Settings.Token == "tok-1" && r.Api.Token == "tok-1" && r.Settings.Username == "Helix", "the token is kept, and the account's own spelling of the name");
            T.Ok(r.C.SignedIn && r.Saves > 0, "signed in and saved");
            T.Ok(!r.Settings.ToJson(new FakeProtector()).Contains("\"pw\"") && !r.Settings.ToJson(new FakeProtector()).ToLowerInvariant().Contains("password"), "the password is not kept anywhere");

            r = new CtlRig(signedIn: false);
            r.Api.Login = () => FakeApi.Err(401, "bad_login", "Invalid username or password.");
            var bad = Util.Wait(r.C.SignInAsync("helix", "nope"));
            T.Ok(!bad.Ok && bad.Message == "Invalid username or password." && !bad.NotTeam, "a wrong password shows the server's words");
            T.Ok(r.Settings.Token == "" && !r.C.SignedIn && !r.C.Stopped && r.Api.Count("heartbeat") == 0, "nothing is kept after a wrong password, and the app does not stop");

            r = new CtlRig(signedIn: false);
            var empty = Util.Wait(r.C.SignInAsync("", "x"));
            T.Ok(!empty.Ok && empty.Message.Length > 0 && r.Api.Count("login") == 0, "empty fields are refused without asking the server");

            r = new CtlRig(signedIn: false);
            r.Api.Login = () => FakeApi.NetErr();
            var net = Util.Wait(r.C.SignInAsync("helix", "x"));
            T.Ok(!net.Ok && net.Network && net.Message.Contains("Could not reach the server"), "no connection is told as it is");

            r = new CtlRig(signedIn: false);
            r.Api.Login = () => FakeApi.Err(403, "not_team", "This account is not on the team.");
            var nt = Util.Wait(r.C.SignInAsync("someone", "pw"));
            T.Ok(!nt.Ok && nt.NotTeam && nt.Message == "This account is not on the team.", "403 not_team: this account is not on the team");
            T.Ok(r.Settings.Token == "" && r.Api.Token == "" && !r.C.SignedIn, "nothing is kept for an account that is not on the team");
            T.Ok(r.C.Stopped, "and the app stops");
            int calls = r.Api.Calls.Count;
            r.Beat(); r.Eval();
            T.Eq(r.Api.Calls.Count, calls, "a stopped app sends nothing more");

            r = new CtlRig(signedIn: false);
            r.Api.Login = () => FakeApi.Ok(new Dictionary<string, object> { { "token", "tok-9" } });
            Util.Wait(r.C.SignInAsync("helix", "pw"));
            T.Eq(r.Settings.Username, "helix", "without a name in the answer the typed name is kept");
        }

        static void AskMode()
        {
            var r = new CtlRig();
            r.Start();
            r.Offer();
            T.Eq(r.C.CurrentOffer.Id, "job000000001", "the offer is taken");
            r.Eval();
            T.Ok(r.Ui.BoxVisible && r.Ui.Shown.Count == 1, "mode ask: the box is shown");
            T.Eq(r.Ui.Shown[0].Text, "Screenshots of a change, about 1 minute", "the box says what it is and how heavy");
            T.Eq(r.LastCountdown, "Runs by itself in 5:00", "and counts down from 5 minutes");
            T.Eq(r.Ui.Status, "Job offered: Screenshots of a change, about 1 minute", "status: offered");
            r.Advance(2); r.Eval();
            T.Eq(r.LastCountdown, "Runs by itself in 3:00", "the countdown runs");
            T.Eq(r.Ran, 0, "nothing runs while the box waits");
            r.Advance(2.99); r.Eval();
            T.Eq(r.Ran, 0, "still waiting at 4:59");
            r.Advance(0.02); r.Eval();
            T.Eq(r.Ran, 1, "after 5 minutes without an answer the job runs by itself");
            T.Ok(!r.Ui.BoxVisible, "the box is gone");
            T.Eq(r.Api.Count("claim"), 1, "the job was claimed");
            T.Eq(r.Runner.LastPlan.Presets.Count, 2, "the runner got the checked plan");
            T.Ok(r.Ui.Status.StartsWith("Last job: 1 picture(s) uploaded"), "status after a job: " + r.Ui.Status);
            T.Ok(!r.C.IsBusy && r.C.CurrentOffer == null, "idle again, offer cleared");

            // the offer vanishes from the server while the box is up
            r = new CtlRig();
            r.Start(); r.Offer(); r.Eval();
            T.Ok(r.Ui.BoxVisible, "box up");
            r.Api.Heartbeat = () => FakeApi.Ok(new Dictionary<string, object> { { "offer", null } });
            r.Beat();
            T.Ok(!r.Ui.BoxVisible && r.C.CurrentOffer == null, "an offer another PC took makes the box go away");
            T.Eq(r.Ran, 0, "and nothing runs");

            // a different offer replaces the old one
            r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval();
            r.Advance(3);
            r.Offer("job000000002"); r.Eval();
            T.Eq(r.C.CurrentOffer.Id, "job000000002", "a newer offer replaces the old");
            T.Eq(r.LastCountdown, "Runs by itself in 5:00", "and starts its own 5 minutes");
        }

        static void Answers()
        {
            var r = new CtlRig();
            r.Start(); r.Offer(); r.Eval();
            Util.Wait(r.C.AnswerAsync(OfferAnswer.Yes));
            T.Eq(r.Ran, 1, "Run now runs at once");
            T.Eq(r.Api.Count("claim"), 1, "and claims the job");

            r = new CtlRig();
            r.Start(); r.Offer(); r.Eval();
            Util.Wait(r.C.AnswerAsync(OfferAnswer.NotNow));
            T.Eq(r.Api.Declines.Count, 0, "Not now refuses nothing on the server (Helix 2026-10-19: it is not a no for good)");
            T.Ok(!r.Ui.BoxVisible && r.C.CurrentOffer == null && r.Ran == 0, "the box goes and nothing runs");
            r.Beat(); r.Eval();
            T.Ok(r.C.CurrentOffer == null && r.Api.Declines.Count == 0, "the server offering the same job again is ignored for a while");
            r.Advance(29); r.Beat(); r.Eval();
            T.Ok(r.C.CurrentOffer == null, "still ignored after 29 minutes");
            r.Advance(2); r.Beat(); r.Eval();
            T.Ok(r.C.CurrentOffer != null && r.Ui.BoxVisible, "asked again after 30 minutes if the job is still waiting");

            r = new CtlRig();
            r.Start(); r.Offer(); r.Eval();
            Util.Wait(r.C.AnswerAsync(OfferAnswer.Pause));
            T.Eq(r.Settings.PausedUntilUtc, r.Now.AddHours(2), "Pause 2 hours pauses until two hours from now");
            T.Ok(r.C.IsPaused && r.Saves > 0, "paused and saved");
            T.Eq(string.Join(",", r.Api.Declines), "job000000001:paused", "the job is declined with paused");
            T.Ok(!r.Ui.BoxVisible, "the box goes");
            r.Eval(); r.Eval(); r.Beat(); r.Eval();
            T.Eq(r.Api.Declines.Count, 1, "a pause declines a job once, not every second");
            T.Ok(r.Api.LastState.Paused, "heartbeat says paused");
            T.Ok(r.Ui.Status.StartsWith("Paused until"), "status: paused");
            r.Advance(61); r.Eval();
            T.Ok(!r.Ui.BoxVisible && r.Ran == 0, "an hour later it is still paused");
            r.Advance(60); r.Beat(); r.Eval();
            T.Ok(r.Ui.BoxVisible && !r.C.IsPaused, "after 2 hours the same job is asked about again");
            T.Ok(!r.Api.LastState.Paused, "and the heartbeat says so");
        }

        static void Exceptions()
        {
            // full screen
            var r = new CtlRig();
            r.Start(); r.Plat.IsFullscreen = true; r.Offer(); r.Eval();
            T.Ok(!r.Ui.BoxVisible && r.Ui.Shown.Count == 0, "full screen: the box is not shown");
            T.Eq(r.Ui.Status, "Job waiting: a full-screen app is open", "status says why it waits");
            r.Advance(30); r.Eval();
            T.Eq(r.Ran, 0, "an unanswered job does not run through a full-screen app, however long");
            r.Plat.IsFullscreen = false; r.Eval();
            T.Ok(r.Ui.BoxVisible, "when the full-screen app ends, the box is shown");
            T.Eq(r.LastCountdown, "Runs by itself in 5:00", "with a fresh 5 minutes");
            r.Advance(4); r.Eval();
            T.Eq(r.Ran, 0, "not yet");
            r.Plat.IsFullscreen = true; r.Eval();
            T.Ok(!r.Ui.BoxVisible, "a full-screen app that starts hides the box");
            r.Advance(10); r.Eval();
            T.Eq(r.Ran, 0, "and nothing runs");
            r.Plat.IsFullscreen = false; r.Eval();
            T.Eq(r.LastCountdown, "Runs by itself in 5:00", "the wait did not use up the 5 minutes");

            // Death Muffin open
            r = new CtlRig();
            r.Start(); r.Plat.IsGame = true; r.Offer(); r.Eval(); r.Advance(60); r.Eval();
            T.Ok(r.Ran == 0 && !r.Ui.BoxVisible, "Death Muffin open: no box and no run");
            T.Eq(r.Ui.Status, "Job waiting: Death Muffin is open", "status says Death Muffin is open");
            r.Plat.IsGame = false; r.Eval();
            T.Ok(r.Ui.BoxVisible, "the box appears when the game closes");

            // battery
            r = new CtlRig();
            r.Start(); r.Plat.IsBattery = true; r.Offer(); r.Eval(); r.Advance(60); r.Eval();
            T.Ok(r.Ran == 0 && !r.Ui.BoxVisible, "battery: no box and no run");
            T.Eq(r.Ui.Status, "Job waiting: this PC is on battery", "status says battery");

            // a yes overrides every exception
            r = new CtlRig();
            r.Start(); r.Plat.IsFullscreen = true; r.Plat.IsGame = true; r.Plat.IsBattery = true; r.Offer(); r.Eval();
            Util.Wait(r.C.AnswerAsync(OfferAnswer.Yes));
            T.Eq(r.Ran, 1, "a yes (the tray's Run now) runs through the exceptions");

            // the box was up when the game started
            r = new CtlRig();
            r.Start(); r.Offer(); r.Eval();
            T.Ok(r.Ui.BoxVisible, "box up");
            r.Plat.IsGame = true; r.Eval();
            T.Ok(!r.Ui.BoxVisible, "the box is taken down when the player starts Death Muffin");
        }

        static void OtherModes()
        {
            var r = new CtlRig(mode: OfferMode.Auto);
            r.Start(); r.Offer(); r.Eval();
            T.Eq(r.Ran, 1, "auto: runs without asking");
            T.Eq(r.Ui.Shown.Count, 0, "auto: no box");

            r = new CtlRig(mode: OfferMode.Auto);
            r.Start(); r.Plat.IsGame = true; r.Offer(); r.Eval();
            T.Eq(r.Ran, 0, "auto: still waits while Death Muffin is open");
            r.Plat.IsGame = false; r.Eval();
            T.Eq(r.Ran, 1, "auto: runs when it closes");

            r = new CtlRig(mode: OfferMode.Auto);
            r.Start(); r.Plat.IsBattery = true; r.Offer(); r.Eval();
            T.Eq(r.Ran, 0, "auto: waits on battery");

            r = new CtlRig(mode: OfferMode.Yes);
            r.Start(); r.Offer(); r.Eval(); r.Advance(60); r.Eval();
            T.Ok(r.Ran == 0 && r.Ui.BoxVisible, "yes: never runs by itself, the box stays");
            T.Eq(r.LastCountdown, "Runs when you say yes", "yes: the box says so");
            Util.Wait(r.C.AnswerAsync(OfferAnswer.Yes));
            T.Eq(r.Ran, 1, "yes: runs on a yes");

            // changing the mode applies to the offer in hand and goes to the server
            r = new CtlRig();
            r.Start(); r.Offer(); r.Eval();
            int saves = r.Saves;
            Util.Wait(r.C.SetModeAsync(OfferMode.Auto));
            T.Ok(r.Settings.Mode == OfferMode.Auto && r.Saves > saves, "the mode is saved");
            T.Eq(r.Api.LastMode, OfferMode.Auto, "the server hears the new mode with a heartbeat at once");
            T.Eq(r.Ran, 1, "an offer in hand runs under the new mode");
            r = new CtlRig(mode: OfferMode.Auto);
            r.Start(); r.Plat.IsGame = true; r.Offer(); r.Eval();
            Util.Wait(r.C.SetModeAsync(OfferMode.Yes));
            T.Eq(r.Api.LastMode, OfferMode.Yes, "mode yes is sent");
        }

        /// <summary>Helix 2026-10-19: the tray has no Run now (a job runs only from the box); Show jobs brings the box back, and Not now puts the jobs off for 30 minutes without refusing them.</summary>
        static void ShowJobsAndPause()
        {
            var r = new CtlRig();
            r.Start();
            Util.Wait(r.C.ShowJobsAsync());
            T.Ok(r.Ran == 0 && r.Ui.Notices.Any(n => n.StartsWith("No jobs")) && r.C.JobsAvailable == 0, "Show jobs with no job says so");

            r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval();
            T.Ok(r.Ui.BoxVisible && r.C.JobsAvailable == 1, "a job: the box");
            Util.Wait(r.C.AnswerAsync(OfferAnswer.NotNow));
            T.Ok(!r.Ui.BoxVisible && r.Api.Declines.Count == 0 && r.C.JobsAvailable == 1, "Not now hides the box and refuses nothing: the job stays this PC's to take");
            r.Advance(10); r.Beat(); r.Eval();
            T.Ok(!r.Ui.BoxVisible && r.Ran == 0, "the box stays away");
            Util.Wait(r.C.ShowJobsAsync());
            T.Ok(r.Ui.BoxVisible && r.Ran == 0 && r.LastCountdown == "Runs by itself in 5:00", "Show jobs brings it back with its own 5 minutes, and runs nothing at once");
            r.Advance(5); r.Eval();
            T.Eq(r.Ran, 1, "the countdown runs it");

            r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval();
            Util.Wait(r.C.AnswerAsync(OfferAnswer.NotNow));
            r.Advance(31); r.Beat(); r.Eval();
            T.Ok(r.Ui.BoxVisible && r.Ran == 0, "after 30 minutes the box asks again");

            r = new CtlRig();
            r.Start();
            Util.Wait(r.C.TogglePauseAsync());
            T.Ok(r.C.IsPaused && r.Settings.PausedUntilUtc == r.Now.AddHours(2) && r.Api.LastState.Paused, "Pause 2 hours from the tray");
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000001");
            r.Beat(); r.Eval();
            T.Ok(r.Ran == 0 && r.Api.Declines.SequenceEqual(new[] { "job000000001:paused" }), "a paused PC declines");
            Util.Wait(r.C.ShowJobsAsync());
            T.Ok(!r.C.IsPaused && r.Ui.BoxVisible && r.Ran == 0, "Show jobs ends the pause and asks");

            r = new CtlRig();
            r.Start();
            Util.Wait(r.C.TogglePauseAsync());
            Util.Wait(r.C.TogglePauseAsync());
            T.Ok(!r.C.IsPaused && r.Settings.PausedUntilUtc == DateTime.MinValue && !r.Api.LastState.Paused, "Resume ends the pause");
        }

        static void JobProblems()
        {
            // another PC got it
            var r = new CtlRig(mode: OfferMode.Auto);
            r.Start();
            r.Api.Claim = id => FakeApi.Err(409, "taken", "Another PC took this job.");
            r.Offer(); r.Eval();
            T.Ok(r.Ran == 0 && r.C.CurrentOffer == null && r.Ui.Status == "Another team PC took the job" && !r.C.IsBusy, "a job another PC claimed is let go");
            T.Eq(r.Api.Count("fail"), 0, "and is not failed");

            // a payload the app refuses
            r = new CtlRig(mode: OfferMode.Auto);
            r.Start();
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "shots" }, { "title", "t" }, { "payload", Program.ValidPayload() } });
            var bad = Program.ValidPayload();
            ((List<object>)bad["files"]).Add(Program.File_("../../evil.dll"));
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "shots" }, { "title", "t" }, { "payload", bad } });
            r.Offer(); r.Eval();
            T.Eq(r.Ran, 0, "a payload with an unsafe file name never reaches the runner");
            T.Eq(r.Api.Count("fail"), 1, "it is failed instead");
            T.Has(r.Api.FailError, "not allowed", "with a readable reason");
            T.Ok(r.Ui.Notices.Any(n => n.StartsWith("A job was refused")), "and the person is told");
            T.Ok(!r.C.IsBusy, "not busy afterwards");

            // a kind this version cannot run
            r = new CtlRig(mode: OfferMode.Auto);
            r.Start(); r.Offer("job000000007", "benchmark"); r.Eval(); r.Eval();
            T.Ok(r.Ran == 0 && r.Api.Count("claim") == 0, "a job kind this version cannot run is not claimed");
            T.Eq(r.Api.Declines.Count, 1, "it is declined once");
            T.Has(r.Ui.Status, "newer team app", "the status says a newer app is needed");

            // a claim the server answers oddly
            r = new CtlRig(mode: OfferMode.Auto);
            r.Start();
            r.Api.Claim = id => FakeApi.Err(500, "", "Something broke on the server.");
            r.Offer(); r.Eval();
            T.Ok(r.Ran == 0 && r.Ui.Status == "Something broke on the server." && !r.C.IsBusy, "a failed claim shows the server's words");
            r.Beat(); r.Eval();
            T.Eq(r.Api.Count("claim"), 1, "and is not retried every second");

            // a job that fails
            r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Result = new RunResult { Ok = false, Error = "The game stopped with code 1 on Low before it took every picture." };
            r.Start(); r.Offer(); r.Eval();
            T.Ok(r.Ui.Status == "Last job failed: The game stopped with code 1 on Low before it took every picture." && r.Ui.Notices.Any(n => n.StartsWith("A job failed")), "a failed job is shown in plain words");

            // a bug in the runner: the job is failed so the server does not wait for it, and the app goes on
            r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Throw = new InvalidOperationException("boom");
            r.Start(); r.Offer(); r.Eval();
            T.Ok(!r.C.IsBusy && r.Api.Count("fail") == 1 && r.Api.FailError.Contains("unexpected error") && r.Api.FailError.Contains("boom"), "an unexpected error in the runner fails the job and frees the app");
            T.Has(r.Ui.Status, "Last job failed", "and the status says so");

            // the next job after one
            r = new CtlRig(mode: OfferMode.Auto);
            r.Start(); r.Offer("job000000001"); r.Eval();
            r.Offer("job000000002"); r.Eval();
            T.Eq(string.Join(",", r.Runner.Ran), "job000000001,job000000002", "one job after another");
        }

        /// <summary>The PC is left alone: every second the controller reads it, and a benchmark that waits is claimed once the minute of quiet is over.</summary>
        static void Settle(CtlRig r, int seconds = 70) { for (int i = 0; i < seconds; i++) r.Eval(); }

        static void BenchJobs()
        {
            Func<string, ApiResult> benchClaim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "bench" }, { "title", "Benchmark of the new release" }, { "payload", BenchTests.ValidPayload() } });

            // the box: what it is, how long, and what it asks of the PC
            var r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000009", "bench", "Benchmark of the new release", 360);
            r.Beat(); r.Eval();
            T.Ok(r.Ui.BoxVisible && r.Ui.Shown.Count == 1, "a benchmark is offered in the box too");
            T.Eq(r.Ui.Shown[0].Text, "Benchmark of the new release, about 6 minutes", "the box says what it is and how long");
            T.Eq(r.Ui.Shown[0].Note, "It starts once other programs have used little of the processor for a minute, takes the whole screen and runs at normal priority. A busy processor restarts it.", "and says it starts once the PC has been left alone, takes the whole screen, runs at normal priority and that a busy processor restarts it");
            T.Eq(r.LastCountdown, "Runs by itself in 5:00", "with the usual countdown");
            r.Offer("job000000010", "shots"); r.Eval();
            T.Eq(r.Ui.Shown.Last().Note, "", "a screenshot job's box has no note");
            T.Eq(TeamLogic.OfferNote("shots"), "", "no note for shots");
            T.Ok(TeamLogic.OfferNote("bench").Contains("little of the processor for a minute") && TeamLogic.OfferNote("bench").Contains("normal priority") && TeamLogic.OfferNote("bench").Contains("restarts"), "the note's words");

            // the same exceptions as for every job: a benchmark waits for what is in the way
            r = new CtlRig(mode: OfferMode.Auto);
            r.Start();
            r.Plat.IsGame = true;
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000011", "bench", "Benchmark of the new release", 360);
            r.Beat(); r.Eval();
            T.Ok(r.Ran == 0 && !r.Ui.BoxVisible && r.Ui.Status == "Job waiting: Death Muffin is open", "a benchmark waits while Death Muffin is open");

            // claimed, checked, run: the runner gets a bench plan that knows when the job's life ends
            r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Result = new RunResult { Ok = true, Runs = 2 };
            r.Api.Claim = benchClaim;
            r.Start();
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000012", "bench", "Benchmark of the new release", 360);
            r.Beat(); r.Eval();
            T.Ok(r.Ran == 0 && r.Api.Count("claim") == 0 && r.C.WaitingBench != null && r.C.WaitingBench.Id == "job000000012" && !r.C.IsBusy, "a benchmark that is said yes to is not claimed: it waits, and the PC is not busy");
            T.Eq(r.Ui.Status, "Benchmark waiting for a quiet PC", "the tray says so");
            Settle(r);
            T.Eq(r.Ran, 1, "a bench job is run once the PC has been left alone");
            T.Ok(r.C.WaitingBench == null && r.Api.Count("claim") == 1, "it was claimed then, and is no longer waiting");
            T.Ok(r.Runner.LastPlan != null && r.Runner.LastPlan.Kind == "bench" && r.Runner.LastPlan.Setups.Count == 2, "with a bench plan of two setups");
            T.Eq(r.Runner.LastPlan.ExpiresAtUtc, (DateTime?)new DateTime(2026, 10, 19, 13, 0, 0, DateTimeKind.Utc), "and the offer's expiry as the end of its life");
            T.Ok(r.Ui.Status.StartsWith("Last job: 2 benchmark run(s) sent at "), "the status says what was sent: " + r.Ui.Status);
            T.Eq(r.Api.Count("fail"), 0, "nothing failed");

            // a failed benchmark: the readable reason is shown
            r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Result = new RunResult { Ok = false, Error = "The PC never went quiet for long enough: Death Muffin is open." };
            r.Api.Claim = benchClaim;
            r.Start();
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000013", "bench"); r.Beat(); r.Eval(); Settle(r);
            T.Ok(r.Ui.Status == "Last job failed: The PC never went quiet for long enough: Death Muffin is open." && r.Ui.Notices.Any(n => n.StartsWith("A job failed")), "a benchmark that failed says why");

            // payloads the app refuses never reach the runner
            r = new CtlRig(mode: OfferMode.Auto);
            var bad = BenchTests.ValidPayload();
            ((List<object>)bad["setups"]).Add(BenchTests.Setup(room: "../../x"));
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "bench" }, { "title", "t" }, { "payload", bad } });
            r.Start();
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000014", "bench"); r.Beat(); r.Eval(); Settle(r);
            T.Ok(r.Ran == 0 && r.Api.Count("fail") == 1 && r.Api.FailError.Contains("room that is not allowed"), "a setup with an unsafe room is refused with a readable reason: " + r.Api.FailError);
            T.Ok(r.Ui.Notices.Any(n => n.StartsWith("A job was refused")) && !r.C.IsBusy, "the person is told, and the app is free");

            r = new CtlRig(mode: OfferMode.Auto);
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "bench" }, { "title", "t" }, { "payload", Program.ValidPayload() } });
            r.Start();
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000015", "bench"); r.Beat(); r.Eval(); Settle(r);
            T.Ok(r.Ran == 0 && r.Api.FailError.Contains("DeathMuffin.exe"), "a shots payload under the kind bench is refused: " + r.Api.FailError);

            // a kind that changed between the offer and the claim
            r = new CtlRig(mode: OfferMode.Auto);
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "benchmark" }, { "title", "t" }, { "payload", BenchTests.ValidPayload() } });
            r.Start();
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000016", "bench"); r.Beat(); r.Eval(); Settle(r);
            T.Ok(r.Ran == 0 && r.Api.FailError == "This version of the team app cannot run benchmark jobs.", "a claimed job of a kind this version does not run is failed in plain words");

            // a shots job also gets its expiry (the plan carries it for every kind)
            r = new CtlRig(mode: OfferMode.Auto);
            r.Start(); r.Offer(); r.Eval();
            T.Ok(r.Runner.LastPlan != null && r.Runner.LastPlan.Kind == "shots" && r.Runner.LastPlan.ExpiresAtUtc.HasValue, "a shots job still runs as a shots job");
            T.Ok(r.Ui.Status.StartsWith("Last job: 1 picture(s) uploaded at "), "and says so in pictures");
        }

        /// <summary>A benchmark asks first, like every job: the same box, the same modes, the same exceptions (TeamLogic.Decide), the same Not now and Pause. Its quiet wait comes only after the yes.</summary>
        static void BenchOffersLikeAnyJob()
        {
            Func<OfferMode, CtlRig> rig = mode =>
            {
                var r = new CtlRig(mode: mode);
                r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "bench" }, { "title", "Benchmark of the new release" }, { "payload", BenchTests.ValidPayload() } });
                r.Start();
                r.Api.Heartbeat = () => FakeApi.OfferReply("job000000001", "bench", "Benchmark of the new release", 360);
                r.Beat();
                return r;
            };

            // Ask: the box, a countdown, and it runs by itself after 5 minutes
            var b = rig(OfferMode.Ask);
            b.Eval();
            T.Ok(b.Ui.BoxVisible && b.Ran == 0 && b.Api.Count("claim") == 0, "mode ask: the box is shown and nothing is claimed before an answer");
            T.Eq(b.LastCountdown, "Runs by itself in 5:00", "with its countdown");
            b.Advance(4.9); b.Eval();
            T.Ok(b.Ran == 0 && b.Ui.BoxVisible, "still asking at 4:54");
            b.Advance(0.2); b.Eval();
            T.Ok(b.Ran == 0 && b.C.WaitingBench != null && !b.Ui.BoxVisible, "after 5 minutes without an answer it is accepted by itself (the box goes)");
            Settle(b);
            T.Ok(b.Ran == 1 && b.Runner.LastPlan.Kind == "bench" && b.Api.Count("claim") == 1, "and runs once the PC has been left alone");

            // ... unless a game, a full-screen app or the battery is in the way
            foreach (string what in new[] { "game", "fullscreen", "battery" })
            {
                b = rig(OfferMode.Ask);
                b.Plat.IsGame = what == "game"; b.Plat.IsFullscreen = what == "fullscreen"; b.Plat.IsBattery = what == "battery";
                b.Eval(); b.Advance(30); b.Eval();
                T.Ok(b.Ran == 0 && !b.Ui.BoxVisible && b.Api.Count("claim") == 0 && b.Ui.Status.StartsWith("Job waiting:"), "mode ask: a benchmark waits while " + what + " (no box, no run)");
                b.Plat.IsGame = b.Plat.IsFullscreen = b.Plat.IsBattery = false;
                b.Eval();
                T.Ok(b.Ui.BoxVisible && b.Ran == 0, "and is asked about once that ends");
            }

            // Run now in the box, Not now, Pause 2 hours
            b = rig(OfferMode.Ask);
            b.Eval();
            Util.Wait(b.C.AnswerAsync(OfferAnswer.Yes));
            T.Ok(b.Ran == 0 && b.C.WaitingBench != null && b.Api.Count("claim") == 0, "Run now accepts the benchmark: it waits for a quiet PC, unclaimed");
            Settle(b);
            T.Ok(b.Ran == 1 && b.Runner.LastPlan.Kind == "bench", "and then runs it");

            b = rig(OfferMode.Ask);
            b.Eval();
            Util.Wait(b.C.AnswerAsync(OfferAnswer.NotNow));
            T.Eq(b.Api.Declines.Count, 0, "Not now refuses a benchmark nowhere either");
            T.Ok(!b.Ui.BoxVisible && b.C.CurrentOffer == null && b.Ran == 0 && b.Api.Count("claim") == 0, "the box goes and nothing runs");
            b.Beat(); b.Eval();
            T.Ok(b.C.CurrentOffer == null && b.Api.Declines.Count == 0, "the same benchmark offered again is ignored for 30 minutes");
            b.Advance(31); b.Beat(); b.Eval();
            T.Ok(b.Ui.BoxVisible, "and asked about again after that");

            b = rig(OfferMode.Ask);
            b.Eval();
            Util.Wait(b.C.AnswerAsync(OfferAnswer.Pause));
            T.Ok(b.C.IsPaused && b.Settings.PausedUntilUtc == b.Now.AddHours(2), "Pause 2 hours pauses the PC");
            T.Eq(string.Join(",", b.Api.Declines), "job000000001:paused", "the benchmark is declined with paused");
            T.Ok(!b.Ui.BoxVisible && b.Ran == 0, "the box goes and nothing runs");
            b.Advance(121); b.Beat(); b.Eval();
            T.Ok(b.Ui.BoxVisible && !b.C.IsPaused, "after the pause the benchmark is asked about again");

            // Run without asking: no box, the same exceptions
            b = rig(OfferMode.Auto);
            b.Eval();
            T.Ok(b.Ran == 0 && b.C.WaitingBench != null && b.Ui.Shown.Count == 0, "mode run without asking: no box, it is accepted");
            Settle(b);
            T.Ok(b.Ran == 1, "and runs once the PC is quiet");
            b = rig(OfferMode.Auto);
            b.Plat.IsBattery = true;
            b.Eval();
            T.Ok(b.Ran == 0 && b.Ui.Shown.Count == 0, "and waits on battery");

            // Only on a yes: the box, for as long as it takes
            b = rig(OfferMode.Yes);
            b.Eval(); b.Advance(600); b.Eval();
            T.Ok(b.Ran == 0 && b.Ui.BoxVisible, "mode only on a yes: it waits for the answer");
            T.Eq(b.LastCountdown, "Runs when you say yes", "and says so");
            Util.Wait(b.C.AnswerAsync(OfferAnswer.Yes));
            Settle(b);
            T.Eq(b.Ran, 1, "a yes runs it");

            // the tray's Show jobs, then the box's yes
            b = rig(OfferMode.Yes);
            Util.Wait(b.C.ShowJobsAsync());
            T.Ok(b.Ran == 0 && b.Ui.BoxVisible, "Show jobs asks about the benchmark");
            Util.Wait(b.C.AnswerAsync(OfferAnswer.Yes));
            T.Ok(b.Ran == 0 && b.C.WaitingBench != null, "a yes accepts it as a waiting benchmark");
            Settle(b);
            T.Ok(b.Ran == 1 && b.Runner.LastPlan.Kind == "bench", "and it runs once the PC is quiet");
        }

        /// <summary>A rig whose server offers what <c>Offered</c> says (a job id and kind; null for nothing), with a screenshot job's payload for ids starting "shots" and a benchmark's for the others.</summary>
        sealed class WaitRig
        {
            public readonly CtlRig R;
            public string Id, Kind;

            public WaitRig(OfferMode mode)
            {
                R = new CtlRig(mode: mode);
                R.Runner.Result = new RunResult { Ok = true, Runs = 2, Files = new List<string> { "low_a.png" } };
                R.Api.Claim = id => id.StartsWith("shots")
                    ? FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "shots" }, { "title", "t" }, { "payload", Program.ValidPayload() } })
                    : FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "bench" }, { "title", "t" }, { "payload", BenchTests.ValidPayload() } });
                R.Api.Heartbeat = () => Id == null
                    ? FakeApi.Ok(new Dictionary<string, object> { { "serverTime", "x" }, { "offer", null } })
                    : FakeApi.OfferReply(Id, Kind, Kind == "bench" ? "Benchmark of the new release" : "Screenshots of a change", Kind == "bench" ? 360 : 60);
                R.Start();
            }

            /// <summary>The server's next heartbeat offers this job (null: nothing).</summary>
            public void Offers(string id, string kind = null) { Id = id; Kind = kind ?? (id != null && id.StartsWith("shots") ? "shots" : "bench"); R.Beat(); }
            public List<string> Claims { get { return R.Api.Calls.Where(c => c.StartsWith("claim")).ToList(); } }
        }

        /// <summary>An accepted benchmark is not claimed and does not make the PC busy: screenshot jobs run in the meantime, and the benchmark resumes after them.</summary>
        static void BenchWaitsUnclaimed()
        {
            var w = new WaitRig(OfferMode.Auto);
            var r = w.R;
            w.Offers("bench0000001");
            r.Eval();
            T.Ok(r.C.WaitingBench != null && r.C.WaitingBench.Id == "bench0000001" && r.Ran == 0 && w.Claims.Count == 0, "the benchmark is accepted and kept: nothing is claimed");
            T.Ok(!r.C.IsBusy && r.Ui.Status == CtlStatus.Waiting, "the PC is not busy and the tray says the benchmark waits");
            r.Beat();
            T.Ok(!r.Api.LastState.Busy, "the heartbeat says the PC is not busy");
            w.Offers("bench0000001"); r.Eval(); r.Beat();
            T.Ok(!r.Ui.BoxVisible && r.Api.Declines.Count == 0 && r.C.CurrentOffer == null && r.C.WaitingBench != null, "the server offering the same benchmark again asks nothing and declines nothing");
            Settle(r, 30);
            T.Ok(r.Ran == 0 && w.Claims.Count == 0, "half a minute of quiet is not enough");
            T.Ok(r.Probe.Reads > 25, "the PC is read while it waits");

            // a screenshot job is offered ahead of it: handled as usual
            r.Runner.Gate = new TaskCompletionSource<int>();
            w.Offers("shots0000001");
            Task running = r.C.EvaluateAsync();
            T.Ok(WaitFor(() => r.C.IsBusy && r.Runner.Ran.Count == 1), "the screenshot job runs");
            T.Eq(r.Runner.Ran[0], "shots0000001", "it is the first to run");
            T.Ok(r.C.WaitingBench != null && r.C.WaitingBench.Id == "bench0000001", "the benchmark is still waiting");
            T.Ok(r.Api.LastState.Busy == false, "(the last heartbeat was before the job)");
            r.Beat();
            T.Ok(r.Api.LastState.Busy, "busy while the screenshot job runs");

            // while it runs: the server offers the benchmark again, and the PC is not read for it
            w.Offers("bench0000001"); r.Beat();
            T.Eq(r.Api.Declines.Count, 0, "the waiting benchmark is not declined for being busy");
            int reads = r.Probe.Reads;
            Settle(r, 20);
            T.Eq(r.Probe.Reads, reads, "a waiting benchmark pauses: the PC is not read while a job runs");
            T.Eq(w.Claims.Count, 1, "and it is not claimed");

            // the screenshot job ends: the benchmark's minute starts over, then it is claimed and run
            r.Runner.Gate.SetResult(0);
            Util.Wait(running);
            T.Ok(!r.C.IsBusy && r.C.WaitingBench != null, "the screenshot job ends and the benchmark still waits");
            Settle(r, 40);
            T.Ok(r.Runner.Ran.Count == 1 && w.Claims.Count == 1, "its quiet minute starts over after the other job (40 s are not enough)");
            Settle(r, 40);
            T.Eq(string.Join(",", r.Runner.Ran), "shots0000001,bench0000001", "the benchmark then runs, after the screenshots");
            T.Eq(string.Join(",", w.Claims), "claim shots0000001,claim bench0000001", "and was claimed only then");
            T.Ok(r.Runner.LastPlan.Kind == "bench" && r.C.WaitingBench == null, "with a bench plan, and it no longer waits");
            T.Ok(r.Ui.Status.StartsWith("Last job: 2 benchmark run(s) sent"), "the status says what was sent: " + r.Ui.Status);

            // the next benchmark of the same PC goes the same way, and a PC that is not quiet never claims
            w = new WaitRig(OfferMode.Auto);
            r = w.R;
            r.Probe.Script = (n, t, pid) => { if (n < 100) r.Probe.LastInput = t; return new PcSample { CpuTotal = 3 }; };
            w.Offers("bench0000002"); r.Eval();
            Settle(r, 95);
            T.Ok(r.Ran == 1 && w.Claims.Count == 1, "someone at the keyboard: the benchmark does not wait for them (only the CPU counts, Helix 2026-10-19)");

            // not while a screenshot offer is waiting for an answer (mode only on a yes)
            w = new WaitRig(OfferMode.Yes);
            r = w.R;
            w.Offers("bench0000003"); r.Eval();
            Util.Wait(r.C.AnswerAsync(OfferAnswer.Yes));
            T.Ok(r.C.WaitingBench != null && r.Ran == 0, "mode only on a yes: the yes accepts the benchmark");
            w.Offers("shots0000002"); r.Eval();
            T.Ok(r.Ui.BoxVisible && r.C.CurrentOffer.Id == "shots0000002", "a screenshot job is asked about as usual while it waits");
            Settle(r, 80);
            T.Ok(r.Ran == 0 && w.Claims.Count == 0, "the benchmark is not claimed while the screenshot job's box is up");
            Util.Wait(r.C.AnswerAsync(OfferAnswer.NotNow));
            w.Offers("bench0000003");
            Settle(r, 75);
            T.Ok(r.Ran == 1 && r.Runner.LastPlan.Kind == "bench", "once the box is answered the benchmark goes on");

            // a benchmark offered while a job runs is not declined busy (it is queued for this PC alone, and a decline would end it)
            w = new WaitRig(OfferMode.Ask);
            r = w.R;
            r.Runner.Gate = new TaskCompletionSource<int>();
            w.Offers("shots0000003"); r.Eval();
            Task running2 = r.C.AnswerAsync(OfferAnswer.Yes);   // a yes: no AFK mode
            T.Ok(WaitFor(() => r.C.IsBusy), "a screenshot job runs");
            w.Offers("bench0000004"); r.Beat();
            T.Eq(r.Api.Declines.Count, 0, "a benchmark offered meanwhile is not declined busy");
            w.Offers("shots0000004"); r.Beat();
            T.Eq(string.Join(",", r.Api.Declines), "shots0000004:busy", "a second screenshot job still is");
            r.Runner.Gate.SetResult(0);
            Util.Wait(running2);
            w.Offers("bench0000004"); r.Eval();
            T.Ok(r.Ui.BoxVisible && r.C.CurrentOffer.Id == "bench0000004", "after it the benchmark is asked about");

            // the tray's Show jobs says a benchmark is waiting
            w = new WaitRig(OfferMode.Auto);
            r = w.R;
            w.Offers("bench0000005"); r.Eval();
            Util.Wait(r.C.ShowJobsAsync());
            T.Ok(r.Ui.Notices.Any(n => n.StartsWith("A benchmark is waiting")) && r.Ran == 0, "Show jobs with only a waiting benchmark says it starts once the PC is left alone");

            // the PC is read about once a second, not once per call
            w = new WaitRig(OfferMode.Auto);
            r = w.R;
            r.C.MinReadMs = 100000;
            w.Offers("bench0000006"); r.Eval();
            int before = r.Probe.Reads;
            r.Eval(); r.Eval(); r.Eval();
            T.Ok(r.Probe.Reads <= before + 1, "evaluating more often than the reading interval does not read the PC more often");
        }

        static void BenchWaitingEnds()
        {
            // the claim says the job is gone (taken, expired or cancelled): dropped, with the server's words
            var w = new WaitRig(OfferMode.Auto);
            var r = w.R;
            w.Offers("bench0000001"); r.Eval();
            r.Api.Claim = id => FakeApi.Err(409, "taken", "This job was cancelled.");
            Settle(r);
            T.Ok(r.C.WaitingBench == null && r.Ran == 0 && r.Api.Count("claim") == 1 && !r.C.IsBusy, "a benchmark that is gone when it is claimed is dropped");
            T.Eq(r.Ui.Status, "This job was cancelled.", "the status has the server's words");
            Settle(r, 10);
            T.Eq(r.Api.Count("claim"), 1, "and is not claimed again");
            T.Eq(r.Api.Count("fail"), 0, "nor failed");

            // the server stops offering it (nothing queued: cancelled or expired): dropped without asking
            w = new WaitRig(OfferMode.Auto);
            r = w.R;
            w.Offers("bench0000002"); r.Eval();
            T.Ok(r.C.WaitingBench != null, "accepted");
            w.Offers(null);
            T.Ok(r.C.WaitingBench == null && r.Ui.Status == "The benchmark is no longer available.", "a heartbeat that offers nothing means it is no longer queued");
            Settle(r);
            T.Ok(r.Ran == 0 && r.Api.Count("claim") == 0, "so it is never claimed");

            // ... but a screenshot job offered ahead of it does not
            w = new WaitRig(OfferMode.Ask);
            r = w.R;
            w.Offers("bench0000003"); r.Eval(); r.Advance(6); r.Eval();
            T.Ok(r.C.WaitingBench != null, "accepted (the box ran out)");
            w.Offers("shots0000001");
            T.Ok(r.C.WaitingBench != null && r.C.CurrentOffer.Id == "shots0000001", "a screenshot job offered ahead of it is no sign that it is gone");

            // another benchmark offered: the waiting one is gone (the oldest is offered first)
            w = new WaitRig(OfferMode.Ask);
            r = w.R;
            w.Offers("bench0000004"); r.Eval(); r.Advance(6); r.Eval();
            T.Ok(r.C.WaitingBench != null && r.C.WaitingBench.Id == "bench0000004", "accepted");
            w.Offers("bench0000005");
            T.Ok(r.C.WaitingBench == null && r.C.CurrentOffer != null && r.C.CurrentOffer.Id == "bench0000005", "another benchmark offered: the waiting one is no longer queued, the new one is asked about");

            // a claim that fails for a passing reason is tried again after 30 s, not dropped and not every second
            w = new WaitRig(OfferMode.Auto);
            r = w.R;
            w.Offers("bench0000006"); r.Eval();
            var good = r.Api.Claim;
            r.Api.Claim = id => FakeApi.Err(500, "", "Something broke on the server.");
            Settle(r);
            T.Ok(r.C.WaitingBench != null && r.Api.Count("claim") == 1 && r.Ran == 0 && !r.C.IsBusy, "a claim that failed leaves the benchmark waiting");
            T.Eq(r.Ui.Status, "Something broke on the server.", "and shows the server's words");
            Settle(r, 20);
            T.Eq(r.Api.Count("claim"), 1, "it is not claimed again every second");
            r.Api.Claim = good;
            r.Advance(0.6);
            Settle(r, 3);
            T.Ok(r.Api.Count("claim") == 2 && r.Ran == 1, "after 30 s it is tried again, and runs");

            // a pause holds it back; the end of the pause lets it go on
            w = new WaitRig(OfferMode.Auto);
            r = w.R;
            w.Offers("bench0000007"); r.Eval();
            Util.Wait(r.C.TogglePauseAsync());
            Settle(r, 80);
            T.Ok(r.Ran == 0 && r.Api.Count("claim") == 0 && r.C.WaitingBench != null, "a paused PC does not claim a waiting benchmark");
            T.Ok(r.Ui.Status.StartsWith("Paused until"), "the status says it is paused");
            r.Advance(121);
            w.Offers("bench0000007");
            Settle(r, 75);
            T.Ok(r.Ran == 1, "the benchmark goes on after the pause");

            // signing out forgets it
            w = new WaitRig(OfferMode.Auto);
            r = w.R;
            w.Offers("bench0000008"); r.Eval();
            Util.Wait(r.C.SignOutAsync());
            T.Ok(r.C.WaitingBench == null, "signing out forgets a waiting benchmark");
            Settle(r, 80);
            T.Eq(r.Api.Count("claim"), 0, "and nothing is claimed");
        }

        /// <summary>AFK mode (Helix's design): a box that runs out in mode ask means the person is away, so jobs run at once until they are back.</summary>
        static void AfkMode()
        {
            // the box's 5 minutes run out: the job runs by itself and AFK mode goes on
            var r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval();
            T.Ok(r.Ui.BoxVisible && !r.C.IsAfk && !r.Ui.Afk, "the first job's box waits as before, AFK mode off");
            r.Advance(4.9); r.Eval();
            T.Ok(r.Ran == 0 && !r.C.IsAfk, "not at 4:54");
            r.Advance(0.2); r.Eval();
            T.Ok(r.Ran == 1, "after 5 minutes without an answer the job runs by itself");
            T.Ok(r.C.IsAfk && r.Ui.Afk && r.Ui.AfkChanges.Count == 1, "and AFK mode is on (the notice is shown once)");
            T.Ok(r.Log.Any(l => l.StartsWith("AFK mode on")), "the app's log says so");
            r.Api.Heartbeat = () => FakeApi.Ok(new Dictionary<string, object> { { "serverTime", "x" }, { "offer", null } });
            r.Beat();
            T.Has(r.Ui.Status, "AFK mode", "the tray status says AFK mode");

            // the next offers run at once: no box, no wait (shots or a benchmark)
            int boxes = r.Ui.Shown.Count;
            r.Offer("job000000002"); r.Eval();
            T.Ok(r.Ran == 2 && r.Ui.Shown.Count == boxes && !r.Ui.BoxVisible, "in AFK mode the next job runs at once with no box");
            r.Offer("job000000003", "bench");
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "bench" }, { "title", "t" }, { "payload", BenchTests.ValidPayload() } });
            r.Eval();
            T.Ok(r.Ui.Shown.Count == boxes && r.C.WaitingBench != null && r.C.WaitingBench.Id == "job000000003", "a benchmark is accepted at once too, with no box");
            Settle(r);
            T.Ok(r.Ran == 3 && r.Runner.LastPlan.Kind == "bench", "and still waits for a quiet PC before it runs");
            T.Ok(r.C.IsAfk, "AFK mode is still on");

            // the button ends it: the next offer shows the box with its 5 minutes again
            r.C.EndAfk();
            T.Ok(!r.C.IsAfk && !r.Ui.Afk && r.Ui.AfkChanges.Last() == false, "the person pressing End AFK mode ends it (the notice goes)");
            r.Offer("job000000004"); r.Eval();
            T.Ok(r.Ui.BoxVisible && r.Ran == 3, "the next offer asks again");
            T.Eq(r.LastCountdown, "Runs by itself in 5:00", "with its 5 minutes");
            r.Advance(5.1); r.Eval();
            T.Ok(r.Ran == 4 && r.C.IsAfk, "and a box that runs out switches AFK mode on again");
            r.C.EndAfk(); r.C.EndAfk();
            T.Eq(r.Ui.AfkChanges.Count(c => !c), 2, "ending it twice changes nothing the second time");

            // Death Muffin started: they are back
            r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval(); r.Advance(5.1); r.Eval();
            T.Ok(r.C.IsAfk, "AFK mode is on");
            r.Plat.IsGame = true;
            r.Eval();
            T.Ok(!r.C.IsAfk && !r.Ui.Afk, "the player starting Death Muffin ends it");
            r.Plat.IsGame = false;
            r.Offer("job000000002"); r.Eval();
            T.Ok(r.Ui.BoxVisible && r.Ran == 1, "the next offer shows the box again");

            // a full-screen app comes up
            r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval(); r.Advance(5.1); r.Eval();
            r.Plat.IsFullscreen = true;
            r.Eval();
            T.Ok(!r.C.IsAfk, "a full-screen app coming up ends it");
            r.Plat.IsFullscreen = false;

            // ... also while a job runs (Death Muffin: the runner stops the job too); a full-screen reading is not trusted then
            r = new CtlRig();
            r.Runner.Gate = new TaskCompletionSource<int>();
            r.Start(); r.Offer("job000000001"); r.Eval();
            r.Advance(5.1);
            Task running = r.C.EvaluateAsync();
            T.Ok(WaitFor(() => r.C.IsBusy && r.C.IsAfk), "AFK mode is on while the job runs");
            r.Plat.IsFullscreen = true;
            r.Eval();
            T.Ok(r.C.IsAfk, "a job's own window may read as full screen on a small screen: that does not end AFK mode while it runs");
            r.Plat.IsFullscreen = false;
            r.Plat.IsGame = true;
            r.Eval();
            T.Ok(!r.C.IsAfk, "but the player starting Death Muffin does");
            r.Runner.Gate.SetResult(0);
            Util.Wait(running);

            // the existing waits still apply in AFK mode
            r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval(); r.Advance(5.1); r.Eval();
            r.Plat.IsBattery = true;
            r.Offer("job000000002"); r.Eval();
            T.Ok(r.Ran == 1 && r.C.IsAfk && !r.Ui.BoxVisible && r.Ui.Status.StartsWith("Job waiting:"), "on battery a job waits in AFK mode too (no box, no run)");
            r.Plat.IsBattery = false;
            r.Eval();
            T.Ok(r.Ran == 2, "and runs when the battery is no longer in the way");

            // a pause ends it
            r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval(); r.Advance(5.1); r.Eval();
            T.Ok(r.C.IsAfk, "AFK mode is on");
            Util.Wait(r.C.TogglePauseAsync());
            T.Ok(r.C.IsPaused && !r.C.IsAfk && !r.Ui.Afk, "Pause 2 hours ends AFK mode");
            Util.Wait(r.C.TogglePauseAsync());
            r.Offer("job000000002"); r.Eval();
            T.Ok(r.Ui.BoxVisible && r.Ran == 1, "after the pause the next offer shows the box");

            // the modes that do not ask or do not run by themselves never enter it
            var a = new CtlRig(mode: OfferMode.Auto);
            a.Start(); a.Offer("job000000001"); a.Eval(); a.Advance(10); a.Eval();
            T.Ok(a.Ran == 1 && !a.C.IsAfk && a.Ui.AfkChanges.Count == 0, "run without asking never enters AFK mode");
            var y = new CtlRig(mode: OfferMode.Yes);
            y.Start(); y.Offer("job000000001"); y.Eval(); y.Advance(60); y.Eval();
            T.Ok(y.Ran == 0 && !y.C.IsAfk, "only on a yes: waiting never enters it");
            Util.Wait(y.C.AnswerAsync(OfferAnswer.Yes));
            T.Ok(y.Ran == 1 && !y.C.IsAfk, "and neither does the yes");
            // a yes in mode ask (Run now) is a person at the PC
            r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval();
            Util.Wait(r.C.AnswerAsync(OfferAnswer.Yes));
            T.Ok(r.Ran == 1 && !r.C.IsAfk, "Run now in the box is not AFK");
            r.Offer("job000000002");
            Util.Wait(r.C.ShowJobsAsync());
            Util.Wait(r.C.AnswerAsync(OfferAnswer.Yes));
            T.Ok(r.Ran == 2 && !r.C.IsAfk, "nor is Show jobs then a yes");
            // a box that runs out while a game is open does not run, so it does not enter it either
            r = new CtlRig();
            r.Start(); r.Plat.IsGame = true; r.Offer("job000000001"); r.Eval(); r.Advance(10); r.Eval();
            T.Ok(r.Ran == 0 && !r.C.IsAfk, "a job that waits for the game to close does not start AFK mode");

            // changing to another mode ends it; a restart starts without it
            r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval(); r.Advance(5.1); r.Eval();
            Util.Wait(r.C.SetModeAsync(OfferMode.Auto));
            T.Ok(!r.C.IsAfk, "switching to run without asking ends AFK mode");
            r = new CtlRig();
            r.Start(); r.Offer("job000000001"); r.Eval(); r.Advance(5.1); r.Eval();
            T.Ok(!MiniJson.TryObject(r.Settings.ToJson(new FakeProtector())).Keys.Any(k => k.ToLowerInvariant().Contains("afk") && k != "afkAllowed"), "AFK mode itself is never saved (only the tray's Allow AFK mode)");
            var fresh = new CtlRig();
            fresh.Start();
            T.Ok(!fresh.C.IsAfk && !fresh.Ui.Afk, "an app that starts again starts with AFK mode off");
            // signing out ends it
            Util.Wait(r.C.SignOutAsync());
            T.Ok(!r.C.IsAfk, "signing out ends it");
        }

        static ApiResult CancelReply(params string[] ids)
        {
            return FakeApi.Ok(new Dictionary<string, object> { { "serverTime", "2026-10-19T12:00:00Z" }, { "offer", null }, { "cancel", ids.Cast<object>().ToList() } });
        }

        static void ServerCancel()
        {
            // the heartbeat lists the job this PC is running: the game is stopped, the job dropped, and the server is told nothing
            var r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Gate = new TaskCompletionSource<int>();
            r.Start(); r.Offer("job000000001");
            Task running = r.C.EvaluateAsync();
            T.Ok(WaitFor(() => r.C.IsBusy && r.Runner.Ran.Count == 1), "a job is running");
            r.Api.Heartbeat = () => CancelReply("job000000099");
            r.Beat();
            T.Ok(r.C.IsBusy && !r.Runner.LastCancel.IsCancellationRequested, "a cancel for another job changes nothing");
            r.Api.Heartbeat = () => FakeApi.Ok(new Dictionary<string, object> { { "serverTime", "x" }, { "offer", null } });
            r.Beat();
            T.Ok(r.C.IsBusy && !r.Runner.LastCancel.IsCancellationRequested, "nor does a heartbeat that cancels nothing");
            r.Api.Heartbeat = () => CancelReply("job000000099", "job000000001");
            r.Beat();
            T.Ok(r.Runner.LastCancel.IsCancellationRequested, "the job the app is running is listed: the runner is told to stop");
            T.Ok(!r.Runner.LastToken.IsCancellationRequested, "(that is not the app closing)");
            Util.Wait(running);
            T.Ok(!r.C.IsBusy, "the job is dropped and the app is free");
            T.Eq(r.Ui.Status, "The job was cancelled.", "the tray says so");
            T.Eq(r.Ui.Level, StatusLevel.Ok, "and it is not a warning");
            T.Eq(r.Api.Count("fail"), 0, "the server is not told the job failed");
            T.Eq(r.Api.Count("done"), 0, "nor done");
            T.Ok(!r.Ui.Notices.Any(n => n.StartsWith("A job failed")), "no failure balloon");
            T.Ok(r.Log.Any(l => l.Contains("cancelled") && l.Contains("job000000001")), "the app's log says it");

            // the next job is not cancelled by what came before
            r.Runner.Gate = null;
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000002");
            r.Beat(); r.Eval();
            T.Ok(r.Runner.Ran.Last() == "job000000002" && !r.Runner.LastCancel.IsCancellationRequested, "the next job starts normally");
            T.Ok(r.Ui.Status.StartsWith("Last job:"), "and ends normally");

            // the cancel lists a job that is only offered, not running: nothing to stop
            r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.Ok(new Dictionary<string, object> { { "serverTime", "x" }, { "offer", new Dictionary<string, object> { { "id", "job000000003" }, { "kind", "shots" }, { "title", "t" }, { "weightS", 60.0 }, { "expiresAt", "2026-10-19T13:00:00Z" } } }, { "cancel", new List<object> { "job000000003" } } });
            r.Beat();
            T.Ok(r.C.CurrentOffer != null && r.Ran == 0 && r.Ui.Status != "The job was cancelled.", "a cancel for a job that is not running is ignored");

            // the cancel arrives while the job is being taken: the runner starts already cancelled
            r = new CtlRig(mode: OfferMode.Auto);
            r.Start();
            r.Api.Claim = id =>
            {
                r.Api.Heartbeat = () => CancelReply(id);
                r.Beat();
                return FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "shots" }, { "title", "t" }, { "payload", Program.ValidPayload() } });
            };
            r.Offer("job000000004"); r.Eval();
            T.Ok(r.Ran == 1 && r.Runner.LastCancel.IsCancellationRequested, "a cancel that came while the job was being claimed reaches the runner");
        }

        static void SignInTrouble()
        {
            // the server no longer accepts the token (401 signed_out): say so, stop polling, ask
            var r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.Err(401, "signed_out", "You are signed out.");
            r.Beat();
            T.Ok(!r.C.SignedIn && r.Settings.Token == "" && r.Api.Token == "", "401 signed_out: the token is forgotten");
            T.Eq(r.Ui.Status, "Signed out: sign in to the team app again.", "and the status says so, in these words");
            T.Ok(r.Ui.SignInCalls == 1 && !r.Ui.SignInOpenNow && r.Ui.SignInReason == "Signed out: sign in to the team app again.", "the member is told with a balloon, not a box in their face");
            T.Eq(r.Api.Count("login"), 0, "nothing signs in by itself (there is no stored password)");
            r.Beat(); r.Beat(); r.Eval();
            T.Eq(r.Api.Count("heartbeat"), 2, "polling stops until the member signs in (the start's heartbeat and the refused one)");
            // and it works again after a sign-in
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000001");
            Util.Wait(r.C.SignInAsync("helix", "pw"));
            T.Ok(r.C.SignedIn && r.C.CurrentOffer != null && r.Api.Count("heartbeat") == 3, "after signing in again the polling goes on");

            // a 401 with no code is the same
            r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.Err(401, "", "invalid token");
            r.Beat();
            T.Ok(!r.C.SignedIn && r.Ui.Status == TeamApi.SignedOutText, "any 401 means signed out");

            // signed out while an offer is up: the box goes away
            r = new CtlRig();
            r.Start(); r.Offer(); r.Eval();
            T.Ok(r.Ui.BoxVisible, "box up");
            r.Api.Heartbeat = () => FakeApi.Err(401, "signed_out", "x");
            r.Beat();
            T.Ok(!r.Ui.BoxVisible && r.C.CurrentOffer == null, "signing out takes the box down");
            r.Eval();
            T.Eq(r.Ran, 0, "and nothing runs");

            // signed out at the claim
            r = new CtlRig(mode: OfferMode.Auto);
            r.Start();
            r.Api.Claim = id => FakeApi.Err(401, "signed_out", "x");
            r.Offer(); r.Eval();
            T.Ok(r.Ran == 0 && !r.C.SignedIn && r.Ui.Status == TeamApi.SignedOutText && !r.C.IsBusy, "a claim the server refuses as signed out stops the app signing on");

            // removed from the team
            r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.Err(403, "not_team", "This account is not on the team.");
            r.Beat();
            T.Eq(r.Ui.StoppedMessage, "This account is not on the team.", "403 not_team on a heartbeat stops the app with the server's words");
            T.Ok(r.Settings.Token == "" && r.C.Stopped, "and forgets the sign-in");

            // 409 session_replaced cannot happen with the team token: it is just an error like any other
            r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.Err(409, "session_replaced", "something");
            r.Beat();
            T.Ok(r.C.SignedIn && r.Api.Count("login") == 0 && r.Ui.SignInCalls == 0, "no special handling of session_replaced any more");

            // offline, then back
            r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.NetErr();
            r.Beat();
            T.Eq(r.Ui.Status, "Offline: trying again", "no internet: the status says so");
            T.Ok(r.C.SignedIn, "and the sign-in is kept");
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000001");
            r.Beat();
            T.Ok(r.C.CurrentOffer != null, "back online: the offer arrives");

            // the server's team service is not ready
            r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.Err(503, "unavailable", "The team service is not ready yet.");
            r.Beat();
            T.Eq(r.Ui.Status, "The team service is not ready yet.", "a 503 shows the server's words");
        }

        static void SignOut()
        {
            var r = new CtlRig();
            r.Start(); r.Offer(); r.Eval();
            T.Ok(r.Ui.BoxVisible, "box up");
            T.Ok(Util.Wait(r.C.SignOutAsync()), "sign out works");
            T.Eq(r.Api.Calls.Last(), "logout tok-0", "the server is told to end this token first");
            T.Ok(!r.C.SignedIn && r.Settings.Token == "" && r.Api.Token == "" && !r.Ui.BoxVisible && r.C.CurrentOffer == null, "then the token is forgotten and the box goes");
            T.Eq(r.Ui.Status, "Signed out", "status: signed out");
            T.Ok(r.Saves > 1, "and the forgetting is saved");
            int beats = r.Api.Count("heartbeat");
            r.Beat(); r.Eval();
            T.Eq(r.Api.Count("heartbeat"), beats, "nothing is sent after signing out");
            T.Eq(r.Ui.SignInCalls, 0, "signing out on purpose does not nag");
            // and signing in again works
            Util.Wait(r.C.SignInAsync("helix", "pw"));
            T.Ok(r.C.SignedIn && r.Settings.Token == "tok-1", "signing in again after signing out");

            // the server cannot be reached or refuses: the token is forgotten here anyway
            r = new CtlRig();
            r.Start();
            r.Api.Logout = () => FakeApi.NetErr();
            T.Ok(Util.Wait(r.C.SignOutAsync()) && r.Settings.Token == "" && !r.C.SignedIn, "sign out forgets the token even when the server does not answer");
            r = new CtlRig();
            r.Start();
            r.Api.Logout = () => FakeApi.Err(401, "signed_out", "x");
            T.Ok(Util.Wait(r.C.SignOutAsync()) && r.Settings.Token == "", "and when the server already considers it signed out");

            // not while a job runs
            r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Gate = new TaskCompletionSource<int>();
            r.Start(); r.Offer();
            var running = r.C.EvaluateAsync();
            T.Ok(WaitFor(() => r.C.IsBusy && r.Runner.Ran.Count == 1), "a job is running");
            T.Ok(!Util.Wait(r.C.SignOutAsync()), "signing out while a job runs is refused");
            T.Ok(r.C.SignedIn && r.Settings.Token == "tok-0" && r.Api.Count("logout") == 0, "and nothing changed");
            T.Ok(r.Ui.Notices.Any(n => n.StartsWith("A job is running")), "with a word about why");
            r.Runner.Gate.SetResult(0);
            Util.Wait(running);

            // signing out with no token held makes no call
            r = new CtlRig(signedIn: false);
            r.Start();
            Util.Wait(r.C.SignOutAsync());
            T.Eq(r.Api.Count("logout"), 0, "no token, no logout call");
        }

        static bool WaitFor(Func<bool> c) { var sw = Stopwatch.StartNew(); while (!c() && sw.Elapsed < TimeSpan.FromSeconds(30)) Thread.Sleep(5); return c(); }

        static void Busy()
        {
            var r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Gate = new TaskCompletionSource<int>();
            r.Start(); r.Offer("job000000001");
            Task running = r.C.EvaluateAsync();   // the job runs until the gate opens
            T.Ok(WaitFor(() => r.C.IsBusy && r.Runner.Ran.Count == 1), "a job is running");
            T.Eq(r.Ui.Status, "running job000000001", "the runner's progress is the status while a job runs");
            r.Beat();
            T.Ok(r.Api.LastState.Busy, "heartbeats go on while the job runs, and say busy (this keeps the job alive on the server)");
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000002");
            r.Beat(); r.Beat();
            T.Eq(string.Join(",", r.Api.Declines), "job000000002:busy", "a second job offered while one runs is declined once, with busy");
            r.Eval();
            T.Eq(r.Runner.Ran.Count, 1, "and is not started");
            T.Ok(r.Ui.BoxVisible == false, "no box while busy");
            Util.Wait(r.C.AnswerAsync(OfferAnswer.Yes));
            T.Eq(r.Runner.Ran.Count, 1, "an answer while busy does nothing");
            Util.Wait(r.C.ShowJobsAsync());
            T.Eq(r.Runner.Ran.Count, 1, "Show jobs while busy runs nothing");
            T.Ok(r.Ui.Notices.Any(n => n.StartsWith("A job is running")), "but says a job is running");
            r.Runner.Gate.SetResult(0);
            Util.Wait(running);
            T.Ok(!r.C.IsBusy, "the job ends");

            // closing the app stops the job
            r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Gate = new TaskCompletionSource<int>();
            r.Start(); r.Offer("job000000001");
            running = r.C.EvaluateAsync();
            T.Ok(WaitFor(() => r.C.IsBusy && r.Runner.Ran.Count == 1), "a job is running before the app closes");
            Util.Wait(r.C.ShutDownAsync(TimeSpan.FromSeconds(20)));
            T.Ok(r.Runner.LastToken.IsCancellationRequested, "closing the app cancels the running job");
            Util.Wait(running);
            T.Ok(!r.C.IsBusy, "and it has ended");
            T.Ok(r.Ui.Status.Contains("stopped: the team app was closed"), "with the reason");
            // closing with nothing running is immediate
            var idle = new CtlRig();
            Util.Wait(idle.C.ShutDownAsync(TimeSpan.FromSeconds(20)));
            T.Ok(true, "closing an idle app returns at once");
        }
    }
}
