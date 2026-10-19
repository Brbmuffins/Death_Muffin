using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam
{
    /// <summary>Colour of the tray status: Ok green, Busy violet, Warn orange.</summary>
    internal enum StatusLevel { Ok, Busy, Warn }

    /// <summary>What the offer box shows.</summary>
    internal sealed class OfferView
    {
        /// <summary>"Screenshots of a change, about 1 minute".</summary>
        public string Text = "";
        /// <summary>"Runs by itself in 4:12", or "Runs when you say yes" (mode: only on a yes).</summary>
        public string Countdown = "";
        /// <summary>A job kind's own words (a benchmark: it starts once the PC is quiet, normal priority, a touch restarts it), or "".</summary>
        public string Note = "";
    }

    /// <summary>The screen side of the app. TrayContext is the real one; tests use a recorder.</summary>
    internal interface ITeamUi
    {
        /// <summary>Shows the offer box, or updates it when it is already up. Never takes the keyboard or the focus.</summary>
        void ShowOffer(OfferView view);
        void HideOffer();
        void SetStatus(string text, StatusLevel level);
        /// <summary>A balloon from the tray icon (it does not take the focus).</summary>
        void Notify(string title, string text, bool error);
        /// <summary>Signed out. <paramref name="openNow"/>: show the sign-in box now (first start); otherwise only say so and let the person open it from the tray menu.</summary>
        void NeedSignIn(string reason, bool openNow);
        /// <summary>The account is not on the team: tell the person; the app then closes.</summary>
        void Stopped(string message);
        /// <summary>AFK mode on or off: a small persistent notice ("AFK mode on: jobs run right away", End AFK mode) and a tray menu item while it is on. Neither takes the focus.</summary>
        void SetAfk(bool on);
    }

    /// <summary>What the app asks about this PC (the controller uses a stand-in in tests).</summary>
    internal interface ITeamPlatform
    {
        /// <summary>A full-screen game or movie, or a presentation, is up (Windows would hide a question then).</summary>
        bool Fullscreen();
        /// <summary>A laptop running on its battery.</summary>
        bool OnBattery();
        /// <summary>The player has Death Muffin open (not the app's own job game).</summary>
        bool GameRunning();
        string GpuName();
    }

    internal sealed class SignInResult
    {
        public bool Ok;
        public string Message = "";
        public bool NotTeam;
        /// <summary>No answer from the server at all (not a wrong password).</summary>
        public bool Network;
    }

    /// <summary>
    /// The app's brain, with no Windows in it (the platform, the server, the runner and the screen are interfaces): the heartbeat, the offer (shown, answered, run by
    /// itself, declined, or kept waiting) by TeamLogic.Decide, the claim, the job, and sign-in and sign-out (a token the server no longer accepts means "signed out": polling stops until the member signs in). All calls come from the UI thread.
    /// </summary>
    internal sealed class TeamController
    {
        public static readonly TimeSpan SnoozeAfterNotNow = TimeSpan.FromMinutes(30);
        readonly ITeamApi api;
        readonly TeamSettings settings;
        readonly Action save;
        readonly ITeamPlatform platform;
        readonly IJobRunner runner;
        readonly ITeamUi ui;
        readonly Func<DateTime> utcNow;
        readonly string version, pcName;
        readonly Uri siteBase;
        readonly Action<string> log;
        readonly IPcProbe probe;
        string gpu;

        /// <summary>The words of the tray status while a benchmark that was accepted waits for the PC to be left alone.</summary>
        public const string BenchWaitingText = "Benchmark waiting for the PC to be left alone";
        public const string BenchGoneText = "The benchmark is no longer available.";
        /// <summary>How the PC is judged quiet before a benchmark is claimed (the runner judges it again before each setup).</summary>
        public QuietRules Rules = new QuietRules();
        /// <summary>The PC is read at most this often while a benchmark waits (EvaluateAsync runs every second).</summary>
        public int MinReadMs = 800;
        /// <summary>A claim of a waiting benchmark that failed for another reason than "gone" is tried again after this long.</summary>
        public static readonly TimeSpan BenchClaimRetry = TimeSpan.FromSeconds(30);

        Offer current;
        OfferAnswer answer = OfferAnswer.None;
        DateTime? shownAt;
        string lastDecision = "";   // the offer's last decision, logged when it changes (app.log: why a box did or did not show, why a job ran)
        readonly Dictionary<string, DateTime> snoozed = new Dictionary<string, DateTime>();
        readonly HashSet<string> sentDeclines = new HashSet<string>();
        bool running, heartbeating, evaluating, signedIn, stopped, offline, afk;
        string runningJobId;
        CancellationTokenSource runCts, cancelCts;
        bool cancelRequested;
        Task runTask = Task.FromResult(0);
        string lastStatus = "";
        StatusLevel lastLevel = StatusLevel.Ok;

        // A benchmark that was said yes to (or ran by itself): kept here, not claimed. It stays queued on the server, so the PC is not busy while it waits and a screenshot job is
        // handled as usual meanwhile; it is claimed once the PC has been quiet for a minute and nothing else runs.
        Offer waitingBench;
        bool benchGone;
        readonly List<PcSample> benchSamples = new List<PcSample>();
        bool benchPrimed;
        DateTime benchRetryAt = DateTime.MinValue;
        readonly Stopwatch readClock = new Stopwatch();

        /// <param name="probe">Reads the PC (shared with the runner: it reads only while no job runs, the runner only while one does).</param>
        public TeamController(ITeamApi api, TeamSettings settings, Action save, ITeamPlatform platform, IJobRunner runner, ITeamUi ui,
            Func<DateTime> utcNow, string version, string pcName, Uri siteBase, Action<string> log, IPcProbe probe)
        {
            this.api = api;
            this.settings = settings;
            this.save = save;
            this.platform = platform;
            this.runner = runner;
            this.ui = ui;
            this.utcNow = utcNow;
            this.version = version;
            this.pcName = pcName;
            this.siteBase = siteBase;
            this.log = log ?? (s => { });
            this.probe = probe;
        }

        public bool IsBusy { get { return running; } }
        public bool SignedIn { get { return signedIn; } }
        public bool Stopped { get { return stopped; } }
        public OfferMode Mode { get { return settings.Mode; } }
        public bool IsPaused { get { return settings.IsPaused(utcNow()); } }
        public Offer CurrentOffer { get { return current; } }
        /// <summary>AFK mode (mode ask only; never kept across a restart): the person is away, so jobs run at once without a box.</summary>
        public bool IsAfk { get { return afk; } }
        /// <summary>The benchmark that was accepted and waits for a quiet PC (not claimed, still queued on the server), or null.</summary>
        public Offer WaitingBench { get { return waitingBench; } }

        // ---- Start and sign-in ---------------------------------------------------------------------------------------------------

        public async Task StartAsync()
        {
            settings.EnsurePcId();
            save();
            gpu = platform.GpuName();
            api.Token = settings.Token;
            if (!settings.SignedIn)
            {
                signedIn = false;
                SetStatus("Not signed in", StatusLevel.Warn);
                ui.NeedSignIn("Sign in with your Death Muffin account to take jobs.", true);
                return;
            }
            signedIn = true;
            SetStatus("Starting...", StatusLevel.Busy);
            await HeartbeatAsync().ConfigureAwait(true);
        }

        /// <summary>
        /// The sign-in box: the team's own sign-in (the server checks the password and that the account is on the team, and never touches the game's session). The token
        /// is kept, protected, only after it succeeds. No password is stored.
        /// </summary>
        public async Task<SignInResult> SignInAsync(string username, string password)
        {
            username = (username ?? "").Trim();
            if (username.Length == 0 || (password ?? "").Length == 0) return new SignInResult { Message = "Enter your username and password." };
            settings.EnsurePcId();
            ApiResult login = await api.LoginAsync(username, password, settings.PcId, pcName, CancellationToken.None).ConfigureAwait(true);
            if (login.NotTeam)
            {
                string text = login.Error.Length > 0 ? login.Error : "This account is not on the team.";
                Stop(text, false);
                return new SignInResult { NotTeam = true, Message = text };
            }
            if (!login.Ok) return new SignInResult { Message = login.Error, Network = login.Network };
            string token = MiniJson.Str(login.Data, "token");
            string name = MiniJson.Str(login.Data, "username");
            settings.Username = name.Length > 0 ? name : username;
            settings.Token = token;
            api.Token = token;
            save();
            signedIn = true;
            stopped = false;
            log("signed in as " + settings.Username);
            SetStatus("Signed in", StatusLevel.Ok);
            await HeartbeatAsync().ConfigureAwait(true);
            return new SignInResult { Ok = true };
        }

        /// <summary>Sign out (tray menu): the server ends the token, then the app forgets it. Not while a job runs (it would lose its pictures). Returns false when it refused.</summary>
        public async Task<bool> SignOutAsync()
        {
            if (running)
            {
                ui.Notify("A job is running", "Sign out when the job is done.", false);
                return false;
            }
            if (settings.Token.Length > 0)
            {
                try { await api.LogoutAsync(CancellationToken.None).ConfigureAwait(true); }
                catch (Exception ex) { log("sign-out call failed: " + ex.Message); }   // offline or refused: the token is forgotten here anyway
            }
            settings.ClearSignIn();
            save();
            api.Token = "";
            signedIn = false;
            ClearOffer();
            DropWaitingBench();
            LeaveAfk("signed out");
            SetStatus("Signed out", StatusLevel.Warn);
            log("signed out");
            return true;
        }

        // ---- The heartbeat ---------------------------------------------------------------------------------------------------------

        PcState BuildState()
        {
            return new PcState
            {
                GameRunning = platform.GameRunning(),
                Fullscreen = platform.Fullscreen(),
                OnBattery = platform.OnBattery(),
                Busy = running,
                Paused = settings.IsPaused(utcNow()),
            };
        }

        /// <summary>Tells the server this PC is here (every 30 seconds) and takes the offer it answers with. Also keeps a running job alive on the server.</summary>
        public async Task HeartbeatAsync()
        {
            if (heartbeating || !signedIn || stopped) return;
            heartbeating = true;
            try
            {
                ApiResult r = await api.HeartbeatAsync(settings.PcId, pcName, version, gpu ?? "", settings.Mode, BuildState(), CancellationToken.None).ConfigureAwait(true);
                await HandleHeartbeatAsync(r).ConfigureAwait(true);
            }
            finally { heartbeating = false; }
        }

        async Task HandleHeartbeatAsync(ApiResult r)
        {
            if (r.Ok)
            {
                if (!signedIn) return;   // signed out while this heartbeat was on its way
                offline = false;
                if (running && runningJobId != null && TeamApi.ParseCancel(r).Contains(runningJobId)) CancelRunningJob();
                Offer offer = TeamApi.ParseOffer(r);
                offer = AboutWaitingBench(offer);
                DateTime now = utcNow();
                if (offer != null && snoozed.ContainsKey(offer.Id))
                {
                    if (snoozed[offer.Id] > now) offer = null;
                    else snoozed.Remove(offer.Id);
                }
                if (running)
                {
                    // A second job offered while one runs: say so once; the job stays queued for the other PCs.
                    // (a benchmark is not declined for being busy: the server would not offer it to this PC again, and it is queued for this PC alone)
                    if (offer != null && offer.Id != runningJobId && offer.Kind != JobPlan.BenchKind && sentDeclines.Add(offer.Id + "|busy"))
                        await api.DeclineAsync(offer.Id, settings.PcId, "busy", CancellationToken.None).ConfigureAwait(true);
                    return;
                }
                if (offer == null) ClearOffer();
                else if (current == null || current.Id != offer.Id)
                {
                    current = offer;
                    answer = OfferAnswer.None;
                    shownAt = null;
                    lastDecision = "";
                    log("offered: " + offer.Id + " " + offer.Kind + " \"" + offer.Title + "\"");
                }
                UpdateIdleStatus();
                return;
            }
            if (r.Network)
            {
                if (!offline) log("no answer from the server: " + r.Error);
                offline = true;
                if (!running) SetStatus("Offline: trying again", StatusLevel.Warn);
                return;
            }
            if (r.NotTeam) { Stop(r.Error.Length > 0 ? r.Error : "This account is not on the team.", true); return; }
            if (r.SignedOut) { SignedOutNow(); return; }
            log("heartbeat refused (" + r.Status + "): " + r.Error);
            if (!running) SetStatus(r.Error, StatusLevel.Warn);
        }

        /// <summary>
        /// What the heartbeat's offer means for a benchmark that is waiting. The server offers the oldest queued job this PC has not declined, so the waiting benchmark (never declined, still
        /// queued) is offered again and again: that is no new question, and no answer is wanted. An offer of nothing, or of another benchmark, means it is no longer queued (cancelled, expired or
        /// taken): it is dropped. A screenshot job offered ahead of it is handled as usual.
        /// </summary>
        Offer AboutWaitingBench(Offer offer)
        {
            if (waitingBench == null) return offer;
            if (offer != null && offer.Id == waitingBench.Id) return null;
            if (offer == null || offer.Kind == JobPlan.BenchKind) { DropWaitingBench(); benchGone = true; SetStatus(BenchGoneText, StatusLevel.Ok); }
            return offer;
        }

        /// <summary>Forgets the waiting benchmark (gone from the server, claimed by nobody, or the member signed out).</summary>
        void DropWaitingBench()
        {
            if (waitingBench == null) return;
            log("the waiting benchmark " + waitingBench.Id + " is dropped");
            waitingBench = null;
            benchSamples.Clear();
            benchPrimed = false;
        }

        /// <summary>The server cancelled the job this PC is running (its heartbeat reply lists it): the runner stops the game and drops the job without telling the server anything.</summary>
        void CancelRunningJob()
        {
            if (cancelRequested) return;
            cancelRequested = true;
            log("the server cancelled job " + runningJobId);
            var c = cancelCts;
            if (c != null) c.Cancel();
        }

        /// <summary>The server does not accept the token any more (401 signed_out): forget it, stop polling, and ask the member to sign in again (a balloon, not a box).</summary>
        void SignedOutNow()
        {
            signedIn = false;
            settings.ClearSignIn();
            save();
            api.Token = "";
            ClearOffer();
            DropWaitingBench();
            LeaveAfk("signed out");
            SetStatus(TeamApi.SignedOutText, StatusLevel.Warn);
            ui.NeedSignIn(TeamApi.SignedOutText, false);
            log("signed out by the server");
        }

        // ---- The offer ---------------------------------------------------------------------------------------------------------------

        void ClearOffer()
        {
            if (current != null && lastDecision != "") log("offer " + current.Id + ": cleared");
            current = null;
            answer = OfferAnswer.None;
            lastDecision = "";
            if (shownAt.HasValue) ui.HideOffer();
            shownAt = null;
        }

        /// <summary>Looks at the offer once (every second while there is one): runs it, asks about it, keeps it waiting, or declines it.</summary>
        public async Task EvaluateAsync()
        {
            if (signedIn && !stopped) CheckAfk();
            if (evaluating || running || !signedIn || stopped) return;
            evaluating = true;
            try
            {
                if (current == null) { await ServeWaitingBenchAsync().ConfigureAwait(true); return; }
                Offer offer = current;
                if (!JobPlan.RunsKind(offer.Kind))
                {
                    // A job this version cannot run: decline it once and tell the person to update (the app updates itself).
                    if (sentDeclines.Add(offer.Id + "|kind"))
                    {
                        await api.DeclineAsync(offer.Id, settings.PcId, "not_now", CancellationToken.None).ConfigureAwait(true);
                        log("skipped a " + offer.Kind + " job: this version runs " + JobPlan.ShotsKind + " and " + JobPlan.BenchKind + " jobs only");
                    }
                    SetStatus("A newer team app is needed for " + offer.Kind + " jobs", StatusLevel.Warn);
                    return;
                }
                DateTime now = utcNow();
                bool paused = settings.IsPaused(now);
                bool fullscreen = platform.Fullscreen(), game = platform.GameRunning(), battery = platform.OnBattery();
                TimeSpan elapsed = shownAt.HasValue ? now - shownAt.Value : TimeSpan.Zero;
                OfferDecision d = TeamLogic.Decide(settings.Mode, answer, elapsed, fullscreen, game, battery, paused, afk);
                string why = d + (d == OfferDecision.Wait ? " (" + TeamLogic.WaitReason(fullscreen, game, battery) + ")" : "") + " mode " + settings.Mode + (afk ? " afk" : "")
                    + (paused ? " paused" : "") + (answer != OfferAnswer.None ? " answer " + answer : "");
                if (why != lastDecision)
                {
                    lastDecision = why;
                    log("offer " + offer.Id + ": " + why + ", " + (int)elapsed.TotalSeconds + " s since the box");
                }
                switch (d)
                {
                    case OfferDecision.Run:
                        if (TeamLogic.EntersAfk(settings.Mode, answer, elapsed, d, afk)) EnterAfk();
                        if (offer.Kind == JobPlan.BenchKind) AcceptBench(offer);
                        else await RunOfferAsync(offer, false).ConfigureAwait(true);
                        break;
                    case OfferDecision.Ask:
                        if (!shownAt.HasValue)
                        {
                            shownAt = now;
                            ui.Notify("Job offered", TeamLogic.OfferText(offer.Title, offer.WeightS), false);   // the tray balloon too: a second way to see it
                        }
                        ui.ShowOffer(View(offer, now - shownAt.Value));
                        SetStatus("Job offered: " + TeamLogic.OfferText(offer.Title, offer.WeightS), StatusLevel.Busy);
                        break;
                    case OfferDecision.Wait:
                        if (shownAt.HasValue) { shownAt = null; ui.HideOffer(); }
                        SetStatus("Job waiting: " + TeamLogic.WaitReason(fullscreen, game, battery), StatusLevel.Busy);
                        break;
                    case OfferDecision.Decline:
                        await DeclineAsync(offer, TeamLogic.DeclineReason(answer, paused), now).ConfigureAwait(true);
                        break;
                }
            }
            finally { evaluating = false; }
        }

        // ---- AFK mode -----------------------------------------------------------------------------------------------------------------

        /// <summary>A box in mode ask ran out with nobody there and its job runs by itself: the person is away, so from now on jobs run at once, until they are back.</summary>
        void EnterAfk()
        {
            if (afk) return;
            afk = true;
            log("AFK mode on: a box ran out with nobody answering");
            ui.SetAfk(true);
        }

        /// <summary>The notice's button and the tray item: the person is back. The next offer shows the box with its 5 minutes again.</summary>
        public void EndAfk() { LeaveAfk("ended by the person"); }

        void LeaveAfk(string why)
        {
            if (!afk) return;
            afk = false;
            log("AFK mode off: " + why);
            ui.SetAfk(false);
            UpdateIdleStatus();
        }

        /// <summary>AFK mode ends by itself when the player starts Death Muffin or a full-screen app comes up (they are back) or the PC is paused. (A job's own game window can read as full screen on a small
        /// screen, so a full-screen app is only looked for while no job runs.)</summary>
        public void CheckAfk()
        {
            if (!afk) return;
            string why = TeamLogic.AfkEndReason(afk, platform.GameRunning(), !running && platform.Fullscreen(), settings.IsPaused(utcNow()));
            if (why.Length > 0) LeaveAfk(why);
        }

        /// <summary>
        /// A benchmark was said yes to (or ran by itself): it is not claimed yet. It waits here until the PC has been quiet for a minute and nothing else runs; it stays queued on the server
        /// (targeted at this PC), so this PC is not busy meanwhile and a screenshot job offered now is handled as usual.
        /// </summary>
        void AcceptBench(Offer offer)
        {
            waitingBench = offer;
            ClearOffer();
            benchSamples.Clear();
            benchPrimed = false;
            benchRetryAt = DateTime.MinValue;
            log("accepted " + offer.Id + " \"" + offer.Title + "\": waiting for the PC to be left alone");
            SetStatus(BenchWaitingText, StatusLevel.Busy);
        }

        /// <summary>
        /// Every second while no offer needs an answer and no job runs: if a benchmark waits, reads the PC, and once it has been quiet for a minute (Quiet.WhyNotQuiet) claims the benchmark and
        /// runs it. Not while the PC is paused. A claim that says the job is gone drops it; one that failed otherwise is tried again in 30 s.
        /// </summary>
        async Task ServeWaitingBenchAsync()
        {
            if (waitingBench == null) return;
            DateTime now = utcNow();
            if (settings.IsPaused(now)) { benchSamples.Clear(); benchPrimed = false; UpdateIdleStatus(); return; }
            if (readClock.IsRunning && readClock.ElapsedMilliseconds < MinReadMs) return;
            readClock.Restart();
            if (!benchPrimed)
            {
                probe.Read(0);   // the CPU numbers are averages since the previous reading: this one only sets the start
                benchPrimed = true;
                SetStatus(BenchWaitingText, StatusLevel.Busy);
                return;
            }
            PcSample s = probe.Read(0);
            benchSamples.Add(s);
            while (benchSamples.Count > 1 && s.At - benchSamples[0].At > Rules.QuietFor + Rules.QuietFor) benchSamples.RemoveAt(0);
            if (Quiet.WhyNotQuiet(benchSamples, Rules).Length > 0) { if (now >= benchRetryAt) SetStatus(BenchWaitingText, StatusLevel.Busy); return; }
            if (now < benchRetryAt) return;   // (a claim that failed is tried again later; the PC is read meanwhile)
            Offer bench = waitingBench;
            waitingBench = null;
            await RunOfferAsync(bench, true).ConfigureAwait(true);
        }

        OfferView View(Offer offer, TimeSpan shownFor)
        {
            var v = new OfferView { Text = TeamLogic.OfferText(offer.Title, offer.WeightS), Note = TeamLogic.OfferNote(offer.Kind) };
            v.Countdown = settings.Mode == OfferMode.Ask ? "Runs by itself in " + TeamLogic.Clock(TeamLogic.AutoRunAfter - shownFor) : "Runs when you say yes";
            return v;
        }

        async Task DeclineAsync(Offer offer, string reason, DateTime now)
        {
            bool notNow = reason == "not_now";
            if (notNow || sentDeclines.Add(offer.Id + "|" + reason))
            {
                await api.DeclineAsync(offer.Id, settings.PcId, reason, CancellationToken.None).ConfigureAwait(true);
                log("declined " + offer.Id + " (" + reason + ")");
            }
            if (notNow)
            {
                snoozed[offer.Id] = now + SnoozeAfterNotNow;
                ClearOffer();
                UpdateIdleStatus();
            }
            else
            {
                // Paused: the box stays hidden and the job stays offered, to be looked at again when the pause ends.
                if (shownAt.HasValue) { shownAt = null; ui.HideOffer(); }
                answer = OfferAnswer.None;
                SetStatus("Paused until " + settings.PausedUntilUtc.ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture), StatusLevel.Warn);
            }
        }

        /// <summary>The person's answer in the box.</summary>
        public async Task AnswerAsync(OfferAnswer a)
        {
            if (current == null || running) return;
            if (a == OfferAnswer.Pause)
            {
                settings.PausedUntilUtc = utcNow() + TeamLogic.PauseFor;
                save();
                answer = OfferAnswer.None;
                CheckAfk();
            }
            else answer = a;
            await EvaluateAsync().ConfigureAwait(true);
        }

        /// <summary>Tray: Run now. Ends a pause, asks the server for a job and runs it without asking (a yes).</summary>
        public async Task RunNowAsync()
        {
            if (!signedIn || stopped) return;
            if (running) { ui.Notify("A job is running", "The app is already working on a job.", false); return; }
            if (settings.IsPaused(utcNow())) { settings.PausedUntilUtc = DateTime.MinValue; save(); }
            await HeartbeatAsync().ConfigureAwait(true);
            if (current == null && !running)
            {
                if (waitingBench != null) ui.Notify("A benchmark is waiting", "It starts once the PC has been left alone for a minute.", false);
                else ui.Notify("Nothing to run", "No jobs are waiting right now.", false);
                return;
            }
            if (running) return;
            answer = OfferAnswer.Yes;
            await EvaluateAsync().ConfigureAwait(true);
        }

        /// <summary>Tray: Pause 2 hours, or Resume.</summary>
        public async Task TogglePauseAsync()
        {
            if (settings.IsPaused(utcNow())) settings.PausedUntilUtc = DateTime.MinValue;
            else settings.PausedUntilUtc = utcNow() + TeamLogic.PauseFor;
            save();
            if (shownAt.HasValue && settings.IsPaused(utcNow())) { shownAt = null; ui.HideOffer(); }
            CheckAfk();
            UpdateIdleStatus();
            await HeartbeatAsync().ConfigureAwait(true);
        }

        /// <summary>Tray: Ask / Run without asking / Only on a yes. The server learns it with the next heartbeat (sent now).</summary>
        public async Task SetModeAsync(OfferMode mode)
        {
            settings.Mode = mode;
            save();
            log("mode: " + Modes.Wire(mode));
            if (mode != OfferMode.Ask) LeaveAfk("the mode is no longer Ask");
            await HeartbeatAsync().ConfigureAwait(true);
            if (current != null) await EvaluateAsync().ConfigureAwait(true);
        }

        // ---- The job ---------------------------------------------------------------------------------------------------------------------

        /// <param name="fromWaiting">A benchmark that waited for a quiet PC: a claim that fails for a passing reason puts it back to wait instead of dropping it.</param>
        async Task RunOfferAsync(Offer offer, bool fromWaiting)
        {
            running = true;
            runningJobId = offer.Id;
            cancelRequested = false;
            if (!fromWaiting)
            {
                benchSamples.Clear();   // the PC is not quiet while a job runs: a waiting benchmark's minute starts over after it
                benchPrimed = false;
            }
            if (shownAt.HasValue) ui.HideOffer();
            shownAt = null;
            var tcs = new TaskCompletionSource<int>();
            runTask = tcs.Task;
            try
            {
                SetStatus("Taking the job...", StatusLevel.Busy);
                ApiResult claim = await api.ClaimAsync(offer.Id, settings.PcId, CancellationToken.None).ConfigureAwait(true);
                if (claim.Taken)
                {
                    ClearOffer();
                    SetStatus(fromWaiting && claim.Error.Length > 0 ? claim.Error : "Another team PC took the job", StatusLevel.Ok);
                    if (fromWaiting) log("the waiting benchmark " + offer.Id + " is gone: " + claim.Error);
                    return;
                }
                if (claim.NotTeam) { Stop(claim.Error.Length > 0 ? claim.Error : "This account is not on the team.", true); return; }
                if (claim.SignedOut) { SignedOutNow(); return; }
                ClaimedJob job = TeamApi.ParseClaim(claim);
                if (job == null)
                {
                    if (fromWaiting) { waitingBench = offer; benchRetryAt = utcNow() + BenchClaimRetry; }   // still queued: tried again soon
                    else snoozed[offer.Id] = utcNow() + TimeSpan.FromMinutes(5);
                    ClearOffer();
                    SetStatus(claim.Ok ? "The server's job could not be read" : claim.Error, StatusLevel.Warn);
                    log("claim of " + offer.Id + " failed: " + claim.Error);
                    return;
                }
                ClearOffer();
                log("claimed " + job.Id + " \"" + job.Title + "\"");
                JobPlan plan = null;
                string err = null;
                if (!JobPlan.TryParse(job.Kind, job.Payload, siteBase, out plan, out err))
                {
                    await api.FailAsync(job.Id, err, "", CancellationToken.None).ConfigureAwait(true);
                    SetStatus("Job refused: " + err, StatusLevel.Warn);
                    ui.Notify("A job was refused", err, true);
                    log("refused " + job.Id + ": " + err);
                    return;
                }
                plan.ExpiresAtUtc = JobPlan.ParseExpiry(offer.ExpiresAt);
                runCts = new CancellationTokenSource();
                cancelCts = new CancellationTokenSource();
                if (cancelRequested) cancelCts.Cancel();   // the server's cancel came while the job was being taken
                CancellationToken token = runCts.Token, cancelled = cancelCts.Token;
                string jobId = job.Id;
                RunResult result;
                try { result = await Task.Run(() => runner.RunAsync(jobId, plan, p => SetStatus(p, StatusLevel.Busy), token, cancelled)).ConfigureAwait(true); }
                catch (Exception ex)
                {
                    // The runner reports its own failures; this is a bug in the app. The job is failed so the server does not wait for it.
                    string why = "The team app hit an unexpected error: " + ex.Message;
                    log("job " + jobId + ": " + ex);
                    try { await api.FailAsync(jobId, why, ex.ToString(), CancellationToken.None).ConfigureAwait(true); } catch (Exception) { }
                    result = new RunResult { Ok = false, Error = why };
                }
                if (result.Cancelled)
                {
                    SetStatus("The job was cancelled.", StatusLevel.Ok);
                    log("job " + jobId + " was cancelled by the server");
                }
                else if (result.Ok)
                {
                    string sent = plan.Kind == JobPlan.BenchKind ? result.Runs + " benchmark run(s) sent" : result.Files.Count + " picture(s) uploaded";
                    SetStatus("Last job: " + sent + " at " + DateTime.Now.ToString("HH:mm", CultureInfo.InvariantCulture), StatusLevel.Ok);
                    log("job " + jobId + " done: " + sent);
                }
                else
                {
                    SetStatus("Last job failed: " + result.Error, StatusLevel.Warn);
                    ui.Notify("A job failed", result.Error, true);
                    log("job " + jobId + " failed: " + result.Error);
                }
            }
            finally
            {
                running = false;
                runningJobId = null;
                runCts = null;
                cancelCts = null;
                cancelRequested = false;
                tcs.TrySetResult(0);
            }
        }

        /// <summary>The app is closing: a running job is stopped (the runner kills the game and tells the server "stopped: the team app was closed"), waiting up to <paramref name="wait"/> for that.</summary>
        public async Task ShutDownAsync(TimeSpan wait)
        {
            var cts = runCts;
            if (running && cts != null)
            {
                log("closing: stopping the running job");
                cts.Cancel();
                await Task.WhenAny(runTask, Task.Delay(wait)).ConfigureAwait(true);
            }
        }

        // ---- Status --------------------------------------------------------------------------------------------------------------------

        void Stop(string message, bool tell)
        {
            stopped = true;
            signedIn = false;
            settings.ClearSignIn();
            api.Token = "";
            save();
            ClearOffer();
            DropWaitingBench();
            LeaveAfk("stopped");
            SetStatus(message, StatusLevel.Warn);
            log("stopped: " + message);
            if (tell) ui.Stopped(message);
        }

        readonly object statusGate = new object();

        /// <summary>The one way to change the status (the runner's progress comes from another thread): the screen hears only about changes.</summary>
        void SetStatus(string text, StatusLevel level)
        {
            lock (statusGate)
            {
                if (text == lastStatus && level == lastLevel) return;
                lastStatus = text;
                lastLevel = level;
            }
            ui.SetStatus(text, level);
        }

        /// <summary>The status when nothing is happening: ready, paused, or waiting for a quiet moment.</summary>
        void UpdateIdleStatus()
        {
            if (running || offline || !signedIn) return;
            DateTime now = utcNow();
            if (settings.IsPaused(now)) { SetStatus("Paused until " + settings.PausedUntilUtc.ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture), StatusLevel.Warn); return; }
            if (current != null) return;   // EvaluateAsync says what the offer is doing
            if (waitingBench != null) { SetStatus(BenchWaitingText, StatusLevel.Busy); return; }
            if (benchGone) { benchGone = false; SetStatus(BenchGoneText, StatusLevel.Ok); return; }   // said once, until the next change of status
            if (afk) { SetStatus("AFK mode: jobs run right away", StatusLevel.Ok); return; }
            SetStatus("Ready (mode: " + Modes.Label(settings.Mode) + ")", StatusLevel.Ok);
        }
    }
}
