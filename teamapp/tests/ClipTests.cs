using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace DeathMuffinTeam.Tests
{
    /// <summary>
    /// The `clip` job (short videos of a change: one game run for each variant, the clips uploaded as motion-JPEG files) and the `shots` job with two builds (before and after): their payloads,
    /// command lines, upload names and the runner's work. The long-poll heartbeat is in PollTests.
    /// </summary>
    static class ClipTests
    {
        static readonly Uri Site = new Uri("https://muffindevelopment.com/death-muffin/");

        public static void Run()
        {
            ClipPlanTests();
            ClipRefusalTests();
            ClipCommandTests();
            ClipNameTests();
            BuildsPlanTests();
            BuildsRefusalTests();
            ResolutionPlanTests();
            ApiTests();
            FolderTests();
            ControllerRuns();
            EncoderTests();
        }

        /// <summary>The encoder's command line, and the real ffmpeg (Linux has one on PATH here) on a 1080p 60 fps motion JPEG it makes itself: a valid mp4 under the limit, and plain words when it cannot.</summary>
        static void EncoderTests()
        {
            T.Eq(string.Join(" ", FfmpegEncoder.Args("C:/j/out/slow/wraith.mjpeg", 60, "C:/j/out/slow/wraith.mp4.part", 20, 6000)),
                "-nostdin -hide_banner -loglevel error -y -f mjpeg -framerate 60 -i C:/j/out/slow/wraith.mjpeg -t 10 -c:v libx264 -preset medium -crf 20 -maxrate 6000k -bufsize 12000k -r 60 -pix_fmt yuv420p -movflags +faststart -an -f mp4 C:/j/out/slow/wraith.mp4.part",
                "ffmpeg's arguments: motion JPEG in at the clip's rate, H.264 at most 10 s, capped bit rate, yuv420p, playable while it loads, no sound");
            T.Ok(FfmpegEncoder.Steps.Length == 3 && FfmpegEncoder.Steps[0][0] == 20 && FfmpegEncoder.Steps[0][1] * 10 / 8 * 1000 < JobPlan.MaxMp4Bytes, "the first step's cap keeps 10 seconds under the server's limit");
            T.Eq(JobPlan.Encoder.Url.ToString(), "https://muffindevelopment.com/death-muffin/team-files/tools/ffmpeg-9.0.2/ffmpeg.exe", "the encoder comes from the game's own team-files");
            T.Ok(JobPlan.Encoder.Sha256.Length == 64 && JobPlan.Encoder.CacheKey == "ffmpeg-" + JobPlan.Encoder.Sha256.Substring(0, 16) && JobPlan.Encoder.Bytes > 0, "checked by its sha256, kept under its own cache key");
            string ffmpeg = "/usr/bin/ffmpeg";
            if (!OperatingSystem.IsLinux() || !File.Exists(ffmpeg)) { Console.WriteLine("(skipped the real encoder test: no /usr/bin/ffmpeg)"); return; }
            string dir = Util.TempDir("enc");
            try
            {
                string mjpeg = Path.Combine(dir, "wraith.mjpeg"), mp4 = Path.Combine(dir, "wraith.mp4");
                var make = Process.Start(new ProcessStartInfo(ffmpeg, "-nostdin -loglevel error -f lavfi -i testsrc2=size=1920x1080:rate=60 -t 2 -q:v 3 -f mjpeg \"" + mjpeg + "\"") { UseShellExecute = false });
                make.WaitForExit(60000);
                T.Ok(File.Exists(mjpeg) && new FileInfo(mjpeg).Length > 100000, "a 2 s 1080p 60 fps motion JPEG to encode (" + (File.Exists(mjpeg) ? new FileInfo(mjpeg).Length : 0) + " bytes)");
                var r = Util.Wait(new FfmpegEncoder().EncodeAsync(ffmpeg, mjpeg, 60, mp4, CancellationToken.None));
                T.Ok(r.Ok && r.Crf == 20 && r.Bytes > 1000 && r.Bytes <= JobPlan.MaxMp4Bytes && new FileInfo(mp4).Length == r.Bytes && !File.Exists(mp4 + ".part"), "the real ffmpeg makes the mp4 at the first step: " + r.Bytes + " bytes " + r.Error);
                byte[] head = File.ReadAllBytes(mp4).Take(12).ToArray();
                T.Eq(Encoding.ASCII.GetString(head, 4, 4), "ftyp", "it is an mp4 (ftyp first)");
                var probe = Process.Start(new ProcessStartInfo("/usr/bin/ffprobe", "-v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,codec_name -of csv=p=0 \"" + mp4 + "\"") { UseShellExecute = false, RedirectStandardOutput = true });
                string said = probe.StandardOutput.ReadToEnd().Trim();
                probe.WaitForExit(30000);
                T.Eq(said, "h264,1920,1080,60/1", "H.264, 1920x1080, 60 frames a second");
                File.WriteAllBytes(Path.Combine(dir, "junk.mjpeg"), Util.Blob(5000, 9));
                var bad = Util.Wait(new FfmpegEncoder().EncodeAsync(ffmpeg, Path.Combine(dir, "junk.mjpeg"), 60, Path.Combine(dir, "junk.mp4"), CancellationToken.None));
                T.Ok(!bad.Ok && bad.Error.StartsWith("ffmpeg ended with code") && !File.Exists(Path.Combine(dir, "junk.mp4")) && !File.Exists(Path.Combine(dir, "junk.mp4.part")), "a file that is no video: plain words, nothing left behind (" + bad.Error + ")");
                var none = Util.Wait(new FfmpegEncoder().EncodeAsync(Path.Combine(dir, "no-ffmpeg"), mjpeg, 60, Path.Combine(dir, "x.mp4"), CancellationToken.None));
                T.Ok(!none.Ok && none.Error.StartsWith("ffmpeg could not be started"), "no encoder: plain words (" + none.Error + ")");
            }
            finally { Util.Rm(dir); }
        }

        // ---- The payload ---------------------------------------------------------------------------------------------------------------

        public static Dictionary<string, object> Clip(string name, object seconds = null)
        {
            var c = new Dictionary<string, object> { { "name", name }, { "area", "graves" }, { "cast", "haunting_wraith" }, { "at", "pack" }, { "enemies", 6.0 }, { "camera", "follow" } };
            if (seconds != null) c["seconds"] = seconds;
            else c["seconds"] = 5.0;
            return c;
        }

        public static Dictionary<string, object> Tune(double speed)
        {
            return new Dictionary<string, object> { { "combat/abilities", new Dictionary<string, object> { { "haunting_wraith", new Dictionary<string, object> { { "speed", speed } } } } } };
        }

        public static Dictionary<string, object> Variant(string label, object tune)
        {
            var v = new Dictionary<string, object> { { "title", "title for " + label } };
            if (label != null) v["label"] = label;
            if (tune != null) v["tune"] = tune;
            return v;
        }

        /// <summary>The runner's clip payload (server/death-muffin/discord-agent): the same files as a screenshots job, the clip plan, two variants with a tune each and the one preset.</summary>
        public static Dictionary<string, object> ValidPayload()
        {
            return new Dictionary<string, object>
            {
                { "rev", "0123456789ab" }, { "godotVersion", "4.7.2.stable" },
                { "files", Program.ValidPayload()["files"] },
                { "plan", new Dictionary<string, object> { { "discipline", "reaper" }, { "clips", new List<object> { Clip("wraith"), Clip("pack") } } } },
                { "variants", new List<object> { Variant("slow", Tune(4)), Variant("fast", Tune(9)) } },
                { "presets", new List<object> { "high" } },
                { "args", new List<object> { "--dev-offline", "--qa" } },
            };
        }

        static List<object> Variants(Dictionary<string, object> p) { return (List<object>)p["variants"]; }
        static List<object> Clips(Dictionary<string, object> p) { return (List<object>)((Dictionary<string, object>)p["plan"])["clips"]; }
        static List<object> Files(Dictionary<string, object> p) { return (List<object>)p["files"]; }

        static void ClipPlanTests()
        {
            JobPlan plan; string error;
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, ValidPayload(), Site, out plan, out error), "a clip payload is accepted: " + error);
            T.Eq(plan.Kind, "clip", "the plan knows its kind");
            T.Ok(JobPlan.RunsKind("clip") && JobPlan.RunsKind("shots") && JobPlan.RunsKind("bench") && !JobPlan.RunsKind("clips"), "this version runs shots, clip and bench jobs");
            T.Eq(plan.Files.Count, 4, "the clip job's files are a screenshots job's");
            T.Eq(string.Join(",", plan.ClipNames), "wraith,pack", "the planned clips, in order");
            T.Eq(plan.Variants.Count, 2, "two variants");
            T.Eq(plan.Variants[0].Label + "|" + plan.Variants[1].Label, "slow|fast", "variants keep their order");
            T.Ok(plan.Variants[0].HasTune && plan.Variants[1].HasTune, "both have a tune");
            var tune = MiniJson.TryObject(plan.Variants[0].TuneJson);
            T.Eq(MiniJson.Int(MiniJson.Obj(MiniJson.Obj(tune, "combat/abilities"), "haunting_wraith"), "speed"), 4L, "the tune is kept as sent");
            T.Eq(string.Join(",", plan.Presets), "high", "one preset");
            T.Eq(string.Join(" ", plan.Args), "--dev-offline --qa", "game options as sent");
            T.Eq(plan.Builds.Count, 0, "a clip job has one build");
            var round = MiniJson.TryObject(plan.PlanJson);
            T.Eq(MiniJson.Str(round, "discipline"), "reaper", "plan.json holds the clip plan");
            T.Eq(MiniJson.Arr(round, "clips").Count, 2, "with its clips");
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, MiniJson.Write(ValidPayload()), Site, out plan, out error) && plan.Variants.Count == 2, "a clip payload given as JSON text is accepted");

            // dev-offline is added once, and never duplicated (a clip run is a QA run like a screenshots run)
            var p = ValidPayload(); p["args"] = new List<object> { "--class=3", "--class=3" };
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error) && string.Join(" ", plan.Args) == "--dev-offline --class=3", "dev-offline is added once");

            // no variants: one run labelled `clip`, no tune
            p = ValidPayload(); p.Remove("variants");
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error) && plan.Variants.Count == 1 && plan.Variants[0].Label == "clip" && !plan.Variants[0].HasTune, "no variants is one run labelled clip with no tune: " + error);
            p = ValidPayload(); p["variants"] = new List<object>();
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error) && plan.Variants.Count == 1 && plan.Variants[0].Label == "clip", "an empty list of variants is the same");
            p = ValidPayload(); p["variants"] = null;
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error) && plan.Variants.Count == 1, "null variants too");
            // a variant with no label is labelled clip, with no tune it has no --tune
            p = ValidPayload(); p["variants"] = new List<object> { Variant(null, null) };
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error) && plan.Variants[0].Label == "clip" && !plan.Variants[0].HasTune, "a variant with no label and no tune");
            p = ValidPayload(); p["variants"] = new List<object> { Variant("", Tune(1)) };
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error) && plan.Variants[0].Label == "clip" && plan.Variants[0].HasTune, "an empty label is clip");
            p = ValidPayload(); p["variants"] = new List<object> { Variant("plain", new Dictionary<string, object>()) };
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error) && plan.Variants[0].HasTune && plan.Variants[0].TuneJson == "{}", "an empty tune object is a tune");
            // up to four variants, four clips; labels of every allowed shape
            p = ValidPayload(); p["variants"] = new List<object> { Variant("a", null), Variant("b-2", null), Variant("3", null), Variant(new string('x', 24), null) };
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error) && plan.Variants.Count == 4, "four variants, labels of 1 to 24 characters with digits and dashes");
            p = ValidPayload(); ((Dictionary<string, object>)p["plan"])["clips"] = new List<object> { Clip("a"), Clip("b"), Clip("c"), Clip("d_e-9", 8.0) };
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error) && plan.ClipNames.Count == 4, "four clips of up to 8 seconds");
            p = ValidPayload(); ((Dictionary<string, object>)p["plan"])["clips"] = new List<object> { new Dictionary<string, object> { { "name", "bare" } } };
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error), "a clip that gives no length is the game's to default");
            // the preset: none is high
            p = ValidPayload(); p.Remove("presets");
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error) && string.Join(",", plan.Presets) == "high", "no preset is high");
            p = ValidPayload(); p["presets"] = new List<object> { "low" };
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error) && string.Join(",", plan.Presets) == "low", "another preset is kept");
            // a screenshots payload is not a clip payload, and the other way round
            T.Ok(!JobPlan.TryParse(JobPlan.ClipKind, Program.ValidPayload(), Site, out plan, out error) && error.Contains("clip plan"), "a screenshots payload has no clip plan");
            T.Ok(!JobPlan.TryParse(JobPlan.ShotsKind, ValidPayload(), Site, out plan, out error) && error.Contains("shot plan"), "a clip payload has no shot plan");
        }

        static string RejectClip(Action<Dictionary<string, object>> mutate, string name, string wantInError = null)
        {
            var p = ValidPayload();
            mutate(p);
            JobPlan plan; string err;
            bool ok = JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out err);
            T.Ok(!ok && plan == null && !string.IsNullOrEmpty(err), "clip payload refused: " + name + (ok ? " (it was accepted)" : ""));
            if (wantInError != null) T.Has(err, wantInError, "clip payload refusal says why: " + name);
            if (err != null) T.Ok(!err.Contains("Exception") && !err.Contains(" at "), "clip payload refusal is plain English: " + name);
            return err;
        }

        static void ClipRefusalTests()
        {
            // the plan
            RejectClip(p => p.Remove("plan"), "no plan", "no clip plan");
            RejectClip(p => p["plan"] = "plan", "plan as text");
            RejectClip(p => p["plan"] = new Dictionary<string, object> { { "discipline", "reaper" } }, "plan with no clips", "no clip plan");
            RejectClip(p => p["plan"] = new Dictionary<string, object> { { "clips", new List<object>() } }, "an empty clip list", "no clip plan");
            RejectClip(p => ((Dictionary<string, object>)p["plan"])["clips"] = new List<object> { Clip("a"), Clip("b"), Clip("c"), Clip("d"), Clip("e") }, "five clips", "too many clips");
            RejectClip(p => Clips(p).Add("wraith"), "a clip that is text");
            foreach (string bad in new[] { "Wraith", "a b", "../x", "", "-wraith", "_wraith", "a/b", "a\\b", "wraith.mjpeg", new string('c', 33), "caf\u00e9", "a;b" })
                RejectClip(p => ((Dictionary<string, object>)p["plan"])["clips"] = new List<object> { Clip(bad) }, "clip name '" + bad + "'", "not allowed");
            RejectClip(p => Clips(p).Add(Clip("wraith")), "the same clip twice", "twice");
            RejectClip(p => ((Dictionary<string, object>)p["plan"])["clips"] = new List<object> { Clip("a", 9.0) }, "a clip of 9 seconds", "longer than 8 seconds");
            RejectClip(p => ((Dictionary<string, object>)p["plan"])["clips"] = new List<object> { Clip("a", 0.0) }, "a clip of 0 seconds");
            RejectClip(p => ((Dictionary<string, object>)p["plan"])["clips"] = new List<object> { Clip("a", -2.0) }, "a negative length");
            RejectClip(p => ((Dictionary<string, object>)p["plan"])["clips"] = new List<object> { Clip("a", "5") }, "a length as text");
            RejectClip(p => ((Dictionary<string, object>)p["plan"])["pad"] = new string('x', 70000), "a plan over 64 KB", "too big");
            // the variants
            RejectClip(p => p["variants"] = "slow", "variants as text", "not a list");
            RejectClip(p => p["variants"] = new List<object> { Variant("a", null), Variant("b", null), Variant("c", null), Variant("d", null), Variant("e", null) }, "five variants", "too many variants");
            foreach (string bad in new[] { "Slow", "-slow", "a_b", "a b", "../x", new string('x', 25), "slow.fast", "caf\u00e9" })
                RejectClip(p => p["variants"] = new List<object> { Variant(bad, null) }, "variant label '" + bad + "'", "not allowed");
            RejectClip(p => p["variants"] = new List<object> { Variant("slow", null), Variant("slow", null) }, "the same label twice", "twice");
            RejectClip(p => p["variants"] = new List<object> { Variant(null, null), Variant("", null) }, "two variants with no label are both clip", "twice");
            RejectClip(p => p["variants"] = new List<object> { "slow" }, "a variant that is text", "not valid");
            RejectClip(p => p["variants"] = new List<object> { Variant("a", "tune") }, "a tune that is text", "not an object");
            RejectClip(p => p["variants"] = new List<object> { Variant("a", new List<object> { 1.0 }) }, "a tune that is a list", "not an object");
            RejectClip(p => p["variants"] = new List<object> { Variant("a", new Dictionary<string, object> { { "pad", new string('x', 33000) } }) }, "a tune over 32 KB", "too big");
            // the preset
            RejectClip(p => p["presets"] = new List<object> { "low", "high" }, "two presets", "one graphics preset");
            RejectClip(p => p["presets"] = new List<object> { "potato" }, "an unknown preset", "does not exist");
            RejectClip(p => p["presets"] = new List<object> { 1.0 }, "a preset as a number");
            RejectClip(p => p["presets"] = "high", "presets as text", "no graphics presets");
            // files, builds, options
            RejectClip(p => p.Remove("files"), "no files", "no files");
            RejectClip(p => Files(p).RemoveAll(f => (string)((Dictionary<string, object>)f)["name"] == "DeathMuffinDebug.exe"), "no game exe", "DeathMuffinDebug.exe");
            RejectClip(p => Files(p).RemoveAll(f => (string)((Dictionary<string, object>)f)["name"] == "DeathMuffinDebug.pck"), "no main pack", "DeathMuffinDebug.pck");
            RejectClip(p => Files(p).Add(Program.File_("../evil.dll")), "an unsafe file name", "not allowed");
            RejectClip(p => Files(p).Add(Program.File_("a.dll", url: "https://evil.example/death-muffin/team-files/x/a.dll")), "another host", "not on the game's server");
            RejectClip(p => p["builds"] = new List<object>(), "builds", "screenshots job");
            foreach (string reserved in new[] { "--clip-plan=x.json", "--clips=x", "--tune=x.json", "--fixed-fps", "--fixed-fps=60", "--preset=low", "--shots=x", "--position=0,0", "--audio-driver=ALSA", "--benchmark" })
                RejectClip(p => p["args"] = new List<object> { reserved }, "args: " + reserved, "which the app sets itself");
            RejectClip(p => p["args"] = new List<object> { "--tune" }, "args: --tune alone", "--tune");
        }

        // ---- Command lines ---------------------------------------------------------------------------------------------------------------

        static void ClipCommandTests()
        {
            JobPlan plan; string error;
            JobPlan.TryParse(JobPlan.ClipKind, ValidPayload(), Site, out plan, out error);
            string planFile = "C:\\Users\\Test User\\AppData\\Local\\DeathMuffinTeam\\jobs\\q7x2k9ab\\plan.json";
            string clips = "C:\\Users\\Test User\\AppData\\Local\\DeathMuffinTeam\\jobs\\q7x2k9ab\\out\\slow";
            string tune = "C:\\Users\\Test User\\AppData\\Local\\DeathMuffinTeam\\jobs\\q7x2k9ab\\tune-slow.json";
            var a = plan.ClipCommandArgs(plan.Variants[0], "high", planFile, clips, tune);
            T.Eq(string.Join("|", a),
                "--windowed|--resolution|1920x1080|--audio-driver|Dummy|--fixed-fps|60|--|--dev-offline|--qa|--preset=high|--clip-plan=C:/Users/Test User/AppData/Local/DeathMuffinTeam/jobs/q7x2k9ab/plan.json|--clips=C:/Users/Test User/AppData/Local/DeathMuffinTeam/jobs/q7x2k9ab/out/slow|--tune=C:/Users/Test User/AppData/Local/DeathMuffinTeam/jobs/q7x2k9ab/tune-slow.json|--clip-fps=60|--clip-width=1920|--qa-window=1920x1080",
                "the clip run's arguments are the contract's: 1080p at the engine's --fixed-fps 60, then -- <args> --preset --clip-plan --clips --tune and the recording's rate, width and window (Helix: 1080p at 60)");
            T.Eq(string.Join(" ", a.Take(7)), "--windowed --resolution 1920x1080 --audio-driver Dummy --fixed-fps 60", "a clip run is silent, windowed at 1920x1080, and at a fixed 60 frames per game second (readback time never changes the clip's timing)");
            T.Eq(a.IndexOf("--"), 7, "everything for the game comes after --");
            T.Ok(a.IndexOf("--fixed-fps") < a.IndexOf("--"), "--fixed-fps is an engine option, ahead of --");
            var noTune = plan.ClipCommandArgs(new ClipVariant { Label = "clip" }, "high", planFile, clips, null);
            T.Ok(!noTune.Any(x => x.StartsWith("--tune")) && noTune.Count == a.Count - 1, "a variant with no tune passes no --tune");
            var off = plan.ClipCommandArgs(plan.Variants[0], "high", planFile, clips, tune, "-1700,0");
            T.Eq(string.Join(" ", off.Take(10)), "--windowed --resolution 1920x1080 --audio-driver Dummy --fixed-fps 60 --position -1700,0 --", "--position (outside every monitor) goes ahead of --, after --fixed-fps");
            T.Eq(string.Join("|", off.Skip(10)), string.Join("|", a.Skip(8)), "the game's own options are the same");
            T.Ok(!a.Contains("--position") && !plan.ClipCommandArgs(plan.Variants[0], "high", "p", "c", "t", "").Contains("--position"), "no position given, none is set");
            string line = plan.ClipCommandLine(plan.Variants[0], "high", planFile, clips, tune);
            T.Has(line, "\"--clip-plan=C:/Users/Test User/AppData/Local/DeathMuffinTeam/jobs/q7x2k9ab/plan.json\"", "a path with a space is quoted");
            T.Has(line, "--fixed-fps 60 -- --dev-offline", "the command line");
            T.Eq(plan.ClipCommandLine(plan.Variants[1], "low", "C:\\j\\plan.json", "C:\\j\\out\\fast", "C:\\j\\tune-fast.json"),
                "--windowed --resolution 1920x1080 --audio-driver Dummy --fixed-fps 60 -- --dev-offline --qa --preset=low --clip-plan=C:/j/plan.json --clips=C:/j/out/fast --tune=C:/j/tune-fast.json --clip-fps=60 --clip-width=1920 --qa-window=1920x1080",
                "a command line without spaces needs no quotes");

            // a screenshots run does not get --fixed-fps
            JobPlan shots; JobPlan.TryParse(Program.ValidPayload(), Site, out shots, out error);
            T.Ok(!shots.CommandArgs("low", "p", "s").Contains("--fixed-fps"), "a screenshots run is not at a fixed frame rate");
        }

        // ---- Upload names -----------------------------------------------------------------------------------------------------------------

        static void ClipNameTests()
        {
            var name = new Regex("^[a-z0-9][a-z0-9_-]{0,59}\\.mp4$");
            T.Eq(JobPlan.Mp4UploadName("slow", "wraith.mp4"), "slow_wraith.mp4", "clip upload name: the variant's label and the clip");
            T.Eq(JobPlan.Mp4UploadName("clip", "C:\\x\\out\\clip\\pack.mp4"), "clip_pack.mp4", "from a path; the default label is clip");
            T.Eq(JobPlan.Mp4UploadName("fast", "Big Hit!.MP4"), "fast_big_hit.mp4", "cleaned and lower-cased");
            T.Eq(JobPlan.Mp4UploadName("fast", "notes.json"), null, "only clips are uploaded");
            T.Eq(JobPlan.Mp4UploadName("fast", "wraith.png"), null, "a picture is not a clip");
            T.Eq(JobPlan.Mp4UploadName("fast", "x.mp4.txt"), null, "a name that only contains .mp4 is not a clip's video");
            T.Eq(JobPlan.Mp4UploadName("fast", "!!!.mp4"), "fast_shot.mp4", "an empty name gets a placeholder");
            foreach (string label in new[] { "a", "slow", new string('x', 24), "b-2" })
                foreach (string clip in new[] { "a", new string('x', 40), new string('y', 200), "caf\u00e9 \u00fcber", "UPPER_case-1", "..", "9" })
                {
                    string n = JobPlan.Mp4UploadName(label, clip + ".mp4");
                    T.Ok(n != null && name.IsMatch(n), "clip upload name matches the server's rule: " + label + " " + (clip.Length > 20 ? clip.Substring(0, 20) : clip) + " -> " + n);
                }
            var used = new HashSet<string>();
            var list = JobPlan.Mp4UploadNames("slow", new[] { "z:/o/b.mp4", "z:/o/a.mp4", "z:/o/A.mp4", "z:/o/a.json", "z:/o/a!.mp4", "z:/o/pic.png" }, used);
            T.Eq(string.Join(",", list.Select(k => k.Value)), "slow_a.mp4,slow_a-2.mp4,slow_a-3.mp4,slow_b.mp4", "names are unique (a second a becomes a-2) and only clips are named");
            T.Eq(JobPlan.Mp4UploadNames("fast", new[] { "z:/f/a.mp4" }, used)[0].Value, "fast_a.mp4", "the same clip of another variant keeps its own name");
            var many = JobPlan.Mp4UploadNames("slow", Enumerable.Range(0, 20).Select(i => "z:/o/" + new string('s', 60) + ".mp4"), new HashSet<string>());
            T.Ok(many.Select(k => k.Value).Distinct().Count() == 20 && many.All(k => name.IsMatch(k.Value)), "long colliding names stay unique and valid");

            // a build's pictures: the build and the preset make the prefix
            T.Eq(JobPlan.UploadName("before_low", "hero-front.png"), "before_low_hero-front.png", "a before picture: <label>_<preset>_<shot>.png");
            T.Eq(JobPlan.UploadName("after_ultra", "C:\\o\\after\\ultra\\bag open.png"), "after_ultra_bag_open.png", "an after picture");
            var png = new Regex("^[a-z0-9_-]{1,60}\\.png$");
            foreach (string pre in new[] { "before_low", "after_medium", "before_high", "after_ultra" })
                T.Ok(png.IsMatch(JobPlan.UploadName(pre, new string('z', 120) + ".png")), "a long picture name still fits the server's rule with " + pre);
        }

        // ---- Two builds --------------------------------------------------------------------------------------------------------------------

        static List<object> BuildFilesFor(string pckSeed)
        {
            return new List<object>
            {
                Program.File_("DeathMuffinDebug.pck", sha: new string(pckSeed[0], 64)),
                Program.File_("DeathMuffin.assets.pck", "assets-0f3a9c"),
                Program.File_("libdmcore.windows.template_release.x86_64.dll"),
                Program.File_("DeathMuffinDebug.exe", "godot-debug-4.7.2"),
            };
        }

        public static Dictionary<string, object> BuildsPayload()
        {
            var p = Program.ValidPayload();
            p.Remove("files");
            p["builds"] = new List<object>
            {
                new Dictionary<string, object> { { "label", "before" }, { "files", BuildFilesFor("b") } },
                new Dictionary<string, object> { { "label", "after" }, { "files", BuildFilesFor("c") } },
            };
            return p;
        }

        static List<object> Builds(Dictionary<string, object> p) { return (List<object>)p["builds"]; }
        static Dictionary<string, object> Build(Dictionary<string, object> p, int i) { return (Dictionary<string, object>)Builds(p)[i]; }

        static void BuildsPlanTests()
        {
            JobPlan plan; string error;
            T.Ok(JobPlan.TryParse(BuildsPayload(), Site, out plan, out error), "a payload with a before and an after build is accepted: " + error);
            T.Eq(plan.Builds.Count, 2, "two builds");
            T.Eq(plan.Builds[0].Label + "," + plan.Builds[1].Label, "before,after", "in the order sent");
            T.Eq(plan.Builds[0].Files.Count + "," + plan.Builds[1].Files.Count, "4,4", "each with its own files");
            T.Ok(plan.Builds[0].Files[0].Sha256 != plan.Builds[1].Files[0].Sha256, "the builds' code packs differ");
            T.Ok(ReferenceEquals(plan.Files, plan.Builds[0].Files), "Files is the first build's");
            T.Eq(plan.AllBuilds().Count, 2, "AllBuilds is both");
            T.Eq(string.Join(",", plan.Presets), "low,ultra", "the presets are for each build");
            T.Eq(string.Join(" ", plan.Args), "--dev-offline --class=2 --qa", "the options are the same for both");
            T.Eq(MiniJson.Arr(MiniJson.TryObject(plan.PlanJson), "shots").Count, 2, "one shot plan for both");

            // a job with one build is its own build, with no label
            JobPlan single; JobPlan.TryParse(Program.ValidPayload(), Site, out single, out error);
            T.Ok(single.Builds.Count == 0 && single.AllBuilds().Count == 1 && single.AllBuilds()[0].Label == "" && ReferenceEquals(single.AllBuilds()[0].Files, single.Files), "a job without builds has one unlabelled build, its files");

            // one build only, either label
            var p = BuildsPayload(); Builds(p).RemoveAt(0);
            T.Ok(JobPlan.TryParse(p, Site, out plan, out error) && plan.Builds.Count == 1 && plan.Builds[0].Label == "after", "one build (after) is accepted");
            // `files` sent too: builds win, files are not used
            p = BuildsPayload(); p["files"] = new List<object> { Program.File_("only-this.dll") };
            T.Ok(JobPlan.TryParse(p, Site, out plan, out error) && plan.Builds.Count == 2 && plan.FileNamed("only-this.dll") == null, "when builds are sent `files` is not used");
            // the same file in both builds: the same cache key and checksum is fine
            T.Ok(plan.Builds[0].Files[1].CacheKey == plan.Builds[1].Files[1].CacheKey, "builds may share a cache key for the same file");
            // a payload that is JSON text
            T.Ok(JobPlan.TryParse(JobPlan.ShotsKind, MiniJson.Write(BuildsPayload()), Site, out plan, out error) && plan.Builds.Count == 2, "a builds payload given as JSON text");
            // builds are for screenshots only
            T.Ok(!JobPlan.TryParse(JobPlan.BenchKind, BenchBuilds(), Site, out plan, out error) && error.Contains("screenshots"), "a benchmark has no builds");
        }

        static Dictionary<string, object> BenchBuilds()
        {
            var p = BenchTests.ValidPayload();
            p["builds"] = Builds(BuildsPayload());
            return p;
        }

        static string RejectBuilds(Action<Dictionary<string, object>> mutate, string name, string wantInError = null)
        {
            var p = BuildsPayload();
            mutate(p);
            JobPlan plan; string err;
            bool ok = JobPlan.TryParse(p, Site, out plan, out err);
            T.Ok(!ok && plan == null && !string.IsNullOrEmpty(err), "builds payload refused: " + name + (ok ? " (it was accepted)" : ""));
            if (wantInError != null) T.Has(err, wantInError, "builds refusal says why: " + name);
            if (err != null) T.Ok(!err.Contains("Exception") && !err.Contains(" at "), "builds refusal is plain English: " + name);
            return err;
        }

        static void BuildsRefusalTests()
        {
            RejectBuilds(p => p["builds"] = new List<object>(), "no builds", "no builds");
            RejectBuilds(p => p["builds"] = "before", "builds as text", "no builds");
            RejectBuilds(p => p["builds"] = new Dictionary<string, object> { { "label", "before" } }, "builds as an object");
            RejectBuilds(p => Builds(p).Add(new Dictionary<string, object> { { "label", "after" }, { "files", BuildFilesFor("d") } }), "three builds", "no builds");
            RejectBuilds(p => Build(p, 1)["label"] = "before", "the same label twice", "twice");
            foreach (string bad in new[] { "middle", "Before", "after ", "", "../x", "both" })
                RejectBuilds(p => Build(p, 0)["label"] = bad, "build label '" + bad + "'", "not allowed");
            RejectBuilds(p => Build(p, 0).Remove("label"), "a build with no label", "not allowed");
            RejectBuilds(p => Builds(p)[0] = "before", "a build that is text", "not valid");
            RejectBuilds(p => Build(p, 1).Remove("files"), "the after build has no files", "after build");
            RejectBuilds(p => Build(p, 1)["files"] = new List<object>(), "the after build has an empty file list", "after build");
            RejectBuilds(p => ((List<object>)Build(p, 0)["files"]).RemoveAll(f => (string)((Dictionary<string, object>)f)["name"] == "DeathMuffinDebug.exe"), "the before build has no game exe", "The before build does not include DeathMuffinDebug.exe");
            RejectBuilds(p => ((List<object>)Build(p, 1)["files"]).RemoveAll(f => (string)((Dictionary<string, object>)f)["name"] == "DeathMuffinDebug.pck"), "the after build has no main pack", "The after build does not include");
            RejectBuilds(p => ((List<object>)Build(p, 1)["files"]).Add(Program.File_("../evil.dll")), "an unsafe name in the after build", "not allowed");
            RejectBuilds(p => ((List<object>)Build(p, 0)["files"]).Add(Program.File_("a.dll", url: "https://evil.example/death-muffin/team-files/x/a.dll")), "another host in the before build", "not on the game's server");
            RejectBuilds(p => ((List<object>)Build(p, 1)["files"]).Add(Program.File_("DeathMuffinDebug.pck")), "a file twice in one build", "twice");
            RejectBuilds(p => ((List<object>)Build(p, 1)["files"])[1] = Program.File_("DeathMuffin.assets.pck", "assets-0f3a9c", sha: new string('e', 64)), "one cache name for different files", "different files");
            RejectBuilds(p => { for (int i = 0; i < 12; i++) ((List<object>)Build(p, 1)["files"]).Add(Program.File_("extra" + i + ".dll")); }, "too many files in a build", "too many");
            RejectBuilds(p => p["presets"] = new List<object> { "potato" }, "an unknown preset", "does not exist");
            RejectBuilds(p => p.Remove("plan"), "no shot plan", "no shot plan");
            RejectBuilds(p => p["args"] = new List<object> { "--shots=x" }, "a reserved option", "--shots");
        }

        // ---- Screenshots at several window sizes ---------------------------------------------------------------------------------------

        static void ResolutionPlanTests()
        {
            JobPlan plan; string error;
            var p = Program.ValidPayload(); p["resolutions"] = new List<object> { "1920x1080", "3840x2160" };
            T.Ok(JobPlan.TryParse(p, Site, out plan, out error) && string.Join(",", plan.ScreenSizes.Select(s => s.Text)) == "1920x1080,3840x2160", "a shots payload with resolutions is accepted: " + error);
            T.Eq(plan.ScreenSizes[1].Width + "x" + plan.ScreenSizes[1].Height, "3840x2160", "the sizes are read");
            p = Program.ValidPayload(); p["resolutions"] = new List<object> { "1920x1080", "2560x1440", "3840x2160", "3440x1440" };
            T.Ok(JobPlan.TryParse(p, Site, out plan, out error) && plan.ScreenSizes.Count == 4, "all four standard sizes");
            p = Program.ValidPayload(); p["resolutions"] = new List<object> { "3440x1440" };
            T.Ok(JobPlan.TryParse(p, Site, out plan, out error) && plan.ScreenSizes.Count == 1, "one size");
            T.Ok(JobPlan.TryParse(Program.ValidPayload(), Site, out plan, out error) && plan.ScreenSizes.Count == 0, "no resolutions: the one 1600x900 window");
            p = Program.ValidPayload(); p["resolutions"] = null;
            T.Ok(JobPlan.TryParse(p, Site, out plan, out error) && plan.ScreenSizes.Count == 0, "null resolutions are none");
            // with builds too
            p = BuildsPayload(); p["resolutions"] = new List<object> { "2560x1440" };
            T.Ok(JobPlan.TryParse(p, Site, out plan, out error) && plan.Builds.Count == 2 && plan.ScreenSizes.Count == 1, "before/after builds and a window size: " + error);
            foreach (object bad in new object[] { new List<object>(), "1920x1080", 1920.0, new List<object> { "800x600" }, new List<object> { "1920X1080" }, new List<object> { "1600x900" }, new List<object> { 1920.0 }, new List<object> { "1920x1080", "1920x1080" },
                new List<object> { "1920x1080", "2560x1440", "3840x2160", "3440x1440", "1920x1080" }, new List<object> { "../1920x1080" }, new List<object> { "" } })
            {
                p = Program.ValidPayload(); p["resolutions"] = bad;
                bool ok = JobPlan.TryParse(p, Site, out plan, out error);
                T.Ok(!ok && plan == null && error.Length > 0 && !error.Contains("Exception"), "resolutions refused: " + MiniJson.Write(bad));
            }
            p = Program.ValidPayload(); p["resolutions"] = new List<object> { "800x600" };
            JobPlan.TryParse(p, Site, out plan, out error);
            T.Has(error, "window size that is not allowed", "and the refusal says why");
            // not for the other kinds' payloads
            p = ValidPayload(); p["resolutions"] = new List<object> { "800x600" };
            T.Ok(JobPlan.TryParse(JobPlan.ClipKind, p, Site, out plan, out error), "a clip payload does not read `resolutions`");

            // the command
            JobPlan shots; JobPlan.TryParse(Program.ValidPayload(), Site, out shots, out error);
            var big = new ScreenSize { Width = 3840, Height = 2160 };
            T.Eq(string.Join(" ", shots.CommandArgs("low", "p", "s", "-3940,0", big).Take(8)), "--windowed --resolution 3840x2160 --audio-driver Dummy --position -3940,0 --", "the window size is the one asked for, outside every monitor");
            T.Eq(string.Join("|", shots.CommandArgs("low", "p", "s", null, big).Skip(5)), string.Join("|", shots.CommandArgs("low", "p", "s").Skip(5)).Replace("--qa-window=1920x1080", "--qa-window=3840x2160"), "everything after -- is the same but the window the game sizes itself to");
            T.Eq(shots.CommandArgs("low", "p", "s")[2] + " " + shots.CommandArgs("low", "p", "s").Last(), "1920x1080 --qa-window=1920x1080", "with no size, 1080p (Helix 2026-10-19)");
            T.Eq(JobPlan.UploadName("low_1920x1080", "hero-front.png"), "low_1920x1080_hero-front.png", "`<preset>_<w>x<h>_<shot>.png`");
            T.Eq(JobPlan.UploadName("before_ultra_3440x1440", "hero-front.png"), "before_ultra_3440x1440_hero-front.png", "`<build>_<preset>_<w>x<h>_<shot>.png`");
            var png = new Regex("^[a-z0-9_-]{1,60}\\.png$");
            T.Ok(png.IsMatch(JobPlan.UploadName("before_ultra_3440x1440", new string('q', 100) + ".png")), "and a long shot name still fits the server's rule");
        }

        // ---- The server's routes and the folders ----------------------------------------------------------------------------------------

        static void ApiTests()
        {
            var tr = new Program.FakeTransport();
            var api = new TeamApi(tr, new Uri(TeamUrls.ApiBase)) { Token = "team-tok-1" };
            tr.Respond = r => new HttpReply { Status = 200, Body = "{\"success\":true,\"data\":{}}" };
            byte[] clip = Util.Blob(5000, 3);
            Util.Wait(api.UploadAsync("ab12cd34ef56", "slow_wraith.mp4", clip, CancellationToken.None));
            var up = tr.Sent[0];
            T.Eq(up.Method + " " + up.Url.AbsolutePath, "PUT /death-muffin/api/team/jobs/ab12cd34ef56/files/slow_wraith.mp4", "a clip's video goes to the files route as a PUT");
            T.Eq(up.ContentType, "video/mp4", "with the content type the server takes for it");
            T.Ok(up.Body.SequenceEqual(clip), "the raw bytes are the body");
            T.Eq(up.Token, "team-tok-1", "with the team token");
            T.Eq(TeamApi.Mp4Type + "|" + TeamApi.PngType, "video/mp4|image/png", "the two content types");
            Util.Wait(api.UploadAsync("ab12cd34ef56", "before_low_hero.png", Util.FakePng(1), CancellationToken.None));
            T.Eq(tr.Sent[1].ContentType, "image/png", "a picture is still image/png");
            T.Eq(tr.Sent[1].Url.AbsolutePath, "/death-muffin/api/team/jobs/ab12cd34ef56/files/before_low_hero.png", "and goes where it did");
            tr.Sent.Clear();
            foreach (string bad in new[] { "../x.mp4", "Slow_a.mp4", "a b.mp4", "a.MP4", "_a.mp4", "-a.mp4", ".mp4", "a.mp4/../b.mp4", "a/b.mp4", "a.mjpeg", "a.mp", new string('a', 61) + ".mp4", "" })
            {
                var r = Util.Wait(api.UploadAsync("ab12cd34ef56", bad, clip, CancellationToken.None));
                T.Ok(!r.Ok && r.Error.Length > 0, "upload refuses the name '" + bad + "'");
            }
            T.Ok(Util.Wait(api.UploadAsync("ab12cd34ef56", "slow_a.mp4", clip, CancellationToken.None)).Ok && Util.Wait(api.UploadAsync("ab12cd34ef56", new string('a', 60) + ".mp4", clip, CancellationToken.None)).Ok, "60 characters before .mp4 is allowed");
            T.Has(Util.Wait(api.UploadAsync("ab12cd34ef56", "A.mp4", clip, CancellationToken.None)).Error, "clip", "a refused clip name says clip");
            T.Ok(!Util.Wait(api.UploadAsync("../x", "a_b.mp4", clip, CancellationToken.None)).Ok, "upload refuses a bad job id for a clip too");
            T.Eq(tr.Sent.Count, 2, "refused uploads never reach the network");

            // a clip job's done is the shots done: the names of what was uploaded
            tr.Sent.Clear();
            Util.Wait(api.DoneAsync("ab12cd34ef56", new List<string> { "slow_wraith.mp4", "fast_wraith.mp4" }, "log", 3.0, 20.0, CancellationToken.None));
            var done = MiniJson.TryObject(Encoding.UTF8.GetString(tr.Sent[0].Body));
            T.Eq(string.Join(",", MiniJson.Arr(done, "files").Cast<string>()), "slow_wraith.mp4,fast_wraith.mp4", "done names the uploaded videos");

            // how long a request may take
            Uri team = new Uri("https://muffindevelopment.com/death-muffin/api/team/");
            T.Eq(HttpClientTransport.TimeoutFor(new Uri(team, "heartbeat"), new byte[300]), TimeSpan.FromSeconds(40), "a heartbeat: 40 s (the server holds it up to 25)");
            T.Eq(HttpClientTransport.TimeoutFor(new Uri(team, "jobs/ab12cd34ef56/claim"), new byte[300]), TimeSpan.FromMinutes(2), "a small call: 2 minutes");
            T.Eq(HttpClientTransport.TimeoutFor(new Uri(team, "jobs/ab12cd34ef56/files/a.png"), new byte[200000]), TimeSpan.FromMinutes(2), "a picture: 2 minutes");
            T.Eq(HttpClientTransport.TimeoutFor(new Uri(team, "jobs/ab12cd34ef56/files/a.mp4"), new byte[3 << 20]), TimeSpan.FromMinutes(6), "a clip's video: 6 minutes");
            T.Eq(HttpClientTransport.TimeoutFor(new Uri(team, "jobs/ab12cd34ef56/done"), new byte[300]), TimeSpan.FromMinutes(6), "a done (the server makes the videos while it waits): 6 minutes");
            T.Eq(HttpClientTransport.TimeoutFor(new Uri(team, "login"), null), TimeSpan.FromMinutes(2), "a call with no body: 2 minutes");
        }

        static void FolderTests()
        {
            var f = new TeamFolders("C:\\root");
            T.Eq(f.GameDir("jobA"), Path.Combine(Path.Combine("C:\\root", "jobs", "jobA"), "game"), "the one game folder");
            T.Eq(f.GameDir("jobA", ""), f.GameDir("jobA"), "no build is the one folder");
            T.Eq(f.GameDir("jobA", "before"), Path.Combine("C:\\root", "jobs", "jobA", "game-before"), "the before build's folder");
            T.Eq(f.GameDir("jobA", "after"), Path.Combine("C:\\root", "jobs", "jobA", "game-after"), "the after build's folder");
            T.Eq(f.TuneFile("jobA", "slow"), Path.Combine("C:\\root", "jobs", "jobA", "tune-slow.json"), "a variant's tune file");
        }

        // ---- The controller -------------------------------------------------------------------------------------------------------------

        static void ControllerRuns()
        {
            // the box says what a clip job is, from the server's title or, with none, from its kind
            var r = new CtlRig();
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "clip" }, { "title", "Short videos of a change" }, { "payload", ValidPayload() } });
            r.Start();
            r.Api.Heartbeat = () => FakeApi.OfferReply("job0000000c1", "clip", "Short videos of a change", 180);
            r.Beat(); r.Eval();
            T.Eq(r.Ui.Shown[0].Text, "Short videos of a change, about 3 minutes", "the box for a clip job: short videos of a change, about N minutes");
            T.Eq(r.Ui.Shown[0].Note, "", "no extra note");
            T.Eq(r.Ui.Status, "Job offered: Short videos of a change, about 3 minutes", "and the tray says the same");
            T.Eq(r.LastCountdown, "Runs by itself in 5:00", "a clip job counts down like any job");
            r.Advance(5.01); r.Eval();
            T.Eq(r.Ran, 1, "after 5 minutes without an answer a clip job runs by itself");
            T.Eq(r.Runner.LastPlan.Kind, "clip", "the runner got a clip plan");
            T.Eq(r.Runner.LastPlan.Variants.Count, 2, "with its variants");
            T.Eq(r.Api.Count("decline"), 0, "a clip job is not declined");
            T.Ok(r.Ui.Status.StartsWith("Last job: 1 picture(s) uploaded") == false && r.Ui.Status.StartsWith("Last job: 1 clip(s) uploaded"), "the status after a clip job counts clips: " + r.Ui.Status);

            r = new CtlRig();
            r.Start();
            r.Api.Heartbeat = () => FakeApi.OfferReply("job0000000c2", "clip", "", 90);
            r.Beat(); r.Eval();
            T.Eq(r.Ui.Shown[0].Text, "Short videos of a change, about 2 minutes", "a clip job with no title is named by its kind");
            T.Eq(TeamLogic.OfferText("shots", "", 60), "Screenshots of a change, about 1 minute", "a screenshots job with no title");
            T.Eq(TeamLogic.OfferText("bench", " ", 360), "Benchmark of the new release, about 6 minutes", "a benchmark with no title");
            T.Eq(TeamLogic.OfferText("stutter", null, 60), "A job, about 1 minute", "an unknown kind with no title");
            T.Eq(TeamLogic.OfferText("clip", "Wraith at three speeds", 240), "Wraith at three speeds, about 4 minutes", "the server's title wins");
            T.Eq(TeamLogic.OfferText("Screenshots of a change", 60), "Screenshots of a change, about 1 minute", "the old overload is the same");

            // the same modes as every job: Run without asking runs at once, Only on a yes asks and waits, AFK runs without a box
            r = new CtlRig(mode: OfferMode.Auto);
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "clip" }, { "title", "t" }, { "payload", ValidPayload() } });
            r.Start(); r.Offer("job0000000c3", "clip"); r.Eval();
            T.Ok(r.Ran == 1 && !r.Ui.BoxVisible, "Run without asking: a clip job runs with no box");
            r = new CtlRig(mode: OfferMode.Yes);
            r.Start(); r.Offer("job0000000c4", "clip"); r.Eval(); r.Advance(30); r.Eval();
            T.Ok(r.Ran == 0 && r.Ui.BoxVisible && r.LastCountdown == "Runs when you say yes", "Only on a yes: the box asks and waits");
            r = new CtlRig();
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "clip" }, { "title", "t" }, { "payload", ValidPayload() } });
            r.Start(); r.Offer("job0000000c5", "shots"); r.Eval(); r.Advance(5.01); r.Eval();   // a box that ran out: AFK mode
            T.Ok(r.Ui.Afk, "a box that runs out in mode Ask is AFK mode");
            r.Offer("job0000000c6", "clip"); r.Eval();
            T.Ok(r.Ran == 2 && r.Runner.LastPlan.Kind == "clip", "in AFK mode a clip job runs at once, with no box");
            r = new CtlRig();
            r.Start(); r.Plat.IsFullscreen = true; r.Offer("job0000000c7", "clip"); r.Eval(); r.Advance(6); r.Eval();
            T.Ok(r.Ran == 0 && !r.Ui.BoxVisible && r.Ui.Status.StartsWith("Job waiting"), "a clip job waits for a full-screen app, like the others");
            r = new CtlRig();
            r.Start(); r.Plat.IsGame = true; r.Offer("job0000000c8", "clip"); r.Eval(); r.Advance(6); r.Eval();
            T.Ok(r.Ran == 0, "and for Death Muffin to close");

            // a clip job offered while another job runs is declined as busy (it stays queued for the other PCs), like a screenshots job
            r = new CtlRig(mode: OfferMode.Auto);
            r.Runner.Gate = new System.Threading.Tasks.TaskCompletionSource<int>();
            r.Start(); r.Offer("job0000000c9", "shots");
            var evaluating = System.Threading.Tasks.Task.Run(() => r.Eval());
            Util.Wait(WaitUntil(() => r.Ran == 1));
            r.Offer("job0000000ca", "clip");
            T.Eq(string.Join(",", r.Api.Declines), "job0000000ca:busy", "a clip job offered while a job runs is declined as busy");
            r.Runner.Gate.SetResult(0);
            Util.Wait(evaluating);

            // a payload the app refuses fails the job in plain words
            r = new CtlRig(mode: OfferMode.Auto);
            var bad = ValidPayload();
            ((Dictionary<string, object>)bad["plan"])["clips"] = new List<object>();
            r.Api.Claim = id => FakeApi.Ok(new Dictionary<string, object> { { "id", id }, { "kind", "clip" }, { "title", "t" }, { "payload", bad } });
            r.Start(); r.Offer("job0000000cb", "clip"); r.Eval();
            T.Ok(r.Ran == 0 && r.Api.Count("fail") == 1 && r.Api.FailError.Contains("no clip plan"), "a clip payload the app refuses is failed with the reason: " + r.Api.FailError);

            // a kind the app still does not know says which it knows
            r = new CtlRig(mode: OfferMode.Auto);
            r.Start(); r.Offer("job0000000cc", "stutter"); r.Eval();
            T.Ok(r.Ran == 0 && r.Api.Count("claim") == 0 && r.Log.Any(l => l.Contains("shots, clip, release and bench")), "a job kind this version cannot run is skipped, and the log names the four it runs");
            T.Has(r.Ui.Status, "newer team app", "and the status asks for a newer app");
        }

        static System.Threading.Tasks.Task WaitUntil(Func<bool> cond)
        {
            return System.Threading.Tasks.Task.Run(() =>
            {
                var sw = System.Diagnostics.Stopwatch.StartNew();
                while (!cond()) { if (sw.Elapsed > TimeSpan.FromSeconds(30)) throw new TimeoutException("waited for a condition"); Thread.Sleep(5); }
            });
        }

        // ---- The runner ---------------------------------------------------------------------------------------------------------------

        /// <summary>The game as a stand-in that records the clips of a plan: for each planned clip it writes `<name>.mjpeg` (and a small `<name>.json`, at <paramref name="fps"/>) into `--clips`; the bytes depend on the variant and the clip.</summary>
        public static byte[] ClipBytes(string variant, string clip) { return Util.Blob(3000 + clip.Length * 100, (variant + "/" + clip).GetHashCode() & 0xffff); }

        static string ArgOf(GameLaunch l, string name)
        {
            string a = l.Args.FirstOrDefault(x => x.StartsWith(name + "="));
            return a == null ? null : a.Substring(a.IndexOf('=') + 1);
        }

        static Func<GameLaunch, string, int?> ClipGame(Func<string, int?> special = null, int fps = 60)
        {
            return (l, dir) =>
            {
                string variant = Path.GetFileName(dir.TrimEnd('/', '\\'));
                int? code = special == null ? null : special(variant);
                if (code.HasValue && code.Value != 0) return code;
                var plan = MiniJson.TryObject(File.ReadAllText(ArgOf(l, "--clip-plan")));
                foreach (object c in MiniJson.Arr(plan, "clips"))
                {
                    string name = MiniJson.Str((Dictionary<string, object>)c, "name");
                    File.WriteAllBytes(Path.Combine(dir, name + ".mjpeg"), ClipBytes(variant, name));
                    File.WriteAllText(Path.Combine(dir, name + ".json"), "{\"fps\":" + fps + ",\"frames\":300,\"width\":1920,\"height\":1080,\"cast_at_frame\":12}");
                }
                return 0;
            };
        }

        public static void RunnerRuns()
        {
            ClipHappy();
            ClipDefaults();
            ClipFailures();
            BuildsHappy();
            BuildsSharing();
            BuildsFailures();
            ResolutionRuns();
        }

        static void ClipHappy()
        {
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ClipGame();
                var plan = rig.ClipPlan();
                var progress = new List<string>();
                string id = "clipA0000001";
                var res = rig.Run(id, plan, progress);
                T.Ok(res.Ok, "a clip job runs to done: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 2, "the game starts once per variant");
                string game = rig.Folders.GameDir(id), planFile = rig.Folders.PlanFile(id);
                var slow = rig.Host.Launches[0];
                T.Eq(slow.ExePath, Path.Combine(game, "DeathMuffinDebug.exe"), "the debug build in the job's game folder is started");
                T.Eq(slow.WorkingDir, game, "in its folder");
                T.Eq(string.Join("|", slow.Args), string.Join("|", plan.ClipCommandArgs(plan.Variants[0], "high", planFile, Path.Combine(rig.Folders.OutDir(id), "slow"), rig.Folders.TuneFile(id, "slow"))), "the slow variant's arguments are the contract's");
                T.Eq(string.Join("|", rig.Host.Launches[1].Args), string.Join("|", plan.ClipCommandArgs(plan.Variants[1], "high", planFile, Path.Combine(rig.Folders.OutDir(id), "fast"), rig.Folders.TuneFile(id, "fast"))), "and the fast one's");
                T.Has(string.Join(" ", slow.Args), "--fixed-fps 60 --", "the engine runs at a fixed 60 frames per game second");
                T.Eq(string.Join(",", rig.Enc.Calls), "pack.mjpeg@60,wraith.mjpeg@60,pack.mjpeg@60,wraith.mjpeg@60", "this PC makes every clip's video, at the rate the game's note says");
                T.Eq(rig.Enc.Ffmpeg, Path.Combine(rig.Folders.CacheDir("ffmpeg-test"), "ffmpeg.exe"), "with the encoder from the cache");
                T.Ok(File.ReadAllBytes(rig.Enc.Ffmpeg).SequenceEqual(rig.Ffmpeg), "downloaded and checked like any job file");
                T.Ok(!Directory.GetFiles(Path.Combine(rig.Folders.OutDir(id), "slow"), "*.mjpeg").Any(), "the motion JPEG is deleted once its video is made");
                T.Has(string.Join(" ", slow.Args), "--preset=high --clip-plan=", "on the plan's preset");
                T.Ok(slow.AppData.StartsWith(rig.Folders.JobDir(id)) && slow.LocalAppData.StartsWith(rig.Folders.JobDir(id)) && slow.AppData != slow.LocalAppData, "APPDATA and LOCALAPPDATA point into the job's own folder");
                T.Ok(slow.AppData != rig.Host.Launches[1].AppData && slow.LocalAppData != rig.Host.Launches[1].LocalAppData, "each variant has its own fresh pair (each in its fresh folder)");
                T.Ok(slow.AppData.Contains("run-1") && rig.Host.Launches[1].AppData.Contains("run-2"), "run-1 and run-2");
                T.Eq(slow.Priority, System.Diagnostics.ProcessPriorityClass.BelowNormal, "a clip run is below normal priority, like screenshots");
                T.Ok(File.ReadAllText(planFile) == plan.PlanJson, "plan.json holds the clip plan");
                var tuneSlow = MiniJson.TryObject(File.ReadAllText(ArgOf(slow, "--tune")));
                var tuneFast = MiniJson.TryObject(File.ReadAllText(ArgOf(rig.Host.Launches[1], "--tune")));
                T.Eq(MiniJson.Int(MiniJson.Obj(MiniJson.Obj(tuneSlow, "combat/abilities"), "haunting_wraith"), "speed"), 4L, "the slow variant's tune is the file the game is given");
                T.Eq(MiniJson.Int(MiniJson.Obj(MiniJson.Obj(tuneFast, "combat/abilities"), "haunting_wraith"), "speed"), 9L, "and the fast variant's");
                T.Ok(ArgOf(slow, "--tune") != ArgOf(rig.Host.Launches[1], "--tune"), "each variant has its own tune file");
                T.Eq(string.Join(",", rig.Api.Uploaded), "slow_pack.mp4,slow_wraith.mp4,fast_pack.mp4,fast_wraith.mp4", "the videos are uploaded as <label>_<clip>.mp4, variant by variant");
                T.Ok(rig.Api.UploadedBytes["slow_wraith.mp4"].SequenceEqual(FakeEncoder.Mp4Of(ClipBytes("slow", "wraith"))) && rig.Api.UploadedBytes["fast_pack.mp4"].SequenceEqual(FakeEncoder.Mp4Of(ClipBytes("fast", "pack"))), "uploaded bytes are the video of the game's clip");
                T.Eq(string.Join(",", rig.Api.DoneFiles), string.Join(",", rig.Api.Uploaded), "done lists every uploaded clip");
                T.Eq(rig.Api.DoneJob, id, "done names the job");
                T.Eq(rig.Api.Count("fail"), 0, "no fail call");
                int lastUpload = rig.Api.Calls.FindLastIndex(c => c.StartsWith("upload")), doneAt = rig.Api.Calls.FindIndex(c => c.StartsWith("done"));
                T.Ok(lastUpload >= 0 && doneAt > lastUpload, "done comes after the last upload");
                T.Eq(res.Files.Count, 4, "the result lists the clips");
                T.Has(rig.Api.DoneLog, "game output (the slow variant)", "the log carries the game's output");
                T.Has(rig.Api.DoneLog, "clip wraith: {\"fps\":60,\"frames\":300", "and the game's note about each clip");
                T.Has(rig.Api.DoneLog, "clip wraith: mp4 of 0.0 MB at 60 fps (crf 20)", "and its video");
                T.Has(rig.Api.DoneLog, "downloaded ffmpeg.exe", "and that the encoder was downloaded");
                T.Has(rig.Api.DoneLog, "uploaded slow_wraith.mp4", "and what was uploaded");
                T.Ok(progress.Any(p => p == "Recording clips for the slow variant (1 of 2)") && progress.Any(p => p == "Recording clips for the fast variant (2 of 2)") && progress.Any(p => p == "Making the video of wraith (2 of 2)")
                    && progress.Any(p => p.StartsWith("Downloading the video encoder (once): ")) && progress.Any(p => p == "Uploading clips (4 of 4)") && progress.Any(p => p == "Done: 4 clip(s) uploaded"), "progress tells what is happening");
                T.Ok(File.ReadAllText(rig.Folders.LogFile(id)).Contains("finished: 4 clip(s)"), "job.log is written");
                T.Eq(rig.Watch.Begins, 1, "the player's games are noted once");
                T.Eq(rig.Links.Count, 2, "the cached files are linked into the game folder");
                T.Ok(rig.Api.DoneRunS >= 0 && rig.Api.DoneDownloadS >= 0, "timings are reported");
                T.Ok(!Directory.Exists(rig.Folders.GameDir(id, "before")), "no per-build game folders for a clip job");
                var again = rig.Run("clipA0000002", rig.ClipPlan());
                T.Ok(again.Ok && rig.Api.DoneLog.Contains("kept from an earlier job: ffmpeg.exe"), "the next clip job uses the cached encoder: " + again.Error);
            }
            // the window: outside every monitor, like a screenshots run
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ClipGame();
                var widths = new List<int>();
                rig.Runner.WindowPosition = w => { widths.Add(w); return "-3940,0"; };
                T.Ok(rig.Run("clipB0000001", rig.ClipPlan()).Ok, "a clip job with a window position runs");
                T.Ok(rig.Host.Launches.All(l => string.Join(" ", l.Args.Take(10)) == "--windowed --resolution 1920x1080 --audio-driver Dummy --fixed-fps 60 --position -3940,0 --"), "every clip run's 1080p window is outside every monitor");
                T.Ok(widths.Count == 2 && widths.All(w => w == 1920), "with a spot for a 1920-wide window");
            }
            // a clip the game left from an earlier try is not this run's
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ClipGame();
                var plan = rig.ClipPlan(p => p["variants"] = new List<object> { Variant("slow", null) });
                string id = "clipC0000001";
                string old = Path.Combine(rig.Folders.OutDir(id), "slow");
                Directory.CreateDirectory(old);
                File.WriteAllBytes(Path.Combine(old, "stale.mjpeg"), Util.Blob(100, 1));
                T.Ok(rig.Run(id, plan).Ok, "a clip job runs over an earlier try's folder");
                T.Eq(string.Join(",", rig.Api.Uploaded), "slow_pack.mp4,slow_wraith.mp4", "a stale clip is not uploaded");
                T.Ok(!rig.Host.Launches[0].Args.Any(a => a.StartsWith("--tune")) && !File.Exists(rig.Folders.TuneFile(id, "slow")), "a variant with no tune has no tune file and no --tune");
            }
        }

        static void ClipDefaults()
        {
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ClipGame();
                var plan = rig.ClipPlan(p => { p.Remove("variants"); p.Remove("presets"); ((Dictionary<string, object>)p["plan"])["clips"] = new List<object> { Clip("wraith") }; });
                var res = rig.Run("clipD0000001", plan);
                T.Ok(res.Ok, "a clip job with no variants and no preset runs: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 1, "one game run");
                T.Has(string.Join(" ", rig.Host.Launches[0].Args), "--preset=high", "on high");
                T.Eq(string.Join(",", rig.Api.Uploaded), "clip_wraith.mp4", "with no label the videos are clip_<name>.mp4");
                T.Ok(rig.Api.Calls.Contains("upload clip_wraith.mp4"), "uploaded as that");
                T.Ok(rig.Api.DoneLog.Contains("game output (the clip run)"), "the run is named the clip run");
            }
        }

        static void ClipFailures()
        {
            // the game makes no clips
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => 0;
                var res = rig.Run("clipE0000001", rig.ClipPlan());
                T.Ok(!res.Ok, "a run that makes no clips fails the job");
                T.Eq(res.Error, "The game finished the slow variant but recorded no clips.", "in plain words");
                T.Eq(rig.Api.Count("fail"), 1, "and the server is told");
                T.Eq(rig.Api.FailError, res.Error, "with the same words");
                T.Eq(rig.Api.Count("upload"), 0, "nothing was uploaded");
                T.Eq(rig.Host.Launches.Count, 1, "the second variant never ran");
            }
            // one planned clip is missing
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => { File.WriteAllBytes(Path.Combine(dir, "wraith.mjpeg"), Util.Blob(500, 2)); return 0; };
                var res = rig.Run("clipE0000002", rig.ClipPlan());
                T.Eq(res.Error, "The game did not record the clip pack on the slow variant.", "a planned clip the game did not write is named");
                T.Eq(rig.Api.Count("upload"), 0, "nothing was uploaded");
            }
            // the second variant fails: nothing of the first is uploaded (a half job is no job)
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ClipGame(v => v == "fast" ? 1 : (int?)null);
                var res = rig.Run("clipE0000003", rig.ClipPlan());
                T.Eq(res.Error, "The game stopped with code 1 on the fast variant before it recorded every clip.", "the game's exit code, on the variant that failed");
                T.Eq(rig.Api.Count("upload"), 0, "the first variant's clips were not uploaded either");
                T.Eq(rig.Host.Launches.Count, 2, "both variants ran");
            }
            // the game refuses the plan or the tune (exit code 2)
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ClipGame(v => 2);
                var res = rig.Run("clipE0000004", rig.ClipPlan());
                T.Eq(res.Error, "The game refused the clip plan or the tune for the slow variant (code 2). The log says which line.", "exit code 2 is the game refusing what it was given");
                T.Has(rig.Api.FailLog, "QA-SHOTS fake game output", "and the log carries what the game printed");
            }
            // the game takes too long
            using (var rig = new Rig())
            {
                rig.Runner.RunLimit = TimeSpan.FromMilliseconds(40);
                rig.Host.Behaviour = (l, dir) => null;
                var res = rig.Run("clipE0000005", rig.ClipPlan());
                T.Has(res.Error, "The game took longer than", "a run past its limit is stopped");
                T.Has(res.Error, "on the slow variant", "on the variant that took it");
                T.Eq(rig.Host.Killed, 1, "and killed");
            }
            // the player starts Death Muffin
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => { rig.Watch.Started = true; return null; };
                var res = rig.Run("clipE0000006", rig.ClipPlan());
                T.Eq(res.Error, "stopped: the game started", "a player's game stops a clip run");
                T.Eq(rig.Api.FailError, "stopped: the game started", "and the server is told");
            }
            // the server refuses a clip
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ClipGame();
                rig.Api.Upload = name => name == "slow_wraith.mp4" ? FakeApi.Err(400, "bad_request", "That clip is not an mp4 video.") : FakeApi.Ok(new Dictionary<string, object>());
                var res = rig.Run("clipE0000007", rig.ClipPlan());
                T.Eq(res.Error, "The server did not take the clip slow_wraith.mp4: That clip is not an mp4 video.", "a refused clip fails the job with the server's words");
                T.Eq(rig.Api.Count("done"), 0, "and done is never sent");
            }
            // a video that cannot be made, and one past the server's limit
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ClipGame();
                rig.Enc.Fail = "ffmpeg ended with code 1: Invalid data found when processing input";
                var res = rig.Run("clipE0000008", rig.ClipPlan());
                T.Eq(res.Error, "The video of the clip pack on the slow variant could not be made: ffmpeg ended with code 1: Invalid data found when processing input", "an encoder failure fails the job, naming the clip and ffmpeg's words");
                T.Eq(rig.Api.Count("upload"), 0, "nothing was uploaded");
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ClipGame();
                rig.Enc.Big = true;
                var res = rig.Run("clipE0000009", rig.ClipPlan());
                T.Eq(res.Error, "The clip slow_pack.mp4 is too big (8 MB).", "a video past the server's 8 MB is refused before it is sent");
                T.Eq(rig.Api.Count("upload"), 0, "and not uploaded");
            }
            // a game build from before 1080p clips records at 30: its note says so, and the video is made at 30
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ClipGame(null, 30);
                T.Ok(rig.Run("clipE0000014", rig.ClipPlan()).Ok && rig.Enc.Calls.All(c => c.EndsWith("@30")), "an older game's clips are made at the rate it recorded: " + string.Join(",", rig.Enc.Calls));
            }
            // the server does not accept the finished job: the clips were uploaded, and no fail follows
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = ClipGame();
                rig.Api.Done = () => FakeApi.Err(400, "bad_request", "The clip slow_wraith could not be turned into a video (the file may be damaged or cut off).");
                var res = rig.Run("clipE0000010", rig.ClipPlan());
                T.Ok(!res.Ok, "a refused done is no success");
                T.Eq(res.Error, "The clips were uploaded, but the server did not accept the finished job: The clip slow_wraith could not be turned into a video (the file may be damaged or cut off).", "the server's reason (the failed transcode) reaches the person");
                T.Eq(rig.Api.Count("fail"), 1, "the app tells the server the job failed, with its reason (the server has already failed it: that answer is a harmless 409)");
                T.Eq(rig.Api.FailError, "The clip slow_wraith could not be turned into a video (the file may be damaged or cut off).", "in the server's words");
                T.Eq(rig.Api.Count("upload"), 4, "all clips had been uploaded");
            }
            // the server cancels the job while the game runs
            using (var rig = new Rig())
            {
                var cts = new CancellationTokenSource();
                rig.Host.Behaviour = (l, dir) => { cts.Cancel(); return null; };
                var res = rig.Run("clipE0000011", rig.ClipPlan(), cancelled: cts.Token);
                T.Ok(res.Cancelled && rig.Api.Count("fail") == 0 && rig.Host.Killed == 1, "a cancel stops the game and tells the server nothing");
            }
            // the app closes: the server is told
            using (var rig = new Rig())
            {
                var cts = new CancellationTokenSource();
                rig.Host.Behaviour = (l, dir) => { cts.Cancel(); return null; };
                var res = rig.Run("clipE0000012", rig.ClipPlan(), ct: cts.Token);
                T.Eq(res.Error, "stopped: the team app was closed", "closing the app stops a clip run");
                T.Eq(rig.Api.FailError, "stopped: the team app was closed", "and tells the server");
            }
            // the game cannot start
            using (var rig = new Rig())
            {
                rig.Host.ThrowOnStart = true;
                var res = rig.Run("clipE0000013", rig.ClipPlan());
                T.Eq(res.Error, "The game could not be started for the slow variant: Access is denied", "a game that cannot start is named by its variant");
            }
        }

        // ---- A screenshots job with two builds ---------------------------------------------------------------------------------------

        static void BuildsHappy()
        {
            using (var rig = new Rig())
            {
                var plan = rig.BuildsPlan();
                var progress = new List<string>();
                string id = "builA0000001";
                var res = rig.Run(id, plan, progress);
                T.Ok(res.Ok, "a before/after job runs to done: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 4, "the game starts once per preset on each build");
                T.Eq(string.Join(",", rig.Api.Uploaded),
                    "before_low_bag-open.png,before_low_hero_view.png,before_ultra_bag-open.png,before_ultra_hero_view.png,after_low_bag-open.png,after_low_hero_view.png,after_ultra_bag-open.png,after_ultra_hero_view.png",
                    "pictures are uploaded as <label>_<preset>_<shot>.png, the before build first");
                T.Eq(string.Join(",", rig.Api.DoneFiles), string.Join(",", rig.Api.Uploaded), "done lists them all");
                var gameBefore = rig.Folders.GameDir(id, "before"); var gameAfter = rig.Folders.GameDir(id, "after");
                T.Ok(gameBefore != gameAfter && Directory.Exists(gameBefore) && Directory.Exists(gameAfter), "each build has its own game folder");
                string[] exes = rig.Host.Launches.Select(l => Path.GetDirectoryName(l.ExePath)).ToArray();
                T.Eq(string.Join("|", exes), string.Join("|", new[] { gameBefore, gameBefore, gameAfter, gameAfter }), "the before build's game runs twice, then the after build's");
                foreach (string dir in new[] { gameBefore, gameAfter })
                    foreach (var f in plan.Files) T.Ok(File.Exists(Path.Combine(dir, f.Name)), "build folder holds " + f.Name);
                T.Ok(!File.ReadAllBytes(Path.Combine(gameBefore, "DeathMuffinDebug.pck")).SequenceEqual(File.ReadAllBytes(Path.Combine(gameAfter, "DeathMuffinDebug.pck"))), "each build has its own code pack");
                T.Ok(File.ReadAllBytes(Path.Combine(gameBefore, "DeathMuffin.assets.pck")).SequenceEqual(File.ReadAllBytes(Path.Combine(gameAfter, "DeathMuffin.assets.pck"))), "and the same art pack");
                var args = rig.Host.Launches.Select(l => ArgOf(l, "--shots")).ToArray();
                T.Eq(string.Join("|", args.Select(a => a.Replace('\\', '/').Substring(a.Replace('\\', '/').IndexOf("/out/") + 5))), "before/low|before/ultra|after/low|after/ultra", "each (build, preset) run has its own picture folder");
                T.Eq(string.Join(",", rig.Host.Launches.Select(l => ArgOf(l, "--preset"))), "low,ultra,low,ultra", "the presets, on each build");
                T.Eq(rig.Host.Launches.Select(l => l.AppData).Distinct().Count(), 4, "four runs, four fresh APPDATA folders");
                T.Ok(rig.Host.Launches[0].AppData.Contains("run-1") && rig.Host.Launches[3].AppData.Contains("run-4"), "run-1 to run-4");
                T.Ok(progress.Any(p => p == "Taking pictures on Low (before build) (1 of 4)") && progress.Any(p => p == "Taking pictures on Ultra (after build) (4 of 4)") && progress.Any(p => p == "Uploading pictures (8 of 8)"), "progress names the build");
                T.Has(rig.Api.DoneLog, "game output (Low (before build))", "the log says which build");
                T.Has(rig.Api.DoneLog, "builds before,after", "and that there are two builds");
                T.Eq(rig.Api.Count("fail"), 0, "no fail call");
            }
        }

        static void BuildsSharing()
        {
            using (var rig = new Rig())
            {
                var plan = rig.BuildsPlan(new[] { "low" });
                string id = "builB0000001";
                T.Ok(rig.Run(id, plan).Ok, "a before/after job runs");
                // the code packs are each build's own; everything else is the same bytes: fetched once
                T.Eq(rig.Srv.HitsFor("/DeathMuffinDebug.pck"), 2, "each build's own code pack is downloaded");
                T.Eq(rig.Srv.HitsFor("/DeathMuffin.assets.pck"), 1, "the art pack both builds share (same checksum) is downloaded once");
                T.Eq(rig.Srv.HitsFor("/DeathMuffinDebug.exe"), 1, "the Godot build both share is downloaded once");
                T.Eq(rig.Srv.HitsFor("/libdmcore.windows.template_release.x86_64.dll"), 1, "the core library both share, with no cache name, is downloaded once too (the same checksum)");
                T.Has(rig.Api.DoneLog, "shared with the before build: DeathMuffin.assets.pck", "the log says the second build shared it");
                T.Has(rig.Api.DoneLog, "shared with the before build: libdmcore", "and the library");
                T.Ok(!rig.Api.DoneLog.Contains("shared with the before build: DeathMuffinDebug.pck"), "but not the code pack, which differs");
                foreach (string build in new[] { "before", "after" })
                    foreach (var f in plan.Builds[build == "before" ? 0 : 1].Files)
                        T.Ok(Hashing.Verify(Path.Combine(rig.Folders.GameDir(id, build), f.Name), f.Bytes, f.Sha256), build + " folder holds a verified " + f.Name);
                T.Ok(Hashing.Verify(Path.Combine(rig.Folders.CacheDir("assets-aaa"), "DeathMuffin.assets.pck"), rig.Art.Length, Util.Sha(rig.Art)), "the art pack is kept in the cache");
                T.Eq(Directory.GetDirectories(rig.Folders.CacheRoot).Length, 2, "two cache folders, not four");
                T.Eq(rig.Links.Count, 5, "the first build links its two cached files, the second links those two and the library it shares");

                // the next job: the cached files are kept, not fetched again; only the packs and the library
                var plan2 = rig.BuildsPlan(new[] { "low" });
                T.Ok(rig.Run("builB0000002", plan2).Ok, "a second before/after job");
                T.Eq(rig.Srv.HitsFor("/DeathMuffin.assets.pck"), 1, "the art pack is not downloaded again");
                T.Eq(rig.Srv.HitsFor("/DeathMuffinDebug.exe"), 1, "nor the Godot build");
            }
            // a before/after job whose builds are the same code pack: it is fetched once
            using (var rig = new Rig())
            {
                var plan = rig.BuildsPlan(new[] { "low" }, p =>
                {
                    var b = (List<object>)p["builds"];
                    var before = (List<object>)((Dictionary<string, object>)b[0])["files"];
                    ((Dictionary<string, object>)b[1])["files"] = new List<object>(before);   // the very same entries (same address)
                });
                string id = "builB0000003";
                T.Ok(rig.Run(id, plan).Ok, "builds that are the same files run");
                T.Eq(rig.Srv.HitsFor("/DeathMuffinDebug.pck"), 1, "files with the same address and checksum are fetched once");
                T.Eq(rig.Host.Launches.Count, 2, "and each build still runs");
            }
        }

        static byte[] PngSized(int w, int h, int seed)
        {
            var b = Util.FakePng(seed);
            b[8] = 0; b[9] = 0; b[10] = 0; b[11] = 13; b[12] = (byte)'I'; b[13] = (byte)'H'; b[14] = (byte)'D'; b[15] = (byte)'R';
            b[16] = (byte)(w >> 24); b[17] = (byte)(w >> 16); b[18] = (byte)(w >> 8); b[19] = (byte)w; b[20] = (byte)(h >> 24); b[21] = (byte)(h >> 16); b[22] = (byte)(h >> 8); b[23] = (byte)h;
            return b;
        }

        static void ResolutionRuns()
        {
            // each preset at each window size, off-screen: <preset>_<w>x<h>_<shot>.png
            using (var rig = new Rig())
            {
                rig.Runner.WindowPosition = w => "-" + (w + 100) + ",0";
                rig.Host.Behaviour = (l, dir) =>
                {
                    string size = l.Args[l.Args.IndexOf("--resolution") + 1];
                    File.WriteAllBytes(Path.Combine(dir, "bag-open.png"), PngSized(int.Parse(size.Split('x')[0]), int.Parse(size.Split('x')[1]), 1));
                    return 0;
                };
                var plan = rig.Plan(new[] { "low", "ultra" }, mutate: p => p["resolutions"] = new List<object> { "1920x1080", "3840x2160" });
                var progress = new List<string>();
                string id = "resA00000001";
                var res = rig.Run(id, plan, progress);
                T.Ok(res.Ok, "a job with window sizes runs to done: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 4, "the game starts once per preset and window size");
                T.Eq(string.Join(",", rig.Api.Uploaded), "low_1920x1080_bag-open.png,low_3840x2160_bag-open.png,ultra_1920x1080_bag-open.png,ultra_3840x2160_bag-open.png", "pictures are uploaded as <preset>_<w>x<h>_<shot>.png");
                var L = rig.Host.Launches;
                string outDir = rig.Folders.OutDir(id);
                T.Eq(string.Join("|", L[1].Args), string.Join("|", plan.CommandArgs("low", rig.Folders.PlanFile(id), Path.Combine(outDir, "low", "3840x2160"), "-3940,0", plan.ScreenSizes[1])), "the second run: Low at 3840x2160, off-screen by its own width");
                T.Eq(string.Join(" ", L[0].Args.Take(8)), "--windowed --resolution 1920x1080 --audio-driver Dummy --position -2020,0 --", "the first at 1920x1080");
                T.Has(string.Join(" ", L[3].Args), "--preset=ultra", "the presets, each at each size");
                T.Eq(L.Select(x => x.AppData).Distinct().Count(), 4, "four runs, four fresh APPDATA folders");
                T.Ok(progress.Contains("Taking pictures on Low at 1920x1080 (1 of 4)") && progress.Contains("Taking pictures on Ultra at 3840x2160 (4 of 4)"), "progress says the size");
                T.Eq(string.Join(",", rig.Api.DoneFiles), string.Join(",", rig.Api.Uploaded), "done lists them");
                T.Eq(rig.Api.Count("fail"), 0, "no fail");
            }
            // pictures the wrong size are noted in the log, and still sent
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => { File.WriteAllBytes(Path.Combine(dir, "bag.png"), PngSized(1936, 1119, 1)); return 0; };
                var res = rig.Run("resA00000002", rig.Plan(new[] { "low" }, mutate: p => p["resolutions"] = new List<object> { "3840x2160" }));
                T.Ok(res.Ok, "done: " + res.Error);
                T.Has(rig.Api.DoneLog, "are 1936x1119, not 3840x2160", "the log says the pictures are not the size asked for");
                T.Eq(string.Join(",", rig.Api.Uploaded), "low_3840x2160_bag.png", "and they are sent");
            }
            // with before/after builds: <build>_<preset>_<w>x<h>_<shot>.png
            using (var rig = new Rig())
            {
                var plan = rig.BuildsPlan(new[] { "low" }, p => p["resolutions"] = new List<object> { "1920x1080", "2560x1440" });
                var res = rig.Run("resA00000003", plan);
                T.Ok(res.Ok, "before/after at two sizes: " + res.Error);
                T.Eq(string.Join(",", rig.Api.Uploaded),
                    "before_low_1920x1080_bag-open.png,before_low_1920x1080_hero_view.png,before_low_2560x1440_bag-open.png,before_low_2560x1440_hero_view.png,after_low_1920x1080_bag-open.png,after_low_1920x1080_hero_view.png,after_low_2560x1440_bag-open.png,after_low_2560x1440_hero_view.png",
                    "pictures are uploaded as <build>_<preset>_<w>x<h>_<shot>.png, the before build first");
                T.Eq(rig.Host.Launches.Count, 4, "each build at each size");
                T.Ok(rig.Host.Launches.Select(l => ArgOf(l, "--shots").Replace('\\', '/')).All(a => a.Contains("/out/before/low/") || a.Contains("/out/after/low/")), "each run has its own folder");
            }
            // more pictures than the server takes: every run keeps the same number of its first pictures
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => { for (int i = 1; i <= 12; i++) File.WriteAllBytes(Path.Combine(dir, "s" + i.ToString("00") + ".png"), Util.FakePng(i)); return 0; };
                var plan = rig.Plan(new[] { "low", "ultra" }, mutate: p => p["resolutions"] = new List<object> { "1920x1080", "2560x1440", "3840x2160", "3440x1440" });
                var res = rig.Run("resA00000004", plan);
                T.Ok(res.Ok, "8 runs of 12 pictures: " + res.Error);
                T.Eq(rig.Api.Uploaded.Count, 40, "at most 40 pictures are sent");
                foreach (string pre in new[] { "low_1920x1080", "low_3440x1440", "ultra_2560x1440", "ultra_3840x2160" })
                    T.Eq(rig.Api.Uploaded.Count(n => n.StartsWith(pre + "_")), 5, "five of " + pre + ": every run keeps its first five, so none loses its pictures to another");
                T.Has(rig.Api.DoneLog, "only the first 5 of each build, preset and window size are sent", "the log says so");
            }
            // without window sizes the names and the window are what they were
            using (var rig = new Rig())
            {
                T.Ok(rig.Run("resA00000005", rig.Plan(new[] { "low" })).Ok, "a job with no window sizes runs");
                T.Eq(string.Join(",", rig.Api.Uploaded), "low_bag-open.png,low_hero_view.png", "pictures are <preset>_<shot>.png");
                T.Eq(rig.Host.Launches[0].Args[2], "1920x1080", "in the 1080p window");
            }
        }

        static void BuildsFailures()
        {
            // too many pictures: the pairs stay pairs
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => { for (int i = 1; i <= 12; i++) File.WriteAllBytes(Path.Combine(dir, "s" + i.ToString("00") + ".png"), Util.FakePng(i)); return 0; };
                var plan = rig.BuildsPlan();
                var res = rig.Run("builC0000001", plan);
                T.Ok(res.Ok, "a job with more than 40 pictures runs: " + res.Error);
                T.Eq(rig.Api.Uploaded.Count, 40, "at most 40 pictures are sent");
                foreach (string pre in new[] { "before_low", "before_ultra", "after_low", "after_ultra" })
                    T.Eq(rig.Api.Uploaded.Count(n => n.StartsWith(pre + "_")), 10, "ten of " + pre + ": the first ten of each, so every picture has its pair");
                T.Ok(rig.Api.Uploaded.Contains("before_low_s10.png") && rig.Api.Uploaded.Contains("after_low_s10.png") && !rig.Api.Uploaded.Contains("after_low_s11.png"), "the same shots of both builds");
                T.Has(rig.Api.DoneLog, "only the first 10 of each build, preset and window size are sent", "the log says so");
            }
            // one build's file does not match its checksum: nothing runs
            using (var rig = new Rig())
            {
                var plan = rig.BuildsPlan(null, p =>
                {
                    var after = (Dictionary<string, object>)((List<object>)p["builds"])[1];
                    var files = (List<object>)after["files"];
                    var pck = (Dictionary<string, object>)files[0];
                    pck["sha256"] = new string('f', 64);   // the file the server hosts does not have this checksum
                });
                var res = rig.Run("builC0000002", plan);
                T.Ok(!res.Ok && rig.Api.Count("fail") == 1, "a file that fails its checksum in the after build fails the job");
                T.Eq(rig.Host.Launches.Count, 0, "before any game starts");
                T.Eq(rig.Api.Count("upload"), 0, "and nothing is uploaded");
            }
            // the second build's game fails: the first build's pictures are not sent
            using (var rig = new Rig())
            {
                int run = 0;
                rig.Host.Behaviour = (l, dir) => { run++; if (run == 3) return 1; File.WriteAllBytes(Path.Combine(dir, "a.png"), Util.FakePng(run)); return 0; };
                var res = rig.Run("builC0000003", rig.BuildsPlan());
                T.Eq(res.Error, "The game stopped with code 1 on Low (after build) before it took every picture.", "the run that failed is named with its build");
                T.Eq(rig.Api.Count("upload"), 0, "nothing of the before build was uploaded either");
            }
            // a run that makes no pictures
            using (var rig = new Rig())
            {
                int run = 0;
                rig.Host.Behaviour = (l, dir) => { run++; if (run != 2) File.WriteAllBytes(Path.Combine(dir, "a.png"), Util.FakePng(run)); return 0; };
                var res = rig.Run("builC0000004", rig.BuildsPlan());
                T.Eq(res.Error, "The game finished on Ultra (before build) but made no pictures.", "a build's run that made nothing is named");
            }
            // the player starts Death Muffin while the files are downloaded
            using (var rig = new Rig())
            {
                rig.Watch.Started = true;
                var res = rig.Run("builC0000005", rig.BuildsPlan());
                T.Eq(res.Error, "stopped: the game started", "a player's game stops a before/after job");
            }
        }
    }
}
