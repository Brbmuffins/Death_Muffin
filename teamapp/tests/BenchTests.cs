using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

namespace DeathMuffinTeam.Tests
{
    /// <summary>The `bench` job's logic: its payload, its command lines, the rules for a quiet PC and a disturbed run, the result file and the done body. The runner and the controller side are in RunnerTests and ControllerTests.</summary>
    static class BenchTests
    {
        static readonly Uri Site = new Uri("https://muffindevelopment.com/death-muffin/");

        public static void Run()
        {
            PlanTests();
            RefusalTests();
            CommandTests();
            QuietTests();
            DisturbedTests();
            ResultFileTests();
            ApiBodyTests();
        }

        // ---- The payload ------------------------------------------------------------------------------------------------------------

        public static Dictionary<string, object> Setup(string preset = "low", string room = "graves", object cls = null, string size = "full_party", string length = "full")
        {
            return new Dictionary<string, object> { { "preset", preset }, { "room", room }, { "class", cls ?? 2.0 }, { "size", size }, { "length", length } };
        }

        /// <summary>The publish hook's payload (server/death-muffin/team-bench.sh): the release build, its pack, the core and the art pack, and a Low and a Medium setup.</summary>
        public static Dictionary<string, object> ValidPayload()
        {
            return new Dictionary<string, object>
            {
                { "version", "0.9.1" }, { "rev", "0123456789ab" }, { "godotVersion", "4.7.2.stable" },
                { "files", new List<object> { Program.File_("DeathMuffin.exe", "godot-release-4.7.2"), Program.File_("DeathMuffin.pck"), Program.File_("DeathMuffin.assets.pck", "assets-0f3a9c"), Program.File_("libdmcore.windows.template_release.x86_64.dll") } },
                { "setups", new List<object> { Setup("low"), Setup("medium") } },
                { "args", new List<object>() },
            };
        }

        static List<object> Files(Dictionary<string, object> p) { return (List<object>)p["files"]; }
        static List<object> Setups(Dictionary<string, object> p) { return (List<object>)p["setups"]; }

        static void PlanTests()
        {
            JobPlan plan; string error;
            T.Ok(JobPlan.TryParse(JobPlan.BenchKind, ValidPayload(), Site, out plan, out error), "the hook's bench payload is accepted: " + error);
            T.Eq(plan.Kind, "bench", "the plan knows its kind");
            T.Eq(plan.Files.Count, 4, "bench files");
            T.Eq(plan.Setups.Count, 2, "two setups");
            T.Eq(plan.Setups[0].Preset + "|" + plan.Setups[0].Room + "|" + plan.Setups[0].Class + "|" + plan.Setups[0].Size + "|" + plan.Setups[0].Length, "low|graves|2|full_party|full", "a setup as sent");
            T.Eq(plan.Setups[1].Preset, "medium", "setups keep their order");
            T.Eq(plan.Args.Count, 0, "a bench job adds no options (not even --dev-offline: --bench-dir keeps the run a trial)");
            T.Eq(plan.FileNamed("DeathMuffin.exe").CacheKey, "godot-release-4.7.2", "the release exe is cached under its key");
            T.Eq(plan.Setups[0].Describe(), "graves, full_party, full, class 2", "the log's words for a setup");
            T.Ok(JobPlan.TryParse(JobPlan.BenchKind, MiniJson.Write(ValidPayload()), Site, out plan, out error) && plan.Setups.Count == 2, "a bench payload given as JSON text is accepted");
            T.Ok(JobPlan.RunsKind("shots") && JobPlan.RunsKind("bench") && !JobPlan.RunsKind("benchmark") && !JobPlan.RunsKind("") && !JobPlan.RunsKind(null), "this version runs shots and bench jobs");

            // every preset, size and length the game knows; one to six setups; classes 1..20
            var p = ValidPayload();
            p["setups"] = new List<object>
            {
                Setup("low", "graves", 1.0, "light", "quick"), Setup("medium", "sanctum", 4.0, "standard", "full"), Setup("high", "pyre", 11.0, "heavy", "quick"),
                Setup("ultra", "fen", 20.0, "full_party", "full"), Setup("low", "nave", 2.0), Setup("low", "cloister", 2.0),
            };
            T.Ok(JobPlan.TryParse(JobPlan.BenchKind, p, Site, out plan, out error) && plan.Setups.Count == 6, "six setups with every preset, size and length are accepted: " + error);
            p["setups"] = new List<object> { Setup("low", "graves-2_b") };
            T.Ok(JobPlan.TryParse(JobPlan.BenchKind, p, Site, out plan, out error), "a room with a dash, a digit and an underscore is a safe token: " + error);
            var p2 = ValidPayload(); p2["args"] = new List<object> { "--bench-warm=5", "--bench-measure=10" };
            T.Ok(JobPlan.TryParse(JobPlan.BenchKind, p2, Site, out plan, out error) && string.Join(" ", plan.Args) == "--bench-warm=5 --bench-measure=10", "other game options pass the usual checks: " + error);

            // a shots payload is not a bench payload, and the other way round
            JobPlan other;
            T.Ok(!JobPlan.TryParse(JobPlan.ShotsKind, ValidPayload(), Site, out other, out error) && other == null, "a bench payload is no shots payload");
            T.Ok(!JobPlan.TryParse(JobPlan.BenchKind, Program.ValidPayload(), Site, out other, out error) && error.Contains("DeathMuffin.exe"), "a shots payload is no bench payload (it has no release exe)");
            T.Ok(!JobPlan.TryParse("benchmark", ValidPayload(), Site, out other, out error) && error == "This version of the team app cannot run benchmark jobs.", "a kind this version does not know is refused in plain words");
            T.Ok(!JobPlan.TryParse(null, ValidPayload(), Site, out other, out error) && error.Length > 0, "no kind is refused");
            T.Ok(JobPlan.TryParse(Program.ValidPayload(), Site, out plan, out error) && plan.Kind == "shots", "the payload without a kind is a shots one");
            T.Eq(plan.Setups.Count, 0, "and has no setups");

            // when a job's life ends
            T.Eq(JobPlan.ParseExpiry("2026-10-19T13:00:00Z"), (DateTime?)new DateTime(2026, 10, 19, 13, 0, 0, DateTimeKind.Utc), "the offer's expiry is read as UTC");
            T.Eq(JobPlan.ParseExpiry("2026-10-19T15:00:00+02:00"), (DateTime?)new DateTime(2026, 10, 19, 13, 0, 0, DateTimeKind.Utc), "with an offset it is converted");
            T.Eq(JobPlan.ParseExpiry(""), (DateTime?)null, "no expiry");
            T.Eq(JobPlan.ParseExpiry("tomorrow-ish"), (DateTime?)null, "an expiry that is not a time");
        }

        static string Reject(Action<Dictionary<string, object>> mutate, string name, string wantInError = null)
        {
            var p = ValidPayload();
            mutate(p);
            JobPlan plan; string err;
            bool ok = JobPlan.TryParse(JobPlan.BenchKind, p, Site, out plan, out err);
            T.Ok(!ok && plan == null && !string.IsNullOrEmpty(err), "bench payload refused: " + name + (ok ? " (it was accepted)" : ""));
            if (wantInError != null) T.Has(err, wantInError, "bench refusal says why: " + name);
            if (err != null) T.Ok(!err.Contains("Exception") && !err.Contains(" at "), "bench refusal is plain English: " + name);
            return err;
        }

        static void RefusalTests()
        {
            // the four files a bench job needs
            foreach (string need in JobPlan.BenchFiles)
                Reject(p => Files(p).RemoveAll(f => (string)((Dictionary<string, object>)f)["name"] == need), "no " + need, need);
            Reject(p => { Files(p).RemoveAll(f => (string)((Dictionary<string, object>)f)["name"] == "DeathMuffin.exe"); Files(p).Add(Program.File_("DeathMuffinDebug.exe")); }, "the debug exe instead of the release exe", "DeathMuffin.exe");
            Reject(p => Files(p).Add(Program.File_("../evil.dll", url: "https://muffindevelopment.com/death-muffin/team-files/q7x2k9/ok.bin")), "a file name with ..", "not allowed");
            Reject(p => Files(p).Add(Program.File_("a.dll", url: "https://evil.example/death-muffin/team-files/x/a.dll")), "a file from another host", "not on the game's server");
            Reject(p => Files(p).Add(Program.File_("a.dll", sha: "xyz")), "a bad checksum", "checksum");
            Reject(p => Files(p).Add(Program.File_("DeathMuffin.exe")), "a file listed twice", "twice");
            Reject(p => p["rev"] = "not-a-rev", "a bad rev");
            // setups: how many
            Reject(p => p.Remove("setups"), "no setups", "setups");
            Reject(p => p["setups"] = new List<object>(), "empty setups");
            Reject(p => p["setups"] = "low", "setups as text");
            Reject(p => p["setups"] = Enumerable.Range(0, 7).Select(i => (object)Setup()).ToList(), "seven setups", "1 to 6");
            Reject(p => Setups(p).Add("graves"), "a setup that is text", "not valid");
            // setups: preset, size, length
            Reject(p => Setups(p).Add(Setup("potato")), "unknown preset", "preset that does not exist");
            Reject(p => Setups(p).Add(Setup("")), "empty preset");
            Reject(p => Setups(p).Add(Setup("Low")), "preset in capitals");
            Reject(p => Setups(p).Add(Setup("../low")), "preset with a path");
            Reject(p => Setups(p).Add(Setup(size: "huge")), "unknown size", "fight size");
            Reject(p => Setups(p).Add(Setup(size: "Full_Party")), "size in capitals");
            Reject(p => Setups(p).Add(Setup(size: "")), "empty size");
            Reject(p => Setups(p).Add(Setup(length: "forever")), "unknown length", "length");
            Reject(p => Setups(p).Add(Setup(length: "standard")), "a length the game does not know (it would run its full length without saying so)", "length");
            Reject(p => Setups(p).Add(Setup(length: "long")), "another length the game does not know", "length");
            Reject(p => Setups(p).Add(Setup(length: "Quick")), "length in capitals");
            Reject(p => Setups(p).Add(Setup(length: "quick --online")), "a length with an option in it");
            // setups: room
            Reject(p => Setups(p).Add(Setup(room: "")), "empty room", "room");
            Reject(p => Setups(p).Add(Setup(room: "Graves")), "room in capitals");
            Reject(p => Setups(p).Add(Setup(room: "../graves")), "room with ..");
            Reject(p => Setups(p).Add(Setup(room: "C:\\x")), "room that is a path");
            Reject(p => Setups(p).Add(Setup(room: "graves --online")), "room with an option in it");
            Reject(p => Setups(p).Add(Setup(room: "graves\"")), "room with a quote");
            Reject(p => Setups(p).Add(Setup(room: "1graves")), "room starting with a digit");
            Reject(p => Setups(p).Add(Setup(room: new string('a', 33))), "room too long");
            // setups: class
            Reject(p => Setups(p).Add(Setup(cls: 0.0)), "class 0", "class");
            Reject(p => Setups(p).Add(Setup(cls: 21.0)), "class 21");
            Reject(p => Setups(p).Add(Setup(cls: -1.0)), "negative class");
            Reject(p => Setups(p).Add(Setup(cls: 2.5)), "fractional class");
            Reject(p => Setups(p).Add(Setup(cls: "2")), "class as text");
            Reject(p => { var s = Setup(); s.Remove("class"); Setups(p).Add(s); }, "no class");
            Reject(p => { var s = Setup(); s.Remove("room"); Setups(p).Add(s); }, "no room");
            // options the app sets itself
            foreach (string reserved in new[] { "--benchmark", "--bench-quit", "--bench-dir=x", "--bench-room=x", "--bench-class=2", "--bench-size=light", "--bench-length=quick", "--bench-preset=low", "--main-pack=x", "--audio-driver=Dummy", "--audio-driver", "--position=0,0", "--rendering-driver=opengl3", "--headless", "--fullscreen", "--online" })
                Reject(p => p["args"] = new List<object> { reserved }, "option " + reserved, "sets itself");
            Reject(p => p["args"] = new List<object> { "--bench-dir=C:/x" }, "option --bench-dir", "--bench-dir");
            Reject(p => p["args"] = new List<object> { "--class=../x" }, "an option with a path in it");
            Reject(p => p["args"] = Enumerable.Range(0, 17).Select(i => (object)("--a" + i)).ToList(), "too many options");
            // the shots reserved list now holds the bench options too
            var shots = Program.ValidPayload();
            shots["args"] = new List<object> { "--benchmark" };
            JobPlan plan; string err;
            T.Ok(!JobPlan.TryParse(shots, Site, out plan, out err) && err.Contains("--benchmark"), "a shots job cannot turn the game into the benchmark");
        }

        // ---- The command line -----------------------------------------------------------------------------------------------------------

        static void CommandTests()
        {
            JobPlan plan; string error;
            JobPlan.TryParse(JobPlan.BenchKind, ValidPayload(), Site, out plan, out error);
            string dir = "C:\\Users\\Test User\\AppData\\Local\\DeathMuffinTeam\\jobs\\q7x2k9ab\\bench-1";
            var a = plan.BenchCommandArgs(plan.Setups[0], dir);
            T.Eq(string.Join("|", a),
                "--windowed|--resolution|1600x900|--audio-driver|Dummy|--|--benchmark|--bench-room=graves|--bench-class=2|--bench-size=full_party|--bench-length=full|--bench-preset=low|--bench-dir=C:/Users/Test User/AppData/Local/DeathMuffinTeam/jobs/q7x2k9ab/bench-1|--bench-quit",
                "the benchmark's arguments for the first setup (the contract's line, no --main-pack)");
            T.Ok(!a.Contains("--main-pack") && !a.Contains("--dev-offline"), "no --main-pack (the release template refuses it) and no --dev-offline");
            T.Eq(plan.BenchCommandArgs(plan.Setups[1], "C:\\j\\bench-2").Last(), "--bench-quit", "--bench-quit ends it");
            T.Has(string.Join(" ", plan.BenchCommandArgs(plan.Setups[1], "C:\\j\\bench-2")), "--bench-preset=medium --bench-dir=C:/j/bench-2", "the second setup's preset and folder");
            T.Eq(plan.BenchCommandLine(plan.Setups[1], "C:\\j\\bench-2"),
                "--windowed --resolution 1600x900 --audio-driver Dummy -- --benchmark --bench-room=graves --bench-class=2 --bench-size=full_party --bench-length=full --bench-preset=medium --bench-dir=C:/j/bench-2 --bench-quit",
                "the command line without spaces needs no quotes");
            T.Has(plan.BenchCommandLine(plan.Setups[0], dir), "\"--bench-dir=C:/Users/Test User/AppData/Local/DeathMuffinTeam/jobs/q7x2k9ab/bench-1\"", "a folder with a space is quoted");
            T.Eq(plan.BenchCommandArgs(plan.Setups[0], "x").IndexOf("--"), 5, "everything for the game comes after --");
            T.Ok(!a.Contains("--position"), "a benchmark's window stays on screen: no --position");
            T.Eq(string.Join(" ", a.Take(5)), "--windowed --resolution 1600x900 --audio-driver Dummy", "a benchmark is silent too: the Dummy audio driver still mixes, so the CPU cost is real");

            var p = ValidPayload(); p["args"] = new List<object> { "--bench-warm=5" };
            JobPlan.TryParse(JobPlan.BenchKind, p, Site, out plan, out error);
            T.Eq(plan.BenchCommandArgs(plan.Setups[0], "d").Last(), "--bench-warm=5", "the job's own options come last");
            T.Eq(TeamLogic.BenchRunLimit, TimeSpan.FromMinutes(15), "a benchmark setup gets 15 minutes");
            T.Eq(new TeamFolders("C:\\r").BenchDir("job1", 2), Path.Combine("C:\\r", "jobs", "job1", "bench-2"), "a setup's folder is bench-<n> in the job's folder");
            var folders = new TeamFolders("C:\\r");
            T.Ok(folders.AppDataDir("job1", 1) != folders.AppDataDir("job1", 2) && folders.LocalAppDataDir("job1", 1) != folders.LocalAppDataDir("job1", 2), "every run has its own APPDATA and LOCALAPPDATA");
            T.Eq(folders.AppDataDir("job1", 3), Path.Combine("C:\\r", "jobs", "job1", "run-3", "appdata"), "run-<n>\\appdata in the job's folder");
            T.Eq(folders.LocalAppDataDir("job1", 3), Path.Combine("C:\\r", "jobs", "job1", "run-3", "localappdata"), "and run-<n>\\localappdata");
        }

        // ---- A quiet PC ---------------------------------------------------------------------------------------------------------------------

        static readonly QuietRules Rules = new QuietRules();

        static PcSample S(double at, double cpu = 3, double idle = 500, double game = 0, bool battery = false, bool full = false, bool player = false)
        {
            return new PcSample { At = TimeSpan.FromSeconds(at), CpuTotal = cpu, CpuGame = game, IdleS = idle, OnBattery = battery, Fullscreen = full, PlayerGame = player };
        }

        /// <summary>Readings once a second from <paramref name="from"/> to <paramref name="to"/>.</summary>
        static List<PcSample> Run(double from, double to, Func<double, PcSample> make)
        {
            var l = new List<PcSample>();
            for (double t = from; t <= to; t++) l.Add(make(t));
            return l;
        }

        static string Why(List<PcSample> l) { return Quiet.WhyNotQuiet(l, Rules); }

        static void QuietTests()
        {
            T.Eq(Why(new List<PcSample>()), "checking the PC", "no readings yet");
            T.Eq(Quiet.WhyNotQuiet(null, Rules), "checking the PC", "no list of readings");
            T.Eq(Why(Run(0, 60, t => S(t))), "", "a minute of readings with nothing going on is quiet");
            T.Eq(Why(Run(0, 58, t => S(t))), "", "59 readings a second apart are a minute (the first one may start the window up to 2 s late)");
            T.Eq(Why(Run(0, 57, t => S(t))), "watching the PC for a quiet minute (57 s so far)", "57 s are not");
            T.Eq(Why(Run(0, 5, t => S(t))), "watching the PC for a quiet minute (5 s so far)", "the first seconds say how long it has been watched");
            T.Eq(Why(Run(0, 300, t => S(t))), "", "a longer stretch is quiet too");
            T.Eq(Quiet.WhyNotQuiet(Run(0, 60, t => S(t)), new QuietRules { QuietFor = TimeSpan.FromSeconds(20) }), "", "the minute is a rule, not a constant");

            // the total CPU, every process counted
            T.Eq(Why(Run(0, 60, t => S(t, cpu: 14.9))), "", "total CPU just under 15% is quiet");
            T.Eq(Why(Run(0, 60, t => S(t, cpu: 15))), "other programs are using the CPU (about 15%)", "15% is not quiet");
            T.Eq(Why(Run(0, 60, t => S(t, cpu: 40))), "other programs are using the CPU (about 40%)", "40% says so");
            T.Eq(Why(Run(0, 60, t => S(t, cpu: 22, game: 22))), "other programs are using the CPU (about 22%)", "the job's own game is not taken off the total before a run (nothing is excluded)");
            T.Eq(Why(Run(0, 60, t => S(t, cpu: t < 30 ? 0 : 31))), "other programs are using the CPU (about 16%)", "the average over the minute counts, so half a minute of 31% is too much");
            T.Eq(Why(Run(0, 60, t => S(t, cpu: t < 6 ? 100 : 5))), "", "a burst that fills less than a sixth of the minute is not");
            T.Eq(Why(Run(0, 130, t => S(t, cpu: t < 60 ? 100 : 5))), "", "a busy time before the minute does not count");
            T.Eq(Why(Run(0, 130, t => S(t, cpu: t < 80 ? 100 : 5))), "other programs are using the CPU (about 21%)", "but one inside it does (10 s at 100% in a minute: the average is over 15%)");

            // keyboard and mouse
            T.Eq(Why(Run(0, 60, t => S(t, idle: 60))), "", "60 s without input is quiet");
            T.Eq(Why(Run(0, 60, t => S(t, idle: 59))), "the keyboard or mouse was used 59 s ago", "59 s is not");
            T.Eq(Why(Run(0, 60, t => S(t, idle: t < 60 ? 500 : 3))), "the keyboard or mouse was used 3 s ago", "a key a moment ago starts the minute over");
            T.Eq(Why(Run(0, 60, t => S(t, idle: 0))), "the keyboard or mouse was used 0 s ago", "this very second");

            // the PC's state, now
            T.Eq(Why(Run(0, 60, t => S(t, player: t == 60))), "Death Muffin is open", "the player's Death Muffin is open");
            T.Eq(Why(Run(0, 60, t => S(t, full: t == 60))), "a full-screen app is open", "a full-screen app is open");
            T.Eq(Why(Run(0, 60, t => S(t, battery: t == 60))), "this PC is on battery", "the PC is on battery");
            T.Eq(Why(Run(0, 60, t => S(t, player: t == 60, full: t == 60, battery: t == 60))), "Death Muffin is open", "the game is named first");
            // ... and a moment ago
            T.Eq(Why(Run(0, 60, t => S(t, player: t == 10))), "Death Muffin was open a moment ago", "Death Muffin was open ten seconds into the minute");
            T.Eq(Why(Run(0, 60, t => S(t, full: t == 10))), "a full-screen app was open a moment ago", "a full-screen app was");
            T.Eq(Why(Run(0, 60, t => S(t, battery: t == 10))), "this PC was on battery a moment ago", "the battery was in use");
            T.Eq(Why(Run(0, 100, t => S(t, player: t == 10, full: t == 20, battery: t == 30))), "", "all of that, but before the minute, is over");

            // a reader that stalled (sleep, a hang) has not watched the PC
            var gap = Run(0, 30, t => S(t)); gap.AddRange(Run(100, 130, t => S(t)));
            T.Eq(Why(gap), "watching the PC for a quiet minute (30 s so far)", "after a long gap the minute starts over");
            gap = Run(0, 30, t => S(t)); gap.AddRange(Run(40, 70, t => S(t)));
            T.Eq(Why(gap), "watching the PC for a quiet minute (30 s so far)", "a gap of 10 s inside the minute does too");
            gap = Run(0, 30, t => S(t)); gap.AddRange(Run(34, 70, t => S(t)));
            T.Eq(Why(gap), "", "a gap of 4 s is a slow reading, not a stall");
            gap = Run(0, 30, t => S(t)); gap.AddRange(Run(100, 160, t => S(t)));
            T.Eq(Why(gap), "", "a stall that is more than a minute ago is over");
            T.Eq(new QuietRules().QuietFor, TimeSpan.FromSeconds(60), "the minute");
            T.Eq(new QuietRules().QuietCpuPct, 15.0, "15%");
        }

        // ---- A disturbed run ---------------------------------------------------------------------------------------------------------------

        static string Dist(List<PcSample> l, double start = 100) { return Quiet.Disturbance(l, TimeSpan.FromSeconds(start), Rules); }

        static void DisturbedTests()
        {
            T.Eq(Dist(new List<PcSample>()), "", "a run with no readings was not disturbed");
            T.Eq(Dist(Run(101, 200, t => S(t, cpu: 45, game: 40, idle: 400 + t))), "", "a run on a quiet PC is left alone: the others use 5%");

            // keyboard and mouse
            T.Eq(Dist(Run(101, 140, t => S(t, idle: t == 110 ? 0 : t < 110 ? t + 400 : t - 110))), "the keyboard or mouse was used", "a key pressed during the run disturbs it");
            T.Eq(Dist(Run(101, 140, t => S(t, idle: t + 400))), "", "input long before the run does not");
            T.Eq(Dist(Run(101, 140, t => S(t, idle: t - 96))), "", "input 4 s before the run started (the last quiet reading was before) does not");
            T.Eq(Dist(new List<PcSample> { S(101, idle: 0.5) }), "", "input within a second of the start is the clocks' difference, not a touch");
            T.Eq(Dist(new List<PcSample> { S(102.5, idle: 0.5) }), "the keyboard or mouse was used", "input 2 s after the start is a touch");
            T.Eq(Dist(new List<PcSample> { S(50, idle: 0), S(101, idle: 500) }), "", "readings from before the run are not the run's");

            // the PC's state
            T.Eq(Dist(Run(101, 140, t => S(t, player: t == 120))), "Death Muffin was started", "the player starts Death Muffin during the run");
            T.Eq(Dist(Run(101, 140, t => S(t, battery: t == 120))), "the PC went on battery", "the cable is pulled during the run");
            T.Eq(Dist(Run(101, 140, t => S(t, full: true))), "", "a full-screen app is not a disturbance (the game's own window may count as one on a small screen)");

            // the other processes' CPU: any 30 s of the run, once it is 10 s old
            T.Eq(Dist(Run(101, 112, t => S(t, cpu: 45, game: 20))), "other programs were using the CPU (about 25%)", "25% for 12 s is too much");
            T.Eq(Dist(Run(101, 110, t => S(t, cpu: 45, game: 20))), "", "a run younger than 10 s is not judged on its CPU");
            T.Eq(Dist(Run(101, 140, t => S(t, cpu: 60, game: 40))), "", "20% on average is allowed (over 20 is not)");
            T.Eq(Dist(Run(101, 140, t => S(t, cpu: 60.4, game: 40))), "other programs were using the CPU (about 20%)", "20.4% is over, and is shown as 20%");
            T.Eq(Dist(Run(101, 140, t => S(t, cpu: 61, game: 40))), "other programs were using the CPU (about 21%)", "21% does");
            T.Eq(Dist(Run(101, 140, t => S(t, cpu: 30, game: 30))), "", "the game's own CPU is taken off");
            T.Eq(Dist(Run(101, 140, t => S(t, cpu: 10, game: 30))), "", "and never counts below nothing");
            T.Eq(Dist(Run(101, 140, t => S(t, cpu: 100, game: 50))), "other programs were using the CPU (about 50%)", "half the CPU for another program is a lot");
            T.Eq(Dist(Run(101, 200, t => S(t, cpu: t >= 150 && t < 154 ? 100 : 5))), "", "a burst of 4 s in a run is not (the game's measured part is about 30 s: 4 s of 100% is 17% of it)");
            T.Eq(Dist(Run(101, 200, t => S(t, cpu: t >= 150 && t < 156 ? 100 : 5))), "other programs were using the CPU (about 21%)", "a burst of 6 s is: over any 30 s the average passes 20%");
            T.Eq(Dist(Run(101, 300, t => S(t, cpu: t >= 150 && t < 160 ? 70 : 5))), "other programs were using the CPU (about 20%)", "10 s at 70% disturbs although the whole run averages 8%");
            T.Eq(Dist(Run(101, 300, t => S(t, cpu: t >= 150 && t < 165 ? 60 : 5))), "other programs were using the CPU (about 22%)", "15 s at 60% does too");
            T.Eq(Dist(Run(101, 140, t => S(t, cpu: 35, game: 20)), 60), "", "readings before the start do not count (a run that started at 60 and was left alone)");
            T.Eq(Rules.OthersCpuPct, 20.0, "20%");
            T.Eq(Rules.OthersWindow, TimeSpan.FromSeconds(30), "30 s");
        }

        // ---- The result file ----------------------------------------------------------------------------------------------------------------

        static void ResultFileTests()
        {
            string dir = Util.TempDir("benchresult");
            try
            {
                Dictionary<string, object> run; string err;
                T.Ok(!JobPlan.TryReadBenchRun(dir, "Low", out run, out err) && err == "The game finished the benchmark on Low but left no result.", "no pending.json: " + err);
                File.WriteAllText(Path.Combine(dir, "pending.json"), "[]");
                T.Ok(!JobPlan.TryReadBenchRun(dir, "Low", out run, out err) && err == "The game finished the benchmark on Low but left no result.", "an empty queue is no result");
                File.WriteAllText(Path.Combine(dir, "pending.json"), "[{\"clientRunId\":\"a1\"");
                T.Ok(!JobPlan.TryReadBenchRun(dir, "Low", out run, out err) && err == "The result of the benchmark on Low is damaged.", "a half-written file is damaged");
                File.WriteAllText(Path.Combine(dir, "pending.json"), "{\"clientRunId\":\"a1\"}");
                T.Ok(!JobPlan.TryReadBenchRun(dir, "Low", out run, out err) && err.Contains("left no result"), "an object is not a queue");
                File.WriteAllText(Path.Combine(dir, "pending.json"), "[1,2]");
                T.Ok(!JobPlan.TryReadBenchRun(dir, "Low", out run, out err) && err == "The result of the benchmark on Low is damaged.", "a queue of numbers is damaged");
                File.WriteAllText(Path.Combine(dir, "pending.json"), "[{\"clientRunId\":\"a1\",\"preset\":\"low\",\"cancelled\":true}]");
                T.Ok(!JobPlan.TryReadBenchRun(dir, "Low", out run, out err) && err == "The benchmark on Low was cancelled before it finished.", "a cancelled run is no result");

                // the last entry is the run just made (DmBenchHistory.record appends); an earlier one is left behind
                File.WriteAllText(Path.Combine(dir, "pending.json"), "[{\"clientRunId\":\"old\"},{\"clientRunId\":\"new\",\"preset\":\"low\",\"metrics\":{\"avg_fps\":88.25,\"hitches\":3},\"standard\":true,\"report\":\"line\\nline\"}]");
                T.Ok(JobPlan.TryReadBenchRun(dir, "Low", out run, out err) && err == null, "two entries: " + err);
                T.Eq(MiniJson.Str(run, "clientRunId"), "new", "the last entry is the run");
                T.Ok(MiniJson.Obj(run, "metrics") != null && MiniJson.Bool(run, "standard"), "the metrics and flags came along");
                T.Eq((double)MiniJson.Obj(run, "metrics")["avg_fps"], 88.25, "and the numbers");

                // the server takes at most 64 KB of JSON a run
                string fat = "[{\"clientRunId\":\"fat\",\"report\":\"" + new string('x', 70000) + "\"}]";
                File.WriteAllText(Path.Combine(dir, "pending.json"), fat);
                T.Ok(!JobPlan.TryReadBenchRun(dir, "Low", out run, out err) && err == "The result of the benchmark on Low is too big to send.", "a run over 64 KB is refused here, not by the server");
                string fits = "[{\"clientRunId\":\"fits\",\"report\":\"" + new string('x', 60000) + "\"}]";
                File.WriteAllText(Path.Combine(dir, "pending.json"), fits);
                T.Ok(JobPlan.TryReadBenchRun(dir, "Low", out run, out err), "a run under 64 KB is sent: " + err);
                T.Eq(JobPlan.MaxRunBytes, 65536, "64 KB");
                T.Ok(!JobPlan.TryReadBenchRun(Path.Combine(dir, "nowhere"), "Low", out run, out err) && err.Contains("left no result"), "a folder that is not there");
            }
            finally { Util.Rm(dir); }
        }

        // ---- done, with the runs ------------------------------------------------------------------------------------------------------------

        sealed class RecordingTransport : ITransport
        {
            public readonly List<KeyValuePair<Uri, string>> Sent = new List<KeyValuePair<Uri, string>>();
            public System.Threading.Tasks.Task<HttpReply> SendAsync(string method, Uri url, string teamToken, byte[] body, string contentType, CancellationToken ct)
            {
                Sent.Add(new KeyValuePair<Uri, string>(url, body == null ? "" : Encoding.UTF8.GetString(body)));
                return System.Threading.Tasks.Task.FromResult(new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{}}" });
            }
        }

        static void ApiBodyTests()
        {
            var tr = new RecordingTransport();
            var api = new TeamApi(tr, new Uri(TeamUrls.ApiBase)) { Token = "t" };
            var run1 = new Dictionary<string, object> { { "clientRunId", "a1" }, { "preset", "low" }, { "metrics", new Dictionary<string, object> { { "avg_fps", 88.25 }, { "hitches", 3.0 } } }, { "standard", true }, { "report", "a\nb" } };
            var run2 = new Dictionary<string, object> { { "clientRunId", "a2" }, { "preset", "medium" } };
            T.Ok(Util.Wait(api.DoneBenchAsync("ab12cd34ef56", new List<Dictionary<string, object>> { run1, run2 }, "the log", 12.34, 56.78, CancellationToken.None)).Ok, "done for a bench job is sent");
            T.Eq(tr.Sent[0].Key.AbsolutePath, "/death-muffin/api/team/jobs/ab12cd34ef56/done", "to the same done route");
            var body = MiniJson.TryObject(tr.Sent[0].Value);
            T.Eq(MiniJson.Arr(body, "files").Count, 0, "with no pictures");
            var runs = MiniJson.Arr(body, "runs");
            T.Eq(runs.Count, 2, "and the two runs");
            T.Eq(MiniJson.Str((Dictionary<string, object>)runs[0], "clientRunId") + MiniJson.Str((Dictionary<string, object>)runs[1], "clientRunId"), "a1a2", "in order");
            var m = MiniJson.Obj((Dictionary<string, object>)runs[0], "metrics");
            T.Ok((double)m["avg_fps"] == 88.25 && (double)m["hitches"] == 3.0, "the numbers arrive as the game wrote them");
            T.Eq(MiniJson.Str((Dictionary<string, object>)runs[0], "report"), "a\nb", "and the text");
            T.Ok(MiniJson.Bool((Dictionary<string, object>)runs[0], "standard"), "and the flags");
            T.Eq(MiniJson.Str(body, "log"), "the log", "the log goes along");
            var tim = MiniJson.Obj(body, "timings");
            T.Ok((double)tim["downloadS"] == 12.3 && (double)tim["runS"] == 56.8, "and the timings");
            T.Ok(!Util.Wait(api.DoneBenchAsync("../x", new List<Dictionary<string, object>>(), "l", 0, 0, CancellationToken.None)).Ok && tr.Sent.Count == 1, "a bad job id is refused without a request");
        }
    }
}
