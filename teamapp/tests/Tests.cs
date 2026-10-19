using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam.Tests
{
    static class Program
    {
        static int Main()
        {
            JsonTests();
            OfferDecisionTests();
            TextTests();
            JobPlanTests();
            CommandLineTests();
            BenchTests.Run();
            UploadNameTests();
            SettingsTests();
            ApiTests();
            TransportTests();
            FolderTests();
            FetcherTests();
            ProcessHostTests();
            SelfUpdateTests();
            RunnerTests.Run();
            LogCancelTests.Run();
            ControllerTests.Run();
            return T.Done();
        }

        static readonly Uri Site = new Uri("https://muffindevelopment.com/death-muffin/");

        // ---- JSON ---------------------------------------------------------------------------------------------------------------------

        static void JsonTests()
        {
            var d = MiniJson.TryObject("{\"a\":1,\"b\":[true,null,\"x\\ny\\u00e9\"],\"c\":{\"d\":2.5}}");
            T.Ok(d != null, "json parses an object");
            T.Eq(MiniJson.Int(d, "a"), (long?)1, "json whole number");
            T.Eq(MiniJson.Int(MiniJson.Obj(d, "c"), "d"), (long?)null, "json fraction is not an int");
            T.Eq(MiniJson.Arr(d, "b").Count, 3, "json array");
            T.Eq((string)MiniJson.Arr(d, "b")[2], "x\ny\u00e9", "json string escapes");
            T.Ok(MiniJson.TryObject("[1]") == null && MiniJson.TryObject("{") == null && MiniJson.TryObject("") == null && MiniJson.TryObject("{} x") == null, "json rejects arrays, broken text and trailing characters");
            T.Eq(MiniJson.Str(d, "missing"), "", "json missing string");
            T.Eq(MiniJson.Str(d, "a"), "", "json mistyped string");
            string round = MiniJson.Write(new Dictionary<string, object> { { "n", 3.0 }, { "f", 0.5 }, { "s", "a\"b\\c\n\u0001" }, { "l", new List<object> { 1, "x", null, true } }, { "o", new Dictionary<string, object>() } });
            T.Eq(round, "{\"n\":3,\"f\":0.5,\"s\":\"a\\\"b\\\\c\\n\\u0001\",\"l\":[1,\"x\",null,true],\"o\":{}}", "json writer output");
            var back = MiniJson.TryObject(round);
            T.Eq(MiniJson.Str(back, "s"), "a\"b\\c\n\u0001", "json writer round trip");
            T.Throws<FormatException>(() => MiniJson.Write(new object()), "json writer refuses unknown types");
        }

        // ---- The offer decision: every branch -----------------------------------------------------------------------------------------

        static OfferDecision D(OfferMode mode, OfferAnswer a, double minutes, bool fs = false, bool game = false, bool battery = false, bool paused = false, bool afk = false)
        {
            return TeamLogic.Decide(mode, a, TimeSpan.FromMinutes(minutes), fs, game, battery, paused, afk);
        }

        static void OfferDecisionTests()
        {
            // a yes runs in every mode, whatever is in the way (the person said so)
            foreach (OfferMode m in new[] { OfferMode.Ask, OfferMode.Auto, OfferMode.Yes })
            {
                T.Eq(D(m, OfferAnswer.Yes, 0), OfferDecision.Run, "yes runs, mode " + m);
                T.Eq(D(m, OfferAnswer.Yes, 0, fs: true, game: true, battery: true, paused: true), OfferDecision.Run, "yes runs through every exception, mode " + m);
                T.Eq(D(m, OfferAnswer.NotNow, 0), OfferDecision.Decline, "not now declines, mode " + m);
                T.Eq(D(m, OfferAnswer.NotNow, 99), OfferDecision.Decline, "not now declines even after the wait, mode " + m);
                T.Eq(D(m, OfferAnswer.Pause, 0), OfferDecision.Decline, "pause declines, mode " + m);
                T.Eq(D(m, OfferAnswer.None, 0, paused: true), OfferDecision.Decline, "a paused PC declines, mode " + m);
                T.Eq(D(m, OfferAnswer.None, 99, paused: true), OfferDecision.Decline, "a paused PC declines after the wait, mode " + m);
                T.Eq(D(m, OfferAnswer.None, 99, paused: true, fs: true), OfferDecision.Decline, "pause beats an exception, mode " + m);
                // exceptions: wait, never visible, never run
                T.Eq(D(m, OfferAnswer.None, 0, fs: true), OfferDecision.Wait, "full screen waits, mode " + m);
                T.Eq(D(m, OfferAnswer.None, 0, game: true), OfferDecision.Wait, "Death Muffin open waits, mode " + m);
                T.Eq(D(m, OfferAnswer.None, 0, battery: true), OfferDecision.Wait, "battery waits, mode " + m);
                T.Eq(D(m, OfferAnswer.None, 99, fs: true, game: true, battery: true), OfferDecision.Wait, "an unanswered box does not run through an exception, mode " + m);
            }
            T.Eq(D(OfferMode.Ask, OfferAnswer.None, 0), OfferDecision.Ask, "ask: the box is shown");
            T.Eq(D(OfferMode.Ask, OfferAnswer.None, 4.99), OfferDecision.Ask, "ask: still asking at 4:59");
            T.Eq(D(OfferMode.Ask, OfferAnswer.None, 5), OfferDecision.Run, "ask: runs by itself after 5 minutes");
            T.Eq(D(OfferMode.Ask, OfferAnswer.None, 60), OfferDecision.Run, "ask: runs after a long unanswered box");
            T.Eq(D(OfferMode.Auto, OfferAnswer.None, 0), OfferDecision.Run, "auto: runs without asking");
            T.Eq(D(OfferMode.Yes, OfferAnswer.None, 0), OfferDecision.Ask, "yes: asks");
            T.Eq(D(OfferMode.Yes, OfferAnswer.None, 600), OfferDecision.Ask, "yes: never runs by itself");
            // AFK mode: Decide takes the flag, and only mode ask is changed by it
            T.Eq(D(OfferMode.Ask, OfferAnswer.None, 0, afk: true), OfferDecision.Run, "afk: a job runs at once, no box");
            T.Eq(TeamLogic.Decide(OfferMode.Ask, OfferAnswer.None, TimeSpan.Zero, false, false, false, false, true), OfferDecision.Run, "afk: the flag is the 8th argument");
            T.Eq(D(OfferMode.Ask, OfferAnswer.None, 0, fs: true, afk: true), OfferDecision.Wait, "afk: a full-screen app still waits");
            T.Eq(D(OfferMode.Ask, OfferAnswer.None, 0, game: true, afk: true), OfferDecision.Wait, "afk: Death Muffin open still waits");
            T.Eq(D(OfferMode.Ask, OfferAnswer.None, 0, battery: true, afk: true), OfferDecision.Wait, "afk: the battery still waits");
            T.Eq(D(OfferMode.Ask, OfferAnswer.None, 0, paused: true, afk: true), OfferDecision.Decline, "afk: a pause still declines");
            T.Eq(D(OfferMode.Ask, OfferAnswer.NotNow, 0, afk: true), OfferDecision.Decline, "afk: a no still declines");
            T.Eq(D(OfferMode.Yes, OfferAnswer.None, 0, afk: true), OfferDecision.Ask, "afk changes nothing in mode yes");
            T.Eq(D(OfferMode.Auto, OfferAnswer.None, 0, afk: true), OfferDecision.Run, "or in mode auto");
            T.Eq(D(OfferMode.Ask, OfferAnswer.None, 0, afk: false), OfferDecision.Ask, "no afk: the box asks");
            var five = TimeSpan.FromMinutes(5);
            T.Ok(TeamLogic.EntersAfk(OfferMode.Ask, OfferAnswer.None, five, OfferDecision.Run, false), "a box that runs out in mode ask enters AFK mode");
            T.Ok(!TeamLogic.EntersAfk(OfferMode.Ask, OfferAnswer.None, five - TimeSpan.FromSeconds(1), OfferDecision.Run, false), "not before the 5 minutes");
            T.Ok(!TeamLogic.EntersAfk(OfferMode.Ask, OfferAnswer.None, TimeSpan.Zero, OfferDecision.Run, true), "already on: nothing to enter");
            T.Ok(!TeamLogic.EntersAfk(OfferMode.Ask, OfferAnswer.Yes, five, OfferDecision.Run, false), "a yes is a person at the PC");
            T.Ok(!TeamLogic.EntersAfk(OfferMode.Auto, OfferAnswer.None, five, OfferDecision.Run, false), "mode auto never enters it");
            T.Ok(!TeamLogic.EntersAfk(OfferMode.Yes, OfferAnswer.None, five, OfferDecision.Run, false), "mode yes never enters it");
            T.Ok(!TeamLogic.EntersAfk(OfferMode.Ask, OfferAnswer.None, five, OfferDecision.Wait, false) && !TeamLogic.EntersAfk(OfferMode.Ask, OfferAnswer.None, five, OfferDecision.Ask, false) && !TeamLogic.EntersAfk(OfferMode.Ask, OfferAnswer.None, five, OfferDecision.Decline, false), "only a decision to run enters it");
            T.Eq(TeamLogic.AfkEndReason(true, true, false, false), "Death Muffin was started", "afk ends when Death Muffin starts");
            T.Eq(TeamLogic.AfkEndReason(true, false, true, false), "a full-screen app came up", "when a full-screen app comes up");
            T.Eq(TeamLogic.AfkEndReason(true, false, false, true), "the PC was paused", "when the PC is paused");
            T.Eq(TeamLogic.AfkEndReason(true, false, false, false), "", "and not otherwise (the battery does not end it)");
            T.Eq(TeamLogic.AfkEndReason(false, true, true, true), "", "off stays off");
            T.Ok(TeamLogic.LeavesAfk(true, true, false, false) && !TeamLogic.LeavesAfk(true, false, false, false) && !TeamLogic.LeavesAfk(false, true, true, true), "leaves, as a yes or no");
            T.Eq(TeamLogic.AfkText, "AFK mode on: jobs run right away", "the notice's words");
            T.Eq(TeamLogic.AfkEndText, "End AFK mode", "and its button's");
            T.Eq(TeamLogic.DeclineReason(OfferAnswer.NotNow, false), "not_now", "decline reason: not now");
            T.Eq(TeamLogic.DeclineReason(OfferAnswer.Pause, false), "paused", "decline reason: pause");
            T.Eq(TeamLogic.DeclineReason(OfferAnswer.None, true), "paused", "decline reason: paused PC");
            T.Eq(TeamLogic.WaitReason(true, false, false), "a full-screen app is open", "wait reason: full screen");
            T.Eq(TeamLogic.WaitReason(false, true, false), "Death Muffin is open", "wait reason: game");
            T.Eq(TeamLogic.WaitReason(false, false, true), "this PC is on battery", "wait reason: battery");
            T.Eq(TeamLogic.WaitReason(true, true, true), "Death Muffin is open", "wait reason: the game first");
            T.Eq(TeamLogic.WaitReason(false, false, false), "", "wait reason: nothing");
            T.Eq(TeamLogic.AutoRunAfter, TimeSpan.FromMinutes(5), "auto-run after 5 minutes");
            T.Eq(TeamLogic.PauseFor, TimeSpan.FromHours(2), "pause is 2 hours");
            T.Eq(TeamLogic.HeartbeatEvery, TimeSpan.FromSeconds(30), "heartbeat every 30 s");
            T.Eq(TeamLogic.RunLimit, TimeSpan.FromMinutes(10), "10-minute limit");
            T.Eq(TeamLogic.KeepJobFolders, 3, "keeps 3 job folders");
            T.Ok(TeamLogic.PausedAt(new DateTime(2026, 10, 19, 14, 0, 0, DateTimeKind.Utc), new DateTime(2026, 10, 19, 13, 59, 59, DateTimeKind.Utc)), "paused before the end");
            T.Ok(!TeamLogic.PausedAt(new DateTime(2026, 10, 19, 14, 0, 0, DateTimeKind.Utc), new DateTime(2026, 10, 19, 14, 0, 0, DateTimeKind.Utc)), "not paused at the end");
            T.Eq(Modes.Parse("auto"), OfferMode.Auto, "mode auto");
            T.Eq(Modes.Parse("yes"), OfferMode.Yes, "mode yes");
            T.Eq(Modes.Parse("ask"), OfferMode.Ask, "mode ask");
            T.Eq(Modes.Parse("run-everything"), OfferMode.Ask, "unknown mode is ask");
            T.Eq(Modes.Parse(null), OfferMode.Ask, "no mode is ask");
            T.Eq(Modes.Wire(OfferMode.Auto) + Modes.Wire(OfferMode.Yes) + Modes.Wire(OfferMode.Ask), "autoyesask", "mode wire names");
            T.Eq(Modes.Label(OfferMode.Auto), "Run without asking", "mode label auto");
            T.Eq(Modes.Label(OfferMode.Yes), "Only on a yes", "mode label yes");
            T.Eq(Modes.Label(OfferMode.Ask), "Ask", "mode label ask");
        }

        static void TextTests()
        {
            T.Eq(TeamLogic.HowLong(10), "less than a minute", "how long: 10 s");
            T.Eq(TeamLogic.HowLong(45), "about 1 minute", "how long: 45 s");
            T.Eq(TeamLogic.HowLong(60), "about 1 minute", "how long: 60 s");
            T.Eq(TeamLogic.HowLong(89), "about 1 minute", "how long: 89 s");
            T.Eq(TeamLogic.HowLong(90), "about 2 minutes", "how long: 90 s");
            T.Eq(TeamLogic.HowLong(300), "about 5 minutes", "how long: 300 s");
            T.Eq(TeamLogic.HowLong(3600), "about 1 hour", "how long: an hour");
            T.Eq(TeamLogic.HowLong(7200), "about 2 hours", "how long: two hours");
            T.Eq(TeamLogic.OfferText("Screenshots of a change", 60), "Screenshots of a change, about 1 minute", "offer text");
            T.Eq(TeamLogic.OfferText("  ", 60), "A job, about 1 minute", "offer text without a title");
            T.Eq(TeamLogic.Clock(TimeSpan.FromSeconds(252)), "4:12", "clock");
            T.Eq(TeamLogic.Clock(TimeSpan.FromSeconds(-5)), "0:00", "clock never negative");
            T.Eq(TeamLogic.Clock(TimeSpan.FromMinutes(5)), "5:00", "clock 5:00");
            T.Eq(TextClip.Head("a\nb", 10), "a b", "head flattens lines");
            T.Eq(TextClip.Head(new string('x', 500), 400).Length, 400, "head caps the length");
            string tail = TextClip.Tail(new string('a', 100) + "END", 50);
            T.Ok(tail.EndsWith("END") && tail.Length == 50, "tail keeps the end of a log");
            string wide = TextClip.Tail(new string('\u20ac', 1000), 600);
            T.Ok(Encoding.UTF8.GetByteCount(wide) <= 600 && wide.Length > 100, "tail caps UTF-8 bytes, not characters");
            T.Eq(VersionCompare.Compare("0.1.1", "0.1.0"), 1, "version newer");
            T.Eq(VersionCompare.Compare("0.1.0", "0.1.0"), 0, "version same");
            T.Eq(VersionCompare.Compare("0.1.0", "0.2.0"), -1, "version older");
            T.Eq(VersionCompare.Compare("0.10.0", "0.9.0"), 1, "version compares numbers, not text");
            T.Eq(VersionCompare.Compare("1.0.0", "0.99.99"), 1, "version major");
            T.Eq(VersionCompare.Compare("0.1", "0.1.0"), 0, "version missing part is zero");
        }

        // ---- The job payload ----------------------------------------------------------------------------------------------------------

        public static Dictionary<string, object> File_(string name, string cacheKey = null, string url = null, string sha = null, object bytes = null)
        {
            var d = new Dictionary<string, object>
            {
                { "name", name }, { "url", url ?? "https://muffindevelopment.com/death-muffin/team-files/q7x2k9/" + name }, { "sha256", sha ?? new string('a', 64) }, { "bytes", bytes ?? 1234.0 },
            };
            if (cacheKey != null) d["cacheKey"] = cacheKey;
            return d;
        }

        public static Dictionary<string, object> ValidPayload()
        {
            return new Dictionary<string, object>
            {
                { "rev", "0123456789ab" }, { "godotVersion", "4.7.2.stable" },
                { "files", new List<object> { File_("DeathMuffinDebug.pck"), File_("DeathMuffin.assets.pck", "assets-0f3a9c"), File_("libdmcore.windows.template_release.x86_64.dll"), File_("DeathMuffinDebug.exe", "godot-debug-4.7.2") } },
                { "plan", new Dictionary<string, object> { { "bag", "demo" }, { "discipline", "gravecaller" }, { "shots", new List<object> {
                    new Dictionary<string, object> { { "name", "bag-open" }, { "open", "bag" } }, new Dictionary<string, object> { { "name", "hero-front" }, { "view", "hero" } } } } } },
                { "presets", new List<object> { "low", "ultra" } },
                { "args", new List<object> { "--dev-offline", "--class=2", "--qa" } },
            };
        }

        const string GoodUrl = "https://muffindevelopment.com/death-muffin/team-files/q7x2k9/ok.bin";   // a valid address, so a name test fails on the name alone

        static List<object> Files(Dictionary<string, object> p) { return (List<object>)p["files"]; }

        static string Reject(Action<Dictionary<string, object>> mutate, string name, string wantInError = null)
        {
            var p = ValidPayload();
            mutate(p);
            JobPlan plan; string err;
            bool ok = JobPlan.TryParse(p, Site, out plan, out err);
            T.Ok(!ok && plan == null && !string.IsNullOrEmpty(err), "payload refused: " + name + (ok ? " (it was accepted)" : ""));
            if (wantInError != null) T.Has(err, wantInError, "payload refusal says why: " + name);
            if (err != null) T.Ok(!err.Contains("Exception") && !err.Contains(" at "), "payload refusal is plain English: " + name);
            return err;
        }

        static void JobPlanTests()
        {
            JobPlan plan; string error;
            T.Ok(JobPlan.TryParse(ValidPayload(), Site, out plan, out error), "the contract's payload is accepted: " + error);
            T.Eq(plan.Files.Count, 4, "plan files");
            T.Eq(plan.Rev, "0123456789ab", "plan rev");
            T.Eq(plan.GodotVersion, "4.7.2.stable", "plan godot version");
            T.Eq(string.Join(",", plan.Presets), "low,ultra", "plan presets in order");
            T.Eq(plan.PlanShots, 2, "plan shot count");
            T.Eq(plan.FileNamed("DeathMuffin.assets.pck").CacheKey, "assets-0f3a9c", "cache key kept");
            T.Eq(plan.FileNamed("DeathMuffinDebug.exe").CacheKey, "godot-debug-4.7.2", "godot cache key kept");
            T.Ok(!plan.FileNamed("DeathMuffinDebug.pck").IsCached, "the main pack is not cached");
            T.Eq(plan.FileNamed("deathmuffindebug.pck").Name, "DeathMuffinDebug.pck", "file lookup ignores case");
            T.Eq(plan.Args[0], "--dev-offline", "args keep dev-offline first");
            T.Eq(string.Join(" ", plan.Args), "--dev-offline --class=2 --qa", "args as sent");
            var round = MiniJson.TryObject(plan.PlanJson);
            T.Eq(MiniJson.Str(round, "discipline"), "gravecaller", "plan json keeps the proposal's plan");
            T.Eq(MiniJson.Arr(round, "shots").Count, 2, "plan json keeps the shots");

            // the payload may arrive as text
            JobPlan fromText;
            T.Ok(JobPlan.TryParse(MiniJson.Write(ValidPayload()), Site, out fromText, out error) && fromText.Files.Count == 4, "a payload given as JSON text is accepted");
            T.Ok(!JobPlan.TryParse("not json", Site, out fromText, out error) && error.Length > 0, "a payload that is not JSON is refused");
            T.Ok(!JobPlan.TryParse(null, Site, out fromText, out error), "no payload is refused");

            // dev-offline is always there, and never duplicated
            var p2 = ValidPayload(); p2["args"] = new List<object> { "--class=3", "--qa", "--class=3" };
            T.Ok(JobPlan.TryParse(p2, Site, out plan, out error) && string.Join(" ", plan.Args) == "--dev-offline --class=3 --qa", "dev-offline is added once and duplicates are dropped");
            var p3 = ValidPayload(); p3.Remove("args");
            T.Ok(JobPlan.TryParse(p3, Site, out plan, out error) && string.Join(" ", plan.Args) == "--dev-offline", "no args gives dev-offline only");

            // files: names
            Reject(p => Files(p).Add(File_("../evil.dll", url: GoodUrl)), "name with ..", "not allowed");
            Reject(p => Files(p).Add(File_("a..b", url: GoodUrl)), "name containing ..");
            Reject(p => Files(p).Add(File_("/etc/passwd", url: GoodUrl)), "absolute unix path");
            Reject(p => Files(p).Add(File_("C:\\Windows\\evil.exe", url: GoodUrl)), "absolute windows path");
            Reject(p => Files(p).Add(File_("\\\\server\\share\\x.dll", url: GoodUrl)), "UNC path");
            Reject(p => Files(p).Add(File_("sub/x.dll", url: GoodUrl)), "name with a folder");
            Reject(p => Files(p).Add(File_("sub\\x.dll", url: GoodUrl)), "name with a backslash");
            Reject(p => Files(p).Add(File_(".hidden", url: GoodUrl)), "name starting with a dot");
            Reject(p => Files(p).Add(File_("name.", url: GoodUrl)), "name ending with a dot");
            Reject(p => Files(p).Add(File_("", url: GoodUrl)), "empty name");
            Reject(p => Files(p).Add(File_("x y.dll", url: GoodUrl)), "name with a space");
            Reject(p => Files(p).Add(File_("nul.pck", url: GoodUrl)), "Windows device name");
            Reject(p => Files(p).Add(File_("COM1", url: GoodUrl)), "Windows device name COM1");
            Reject(p => Files(p).Add(File_(new string('a', 81), url: GoodUrl)), "name too long");
            Reject(p => Files(p).Add(File_("DEATHMUFFINDEBUG.PCK", url: GoodUrl)), "same name in another case", "twice");
            Reject(p => Files(p).Add(File_("DeathMuffinDebug.pck", url: GoodUrl)), "same name twice", "twice");
            // files: checksum, size, cache key
            Reject(p => Files(p).Add(File_("a.dll", sha: "xyz")), "bad sha256", "checksum");
            Reject(p => Files(p).Add(File_("a.dll", sha: new string('g', 64))), "non-hex sha256");
            Reject(p => Files(p).Add(File_("a.dll", sha: new string('a', 63))), "short sha256");
            Reject(p => Files(p).Add(File_("a.dll", sha: "")), "empty sha256");
            Reject(p => Files(p).Add(File_("a.dll", bytes: 0.0)), "zero bytes", "size");
            Reject(p => Files(p).Add(File_("a.dll", bytes: -5.0)), "negative bytes");
            Reject(p => Files(p).Add(File_("a.dll", bytes: 1.5)), "fractional bytes");
            Reject(p => Files(p).Add(File_("a.dll", bytes: "100")), "bytes as text");
            Reject(p => Files(p).Add(File_("a.dll", bytes: 9e12)), "absurd size");
            Reject(p => Files(p).Add(File_("a.dll", cacheKey: "../../x")), "cache key with ..", "cache");
            Reject(p => Files(p).Add(File_("a.dll", cacheKey: "a/b")), "cache key with a slash");
            Reject(p => Files(p).Add(File_("a.dll", cacheKey: "A-Upper")), "cache key in capitals");
            Reject(p => Files(p).Add(File_("a.dll", cacheKey: ".hidden")), "cache key starting with a dot");
            // files: URLs
            Reject(p => Files(p).Add(File_("a.dll", url: "https://evil.example/death-muffin/team-files/x/a.dll")), "another host", "not on the game's server");
            Reject(p => Files(p).Add(File_("a.dll", url: "https://muffindevelopment.com.evil.example/death-muffin/team-files/x/a.dll")), "lookalike host");
            Reject(p => Files(p).Add(File_("a.dll", url: "http://muffindevelopment.com/death-muffin/team-files/x/a.dll")), "plain http");
            Reject(p => Files(p).Add(File_("a.dll", url: "https://muffindevelopment.com:8443/death-muffin/team-files/x/a.dll")), "another port");
            Reject(p => Files(p).Add(File_("a.dll", url: "https://muffindevelopment.com/death-muffin/client/DeathMuffin.exe")), "outside the team files folder", "team files folder");
            Reject(p => Files(p).Add(File_("a.dll", url: "https://muffindevelopment.com/death-muffin/team-files/")), "the folder itself");
            Reject(p => Files(p).Add(File_("a.dll", url: "https://muffindevelopment.com/death-muffin/team-files/../client/a.dll")), "dot-dot in the url");
            Reject(p => Files(p).Add(File_("a.dll", url: "https://muffindevelopment.com/death-muffin/team-files/%2e%2e/client/a.dll")), "encoded dot-dot");
            Reject(p => Files(p).Add(File_("a.dll", url: "https://muffindevelopment.com/death-muffin/team-files/x%2Fa.dll")), "encoded slash");
            Reject(p => Files(p).Add(File_("a.dll", url: "https://user:pw@muffindevelopment.com/death-muffin/team-files/x/a.dll")), "user info in the url");
            Reject(p => Files(p).Add(File_("a.dll", url: "https://muffindevelopment.com/death-muffin/team-files/x/a.dll?x=1")), "query in the url");
            Reject(p => Files(p).Add(File_("a.dll", url: "https://muffindevelopment.com/death-muffin/team-files/x/a.dll#frag")), "fragment in the url");
            Reject(p => Files(p).Add(File_("a.dll", url: "\\\\evil\\share\\a.dll")), "a UNC url");
            Reject(p => Files(p).Add(File_("a.dll", url: "file:///C:/Windows/a.dll")), "a file url");
            Reject(p => Files(p).Add(File_("a.dll", url: "")), "no url");
            Reject(p => Files(p).Add(File_("a.dll", url: "a.dll")), "a relative url");
            // files: the list
            Reject(p => p.Remove("files"), "no files", "no files");
            Reject(p => p["files"] = new List<object>(), "empty files");
            Reject(p => p["files"] = "files", "files as text");
            Reject(p => Files(p).Add("DeathMuffinDebug.pck"), "a file entry that is text");
            Reject(p => { for (int i = 0; i < 12; i++) Files(p).Add(File_("extra" + i + ".dll")); }, "too many files", "too many");
            Reject(p => Files(p).RemoveAll(f => (string)((Dictionary<string, object>)f)["name"] == "DeathMuffinDebug.exe"), "no game exe", "DeathMuffinDebug.exe");
            Reject(p => Files(p).RemoveAll(f => (string)((Dictionary<string, object>)f)["name"] == "DeathMuffinDebug.pck"), "no main pack", "DeathMuffinDebug.pck");
            // revision, version
            Reject(p => p["rev"] = "not-a-rev", "bad rev");
            Reject(p => p["godotVersion"] = "4.7.2 && calc", "bad godot version");
            // plan
            Reject(p => p.Remove("plan"), "no plan", "no shot plan");
            Reject(p => p["plan"] = new Dictionary<string, object> { { "shots", new List<object>() } }, "empty shot list");
            Reject(p => p["plan"] = new Dictionary<string, object> { { "bag", "demo" } }, "plan without shots");
            Reject(p => p["plan"] = "plan", "plan as text");
            Reject(p => ((Dictionary<string, object>)p["plan"])["pad"] = new string('x', 70000), "plan too big", "too big");
            // presets
            Reject(p => p.Remove("presets"), "no presets", "preset");
            Reject(p => p["presets"] = new List<object>(), "empty presets");
            Reject(p => p["presets"] = new List<object> { "low", "low" }, "duplicate preset", "twice");
            Reject(p => p["presets"] = new List<object> { "potato" }, "unknown preset", "does not exist");
            Reject(p => p["presets"] = new List<object> { "../low" }, "preset with a path");
            Reject(p => p["presets"] = new List<object> { "low", "medium", "high", "ultra", "low" }, "five presets");
            Reject(p => p["presets"] = new List<object> { 1.0 }, "preset as a number");
            // args
            Reject(p => p["args"] = new List<object> { "--shots=C:/x" }, "args: --shots", "--shots");
            Reject(p => p["args"] = new List<object> { "--shot-plan=x.json" }, "args: --shot-plan");
            Reject(p => p["args"] = new List<object> { "--preset=ultra" }, "args: --preset");
            Reject(p => p["args"] = new List<object> { "--online" }, "args: --online");
            Reject(p => p["args"] = new List<object> { "--audio-driver" }, "args: --audio-driver", "--audio-driver");
            Reject(p => p["args"] = new List<object> { "--audio-driver=ALSA" }, "args: --audio-driver with a value", "--audio-driver");
            Reject(p => p["args"] = new List<object> { "--position=0,0" }, "args: --position", "--position");
            Reject(p => p["args"] = new List<object> { "--benchmark" }, "args: --benchmark", "--benchmark");
            Reject(p => p["args"] = new List<object> { "--assets-pack=evil.pck" }, "args: --assets-pack");
            Reject(p => p["args"] = new List<object> { "--baked=x" }, "args: --baked");
            Reject(p => p["args"] = new List<object> { "--bench-dir=x" }, "args: --bench-dir");
            Reject(p => p["args"] = new List<object> { "--shot=x" }, "args: --shot");
            Reject(p => p["args"] = new List<object> { "--class=C:/x" }, "args: a path in a value");
            Reject(p => p["args"] = new List<object> { "--class=../x" }, "args: dot-dot in a value");
            Reject(p => p["args"] = new List<object> { "--class=\\\\evil\\x" }, "args: a UNC value");
            Reject(p => p["args"] = new List<object> { "-class=2" }, "args: one dash");
            Reject(p => p["args"] = new List<object> { "class=2" }, "args: no dashes");
            Reject(p => p["args"] = new List<object> { "--" }, "args: a bare separator");
            Reject(p => p["args"] = new List<object> { "--class=2 --online" }, "args: two options in one");
            Reject(p => p["args"] = new List<object> { "--main-pack=x" }, "args: main-pack with a value");
            Reject(p => p["args"] = new List<object> { "--Class=2" }, "args: capitals");
            Reject(p => p["args"] = new List<object> { 5.0 }, "args: a number");
            Reject(p => p["args"] = Enumerable.Range(0, 17).Select(i => (object)("--a" + i)).ToList(), "args: too many");
            Reject(p => p["args"] = "--qa", "args: text instead of a list");
            T.Ok(JobPlan.TryParse(ValidPayload(), new Uri("https://muffindevelopment.com/death-muffin/"), out plan, out error), "valid payload still accepted after the refusals");
            // a different site base moves the rule with it (tests run against a local server)
            JobPlan local;
            T.Ok(!JobPlan.TryParse(ValidPayload(), new Uri("http://127.0.0.1:9/death-muffin/"), out local, out error), "the payload's host must be the app's server");
        }

        // ---- Command lines -------------------------------------------------------------------------------------------------------------

        /// <summary>CommandLineToArgvW's rules, to read back what Quote wrote.</summary>
        static List<string> ParseWinArgs(string line)
        {
            var args = new List<string>();
            int i = 0;
            while (i < line.Length)
            {
                while (i < line.Length && (line[i] == ' ' || line[i] == '\t')) i++;
                if (i >= line.Length) break;
                var sb = new StringBuilder();
                bool inQuotes = false;
                while (i < line.Length && (inQuotes || (line[i] != ' ' && line[i] != '\t')))
                {
                    int slashes = 0;
                    while (i < line.Length && line[i] == '\\') { slashes++; i++; }
                    if (i < line.Length && line[i] == '"')
                    {
                        sb.Append('\\', slashes / 2);
                        if (slashes % 2 == 1) { sb.Append('"'); }
                        else inQuotes = !inQuotes;
                        i++;
                    }
                    else
                    {
                        sb.Append('\\', slashes);
                        if (i < line.Length && (inQuotes || (line[i] != ' ' && line[i] != '\t'))) { sb.Append(line[i]); i++; }
                    }
                }
                args.Add(sb.ToString());
            }
            return args;
        }

        static void CommandLineTests()
        {
            JobPlan plan; string error;
            JobPlan.TryParse(ValidPayload(), Site, out plan, out error);
            string planFile = "C:\\Users\\Test User\\AppData\\Local\\DeathMuffinTeam\\jobs\\q7x2k9ab\\plan.json";
            string shots = "C:\\Users\\Test User\\AppData\\Local\\DeathMuffinTeam\\jobs\\q7x2k9ab\\out\\low";
            var a = plan.CommandArgs("low", planFile, shots);
            T.Eq(string.Join("|", a),
                "--windowed|--resolution|1600x900|--audio-driver|Dummy|--|--dev-offline|--class=2|--qa|--shot-plan=C:/Users/Test User/AppData/Local/DeathMuffinTeam/jobs/q7x2k9ab/plan.json|--shots=C:/Users/Test User/AppData/Local/DeathMuffinTeam/jobs/q7x2k9ab/out/low|--preset=low",
                "command arguments for low (the contract's line)");
            T.Eq(plan.CommandArgs("ultra", planFile, shots.Replace("low", "ultra")).Last(), "--preset=ultra", "command arguments for ultra");
            T.Eq(plan.CommandLine("low", "C:\\j\\plan.json", "C:\\j\\out\\low"),
                "--windowed --resolution 1600x900 --audio-driver Dummy -- --dev-offline --class=2 --qa --shot-plan=C:/j/plan.json --shots=C:/j/out/low --preset=low",
                "command line without spaces needs no quotes");
            string line = plan.CommandLine("low", planFile, shots);
            T.Has(line, "\"--shot-plan=C:/Users/Test User/AppData/Local/DeathMuffinTeam/jobs/q7x2k9ab/plan.json\"", "a path with a space is quoted");
            T.Eq(string.Join("|", ParseWinArgs(line)), string.Join("|", a), "the command line reads back as the same arguments");
            T.Eq(plan.CommandArgs("low", "p", "s").IndexOf("--"), 5, "everything for the game comes after --");
            T.Eq(string.Join(" ", a.Take(5)), "--windowed --resolution 1600x900 --audio-driver Dummy", "the game is silent: the Dummy audio driver still mixes, so its cost stays real");

            // screenshot jobs keep the window outside every monitor
            var off = plan.CommandArgs("low", planFile, shots, "-1700,0");
            T.Eq(string.Join(" ", off.Take(8)), "--windowed --resolution 1600x900 --audio-driver Dummy --position -1700,0 --", "--position goes ahead of --, after the audio driver");
            T.Eq(off.IndexOf("--"), 7, "and everything for the game still comes after --");
            T.Eq(string.Join("|", off.Skip(8)), string.Join("|", a.Skip(6)), "the game's own options are the same");
            T.Eq(plan.CommandLine("low", "C:\\j\\plan.json", "C:\\j\\out\\low", "-3620,-200"),
                "--windowed --resolution 1600x900 --audio-driver Dummy --position -3620,-200 -- --dev-offline --class=2 --qa --shot-plan=C:/j/plan.json --shots=C:/j/out/low --preset=low", "the command line with a position");
            T.Ok(!a.Contains("--position") && !plan.CommandArgs("low", "p", "s", "").Contains("--position"), "no position given, none is set");
            T.Eq(ParseWinArgs(plan.CommandLine("low", planFile, shots, "-1700,0")).Count(x => x == "-1700,0"), 1, "a negative position is one argument");

            // the position: 1700 px left of the virtual screen (the window is 1600 wide), level with its top
            T.Eq(JobPlan.OffscreenPosition(0, 0), "-1700,0", "one monitor at 0,0");
            T.Eq(JobPlan.OffscreenPosition(-1920, 0), "-3620,0", "a monitor left of the main one: left of that");
            T.Eq(JobPlan.OffscreenPosition(0, -1080), "-1700,-1080", "a monitor above the main one: level with its top");
            T.Eq(JobPlan.OffscreenPosition(-1920, -200), "-3620,-200", "both");
            T.Eq(JobPlan.OffscreenPosition(100, 50), "-1600,50", "a virtual screen that starts right of 0");
            int width = int.Parse(JobPlan.Resolution.Split('x')[0]);
            foreach (int left in new[] { 0, -1920, -3840, 200 })
            {
                int x = int.Parse(JobPlan.OffscreenPosition(left, 0).Split(',')[0]);
                T.Ok(x + width < left, "the window (" + width + " px wide) ends left of the virtual screen at " + left + " (x " + x + ")");
            }

            T.Eq(CommandLineText.Quote("plain"), "plain", "quote: plain");
            T.Eq(CommandLineText.Quote(""), "\"\"", "quote: empty");
            T.Eq(CommandLineText.Quote("a b"), "\"a b\"", "quote: space");
            T.Eq(CommandLineText.Quote("a\"b"), "\"a\\\"b\"", "quote: a quote");
            T.Eq(CommandLineText.Quote("C:\\dir\\"), "C:\\dir\\", "quote: trailing backslash without a space");
            T.Eq(CommandLineText.Quote("C:\\my dir\\"), "\"C:\\my dir\\\\\"", "quote: trailing backslash in quotes is doubled");
            foreach (string s in new[] { "plain", "a b", "a\"b", "C:\\dir\\", "C:\\my dir\\", "a\\\"b c", "\\\\server\\share name\\x", "  lead", "tab\there", "q\"\"q", "end\\\\", "\"", "\\\"", "x y\\\\\"z", "--shot-plan=C:/a b/c.json" })
                T.Eq(ParseWinArgs(CommandLineText.Quote(s)).SingleOrDefault(), s, "quote round trip: " + s);
        }

        // ---- Upload names --------------------------------------------------------------------------------------------------------------

        static void UploadNameTests()
        {
            var name = new Regex("^[a-z0-9_-]{1,60}\\.png$");
            T.Eq(JobPlan.UploadName("low", "bag-open.png"), "low_bag-open.png", "upload name");
            T.Eq(JobPlan.UploadName("ultra", "C:\\x\\out\\ultra\\hero-front.png"), "ultra_hero-front.png", "upload name from a path");
            T.Eq(JobPlan.UploadName("low", "Bag Open!.PNG"), "low_bag_open.png", "upload name is cleaned and lower-cased");
            T.Eq(JobPlan.UploadName("low", "notes.txt"), null, "only pictures are uploaded");
            T.Eq(JobPlan.UploadName("low", "x.png.txt"), null, "a name that only contains .png is not a picture");
            T.Eq(JobPlan.UploadName("low", "!!!.png"), "low_shot.png", "an empty shot name gets a placeholder");
            foreach (string preset in new[] { "low", "medium", "high", "ultra" })
                foreach (string shot in new[] { "a", new string('x', 40) + ".png", new string('y', 200) + ".png", "caf\u00e9 \u00fcber.png", "UPPER_case-1.png", "..png" })
                {
                    string n = JobPlan.UploadName(preset, shot.EndsWith(".png") ? shot : shot + ".png");
                    T.Ok(n != null && name.IsMatch(n), "upload name matches the server's rule: " + preset + " " + (shot.Length > 20 ? shot.Substring(0, 20) : shot) + " -> " + n);
                }
            var used = new HashSet<string>();
            var list = JobPlan.UploadNames("low", new[] { "z:/o/b.png", "z:/o/a.png", "z:/o/A.png", "z:/o/readme.txt", "z:/o/a!.png" }, used);
            T.Eq(string.Join(",", list.Select(k => k.Value)), "low_a.png,low_a-2.png,low_a-3.png,low_b.png", "names are unique (a second a becomes a-2) and non-pictures are skipped");
            var second = JobPlan.UploadNames("ultra", new[] { "z:/u/a.png" }, used);
            T.Eq(second[0].Value, "ultra_a.png", "the same shot on another preset keeps its own name");
            var many = JobPlan.UploadNames("low", Enumerable.Range(0, 30).Select(i => "z:/o/" + new string('s', 60) + ".png"), new HashSet<string>());
            T.Ok(many.Select(k => k.Value).Distinct().Count() == 30 && many.All(k => name.IsMatch(k.Value)), "long colliding names stay unique and valid");
            T.Eq(JobPlan.PresetLabel("low"), "Low", "preset label");
        }

        // ---- Settings ------------------------------------------------------------------------------------------------------------------

        static void SettingsTests()
        {
            var prot = new FakeProtector();
            var s = new TeamSettings { Username = "Helix", Token = "TOKEN-SECRET", Mode = OfferMode.Auto };
            s.EnsurePcId();
            s.PausedUntilUtc = new DateTime(2026, 10, 19, 14, 30, 0, DateTimeKind.Utc);
            string json = s.ToJson(prot);
            T.Ok(!json.Contains("TOKEN-SECRET"), "the token is never written in plain text");
            T.Ok(!json.ToLowerInvariant().Contains("password") && !json.Contains("keepSignedIn"), "no password (or keep-signed-in) key is ever written");
            T.Has(json, "\"mode\":\"auto\"", "settings keep the mode");
            var back = TeamSettings.FromJson(json, prot);
            T.Eq(back.Username, "Helix", "settings round trip: username");
            T.Eq(back.Token, "TOKEN-SECRET", "settings round trip: token");
            T.Eq(back.PcId, s.PcId, "settings round trip: pc id");
            T.Eq(back.Mode, OfferMode.Auto, "settings round trip: mode");
            T.Eq(back.PausedUntilUtc, s.PausedUntilUtc, "settings round trip: pause");
            T.Ok(back.SignedIn, "signed in with a token");
            T.Ok(s.PcId.Length == 32 && Regex.IsMatch(s.PcId, "^[A-Za-z0-9_-]{8,64}$"), "pc id fits the server's rule");
            string again = s.PcId; s.EnsurePcId();
            T.Eq(s.PcId, again, "pc id is made once");

            // a file from an older build that still holds a password: it is not read, and the next save drops it
            string oldJson = "{\"username\":\"Helix\",\"token\":\"" + prot.Protect("T") + "\",\"keepSignedIn\":true,\"password\":\"" + prot.Protect("PW-OLD") + "\"}";
            var old = TeamSettings.FromJson(oldJson, prot);
            T.Ok(old.Token == "T" && !old.ToJson(prot).Contains("PW-OLD") && !old.ToJson(prot).Contains(prot.Protect("PW-OLD")), "an old stored password is ignored and not written back");

            prot.Fail = true;
            var lost = TeamSettings.FromJson(json, prot);
            T.Ok(!lost.SignedIn && lost.Token == "", "a token this Windows user cannot open signs the person out");
            T.Eq(lost.Username, "Helix", "the name stays so the sign-in box can offer it");
            prot.Fail = false;

            var broken = TeamSettings.FromJson("{not json", prot);
            T.Ok(!broken.SignedIn && broken.Mode == OfferMode.Ask && broken.PcId == "", "broken settings give the defaults");
            var odd = TeamSettings.FromJson("{\"mode\":\"yolo\",\"pcId\":\"../../x\",\"pausedUntil\":\"soon\",\"token\":5}", prot);
            T.Ok(odd.Mode == OfferMode.Ask && odd.PcId == "" && odd.PausedUntilUtc == DateTime.MinValue && !odd.SignedIn, "mistyped or unsafe values fall back to defaults");
            T.Ok(!new TeamSettings().IsPaused(DateTime.UtcNow), "a new PC is not paused");
            T.Ok(s.IsPaused(s.PausedUntilUtc.AddMinutes(-1)) && !s.IsPaused(s.PausedUntilUtc.AddMinutes(1)), "pause ends at its time");
            s.ClearSignIn();
            T.Ok(!s.SignedIn && s.Token == "", "clear sign-in");

            string dir = Util.TempDir("settings");
            try
            {
                string file = Path.Combine(dir, "sub", "settings.json");
                s.Token = "T2";
                s.Save(prot, file);
                T.Ok(File.Exists(file) && !File.Exists(file + ".tmp"), "settings save creates the folder and leaves no temp file");
                s.Mode = OfferMode.Yes; s.Save(prot, file);
                var loaded = TeamSettings.Load(prot, file);
                T.Ok(loaded.Token == "T2" && loaded.Mode == OfferMode.Yes, "settings save replaces and loads");
                T.Ok(!TeamSettings.Load(prot, Path.Combine(dir, "none.json")).SignedIn, "no settings file is a fresh PC");
            }
            finally { Util.Rm(dir); }
        }

        // ---- The server calls -----------------------------------------------------------------------------------------------------------

        sealed class FakeTransport : ITransport
        {
            public sealed class Req { public string Method; public Uri Url; public string Token; public byte[] Body; public string ContentType; }
            public readonly List<Req> Sent = new List<Req>();
            public Func<Req, HttpReply> Respond = r => new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{}}" };
            public Task<HttpReply> SendAsync(string method, Uri url, string token, byte[] body, string contentType, CancellationToken ct)
            {
                var r = new Req { Method = method, Url = url, Token = token, Body = body, ContentType = contentType };
                Sent.Add(r);
                return Task.FromResult(Respond(r));
            }
        }

        static Dictionary<string, object> BodyOf(FakeTransport.Req r) { return MiniJson.TryObject(Encoding.UTF8.GetString(r.Body)); }

        static void ApiTests()
        {
            var tr = new FakeTransport();
            var api = new TeamApi(tr, new Uri(TeamUrls.ApiBase)) { Token = "team-tok-1" };
            Func<ApiResult> beat = () => Util.Wait(api.HeartbeatAsync("0123456789abcdef", "n", "v", "g", OfferMode.Ask, new PcState(), CancellationToken.None));

            // team sign-in: the new route, no token sent, nothing about the game's login
            tr.Respond = r => new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{\"token\":\"abc.def.ghi\",\"expiresAt\":\"2027-01-17T12:00:00Z\",\"accountId\":100,\"username\":\"Helix\"}}" };
            var login = Util.Wait(api.LoginAsync("helix", "pw", "0123456789abcdef", "WAR-PC", CancellationToken.None));
            T.Ok(login.Ok && MiniJson.Str(login.Data, "token") == "abc.def.ghi" && MiniJson.Str(login.Data, "username") == "Helix" && MiniJson.Int(login.Data, "accountId") == 100, "login reads the token, the account and its name");
            T.Eq(MiniJson.Str(login.Data, "expiresAt"), "2027-01-17T12:00:00Z", "login reads when the token ends");
            T.Eq(tr.Sent[0].Url.ToString(), "https://muffindevelopment.com/death-muffin/api/team/login", "login goes to the team login route, in the style of the other team routes");
            T.Eq(tr.Sent[0].Method, "POST", "login is a POST");
            T.Eq(tr.Sent[0].Token, "", "login sends no token (not even the one the app holds)");
            var lb = BodyOf(tr.Sent[0]);
            T.Eq(MiniJson.Str(lb, "username") + "/" + MiniJson.Str(lb, "password") + "/" + MiniJson.Str(lb, "pcId") + "/" + MiniJson.Str(lb, "pcName"), "helix/pw/0123456789abcdef/WAR-PC", "login body: username, password, pcId, pcName");
            T.Eq(lb.Count, 4, "and nothing else");
            Util.Wait(api.LoginAsync("helix", "pw", "0123456789abcdef", new string('P', 100), CancellationToken.None));
            T.Eq(MiniJson.Str(BodyOf(tr.Sent.Last()), "pcName").Length, 64, "the pc name is capped at 64");
            int sentBefore = tr.Sent.Count;
            T.Ok(!Util.Wait(api.LoginAsync("helix", "pw", "short", "n", CancellationToken.None)).Ok && tr.Sent.Count == sentBefore, "a bad pc id is refused without a request");
            tr.Respond = r => new HttpReply { Status = 401, Body = "{\"success\":false,\"code\":\"bad_login\",\"error\":\"Invalid username or password.\"}" };
            login = Util.Wait(api.LoginAsync("helix", "bad", "0123456789abcdef", "n", CancellationToken.None));
            T.Ok(!login.Ok && login.Error == "Invalid username or password.", "a wrong password shows the server's own text");
            tr.Respond = r => new HttpReply { Status = 403, Body = "{\"success\":false,\"code\":\"not_team\",\"error\":\"This account is not on the team.\"}" };
            login = Util.Wait(api.LoginAsync("someone", "pw", "0123456789abcdef", "n", CancellationToken.None));
            T.Ok(!login.Ok && login.NotTeam && login.Error == "This account is not on the team.", "403 not_team on the sign-in");
            tr.Respond = r => new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{\"accountId\":100}}" };
            T.Ok(!Util.Wait(api.LoginAsync("a", "b", "0123456789abcdef", "n", CancellationToken.None)).Ok, "an answer without a token is not a sign-in");

            // every other route sends `Authorization: Team <token>` (the transport turns the token into that header)
            tr.Respond = r => new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{\"offer\":null}}" };
            T.Ok(beat().Ok, "heartbeat ok");
            T.Eq(tr.Sent.Last().Token, "team-tok-1", "team routes send the team token");
            T.Eq(TeamApi.AuthScheme, "Team", "the authorization scheme is Team");
            tr.Respond = r => new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{}}" };
            tr.Sent.Clear();
            Util.Wait(api.ClaimAsync("ab12cd34ef56", "0123456789abcdef", CancellationToken.None));
            Util.Wait(api.DeclineAsync("ab12cd34ef56", "0123456789abcdef", "paused", CancellationToken.None));
            Util.Wait(api.UploadAsync("ab12cd34ef56", "low_a.png", Util.FakePng(1), CancellationToken.None));
            Util.Wait(api.DoneAsync("ab12cd34ef56", new List<string> { "low_a.png" }, "l", 1, 2, CancellationToken.None));
            Util.Wait(api.FailAsync("ab12cd34ef56", "e", "l", CancellationToken.None));
            Util.Wait(api.LogoutAsync(CancellationToken.None));
            T.Ok(tr.Sent.Count == 6 && tr.Sent.All(r => r.Token == "team-tok-1"), "claim, decline, upload, done, fail and logout all carry the team token");

            // logout
            Util.Wait(api.LogoutAsync(CancellationToken.None));
            T.Eq(tr.Sent.Last().Method + " " + tr.Sent.Last().Url, "POST https://muffindevelopment.com/death-muffin/api/team/logout", "logout is POST /team/logout");
            T.Eq(tr.Sent.Last().Token, "team-tok-1", "and says whose token it ends");

            // errors
            tr.Respond = r => new HttpReply { Status = 403, Body = "{\"success\":false,\"code\":\"not_team\",\"error\":\"This account is not on the team.\"}" };
            var nt = beat();
            T.Ok(!nt.Ok && nt.NotTeam && nt.Error == "This account is not on the team.", "403 not_team");
            tr.Respond = r => new HttpReply { Status = 503, Body = "{\"success\":false,\"code\":\"unavailable\",\"error\":\"The team service is not ready yet.\"}" };
            var un = beat();
            T.Ok(!un.Ok && un.Status == 503 && un.Error == "The team service is not ready yet.", "503 unavailable passes the server's text on");
            tr.Respond = r => new HttpReply { Status = 401, Body = "{\"success\":false,\"code\":\"signed_out\",\"error\":\"You are signed out.\"}" };
            var so = beat();
            T.Ok(!so.Ok && so.SignedOut && so.Code == "signed_out" && !so.NotTeam, "401 signed_out is signed out");
            tr.Respond = r => new HttpReply { Status = 401, Body = "{\"error\":\"invalid token\"}" };
            T.Ok(beat().SignedOut, "any 401 on a team route means signed out");
            tr.Respond = r => new HttpReply { Status = 401, Body = "{\"success\":false}" };
            T.Eq(beat().Error, TeamApi.SignedOutText, "a 401 without words gets the signed-out sentence");
            T.Eq(TeamApi.SignedOutText, "Signed out: sign in to the team app again.", "the signed-out sentence");
            tr.Respond = r => new HttpReply { Status = 409, Body = "{\"success\":false,\"code\":\"taken\",\"error\":\"Another PC took this job.\"}" };
            T.Ok(Util.Wait(api.ClaimAsync("job1", "pc123456", CancellationToken.None)).Taken, "409 taken");
            tr.Respond = r => new HttpReply { Status = 502, Body = "<html>Bad gateway</html>" };
            var bad = beat();
            T.Ok(!bad.Ok && bad.Error == "The server answered with an error (HTTP 502).", "a proxy error page becomes a sentence");
            tr.Respond = r => new HttpReply { NetworkError = "connection refused" };
            var net = beat();
            T.Ok(!net.Ok && net.Network && net.Error.Contains("Could not reach the server"), "no answer at all");
            tr.Respond = r => new HttpReply { Status = 200, Body = "{\"success\":false,\"error\":\"no\"}" };
            T.Ok(!beat().Ok, "success:false is a failure even on HTTP 200");

            // heartbeat
            tr.Sent.Clear();
            tr.Respond = r => new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{\"serverTime\":\"2026-10-19T12:00:00Z\",\"offer\":{\"id\":\"ab12cd34ef56\",\"kind\":\"shots\",\"title\":\"Screenshots of a change\",\"weightS\":60,\"expiresAt\":\"2026-10-19T13:00:00Z\"}}}" };
            var hb = Util.Wait(api.HeartbeatAsync("0123456789abcdef", "WAR-PC", "0.1.0", new string('G', 300), OfferMode.Auto,
                new PcState { GameRunning = true, Fullscreen = false, OnBattery = true, Busy = false, Paused = true }, CancellationToken.None));
            var hbBody = BodyOf(tr.Sent[0]);
            T.Eq(tr.Sent[0].Url.ToString(), "https://muffindevelopment.com/death-muffin/api/team/heartbeat", "heartbeat route");
            T.Eq(MiniJson.Str(hbBody, "pcId") + "|" + MiniJson.Str(hbBody, "name") + "|" + MiniJson.Str(hbBody, "version") + "|" + MiniJson.Str(hbBody, "mode"), "0123456789abcdef|WAR-PC|0.1.0|auto", "heartbeat body fields");
            T.Eq(MiniJson.Str(hbBody, "gpu").Length, 120, "heartbeat caps the gpu name at 120");
            var st = MiniJson.Obj(hbBody, "state");
            T.Ok(MiniJson.Bool(st, "gameRunning") && !MiniJson.Bool(st, "fullscreen") && MiniJson.Bool(st, "onBattery") && !MiniJson.Bool(st, "busy") && MiniJson.Bool(st, "paused"), "heartbeat state flags");
            T.Eq(st.Count, 5, "heartbeat state has exactly the five contract keys");
            var offer = TeamApi.ParseOffer(hb);
            T.Ok(offer != null && offer.Id == "ab12cd34ef56" && offer.Kind == "shots" && offer.WeightS == 60 && offer.Title == "Screenshots of a change", "heartbeat offer is read");
            tr.Respond = r => new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{\"serverTime\":\"x\",\"offer\":null}}" };
            T.Ok(TeamApi.ParseOffer(Util.Wait(api.HeartbeatAsync("0123456789abcdef", "n", "v", "g", OfferMode.Ask, new PcState(), CancellationToken.None))) == null, "no offer");
            T.Ok(TeamApi.ParseOffer(new ApiResult { Ok = true, Data = new Dictionary<string, object> { { "offer", new Dictionary<string, object> { { "id", "../x" } } } } }) == null, "an offer with an unsafe id is ignored");
            tr.Sent.Clear();
            var badId = Util.Wait(api.HeartbeatAsync("short", "n", "v", "g", OfferMode.Ask, new PcState(), CancellationToken.None));
            T.Ok(!badId.Ok && tr.Sent.Count == 0, "a bad pc id is refused without a request");

            // claim, decline
            tr.Respond = r => new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{\"id\":\"ab12cd34ef56\",\"kind\":\"shots\",\"title\":\"T\",\"payload\":{\"rev\":\"0123456789ab\"}}}" };
            var claim = Util.Wait(api.ClaimAsync("ab12cd34ef56", "0123456789abcdef", CancellationToken.None));
            T.Eq(tr.Sent.Last().Url.AbsolutePath, "/death-muffin/api/team/jobs/ab12cd34ef56/claim", "claim route");
            T.Eq(MiniJson.Str(BodyOf(tr.Sent.Last()), "pcId"), "0123456789abcdef", "claim body");
            var job = TeamApi.ParseClaim(claim);
            T.Ok(job != null && job.Id == "ab12cd34ef56" && job.Kind == "shots" && ((Dictionary<string, object>)job.Payload).ContainsKey("rev"), "claim reads the job");
            T.Ok(TeamApi.ParseClaim(new ApiResult { Ok = false }) == null, "a failed claim has no job");
            Util.Wait(api.DeclineAsync("ab12cd34ef56", "0123456789abcdef", "not_now", CancellationToken.None));
            T.Eq(tr.Sent.Last().Url.AbsolutePath, "/death-muffin/api/team/jobs/ab12cd34ef56/decline", "decline route");
            T.Eq(MiniJson.Str(BodyOf(tr.Sent.Last()), "reason"), "not_now", "decline reason");

            // upload
            tr.Sent.Clear();
            byte[] png = Util.FakePng(9);
            Util.Wait(api.UploadAsync("ab12cd34ef56", "low_bag-open.png", png, CancellationToken.None));
            var up = tr.Sent[0];
            T.Eq(up.Method + " " + up.Url.AbsolutePath, "PUT /death-muffin/api/team/jobs/ab12cd34ef56/files/low_bag-open.png", "upload route");
            T.Eq(up.ContentType, "image/png", "upload content type");
            T.Ok(up.Body.SequenceEqual(png), "upload sends the raw bytes");
            T.Eq(up.Token, "team-tok-1", "upload sends the team token");
            tr.Sent.Clear();
            foreach (string bad2 in new[] { "../x.png", "Low_A.png", "a b.png", "a.PNG", "x.png/../y.png", "", "a.jpg", new string('a', 61) + ".png", "a/b.png" })
                T.Ok(!Util.Wait(api.UploadAsync("ab12cd34ef56", bad2, png, CancellationToken.None)).Ok, "upload refuses the name '" + bad2 + "'");
            T.Ok(!Util.Wait(api.UploadAsync("../x", "a.png", png, CancellationToken.None)).Ok, "upload refuses a bad job id");
            T.Eq(tr.Sent.Count, 0, "refused uploads never reach the network");

            // done, fail
            tr.Respond = r => new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{}}" };
            Util.Wait(api.DoneAsync("ab12cd34ef56", new List<string> { "low_a.png", "ultra_a.png" }, new string('L', 100000) + "THE END", 12.34, 56.78, CancellationToken.None));
            var done = BodyOf(tr.Sent.Last());
            T.Eq(tr.Sent.Last().Url.AbsolutePath, "/death-muffin/api/team/jobs/ab12cd34ef56/done", "done route");
            T.Eq(string.Join(",", MiniJson.Arr(done, "files").Cast<string>()), "low_a.png,ultra_a.png", "done files");
            T.Ok(MiniJson.Str(done, "log").EndsWith("THE END") && Encoding.UTF8.GetByteCount(MiniJson.Str(done, "log")) <= 60000, "done log is the tail, within 64 KB");
            var tim = MiniJson.Obj(done, "timings");
            T.Ok(tim.ContainsKey("downloadS") && tim.ContainsKey("runS") && (double)tim["downloadS"] == 12.3 && (double)tim["runS"] == 56.8, "done timings");
            Util.Wait(api.FailAsync("ab12cd34ef56", new string('E', 1000), "log line", CancellationToken.None));
            var fail = BodyOf(tr.Sent.Last());
            T.Eq(tr.Sent.Last().Url.AbsolutePath, "/death-muffin/api/team/jobs/ab12cd34ef56/fail", "fail route");
            T.Eq(MiniJson.Str(fail, "error").Length, 400, "fail error is capped at 400");
            T.Eq(MiniJson.Str(fail, "log"), "log line", "fail log");
            T.Ok(!Util.Wait(api.FailAsync("bad id", "e", "l", CancellationToken.None)).Ok, "fail refuses a bad job id");
        }

        // ---- The real transport, against a local listener ----------------------------------------------------------------------------

        static void TransportTests()
        {
            int port;
            using (var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0)) { probe.Start(); port = ((System.Net.IPEndPoint)probe.LocalEndpoint).Port; probe.Stop(); }
            var listener = new System.Net.HttpListener();
            listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
            listener.Start();
            var seen = new List<string>();
            var loop = Task.Run(async () =>
            {
                while (listener.IsListening)
                {
                    System.Net.HttpListenerContext c;
                    try { c = await listener.GetContextAsync(); } catch (Exception) { return; }
                    var body = new MemoryStream();
                    c.Request.InputStream.CopyTo(body);
                    lock (seen) seen.Add(c.Request.HttpMethod + " " + c.Request.Url.AbsolutePath + "|" + (c.Request.Headers["Authorization"] ?? "none") + "|" + (c.Request.ContentType ?? "none") + "|" + body.Length + "|" + c.Request.UserAgent);
                    byte[] reply = Encoding.UTF8.GetBytes("{\"success\":true,\"data\":{\"x\":1}}");
                    c.Response.StatusCode = 200;
                    c.Response.ContentLength64 = reply.Length;
                    c.Response.OutputStream.Write(reply, 0, reply.Length);
                    c.Response.Close();
                }
            });
            try
            {
                using (var http = HttpClientTransport.CreateClient("9.8.7"))
                {
                    var tr = new HttpClientTransport(http);
                    Uri url = new Uri("http://127.0.0.1:" + port + "/death-muffin/api/team/x");
                    var r1 = Util.Wait(tr.SendAsync("POST", url, "tok123", Encoding.UTF8.GetBytes("{\"a\":1}"), "application/json", CancellationToken.None));
                    T.Ok(r1.NetworkError == null && r1.Status == 200 && r1.Body.Contains("\"x\":1"), "the transport returns the status and body");
                    Util.Wait(tr.SendAsync("PUT", url, "tok123", Util.FakePng(1), "image/png", CancellationToken.None));
                    Util.Wait(tr.SendAsync("POST", url, "", Encoding.UTF8.GetBytes("{}"), "application/json", CancellationToken.None));
                    Util.Wait(tr.SendAsync("GET", url, "tok123", null, null, CancellationToken.None));
                    lock (seen)
                    {
                        T.Eq(seen.Count, 4, "four requests arrived");
                        // each entry: method and path | Authorization | content type | body length | user agent
                        string[][] f = seen.Select(x => x.Split('|')).ToArray();
                        T.Eq(f[0][0], "POST /death-muffin/api/team/x", "the request goes where it was sent");
                        T.Eq(f[0][1], "Team tok123", "the token is sent as `Authorization: Team <token>`, not Bearer");
                        T.Ok(f[0][2].StartsWith("application/json") && f[0][3] == "7", "a JSON body keeps its content type and length");
                        T.Ok(f[1][0].StartsWith("PUT ") && f[1][1] == "Team tok123" && f[1][2] == "image/png" && f[1][3] == "200", "a picture goes as a PUT of image/png with the Team token");
                        T.Eq(f[2][1], "none", "no token, no Authorization header (the sign-in)");
                        T.Ok(f[3][0].StartsWith("GET ") && f[3][1] == "Team tok123", "a GET carries the token too");
                        T.Ok(f.All(x => x[4] == "DeathMuffinTeam/9.8.7"), "every request carries the app's user agent");
                    }
                    // a closed port is "no answer", not an exception
                    var dead = Util.Wait(tr.SendAsync("GET", new Uri("http://127.0.0.1:1/x"), "t", null, null, CancellationToken.None));
                    T.Ok(dead.NetworkError != null && dead.Status == 0, "a closed port is reported as no answer");
                    var cts = new CancellationTokenSource(); cts.Cancel();
                    T.Throws<OperationCanceledException>(() => Util.Wait(tr.SendAsync("GET", url, "t", null, null, cts.Token)), "a cancelled request throws");
                }
            }
            finally { try { listener.Stop(); listener.Close(); } catch (Exception) { } }
        }

        // ---- Folders --------------------------------------------------------------------------------------------------------------------

        static void FolderTests()
        {
            string root = Util.TempDir("folders");
            try
            {
                var f = new TeamFolders(root);
                T.Eq(f.JobDir("abc"), Path.Combine(root, "jobs", "abc"), "job folder");
                T.Eq(f.GameDir("abc"), Path.Combine(root, "jobs", "abc", "game"), "game folder");
                T.Eq(f.CacheDir("assets-1"), Path.Combine(root, "cache", "assets-1"), "cache folder");
                var t0 = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);   // in the past, so "now" is newer than all of it
                for (int i = 1; i <= 6; i++)
                {
                    Directory.CreateDirectory(f.JobDir("job" + i));
                    File.WriteAllText(Path.Combine(f.JobDir("job" + i), "x.txt"), "x");
                    Directory.SetLastWriteTimeUtc(f.JobDir("job" + i), t0.AddMinutes(i));
                }
                Directory.CreateDirectory(Path.Combine(f.JobsRoot, "not a job id!"));
                f.PruneJobs(3, "job7");   // a job whose folder does not exist yet changes nothing about who is protected
                T.Eq(string.Join(",", Directory.GetDirectories(f.JobsRoot).Select(Path.GetFileName).Where(n => n.StartsWith("job")).OrderBy(n => n)), "job4,job5,job6", "keeps the newest 3 job folders");
                T.Ok(Directory.Exists(Path.Combine(f.JobsRoot, "not a job id!")), "folders that are not job ids are left alone");
                Directory.CreateDirectory(f.JobDir("job9"));
                Directory.SetLastWriteTimeUtc(f.JobDir("job9"), t0.AddMinutes(100));
                f.PruneJobs(3, "job9");
                T.Eq(string.Join(",", Directory.GetDirectories(f.JobsRoot).Select(Path.GetFileName).Where(n => n.StartsWith("job")).OrderBy(n => n)), "job5,job6,job9", "keeps the current job and the newest others, 3 in all");
                Directory.SetLastWriteTimeUtc(f.JobDir("job5"), t0.AddMinutes(500));
                f.PruneJobs(3, "job1");   // protecting a missing folder
                T.Eq(Directory.GetDirectories(f.JobsRoot).Count(n => Path.GetFileName(n).StartsWith("job")), 3, "still 3");
                T.Eq(f.LatestLog(), null, "no log yet");
                File.WriteAllText(f.LogFile("job6"), "log");
                T.Eq(f.LatestLog(), f.LogFile("job6"), "latest log");

                for (int i = 1; i <= 6; i++)
                {
                    Directory.CreateDirectory(f.CacheDir("key" + i));
                    Directory.SetLastWriteTimeUtc(f.CacheDir("key" + i), t0.AddMinutes(i));
                }
                f.PruneCache(4, new List<string> { "key1" });
                T.Eq(string.Join(",", Directory.GetDirectories(f.CacheRoot).Select(Path.GetFileName).OrderBy(n => n)), "key1,key4,key5,key6", "cache keeps the protected key and the most recently used");
                f.TouchCache("key4");
                T.Ok(Directory.GetLastWriteTimeUtc(f.CacheDir("key4")) > t0.AddDays(30), "touching a cache key marks it used");
                f.PruneCache(4, null);
                T.Eq(Directory.GetDirectories(f.CacheRoot).Length, 4, "cache pruning is repeatable");
            }
            finally { Util.Rm(root); }
        }

        // ---- Downloads ------------------------------------------------------------------------------------------------------------------

        static PlanFile PF(TestServer srv, string name, byte[] data, string folder = "f1")
        {
            var d = srv.Publish(folder, name, data);
            return new PlanFile { Name = name, Url = new Uri((string)d["url"]), Sha256 = (string)d["sha256"], Bytes = data.Length };
        }

        static FileFetcher Fast(HttpClient http) { return new FileFetcher(http) { RetryDelay = TimeSpan.FromMilliseconds(5), StallTimeout = TimeSpan.FromSeconds(10) }; }

        static void FetcherTests()
        {
            string dir = Util.TempDir("fetch");
            using (var srv = new TestServer())
            using (var http = new HttpClient())
            {
                try
                {
                    byte[] data = Util.Blob(300000, 1);
                    var f = PF(srv, "a.pck", data);
                    string dest = Path.Combine(dir, "g", "a.pck");
                    var seen = new List<long>();
                    T.Ok(Util.Wait(Fast(http).EnsureAsync(f, dest, seen.Add, CancellationToken.None)), "a missing file is downloaded");
                    T.Ok(File.ReadAllBytes(dest).SequenceEqual(data) && !File.Exists(dest + ".part"), "the file is in place and the part file is gone");
                    T.Eq(seen.Last(), (long)data.Length, "progress reaches the full size");
                    int hits = srv.HitsFor("a.pck");
                    T.Ok(!Util.Wait(Fast(http).EnsureAsync(f, dest, x => { }, CancellationToken.None)) && srv.HitsFor("a.pck") == hits, "a file that is there and correct is not downloaded again");

                    // a damaged file in place is downloaded again
                    File.WriteAllBytes(dest, Util.Blob(300000, 99));
                    T.Ok(Util.Wait(Fast(http).EnsureAsync(f, dest, x => { }, CancellationToken.None)) && File.ReadAllBytes(dest).SequenceEqual(data), "a wrong file in place is replaced");

                    // resume after a dropped connection
                    byte[] big = Util.Blob(400000, 2);
                    var g = PF(srv, "big.pck", big);
                    srv.DropFirstAfter["death-muffin/team-files/f1/big.pck"] = 150000;
                    string dest2 = Path.Combine(dir, "g", "big.pck");
                    Util.Wait(Fast(http).EnsureAsync(g, dest2, x => { }, CancellationToken.None));
                    T.Ok(File.ReadAllBytes(dest2).SequenceEqual(big), "a dropped download is completed");
                    T.Ok(srv.RangeHeaders.Any(h => h.StartsWith("death-muffin/team-files/f1/big.pck bytes=") && h.EndsWith("-")), "and it resumed with a Range request");

                    // resume from a part file left by an earlier run
                    byte[] third = Util.Blob(200000, 3);
                    var h3 = PF(srv, "third.pck", third);
                    string dest3 = Path.Combine(dir, "g", "third.pck");
                    File.WriteAllBytes(dest3 + ".part", third.Take(80000).ToArray());
                    Util.Wait(Fast(http).EnsureAsync(h3, dest3, x => { }, CancellationToken.None));
                    T.Ok(File.ReadAllBytes(dest3).SequenceEqual(third) && srv.RangeHeaders.Any(h => h.Contains("third.pck bytes=80000-")), "a part file from an earlier run is resumed");

                    // a part file that is longer than the file is dropped
                    byte[] fourth = Util.Blob(50000, 4);
                    var h4 = PF(srv, "fourth.pck", fourth);
                    string dest4 = Path.Combine(dir, "g", "fourth.pck");
                    File.WriteAllBytes(dest4 + ".part", Util.Blob(90000, 5));
                    Util.Wait(Fast(http).EnsureAsync(h4, dest4, x => { }, CancellationToken.None));
                    T.Ok(File.ReadAllBytes(dest4).SequenceEqual(fourth), "an oversized part file is started over");

                    // the server ignores Range: start over
                    srv.IgnoreRange = true;
                    byte[] fifth = Util.Blob(120000, 6);
                    var h5 = PF(srv, "fifth.pck", fifth);
                    string dest5 = Path.Combine(dir, "g", "fifth.pck");
                    File.WriteAllBytes(dest5 + ".part", fifth.Take(30000).ToArray());
                    Util.Wait(Fast(http).EnsureAsync(h5, dest5, x => { }, CancellationToken.None));
                    T.Ok(File.ReadAllBytes(dest5).SequenceEqual(fifth), "a server that ignores Range gives the whole file");
                    srv.IgnoreRange = false;

                    // corrupt once, then fine: retried
                    byte[] sixth = Util.Blob(100000, 7);
                    var h6 = PF(srv, "sixth.pck", sixth);
                    srv.CorruptFirst["death-muffin/team-files/f1/sixth.pck"] = 1;
                    string dest6 = Path.Combine(dir, "g", "sixth.pck");
                    Util.Wait(Fast(http).EnsureAsync(h6, dest6, x => { }, CancellationToken.None));
                    T.Ok(File.ReadAllBytes(dest6).SequenceEqual(sixth), "a corrupt download is thrown away and fetched again");

                    // always corrupt: fails with a readable message, nothing is left in place
                    srv.AlwaysCorrupt = true;
                    byte[] seventh = Util.Blob(60000, 8);
                    var h7 = PF(srv, "seventh.pck", seventh);
                    string dest7 = Path.Combine(dir, "g", "seventh.pck");
                    var ex = Assert<IOException>(() => Util.Wait(Fast(http).EnsureAsync(h7, dest7, x => { }, CancellationToken.None)));
                    T.Ok(ex != null && ex.Message.Contains("Could not download seventh.pck") && ex.Message.Contains("checksum"), "a file that never matches fails with a readable message");
                    T.Ok(!File.Exists(dest7) && !File.Exists(dest7 + ".part"), "a failed file leaves nothing behind");
                    srv.AlwaysCorrupt = false;

                    // 404
                    var gone = new PlanFile { Name = "gone.pck", Url = new Uri(srv.FilesBase + "f1/gone.pck"), Sha256 = new string('a', 64), Bytes = 10 };
                    ex = Assert<IOException>(() => Util.Wait(Fast(http).EnsureAsync(gone, Path.Combine(dir, "g", "gone.pck"), x => { }, CancellationToken.None)));
                    T.Ok(ex != null && ex.Message.Contains("HTTP 404"), "a missing file says HTTP 404");

                    // a server that sends more than the job says
                    var liar = new PlanFile { Name = "liar.pck", Url = f.Url, Sha256 = f.Sha256, Bytes = 1000 };
                    ex = Assert<IOException>(() => Util.Wait(Fast(http).EnsureAsync(liar, Path.Combine(dir, "g", "liar.pck"), x => { }, CancellationToken.None)));
                    T.Ok(ex != null && ex.Message.Contains("larger than the job says"), "a file larger than the job says is refused");

                    // cancel
                    var cts = new CancellationTokenSource(); cts.Cancel();
                    T.Throws<OperationCanceledException>(() => Util.Wait(Fast(http).EnsureAsync(PF(srv, "c.pck", Util.Blob(1000, 1)), Path.Combine(dir, "g", "c.pck"), x => { }, cts.Token)), "a cancelled download stops");
                }
                finally { Util.Rm(dir); }
            }
        }

        public static E Assert<E>(Action a) where E : Exception
        {
            try { a(); return null; }
            catch (E e) { return e; }
            catch (AggregateException ae) { return ae.Flatten().InnerExceptions.OfType<E>().FirstOrDefault(); }
        }

        // ---- The real game process (a tiny script stands in for the game; Linux only) ------------------------------------------------------

        static void ProcessHostTests()
        {
            if (!OperatingSystem.IsLinux()) { Console.WriteLine("(skipped the process test: it needs a shell script as the game)"); return; }
            string dir = Util.TempDir("proc");
            try
            {
                string game = Path.Combine(dir, "game");
                Directory.CreateDirectory(game);
                string exe = Path.Combine(game, "DeathMuffinDebug.exe");
                File.WriteAllText(exe, "#!/bin/bash\necho \"APPDATA=$APPDATA\"\necho \"LOCALAPPDATA=$LOCALAPPDATA\"\necho \"PWD=$PWD\"\nfor a in \"$@\"; do echo \"ARG[$a]\"; done\necho oops >&2\nexit ${EXIT_CODE:-3}\n");
                File.SetUnixFileMode(exe, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                var host = new ProcessGameHost(pid => { });
                var launch = new GameLaunch { ExePath = exe, WorkingDir = game, AppData = Path.Combine(dir, "appdata"), LocalAppData = Path.Combine(dir, "local appdata"), Args = new List<string> { "--windowed", "--", "--shot-plan=/tmp/a b/plan.json", "--preset=low" } };
                IGameProcess p;
                using (p = host.Start(launch))
                {
                    var sw = Stopwatch.StartNew();
                    while (!p.HasExited && sw.Elapsed < TimeSpan.FromSeconds(20)) Thread.Sleep(20);
                    T.Ok(p.HasExited, "the process ends");
                    T.Eq(p.ExitCode, 3, "exit code is read");
                    p.Tend();
                    string o = p.Output();
                    T.Has(o, "APPDATA=" + Path.Combine(dir, "appdata"), "APPDATA points into the job folder");
                    T.Has(o, "LOCALAPPDATA=" + Path.Combine(dir, "local appdata"), "LOCALAPPDATA points into the job folder (a path with a space)");
                    T.Has(o, "PWD=" + game, "the game starts in its own folder");
                    T.Has(o, "ARG[--shot-plan=/tmp/a b/plan.json]", "an argument with a space stays one argument");
                    T.Has(o, "ARG[--windowed]", "arguments are passed");
                    T.Has(o, "oops", "standard error is captured too");
                }
                // a game that does not stop: Kill ends it
                File.WriteAllText(exe, "#!/bin/bash\nsleep 60\n");
                using (p = host.Start(launch))
                {
                    T.Ok(!p.HasExited, "a running game has not exited");
                    p.Kill();
                    T.Ok(p.HasExited, "Kill ends the game");
                    p.Kill();
                    T.Ok(true, "killing twice is harmless");
                }
                T.Throws<System.ComponentModel.Win32Exception>(() => host.Start(new GameLaunch { ExePath = Path.Combine(dir, "missing.exe"), WorkingDir = dir, AppData = dir, LocalAppData = dir }), "a game that is not there fails to start");
                var buf = new OutputBuffer(100);
                for (int i = 0; i < 50; i++) buf.Add("line " + i);
                T.Ok(buf.Text().EndsWith("line 49") && buf.Text().Length <= 120 && !buf.Text().Contains("line 0\n"), "the output buffer keeps the end");
            }
            finally { Util.Rm(dir); }
        }

        // ---- Self-update ----------------------------------------------------------------------------------------------------------------

        static TeamManifest Manifest(string version, string sha = null, long size = 0, string url = "https://muffindevelopment.com/death-muffin/teamapp/0.2.0/DeathMuffinTeam.exe")
        {
            string json = "{\"version\":\"" + version + "\",\"url\":\"" + url + "\",\"sha256\":\"" + (sha ?? new string('b', 64)) + "\"" + (size > 0 ? ",\"size\":" + size : "") + "}";
            TeamManifest m; string err;
            return TeamManifest.TryParse(json, new Uri(TeamUrls.VersionUrl), out m, out err) ? m : null;
        }

        static void SelfUpdateTests()
        {
            T.Eq(TeamUrls.VersionUrl, "https://muffindevelopment.com/death-muffin/teamapp/version.json", "the version manifest's address");
            var m = Manifest("0.2.0");
            T.Ok(m != null && m.Version == "0.2.0" && m.Sha256 == new string('b', 64) && m.Size == 0, "a valid manifest parses");
            T.Ok(Manifest("0.2.0", size: 1234).Size == 1234, "an optional size is read");
            T.Ok(Manifest("0.2.0", url: "0.2.0/DeathMuffinTeam.exe").Url.ToString() == "https://muffindevelopment.com/death-muffin/teamapp/0.2.0/DeathMuffinTeam.exe", "a relative url resolves against the manifest");
            T.Ok(Manifest("0.2") == null && Manifest("v0.2.0") == null && Manifest("0.2.0.1") == null && Manifest("") == null, "versions must be three numbers");
            T.Ok(Manifest("0.2.0", sha: "zz") == null, "a bad sha256 is refused");
            T.Ok(Manifest("0.2.0", url: "https://evil.example/x.exe") == null, "an exe on another host is refused");
            T.Ok(Manifest("0.2.0", url: "http://muffindevelopment.com/x.exe") == null, "an exe on another scheme is refused");
            T.Ok(Manifest("0.2.0", url: "") == null, "no url is refused");
            TeamManifest mm; string err;
            T.Ok(!TeamManifest.TryParse("{\"version\":\"0.2.0\",\"url\":\"x.exe\",\"sha256\":\"" + new string('b', 64) + "\",\"size\":-5}", new Uri(TeamUrls.VersionUrl), out mm, out err), "a bad size is refused");
            T.Ok(!TeamManifest.TryParse("[1]", new Uri(TeamUrls.VersionUrl), out mm, out err) && !TeamManifest.TryParse("nope", new Uri(TeamUrls.VersionUrl), out mm, out err), "a manifest that is not an object is refused");

            T.Eq(SelfUpdate.Decide(null, "0.1.0", false, true, 0), SelfUpdateAction.None, "no manifest: nothing to do");
            T.Eq(SelfUpdate.Decide(Manifest("0.1.0"), "0.1.0", false, true, 0), SelfUpdateAction.None, "same version: nothing to do");
            T.Eq(SelfUpdate.Decide(Manifest("0.0.9"), "0.1.0", false, true, 0), SelfUpdateAction.None, "older version: never downgrade");
            T.Eq(SelfUpdate.Decide(Manifest("0.2.0"), "0.1.0", false, true, 0), SelfUpdateAction.Apply, "newer version: apply");
            T.Eq(SelfUpdate.Decide(Manifest("0.2.0"), "0.1.0", true, true, 0), SelfUpdateAction.Wait, "newer version while a job runs: wait");
            T.Eq(SelfUpdate.Decide(Manifest("0.2.0"), "0.1.0", false, false, 0), SelfUpdateAction.GiveUp, "folder not writable: give up");
            T.Eq(SelfUpdate.Decide(Manifest("0.2.0"), "0.1.0", false, true, SelfUpdate.MaxFailures), SelfUpdateAction.GiveUp, "failed too often: give up");
            T.Eq(SelfUpdate.Decide(Manifest("0.2.0"), "0.1.0", true, true, SelfUpdate.MaxFailures - 1), SelfUpdateAction.Wait, "one failure left, job running: wait");
            T.Eq(SelfUpdate.Decide(Manifest("0.10.0"), "0.9.0", false, true, 0), SelfUpdateAction.Apply, "0.10.0 is newer than 0.9.0");

            string dir = Util.TempDir("update");
            using (var srv = new TestServer())
            using (var http = new HttpClient())
            {
                try
                {
                    string exe = Path.Combine(dir, "DeathMuffinTeam.exe");
                    byte[] oldExe = Util.Blob(5000, 11), newExe = Util.Blob(7000, 12);
                    File.WriteAllBytes(exe, oldExe);
                    srv.Files["death-muffin/teamapp/0.2.0/DeathMuffinTeam.exe"] = newExe;
                    var url = new Uri(srv.SiteBase + "teamapp/0.2.0/DeathMuffinTeam.exe");
                    var good = new TeamManifest { Version = "0.2.0", Url = url, Sha256 = Util.Sha(newExe), Size = newExe.Length };
                    Util.Wait(SelfUpdate.DownloadAsync(http, good, exe, CancellationToken.None));
                    T.Ok(File.Exists(SelfUpdate.NewPath(exe)) && !File.Exists(exe + ".new.part") && File.ReadAllBytes(SelfUpdate.NewPath(exe)).SequenceEqual(newExe), "the update is downloaded next to the exe as .new");
                    T.Ok(File.ReadAllBytes(exe).SequenceEqual(oldExe), "the running exe is untouched until the swap");
                    SelfUpdate.Swap(exe);
                    T.Ok(File.ReadAllBytes(exe).SequenceEqual(newExe) && File.ReadAllBytes(SelfUpdate.OldPath(exe)).SequenceEqual(oldExe) && !File.Exists(SelfUpdate.NewPath(exe)), "swap: new in place, old kept as .old");
                    SelfUpdate.CleanUp(exe);
                    T.Ok(!File.Exists(SelfUpdate.OldPath(exe)) && File.Exists(exe), "the new copy removes .old at start");

                    // wrong checksum: nothing is swapped
                    var bad = new TeamManifest { Version = "0.3.0", Url = url, Sha256 = new string('c', 64), Size = newExe.Length };
                    T.Throws<InvalidDataException>(() => Util.Wait(SelfUpdate.DownloadAsync(http, bad, exe, CancellationToken.None)), "a download that fails its SHA-256 is refused");
                    T.Ok(!File.Exists(SelfUpdate.NewPath(exe)) && !File.Exists(exe + ".new.part"), "a refused update leaves no files");
                    // a download larger than the manifest says
                    var small = new TeamManifest { Version = "0.3.0", Url = url, Sha256 = Util.Sha(newExe), Size = 100 };
                    T.Throws<InvalidDataException>(() => Util.Wait(SelfUpdate.DownloadAsync(http, small, exe, CancellationToken.None)), "a download larger than the manifest says is refused");
                    // 404
                    var missing = new TeamManifest { Version = "0.3.0", Url = new Uri(srv.SiteBase + "teamapp/none.exe"), Sha256 = new string('d', 64) };
                    T.Throws<HttpRequestException>(() => Util.Wait(SelfUpdate.DownloadAsync(http, missing, exe, CancellationToken.None)), "a missing update download fails");
                    T.Throws<FileNotFoundException>(() => SelfUpdate.Swap(exe), "swap without a download fails");
                    T.Ok(File.ReadAllBytes(exe).SequenceEqual(newExe), "a failed swap leaves the exe in place");
                    T.Ok(SelfUpdate.FolderWritable(exe) && !SelfUpdate.FolderWritable(Path.Combine(dir, "no", "such", "folder", "x.exe")), "folder writable check");

                    // the manifest over HTTP
                    srv.Files["death-muffin/teamapp/version.json"] = Encoding.UTF8.GetBytes("{\"version\":\"0.2.0\",\"url\":\"0.2.0/DeathMuffinTeam.exe\",\"sha256\":\"" + new string('e', 64) + "\"}");
                    var fetched = Util.Wait(SelfUpdate.FetchAsync(http, srv.SiteBase + "teamapp/version.json"));
                    T.Ok(fetched != null && fetched.Version == "0.2.0", "the manifest is fetched");
                    T.Ok(Util.Wait(SelfUpdate.FetchAsync(http, srv.SiteBase + "teamapp/none.json")) == null, "no manifest published yet: null");
                }
                finally { Util.Rm(dir); }
            }
        }
    }
}
