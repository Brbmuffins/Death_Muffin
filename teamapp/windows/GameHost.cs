using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace DeathMuffinTeam
{
    /// <summary>What to start: the game, from the job's game folder, with Godot's user folders pointed into the job's folder.</summary>
    internal sealed class GameLaunch
    {
        public string ExePath = "";
        public string WorkingDir = "";
        public string AppData = "";
        public string LocalAppData = "";
        public List<string> Args = new List<string>();
        /// <summary>Below normal for screenshots (a job never competes with what the person is doing); a benchmark runs at normal: low priority would skew it.</summary>
        public ProcessPriorityClass Priority = ProcessPriorityClass.BelowNormal;
    }

    internal interface IGameProcess : IDisposable
    {
        int Id { get; }
        bool HasExited { get; }
        int ExitCode { get; }
        void Kill();
        /// <summary>Called every poll while the game runs: keeps its window out of the way (Windows only; a no-op elsewhere).</summary>
        void Tend();
        /// <summary>What the game printed (the end of it).</summary>
        string Output();
    }

    /// <summary>Starts the game. The real one starts a process; tests use stand-ins that write pictures instead.</summary>
    internal interface IGameHost
    {
        IGameProcess Start(GameLaunch launch);
    }

    /// <summary>Sees whether the player started Death Muffin while a job runs.</summary>
    internal interface IPlayerGameWatch
    {
        /// <summary>Notes which Death Muffin processes are running now (a game the player already had open when they said yes does not stop the job).</summary>
        void Begin();
        /// <summary>True when a Death Muffin process that was not there at Begin, and is not the job's own game (<paramref name="ownPid"/>), is running.</summary>
        bool PlayerStarted(int ownPid);
        /// <summary>What the last check counted as the player's game (name, process id, its exe path, the app's own folder), for the job log; "" when none.</summary>
        string LastSeen { get; }
    }

    internal sealed class ProcessGameHost : IGameHost
    {
        readonly Action<int, System.Drawing.Point?> tend;
        readonly Action<int> started;

        /// <param name="tend">Called with the game's process id on every poll (the window tamer on Windows), and with the spot outside every monitor the
        /// window must stay at when the run is one nobody should see (it was started with `--position`; a benchmark is not); null for none.</param>
        /// <param name="started">Called with each game's process id the moment it starts (the platform remembers the app's own games: never the player's).</param>
        public ProcessGameHost(Action<int, System.Drawing.Point?> tend = null, Action<int> started = null) { this.tend = tend; this.started = started; }

        /// <summary>The `--position X,Y` the run was started with, or null (the window may be seen: a benchmark).</summary>
        static System.Drawing.Point? HiddenSpot(List<string> args)
        {
            int i = args.IndexOf("--position");
            if (i < 0 || i + 1 >= args.Count) return null;
            string[] xy = args[i + 1].Split(',');
            int x, y;
            return xy.Length == 2 && int.TryParse(xy[0], out x) && int.TryParse(xy[1], out y) ? new System.Drawing.Point(x, y) : (System.Drawing.Point?)null;
        }

        public IGameProcess Start(GameLaunch l)
        {
            var psi = new ProcessStartInfo
            {
                FileName = l.ExePath,
                Arguments = CommandLineText.Join(l.Args),
                WorkingDirectory = l.WorkingDir,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            // The game's user:// (its settings, accounts and logs) lives under these, so it never touches the player's own.
            psi.EnvironmentVariables["APPDATA"] = l.AppData;
            psi.EnvironmentVariables["LOCALAPPDATA"] = l.LocalAppData;
            var buffer = new OutputBuffer(64 * 1024);
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.OutputDataReceived += (s, e) => { if (e.Data != null) buffer.Add(e.Data); };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null) buffer.Add(e.Data); };
            p.Start();
            if (started != null) started(p.Id);
            bool prioritySet = true;
            try { p.PriorityClass = l.Priority; } catch (Exception) { prioritySet = false; }
            if (!prioritySet && l.Priority == ProcessPriorityClass.Normal && !p.HasExited)
            {
                // A benchmark must not run at the app's own below-normal priority (honest numbers): no run is better than a skewed one.
                try { p.Kill(); } catch (Exception) { }
                p.Dispose();
                throw new InvalidOperationException("Windows did not let the app run the game at normal priority");
            }
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            System.Drawing.Point? spot = HiddenSpot(l.Args);
            var running = new Running(p, buffer, tend, spot);
            if (tend != null && spot.HasValue)
            {
                // Godot shows its window (the boot splash) before the game reads --position, and may place it on a monitor: for the first 10 s the
                // window is looked for every 10 ms and moved outside every monitor the moment it appears (Helix, 2026-10-19: the splash popped up, then hid).
                int id0 = p.Id;
                System.Threading.Tasks.Task.Run(() =>
                {
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    while (sw.ElapsedMilliseconds < 10000 && !running.HasExited)
                    {
                        try { tend(id0, spot); } catch (Exception) { }
                        System.Threading.Thread.Sleep(10);
                    }
                });
            }
            return running;
        }

        sealed class Running : IGameProcess
        {
            readonly Process p;
            readonly OutputBuffer buffer;
            readonly Action<int, System.Drawing.Point?> tend;
            readonly System.Drawing.Point? spot;
            readonly int id;

            public Running(Process p, OutputBuffer buffer, Action<int, System.Drawing.Point?> tend, System.Drawing.Point? spot) { this.p = p; this.buffer = buffer; this.tend = tend; this.spot = spot; id = p.Id; }

            public int Id { get { return id; } }

            public bool HasExited
            {
                get
                {
                    try { return p.HasExited; }
                    catch (InvalidOperationException) { return true; }
                }
            }

            public int ExitCode { get { return p.ExitCode; } }

            public void Kill()
            {
                try { if (!p.HasExited) p.Kill(); }
                catch (InvalidOperationException) { }
                catch (System.ComponentModel.Win32Exception) { }
                try { p.WaitForExit(5000); } catch (Exception) { }
            }

            public void Tend()
            {
                if (tend == null) return;
                try { tend(id, spot); } catch (Exception) { /* keeping the window out of the way is best effort */ }
            }

            public string Output()
            {
                // The timed WaitForExit does not wait for the output events; the one without a time does, once the process has ended.
                try { if (p.HasExited && p.WaitForExit(3000)) p.WaitForExit(); } catch (Exception) { }
                return buffer.Text();
            }

            public void Dispose() { p.Dispose(); }
        }
    }

    /// <summary>
    /// Godot's exit report. A debug build, on exit, prints a long list of what it never freed ("... were leaked at exit", "... were never freed", "Leaked instance dependency", "ObjectDB instances were
    /// leaked", "resources still in use"), each followed by an "   at: ..." line. It says nothing about why a job failed and it fills the log tail the server keeps, so those lines (and the "at:" line after
    /// each) are dropped from what the app keeps and uploads. Every other line, every other ERROR and WARNING, stays.
    /// </summary>
    internal static class GodotLog
    {
        static readonly Regex LeakRe = new Regex("were leaked at exit|were never freed|Leaked instance dependency|ObjectDB instances (were )?leaked|resources still in use", RegexOptions.CultureInvariant);
        static readonly Regex LocationRe = new Regex("^\\s+at: ", RegexOptions.CultureInvariant);

        /// <summary>A line of the exit report.</summary>
        public static bool IsLeak(string line) { return line != null && LeakRe.IsMatch(line); }

        /// <summary>The "   at: function (file:line)" line Godot prints under an error.</summary>
        public static bool IsLocation(string line) { return line != null && LocationRe.IsMatch(line); }

        /// <summary>The text without the exit report's lines.</summary>
        public static string Clean(string text)
        {
            if (string.IsNullOrEmpty(text)) return text ?? "";
            var kept = new List<string>();
            bool dropLocation = false;
            foreach (string line in text.Split('\n'))
            {
                if (IsLeak(line)) { dropLocation = true; continue; }
                if (dropLocation && IsLocation(line)) { dropLocation = false; continue; }
                dropLocation = false;
                kept.Add(line);
            }
            return string.Join("\n", kept);
        }
    }

    /// <summary>The end of a process's output: at most <c>max</c> characters, oldest lines dropped first. Godot's exit report is not kept (GodotLog).</summary>
    internal sealed class OutputBuffer
    {
        readonly int max;
        readonly Queue<string> lines = new Queue<string>();
        int size;
        bool dropLocation;

        public OutputBuffer(int max) { this.max = max; }

        public void Add(string line)
        {
            lock (lines)
            {
                if (GodotLog.IsLeak(line)) { dropLocation = true; return; }
                if (dropLocation && GodotLog.IsLocation(line)) { dropLocation = false; return; }
                dropLocation = false;
                if (line.Length > 2000) line = line.Substring(0, 2000);
                lines.Enqueue(line);
                size += line.Length + 1;
                while (size > max && lines.Count > 1) size -= lines.Dequeue().Length + 1;
            }
        }

        public string Text()
        {
            lock (lines) return string.Join("\n", lines.ToArray());
        }
    }
}
