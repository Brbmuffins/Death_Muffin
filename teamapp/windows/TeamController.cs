using System;
using System.Collections.Generic;
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
        string gpu;

        Offer current;
        OfferAnswer answer = OfferAnswer.None;
        DateTime? shownAt;
        readonly Dictionary<string, DateTime> snoozed = new Dictionary<string, DateTime>();
        readonly HashSet<string> sentDeclines = new HashSet<string>();
        bool running, heartbeating, evaluating, signedIn, stopped, offline;
        string runningJobId;
        CancellationTokenSource runCts;
        Task runTask = Task.FromResult(0);
        string lastStatus = "";
        StatusLevel lastLevel = StatusLevel.Ok;

        public TeamController(ITeamApi api, TeamSettings settings, Action save, ITeamPlatform platform, IJobRunner runner, ITeamUi ui,
            Func<DateTime> utcNow, string version, string pcName, Uri siteBase, Action<string> log)
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
        }

        public bool IsBusy { get { return running; } }
        public bool SignedIn { get { return signedIn; } }
        public bool Stopped { get { return stopped; } }
        public OfferMode Mode { get { return settings.Mode; } }
        public bool IsPaused { get { return settings.IsPaused(utcNow()); } }
        public Offer CurrentOffer { get { return current; } }

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
                Offer offer = TeamApi.ParseOffer(r);
                DateTime now = utcNow();
                if (offer != null && snoozed.ContainsKey(offer.Id))
                {
                    if (snoozed[offer.Id] > now) offer = null;
                    else snoozed.Remove(offer.Id);
                }
                if (running)
                {
                    // A second job offered while one runs: say so once; the job stays queued for the other PCs.
                    if (offer != null && offer.Id != runningJobId && sentDeclines.Add(offer.Id + "|busy"))
                        await api.DeclineAsync(offer.Id, settings.PcId, "busy", CancellationToken.None).ConfigureAwait(true);
                    return;
                }
                if (offer == null) ClearOffer();
                else if (current == null || current.Id != offer.Id)
                {
                    current = offer;
                    answer = OfferAnswer.None;
                    shownAt = null;
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

        /// <summary>The server does not accept the token any more (401 signed_out): forget it, stop polling, and ask the member to sign in again (a balloon, not a box).</summary>
        void SignedOutNow()
        {
            signedIn = false;
            settings.ClearSignIn();
            save();
            api.Token = "";
            ClearOffer();
            SetStatus(TeamApi.SignedOutText, StatusLevel.Warn);
            ui.NeedSignIn(TeamApi.SignedOutText, false);
            log("signed out by the server");
        }

        // ---- The offer ---------------------------------------------------------------------------------------------------------------

        void ClearOffer()
        {
            current = null;
            answer = OfferAnswer.None;
            if (shownAt.HasValue) ui.HideOffer();
            shownAt = null;
        }

        /// <summary>Looks at the offer once (every second while there is one): runs it, asks about it, keeps it waiting, or declines it.</summary>
        public async Task EvaluateAsync()
        {
            if (evaluating || running || !signedIn || stopped || current == null) return;
            evaluating = true;
            try
            {
                Offer offer = current;
                if (offer.Kind != JobPlan.Kind)
                {
                    // A job this version cannot run: decline it once and tell the person to update (the app updates itself).
                    if (sentDeclines.Add(offer.Id + "|kind"))
                    {
                        await api.DeclineAsync(offer.Id, settings.PcId, "not_now", CancellationToken.None).ConfigureAwait(true);
                        log("skipped a " + offer.Kind + " job: this version runs shots jobs only");
                    }
                    SetStatus("A newer team app is needed for " + offer.Kind + " jobs", StatusLevel.Warn);
                    return;
                }
                DateTime now = utcNow();
                bool paused = settings.IsPaused(now);
                bool fullscreen = platform.Fullscreen(), game = platform.GameRunning(), battery = platform.OnBattery();
                TimeSpan elapsed = shownAt.HasValue ? now - shownAt.Value : TimeSpan.Zero;
                OfferDecision d = TeamLogic.Decide(settings.Mode, answer, elapsed, fullscreen, game, battery, paused);
                switch (d)
                {
                    case OfferDecision.Run:
                        await RunOfferAsync(offer).ConfigureAwait(true);
                        break;
                    case OfferDecision.Ask:
                        if (!shownAt.HasValue) shownAt = now;
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

        OfferView View(Offer offer, TimeSpan shownFor)
        {
            var v = new OfferView { Text = TeamLogic.OfferText(offer.Title, offer.WeightS) };
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
                ui.Notify("Nothing to run", "No jobs are waiting right now.", false);
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
            UpdateIdleStatus();
            await HeartbeatAsync().ConfigureAwait(true);
        }

        /// <summary>Tray: Ask / Run without asking / Only on a yes. The server learns it with the next heartbeat (sent now).</summary>
        public async Task SetModeAsync(OfferMode mode)
        {
            settings.Mode = mode;
            save();
            log("mode: " + Modes.Wire(mode));
            await HeartbeatAsync().ConfigureAwait(true);
            if (current != null) await EvaluateAsync().ConfigureAwait(true);
        }

        // ---- The job ---------------------------------------------------------------------------------------------------------------------

        async Task RunOfferAsync(Offer offer)
        {
            running = true;
            runningJobId = offer.Id;
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
                    SetStatus("Another team PC took the job", StatusLevel.Ok);
                    return;
                }
                if (claim.NotTeam) { Stop(claim.Error.Length > 0 ? claim.Error : "This account is not on the team.", true); return; }
                if (claim.SignedOut) { SignedOutNow(); return; }
                ClaimedJob job = TeamApi.ParseClaim(claim);
                if (job == null)
                {
                    snoozed[offer.Id] = utcNow() + TimeSpan.FromMinutes(5);
                    ClearOffer();
                    SetStatus(claim.Ok ? "The server's job could not be read" : claim.Error, StatusLevel.Warn);
                    log("claim of " + offer.Id + " failed: " + claim.Error);
                    return;
                }
                ClearOffer();
                log("claimed " + job.Id + " \"" + job.Title + "\"");
                JobPlan plan = null;
                string err = null;
                if (job.Kind != JobPlan.Kind || !JobPlan.TryParse(job.Payload, siteBase, out plan, out err))
                {
                    if (job.Kind != JobPlan.Kind) err = "This version of the team app cannot run " + job.Kind + " jobs.";
                    await api.FailAsync(job.Id, err, "", CancellationToken.None).ConfigureAwait(true);
                    SetStatus("Job refused: " + err, StatusLevel.Warn);
                    ui.Notify("A job was refused", err, true);
                    log("refused " + job.Id + ": " + err);
                    return;
                }
                runCts = new CancellationTokenSource();
                CancellationToken token = runCts.Token;
                string jobId = job.Id;
                RunResult result;
                try { result = await Task.Run(() => runner.RunAsync(jobId, plan, p => SetStatus(p, StatusLevel.Busy), token)).ConfigureAwait(true); }
                catch (Exception ex)
                {
                    // The runner reports its own failures; this is a bug in the app. The job is failed so the server does not wait for it.
                    string why = "The team app hit an unexpected error: " + ex.Message;
                    log("job " + jobId + ": " + ex);
                    try { await api.FailAsync(jobId, why, ex.ToString(), CancellationToken.None).ConfigureAwait(true); } catch (Exception) { }
                    result = new RunResult { Ok = false, Error = why };
                }
                if (result.Ok)
                {
                    SetStatus("Last job: " + result.Files.Count + " picture(s) uploaded at " + DateTime.Now.ToString("HH:mm", CultureInfo.InvariantCulture), StatusLevel.Ok);
                    log("job " + jobId + " done: " + result.Files.Count + " picture(s)");
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
            SetStatus("Ready (mode: " + Modes.Label(settings.Mode) + ")", StatusLevel.Ok);
        }
    }
}
