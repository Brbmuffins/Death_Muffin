using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
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

    /// <summary>
    /// Godot's own settings for one run: an `override.cfg` beside the game's exe, which Godot reads at start over the project's settings (only ever in a job's game folder).
    /// A run nobody should see starts its window minimized. Godot keeps a new window at least a third on a monitor whatever `--position` says (DisplayServerWindows::_create_window),
    /// draws its boot splash there and answers no window messages until its first frame, so the app could only move the window away a second or two later (Helix, 2026-10-19:
    /// the splash still showed on 0.3.3 to 0.4.1). Minimized, nothing reaches a monitor; the window tamer restores it outside every monitor once Godot answers (Godot draws nothing
    /// while minimized). `--windowed` does not undo it: a game's window mode comes from its settings, the flag only skips Godot's change at boot. Every other run (a benchmark)
    /// starts with the file removed.
    /// </summary>
    internal static class GameOverride
    {
        public const string FileName = "override.cfg";
        public const string MinimizedText = "; Written by the Death Muffin team app for a run nobody should see: the window starts minimized and the app restores it outside every monitor.\n"
            + "; Removed before any other run.\n[display]\n\nwindow/size/mode=1\n";

        /// <summary>
        /// Removes the file from <paramref name="exeDir"/> (it is never written through: it could be a hard link) and, when <paramref name="minimized"/>, writes it again. True when the run starts minimized;
        /// false when it was not asked or could not be written (the run then starts as before, on a monitor until it is moved). A file that cannot be removed throws: that run would start minimized and nothing would restore it.
        /// </summary>
        public static bool Prepare(string exeDir, bool minimized)
        {
            string file = Path.Combine(exeDir, FileName);
            if (File.Exists(file)) File.Delete(file);
            if (!minimized) return false;
            try { File.WriteAllText(file, MinimizedText, new UTF8Encoding(false)); return true; }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }
    }

    /// <summary>
    /// What the window tamer does with a game's window, read from the run's engine options (ahead of `--`). A run nobody should see has `--position X,Y` (<see cref="HiddenAt"/>, outside every
    /// monitor): it starts minimized (<see cref="GameOverride"/>) and is restored there at <see cref="ClientSize"/>. A benchmark has `--fullscreen` (<see cref="InFront"/>: borderless over the whole
    /// screen at its own resolution, the display mode unchanged) and is brought in front of everything with the focus (Helix, 2026-10-19: "run only benchmarks in fullscreen-windowed in the
    /// foreground"). Any other window is only kept from taking the focus.
    /// </summary>
    internal sealed class WindowWish
    {
        public System.Drawing.Point? HiddenAt;
        public System.Drawing.Size? ClientSize;
        public bool InFront;

        public static WindowWish From(List<string> args)
        {
            int end = args.IndexOf("--");
            List<string> engine = end < 0 ? args : args.GetRange(0, end);
            return new WindowWish { HiddenAt = Spot(engine), ClientSize = Size(args, engine), InFront = engine.Contains("--fullscreen") };
        }

        /// <summary>The `--position X,Y` the run was started with, or null.</summary>
        static System.Drawing.Point? Spot(List<string> engine)
        {
            int i = engine.IndexOf("--position");
            if (i < 0 || i + 1 >= engine.Count) return null;
            string[] xy = engine[i + 1].Split(',');
            int x, y;
            return xy.Length == 2 && int.TryParse(xy[0], out x) && int.TryParse(xy[1], out y) ? new System.Drawing.Point(x, y) : (System.Drawing.Point?)null;
        }

        /// <summary>The size of the window's inside the run asks for: the game's `--qa-window=WxH` (the release checks' screens, past the screen), else the engine's `--resolution WxH`; null when neither reads.</summary>
        static System.Drawing.Size? Size(List<string> args, List<string> engine)
        {
            string v = null;
            foreach (string a in args) if (a.StartsWith("--qa-window=", StringComparison.Ordinal)) v = a.Substring(12);
            int i = engine.IndexOf("--resolution");
            if (v == null && i >= 0 && i + 1 < engine.Count) v = engine[i + 1];
            string[] wh = v == null ? new string[0] : v.Split('x');
            int w, h;
            return wh.Length == 2 && int.TryParse(wh[0], out w) && int.TryParse(wh[1], out h) && w > 0 && h > 0 ? new System.Drawing.Size(w, h) : (System.Drawing.Size?)null;
        }

        public override string ToString()
        {
            return (HiddenAt.HasValue ? "hidden at " + HiddenAt.Value.X + "," + HiddenAt.Value.Y : InFront ? "in front" : "left alone")
                + (ClientSize.HasValue ? ", " + ClientSize.Value.Width + "x" + ClientSize.Value.Height : "");
        }
    }

    internal sealed class ProcessGameHost : IGameHost
    {
        readonly Action<int, WindowWish> tend;
        readonly Action<int> started;

        /// <param name="tend">Called with the game's process id on every poll (the window tamer on Windows) and what the run wants of its window (<see cref="WindowWish"/>); null for none.
        /// A run nobody should see starts minimized only when there is a tamer to restore it (<see cref="GameOverride"/>).</param>
        /// <param name="started">Called with each game's process id the moment it starts (the platform remembers the app's own games: never the player's).</param>
        public ProcessGameHost(Action<int, WindowWish> tend = null, Action<int> started = null) { this.tend = tend; this.started = started; }

        public IGameProcess Start(GameLaunch l)
        {
            WindowWish wish = WindowWish.From(l.Args);
            GameOverride.Prepare(Path.GetDirectoryName(Path.GetFullPath(l.ExePath)), tend != null && wish.HiddenAt.HasValue);
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
            var running = new Running(p, buffer, tend, wish);
            if (tend != null && (wish.HiddenAt.HasValue || wish.InFront))
            {
                // Godot answers no window messages until its first frame: for the first 10 s the window is looked for every 10 ms, so a hidden run's window (started minimized, GameOverride)
                // is restored outside every monitor at Godot's first answer, before the game draws anything, and a benchmark's comes in front as soon as it can.
                int id0 = p.Id;
                System.Threading.Tasks.Task.Run(() =>
                {
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    while (sw.ElapsedMilliseconds < 10000 && !running.HasExited)
                    {
                        try { tend(id0, wish); } catch (Exception) { }
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
            readonly Action<int, WindowWish> tend;
            readonly WindowWish wish;
            readonly int id;

            public Running(Process p, OutputBuffer buffer, Action<int, WindowWish> tend, WindowWish wish) { this.p = p; this.buffer = buffer; this.tend = tend; this.wish = wish; id = p.Id; }

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
                try { tend(id, wish); } catch (Exception) { /* placing the window is best effort */ }
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
