using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam.Tests
{
    /// <summary>Godot's exit report kept out of the log, and the server cancelling a running job (its heartbeat reply lists it). The controller's side of the cancel is in ControllerTests.</summary>
    static class LogCancelTests
    {
        public static void Run()
        {
            GodotLogTests();
            CancelParseTests();
            RunnerCancelTests();
        }

        /// <summary>What a debug build of Godot prints at exit, with the lines that matter between and after it.</summary>
        const string Sample =
            "ERROR: Shader compile failed: missing uniform 'u_tint'\n" +
            "   at: compile (servers/rendering/renderer_rd/shader.cpp:123)\n" +
            "WARNING: ObjectDB instances leaked at exit (run with --verbose for details).\n" +
            "     at: cleanup (core/object/object.cpp:2468)\n" +
            "ERROR: 14 RIDs of type \"Texture\" were leaked at exit.\n" +
            "   at: _free_rids (servers/rendering/renderer_rd/storage_rd/texture_storage.cpp:1234)\n" +
            "ERROR: 3 resources still in use at exit (run with --verbose for details).\n" +
            "   at: clear (core/io/resource.cpp:777)\n" +
            "ERROR: Leaked instance dependency: Resource:-9223372009009999999 - Resource path: res://x.tres\n" +
            "   at: ~Resource (core/io/resource.cpp:90)\n" +
            "ERROR: 12 objects were never freed\n" +
            "   at: report (core/object/object.cpp:1)\n" +
            "ERROR: ObjectDB instances were leaked\n" +
            "WARNING: slow frame: 48 ms\n" +
            "     at: _process (main/main.cpp:99)\n" +
            "QA-SHOTS done\n";

        static void GodotLogTests()
        {
            string clean = GodotLog.Clean(Sample);
            T.Eq(clean,
                "ERROR: Shader compile failed: missing uniform 'u_tint'\n   at: compile (servers/rendering/renderer_rd/shader.cpp:123)\nWARNING: slow frame: 48 ms\n     at: _process (main/main.cpp:99)\nQA-SHOTS done\n",
                "the exit report goes, with each \"at:\" line under it; every other ERROR and WARNING stays with its own \"at:\" line");
            foreach (string gone in new[] { "were leaked at exit", "were never freed", "Leaked instance dependency", "ObjectDB instances", "resources still in use", "cleanup (core", "_free_rids" })
                T.Ok(!clean.Contains(gone), "no \"" + gone + "\" is left");
            T.Eq(GodotLog.Clean(""), "", "an empty log");
            T.Eq(GodotLog.Clean(null), "", "no log");
            T.Eq(GodotLog.Clean("one line"), "one line", "a log with nothing to drop is as it was");
            T.Eq(GodotLog.Clean(Sample.Replace("\n", "\r\n")), clean.Replace("\n", "\r\n"), "Windows line ends: the same lines go (the \r stays on the others)");
            T.Eq(GodotLog.Clean("ERROR: 3 resources still in use at exit\nERROR: a real one\n   at: x\n"), "ERROR: a real one\n   at: x\n", "a dropped line without an \"at:\" line takes nothing else with it");
            T.Eq(GodotLog.Clean("   at: orphan\nERROR: 3 resources still in use at exit\nafter\n"), "   at: orphan\nafter\n", "an \"at:\" line that is not under a dropped line stays");
            T.Eq(GodotLog.Clean("ERROR: ObjectDB instances were leaked\n   at: a\n   at: b\nend"), "   at: b\nend", "only the one line under it is dropped");
            T.Ok(GodotLog.IsLeak("ERROR: 1 resources still in use at exit") && !GodotLog.IsLeak("ERROR: the resource is in use") && !GodotLog.IsLeak(null), "what a leak line is");
            T.Ok(GodotLog.IsLocation("   at: f (a.cpp:1)") && GodotLog.IsLocation("\tat: f") && !GodotLog.IsLocation("at: f") && !GodotLog.IsLocation("ERROR: x at: y"), "what a location line is");

            // the live buffer keeps the end of the output: a leak dump must not push the useful lines out
            var buf = new OutputBuffer(400);
            buf.Add("ERROR: the real failure");
            buf.Add("   at: f (a.cpp:1)");
            for (int i = 0; i < 100; i++)
            {
                buf.Add("ERROR: " + i + " RIDs of type \"Texture\" were leaked at exit.");
                buf.Add("   at: _free_rids (servers/x.cpp:" + i + ")");
            }
            buf.Add("WARNING: ObjectDB instances leaked at exit (run with --verbose for details).");
            buf.Add("     at: cleanup (core/object/object.cpp:2468)");
            buf.Add("QA-SHOTS done");
            T.Eq(buf.Text(), "ERROR: the real failure\n   at: f (a.cpp:1)\nQA-SHOTS done", "the output buffer drops the exit report as it arrives, so the real failure is still there");
            var only = new OutputBuffer(100);
            only.Add("ERROR: 3 resources still in use at exit");
            T.Eq(only.Text(), "", "a buffer that only saw the report is empty");

            if (!OperatingSystem.IsLinux()) return;
            string dir = Util.TempDir("godotlog");
            try
            {
                // a real process printing it to standard error, as Godot does
                string exe = Path.Combine(dir, "DeathMuffinDebug.exe");
                File.WriteAllText(exe, "#!/bin/bash\necho 'ERROR: a shader failed' >&2\necho '   at: compile (shader.cpp:1)' >&2\necho 'ERROR: 3 resources still in use at exit (run with --verbose for details).' >&2\necho '   at: clear (resource.cpp:2)' >&2\necho 'WARNING: ObjectDB instances leaked at exit (run with --verbose for details).' >&2\necho '     at: cleanup (object.cpp:3)' >&2\necho 'QA-SHOTS done'\nexit 0\n");
                File.SetUnixFileMode(exe, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                using (IGameProcess p = new ProcessGameHost().Start(new GameLaunch { ExePath = exe, WorkingDir = dir, AppData = dir, LocalAppData = dir }))
                {
                    var sw = Stopwatch.StartNew();
                    while (!p.HasExited && sw.Elapsed < TimeSpan.FromSeconds(20)) Thread.Sleep(20);
                    string o = p.Output();
                    T.Has(o, "ERROR: a shader failed", "a real process: the real error is kept");
                    T.Has(o, "at: compile (shader.cpp:1)", "with its location");
                    T.Has(o, "QA-SHOTS done", "and the rest");
                    T.Ok(!o.Contains("still in use") && !o.Contains("ObjectDB") && !o.Contains("cleanup"), "and the exit report is not: " + o);
                }
            }
            finally { Util.Rm(dir); }

            using (var rig = new Rig())
            {
                // Godot's own log, added to a failed job, has no exit report either
                rig.Host.Behaviour = (l, dir2) =>
                {
                    string logs = Path.Combine(l.AppData, "Godot", "app_userdata", "Death Muffin", "logs");
                    Directory.CreateDirectory(logs);
                    File.WriteAllText(Path.Combine(logs, "godot.log"), Sample);
                    return 1;
                };
                rig.Run("jobG00000001", rig.Plan(new[] { "low" }));
                T.Has(rig.Api.FailLog, "Godot's log (godot.log)", "the failed job carries Godot's log");
                T.Has(rig.Api.FailLog, "Shader compile failed: missing uniform", "with the failure");
                T.Has(rig.Api.FailLog, "WARNING: slow frame", "and the other warnings");
                T.Ok(!rig.Api.FailLog.Contains("were leaked at exit") && !rig.Api.FailLog.Contains("resources still in use") && !rig.Api.FailLog.Contains("ObjectDB") && !rig.Api.FailLog.Contains("Leaked instance dependency"), "but not the exit report");
            }
        }

        // ---- The heartbeat's `cancel` ------------------------------------------------------------------------------------------------------

        static List<string> Cancel(params object[] items)
        {
            return TeamApi.ParseCancel(FakeApi.Ok(new Dictionary<string, object> { { "cancel", items.ToList() } }));
        }

        static void CancelParseTests()
        {
            T.Eq(string.Join(",", Cancel("ab12cd34ef56", "job000000002")), "ab12cd34ef56,job000000002", "the cancelled job ids are read");
            T.Eq(string.Join(",", Cancel("ab12cd34ef56", "ab12cd34ef56")), "ab12cd34ef56", "once each");
            T.Eq(string.Join(",", Cancel("../x", "", 5.0, null, "has space", "ok1", new string('a', 25))), "ok1", "an entry that is not a job id is ignored");
            T.Eq(Cancel().Count, 0, "an empty list");
            T.Eq(TeamApi.ParseCancel(FakeApi.Ok(new Dictionary<string, object>())).Count, 0, "no list");
            T.Eq(TeamApi.ParseCancel(FakeApi.Ok(new Dictionary<string, object> { { "cancel", "ab12cd34ef56" } })).Count, 0, "a list that is text");
            T.Eq(TeamApi.ParseCancel(null).Count, 0, "no answer");
        }

        // ---- The runner stops and drops a cancelled job ---------------------------------------------------------------------------------

        static void RunnerCancelTests()
        {
            using (var rig = new Rig())
            {
                // a screenshot job whose game is running: the game is killed and the server is told nothing
                var cancel = new CancellationTokenSource();
                rig.Host.Behaviour = (l, dir) => { new Timer2(100, () => cancel.Cancel()); return null; };
                var res = rig.Run("jobX00000001", rig.Plan(), null, null, cancel.Token);
                T.Ok(!res.Ok && res.Cancelled && res.Error == "The job was cancelled.", "a cancelled job says so: " + res.Error);
                T.Eq(rig.Host.Killed, 1, "the game is killed");
                T.Eq(rig.Api.Count("fail") + rig.Api.Count("done") + rig.Api.Count("upload"), 0, "and the server hears nothing: no fail, no done, no pictures");
                T.Has(File.ReadAllText(rig.Folders.LogFile("jobX00000001")), "CANCELLED by the server", "the job's log says it was cancelled");
            }
            using (var rig = new Rig())
            {
                // the app closing is still a fail
                var closing = new CancellationTokenSource();
                rig.Host.Behaviour = (l, dir) => { new Timer2(100, () => closing.Cancel()); return null; };
                var res = rig.Run("jobX00000002", rig.Plan(), null, closing.Token, CancellationToken.None);
                T.Ok(!res.Ok && !res.Cancelled && res.Error == "stopped: the team app was closed" && rig.Api.Count("fail") == 1, "closing the app is reported as before");
            }
            using (var rig = new Rig())
            {
                // both at once: the server's cancel wins (it already knows)
                var closing = new CancellationTokenSource();
                var cancel = new CancellationTokenSource();
                rig.Host.Behaviour = (l, dir) => { new Timer2(100, () => { cancel.Cancel(); closing.Cancel(); }); return null; };
                var res = rig.Run("jobX00000003", rig.Plan(), null, closing.Token, cancel.Token);
                T.Ok(res.Cancelled && rig.Api.Count("fail") == 0, "a cancel and a closing together drop the job");
            }
            using (var rig = new Rig())
            {
                // cancelled before the job started
                var cancel = new CancellationTokenSource();
                cancel.Cancel();
                var res = rig.Run("jobX00000004", rig.Plan(), null, null, cancel.Token);
                T.Ok(res.Cancelled && rig.Host.Launches.Count == 0 && rig.Api.Count("fail") == 0, "a job cancelled before it starts never starts its game");
            }
            using (var rig = new Rig())
            {
                // a benchmark that is waiting for a quiet PC
                var cancel = new CancellationTokenSource();
                rig.Probe.Script = (n, t, pid) => { if (n == 15) cancel.Cancel(); return new PcSample { CpuTotal = 60 }; };
                var res = rig.Run("jobX00000005", rig.BenchPlan(new[] { "low" }), null, null, cancel.Token);
                T.Ok(res.Cancelled && rig.Host.Launches.Count == 0 && rig.Api.Count("fail") == 0, "a benchmark waiting for a quiet PC is dropped without a fail");
            }
            using (var rig = new Rig())
            {
                // a benchmark whose game is running
                var cancel = new CancellationTokenSource();
                rig.Host.Behaviour = (l, dir) => { new Timer2(100, () => cancel.Cancel()); return null; };
                var res = rig.Run("jobX00000006", rig.BenchPlan(new[] { "low" }), null, null, cancel.Token);
                T.Ok(res.Cancelled && rig.Host.Killed == 1 && rig.Api.Count("fail") == 0 && rig.Api.Count("done") == 0, "a benchmark that is running is stopped and dropped");
            }
        }

        sealed class Timer2
        {
            public Timer2(int ms, Action a) { Task.Run(async () => { await Task.Delay(ms); a(); }); }
        }
    }
}
