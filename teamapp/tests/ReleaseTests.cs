using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

namespace DeathMuffinTeam.Tests
{
    /// <summary>
    /// The `release` job: the release checks of a new client on a team PC (install, quit while loading, screens, stutter, bench, soak). Its payload, command lines, the server calls, the runner's steps
    /// (each result uploaded as it finishes, a failed step does not stop the next) and the controller side.
    /// </summary>
    static class ReleaseTests
    {
        static readonly Uri Site = new Uri("https://muffindevelopment.com/death-muffin/");

        public static void Run()
        {
            PlanTests();
            RefusalTests();
            CommandTests();
            ApiBodyTests();
            ControllerRuns();
        }

        public static void RunnerRuns()
        {
            AllSteps();
            FailingSteps();
            BootSteps();
            SubsetsAndDownloads();
            ScreensDetails();
            ScenarioFiles();
            SoakAndBench();
            JobProblems();
        }

        // ---- The payload ---------------------------------------------------------------------------------------------------------------

        static List<object> ReleaseFiles()
        {
            return new List<object> { Program.File_("DeathMuffin.exe", "godot-release-4.7.2"), Program.File_("DeathMuffin.pck"), Program.File_("DeathMuffin.assets.pck", "assets-0f3a9c"), Program.File_("libdmcore.windows.template_release.x86_64.dll") };
        }

        static List<object> DebugFiles()
        {
            return new List<object> { Program.File_("DeathMuffinDebug.pck", sha: new string('d', 64)), Program.File_("DeathMuffin.assets.pck", "assets-0f3a9c"), Program.File_("libdmcore.windows.template_release.x86_64.dll"), Program.File_("DeathMuffinDebug.exe", "godot-debug-4.7.2") };
        }

        /// <summary>The publish hook's payload for a team PC: the release build and the debug build of the same revision, the steps, the bench setups, the screens plan (two window sizes and one more UI scale), a 2-minute soak.</summary>
        public static Dictionary<string, object> ValidPayload()
        {
            return new Dictionary<string, object>
            {
                { "version", "20261019.120000-abc1234" }, { "rev", "0123456789ab" }, { "godotVersion", "4.7.2.stable" },
                { "builds", new List<object>
                {
                    new Dictionary<string, object> { { "label", "release" }, { "files", ReleaseFiles() } },
                    new Dictionary<string, object> { { "label", "debug" }, { "files", DebugFiles() } },
                } },
                { "steps", new List<object> { "install", "quit-loading", "screens", "stutter", "bench", "soak" } },
                { "setups", new List<object> { BenchTests.Setup("low"), BenchTests.Setup("medium") } },
                { "screens", new Dictionary<string, object>
                {
                    { "plan", ((Dictionary<string, object>)Program.ValidPayload()["plan"]) },
                    { "resolutions", new List<object> { "1920x1080", "2560x1440" } }, { "uiScales", new List<object> { "1.5" } },
                } },
                { "soak", new Dictionary<string, object> { { "minutes", 2.0 } } },
                { "args", new List<object>() },
            };
        }

        static List<object> Builds(Dictionary<string, object> p) { return (List<object>)p["builds"]; }
        static Dictionary<string, object> Build(Dictionary<string, object> p, string label) { return Builds(p).Cast<Dictionary<string, object>>().First(b => (string)b["label"] == label); }
        static List<object> BuildFilesOf(Dictionary<string, object> p, string label) { return (List<object>)Build(p, label)["files"]; }
        static Dictionary<string, object> Screens(Dictionary<string, object> p) { return (Dictionary<string, object>)p["screens"]; }

        static bool Parse(Dictionary<string, object> p, out JobPlan plan, out string error) { return JobPlan.TryParse(JobPlan.ReleaseKind, p, Site, out plan, out error); }

        static void PlanTests()
        {
            JobPlan plan; string error;
            T.Ok(Parse(ValidPayload(), out plan, out error), "a release payload is accepted: " + error);
            T.Eq(plan.Kind, "release", "the plan knows its kind");
            T.Ok(JobPlan.RunsKind("release") && !JobPlan.RunsKind("releases"), "this version runs release jobs");
            T.Eq(string.Join(",", plan.Steps), "install,quit-loading,screens,stutter,bench,soak", "the steps");
            T.Eq(plan.Builds.Count, 2, "two builds");
            T.Eq(plan.BuildNamed("release").Files.Count + "," + plan.BuildNamed("debug").Files.Count, "4,4", "each with its files");
            T.Ok(plan.BuildNamed("both") == null, "no other build");
            T.Eq(string.Join(",", plan.ScreenSizes.Select(s => s.Text)), "1920x1080,2560x1440", "the window sizes");
            T.Eq(string.Join(",", plan.UiScales), "1.5", "the UI scale besides the default");
            T.Eq(plan.ScreensPreset, "high", "screens on high unless the job says");
            T.Eq(plan.SoakMinutes, 2, "the soak's minutes");
            T.Eq(plan.Setups.Count, 2, "the bench setups");
            T.Eq(plan.Setups[0].Preset + "|" + plan.Setups[0].Room + "|" + plan.Setups[0].Class + "|" + plan.Setups[0].Size + "|" + plan.Setups[0].Length, "low|graves|2|full_party|full", "as sent");
            T.Eq(plan.PlanShots, 2, "the screens step's shot plan");
            T.Eq(MiniJson.Arr(MiniJson.TryObject(plan.PlanJson), "shots").Count, 2, "is the plan's");
            T.Eq(plan.Args.Count, 0, "a release job adds no game option of its own to the release exe's runs (the debug runs get --dev-offline themselves)");
            T.Ok(JobPlan.TryParse(JobPlan.ReleaseKind, MiniJson.Write(ValidPayload()), Site, out plan, out error) && plan.Steps.Count == 6, "a release payload given as JSON text");

            // steps may be listed in any order and in any subset; they run in the contract's order
            var p = ValidPayload(); p["steps"] = new List<object> { "soak", "install", "bench" };
            T.Ok(Parse(p, out plan, out error) && string.Join(",", plan.Steps) == "install,bench,soak", "steps run in the contract's order whatever order they are listed in: " + error);
            // only the builds the steps need
            p = ValidPayload(); p["steps"] = new List<object> { "install", "bench" }; Builds(p).RemoveAt(1);
            T.Ok(Parse(p, out plan, out error) && plan.Builds.Count == 1 && plan.BuildNamed("debug") == null, "install and bench need only the release build: " + error);
            p = ValidPayload(); p["steps"] = new List<object> { "stutter" }; Builds(p).RemoveAt(0);
            T.Ok(Parse(p, out plan, out error) && plan.Builds.Count == 1 && plan.BuildNamed("release") == null, "stutter needs only the debug build: " + error);
            p = ValidPayload(); p["steps"] = new List<object> { "install" }; p.Remove("setups"); p.Remove("screens"); p.Remove("soak");
            T.Ok(Parse(p, out plan, out error), "a step's settings are needed only for that step: " + error);

            // defaults
            p = ValidPayload(); p.Remove("setups");
            T.Ok(Parse(p, out plan, out error) && plan.Setups.Count == 2 && plan.Setups[0].Preset == "low" && plan.Setups[1].Preset == "medium" && plan.Setups[1].Size == "full_party" && plan.Setups[1].Length == "full" && plan.Setups[1].Room == "graves", "no setups: Low and Medium, the Full Party fight, full: " + error);
            p = ValidPayload(); Screens(p).Remove("resolutions"); Screens(p).Remove("uiScales");
            T.Ok(Parse(p, out plan, out error) && string.Join(",", plan.ScreenSizes.Select(s => s.Text)) == "1920x1080,2560x1440,3840x2160,3440x1440" && plan.UiScales.Count == 0, "no resolutions: the four standard sizes, the default UI scale only: " + error);
            p = ValidPayload(); p.Remove("soak");
            T.Ok(Parse(p, out plan, out error) && plan.SoakMinutes == 30, "no soak settings: 30 minutes");
            p = ValidPayload(); Screens(p)["preset"] = "ultra"; Screens(p)["uiScales"] = new List<object> { 1.25, "2", 1.5, };
            T.Ok(Parse(p, out plan, out error) && plan.ScreensPreset == "ultra" && string.Join(",", plan.UiScales) == "1.25,2,1.5", "a preset and UI scales as numbers or text: " + error);
            p = ValidPayload(); Screens(p)["uiScales"] = new List<object> { "1.5", 1.5 };
            T.Ok(Parse(p, out plan, out error) && plan.UiScales.Count == 1, "a UI scale named twice is one");
            p = ValidPayload(); p["args"] = new List<object> { "--class=3", "--class=3", "--qa" };
            T.Ok(Parse(p, out plan, out error) && string.Join(" ", plan.Args) == "--class=3 --qa", "game options, once each");
        }

        static string Reject(Action<Dictionary<string, object>> mutate, string name, string wantInError = null)
        {
            var p = ValidPayload();
            mutate(p);
            JobPlan plan; string err;
            bool ok = Parse(p, out plan, out err);
            T.Ok(!ok && plan == null && !string.IsNullOrEmpty(err), "release payload refused: " + name + (ok ? " (it was accepted)" : ""));
            if (wantInError != null) T.Has(err, wantInError, "release refusal says why: " + name);
            if (err != null) T.Ok(!err.Contains("Exception") && !err.Contains(" at "), "release refusal is plain English: " + name);
            return err;
        }

        static void RefusalTests()
        {
            // builds and steps
            Reject(p => p.Remove("builds"), "no builds", "no builds");
            Reject(p => p["builds"] = new List<object>(), "an empty build list", "no builds");
            Reject(p => p["builds"] = "release", "builds as text", "no builds");
            Reject(p => { p.Remove("builds"); p["files"] = ReleaseFiles(); }, "a flat file list instead of builds", "no builds");
            Reject(p => Builds(p).Add(new Dictionary<string, object> { { "label", "release" }, { "files", ReleaseFiles() } }), "three builds", "no builds");
            Reject(p => ((Dictionary<string, object>)Builds(p)[1])["label"] = "release", "the release build twice", "twice");
            Reject(p => ((Dictionary<string, object>)Builds(p)[1])["label"] = "before", "a build labelled before", "not allowed");
            Reject(p => ((Dictionary<string, object>)Builds(p)[0])["label"] = "Release", "a build label in capitals", "not allowed");
            Reject(p => p.Remove("steps"), "no steps", "no steps");
            Reject(p => p["steps"] = new List<object>(), "an empty step list", "no steps");
            Reject(p => p["steps"] = "install", "steps as text", "no steps");
            Reject(p => p["steps"] = new List<object> { "install", "install" }, "a step twice", "twice");
            foreach (string bad in new[] { "launch", "Install", "quit_loading", "../install", "" })
                Reject(p => p["steps"] = new List<object> { bad }, "step '" + bad + "'", "does not know");
            Reject(p => p["steps"] = new List<object> { 1.0 }, "a step that is a number", "does not know");
            // the builds the steps need
            Reject(p => { p["steps"] = new List<object> { "install" }; Builds(p).RemoveAt(0); }, "install with no release build", "no release build");
            Reject(p => { p["steps"] = new List<object> { "quit-loading" }; Builds(p).RemoveAt(0); }, "quit-loading with no release build", "no release build");
            Reject(p => { p["steps"] = new List<object> { "bench" }; Builds(p).RemoveAt(0); }, "bench with no release build", "no release build");
            Reject(p => { p["steps"] = new List<object> { "screens" }; Builds(p).RemoveAt(1); }, "screens with no debug build", "no debug build");
            Reject(p => { p["steps"] = new List<object> { "stutter" }; Builds(p).RemoveAt(1); }, "stutter with no debug build", "no debug build");
            Reject(p => { p["steps"] = new List<object> { "soak" }; Builds(p).RemoveAt(1); }, "soak with no debug build", "no debug build");
            foreach (string need in JobPlan.BenchFiles)
                Reject(p => BuildFilesOf(p, "release").RemoveAll(f => (string)((Dictionary<string, object>)f)["name"] == need), "the release build without " + need, "release build does not include " + need);
            Reject(p => BuildFilesOf(p, "debug").RemoveAll(f => (string)((Dictionary<string, object>)f)["name"] == "DeathMuffinDebug.exe"), "the debug build without its exe", "debug build does not include");
            Reject(p => BuildFilesOf(p, "debug").RemoveAll(f => (string)((Dictionary<string, object>)f)["name"] == "DeathMuffinDebug.pck"), "the debug build without its pack", "debug build does not include");
            Reject(p => BuildFilesOf(p, "release").Add(Program.File_("../evil.dll")), "an unsafe name in the release build", "not allowed");
            Reject(p => BuildFilesOf(p, "debug").Add(Program.File_("a.dll", url: "https://evil.example/death-muffin/team-files/x/a.dll")), "another host in the debug build", "not on the game's server");
            Reject(p => BuildFilesOf(p, "debug")[1] = Program.File_("DeathMuffin.assets.pck", "assets-0f3a9c", sha: new string('e', 64)), "one cache name for two different art packs", "different files");
            // the settings
            Reject(p => p["setups"] = new List<object>(), "an empty setup list", "no benchmark setups");
            Reject(p => p["setups"] = new List<object> { BenchTests.Setup("potato") }, "a setup with an unknown preset", "does not exist");
            Reject(p => p["setups"] = new List<object> { BenchTests.Setup("low", length: "forever") }, "a setup with an unknown length", "length");
            Reject(p => p.Remove("screens"), "screens with no settings", "no shot plan");
            Reject(p => Screens(p).Remove("plan"), "screens with no plan", "no shot plan");
            Reject(p => Screens(p)["plan"] = new Dictionary<string, object> { { "shots", new List<object>() } }, "screens with an empty plan", "no shot plan");
            Reject(p => ((Dictionary<string, object>)Screens(p)["plan"])["pad"] = new string('x', 70000), "a plan over 64 KB", "too big");
            foreach (string bad in new[] { "800", "1920X1080", "1920x", "x1080", "100x100", "639x480", "9000x2000", "1920x1080x2", "1920 x 1080", "../1920x1080", "", "-1920x1080" })
                Reject(p => Screens(p)["resolutions"] = new List<object> { bad }, "window size '" + bad + "'", "window size that is not allowed");
            Reject(p => Screens(p)["resolutions"] = new List<object> { 1920.0 }, "a window size that is a number", "not allowed");
            Reject(p => Screens(p)["resolutions"] = new List<object> { "1920x1080", "1920x1080" }, "a window size twice", "twice");
            Reject(p => Screens(p)["resolutions"] = new List<object> { "800x600", "1024x768", "1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160" }, "seven window sizes", "too many");
            foreach (string bad in new[] { "0", "abc", "-1", "1e3", "1.5.2", "1,5", "100", "../2", "", "1.5555" })
                Reject(p => Screens(p)["uiScales"] = new List<object> { bad }, "UI scale '" + bad + "'", "UI scale");
            Reject(p => Screens(p)["uiScales"] = new List<object> { "1", "1.25", "1.5", "2" }, "four UI scales", "UI scales");
            Reject(p => Screens(p)["uiScales"] = "1.5", "UI scales as text", "UI scales");
            Reject(p => Screens(p)["preset"] = "potato", "an unknown screens preset", "does not exist");
            foreach (object bad in new object[] { 0.0, 121.0, -5.0, 1.5, "30", true })
                Reject(p => p["soak"] = new Dictionary<string, object> { { "minutes", bad } }, "soak minutes " + bad, "soak step's minutes");
            // the options
            foreach (string reserved in new[] { "--boot-check", "--quit-while-loading", "--stutter", "--stutter-out=x", "--soak=5", "--soak-out=x", "--ui-scale=2", "--shot-plan=x", "--shots=x", "--preset=low", "--benchmark", "--bench-quit", "--position=0,0", "--audio-driver=ALSA", "--clips=x" })
                Reject(p => p["args"] = new List<object> { reserved }, "args: " + reserved, "which the app sets itself");
        }

        // ---- Command lines ---------------------------------------------------------------------------------------------------------------

        static void CommandTests()
        {
            JobPlan plan; string error;
            Parse(ValidPayload(), out plan, out error);
            T.Eq(string.Join("|", JobPlan.BootCheckArgs(false)), "--windowed|--resolution|1600x900|--audio-driver|Dummy|--|--boot-check", "install: the release exe with -- --boot-check, windowed and silent");
            T.Eq(string.Join("|", JobPlan.BootCheckArgs(true)), "--windowed|--resolution|1600x900|--audio-driver|Dummy|--|--boot-check|--quit-while-loading", "quit-loading: and --quit-while-loading");
            T.Eq(string.Join("|", JobPlan.BootCheckArgs(true, "-1700,0")), "--windowed|--resolution|1600x900|--audio-driver|Dummy|--position|-1700,0|--|--boot-check|--quit-while-loading", "outside every monitor when a position is given");
            string planFile = "C:\\Users\\Test User\\AppData\\Local\\DeathMuffinTeam\\jobs\\q7x2k9ab\\plan.json";
            string dir = "C:\\Users\\Test User\\AppData\\Local\\DeathMuffinTeam\\jobs\\q7x2k9ab\\out\\screens\\3840x2160_s1-5";
            var big = new ScreenSize { Width = 3840, Height = 2160 };
            var a = plan.ScreensCommandArgs(big, "1.5", planFile, dir);
            T.Eq(string.Join("|", a),
                "--windowed|--resolution|3840x2160|--audio-driver|Dummy|--|--dev-offline|--class=2|--shot-plan=C:/Users/Test User/AppData/Local/DeathMuffinTeam/jobs/q7x2k9ab/plan.json|--shots=C:/Users/Test User/AppData/Local/DeathMuffinTeam/jobs/q7x2k9ab/out/screens/3840x2160_s1-5|--preset=high|--ui-scale=1.5|--qa-window=3840x2160",
                "screens: the debug build at the window size, the plan, the pictures' folder, the preset, the UI scale and the window size again for the game (it cannot read --resolution)");
            T.Ok(!plan.ScreensCommandArgs(big, "", planFile, dir).Any(x => x.StartsWith("--ui-scale")), "the default UI scale passes no --ui-scale");
            T.Ok(plan.ScreensCommandArgs(big, "", planFile, dir).Count(x => x.StartsWith("--class=")) == 1, "the debug build is told its class once (without it no game starts and the QA driver gives up)");
            T.Eq(string.Join(" ", plan.ScreensCommandArgs(big, "", "p", "s", "-3940,0").Take(8)), "--windowed --resolution 3840x2160 --audio-driver Dummy --position -3940,0 --", "the window is outside every monitor");
            var withOptions = ValidPayload(); withOptions["args"] = new List<object> { "--class=2", "--qa" };
            JobPlan p2; Parse(withOptions, out p2, out error);
            T.Eq(string.Join(" ", p2.ScreensCommandArgs(big, "", "p", "s").Skip(6).Take(3)), "--dev-offline --class=2 --qa", "the job's options follow --dev-offline");
            T.Eq(string.Join("|", plan.StutterCommandArgs("C:\\j\\out\\stutter")), "--windowed|--resolution|1600x900|--audio-driver|Dummy|--|--dev-offline|--stutter|--stutter-out=C:/j/out/stutter", "stutter: the debug build's --stutter scenario writing into its folder");
            T.Eq(string.Join("|", plan.SoakCommandArgs("C:\\j\\out\\soak", "-1700,0")), "--windowed|--resolution|1600x900|--audio-driver|Dummy|--position|-1700,0|--|--dev-offline|--soak=2|--soak-out=C:/j/out/soak", "soak: --soak=<minutes> writing into its folder");
            T.Ok(!plan.StutterCommandArgs("x").Contains("--fixed-fps") && !plan.SoakCommandArgs("x").Contains("--fixed-fps"), "no --fixed-fps: these are timed runs");
            T.Eq(JobPlan.ScreensTag(big, ""), "3840x2160", "the pictures' tag at the default scale");
            T.Eq(JobPlan.ScreensTag(big, "1.5"), "3840x2160_s1-5", "with a UI scale (a name has no dot)");
            T.Eq(JobPlan.ScreensTag(new ScreenSize { Width = 3440, Height = 1440 }, "2"), "3440x1440_s2", "a whole scale");
            var png = new System.Text.RegularExpressions.Regex("^[a-z0-9_-]{1,60}\\.png$");
            T.Eq(JobPlan.UploadName(JobPlan.ScreensTag(big, "1.5"), "bag with tooltip.png"), "3840x2160_s1-5_bag_with_tooltip.png", "`<w>x<h>[_s<scale>]_<shot>.png`");
            T.Ok(png.IsMatch(JobPlan.UploadName(JobPlan.ScreensTag(big, "1.125"), new string('z', 100) + ".png")), "and it fits the server's rule");

            // the game's boot line
            T.Eq(JobPlan.ParseBootMs("loading...\nBOOT OK 812\n"), 812L, "BOOT OK <ms>");
            T.Eq(JobPlan.ParseBootMs("BOOT OK 0"), 0L, "at the very start");
            T.Eq(JobPlan.ParseBootMs("noise BOOT OK 4521 more"), 4521L, "among other words");
            T.Eq(JobPlan.ParseBootMs("a\r\nBOOT OK 77\r\nb"), 77L, "with Windows line ends");
            foreach (string none in new[] { "", null, "BOOT FAILED", "BOOT OK", "BOOT OK x", "BOOT OK -5", "XBOOT OK 5", "BOOT OK 12345678901", "boot ok 5" })
                T.Eq(JobPlan.ParseBootMs(none), (long?)null, "no boot line in '" + none + "'");

            // a wide window starts left of every monitor by its own width
            T.Eq(JobPlan.OffscreenPosition(0, 0), "-1700,0", "a 1600-wide window as before");
            T.Eq(JobPlan.OffscreenPosition(0, 0, 3840), "-3940,0", "a 3840-wide one");
            T.Eq(JobPlan.OffscreenPosition(-1920, -200, 2560), "-4580,-200", "with a monitor to the left");
            foreach (int w in new[] { 1920, 2560, 3440, 3840 })
                T.Ok(int.Parse(JobPlan.OffscreenPosition(0, 0, w).Split(',')[0]) + w < 0, "a " + w + "-wide window ends left of the screen");
        }

        // ---- The server calls --------------------------------------------------------------------------------------------------------

        static void ApiBodyTests()
        {
            var tr = new Program.FakeTransport();
            var api = new TeamApi(tr, new Uri(TeamUrls.ApiBase)) { Token = "tok" };
            tr.Respond = r => new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{}}" };
            byte[] json = Encoding.UTF8.GetBytes("{\"ok\":true}");
            Util.Wait(api.UploadAsync("ab12cd34ef56", "quit-loading.json", json, CancellationToken.None));
            T.Eq(tr.Sent[0].Method + " " + tr.Sent[0].Url.AbsolutePath, "PUT /death-muffin/api/team/jobs/ab12cd34ef56/files/quit-loading.json", "a step's result goes to the files route");
            T.Eq(tr.Sent[0].ContentType, "application/json", "as application/json");
            T.Ok(tr.Sent[0].Body.SequenceEqual(json), "the bytes as they are");
            T.Eq(TeamApi.JsonType, "application/json", "the content type");
            Util.Wait(api.UploadAsync("ab12cd34ef56", "1920x1080_s1-5_bag.png", Util.FakePng(1), CancellationToken.None));
            T.Eq(tr.Sent[1].ContentType, "image/png", "a screens picture is a picture");
            tr.Sent.Clear();
            foreach (string bad in new[] { "Install.json", "install.JSON", "_x.json", "-x.json", ".json", "a b.json", "../x.json", "a/b.json", "x.json.exe", "x.txt", new string('a', 61) + ".json", "a.json/../b.json" })
                T.Ok(!Util.Wait(api.UploadAsync("ab12cd34ef56", bad, json, CancellationToken.None)).Ok, "upload refuses the name '" + bad + "'");
            T.Has(Util.Wait(api.UploadAsync("ab12cd34ef56", "A.json", json, CancellationToken.None)).Error, "result", "a refused result name says result");
            T.Eq(tr.Sent.Count, 0, "refused uploads never reach the network");
            T.Ok(Util.Wait(api.UploadAsync("ab12cd34ef56", new string('a', 60) + ".json", json, CancellationToken.None)).Ok, "60 characters before .json is allowed");

            // done
            tr.Sent.Clear();
            var steps = new List<StepReport>
            {
                new StepReport { Step = "install", Ok = true, Ms = 812 },
                new StepReport { Step = "quit-loading", Ok = false, Error = new string('e', 600), Ms = 20001 },
            };
            var runs = new List<Dictionary<string, object>> { new Dictionary<string, object> { { "clientRunId", "r1" } } };
            Util.Wait(api.DoneReleaseAsync("ab12cd34ef56", steps, new List<string> { "install.json", "quit-loading.json" }, runs, new string('L', 100000) + "THE END", 12.34, 56.78, CancellationToken.None));
            var done = MiniJson.TryObject(Encoding.UTF8.GetString(tr.Sent[0].Body));
            T.Eq(tr.Sent[0].Url.AbsolutePath, "/death-muffin/api/team/jobs/ab12cd34ef56/done", "done route");
            var s0 = (Dictionary<string, object>)MiniJson.Arr(done, "steps")[0];
            var s1 = (Dictionary<string, object>)MiniJson.Arr(done, "steps")[1];
            T.Eq(MiniJson.Str(s0, "step") + "|" + MiniJson.Bool(s0, "ok") + "|" + MiniJson.Int(s0, "ms") + "|" + s0.ContainsKey("error"), "install|True|812|False", "a step that worked: its name, ok and ms, no error");
            T.Eq(MiniJson.Str(s1, "step") + "|" + MiniJson.Bool(s1, "ok") + "|" + MiniJson.Int(s1, "ms") + "|" + MiniJson.Str(s1, "error").Length, "quit-loading|False|20001|400", "a step that failed: the reason, cut to 400 characters");
            T.Eq(string.Join(",", MiniJson.Arr(done, "files").Cast<string>()), "install.json,quit-loading.json", "the files it uploaded");
            T.Eq(MiniJson.Arr(done, "runs").Count, 1, "the bench step's runs");
            T.Ok(MiniJson.Str(done, "log").EndsWith("THE END") && Encoding.UTF8.GetByteCount(MiniJson.Str(done, "log")) <= 60000, "the end of the log, within 64 KB");
            var tim = MiniJson.Obj(done, "timings");
            T.Ok((double)tim["downloadS"] == 12.3 && (double)tim["runS"] == 56.8, "timings");
            Util.Wait(api.DoneReleaseAsync("ab12cd34ef56", steps, new List<string>(), null, "log", 1, 2, CancellationToken.None));
            T.Ok(!MiniJson.TryObject(Encoding.UTF8.GetString(tr.Sent[1].Body)).ContainsKey("runs"), "no runs, no `runs` key");
            Util.Wait(api.DoneReleaseAsync("ab12cd34ef56", steps, new List<string>(), new List<Dictionary<string, object>>(), "log", 1, 2, CancellationToken.None));
            T.Ok(!MiniJson.TryObject(Encoding.UTF8.GetString(tr.Sent[2].Body)).ContainsKey("runs"), "an empty list of runs is none");

            // fail, with the steps that were finished
            tr.Sent.Clear();
            Util.Wait(api.FailAsync("ab12cd34ef56", "stopped: the game started", "log", steps, CancellationToken.None));
            var fail = MiniJson.TryObject(Encoding.UTF8.GetString(tr.Sent[0].Body));
            T.Eq(tr.Sent[0].Url.AbsolutePath, "/death-muffin/api/team/jobs/ab12cd34ef56/fail", "fail route");
            T.Eq(MiniJson.Arr(fail, "steps").Count, 2, "a release job that stops halfway reports its steps");
            T.Eq(MiniJson.Str(fail, "error"), "stopped: the game started", "and why");
            Util.Wait(api.FailAsync("ab12cd34ef56", "x", "log", CancellationToken.None));
            T.Ok(!MiniJson.TryObject(Encoding.UTF8.GetString(tr.Sent[1].Body)).ContainsKey("steps"), "the other fail has no steps");
            Util.Wait(api.FailAsync("ab12cd34ef56", "x", "log", new List<StepReport>(), CancellationToken.None));
            T.Ok(!MiniJson.TryObject(Encoding.UTF8.GetString(tr.Sent[2].Body)).ContainsKey("steps"), "and neither has one with no step to say");
            T.Ok(!Util.Wait(api.DoneReleaseAsync("bad id", steps, null, null, "l", 0, 0, CancellationToken.None)).Ok, "done refuses a bad job id");
        }

        // ---- The controller ----------------------------------------------------------------------------------------------------------

        static void ControllerRuns()
        {
            var r = new CtlRig();
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "release" }, { "title", "Release checks of 20261019.120000-abc1234" }, { "payload", ValidPayload() } });
            r.Start();
            r.Api.Heartbeat = () => FakeApi.OfferReply("jobRel000001", "release", "Release checks of 20261019.120000-abc1234", 2400);
            r.Beat(); r.Eval();
            T.Eq(r.Ui.Shown[0].Text, "Release checks of 20261019.120000-abc1234, about 40 minutes", "the box says what the job is and how long: about 40 minutes");
            T.Has(r.Ui.Shown[0].Note, "starts several times", "and its note says the game starts several times, and that the benchmark and the soak wait for a quiet PC");
            T.Has(r.Ui.Shown[0].Note, "little of the processor for a minute", "(the benchmark and the soak wait for a quiet processor)");
            T.Eq(r.LastCountdown, "Runs by itself in 5:00", "a release job counts down like any job");
            r.Advance(5.01); r.Eval();
            T.Eq(r.Ran, 1, "after 5 minutes without an answer the job runs by itself (AFK mode starts, as for any job)");
            T.Eq(r.Runner.LastPlan.Kind, "release", "the runner got a release plan");
            T.Eq(r.Runner.LastPlan.Steps.Count, 6, "with its steps");
            T.Eq(r.Api.Count("claim"), 1, "the job was claimed at once (unlike a benchmark, which waits for a quiet PC: the checks are quiet by their own rules)");
            r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Result = new RunResult { Ok = true, Steps = new List<StepReport> { new StepReport { Step = "install", Ok = true }, new StepReport { Step = "quit-loading", Ok = true }, new StepReport { Step = "soak", Ok = false } } };
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "release" }, { "title", "t" }, { "payload", ValidPayload() } });
            r.Start(); r.Offer("jobRel000002", "release"); r.Eval();
            T.Ok(r.Ran == 1 && !r.Ui.BoxVisible, "Run without asking: a release job runs with no box");
            T.Ok(r.Ui.Status.StartsWith("Last job: 2 of 3 release check step(s) passed"), "the status after a release job says how many steps passed: " + r.Ui.Status);

            r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.OfferReply("jobRel000003", "release", "", 2400);
            r.Beat(); r.Eval();
            T.Eq(r.Ui.Shown[0].Text, "Release checks of the new client, about 40 minutes", "a release job with no title is named by its kind");

            // the other modes and the waits are the ones every job has
            r = new CtlRig(mode: OfferMode.Yes);
            r.Start(); r.Offer("jobRel000004", "release"); r.Eval(); r.Advance(30); r.Eval();
            T.Ok(r.Ran == 0 && r.LastCountdown == "Runs when you say yes", "Only on a yes: the box asks and waits");
            r = new CtlRig();
            r.Start(); r.Plat.IsFullscreen = true; r.Offer("jobRel000005", "release"); r.Eval(); r.Advance(6); r.Eval();
            T.Ok(r.Ran == 0 && !r.Ui.BoxVisible, "a release job waits for a full-screen app");
            r = new CtlRig();
            r.Start(); r.Plat.IsGame = true; r.Offer("jobRel000006", "release"); r.Eval(); r.Advance(6); r.Eval();
            T.Ok(r.Ran == 0, "and for Death Muffin to close");
            r = new CtlRig();
            r.Start(); r.Plat.IsBattery = true; r.Offer("jobRel000007", "release"); r.Eval(); r.Advance(6); r.Eval();
            T.Ok(r.Ran == 0, "and for a laptop to be on mains");

            // a release job is not declined for being busy: it is queued for this PC alone, and a decline would end it
            r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Gate = new System.Threading.Tasks.TaskCompletionSource<int>();
            r.Start(); r.Offer("jobRel000008", "shots");
            var running = System.Threading.Tasks.Task.Run(() => r.Eval());
            var sw = Stopwatch.StartNew();
            while (r.Ran < 1 && sw.Elapsed < TimeSpan.FromSeconds(30)) Thread.Sleep(5);
            r.Offer("jobRel000009", "release");
            T.Eq(r.Api.Declines.Count, 0, "a release job offered while a job runs is not declined as busy");
            r.Offer("jobRel00000a", "shots");
            T.Eq(string.Join(",", r.Api.Declines), "jobRel00000a:busy", "(a shots job still is)");
            r.Runner.Gate.SetResult(0);
            Util.Wait(running);
        }

        // ---- The runner ----------------------------------------------------------------------------------------------------------------

        /// <summary>A PNG's first 24 bytes with the size in its header: enough for the app's size check.</summary>
        static byte[] PngOf(int w, int h, int seed = 1)
        {
            var b = Util.FakePng(seed);
            b[8] = 0; b[9] = 0; b[10] = 0; b[11] = 13;
            b[12] = (byte)'I'; b[13] = (byte)'H'; b[14] = (byte)'D'; b[15] = (byte)'R';
            b[16] = (byte)(w >> 24); b[17] = (byte)(w >> 16); b[18] = (byte)(w >> 8); b[19] = (byte)w;
            b[20] = (byte)(h >> 24); b[21] = (byte)(h >> 16); b[22] = (byte)(h >> 8); b[23] = (byte)h;
            return b;
        }

        static string ArgOf(GameLaunch l, string name)
        {
            string a = l.Args.FirstOrDefault(x => x.StartsWith(name + "="));
            return a == null ? null : a.Substring(a.IndexOf('=') + 1);
        }

        static string StepOf(GameLaunch l)
        {
            if (l.Args.Contains("--quit-while-loading")) return "quit-loading";
            if (l.Args.Contains("--boot-check")) return "install";
            if (l.Args.Any(x => x.StartsWith("--shot-plan="))) return "screens";
            if (l.Args.Contains("--stutter")) return "stutter";
            if (l.Args.Any(x => x.StartsWith("--soak="))) return "soak";
            if (l.Args.Contains("--benchmark")) return "bench";
            return "?";
        }

        public const string StutterText = "[{\"discipline\":1,\"rite\":\"bone_spear\",\"worst_ms\":18.5,\"compilations\":0}]";
        public const string SoakText = "{\"minutes\":[{\"minute\":1,\"p50\":6.9,\"p99\":9.8}],\"growth\":{\"memory_mb\":1.5}}";

        /// <summary>The game as a stand-in that does what each step's command asks: a boot line, nothing at quit, pictures of the window's size, the scenarios' JSON, a benchmark run. `over(step, launch)` may take over a step (its exit code).</summary>
        const int Hang = -999;   // what an `over` returns to make the game keep running until it is stopped

        static Func<GameLaunch, string, int?> ReleaseGame(Func<string, GameLaunch, int?> over = null)
        {
            return (l, dir) =>
            {
                string step = StepOf(l);
                int? taken = over == null ? null : over(step, l);
                if (taken.HasValue) return taken.Value == Hang ? null : taken;
                switch (step)
                {
                    case "screens":
                        {
                            string size = l.Args[l.Args.IndexOf("--resolution") + 1];
                            int w = int.Parse(size.Split('x')[0]), h = int.Parse(size.Split('x')[1]);
                            File.WriteAllBytes(Path.Combine(dir, "bag-open.png"), PngOf(w, h, 1));
                            File.WriteAllBytes(Path.Combine(dir, "hero view.png"), PngOf(w, h, 2));
                            return 0;
                        }
                    case "stutter": File.WriteAllText(Path.Combine(dir, "stutter.json"), StutterText); return 0;
                    case "soak": File.WriteAllText(Path.Combine(dir, "soak.json"), SoakText); return 0;
                    case "bench":
                        File.WriteAllText(Path.Combine(dir, "pending.json"), "[{\"clientRunId\":\"r-" + FakeGameHost.Preset(l) + "\",\"preset\":\"" + FakeGameHost.Preset(l) + "\",\"room\":\"graves\",\"size\":\"full_party\",\"length\":\"full\",\"gpu\":\"GTX 970\",\"cancelled\":false,\"metrics\":{\"avg_fps\":61.5,\"p95_ms\":18.2,\"hitches\":2}}]");
                        return 0;
                    default: return 0;
                }
            };
        }

        static void Rig_Boot(Rig rig, string output = null) { rig.Host.OutputFor = l => StepOf(l) == "install" ? (output ?? "Godot Engine\nBOOT OK 812\n") : "quiet"; }

        static byte[] Uploaded(Rig rig, string name) { return rig.Api.UploadedBytes[name]; }
        static Dictionary<string, object> JsonOf(Rig rig, string name) { return MiniJson.TryObject(Encoding.UTF8.GetString(Uploaded(rig, name))); }
        static StepReport StepIn(List<StepReport> steps, string step) { return steps.First(s => s.Step == step); }

        static void AllSteps()
        {
            using (var rig = new Rig())
            {
                var seenAtLaunch = new List<string>();
                var debugHitsAtInstall = -1;
                rig.Host.Behaviour = (l, dir) =>
                {
                    string step = StepOf(l);
                    lock (seenAtLaunch) seenAtLaunch.Add(step + ":" + string.Join(",", rig.Api.Uploaded));
                    if (step == "install") debugHitsAtInstall = rig.Srv.HitsFor("DeathMuffinDebug");
                    return ReleaseGame()(l, dir);
                };
                Rig_Boot(rig);
                rig.Runner.WindowPosition = w => "-" + (w + 100) + ",0";
                var plan = rig.ReleasePlan();
                var progress = new List<string>();
                string id = "relA00000001";
                var res = rig.Run(id, plan, progress);
                T.Ok(res.Ok, "a release job runs to done: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 10, "the game starts 10 times: install, quit-loading, 4 screens runs, stutter, 2 bench setups, soak");
                T.Eq(string.Join(",", rig.Host.Launches.Select(StepOf)), "install,quit-loading,screens,screens,screens,screens,stutter,bench,bench,soak", "in the contract's order");
                string rel = rig.Folders.GameDir(id, "release"), dbg = rig.Folders.GameDir(id, "debug");
                var L = rig.Host.Launches;
                // install and quit-loading
                T.Eq(L[0].ExePath, Path.Combine(rel, "DeathMuffin.exe"), "install: the release exe in a fresh folder of its own");
                T.Eq(string.Join("|", L[0].Args), string.Join("|", JobPlan.BootCheckArgs(false, "-1700,0")), "with -- --boot-check, windowed, silent, outside every monitor");
                T.Eq(string.Join("|", L[1].Args), string.Join("|", JobPlan.BootCheckArgs(true, "-1700,0")), "quit-loading adds --quit-while-loading");
                T.Eq(L[0].Priority, ProcessPriorityClass.BelowNormal, "install runs below normal priority");
                T.Eq(L[1].Priority, ProcessPriorityClass.BelowNormal, "and so does quit-loading");
                foreach (var f in plan.BuildNamed("release").Files) T.Ok(Hashing.Verify(Path.Combine(rel, f.Name), f.Bytes, f.Sha256), "release folder holds a verified " + f.Name);
                // screens
                T.Eq(L[2].ExePath, Path.Combine(dbg, "DeathMuffinDebug.exe"), "screens: the debug build");
                var tags = new[] { "1920x1080", "1920x1080_s1-5", "2560x1440", "2560x1440_s1-5" };
                for (int i = 0; i < 4; i++)
                {
                    var l = L[2 + i];
                    T.Eq(string.Join("|", l.Args), string.Join("|", plan.ScreensCommandArgs(plan.ScreenSizes[i / 2], i % 2 == 0 ? "" : "1.5", rig.Folders.PlanFile(id), Path.Combine(rig.Folders.OutDir(id), "screens", tags[i]), "-" + (plan.ScreenSizes[i / 2].Width + 100) + ",0")), "screens run " + (i + 1) + " is the contract's command for " + tags[i]);
                    T.Eq(l.Priority, ProcessPriorityClass.BelowNormal, "screens run " + (i + 1) + " is below normal priority");
                }
                T.Ok(File.ReadAllText(rig.Folders.PlanFile(id)) == plan.PlanJson, "plan.json holds the screens' shot plan");
                // stutter, bench, soak
                T.Eq(string.Join("|", L[6].Args), string.Join("|", plan.StutterCommandArgs(Path.Combine(rig.Folders.OutDir(id), "stutter"), "-1700,0")), "stutter's command");
                T.Eq(L[6].Priority, ProcessPriorityClass.BelowNormal, "stutter runs below normal priority");
                T.Eq(L[7].ExePath, Path.Combine(rel, "DeathMuffin.exe"), "bench: the release build");
                T.Eq(string.Join("|", L[7].Args), string.Join("|", plan.BenchCommandArgs(plan.Setups[0], rig.Folders.BenchDir(id, 1))), "with the benchmark's command for setup 1");
                T.Eq(L[7].Priority, ProcessPriorityClass.Normal, "bench runs at normal priority");
                T.Eq(L[8].Priority, ProcessPriorityClass.Normal, "every setup does");
                T.Eq(string.Join("|", L[9].Args), string.Join("|", plan.SoakCommandArgs(Path.Combine(rig.Folders.OutDir(id), "soak"), "-1700,0")), "soak's command");
                T.Eq(L[9].Priority, ProcessPriorityClass.Normal, "soak runs at normal priority");
                T.Eq(L[9].ExePath, Path.Combine(dbg, "DeathMuffinDebug.exe"), "soak uses the debug build");
                T.Eq(L.Select(x => x.AppData).Distinct().Count(), 10, "every run has its own empty APPDATA");
                T.Ok(L.All(x => x.AppData.StartsWith(rig.Folders.JobDir(id)) && x.LocalAppData.StartsWith(rig.Folders.JobDir(id))), "all inside the job's folder");
                // what was uploaded, in the order the steps finished
                T.Eq(string.Join(",", rig.Api.Uploaded),
                    "install.json,quit-loading.json,1920x1080_bag-open.png,1920x1080_hero_view.png,1920x1080_s1-5_bag-open.png,1920x1080_s1-5_hero_view.png,2560x1440_bag-open.png,2560x1440_hero_view.png,2560x1440_s1-5_bag-open.png,2560x1440_s1-5_hero_view.png,screens.json,stutter.json,bench.json,soak.json",
                    "each step's pictures and result file, as the step finishes");
                T.Ok(seenAtLaunch[1].StartsWith("quit-loading:install.json"), "install.json was up before quit-loading started");
                T.Ok(seenAtLaunch.First(x => x.StartsWith("stutter:")).Contains("screens.json"), "screens.json was up before stutter started");
                T.Ok(seenAtLaunch.First(x => x.StartsWith("soak:")).Contains("bench.json") && !seenAtLaunch.First(x => x.StartsWith("soak:")).Contains("soak.json"), "bench.json was up before the soak started, soak.json not yet");
                T.Eq(debugHitsAtInstall, 0, "the debug build is not downloaded until a step needs it");
                T.Ok(rig.Api.UploadedBytes["1920x1080_bag-open.png"].SequenceEqual(PngOf(1920, 1080, 1)), "pictures are uploaded as the game made them");
                // the results
                var install = JsonOf(rig, "install.json");
                T.Ok(MiniJson.Bool(install, "ok") && MiniJson.Int(install, "bootMs") == 812 && MiniJson.Int(install, "exitCode") == 0 && install.ContainsKey("downloadS"), "install.json: ok, the boot time, the exit code and the download time");
                T.Eq(MiniJson.Arr(install, "files").Count, 4, "and the files it installed");
                var quit = JsonOf(rig, "quit-loading.json");
                T.Ok(MiniJson.Bool(quit, "ok") && MiniJson.Int(quit, "exitCode") == 0 && !MiniJson.Bool(quit, "crashReport") && MiniJson.Arr(quit, "crashFiles").Count == 0, "quit-loading.json: ok, exit 0, no crash report");
                var screens = JsonOf(rig, "screens.json");
                T.Ok(MiniJson.Bool(screens, "ok") && MiniJson.Arr(screens, "runs").Count == 4 && MiniJson.Str(screens, "preset") == "high", "screens.json: four runs on high");
                T.Eq(string.Join(",", MiniJson.Arr(screens, "uiScales").Cast<string>()), "default,1.5", "and the UI scales taken");
                var run3 = (Dictionary<string, object>)MiniJson.Arr(screens, "runs")[3];
                T.Eq(MiniJson.Str(run3, "size") + "|" + MiniJson.Str(run3, "uiScale") + "|" + MiniJson.Arr(run3, "shots").Count + "|" + MiniJson.Bool(run3, "ok"), "2560x1440|1.5|2|True", "a run: its size, scale, pictures");
                T.Ok(Uploaded(rig, "stutter.json").SequenceEqual(Encoding.UTF8.GetBytes(StutterText)), "stutter.json is the game's JSON as it was written");
                T.Ok(Uploaded(rig, "soak.json").SequenceEqual(Encoding.UTF8.GetBytes(SoakText)), "soak.json too");
                var bench = JsonOf(rig, "bench.json");
                T.Eq(MiniJson.Arr(bench, "runs").Count, 2, "bench.json holds the runs");
                var row = (Dictionary<string, object>)MiniJson.Arr(bench, "summary")[0];
                T.Ok(MiniJson.Str(row, "preset") == "low" && (double)row["avg_fps"] == 61.5 && (double)row["p95_ms"] == 18.2 && MiniJson.Str(row, "gpu") == "GTX 970", "and a summary of the numbers that matter");
                // done
                T.Eq(rig.Api.DoneJob, id, "done names the job");
                T.Eq(rig.Api.DoneSteps.Count, 6, "done says how each of the six steps went");
                T.Eq(string.Join(",", rig.Api.DoneSteps.Select(s => s.Step)), "install,quit-loading,screens,stutter,bench,soak", "in order");
                T.Ok(rig.Api.DoneSteps.All(s => s.Ok && s.Error == "" && s.Ms >= 0), "all passed");
                T.Eq(StepIn(rig.Api.DoneSteps, "install").Ms, 812L, "install's ms is the time to the first screen the game reported");
                T.Eq(string.Join(",", rig.Api.DoneFiles), string.Join(",", rig.Api.Uploaded), "done names every file it uploaded");
                T.Eq(rig.Api.DoneRuns.Count, 2, "and the bench step's two runs");
                T.Eq(MiniJson.Str(rig.Api.DoneRuns[0], "clientRunId") + "," + MiniJson.Str(rig.Api.DoneRuns[1], "clientRunId"), "r-low,r-medium", "in setup order");
                T.Eq(rig.Api.Count("fail"), 0, "no fail call");
                int lastUpload = rig.Api.Calls.FindLastIndex(c => c.StartsWith("upload")), doneAt = rig.Api.Calls.FindIndex(c => c.StartsWith("done"));
                T.Ok(doneAt > lastUpload, "done comes after the last upload");
                T.Eq(res.Steps.Count, 6, "the result carries the steps");
                T.Eq(res.Runs, 2, "and the runs sent");
                T.Ok(rig.Api.DoneDownloadS >= 0 && rig.Api.DoneRunS >= 0, "timings are reported");
                // downloads: the art pack and the core library the builds share are fetched once; each build's exe and code pack once
                T.Eq(rig.Srv.HitsFor("/DeathMuffin.assets.pck"), 1, "the art pack both builds share is downloaded once");
                T.Eq(rig.Srv.HitsFor("/libdmcore"), 1, "so is the core library");
                T.Eq(rig.Srv.HitsFor("/DeathMuffin.exe") + rig.Srv.HitsFor("/DeathMuffinDebug.exe"), 2, "each build's exe once");
                T.Has(rig.Api.DoneLog, "shared with the release build: DeathMuffin.assets.pck", "the log says the debug build shared it");
                T.Has(rig.Api.DoneLog, "step install passed", "the log names each step");
                T.Has(rig.Api.DoneLog, "finished: 6 of 6 step(s) passed", "and the end");
                T.Ok(progress.Contains("Release checks, step 1 of 6: install") && progress.Contains("Release checks, step 6 of 6: soak") && progress.Any(p => p == "Release check: screens at 2560x1440, UI scale 1.5 (4 of 4)") && progress.Contains("Done: 6 of 6 release check step(s) passed"), "progress says which step it is on");
                T.Ok(File.ReadAllText(rig.Folders.LogFile(id)).Contains("finished: 6 of 6"), "job.log is written");
            }
        }

        static void FailingSteps()
        {
            // every step goes wrong in its own way: each is a result, the next one runs, the job is done
            using (var rig = new Rig())
            {
                rig.Runner.QuitLimit = TimeSpan.FromMilliseconds(40);
                Rig_Boot(rig, "Godot Engine\nloading\n");   // no BOOT OK line
                rig.Host.Behaviour = ReleaseGame((step, l) =>
                {
                    if (step == "quit-loading") return Hang;                                // never quits
                    if (step == "screens" && ArgOf(l, "--shots").Contains("1920x1080_s1-5")) return 3;   // one run of four fails
                    if (step == "stutter") return 1;
                    if (step == "bench") return 1;
                    return step == "soak" ? (int?)5 : null;
                });
                rig.Runner.PollMs = 2;
                var plan = rig.ReleasePlan();
                var res = rig.Run("relB00000001", plan);
                T.Ok(res.Ok, "a job whose steps failed is still done: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 9, "every step ran (the bench's first setup failed, so its second never started)");
                var steps = rig.Api.DoneSteps;
                T.Eq(string.Join(",", steps.Select(s => s.Step + ":" + s.Ok)), "install:False,quit-loading:False,screens:False,stutter:False,bench:False,soak:False", "no step passed");
                T.Eq(StepIn(steps, "install").Error, "The game quit with code 0 but never said BOOT OK.", "install says why");
                T.Has(StepIn(steps, "quit-loading").Error, "did not quit by itself within", "quit-loading says why");
                T.Has(StepIn(steps, "screens").Error, "stopped with code 3", "screens names the run that failed");
                T.Has(StepIn(steps, "screens").Error, "UI scale 1.5", "and its UI scale");
                T.Eq(StepIn(steps, "stutter").Error, "The game stopped with code 1 on the stutter test.", "stutter says why");
                T.Has(StepIn(steps, "bench").Error, "benchmark on Low", "the failed benchmark names its setup");
                T.Eq(StepIn(steps, "soak").Error, "The game stopped with code 5 on the soak test.", "soak says why");
                T.Ok(Uploaded(rig, "install.json") != null && !MiniJson.Bool(JsonOf(rig, "install.json"), "ok") && MiniJson.Str(JsonOf(rig, "install.json"), "error").Contains("BOOT OK"), "each failed step still uploads its result, with the reason");
                T.Eq(string.Join(",", rig.Api.Uploaded.Where(n => n.EndsWith(".json"))), "install.json,quit-loading.json,screens.json,stutter.json,bench.json,soak.json", "all six result files are up");
                var screens = JsonOf(rig, "screens.json");
                T.Eq(string.Join(",", MiniJson.Arr(screens, "runs").Cast<Dictionary<string, object>>().Select(x => MiniJson.Bool(x, "ok").ToString())), "True,False,True,True", "screens.json says which run went wrong");
                T.Eq(rig.Api.Uploaded.Count(n => n.EndsWith(".png")), 6, "the pictures of the three runs that worked are up");
                T.Eq(rig.Api.DoneRuns == null ? 0 : rig.Api.DoneRuns.Count, 0, "no bench runs were sent");
                T.Eq(rig.Api.Count("fail"), 0, "the job is not failed");
                T.Eq(res.Steps.Count(s => s.Ok), 0, "the result counts no step that passed");
            }
            // a step whose result is not what the game should have written: crash markers, empty scenario folders
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ReleaseGame((step, l) =>
                {
                    if (step == "stutter" || step == "soak") return 0;   // exits 0 and writes nothing
                    return null;
                });
                Rig_Boot(rig);
                var plan = rig.ReleasePlan(p => p["steps"] = new List<object> { "stutter", "soak" });
                var res = rig.Run("relB00000002", plan);
                T.Ok(res.Ok, "done: " + res.Error);
                T.Eq(StepIn(rig.Api.DoneSteps, "stutter").Error, "The game left no result file.", "a scenario that wrote nothing fails its step");
                T.Eq(StepIn(rig.Api.DoneSteps, "soak").Error, "The game left no result file.", "and so does the soak");
                T.Ok(!MiniJson.Bool(JsonOf(rig, "stutter.json"), "ok"), "with a small result file of the app's own that says so");
            }
        }

        static void BootSteps()
        {
            // install: a game that stops with a code, a game that takes too long, a game that is never started
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                rig.Host.Behaviour = ReleaseGame((step, l) => step == "install" ? (int?)3 : null);
                var res = rig.Run("relC00000001", rig.ReleasePlan(p => p["steps"] = new List<object> { "install" }));
                T.Eq(StepIn(rig.Api.DoneSteps, "install").Error, "The game stopped with code 3 before its first screen.", "install: an exit code other than 0");
                T.Has(rig.Api.DoneLog, "start install: DeathMuffin.exe", "the log has the command");
            }
            using (var rig = new Rig())
            {
                rig.Runner.BootLimit = TimeSpan.FromMilliseconds(40);
                rig.Runner.PollMs = 2;
                rig.Host.Behaviour = (l, dir) => null;
                rig.Run("relC00000002", rig.ReleasePlan(p => p["steps"] = new List<object> { "install" }));
                T.Has(StepIn(rig.Api.DoneSteps, "install").Error, "did not reach its first screen within", "install: a game that never gets to its first screen is stopped");
                T.Eq(rig.Host.Killed, 1, "and killed");
            }
            using (var rig = new Rig())
            {
                rig.Host.ThrowOnStart = true;
                rig.Run("relC00000003", rig.ReleasePlan(p => p["steps"] = new List<object> { "install", "quit-loading" }));
                T.Eq(string.Join("|", rig.Api.DoneSteps.Select(s => s.Ok + ":" + s.Error)), "False:The game could not be started for install: Access is denied|False:The game could not be started for quit-loading: Access is denied", "a game that cannot start fails each step that needs it, and the job goes on");
            }
            // the ms is the game's own; none given: the step's time
            using (var rig = new Rig())
            {
                Rig_Boot(rig, "BOOT OK 4521");
                rig.Host.Behaviour = ReleaseGame();
                rig.Run("relC00000004", rig.ReleasePlan(p => p["steps"] = new List<object> { "install" }));
                T.Eq(StepIn(rig.Api.DoneSteps, "install").Ms, 4521L, "install's ms is the boot time from BOOT OK <ms>");
            }
            // quit-loading: crash reports left in the run's APPDATA
            foreach (string marker in new[] { "session.lock", "crash_pending.json", "core_crash_note.txt" })
                using (var rig = new Rig())
                {
                    rig.Host.Behaviour = (l, dir) =>
                    {
                        string deep = Path.Combine(l.AppData, "Godot", "app_userdata", "Death Muffin");
                        Directory.CreateDirectory(deep);
                        File.WriteAllText(Path.Combine(deep, marker), "x");
                        return 0;
                    };
                    rig.Run("relC00000005", rig.ReleasePlan(p => p["steps"] = new List<object> { "quit-loading" }));
                    var step = rig.Api.DoneSteps[0];
                    T.Ok(!step.Ok && step.Error == "The game quit but left a crash report (" + marker + ").", "quit-loading: " + marker + " under the run's APPDATA is a crash report: " + step.Error);
                    var j = JsonOf(rig, "quit-loading.json");
                    T.Ok(MiniJson.Bool(j, "crashReport") && string.Join(",", MiniJson.Arr(j, "crashFiles").Cast<string>()) == marker, "and the result file lists it");
                }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => 4;
                rig.Run("relC00000006", rig.ReleasePlan(p => p["steps"] = new List<object> { "quit-loading" }));
                T.Eq(rig.Api.DoneSteps[0].Error, "The game quit with code 4 while loading.", "quit-loading: an exit code other than 0");
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => 0;
                rig.Run("relC00000007", rig.ReleasePlan(p => p["steps"] = new List<object> { "quit-loading" }));
                T.Ok(rig.Api.DoneSteps[0].Ok && rig.Api.DoneSteps[0].Ms >= 0, "quit-loading passes on exit 0 with no crash report");
            }
        }

        static void SubsetsAndDownloads()
        {
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                rig.Host.Behaviour = ReleaseGame();
                var plan = rig.ReleasePlan(p => { p["steps"] = new List<object> { "install", "bench" }; });
                var res = rig.Run("relD00000001", plan);
                T.Ok(res.Ok, "install and bench: " + res.Error);
                T.Eq(string.Join(",", rig.Host.Launches.Select(StepOf)), "install,bench,bench", "only those steps run");
                T.Eq(rig.Srv.HitsFor("DeathMuffinDebug"), 0, "the debug build is never downloaded");
                T.Ok(!Directory.GetFiles(rig.Folders.GameDir("relD00000001", "debug")).Any(), "its folder is empty");
                T.Eq(string.Join(",", rig.Api.Uploaded), "install.json,bench.json", "and only their results are up");
            }
            // a download that fails fails the steps that need that build, not the others
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                rig.Host.Behaviour = ReleaseGame();
                var plan = rig.ReleasePlan(p =>
                {
                    var debug = BuildFilesOf(p, "debug");
                    ((Dictionary<string, object>)debug[0])["sha256"] = new string('f', 64);   // the pack the server hosts does not have this checksum
                });
                rig.Srv.CorruptFirst.Clear();
                var res = rig.Run("relD00000002", plan);
                T.Ok(res.Ok, "a job whose debug build cannot be downloaded is still done: " + res.Error);
                var steps = rig.Api.DoneSteps;
                T.Eq(string.Join(",", steps.Select(s => s.Step + ":" + s.Ok)), "install:True,quit-loading:True,screens:False,stutter:False,bench:True,soak:False", "the steps that need the debug build fail, the others pass");
                T.Eq(StepIn(steps, "screens").Error, StepIn(steps, "stutter").Error, "each with the same words");
                T.Eq(StepIn(steps, "stutter").Error, StepIn(steps, "soak").Error, "(the download is tried once)");
                T.Has(StepIn(steps, "screens").Error, "DeathMuffinDebug.pck", "that name the file");
                int hits = rig.Srv.HitsFor("/DeathMuffinDebug.pck");
                using (var one = new Rig())
                {
                    one.Host.Behaviour = ReleaseGame();
                    one.Run("relD00000009", one.ReleasePlan(p => { p["steps"] = new List<object> { "screens" }; ((Dictionary<string, object>)BuildFilesOf(p, "debug")[0])["sha256"] = new string('f', 64); }));
                    T.Eq(hits, one.Srv.HitsFor("/DeathMuffinDebug.pck"), "and it was not downloaded again for the second and third step (as many tries as for one step alone)");
                }
                T.Eq(string.Join(",", rig.Host.Launches.Select(StepOf)), "install,quit-loading,bench,bench", "no debug game was started");
                T.Ok(!MiniJson.Bool(JsonOf(rig, "screens.json"), "ok") && MiniJson.Str(JsonOf(rig, "screens.json"), "error").Length > 0, "the failed step's result file says why");
            }
            // the release build's download fails: install and the others fail, the debug steps run
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ReleaseGame();
                var plan = rig.ReleasePlan(p => ((Dictionary<string, object>)BuildFilesOf(p, "release")[1])["sha256"] = new string('f', 64));
                var res = rig.Run("relD00000003", plan);
                T.Ok(res.Ok, "done: " + res.Error);
                T.Eq(string.Join(",", rig.Api.DoneSteps.Select(s => s.Step + ":" + s.Ok)), "install:False,quit-loading:False,screens:True,stutter:True,bench:False,soak:True", "install, quit-loading and bench fail; the debug steps pass");
            }
            // the cache keeps the exes and the art pack for the next release job
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                rig.Host.Behaviour = ReleaseGame();
                var steps = new List<object> { "install", "stutter" };
                T.Ok(rig.Run("relD00000004", rig.ReleasePlan(p => p["steps"] = steps)).Ok, "a first release job");
                int artHits = rig.Srv.HitsFor("/DeathMuffin.assets.pck"), exeHits = rig.Srv.HitsFor("/DeathMuffinDebug.exe");
                T.Ok(rig.Run("relD00000005", rig.ReleasePlan(p => p["steps"] = steps)).Ok, "a second one");
                T.Eq(rig.Srv.HitsFor("/DeathMuffin.assets.pck"), artHits, "the art pack is not downloaded again");
                T.Eq(rig.Srv.HitsFor("/DeathMuffinDebug.exe"), exeHits, "nor the Godot builds");
                T.Eq(Directory.GetDirectories(rig.Folders.CacheRoot).Length, 3, "three cache folders: the art pack and the two Godot builds (the limit is four)");
            }
        }

        static void ScreensDetails()
        {
            // pictures whose size is not the size asked for (Windows held the window to the screen): reported, and still uploaded
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ReleaseGame((step, l) =>
                {
                    if (step != "screens") return null;
                    string dir = ArgOf(l, "--shots");
                    File.WriteAllBytes(Path.Combine(dir, "bag.png"), PngOf(l.Args.Contains("3840x2160") ? 1936 : 1920, l.Args.Contains("3840x2160") ? 1119 : 1080));
                    return 0;
                });
                var plan = rig.ReleasePlan(p => { p["steps"] = new List<object> { "screens" }; Screens(p)["resolutions"] = new List<object> { "1920x1080", "3840x2160" }; Screens(p).Remove("uiScales"); });
                var res = rig.Run("relE00000001", plan);
                T.Ok(res.Ok, "done: " + res.Error);
                var step = rig.Api.DoneSteps[0];
                T.Ok(!step.Ok && step.Error.Contains("1936x1119, not 3840x2160"), "the step fails and says what the pictures are: " + step.Error);
                T.Eq(string.Join(",", rig.Api.Uploaded.Where(n => n.EndsWith(".png"))), "1920x1080_bag.png,3840x2160_bag.png", "both pictures are still uploaded");
                var runs = MiniJson.Arr(JsonOf(rig, "screens.json"), "runs").Cast<Dictionary<string, object>>().ToList();
                T.Ok(MiniJson.Bool(runs[0], "ok") && !MiniJson.Bool(runs[1], "ok") && MiniJson.Str(runs[1], "pictureSize") == "1936x1119", "screens.json marks the run and gives the size it got");
                T.Eq(MiniJson.Str(JsonOf(rig, "screens.json"), "note"), "default UI scale only: the job names no other UI scale", "and says that only the default UI scale was taken");
            }
            // a run that makes no pictures, and a run that is too slow
            using (var rig = new Rig())
            {
                rig.Runner.RunLimit = TimeSpan.FromMilliseconds(40);
                rig.Runner.PollMs = 2;
                int n = 0;
                rig.Host.Behaviour = (l, dir) => { n++; if (n == 1) return 0; if (n == 2) return null; File.WriteAllBytes(Path.Combine(dir, "a.png"), PngOf(1920, 1080)); return 0; };
                var plan = rig.ReleasePlan(p => { p["steps"] = new List<object> { "screens" }; Screens(p)["resolutions"] = new List<object> { "1920x1080" }; Screens(p)["uiScales"] = new List<object> { "1.5", "2" }; });
                rig.Run("relE00000002", plan);
                var step = rig.Api.DoneSteps[0];
                T.Has(step.Error, "made no pictures", "a run with no pictures is named");
                T.Has(step.Error, "and 1 more run(s) went wrong", "and the slow one is counted");
                T.Eq(rig.Host.Launches.Count, 3, "all three runs happened");
                T.Eq(rig.Api.Uploaded.Count(x => x.EndsWith(".png")), 1, "the one that worked is up");
            }
            // too many pictures: every run keeps its first few
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => { for (int i = 1; i <= 30; i++) File.WriteAllBytes(Path.Combine(dir, "s" + i.ToString("00") + ".png"), PngOf(1920, 1080, i)); return 0; };
                var plan = rig.ReleasePlan(p => { p["steps"] = new List<object> { "screens" }; Screens(p)["resolutions"] = new List<object> { "1920x1080", "1920x1081", "1920x1082", "1920x1083" }; Screens(p)["uiScales"] = new List<object> { "2" }; });
                var res = rig.Run("relE00000003", plan);
                int pictures = rig.Api.Uploaded.Count(x => x.EndsWith(".png"));
                T.Ok(res.Ok && pictures <= JobPlan.MaxReleaseUploads && pictures >= 100, "at most " + JobPlan.MaxReleaseUploads + " pictures are sent (" + pictures + "), room being left for the result files");
                T.Eq(rig.Api.Uploaded.Count(x => x.StartsWith("1920x1083_s2_")), JobPlan.MaxReleaseUploads / 8, "every run keeps the same number of its first pictures");
                T.Has(rig.Api.DoneLog, "only the first", "the log says so");
            }
        }

        static void ScenarioFiles()
        {
            // the scenario's JSON: any file the game left when it did not use the step's own name; a file that is not JSON, or too big
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ReleaseGame((step, l) =>
                {
                    if (step == "stutter") { File.WriteAllText(Path.Combine(ArgOf(l, "--stutter-out"), "results.json"), "{\"p50\":6.9}"); return 0; }
                    if (step == "soak") { File.WriteAllText(Path.Combine(ArgOf(l, "--soak-out"), "soak.json"), "this is not json {"); return 0; }
                    return null;
                });
                Rig_Boot(rig);
                rig.Run("relF00000001", rig.ReleasePlan(p => p["steps"] = new List<object> { "stutter", "soak" }));
                T.Ok(rig.Api.DoneSteps[0].Ok && Encoding.UTF8.GetString(Uploaded(rig, "stutter.json")) == "{\"p50\":6.9}", "a result under another name is uploaded as stutter.json, as written");
                T.Eq(rig.Api.DoneSteps[1].Error, "The game's result file is not JSON.", "a result that is not JSON fails its step");
                T.Ok(!MiniJson.Bool(JsonOf(rig, "soak.json"), "ok"), "and the result file uploaded is the app's own note, valid JSON");
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ReleaseGame((step, l) =>
                {
                    if (step == "stutter") { File.WriteAllText(Path.Combine(ArgOf(l, "--stutter-out"), "stutter.json"), "{\"pad\":\"" + new string('x', JobRunnerLimit()) + "\"}"); return 0; }
                    return null;
                });
                rig.Run("relF00000002", rig.ReleasePlan(p => p["steps"] = new List<object> { "stutter" }));
                T.Has(rig.Api.DoneSteps[0].Error, "too big to send", "a result over 1 MB fails its step");
                T.Ok(Uploaded(rig, "stutter.json").Length < 1000, "and a small note goes up instead");
            }
            using (var rig = new Rig())
            {
                // the game's result is valid JSON but the game failed: the step fails, the result is kept and uploaded
                rig.Host.Behaviour = ReleaseGame((step, l) =>
                {
                    if (step == "stutter") { File.WriteAllText(Path.Combine(ArgOf(l, "--stutter-out"), "stutter.json"), "[{\"discipline\":1}]"); return 1; }
                    return null;
                });
                rig.Run("relF00000003", rig.ReleasePlan(p => p["steps"] = new List<object> { "stutter" }));
                T.Ok(!rig.Api.DoneSteps[0].Ok && rig.Api.DoneSteps[0].Error == "The game stopped with code 1 on the stutter test.", "a game that failed fails its step");
                T.Eq(Encoding.UTF8.GetString(Uploaded(rig, "stutter.json")), "[{\"discipline\":1}]", "and its partial result is uploaded as it is");
            }
        }

        static int JobRunnerLimit() { return JobRunner.MaxStepResultBytes + 10; }

        static void SoakAndBench()
        {
            // the soak: the PC is read for a quiet minute first; a key or mouse during it, other programs using the CPU, are noted, never throw it out
            using (var rig = new Rig())
            {
                int readsAtStart = 0;
                rig.Host.RunPolls = 60;
                rig.Host.Behaviour = ReleaseGame((step, l) =>
                {
                    if (step != "soak") return null;
                    readsAtStart = rig.Probe.Reads;
                    return null;
                });
                int gameReads = 0;
                rig.Probe.Script = (nRead, clock, pid) =>
                {
                    bool game = pid > 0;
                    if (game) gameReads++;
                    if (game && gameReads == 5) rig.Probe.LastInput = clock;   // someone moves the mouse
                    return new PcSample { CpuTotal = 3 + (game ? 40 : 0) + (game && gameReads > 25 ? 40 : 0), CpuGame = game ? 40 : 0 };   // and from the 25th reading on, other programs use the CPU
                };
                var plan = rig.ReleasePlan(p => p["steps"] = new List<object> { "soak" });
                var res = rig.Run("relG00000001", plan);
                T.Ok(res.Ok, "done: " + res.Error);
                T.Ok(readsAtStart >= 60, "the PC was read for a quiet minute before the soak (" + readsAtStart + " readings)");
                T.Eq(rig.Host.Launches.Count, 1, "a touched PC does not restart the soak (a benchmark would)");
                T.Ok(rig.Api.DoneSteps[0].Ok, "the step passes");
                T.Eq(rig.Host.Launches[0].Priority, ProcessPriorityClass.Normal, "at normal priority");
                T.Ok(Uploaded(rig, "soak.json").SequenceEqual(Encoding.UTF8.GetBytes(SoakText)), "soak.json is still the game's");
                T.Eq(string.Join(",", rig.Api.Uploaded), "soak-notes.json,soak.json", "and the notes are a file of their own, uploaded first");
                var notes = MiniJson.Arr(JsonOf(rig, "soak-notes.json"), "notes").Cast<string>().ToList();
                T.Ok(notes.Any(x => x.Contains("the keyboard or mouse was used")), "the notes say the mouse was used: " + string.Join(" | ", notes));
                T.Ok(notes.Any(x => x.Contains("other programs were using the CPU")), "and that other programs used the CPU");
                T.Eq(MiniJson.Int(JsonOf(rig, "soak-notes.json"), "minutes"), 2L, "and how long the soak was");
                T.Has(rig.Api.DoneLog, "soak: minute", "the log has them too");
            }
            // a quiet soak leaves no notes file
            using (var rig = new Rig())
            {
                rig.Host.RunPolls = 30;
                rig.Host.Behaviour = ReleaseGame();
                rig.Run("relG00000002", rig.ReleasePlan(p => p["steps"] = new List<object> { "soak" }));
                T.Eq(string.Join(",", rig.Api.Uploaded), "soak.json", "a soak that was left alone has no notes file");
            }
            // the PC never goes quiet: the bench and soak steps fail, the others run
            using (var rig = new Rig())
            {
                rig.Runner.ReleaseQuietLimit = TimeSpan.FromMilliseconds(150);
                rig.Runner.SampleMs = 5;
                rig.Probe.Script = (n, t, pid) => new PcSample { CpuTotal = 90, CpuGame = 0 };
                Rig_Boot(rig);
                rig.Host.Behaviour = ReleaseGame();
                var res = rig.Run("relG00000003", rig.ReleasePlan(p => p["steps"] = new List<object> { "install", "bench", "stutter", "soak" }));
                T.Ok(res.Ok, "done: " + res.Error);
                T.Eq(string.Join(",", rig.Api.DoneSteps.Select(s => s.Step + ":" + s.Ok)), "install:True,stutter:True,bench:False,soak:False", "the bench and the soak give up waiting for a quiet PC; the other steps run");
                T.Has(StepIn(rig.Api.DoneSteps, "bench").Error, "never went quiet for long enough", "and say so");
                T.Has(StepIn(rig.Api.DoneSteps, "soak").Error, "never went quiet for long enough", "(both)");
                T.Eq(rig.Host.Launches.Count, 2, "no game was started for either");
            }
            // the bench step keeps the benchmark's rules: a disturbed run (the player starts Death Muffin) is thrown out and it is tried again
            using (var rig = new Rig())
            {
                int gameReads = 0;
                rig.Probe.Script = (n, t, pid) =>
                {
                    bool player = pid > 0 && rig.Host.Launches.Count == 1 && ++gameReads >= 3;   // the player starts the game during the first run (and it stays open)
                    return new PcSample { CpuTotal = 3 + (pid > 0 ? 40 : 0), CpuGame = pid > 0 ? 40 : 0, PlayerGame = player };
                };
                rig.Host.Behaviour = ReleaseGame((step, l) =>
                {
                    if (step == "bench") rig.Host.RunPolls = rig.Host.Launches.Count == 1 ? 100000 : 0;   // the first run lasts until it is disturbed
                    return null;
                });
                var res = rig.Run("relG00000004", rig.ReleasePlan(p => { p["steps"] = new List<object> { "bench" }; p["setups"] = new List<object> { BenchTests.Setup("low") }; }));
                T.Ok(res.Ok && rig.Api.DoneSteps[0].Ok, "the bench step passes after a retry: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 2, "the disturbed run was thrown away and the setup run again");
                T.Eq(rig.Api.DoneRuns.Count, 1, "one run is sent");
                T.Has(rig.Api.DoneLog, "was disturbed", "the log says the run was disturbed");
            }
            // benchmarks switched off in the tray (Helix 2026-10-19): the bench step is skipped, not failed, and nothing is started for it; the other steps run
            using (var rig = new Rig())
            {
                rig.Runner.BenchmarksAllowed = () => false;
                rig.Host.Behaviour = ReleaseGame();
                var res = rig.Run("relG00000006", rig.ReleasePlan(p => { p["steps"] = new List<object> { "bench", "stutter" }; p["setups"] = new List<object> { BenchTests.Setup("low") }; }));
                T.Ok(res.Ok, "done: " + res.Error);
                var bench = StepIn(rig.Api.DoneSteps, "bench");
                T.Ok(bench.Ok && bench.Skipped && bench.Error == JobRunner.BenchSkipped, "the bench step is reported skipped, with why");
                T.Eq(MiniJson.Write(bench.ToJson()), "{\"step\":\"bench\",\"ok\":true,\"skipped\":true,\"error\":\"" + JobRunner.BenchSkipped + "\",\"ms\":0}", "and sent as skipped");
                T.Ok(StepIn(rig.Api.DoneSteps, "stutter").Ok && rig.Host.Launches.Count == 1, "only the stutter step started the game");
                T.Ok(!rig.Api.Uploaded.Contains("bench.json") && (rig.Api.DoneRuns == null || rig.Api.DoneRuns.Count == 0), "no bench result and no runs");
                T.Has(rig.Api.DoneLog, "step bench skipped", "the log says so");
            }
            // a setup that is disturbed every time fails the bench step only
            using (var rig = new Rig())
            {
                int gameReads = 0;
                rig.Probe.Script = (n, t, pid) =>
                {
                    bool player = pid > 0 && ++gameReads >= 3;   // every run is disturbed (the game stays open)
                    return new PcSample { CpuTotal = 3 + (pid > 0 ? 40 : 0), CpuGame = pid > 0 ? 40 : 0, PlayerGame = player };
                };
                rig.Host.Behaviour = ReleaseGame((step, l) => { rig.Host.RunPolls = step == "bench" ? 100000 : 0; return null; });
                var res = rig.Run("relG00000005", rig.ReleasePlan(p => { p["steps"] = new List<object> { "bench", "stutter" }; p["setups"] = new List<object> { BenchTests.Setup("low") }; }));
                T.Ok(res.Ok, "done: " + res.Error);
                T.Has(StepIn(rig.Api.DoneSteps, "bench").Error, "was disturbed 3 times", "three disturbed runs fail the bench step");
                T.Ok(StepIn(rig.Api.DoneSteps, "stutter").Ok, "and the next step runs");
                T.Eq(rig.Api.DoneRuns == null ? 0 : rig.Api.DoneRuns.Count, 0, "no runs are sent");
            }
        }

        static void JobProblems()
        {
            // the player starts Death Muffin: the whole job stops, with the steps that were finished
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                rig.Host.Behaviour = ReleaseGame((step, l) => { if (step == "screens") { rig.Watch.Started = true; return null; } return null; });
                var res = rig.Run("relH00000001", rig.ReleasePlan());
                T.Ok(!res.Ok && res.Error == "stopped: the game started", "the player's game stops a release job: " + res.Error);
                T.Eq(rig.Api.Count("fail"), 1, "and the server is told");
                T.Eq(rig.Api.FailError, "stopped: the game started", "in those words");
                T.Eq(string.Join(",", rig.Api.FailSteps.Select(s => s.Step + ":" + s.Ok)), "install:True,quit-loading:True", "with the steps that finished before it");
                T.Eq(string.Join(",", rig.Api.Uploaded), "install.json,quit-loading.json", "whose results are already up");
                T.Eq(rig.Api.Count("done"), 0, "no done");
                T.Eq(rig.Host.Launches.Count, 3, "no further step ran");
            }
            // the server will not take a result: the job fails, with the steps so far
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                rig.Host.Behaviour = ReleaseGame();
                rig.Api.Upload = name => name == "quit-loading.json" ? FakeApi.Err(400, "bad_request", "That file is not valid JSON.") : FakeApi.Ok(new Dictionary<string, object>());
                var res = rig.Run("relH00000002", rig.ReleasePlan());
                T.Eq(res.Error, "The server did not take the result quit-loading.json: That file is not valid JSON.", "a refused result fails the job with the server's words");
                T.Eq(string.Join(",", rig.Api.FailSteps.Select(s => s.Step)), "install", "the steps reported are the ones that were finished and uploaded");
                T.Eq(rig.Host.Launches.Count, 2, "nothing runs after it");
            }
            // the game crashes while closing after a finished benchmark (Helix's PC, 2026-10-19: 0xC0000374): the numbers are sent, the step fails naming the crash and what Windows recorded
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                var plain = ReleaseGame();
                rig.Host.Behaviour = (l, dir) => { int? code = plain(l, dir); return StepOf(l) == "bench" ? -1073740940 : code; };
                rig.Runner.CrashRecord = pid => "Windows: faulting module ntdll.dll, offset 0x00000000000ff1c9";
                var res = rig.Run("relH00000010", rig.ReleasePlan(p => { p["steps"] = new List<object> { "bench", "stutter" }; p["setups"] = new List<object> { BenchTests.Setup("low") }; }));
                T.Ok(res.Ok, "the job ends: " + res.Error);
                var bench = StepIn(rig.Api.DoneSteps, "bench");
                T.Ok(!bench.Ok && bench.Error.Contains("crashed while closing") && bench.Error.Contains("0xC0000374, heap corruption") && bench.Error.Contains("ntdll.dll"), "the bench step fails, naming the crash: " + bench.Error);
                T.Eq(rig.Api.DoneRuns == null ? 0 : rig.Api.DoneRuns.Count, 1, "and its numbers are sent");
                T.Eq(rig.Host.Launches.Count(l => StepOf(l) == "bench"), 1, "a crash while closing is no reason to run it again");
                T.Ok(StepIn(rig.Api.DoneSteps, "stutter").Ok, "the next step runs");
                T.Has(Encoding.UTF8.GetString(Uploaded(rig, "bench.json")), "\"crashes\"", "bench.json lists the crash");
            }
            // the screen was off (asleep) during the benchmark: the run counts, and the summary and the log say for how long (Helix, 2026-10-19)
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                rig.Host.Behaviour = ReleaseGame((step, l) => { rig.Host.RunPolls = step == "bench" ? 12 : 0; return null; });
                rig.Probe.Script = (n, t, pid) => new PcSample { CpuTotal = 3 + (pid > 0 ? 40 : 0), CpuGame = pid > 0 ? 40 : 0, DisplayOff = pid > 0 };
                var res = rig.Run("relH00000012", rig.ReleasePlan(p => { p["steps"] = new List<object> { "bench" }; p["setups"] = new List<object> { BenchTests.Setup("low") }; }));
                T.Ok(res.Ok && StepIn(rig.Api.DoneSteps, "bench").Ok, "a run with the screen off still counts: " + res.Error);
                string bench = Encoding.UTF8.GetString(Uploaded(rig, "bench.json"));
                T.Has(bench, "\"screenOffS\"", "the summary says how long the screen was off: " + bench);
                T.Has(rig.Api.DoneLog, "the screen was off for", "and so does the log");
            }
            // ... and a crash before the numbers were saved fails the step with no numbers
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                rig.Host.Behaviour = ReleaseGame((step, l) => step == "bench" ? -1073741819 : (int?)null);
                var res = rig.Run("relH00000011", rig.ReleasePlan(p => { p["steps"] = new List<object> { "bench" }; p["setups"] = new List<object> { BenchTests.Setup("low") }; }));
                T.Eq(StepIn(rig.Api.DoneSteps, "bench").Error, "The game crashed on Low (0xC0000005, access violation) before the benchmark was done.", "a crash during the run says so in plain words");
                T.Eq(rig.Api.DoneRuns == null ? 0 : rig.Api.DoneRuns.Count, 0, "no numbers");
            }
            // the server will not take a picture: its step fails and the job goes on (Helix's 3840x2160 fight picture was over the limit, 2026-10-19)
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                rig.Host.Behaviour = ReleaseGame();
                string refused = null;
                rig.Api.Upload = name =>
                {
                    if (name.EndsWith(".png") && (refused == null || refused == name)) { refused = name; return FakeApi.Err(413, "too_big", "That picture is too big."); }
                    return FakeApi.Ok(new Dictionary<string, object>());
                };
                var res = rig.Run("relH00000009", rig.ReleasePlan());
                T.Ok(res.Ok, "the job ends: " + res.Error);
                T.Ok(refused != null && !StepIn(rig.Api.DoneSteps, "screens").Ok && StepIn(rig.Api.DoneSteps, "screens").Error.Contains("did not take the picture " + refused), "the screens step failed, saying which picture: " + StepIn(rig.Api.DoneSteps, "screens").Error);
                T.Ok(StepIn(rig.Api.DoneSteps, "stutter").Ok && rig.Api.DoneSteps.Any(s => s.Step == "soak"), "and the steps after it still ran");
                T.Ok(!rig.Api.DoneFiles.Contains(refused) && rig.Api.DoneFiles.Contains("screens.json"), "done lists the pictures that were sent, and the step's result");
            }
            // done is refused: the job is failed with the server's reason and the steps
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                rig.Host.Behaviour = ReleaseGame();
                rig.Api.Done = () => FakeApi.Err(400, "bad_request", "The step soak is listed twice.");
                var res = rig.Run("relH00000003", rig.ReleasePlan(p => p["steps"] = new List<object> { "install" }));
                T.Ok(!res.Ok && res.Error == "The checks ran, but the server did not accept the finished job: The step soak is listed twice.", "a refused done says why: " + res.Error);
                T.Eq(rig.Api.Count("fail"), 1, "and the job is failed with the server's reason, so it never stays running");
                T.Eq(rig.Api.FailError, "The step soak is listed twice.", "the reason is the server's own");
                T.Eq(rig.Api.FailSteps.Count, 1, "with the steps");
            }
            // the server cancels the job while a step runs
            using (var rig = new Rig())
            {
                var cts = new CancellationTokenSource();
                rig.Host.Behaviour = (l, dir) => { cts.Cancel(); return null; };
                var res = rig.Run("relH00000004", rig.ReleasePlan(), cancelled: cts.Token);
                T.Ok(res.Cancelled && rig.Api.Count("fail") == 0 && rig.Api.Count("done") == 0 && rig.Host.Killed == 1, "a cancel stops the game and tells the server nothing");
            }
            // the app closes: the server is told, with the steps
            using (var rig = new Rig())
            {
                Rig_Boot(rig);
                var cts = new CancellationTokenSource();
                rig.Host.Behaviour = ReleaseGame((step, l) => { if (step == "quit-loading") { cts.Cancel(); return Hang; } return null; });
                var res = rig.Run("relH00000005", rig.ReleasePlan(), ct: cts.Token);
                T.Eq(res.Error, "stopped: the team app was closed", "closing the app stops a release job");
                T.Eq(string.Join(",", rig.Api.FailSteps.Select(s => s.Step)), "install", "and tells the server what it had finished");
            }
            // a payload the app refuses at the controller never reaches the runner (covered in ControllerTests); here a plan with no step is not a plan
            JobPlan plan; string error;
            var bad = ValidPayload(); bad["steps"] = new List<object>();
            T.Ok(!Parse(bad, out plan, out error), "no steps, no job");
        }
    }
}
