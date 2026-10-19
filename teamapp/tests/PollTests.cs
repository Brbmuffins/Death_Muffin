using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam.Tests
{
    /// <summary>
    /// The heartbeat as a long poll: each one asks the server to hold it up to 25 seconds while it has nothing to say, and the next is sent right after the answer, with a pause only after
    /// failures (5, 15, 30 s) and after answers with nothing new that came back at once (at least 5 s between two heartbeats), so a server that does not hold requests is never hammered.
    /// </summary>
    static class PollTests
    {
        public static void Run()
        {
            PauseRules();
            WireTests();
            LoopTests();
            LoopWhileSignedOut();
            LoopWithAJob();
            LoopAndTheOthers();
        }

        static ApiResult Empty() { return FakeApi.Ok(new Dictionary<string, object> { { "serverTime", "2026-10-19T12:00:00Z" }, { "offer", null }, { "cancel", new List<object>() } }); }
        static ApiResult CancelReply(params string[] ids) { return FakeApi.Ok(new Dictionary<string, object> { { "serverTime", "x" }, { "offer", null }, { "cancel", ids.Cast<object>().ToList() } }); }

        static void PauseRules()
        {
            TimeSpan s = TimeSpan.FromSeconds(1);
            T.Eq(TeamLogic.HeartbeatPause(0, true, TimeSpan.Zero), TimeSpan.Zero, "after an answer with news the next heartbeat goes at once, however fast the answer came");
            T.Eq(TeamLogic.HeartbeatPause(0, false, TimeSpan.FromSeconds(25)), TimeSpan.Zero, "after an answer the server held for 25 s: at once");
            T.Eq(TeamLogic.HeartbeatPause(0, false, TimeSpan.FromSeconds(5)), TimeSpan.Zero, "after exactly the minimum cycle: at once");
            T.Eq(TeamLogic.HeartbeatPause(0, false, TimeSpan.Zero), TimeSpan.FromSeconds(5), "an empty answer that came back at once: wait out the 5 s (a server that does not hold requests, or an offer waiting for a yes)");
            T.Eq(TeamLogic.HeartbeatPause(0, false, TimeSpan.FromSeconds(1.5)), TimeSpan.FromSeconds(3.5), "what is left of the 5 s");
            T.Eq(TeamLogic.HeartbeatPause(0, false, TimeSpan.FromSeconds(-3)), TimeSpan.FromSeconds(8), "a clock that went back does not make a negative pause worse than 8 s");
            T.Eq(TeamLogic.HeartbeatPause(1, false, TimeSpan.FromSeconds(30)), TimeSpan.FromSeconds(5), "the first failure: 5 s");
            T.Eq(TeamLogic.HeartbeatPause(2, false, TimeSpan.Zero), TimeSpan.FromSeconds(15), "the second: 15 s");
            T.Eq(TeamLogic.HeartbeatPause(3, false, TimeSpan.Zero), TimeSpan.FromSeconds(30), "the third: 30 s");
            T.Eq(TeamLogic.HeartbeatPause(40, true, TimeSpan.Zero), TimeSpan.FromSeconds(30), "and 30 s from then on (a failure is never news)");
            T.Eq(TeamLogic.HeartbeatMinCycle, TimeSpan.FromSeconds(5), "the minimum cycle is 5 s");
            T.Eq(TeamLogic.HeartbeatBackoff.Length, 3, "three back-off steps");
            T.Ok(TeamLogic.HeartbeatWaitS <= 25 && TeamLogic.HeartbeatTimeout > TimeSpan.FromSeconds(TeamLogic.HeartbeatWaitS + 10), "the app gives up on a heartbeat well after the server's longest hold");
        }

        static void WireTests()
        {
            var tr = new Program.FakeTransport();
            var api = new TeamApi(tr, new Uri(TeamUrls.ApiBase)) { Token = "tok" };
            Func<Program.FakeTransport.Req, Dictionary<string, object>> body = r => MiniJson.TryObject(Encoding.UTF8.GetString(r.Body));
            Util.Wait(api.HeartbeatAsync("0123456789abcdef", "n", "v", "g", OfferMode.Ask, new PcState(), 25, CancellationToken.None));
            T.Eq(MiniJson.Int(body(tr.Sent[0]), "wait"), 25L, "a long-poll heartbeat sends wait 25");
            T.Eq(tr.Sent[0].Url.AbsolutePath, "/death-muffin/api/team/heartbeat", "to the heartbeat route");
            T.Eq(body(tr.Sent[0]).Count, 7, "the contract's six keys and wait");
            Util.Wait(api.HeartbeatAsync("0123456789abcdef", "n", "v", "g", OfferMode.Ask, new PcState(), CancellationToken.None));
            T.Ok(!body(tr.Sent[1]).ContainsKey("wait") && body(tr.Sent[1]).Count == 6, "a heartbeat with no wait is the old one, byte for byte");
            Util.Wait(api.HeartbeatAsync("0123456789abcdef", "n", "v", "g", OfferMode.Ask, new PcState(), 0, CancellationToken.None));
            T.Ok(!body(tr.Sent[2]).ContainsKey("wait"), "wait 0 sends none");
            Util.Wait(api.HeartbeatAsync("0123456789abcdef", "n", "v", "g", OfferMode.Ask, new PcState(), 600, CancellationToken.None));
            T.Eq(MiniJson.Int(body(tr.Sent[3]), "wait"), 25L, "a wait past the server's limit is cut to 25");
            tr.Sent.Clear();
            T.Ok(!Util.Wait(api.HeartbeatAsync("short", "n", "v", "g", OfferMode.Ask, new PcState(), 25, CancellationToken.None)).Ok && tr.Sent.Count == 0, "a bad pc id is refused without a request, with a wait too");
        }

        /// <summary>
        /// Runs the loop to the end: each heartbeat is answered by `answers` (the last one repeats); `held` is how long (seconds) each answer took, on the controller's clock; the pauses are recorded and
        /// advance the clock. The loop ends after `calls` heartbeats.
        /// </summary>
        sealed class LoopRun
        {
            public readonly CtlRig R;
            public readonly List<double> Pauses = new List<double>();
            public int Calls;
            public readonly List<bool> Busy = new List<bool>();
            readonly Func<int, ApiResult> answer;
            readonly Func<int, double> held;
            readonly int max;
            readonly CancellationTokenSource cts = new CancellationTokenSource();

            public LoopRun(CtlRig r, int calls, Func<int, ApiResult> answer, Func<int, double> held = null)
            {
                R = r; max = calls; this.answer = answer; this.held = held ?? (n => 0);
                R.Api.Heartbeat = () =>
                {
                    Calls++;
                    Busy.Add(R.Api.LastState.Busy);
                    R.Now = R.Now.AddSeconds(this.held(Calls));
                    if (Calls >= max) cts.Cancel();   // the loop notices after this answer is handled
                    return this.answer(Calls);
                };
            }

            public void Go()
            {
                // (a pause that is cut short by the loop ending is not recorded, as Task.Delay with a cancelled token would not wait)
                Util.Wait(R.C.HeartbeatLoopAsync(cts.Token, (d, c) => { c.ThrowIfCancellationRequested(); Pauses.Add(d.TotalSeconds); R.Now = R.Now.Add(d); return Task.CompletedTask; }));
            }
        }

        static void LoopTests()
        {
            // the server holds each heartbeat for 25 s and answers empty: the next goes at once, with no pause at all
            var r = new CtlRig();
            r.Start();
            int before = r.Api.Count("heartbeat");
            var run = new LoopRun(r, 4, n => Empty(), n => 25);
            run.Go();
            T.Eq(run.Calls, 4, "four heartbeats");
            T.Eq(run.Pauses.Count, 0, "none of them is followed by a pause: the server's hold is the pause");
            T.Ok(r.Api.Waits.Skip(before).All(w => w == 25), "every one asks to be held up to 25 s");
            T.Ok(r.Api.LastState != null && r.Api.LastPcId == "0123456789abcdef" && r.Api.LastName == "WAR-PC", "and carries the PC, its name and its state as the 30-second heartbeat did");

            // a server that does not hold (an older one) answers at once: never faster than one heartbeat in 5 s
            r = new CtlRig();
            r.Start();
            run = new LoopRun(r, 4, n => Empty(), n => 0);
            run.Go();
            T.Eq(string.Join(",", run.Pauses), "5,5,5", "an empty answer that came back at once waits out 5 s before the next heartbeat (after the last one the loop ends)");
            r = new CtlRig();
            r.Start();
            run = new LoopRun(r, 3, n => Empty(), n => 1.5);
            run.Go();
            T.Eq(string.Join(",", run.Pauses), "3.5,3.5", "what is left of the 5 s");

            // a new offer: the next heartbeat at once; the same offer again, answered at once: 5 s (the server answers at once while an offer waits for a yes)
            r = new CtlRig();
            r.Start();
            run = new LoopRun(r, 5, n => n <= 3 ? FakeApi.OfferReply("jobPoll00001") : FakeApi.OfferReply("jobPoll00002"), n => 0);
            run.Go();
            T.Eq(string.Join(",", run.Pauses), "5,5", "a new offer is news (no pause), the same one again is not (5 s each time), another new one is news again (none)");
            T.Eq(r.C.CurrentOffer == null ? "" : r.C.CurrentOffer.Id, "jobPoll00002", "and every answer is handled: the latest offer is the one the box asks about");

            // an offer that vanishes and comes back is news again
            r = new CtlRig();
            r.Start();
            run = new LoopRun(r, 4, n => n == 2 ? Empty() : FakeApi.OfferReply("jobPoll00003"), n => 0);
            run.Go();
            T.Eq(string.Join(",", run.Pauses), "5", "offer, nothing (5 s), offer again: news, no pause (so the only pause is after the empty answer)");

            // failures: 5 s, 15 s, then 30 s every time; a success starts the count over
            r = new CtlRig();
            r.Start();
            run = new LoopRun(r, 8, n => n == 5 ? Empty() : n == 6 ? FakeApi.Err(503, "unavailable", "Team jobs are not available just yet.") : FakeApi.NetErr(), n => n == 5 ? 25 : 0);
            run.Go();
            T.Eq(string.Join(",", run.Pauses), "5,15,30,30,5,15", "four failures (5, 15, 30, 30 s), a held success (none), then failures count again from the start (5, 15)");
            T.Eq(r.Ui.Status, "Offline: trying again", "the status says what is wrong");

            // a refused heartbeat (500 and friends) is a failure too, and the server's words are kept in the status
            r = new CtlRig();
            r.Start();
            run = new LoopRun(r, 3, n => FakeApi.Err(500, "server_error", "The server could not finish that."), n => 0);
            run.Go();
            T.Eq(string.Join(",", run.Pauses), "5,15", "a server error backs off like no answer");
            T.Eq(r.Ui.Status, "The server could not finish that.", "and says what the server said");
        }

        static void LoopWhileSignedOut()
        {
            // signed out: nothing is sent, the loop looks again every second, and it starts the moment the PC signs in
            var r = new CtlRig(signedIn: false);
            r.Start();
            var cts = new CancellationTokenSource();
            var pauses = new List<double>();
            int heartbeatsBefore = r.Api.Count("heartbeat");
            Util.Wait(r.C.HeartbeatLoopAsync(cts.Token, (d, c) =>
            {
                pauses.Add(d.TotalSeconds);
                if (pauses.Count == 3) { Util.Wait(r.C.SignInAsync("helix", "pw")); r.Api.Heartbeat = () => { cts.Cancel(); return Empty(); }; }
                return Task.CompletedTask;
            }));
            T.Eq(string.Join(",", pauses.Take(3)), "1,1,1", "signed out: the loop looks again every second");
            T.Eq(r.Api.Count("heartbeat") - heartbeatsBefore, 1 + 1, "and sends nothing until then (the sign-in's own heartbeat, then the first long poll)");
            T.Eq(r.Api.Waits.Last(), 25, "the long poll starts after the sign-in");

            // the server says the token is no longer good (401): that is not a failure to back off from; the loop idles until a new sign-in
            r = new CtlRig();
            r.Start();
            var stop = new CancellationTokenSource();
            var idle = new List<double>();
            r.Api.Heartbeat = () => FakeApi.Err(401, "signed_out", "Signed out: sign in to the team app again.");
            Util.Wait(r.C.HeartbeatLoopAsync(stop.Token, (d, c) => { idle.Add(d.TotalSeconds); if (idle.Count == 4) stop.Cancel(); return Task.CompletedTask; }));
            T.Ok(!r.C.SignedIn && r.Ui.SignInCalls >= 1, "a 401 signs the app out");
            T.Eq(string.Join(",", idle), "1,1,1,1", "and the loop idles at one look a second: no back-off, no more heartbeats");
            T.Eq(r.Api.Count("heartbeat"), 2, "one heartbeat was sent (the start) and one answered 401");

            // a 403 not_team stops the app: same
            r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.Err(403, "not_team", "This account is not on the team.");
            stop = new CancellationTokenSource();
            idle = new List<double>();
            Util.Wait(r.C.HeartbeatLoopAsync(stop.Token, (d, c) => { idle.Add(d.TotalSeconds); if (idle.Count == 2) stop.Cancel(); return Task.CompletedTask; }));
            T.Ok(r.C.Stopped && string.Join(",", idle) == "1,1", "not on the team: the app stops and the loop idles");
        }

        static void LoopWithAJob()
        {
            // a job runs: the long poll goes on (it keeps the job alive on the server), and a cancel of that job is news that is acted on at once
            var r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Gate = new TaskCompletionSource<int>();
            r.Start(); r.Offer("jobPoll0000a");
            Task running = r.C.EvaluateAsync();
            T.Ok(WaitUntil(() => r.C.IsBusy && r.Runner.Ran.Count == 1), "a job is running");
            var run = new LoopRun(r, 3, n => n == 2 ? CancelReply("jobPoll0000a") : Empty(), n => 25);
            run.Go();
            T.Ok(run.Busy[0], "the poll says the PC is busy");
            T.Ok(r.Runner.LastCancel.IsCancellationRequested, "a cancel of the job it runs, in an answer to the poll, stops the job");
            T.Eq(string.Join(",", run.Pauses), "", "and none of the three polls was followed by a pause");
            Util.Wait(running);
            T.Eq(r.Api.Count("fail"), 0, "the server is told nothing: it cancelled the job");

            // a cancel that stays in the list (the server keeps it 10 minutes) is not news once the job is gone: the 5 s minimum applies
            r = new CtlRig();
            r.Start();
            run = new LoopRun(r, 3, n => CancelReply("jobPoll0000b"), n => 0);
            run.Go();
            T.Eq(string.Join(",", run.Pauses), "5,5", "a cancel of a job this PC no longer runs is no news: an answer that comes at once waits out the 5 s");
        }

        static void LoopAndTheOthers()
        {
            // an explicit heartbeat (after a sign-in, a mode change, a finished job) asks to be answered at once: wait 0
            var r = new CtlRig();
            r.Start();
            T.Eq(r.Api.LastWait, 0, "the start's heartbeat asks to be answered at once");
            r.Beat();
            T.Eq(r.Api.LastWait, 0, "so does an explicit one");

            // closing the app ends the loop quietly, whether it is between heartbeats or inside one
            r = new CtlRig();
            r.Start();
            var cts = new CancellationTokenSource();
            cts.Cancel();
            Util.Wait(r.C.HeartbeatLoopAsync(cts.Token, (d, c) => Task.CompletedTask));
            T.Eq(r.Api.Waits.Count(w => w == 25), 0, "a cancelled loop sends nothing");
            r = new CtlRig();
            r.Start();
            cts = new CancellationTokenSource();
            int polls = 0;
            r.Api.Heartbeat = () => { polls++; cts.Cancel(); return Empty(); };   // the app closes during the poll: the fake's cancellation check throws
            Util.Wait(r.C.HeartbeatLoopAsync(cts.Token, (d, c) => Task.CompletedTask));
            T.Ok(polls <= 1 && !r.Log.Any(l => l.Contains("error")), "the app closing during a poll ends the loop without an error");

            // the real sleep is Task.Delay: it ends with the token
            r = new CtlRig(signedIn: false);
            cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(80));
            var sw = Stopwatch.StartNew();
            Util.Wait(r.C.HeartbeatLoopAsync(cts.Token));
            T.Ok(sw.Elapsed < TimeSpan.FromSeconds(10), "the default sleep is cancelled with the app (no 1-second wait is left running)");

            // a stopped app (not on the team) sends nothing
            r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.Err(403, "not_team", "This account is not on the team.");
            r.Beat();
            int sent = r.Api.Count("heartbeat");
            cts = new CancellationTokenSource();
            int idles = 0;
            Util.Wait(r.C.HeartbeatLoopAsync(cts.Token, (d, c) => { if (++idles == 3) cts.Cancel(); return Task.CompletedTask; }));
            T.Eq(r.Api.Count("heartbeat"), sent, "a stopped app sends no heartbeat from the loop");
        }

        static bool WaitUntil(Func<bool> c) { var sw = Stopwatch.StartNew(); while (!c() && sw.Elapsed < TimeSpan.FromSeconds(30)) Thread.Sleep(5); return c(); }
    }
}
