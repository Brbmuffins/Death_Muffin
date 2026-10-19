using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam.Tests
{
    /// <summary>Everything around one job in a folder: a local file server, the stand-in game, the stand-in server routes.</summary>
    sealed class Rig : IDisposable
    {
        public readonly TestServer Srv = new TestServer();
        public readonly string Root = Util.TempDir("runner");
        public readonly TeamFolders Folders;
        public readonly FakeApi Api = new FakeApi();
        public readonly FakeGameHost Host = new FakeGameHost();
        public readonly FakeWatch Watch = new FakeWatch();
        public readonly FakePcProbe Probe = new FakePcProbe();
        public readonly HttpClient Http = new HttpClient();
        public readonly JobRunner Runner;
        public readonly List<string> Links = new List<string>();
        public bool LinkWorks = true;
        public readonly byte[] Art = Util.Blob(120000, 21), Godot = Util.Blob(80000, 22), Dll = Util.Blob(9000, 23), Ffmpeg = Util.Blob(7000, 24);
        public readonly FakeEncoder Enc = new FakeEncoder();
        int n;

        public Rig()
        {
            Folders = new TeamFolders(Root);
            Func<string, string, bool> linker = (link, target) =>
            {
                lock (Links) Links.Add(Path.GetFileName(link));
                if (!LinkWorks) return false;
                File.Copy(target, link, true);   // the real one makes a hard link; a copy is the same to the runner
                return true;
            };
            Runner = new JobRunner(Api, Folders, new FileFetcher(Http) { RetryDelay = TimeSpan.FromMilliseconds(5), StallTimeout = TimeSpan.FromSeconds(10) }, Host, Watch, linker, Probe)
            { PollMs = 5, SampleMs = 1, ApiRetryDelay = TimeSpan.FromMilliseconds(5), Encoder = Enc };
            var enc = Srv.Publish("tools", "ffmpeg.exe", Ffmpeg, "ffmpeg-test");   // the video encoder, from the test server like any job file
            Runner.EncoderFile = new PlanFile { Name = "ffmpeg.exe", Url = new Uri((string)enc["url"]), Sha256 = (string)enc["sha256"], Bytes = Ffmpeg.Length, CacheKey = "ffmpeg-test" };
        }

        /// <summary>A payload for a job: its own main pack, the shared art pack and Godot template under their cache keys.</summary>
        public JobPlan Plan(string[] presets = null, string artKey = "assets-aaa", byte[] art = null, bool publishMain = true, Action<Dictionary<string, object>> mutate = null)
        {
            string folder = "job" + (++n) + "x";
            var files = new List<object>();
            files.Add(publishMain ? Srv.Publish(folder, "DeathMuffinDebug.pck", Util.Blob(5000, 30 + n)) : Program.File_("DeathMuffinDebug.pck", url: Srv.FilesBase + folder + "/DeathMuffinDebug.pck", sha: new string('a', 64), bytes: 10.0));
            files.Add(Srv.Publish(folder, "DeathMuffin.assets.pck", art ?? Art, artKey));
            files.Add(Srv.Publish(folder, "libdmcore.windows.template_release.x86_64.dll", Dll));
            files.Add(Srv.Publish(folder, "DeathMuffinDebug.exe", Godot, "godot-debug-4.7.2"));
            var p = Program.ValidPayload();
            p["files"] = files;
            p["presets"] = (presets ?? new[] { "low", "ultra" }).Cast<object>().ToList();
            if (mutate != null) mutate(p);
            JobPlan plan; string err;
            if (!JobPlan.TryParse(p, Srv.SiteBase, out plan, out err)) throw new InvalidOperationException("test payload refused: " + err);
            return plan;
        }

        /// <summary>A `bench` payload: the release exe and the art pack under cache keys, the job's own pack, the core library, and one setup for each preset.</summary>
        public JobPlan BenchPlan(string[] presets = null, DateTime? expires = null)
        {
            string folder = "bench" + (++n) + "x";
            var files = new List<object>
            {
                Srv.Publish(folder, "DeathMuffin.exe", Godot, "godot-release-4.7.2"),
                Srv.Publish(folder, "DeathMuffin.pck", Util.Blob(5000, 40 + n)),
                Srv.Publish(folder, "DeathMuffin.assets.pck", Art, "assets-aaa"),
                Srv.Publish(folder, "libdmcore.windows.template_release.x86_64.dll", Dll),
            };
            var p = BenchTests.ValidPayload();
            p["files"] = files;
            p["setups"] = (presets ?? new[] { "low", "medium" }).Select(x => (object)BenchTests.Setup(x)).ToList();
            JobPlan plan; string err;
            if (!JobPlan.TryParse(JobPlan.BenchKind, p, Srv.SiteBase, out plan, out err)) throw new InvalidOperationException("test bench payload refused: " + err);
            plan.ExpiresAtUtc = expires;
            return plan;
        }

        /// <summary>A `clip` payload: the shared files as a screenshots job's, the clip plan and two variants (`slow` and `fast`, each with a tune); <paramref name="mutate"/> changes the payload first.</summary>
        public JobPlan ClipPlan(Action<Dictionary<string, object>> mutate = null)
        {
            string folder = "clip" + (++n) + "x";
            var files = new List<object>
            {
                Srv.Publish(folder, "DeathMuffinDebug.pck", Util.Blob(5000, 50 + n)),
                Srv.Publish(folder, "DeathMuffin.assets.pck", Art, "assets-aaa"),
                Srv.Publish(folder, "libdmcore.windows.template_release.x86_64.dll", Dll),
                Srv.Publish(folder, "DeathMuffinDebug.exe", Godot, "godot-debug-4.7.2"),
            };
            var p = ClipTests.ValidPayload();
            p["files"] = files;
            if (mutate != null) mutate(p);
            JobPlan plan; string err;
            if (!JobPlan.TryParse(JobPlan.ClipKind, p, Srv.SiteBase, out plan, out err)) throw new InvalidOperationException("test clip payload refused: " + err);
            return plan;
        }

        /// <summary>
        /// One build's file entries for a `shots` job with two builds: its own code pack, the debug game and the art pack under their cache keys (the same bytes for both builds, each published at its own
        /// address) and the core library (the same bytes, no cache key). <paramref name="packSeed"/> makes the code pack differ between builds.
        /// </summary>
        public List<object> BuildFiles(string label, int packSeed, bool corruptPack = false)
        {
            string folder = "b" + label + (++n) + "x";
            return new List<object>
            {
                Srv.Publish(folder, "DeathMuffinDebug.pck", Util.Blob(5000, packSeed)),
                Srv.Publish(folder, "DeathMuffin.assets.pck", Art, "assets-aaa"),
                Srv.Publish(folder, "libdmcore.windows.template_release.x86_64.dll", Dll),
                Srv.Publish(folder, "DeathMuffinDebug.exe", Godot, "godot-debug-4.7.2"),
            };
        }

        /// <summary>A `shots` payload with a before and an after build (`files` replaced by `builds`), on the given presets.</summary>
        public JobPlan BuildsPlan(string[] presets = null, Action<Dictionary<string, object>> mutate = null)
        {
            var p = Program.ValidPayload();
            p.Remove("files");
            p["builds"] = new List<object>
            {
                new Dictionary<string, object> { { "label", "before" }, { "files", BuildFiles("before", 61) } },
                new Dictionary<string, object> { { "label", "after" }, { "files", BuildFiles("after", 62) } },
            };
            p["presets"] = (presets ?? new[] { "low", "ultra" }).Cast<object>().ToList();
            if (mutate != null) mutate(p);
            JobPlan plan; string err;
            if (!JobPlan.TryParse(p, Srv.SiteBase, out plan, out err)) throw new InvalidOperationException("test builds payload refused: " + err);
            return plan;
        }

        /// <summary>A `release` payload: the release build's files and the debug build's (the art pack, the core library and the code of each, each published at its own address), all six steps, two window sizes with one more UI scale and a 2-minute soak.</summary>
        public JobPlan ReleasePlan(Action<Dictionary<string, object>> mutate = null, DateTime? expires = null)
        {
            var p = ReleaseTests.ValidPayload();
            string folder = "rel" + (++n) + "x";
            p["builds"] = new List<object>
            {
                new Dictionary<string, object> { { "label", "release" }, { "files", new List<object>
                {
                    Srv.Publish(folder, "DeathMuffin.exe", Godot, "godot-release-4.7.2"), Srv.Publish(folder, "DeathMuffin.pck", Util.Blob(5000, 70 + n)),
                    Srv.Publish(folder, "DeathMuffin.assets.pck", Art, "assets-aaa"), Srv.Publish(folder, "libdmcore.windows.template_release.x86_64.dll", Dll),
                } } },
                new Dictionary<string, object> { { "label", "debug" }, { "files", new List<object>
                {
                    Srv.Publish(folder + "d", "DeathMuffinDebug.pck", Util.Blob(5000, 80 + n)), Srv.Publish(folder + "d", "DeathMuffin.assets.pck", Art, "assets-aaa"),
                    Srv.Publish(folder + "d", "libdmcore.windows.template_release.x86_64.dll", Dll), Srv.Publish(folder + "d", "DeathMuffinDebug.exe", Util.Blob(81000, 24), "godot-debug-4.7.2"),
                } } },
            };
            if (mutate != null) mutate(p);
            JobPlan plan; string err;
            if (!JobPlan.TryParse(JobPlan.ReleaseKind, p, Srv.SiteBase, out plan, out err)) throw new InvalidOperationException("test release payload refused: " + err);
            plan.ExpiresAtUtc = expires;
            return plan;
        }

        public string Folder(int job) { return "job" + job + "x"; }

        public RunResult Run(string id, JobPlan plan, List<string> progress = null, CancellationToken? ct = null, CancellationToken? cancelled = null)
        {
            return Util.Wait(Runner.RunAsync(id, plan, (progress ?? new List<string>()).Add, ct ?? CancellationToken.None, cancelled ?? CancellationToken.None));
        }

        public void Dispose() { Srv.Dispose(); Http.Dispose(); Util.Rm(Root); }
    }

    static class RunnerTests
    {
        static string Names(IEnumerable<string> l) { return string.Join(",", l); }

        public static void Run()
        {
            HappyPath();
            CacheReuse();
            Failures();
            Limits();
            FreshRunFolders();
            Windows();
            BenchHappy();
            ClipTests.RunnerRuns();
            ReleaseTests.RunnerRuns();
            BenchDisturbed();
            BenchQuietWait();
            BenchFailures();
        }

        static void HappyPath()
        {
            using (var rig = new Rig())
            {
                var plan = rig.Plan();
                var progress = new List<string>();
                string id = "jobA00000001";
                var res = rig.Run(id, plan, progress);
                T.Ok(res.Ok, "a job runs to done: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 2, "the game starts once per preset");
                var low = rig.Host.Launches[0];
                string game = rig.Folders.GameDir(id);
                T.Eq(low.ExePath, Path.Combine(game, "DeathMuffinDebug.exe"), "the debug build in the job's game folder is started");
                T.Eq(low.WorkingDir, game, "the game starts in its folder");
                T.Eq(string.Join("|", low.Args), string.Join("|", plan.CommandArgs("low", rig.Folders.PlanFile(id), Path.Combine(rig.Folders.OutDir(id), "low"))), "the game's arguments are the contract's, for low");
                T.Eq(string.Join("|", rig.Host.Launches[1].Args), string.Join("|", plan.CommandArgs("ultra", rig.Folders.PlanFile(id), Path.Combine(rig.Folders.OutDir(id), "ultra"))), "and for ultra");
                T.Has(string.Join(" ", low.Args), "--preset=low", "the preset is passed");
                T.Has(string.Join(" ", rig.Host.Launches[1].Args), "--preset=ultra", "the second preset is passed");
                T.Ok(low.AppData.StartsWith(rig.Folders.JobDir(id)) && low.LocalAppData.StartsWith(rig.Folders.JobDir(id)) && low.AppData != low.LocalAppData, "APPDATA and LOCALAPPDATA point into the job's own folder");
                T.Ok(Directory.Exists(low.AppData) && Directory.Exists(low.LocalAppData), "those folders exist");
                T.Ok(File.ReadAllText(rig.Folders.PlanFile(id)) == plan.PlanJson, "plan.json holds the proposal's plan");
                foreach (var f in plan.Files) T.Ok(Hashing.Verify(Path.Combine(game, f.Name), f.Bytes, f.Sha256), "game folder holds a verified " + f.Name);
                T.Ok(Hashing.Verify(Path.Combine(rig.Folders.CacheDir("assets-aaa"), "DeathMuffin.assets.pck"), rig.Art.Length, Util.Sha(rig.Art)), "the art pack is kept in cache\\assets-aaa");
                T.Ok(Hashing.Verify(Path.Combine(rig.Folders.CacheDir("godot-debug-4.7.2"), "DeathMuffinDebug.exe"), rig.Godot.Length, Util.Sha(rig.Godot)), "the Godot template is kept in its cache folder");
                T.Ok(!Directory.Exists(Path.Combine(rig.Folders.CacheRoot, "none")) && Directory.GetDirectories(rig.Folders.CacheRoot).Length == 2, "only cacheKey files are cached");
                T.Eq(Names(rig.Api.Uploaded), "low_bag-open.png,low_hero_view.png,ultra_bag-open.png,ultra_hero_view.png", "pictures are uploaded as <preset>_<shot>.png");
                T.Ok(rig.Api.UploadedBytes["ultra_bag-open.png"].SequenceEqual(Util.FakePng(1)), "uploaded bytes are the game's picture");
                T.Eq(Names(rig.Api.DoneFiles), Names(rig.Api.Uploaded), "done lists every uploaded picture");
                T.Eq(rig.Api.DoneJob, id, "done names the job");
                T.Ok(rig.Api.Count("fail") == 0, "no fail call");
                int lastUpload = rig.Api.Calls.FindLastIndex(c => c.StartsWith("upload")), doneAt = rig.Api.Calls.FindIndex(c => c.StartsWith("done"));
                T.Ok(lastUpload >= 0 && doneAt > lastUpload, "done comes after the last upload");
                T.Has(rig.Api.DoneLog, "game output (Low)", "the log carries the game's output");
                T.Has(rig.Api.DoneLog, "QA-SHOTS fake game output", "with its lines");
                T.Has(rig.Api.DoneLog, "downloaded DeathMuffin.assets.pck", "and what was downloaded");
                T.Ok(rig.Api.DoneDownloadS >= 0 && rig.Api.DoneRunS >= 0, "timings are reported");
                T.Eq(res.Files.Count, 4, "the result lists the files");
                T.Ok(progress.Any(p => p.StartsWith("Downloading DeathMuffinDebug.pck")) && progress.Any(p => p == "Taking pictures on Low (1 of 2)") && progress.Any(p => p == "Taking pictures on Ultra (2 of 2)") && progress.Any(p => p == "Uploading pictures (4 of 4)"), "progress tells what is happening");
                T.Eq(rig.Watch.Begins, 1, "the player's games are noted once, when the job starts");
                T.Ok(File.Exists(rig.Folders.LogFile(id)) && File.ReadAllText(rig.Folders.LogFile(id)).Contains("finished: 4 picture(s)"), "job.log is written");
                T.Eq(rig.Links.Count, 2, "the cached files are linked into the game folder");
                T.Eq(Names(rig.Links.OrderBy(x => x)), "DeathMuffin.assets.pck,DeathMuffinDebug.exe", "exactly the two cached files");
            }
        }

        static void CacheReuse()
        {
            using (var rig = new Rig())
            {
                var plan1 = rig.Plan();
                T.Ok(rig.Run("jobB00000001", plan1).Ok, "first job");
                var plan2 = rig.Plan();   // a new job: its own main pack and URLs, the same art pack and Godot under the same keys
                T.Ok(rig.Run("jobB00000002", plan2).Ok, "second job");
                T.Eq(rig.Srv.HitsFor(rig.Folder(2) + "/DeathMuffin.assets.pck"), 0, "the second job does not download the art pack again");
                T.Eq(rig.Srv.HitsFor(rig.Folder(2) + "/DeathMuffinDebug.exe"), 0, "nor the Godot template");
                T.Eq(rig.Srv.HitsFor(rig.Folder(2) + "/DeathMuffinDebug.pck"), 1, "but the main pack, which is the job's own");
                T.Eq(rig.Srv.HitsFor(rig.Folder(2) + "/libdmcore"), 1, "and the core library");
                T.Ok(Hashing.Verify(Path.Combine(rig.Folders.GameDir("jobB00000002"), "DeathMuffin.assets.pck"), rig.Art.Length, Util.Sha(rig.Art)), "the reused art pack is in the second job's game folder");
                T.Has(rig.Api.DoneLog, "kept from an earlier job: DeathMuffin.assets.pck", "the log says it was reused");

                // a damaged cache file is downloaded again
                File.WriteAllBytes(Path.Combine(rig.Folders.CacheDir("assets-aaa"), "DeathMuffin.assets.pck"), Util.Blob(rig.Art.Length, 77));
                var plan3 = rig.Plan();
                T.Ok(rig.Run("jobB00000003", plan3).Ok, "third job");
                T.Eq(rig.Srv.HitsFor(rig.Folder(3) + "/DeathMuffin.assets.pck"), 1, "a cached file that fails its checksum is downloaded again");
                T.Ok(Hashing.Verify(Path.Combine(rig.Folders.CacheDir("assets-aaa"), "DeathMuffin.assets.pck"), rig.Art.Length, Util.Sha(rig.Art)), "and the cache is repaired");

                // a new art pack under a new key sits beside the old one
                byte[] art2 = Util.Blob(90000, 55);
                var plan4 = rig.Plan(artKey: "assets-bbb", art: art2);
                T.Ok(rig.Run("jobB00000004", plan4).Ok, "fourth job with new art");
                T.Ok(Directory.Exists(rig.Folders.CacheDir("assets-aaa")) && Directory.Exists(rig.Folders.CacheDir("assets-bbb")), "old and new cache keys are both kept (up to 4 keys)");
                T.Ok(Hashing.Verify(Path.Combine(rig.Folders.GameDir("jobB00000004"), "DeathMuffin.assets.pck"), art2.Length, Util.Sha(art2)), "the new art pack is the one in the game folder");

                // old job folders go: 4 jobs ran, the last 3 stay
                T.Eq(Directory.GetDirectories(rig.Folders.JobsRoot).Length, 3, "only the last 3 job folders are kept");
                T.Ok(!Directory.Exists(rig.Folders.JobDir("jobB00000001")) && Directory.Exists(rig.Folders.JobDir("jobB00000004")), "the oldest job folder is the one removed");
            }
            using (var rig = new Rig())
            {
                rig.LinkWorks = false;
                var plan = rig.Plan();
                T.Ok(rig.Run("jobC00000001", plan).Ok, "a job runs when hard links are not possible");
                T.Ok(Hashing.Verify(Path.Combine(rig.Folders.GameDir("jobC00000001"), "DeathMuffin.assets.pck"), rig.Art.Length, Util.Sha(rig.Art)), "the file is copied instead");
            }
            using (var rig = new Rig())
            {
                var plan = rig.Plan();
                // the same job id run twice (the server put it back): files already in place are not downloaded again
                T.Ok(rig.Run("jobD00000001", plan).Ok, "a job");
                int hits = rig.Srv.HitsFor("/DeathMuffinDebug.pck");
                T.Ok(rig.Run("jobD00000001", plan).Ok, "the same job again");
                T.Eq(rig.Srv.HitsFor("/DeathMuffinDebug.pck"), hits, "files already in the job's folder are kept");
            }
        }

        static void Failures()
        {
            using (var rig = new Rig())
            {
                // the game stops with an error after the first picture
                rig.Host.Behaviour = (l, dir) => { File.WriteAllBytes(Path.Combine(dir, "a.png"), Util.FakePng(1)); return 1; };
                var res = rig.Run("jobF00000001", rig.Plan());
                T.Ok(!res.Ok, "exit code 1 fails the job");
                T.Eq(res.Error, "The game stopped with code 1 on Low before it took every picture.", "readable error for a bad exit code");
                T.Eq(rig.Api.FailError, res.Error, "the server is told the same");
                T.Has(rig.Api.FailLog, "game output (Low)", "the fail call carries the game's log");
                T.Eq(rig.Api.Count("done"), 0, "no done after a failure");
                T.Eq(rig.Api.Uploaded.Count, 0, "nothing is uploaded after a failure");
                T.Eq(rig.Host.Launches.Count, 1, "the second preset is not run");
                T.Eq(rig.Api.FailJob, "jobF00000001", "fail names the job");
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => 0;
                var res = rig.Run("jobF00000002", rig.Plan());
                T.Eq(res.Error, "The game finished on Low but made no pictures.", "no pictures is a failure");
                T.Eq(rig.Api.Count("fail"), 1, "fail is called once");
            }
            using (var rig = new Rig())
            {
                // pictures left in the folder by an earlier try do not count
                string stale = Path.Combine(rig.Folders.OutDir("jobF00000003"), "low");
                Directory.CreateDirectory(stale);
                File.WriteAllBytes(Path.Combine(stale, "old.png"), Util.FakePng(5));
                rig.Host.Behaviour = (l, dir) => 0;
                var res = rig.Run("jobF00000003", rig.Plan());
                T.Eq(res.Error, "The game finished on Low but made no pictures.", "stale pictures are removed before a run");
            }
            using (var rig = new Rig())
            {
                // Godot's own log is added when the game fails
                rig.Host.Behaviour = (l, dir) =>
                {
                    string logs = Path.Combine(l.AppData, "Godot", "app_userdata", "Death Muffin", "logs");
                    Directory.CreateDirectory(logs);
                    File.WriteAllText(Path.Combine(logs, "godot.log"), "ERROR: shader failed to compile");
                    return 1;
                };
                rig.Run("jobF00000004", rig.Plan());
                T.Has(rig.Api.FailLog, "Godot's log (godot.log)", "Godot's own log is in the fail log");
                T.Has(rig.Api.FailLog, "shader failed to compile", "with its lines");
            }
            using (var rig = new Rig())
            {
                rig.Host.ThrowOnStart = true;
                var res = rig.Run("jobF00000005", rig.Plan());
                T.Eq(res.Error, "The game could not be started for Low: Access is denied", "a game that cannot start says so");
            }
            using (var rig = new Rig())
            {
                // a file that is not on the server
                var res = rig.Run("jobF00000006", rig.Plan(publishMain: false));
                T.Ok(!res.Ok && res.Error.Contains("Could not download DeathMuffinDebug.pck") && res.Error.Contains("HTTP 404"), "a missing download fails readably: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 0, "the game does not start without its files");
                T.Eq(rig.Api.Count("fail"), 1, "fail is called for a failed download");
            }
            using (var rig = new Rig())
            {
                rig.Srv.AlwaysCorrupt = true;
                var res = rig.Run("jobF00000007", rig.Plan());
                T.Ok(!res.Ok && res.Error.Contains("checksum"), "a file that never matches its checksum fails: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 0, "the game does not start on a file that failed its checksum");
            }
            using (var rig = new Rig())
            {
                rig.Api.Upload = name => FakeApi.Err(400, "bad_png", "The picture is not a valid PNG.");
                var res = rig.Run("jobF00000008", rig.Plan());
                T.Eq(res.Error, "The server did not take the picture low_bag-open.png: The picture is not a valid PNG.", "a rejected picture fails the job with the server's words");
                T.Eq(rig.Api.Count("upload"), 1, "a 400 is not retried");
                T.Eq(rig.Api.Count("done"), 0, "no done after a rejected upload");
            }
            using (var rig = new Rig())
            {
                int tries = 0;
                rig.Api.Upload = name => ++tries == 1 ? FakeApi.Err(503, "unavailable", "busy") : FakeApi.Ok(new Dictionary<string, object>());
                var res = rig.Run("jobF00000009", rig.Plan(new[] { "low" }));
                T.Ok(res.Ok && rig.Api.Uploaded.Count == 2, "an upload that gets a 503 once is retried: " + res.Error);
                int nets = 0;
                rig.Api.Upload = name => ++nets == 1 ? FakeApi.NetErr() : FakeApi.Ok(new Dictionary<string, object>());
                res = rig.Run("jobF00000010", rig.Plan(new[] { "low" }));
                T.Ok(res.Ok, "an upload that gets no answer once is retried: " + res.Error);
            }
            using (var rig = new Rig())
            {
                rig.Api.Upload = name => FakeApi.Err(500, "", "boom");
                var res = rig.Run("jobF00000011", rig.Plan(new[] { "low" }));
                T.Ok(!res.Ok && rig.Api.Count("upload") == 3 && res.Error.Contains("boom"), "an upload that keeps failing stops after 3 tries");
            }
            using (var rig = new Rig())
            {
                // done itself is refused: the pictures are up, and the server is told the job failed, in its own words (a job the app leaves "running" would be kept alive by its heartbeat for ever)
                rig.Api.Done = () => FakeApi.Err(409, "", "This job is not running any more.");
                var res = rig.Run("jobF00000012", rig.Plan(new[] { "low" }));
                T.Ok(!res.Ok && res.Error.Contains("did not accept the finished job") && res.Error.Contains("not running any more"), "a refused done is reported");
                T.Eq(rig.Api.Count("fail"), 1, "the job is failed with the server's reason, so it never stays running");
                T.Eq(rig.Api.FailError, "This job is not running any more.", "the reason is the server's own");
                T.Has(rig.Api.FailLog, "uploaded low_", "and the log goes with it");
            }
            using (var rig = new Rig())
            {
                rig.Api.Fail = () => FakeApi.NetErr();
                rig.Host.Behaviour = (l, dir) => 1;
                var res = rig.Run("jobF00000013", rig.Plan());
                T.Ok(!res.Ok && res.Error.Length > 0, "a fail call that cannot be sent does not throw");
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => { File.WriteAllBytes(Path.Combine(dir, "empty.png"), new byte[0]); return 0; };
                var res = rig.Run("jobF00000014", rig.Plan());
                T.Ok(!res.Ok && res.Error.Contains("empty"), "an empty picture fails the job: " + res.Error);
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => { File.WriteAllBytes(Path.Combine(dir, "huge.png"), new byte[JobPlan.MaxUploadBytes + 1]); return 0; };
                var res = rig.Run("jobF00000015", rig.Plan(new[] { "low" }));
                T.Ok(!res.Ok && res.Error.Contains("too big"), "a picture over the server's limit fails a screenshot job: " + res.Error);
                T.Eq(JobPlan.MaxUploadBytes, 20 << 20, "the limit is the server's: 20 MB a picture");
            }
        }

        static void Limits()
        {
            using (var rig = new Rig())
            {
                // a game that never ends is stopped at the limit
                rig.Runner.RunLimit = TimeSpan.FromMilliseconds(250);
                rig.Host.Behaviour = (l, dir) => null;
                var res = rig.Run("jobL00000001", rig.Plan());
                T.Ok(!res.Ok && res.Error == "The game took longer than 1 second on Low and was stopped.", "a game over the time limit fails: " + res.Error);
                T.Eq(rig.Host.Killed, 1, "and is killed");
            }
            using (var rig = new Rig())
            {
                // the player starts Death Muffin while the game runs
                rig.Host.Behaviour = (l, dir) => { new Timer2(150, () => rig.Watch.Started = true); return null; };
                var res = rig.Run("jobL00000002", rig.Plan());
                T.Eq(res.Error, "stopped: the game started", "the job stops when the player starts Death Muffin");
                T.Eq(rig.Api.FailError, "stopped: the game started", "and the server is told exactly that");
                T.Eq(rig.Host.Killed, 1, "the job's game is killed");
                T.Eq(rig.Api.Count("upload"), 0, "nothing is uploaded");
            }
            using (var rig = new Rig())
            {
                // started before the first file: nothing is downloaded, nothing starts
                rig.Watch.Started = true;
                var res = rig.Run("jobL00000003", rig.Plan());
                T.Eq(res.Error, "stopped: the game started", "a game started before the job's files are fetched stops it too");
                T.Eq(rig.Host.Launches.Count, 0, "the job's game never starts");
                T.Eq(rig.Srv.HitsFor("DeathMuffinDebug.pck"), 0, "and nothing is downloaded");
            }
            using (var rig = new Rig())
            {
                // between presets
                rig.Host.Behaviour = (l, dir) => { File.WriteAllBytes(Path.Combine(dir, "a.png"), Util.FakePng(1)); if (FakeGameHost.Preset(l) == "low") rig.Watch.Started = true; return 0; };
                var res = rig.Run("jobL00000004", rig.Plan());
                T.Eq(res.Error, "stopped: the game started", "a game started between the presets stops the job");
                T.Eq(rig.Host.Launches.Count, 1, "the second preset does not start");
            }
            using (var rig = new Rig())
            {
                // the app closes
                var cts = new CancellationTokenSource();
                rig.Host.Behaviour = (l, dir) => { new Timer2(100, () => cts.Cancel()); return null; };
                var res = rig.Run("jobL00000005", rig.Plan(), null, cts.Token);
                T.Eq(res.Error, "stopped: the team app was closed", "closing the app stops the job");
                T.Eq(rig.Api.FailError, "stopped: the team app was closed", "and tells the server");
                T.Eq(rig.Host.Killed, 1, "the game is killed");
            }
            using (var rig = new Rig())
            {
                // more pictures than the server keeps
                rig.Host.Behaviour = (l, dir) => { for (int i = 0; i < 30; i++) File.WriteAllBytes(Path.Combine(dir, "shot" + i.ToString("00") + ".png"), Util.FakePng(i)); return 0; };
                var res = rig.Run("jobL00000006", rig.Plan());
                T.Ok(res.Ok && rig.Api.Uploaded.Count == 40, "at most 40 pictures are sent: " + rig.Api.Uploaded.Count);
                T.Has(rig.Api.DoneLog, "only the first 40", "and the log says so");
            }
            using (var rig = new Rig())
            {
                // a picture name that collides after cleaning
                rig.Host.Behaviour = (l, dir) => { File.WriteAllBytes(Path.Combine(dir, "Hero View.png"), Util.FakePng(1)); File.WriteAllBytes(Path.Combine(dir, "hero_view.png"), Util.FakePng(2)); File.WriteAllText(Path.Combine(dir, "notes.txt"), "x"); return 0; };
                var res = rig.Run("jobL00000007", rig.Plan(new[] { "high" }));
                T.Ok(res.Ok && Names(rig.Api.Uploaded.OrderBy(x => x)) == "high_hero_view-2.png,high_hero_view.png", "colliding picture names stay unique, other files are skipped: " + Names(rig.Api.Uploaded));
            }
        }

        // ---- A run of its own: fresh APPDATA and LOCALAPPDATA ---------------------------------------------------------------------------

        static string Entries(string dir) { return string.Join(",", Directory.GetFileSystemEntries(dir).Select(Path.GetFileName).OrderBy(x => x)); }

        static void FreshRunFolders()
        {
            using (var rig = new Rig())
            {
                // Low's offline save must not be Ultra's start (the bag was 23 items instead of 16 on a real PC: the shot plan's `give` ran twice)
                var saw = new List<string>();
                rig.Host.Behaviour = (l, dir) =>
                {
                    saw.Add(Entries(l.AppData) + "|" + Entries(l.LocalAppData));
                    File.WriteAllText(Path.Combine(l.AppData, "save.json"), "offline save of " + FakeGameHost.Preset(l));
                    File.WriteAllText(Path.Combine(l.LocalAppData, "cache.bin"), "x");
                    File.WriteAllBytes(Path.Combine(dir, "a.png"), Util.FakePng(1));
                    return 0;
                };
                var plan = rig.Plan(new[] { "low", "ultra", "high" });
                var res = rig.Run("jobR00000001", plan);
                T.Ok(res.Ok, "three presets run: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 3, "one game a preset");
                T.Eq(string.Join(";", saw), "|;|;|", "every run starts with empty APPDATA and LOCALAPPDATA");
                var l0 = rig.Host.Launches;
                T.Ok(l0.Select(l => l.AppData).Distinct().Count() == 3 && l0.Select(l => l.LocalAppData).Distinct().Count() == 3, "each run has its own pair of folders");
                T.Ok(l0.All(l => l.AppData.StartsWith(rig.Folders.JobDir("jobR00000001")) && l.LocalAppData.StartsWith(rig.Folders.JobDir("jobR00000001"))), "under the job's folder");
                T.Eq(File.ReadAllText(Path.Combine(l0[0].AppData, "save.json")), "offline save of low", "the first run's save is still its own");
                T.Eq(l0[1].AppData, rig.Folders.AppDataDir("jobR00000001", 2), "the second preset is run 2");
                T.Eq(l0[2].LocalAppData, rig.Folders.LocalAppDataDir("jobR00000001", 3), "the third is run 3");

                // the same job again (the server put it back): nothing is left over from the first time
                saw.Clear();
                T.Ok(rig.Run("jobR00000001", plan).Ok, "the same job again");
                T.Eq(string.Join(";", saw), "|;|;|", "the second time starts empty too");
            }
        }

        // ---- The `bench` job ------------------------------------------------------------------------------------------------------------

        /// <summary>What the game leaves in its `--bench-dir`: the queue with one run.</summary>
        static void WriteRun(string dir, string id, string preset, bool cancelled = false)
        {
            File.WriteAllText(Path.Combine(dir, "pending.json"),
                "[{\"clientRunId\":\"" + id + "\",\"preset\":\"" + preset + "\",\"cancelled\":" + (cancelled ? "true" : "false") + ",\"standard\":false,\"metrics\":{\"avg_fps\":" + (preset == "low" ? "144.5" : "97") + "},\"report\":\"ok\"}]");
        }

        static void Windows()
        {
            using (var rig = new Rig())
            {
                // a screenshot job's window is started outside every monitor, and silent
                rig.Runner.ShotsPosition = () => "-3620,-200";
                var res = rig.Run("jobW00000001", rig.Plan());
                T.Ok(res.Ok, "a job with a window position runs: " + res.Error);
                foreach (var l in rig.Host.Launches)
                {
                    int sep = l.Args.IndexOf("--");
                    T.Eq(string.Join(" ", l.Args.Take(sep)), "--windowed --resolution 1920x1080 --audio-driver Dummy --position -3620,-200", "each screenshot run: windowed at 1080p, silent, off every monitor, all ahead of --");
                    T.Ok(!l.Args.Skip(sep).Any(a => a.StartsWith("--position") || a.StartsWith("--audio-driver")), "and nothing of it is passed after --");
                }
            }
            using (var rig = new Rig())
            {
                // the position is asked for at each run (monitors come and go)
                int asked = 0;
                rig.Runner.ShotsPosition = () => "-" + (1700 + ++asked * 10) + ",0";
                rig.Run("jobW00000002", rig.Plan(new[] { "low", "ultra" }));
                T.Eq(string.Join(";", rig.Host.Launches.Select(l => l.Args[l.Args.IndexOf("--position") + 1])), "-1710,0;-1720,0", "the position is worked out again for each run");
            }
            using (var rig = new Rig())
            {
                // a 1080p picture window (the default since 0.4.7) gets a spot left of every monitor by its own 1920 px
                var widths = new List<int>();
                rig.Runner.WindowPosition = w => { widths.Add(w); return "-2020,0"; };
                rig.Run("jobW00000006", rig.Plan(new[] { "low" }));
                T.Ok(widths.SequenceEqual(new[] { 1920 }) && rig.Host.Launches[0].Args.Contains("-2020,0") && rig.Host.Launches[0].Args.Last() == "--qa-window=1920x1080", "a 1920-wide spot, and the game sizes its window to 1920x1080");
            }
            using (var rig = new Rig())
            {
                rig.Run("jobW00000003", rig.Plan(new[] { "low" }));
                var args = rig.Host.Launches[0].Args;
                T.Ok(!args.Contains("--position") && string.Join(" ", args.Take(5)) == "--windowed --resolution 1920x1080 --audio-driver Dummy", "without a position source the window is left to Godot, still silent");
            }
            using (var rig = new Rig())
            {
                // a benchmark's window stays on screen, whatever the screenshot jobs do; it is silent too
                rig.Runner.ShotsPosition = () => "-3620,-200";
                rig.Host.Behaviour = (l, dir) => { WriteRun(dir, "r", "low"); return 0; };
                var res = rig.Run("jobW00000004", rig.BenchPlan(new[] { "low" }));
                var args = rig.Host.Launches[0].Args;
                T.Ok(res.Ok && !args.Contains("--position") && string.Join(" ", args.Take(3)) == "--fullscreen --audio-driver Dummy", "a benchmark's window is full screen, not off screen, and silent: " + res.Error);
            }
        }

        static void BenchHappy()
        {
            using (var rig = new Rig())
            {
                var plan = rig.BenchPlan();
                var readsAtStart = new List<int>();
                var saw = new List<string>();
                rig.Host.Behaviour = (l, dir) =>
                {
                    readsAtStart.Add(rig.Probe.Reads);
                    saw.Add(Entries(l.AppData) + "|" + Entries(dir));
                    File.WriteAllText(Path.Combine(l.AppData, "save.json"), "x");
                    WriteRun(dir, "r-" + FakeGameHost.Preset(l), FakeGameHost.Preset(l));
                    return 0;
                };
                var progress = new List<string>();
                string id = "benchA0000001";
                var res = rig.Run(id, plan, progress);
                T.Ok(res.Ok, "a bench job runs to done: " + res.Error);
                T.Eq(res.Runs, 2, "two runs are reported");
                T.Eq(rig.Host.Launches.Count, 2, "the game starts once per setup");
                string game = rig.Folders.GameDir(id);
                var first = rig.Host.Launches[0];
                T.Eq(first.ExePath, Path.Combine(game, "DeathMuffin.exe"), "the release exe in the job's game folder is started");
                T.Eq(first.WorkingDir, game, "in its folder");
                T.Eq(string.Join("|", first.Args), string.Join("|", plan.BenchCommandArgs(plan.Setups[0], rig.Folders.BenchDir(id, 1))), "the arguments are the contract's, for setup 1");
                T.Eq(string.Join("|", rig.Host.Launches[1].Args), string.Join("|", plan.BenchCommandArgs(plan.Setups[1], rig.Folders.BenchDir(id, 2))), "and for setup 2, in its own folder");
                T.Has(string.Join(" ", rig.Host.Launches[1].Args), "--bench-preset=medium", "the second setup is Medium");
                T.Ok(!string.Join(" ", first.Args).Contains("--main-pack"), "no --main-pack");
                T.Eq(first.Priority, ProcessPriorityClass.Normal, "a benchmark runs at normal priority");
                T.Eq(rig.Host.Launches[1].Priority, ProcessPriorityClass.Normal, "every setup does");
                T.Ok(first.AppData.StartsWith(rig.Folders.JobDir(id)) && first.AppData != first.LocalAppData && first.AppData != rig.Host.Launches[1].AppData, "APPDATA and LOCALAPPDATA are in the job's folder, a pair for each run");
                T.Eq(string.Join(";", saw), "|;|", "each run starts with empty APPDATA and an empty --bench-dir");
                T.Ok(readsAtStart[0] >= 60 && readsAtStart[1] - readsAtStart[0] >= 60, "the PC was read for a quiet minute before each setup (" + string.Join(",", readsAtStart) + " readings)");
                T.Ok(rig.Probe.Pids.Take(60).All(p => p == 0), "while waiting no game runs");
                foreach (var f in plan.Files) T.Ok(Hashing.Verify(Path.Combine(game, f.Name), f.Bytes, f.Sha256), "game folder holds a verified " + f.Name);
                T.Eq(Directory.GetDirectories(rig.Folders.CacheRoot).Length, 2, "the release exe and the art pack are cached");
                T.Eq(string.Join(",", rig.Links.OrderBy(x => x)), "DeathMuffin.assets.pck,DeathMuffin.exe", "and linked into the game folder");
                T.Eq(rig.Api.DoneJob, id, "done names the job");
                T.Eq(rig.Api.DoneRuns.Count, 2, "done carries both runs");
                T.Eq(MiniJson.Str(rig.Api.DoneRuns[0], "clientRunId") + "," + MiniJson.Str(rig.Api.DoneRuns[1], "clientRunId"), "r-low,r-medium", "in setup order");
                T.Eq((double)MiniJson.Obj(rig.Api.DoneRuns[0], "metrics")["avg_fps"], 144.5, "with the game's numbers");
                T.Eq(rig.Api.DoneFiles.Count, 0, "no pictures");
                T.Eq(rig.Api.Count("upload") + rig.Api.Count("fail"), 0, "nothing uploaded, nothing failed");
                T.Has(rig.Api.DoneLog, "start Low: DeathMuffin.exe --fullscreen --audio-driver Dummy -- --benchmark", "the log has the command");
                T.Has(rig.Api.DoneLog, "finished: 2 run(s)", "and the end");
                T.Has(rig.Api.DoneLog, "the PC is quiet", "and that the PC was quiet");
                T.Ok(rig.Api.DoneDownloadS >= 0 && rig.Api.DoneRunS >= 0, "timings are reported");
                T.Ok(progress.Any(p => p.StartsWith("Waiting for a quiet PC: watching the PC for a quiet minute")), "progress says it is waiting for a quiet minute");
                T.Ok(progress.Contains("Benchmark on Low (1 of 2)") && progress.Contains("Benchmark on Medium (2 of 2)") && progress.Contains("Done: 2 benchmark run(s) sent"), "and what it is running");
                T.Ok(File.Exists(rig.Folders.LogFile(id)) && File.ReadAllText(rig.Folders.LogFile(id)).Contains("finished: 2 run(s)"), "job.log is written");
                T.Ok(File.Exists(Path.Combine(rig.Folders.BenchDir(id, 2), "pending.json")), "the runs stay in their folders");
            }
            using (var rig = new Rig())
            {
                // the queue may hold older runs: the last entry is the one just made
                rig.Host.Behaviour = (l, dir) => { File.WriteAllText(Path.Combine(dir, "pending.json"), "[{\"clientRunId\":\"old\"},{\"clientRunId\":\"new\"}]"); return 0; };
                T.Ok(rig.Run("benchA0000002", rig.BenchPlan(new[] { "ultra" })).Ok && rig.Api.DoneRuns.Count == 1 && MiniJson.Str(rig.Api.DoneRuns[0], "clientRunId") == "new", "the last entry of pending.json is the run");
            }
            using (var rig = new Rig())
            {
                // a shots job still runs below normal priority
                T.Ok(rig.Run("benchA0000003", rig.Plan(new[] { "low" })).Ok && rig.Host.Launches[0].Priority == ProcessPriorityClass.BelowNormal, "a screenshot job's game runs below normal priority");
            }
            using (var rig = new Rig())
            {
                // done does not get through the first time
                int tries = 0;
                rig.Host.Behaviour = (l, dir) => { WriteRun(dir, "r", "low"); return 0; };
                rig.Api.Done = () => ++tries == 1 ? FakeApi.Err(503, "unavailable", "busy") : FakeApi.Ok(new Dictionary<string, object>());
                var res = rig.Run("benchA0000004", rig.BenchPlan(new[] { "low" }));
                T.Ok(res.Ok && tries == 2 && rig.Host.Launches.Count == 1, "a done that gets a 503 once is sent again, and the benchmark is not run again: " + res.Error);
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => { WriteRun(dir, "r", "low"); return 0; };
                rig.Api.Done = () => FakeApi.Err(400, "bad_request", "The run of Low is not valid: its numbers are missing.");
                var res = rig.Run("benchA0000005", rig.BenchPlan(new[] { "low" }));
                T.Ok(!res.Ok && res.Error == "The benchmark ran, but the server did not accept the results: The run of Low is not valid: its numbers are missing.", "a refused done says why: " + res.Error);
                T.Eq(rig.Api.Count("fail"), 1, "the job is failed with the server's reason (a server that already failed it answers 409, harmlessly)");
                T.Eq(rig.Api.FailError, "The run of Low is not valid: its numbers are missing.", "the reason is the server's own");
            }
        }

        static void BenchDisturbed()
        {
            // the player starts Death Muffin during the first run: the run is thrown away with its folders, the PC is waited on again, and the retry is the result
            using (var rig = new Rig())
            {
                var saw = new List<string>();
                var readsAtStart = new List<int>();
                int gameReads = 0;
                rig.Probe.Script = (n, t, pid) =>
                {
                    bool player = pid > 0 && rig.Host.Launches.Count == 1 && ++gameReads >= 3;   // started during the first run, and it stays open
                    return new PcSample { CpuTotal = 3 + (pid > 0 ? 40 : 0), CpuGame = pid > 0 ? 40 : 0, PlayerGame = player };
                };
                rig.Host.Behaviour = (l, dir) =>
                {
                    readsAtStart.Add(rig.Probe.Reads);
                    saw.Add(Entries(l.AppData) + "|" + Entries(dir));
                    File.WriteAllText(Path.Combine(l.AppData, "save.json"), "x");
                    if (rig.Host.Launches.Count == 1)
                    {
                        File.WriteAllText(Path.Combine(dir, "stale.txt"), "x");
                        WriteRun(dir, "disturbed", "low");
                        rig.Host.RunPolls = 100000;   // runs until it is disturbed
                        return 0;
                    }
                    rig.Host.RunPolls = 0;
                    WriteRun(dir, "second-try", "low");
                    return 0;
                };
                var progress = new List<string>();
                var res = rig.Run("benchB0000001", rig.BenchPlan(new[] { "low" }), progress);
                T.Ok(res.Ok, "a disturbed run is run again: " + res.Error);
                T.Eq(rig.Host.Launches.Count, 2, "the game started twice");
                T.Eq(rig.Host.Killed, 1, "and the disturbed run was stopped");
                T.Eq(MiniJson.Str(rig.Api.DoneRuns.Single(), "clientRunId"), "second-try", "the run sent is the second one");
                T.Eq(string.Join(";", saw), "|;|", "the retry found its --bench-dir and its APPDATA empty (the disturbed run's files are gone)");
                T.Ok(rig.Host.Launches[0].AppData != rig.Host.Launches[1].AppData, "and has an APPDATA of its own");
                T.Ok(readsAtStart[1] - readsAtStart[0] >= 60, "the PC had to be quiet for a minute again first (" + (readsAtStart[1] - readsAtStart[0]) + " readings)");
                T.Has(rig.Api.DoneLog, "the run was disturbed (Death Muffin was started) and thrown away", "the log says what happened");
                T.Ok(progress.Contains("Benchmark on Low (1 of 1)") && progress.Contains("Benchmark on Low (1 of 1), try 2 of 3"), "the status says it is the second try");
                T.Ok(!File.Exists(Path.Combine(rig.Folders.BenchDir("benchB0000001", 1), "stale.txt")), "the first try's files are gone");
            }

            // the keyboard and mouse never disturb a run (Helix, 2026-10-19: the PC may be in use while it runs)
            using (var rig = new Rig())
            {
                rig.Probe.Script = (n, t, pid) =>
                {
                    if (pid > 0) rig.Probe.LastInput = t;   // in use the whole run
                    return new PcSample { CpuTotal = 3 + (pid > 0 ? 40 : 0), CpuGame = pid > 0 ? 40 : 0 };
                };
                int polls = 0;
                rig.Host.Behaviour = (l, dir) => { WriteRun(dir, "used", "low"); rig.Host.RunPolls = 30; polls++; return 0; };
                var res = rig.Run("benchB0000009", rig.BenchPlan(new[] { "low" }));
                T.Ok(res.Ok && rig.Host.Launches.Count == 1 && MiniJson.Str(rig.Api.DoneRuns.Single(), "clientRunId") == "used", "a run on a PC in use is kept the first time: " + res.Error);
                T.Ok(!rig.Api.DoneLog.Contains("disturbed"), "and nothing calls it disturbed");
            }

            // other programs, the player's Death Muffin, the battery: each disturbs a run once
            foreach (var kind in new[] { "cpu", "game", "battery" })
                using (var rig = new Rig())
                {
                    int gameReads = 0;
                    rig.Probe.Script = (n, t, pid) =>
                    {
                        var s = new PcSample { CpuTotal = 3 + (pid > 0 ? 40 : 0), CpuGame = pid > 0 ? 40 : 0 };
                        if (pid > 0 && rig.Host.Launches.Count == 1 && ++gameReads >= 3)
                        {
                            if (kind == "cpu") s.CpuTotal = 75;
                            if (kind == "game") s.PlayerGame = true;
                            if (kind == "battery") s.OnBattery = true;
                        }
                        return s;
                    };
                    rig.Host.Behaviour = (l, dir) => { WriteRun(dir, "run" + rig.Host.Launches.Count, "low"); rig.Host.RunPolls = rig.Host.Launches.Count == 1 ? 100000 : 0; return 0; };
                    var res = rig.Run("benchB0000002", rig.BenchPlan(new[] { "low" }));
                    T.Ok(res.Ok && rig.Host.Launches.Count == 2 && rig.Host.Killed == 1 && MiniJson.Str(rig.Api.DoneRuns.Single(), "clientRunId") == "run2", "a run disturbed by " + kind + " is run again: " + res.Error);
                    string why = kind == "cpu" ? "other programs were using the CPU (about 29%)" : kind == "game" ? "Death Muffin was started" : "the PC went on battery";
                    T.Has(rig.Api.DoneLog, "the run was disturbed (" + why + ")", "the log says why (" + kind + ")");
                }

            // disturbed three times: the job fails with the reason, and no run is sent
            using (var rig = new Rig())
            {
                rig.Probe.Script = (n, t, pid) => pid > 0 ? new PcSample { CpuTotal = 70, CpuGame = 40 } : new PcSample { CpuTotal = 3 };
                rig.Host.RunPolls = 100000;
                rig.Host.Behaviour = (l, dir) => { WriteRun(dir, "never-sent", "low"); File.WriteAllText(Path.Combine(dir, "stale.txt"), "x"); return 0; };
                string id = "benchB0000003";
                var res = rig.Run(id, rig.BenchPlan(new[] { "low" }));
                T.Eq(res.Error, "The benchmark on Low was disturbed 3 times (other programs were using the CPU (about 30%)), so no numbers were sent. Keep other programs and Death Muffin closed while it runs.", "three disturbed runs fail the job in plain words");
                T.Eq(rig.Host.Launches.Count, 3, "at most 3 tries");
                T.Eq(rig.Host.Killed, 3, "each was stopped");
                T.Eq(rig.Api.FailError, res.Error, "the server is told the same");
                T.Eq(rig.Api.Count("done"), 0, "nothing is sent as a result");
                T.Eq(Directory.GetFiles(rig.Folders.BenchDir(id, 1)).Length, 0, "the last disturbed run's folder is emptied too");
                T.Eq(rig.Host.Launches.Select(l => l.AppData).Distinct().Count(), 3, "every try had its own APPDATA");
            }
            using (var rig = new Rig())
            {
                // the number of tries is a setting
                rig.Runner.BenchTries = 2;
                rig.Probe.Script = (n, t, pid) => pid > 0 ? new PcSample { CpuTotal = 70, CpuGame = 40 } : new PcSample { CpuTotal = 3 };
                rig.Host.RunPolls = 100000;
                rig.Host.Behaviour = (l, dir) => 0;
                var res = rig.Run("benchB0000004", rig.BenchPlan(new[] { "low" }));
                T.Ok(!res.Ok && rig.Host.Launches.Count == 2 && res.Error.Contains("disturbed 2 times"), "two tries when two are allowed");
            }
            using (var rig = new Rig())
            {
                // tries are per setup: the first setup is disturbed twice and still gets its third, and the second setup starts with 3 of its own
                int run = 0;
                rig.Probe.Script = (n, t, pid) =>
                {
                    var s = new PcSample { CpuTotal = 3 + (pid > 0 ? 40 : 0), CpuGame = pid > 0 ? 40 : 0 };
                    if (pid > 0 && rig.Host.Launches.Count <= 2) s.CpuTotal = 80;
                    return s;
                };
                rig.Host.Behaviour = (l, dir) => { run++; WriteRun(dir, "run" + run, FakeGameHost.Preset(l)); rig.Host.RunPolls = run <= 2 ? 100000 : 0; return 0; };
                var res = rig.Run("benchB0000005", rig.BenchPlan());
                T.Ok(res.Ok && rig.Host.Launches.Count == 4 && rig.Api.DoneRuns.Count == 2, "two setups, one disturbed twice: " + res.Error + " (" + rig.Host.Launches.Count + " launches)");
                T.Eq(MiniJson.Str(rig.Api.DoneRuns[0], "clientRunId") + "," + MiniJson.Str(rig.Api.DoneRuns[1], "clientRunId"), "run3,run4", "the runs sent are the third and the fourth start");
            }
        }

        static void BenchQuietWait()
        {
            using (var rig = new Rig())
            {
                // the player has Death Muffin open: the benchmark waits for it to be closed, then for the minute
                var readsAtStart = new List<int>();
                rig.Probe.Script = (n, t, pid) => new PcSample { CpuTotal = 3, PlayerGame = n < 100 };
                rig.Host.Behaviour = (l, dir) => { readsAtStart.Add(rig.Probe.Reads); WriteRun(dir, "r", "low"); return 0; };
                var progress = new List<string>();
                var res = rig.Run("benchQ0000001", rig.BenchPlan(new[] { "low" }), progress);
                T.Ok(res.Ok, "the benchmark runs once Death Muffin is closed: " + res.Error);
                T.Ok(readsAtStart[0] >= 160, "and a minute after it: " + readsAtStart[0] + " readings");
                T.Ok(progress.Contains("Waiting for a quiet PC: Death Muffin is open"), "the status says why it waits");
                T.Has(rig.Api.DoneLog, "waiting for a quiet PC: Death Muffin is open", "the log says it once");
                T.Eq(rig.Api.DoneLog.Split(new[] { "waiting for a quiet PC: Death Muffin is open" }, StringSplitOptions.None).Length - 1, 1, "and only once");
            }
            using (var rig = new Rig())
            {
                // a full-screen app, the battery, and busy CPU wait too
                foreach (string kind in new[] { "full", "battery", "cpu" })
                {
                    rig.Host.Launches.Clear();
                    rig.Probe.Script = (n, t, pid) =>
                    {
                        var s = new PcSample { CpuTotal = 3 };
                        bool bad = n < 90;
                        if (kind == "full") s.Fullscreen = bad;
                        if (kind == "battery") s.OnBattery = bad;
                        if (kind == "cpu" && bad) s.CpuTotal = 45;
                        return s;
                    };
                    rig.Probe.Reads = 0;
                    var starts = new List<int>();
                    rig.Host.Behaviour = (l, dir) => { starts.Add(rig.Probe.Reads); WriteRun(dir, "r", "low"); return 0; };
                    var res = rig.Run("benchQ000000" + (kind == "full" ? 2 : kind == "battery" ? 3 : 4), rig.BenchPlan(new[] { "low" }));
                    T.Ok(res.Ok && starts.Count == 1 && starts[0] >= (kind == "cpu" ? 130 : 148), kind + ": the benchmark waits until the PC is quiet and a minute has passed (" + (starts.Count == 1 ? starts[0].ToString() : "?") + " readings): " + res.Error);
                }
            }
            using (var rig = new Rig())
            {
                // the PC never goes quiet: the job's life ends first
                rig.Probe.Script = (n, t, pid) => new PcSample { CpuTotal = 60 };
                var res = rig.Run("benchQ0000006", rig.BenchPlan(new[] { "low" }, DateTime.UtcNow.AddMilliseconds(300)));
                T.Eq(res.Error, "The PC never went quiet for long enough: other programs are using the CPU (about 60%).", "a PC that never goes quiet fails the job in plain words");
                T.Eq(rig.Host.Launches.Count, 0, "the game never started");
                T.Eq(rig.Api.FailError, res.Error, "the server is told");
            }
            using (var rig = new Rig())
            {
                // someone who never stops typing on a quiet PC: the benchmark runs after its quiet minute anyway (Helix, 2026-10-19: only the CPU counts)
                rig.Probe.Script = (n, t, pid) => { rig.Probe.LastInput = t; return new PcSample { CpuTotal = 3 + (pid > 0 ? 40 : 0), CpuGame = pid > 0 ? 40 : 0 }; };
                rig.Probe.Reads = 0;
                var starts = new List<int>();
                rig.Host.Behaviour = (l, dir) => { starts.Add(rig.Probe.Reads); WriteRun(dir, "typed", "low"); return 0; };
                var res = rig.Run("benchQ0000007", rig.BenchPlan(new[] { "low" }));
                T.Ok(res.Ok && starts.Count == 1 && starts[0] < 90, "someone who never stops typing: the benchmark runs after its quiet minute (" + (starts.Count == 1 ? starts[0].ToString() : "?") + " readings): " + res.Error);
            }
            using (var rig = new Rig())
            {
                // a job that does not say when it ends waits as long as the runner allows
                rig.Runner.QuietWaitLimit = TimeSpan.FromMilliseconds(200);
                rig.Probe.Script = (n, t, pid) => new PcSample { CpuTotal = 60 };
                var res = rig.Run("benchQ0000008", rig.BenchPlan(new[] { "low" }));
                T.Ok(!res.Ok && res.Error.StartsWith("The PC never went quiet for long enough"), "without an expiry the runner's own limit applies: " + res.Error);
            }
            using (var rig = new Rig())
            {
                // the player's Death Muffin does not stop a bench job by itself: the PC's readings decide
                rig.Watch.Started = true;
                rig.Host.Behaviour = (l, dir) => { WriteRun(dir, "r", "low"); return 0; };
                var res = rig.Run("benchQ0000009", rig.BenchPlan(new[] { "low" }));
                T.Ok(res.Ok, "a bench job is not stopped by the shots job's watch: " + res.Error);
            }
            using (var rig = new Rig())
            {
                // the app closes while it waits
                var cts = new CancellationTokenSource();
                rig.Probe.Script = (n, t, pid) => { if (n == 20) cts.Cancel(); return new PcSample { CpuTotal = 60 }; };
                var res = rig.Run("benchQ0000010", rig.BenchPlan(new[] { "low" }), null, cts.Token);
                T.Eq(res.Error, "stopped: the team app was closed", "closing the app stops a job that is waiting");
                T.Eq(rig.Api.FailError, "stopped: the team app was closed", "and tells the server");
                T.Eq(rig.Host.Launches.Count, 0, "no game ran");
            }
            using (var rig = new Rig())
            {
                // the app closes during a run
                var cts = new CancellationTokenSource();
                rig.Host.Behaviour = (l, dir) => { new Timer2(150, () => cts.Cancel()); return null; };
                var res = rig.Run("benchQ0000011", rig.BenchPlan(new[] { "low" }), null, cts.Token);
                T.Eq(res.Error, "stopped: the team app was closed", "closing the app stops a benchmark");
                T.Eq(rig.Host.Killed, 1, "and kills the game");
            }
        }

        static void BenchFailures()
        {
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) =>
                {
                    string logs = Path.Combine(l.AppData, "Godot", "app_userdata", "Death Muffin", "logs");
                    Directory.CreateDirectory(logs);
                    File.WriteAllText(Path.Combine(logs, "godot.log"), "ERROR: no Vulkan device");
                    return 1;
                };
                var res = rig.Run("benchF0000001", rig.BenchPlan());
                T.Eq(res.Error, "The game did not finish the benchmark on Low (it was cancelled or failed, code 1).", "code 1 is a failed benchmark");
                T.Eq(rig.Host.Launches.Count, 1, "not tried again (only a disturbed run is)");
                T.Eq(rig.Api.FailError, res.Error, "the server is told");
                T.Has(rig.Api.FailLog, "Godot's log (godot.log)", "Godot's own log is in the fail log");
                T.Has(rig.Api.FailLog, "no Vulkan device", "with its lines");
                T.Has(rig.Api.FailLog, "game output (Low)", "and the game's output");
                T.Eq(rig.Api.Count("done"), 0, "no done");
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => 2;
                T.Eq(rig.Run("benchF0000002", rig.BenchPlan(new[] { "ultra" })).Error, "The game refused the benchmark setup on Ultra (code 2).", "code 2 is a setup the game refuses");
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => 7;
                T.Eq(rig.Run("benchF0000003", rig.BenchPlan(new[] { "high" })).Error, "The game stopped with code 7 on High before the benchmark was done.", "another code");
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => 0;
                T.Eq(rig.Run("benchF0000004", rig.BenchPlan(new[] { "low" })).Error, "The game finished the benchmark on Low but left no result.", "a game that ends with code 0 and no run");
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => { WriteRun(dir, "c", "low", cancelled: true); return 0; };
                T.Eq(rig.Run("benchF0000005", rig.BenchPlan(new[] { "low" })).Error, "The benchmark on Low was cancelled before it finished.", "a cancelled run is no result");
            }
            using (var rig = new Rig())
            {
                rig.Host.Behaviour = (l, dir) => { File.WriteAllText(Path.Combine(dir, "pending.json"), "[{\"clientRunId\":\"x\",\"report\":\"" + new string('x', 70000) + "\"}]"); return 0; };
                T.Eq(rig.Run("benchF0000006", rig.BenchPlan(new[] { "low" })).Error, "The result of the benchmark on Low is too big to send.", "a run the server would refuse for its size is not sent");
            }
            using (var rig = new Rig())
            {
                rig.Host.ThrowOnStart = true;
                T.Eq(rig.Run("benchF0000007", rig.BenchPlan(new[] { "low" })).Error, "The game could not be started for Low: Access is denied", "a game that cannot start says so");
            }
            using (var rig = new Rig())
            {
                // the second setup fails: nothing at all is sent (done carries every run or none)
                rig.Host.Behaviour = (l, dir) => { if (FakeGameHost.Preset(l) == "low") { WriteRun(dir, "a", "low"); return 0; } return 1; };
                var res = rig.Run("benchF0000008", rig.BenchPlan());
                T.Ok(!res.Ok && res.Error.Contains("on Medium") && rig.Api.Count("done") == 0 && rig.Host.Launches.Count == 2, "a failure of a later setup fails the whole job: " + res.Error);
            }
            using (var rig = new Rig())
            {
                // a game that runs too long
                rig.Runner.BenchRunLimit = TimeSpan.FromMilliseconds(250);
                rig.Host.Behaviour = (l, dir) => null;
                var res = rig.Run("benchF0000009", rig.BenchPlan(new[] { "low" }));
                T.Eq(res.Error, "The benchmark took longer than 1 second on Low and was stopped.", "a benchmark over the time limit fails");
                T.Eq(rig.Host.Killed, 1, "and is killed");
                T.Eq(rig.Runner.BenchRunLimit == TimeSpan.FromMinutes(15) ? 1 : 0, 0, "(the limit above was changed for the test)");
                T.Eq(new JobRunner(rig.Api, rig.Folders, new FileFetcher(rig.Http), rig.Host, rig.Watch, null, rig.Probe).BenchRunLimit, TimeSpan.FromMinutes(15), "a benchmark setup gets 15 minutes");
            }
            using (var rig = new Rig())
            {
                // a bench job with a missing file fails before any game starts
                var plan = rig.BenchPlan();
                rig.Srv.Files.Remove("death-muffin/team-files/bench1x/DeathMuffin.pck");
                var res = rig.Run("benchF0000010", plan);
                T.Ok(!res.Ok && res.Error.Contains("Could not download DeathMuffin.pck") && rig.Host.Launches.Count == 0 && rig.Probe.Reads == 0, "a download that fails ends the job before the PC is read: " + res.Error);
            }
        }

        /// <summary>Runs an action once, after a delay, on its own thread (a stand-in for time passing while the game runs).</summary>
        sealed class Timer2
        {
            public Timer2(int ms, Action a) { Task.Run(async () => { await Task.Delay(ms); a(); }); }
        }
    }
}
