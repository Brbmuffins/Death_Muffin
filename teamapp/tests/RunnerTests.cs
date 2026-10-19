using System;
using System.Collections.Generic;
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
        public readonly HttpClient Http = new HttpClient();
        public readonly JobRunner Runner;
        public readonly List<string> Links = new List<string>();
        public bool LinkWorks = true;
        public readonly byte[] Art = Util.Blob(120000, 21), Godot = Util.Blob(80000, 22), Dll = Util.Blob(9000, 23);
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
            Runner = new JobRunner(Api, Folders, new FileFetcher(Http) { RetryDelay = TimeSpan.FromMilliseconds(5), StallTimeout = TimeSpan.FromSeconds(10) }, Host, Watch, linker)
            { PollMs = 5, ApiRetryDelay = TimeSpan.FromMilliseconds(5) };
        }

        /// <summary>A payload for a job: its own main pack, the shared art pack and Godot template under their cache keys.</summary>
        public JobPlan Plan(string[] presets = null, string artKey = "assets-aaa", byte[] art = null, bool publishMain = true)
        {
            string folder = "job" + (++n) + "x";
            var files = new List<object>();
            files.Add(publishMain ? Srv.Publish(folder, "DeathMuffin.pck", Util.Blob(5000, 30 + n)) : Program.File_("DeathMuffin.pck", url: Srv.FilesBase + folder + "/DeathMuffin.pck", sha: new string('a', 64), bytes: 10.0));
            files.Add(Srv.Publish(folder, "DeathMuffin.assets.pck", art ?? Art, artKey));
            files.Add(Srv.Publish(folder, "libdmcore.windows.template_release.x86_64.dll", Dll));
            files.Add(Srv.Publish(folder, "DeathMuffinDebug.exe", Godot, "godot-debug-4.7.2"));
            var p = Program.ValidPayload();
            p["files"] = files;
            p["presets"] = (presets ?? new[] { "low", "ultra" }).Cast<object>().ToList();
            JobPlan plan; string err;
            if (!JobPlan.TryParse(p, Srv.SiteBase, out plan, out err)) throw new InvalidOperationException("test payload refused: " + err);
            return plan;
        }

        public string Folder(int job) { return "job" + job + "x"; }

        public RunResult Run(string id, JobPlan plan, List<string> progress = null, CancellationToken? ct = null)
        {
            return Util.Wait(Runner.RunAsync(id, plan, (progress ?? new List<string>()).Add, ct ?? CancellationToken.None));
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
                T.Ok(progress.Any(p => p.StartsWith("Downloading DeathMuffin.pck")) && progress.Any(p => p == "Taking pictures on Low (1 of 2)") && progress.Any(p => p == "Taking pictures on Ultra (2 of 2)") && progress.Any(p => p == "Uploading pictures (4 of 4)"), "progress tells what is happening");
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
                T.Eq(rig.Srv.HitsFor(rig.Folder(2) + "/DeathMuffin.pck"), 1, "but the main pack, which is the job's own");
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
                int hits = rig.Srv.HitsFor("/DeathMuffin.pck");
                T.Ok(rig.Run("jobD00000001", plan).Ok, "the same job again");
                T.Eq(rig.Srv.HitsFor("/DeathMuffin.pck"), hits, "files already in the job's folder are kept");
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
                T.Ok(!res.Ok && res.Error.Contains("Could not download DeathMuffin.pck") && res.Error.Contains("HTTP 404"), "a missing download fails readably: " + res.Error);
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
                // done itself fails: the pictures are up, the job cannot be failed for that
                rig.Api.Done = () => FakeApi.Err(409, "", "This job is not running any more.");
                var res = rig.Run("jobF00000012", rig.Plan(new[] { "low" }));
                T.Ok(!res.Ok && res.Error.Contains("did not accept the finished job") && res.Error.Contains("not running any more"), "a refused done is reported");
                T.Eq(rig.Api.Count("fail"), 0, "and the job is not failed after its pictures were taken");
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
                rig.Host.Behaviour = (l, dir) => { File.WriteAllBytes(Path.Combine(dir, "huge.png"), new byte[(8 << 20) + 1]); return 0; };
                var res = rig.Run("jobF00000015", rig.Plan(new[] { "low" }));
                T.Ok(!res.Ok && res.Error.Contains("too big"), "a picture over 8 MB fails the job: " + res.Error);
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
                T.Eq(rig.Srv.HitsFor("DeathMuffin.pck"), 0, "and nothing is downloaded");
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

        /// <summary>Runs an action once, after a delay, on its own thread (a stand-in for time passing while the game runs).</summary>
        sealed class Timer2
        {
            public Timer2(int ms, Action a) { Task.Run(async () => { await Task.Delay(ms); a(); }); }
        }
    }
}
