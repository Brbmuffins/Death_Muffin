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
        public readonly TeamSettings Settings;
        public readonly List<string> Log = new List<string>();
        public readonly TeamController C;
        public DateTime Now = new DateTime(2026, 10, 19, 12, 0, 0, DateTimeKind.Utc);
        public int Saves;
        public static readonly Uri Site = new Uri("https://muffindevelopment.com/death-muffin/");

        public CtlRig(bool signedIn = true, OfferMode mode = OfferMode.Ask)
        {
            Settings = new TeamSettings { Username = "Helix", Token = signedIn ? "tok-0" : "", Mode = mode, PcId = "0123456789abcdef" };
            C = new TeamController(Api, Settings, () => Saves++, Plat, Runner, Ui, () => Now, "0.1.0", "WAR-PC", Site, Log.Add);
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
            RunNowAndPause();
            JobProblems();
            SignInTrouble();
            SignOut();
            Busy();
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
            T.Eq(string.Join(",", r.Api.Declines), "job000000001:not_now", "Not now declines with not_now");
            T.Ok(!r.Ui.BoxVisible && r.C.CurrentOffer == null && r.Ran == 0, "the box goes and nothing runs");
            r.Beat(); r.Eval();
            T.Ok(r.C.CurrentOffer == null && r.Api.Declines.Count == 1, "the server offering the same job again is ignored for a while");
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

        static void RunNowAndPause()
        {
            var r = new CtlRig();
            r.Start();
            Util.Wait(r.C.RunNowAsync());
            T.Ok(r.Ran == 0 && r.Ui.Notices.Any(n => n.StartsWith("Nothing to run")), "Run now with no job says so");

            r = new CtlRig();
            r.Start(); r.Api.Heartbeat = () => FakeApi.OfferReply("job000000001");
            Util.Wait(r.C.RunNowAsync());
            T.Eq(r.Ran, 1, "Run now takes the waiting job at once, without the box");
            T.Eq(r.Ui.Shown.Count, 0, "no box for Run now");

            r = new CtlRig();
            r.Start(); r.Plat.IsGame = true; r.Api.Heartbeat = () => FakeApi.OfferReply("job000000001");
            Util.Wait(r.C.RunNowAsync());
            T.Eq(r.Ran, 1, "Run now is a yes: it runs while Death Muffin is open");

            r = new CtlRig();
            r.Start();
            Util.Wait(r.C.TogglePauseAsync());
            T.Ok(r.C.IsPaused && r.Settings.PausedUntilUtc == r.Now.AddHours(2) && r.Api.LastState.Paused, "Pause 2 hours from the tray");
            r.Api.Heartbeat = () => FakeApi.OfferReply("job000000001");
            r.Beat(); r.Eval();
            T.Ok(r.Ran == 0 && r.Api.Declines.SequenceEqual(new[] { "job000000001:paused" }), "a paused PC declines");
            Util.Wait(r.C.RunNowAsync());
            T.Ok(!r.C.IsPaused && r.Ran == 1, "Run now ends the pause and runs");

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
            Util.Wait(r.C.RunNowAsync());
            T.Eq(r.Runner.Ran.Count, 1, "Run now while busy does nothing");
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
