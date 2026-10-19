using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

// Everything that needs Windows: DPAPI, the full-screen and battery checks, the CPU and keyboard/mouse readings, hard links, the game's window, the start-with-Windows switch.
// Not compiled by teamapp/tests; teamapp/tests/compile-check.sh compiles it against the .NET Framework 4.8 reference assemblies.
namespace DeathMuffinTeam
{
    /// <summary>DPAPI, current user: only this Windows account can open what it wrote.</summary>
    internal sealed class DpapiProtector : ITokenProtector
    {
        static readonly byte[] Entropy = Encoding.UTF8.GetBytes("DeathMuffinTeam");

        public string Protect(string plain)
        {
            byte[] data = ProtectedData.Protect(Encoding.UTF8.GetBytes(plain), Entropy, DataProtectionScope.CurrentUser);
            return Convert.ToBase64String(data);
        }

        public string Unprotect(string protectedText)
        {
            try
            {
                byte[] data = ProtectedData.Unprotect(Convert.FromBase64String(protectedText), Entropy, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(data);
            }
            catch (CryptographicException) { return null; }
            catch (FormatException) { return null; }
        }
    }

    internal sealed class WindowsPlatform : ITeamPlatform, IPlayerGameWatch
    {
        static readonly string[] GameProcesses = { "DeathMuffin", "DeathMuffinDebug" };
        readonly string ownRoot;

        /// <param name="ownRoot">The app's folder: a game running from under it is a job's, not the player's.</param>
        public WindowsPlatform(string ownRoot) { this.ownRoot = ownRoot; }

        // SHQueryUserNotificationState values: 2 busy (a full-screen app), 3 a Direct3D full-screen game, 4 presentation mode.
        [DllImport("shell32.dll")]
        static extern int SHQueryUserNotificationState(out int state);

        public bool Fullscreen()
        {
            try
            {
                int state;
                if (SHQueryUserNotificationState(out state) != 0) return false;
                return state == 2 || state == 3 || state == 4;
            }
            catch (Exception) { return false; }
        }

        public bool OnBattery()
        {
            try { return SystemInformation.PowerStatus.PowerLineStatus == PowerLineStatus.Offline; }
            catch (Exception) { return false; }
        }

        public bool GameRunning() { return RunningGames(null).Count > 0; }

        /// <summary>True when the process runs from under the app's own folder (a job's game). A process whose path cannot be read counts as the player's.</summary>
        bool IsOurs(Process p)
        {
            // QueryFullProcessImageName, not p.MainModule: reading the modules fails for a moment while a game is still starting (ERROR_PARTIAL_COPY),
            // and a failure here counts as the player's game (2026-10-19: Helix's release benchmark was thrown away three times as "Death Muffin was started"
            // by its own game). An unreadable path still counts as the player's: the safe side when it really is theirs.
            string path = Native.ImagePath(p.Id);
            return path != null && path.StartsWith(ownRoot, StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>The player's games, the job's own game <paramref name="jobPid"/> left out (the benchmark's disturbance check).</summary>
        public bool GameRunningBesides(int jobPid) { return RunningGames(jobPid > 0 ? (int?)jobPid : null).Count > 0; }

        /// <summary>The process ids of the player's Death Muffin (and debug build) that are running, except <paramref name="exclude"/> and the app's own job games.</summary>
        List<int> RunningGames(int? exclude)
        {
            var ids = new List<int>();
            foreach (string name in GameProcesses)
            {
                Process[] list;
                try { list = Process.GetProcessesByName(name); }
                catch (Exception) { continue; }
                foreach (Process p in list)
                {
                    try { if ((!exclude.HasValue || p.Id != exclude.Value) && !IsOurs(p)) ids.Add(p.Id); }
                    finally { p.Dispose(); }
                }
            }
            return ids;
        }

        // ---- IPlayerGameWatch --------------------------------------------------------------------------------------------------------
        readonly HashSet<int> baseline = new HashSet<int>();

        public void Begin()
        {
            baseline.Clear();
            foreach (int id in RunningGames(null)) baseline.Add(id);
        }

        public bool PlayerStarted(int ownPid)
        {
            foreach (int id in RunningGames(ownPid > 0 ? (int?)ownPid : null))
                if (!baseline.Contains(id)) return true;
            return false;
        }

        // ---- The graphics card's name ---------------------------------------------------------------------------------------------------

        public string GpuName()
        {
            // The display adapters Windows lists (EnumDisplayDevices: no admin rights, no WMI); the registry's display class as a fallback, one
            // entry at a time (one entry that cannot be opened must not hide the others: 0.1.0 reported nothing on Helix's PC).
            var names = new List<string>();
            try
            {
                for (uint i = 0; i < 16; i++)
                {
                    var d = new Native.DisplayDevice();
                    d.cb = Marshal.SizeOf(typeof(Native.DisplayDevice));
                    if (!Native.EnumDisplayDevices(null, i, ref d, 0)) break;
                    string n = (d.DeviceString ?? "").Trim();
                    if (n.Length > 0 && !names.Contains(n) && (d.StateFlags & Native.DisplayDeviceMirroring) == 0) names.Add(n);
                }
            }
            catch (Exception) { }
            if (names.Count == 0)
            {
                try
                {
                    using (RegistryKey cls = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11cd-b6bb-00a0c91d1e40}"))
                    {
                        if (cls != null)
                            foreach (string sub in cls.GetSubKeyNames())
                            {
                                if (sub.Length != 4) continue;
                                try
                                {
                                    using (RegistryKey k = cls.OpenSubKey(sub))
                                    {
                                        string desc = k == null ? null : k.GetValue("DriverDesc") as string;
                                        if (!string.IsNullOrWhiteSpace(desc) && !names.Contains(desc.Trim())) names.Add(desc.Trim());
                                    }
                                }
                                catch (Exception) { }
                            }
                    }
                }
                catch (Exception) { }
            }
            return string.Join(" + ", names);
        }
    }

    /// <summary>
    /// What a `bench` job reads to know whether the PC is quiet (Quiet.cs decides): the total CPU between two readings from GetSystemTimes, the job's game's share of it from its process's CPU time,
    /// the seconds since the last key or mouse input from GetLastInputInfo, and the platform's own battery, full-screen and player's-game checks. Called from one thread, about once a second.
    /// </summary>
    internal sealed class WindowsPcProbe : IPcProbe
    {
        [StructLayout(LayoutKind.Sequential)]
        struct FileTime { public uint Low, High; }

        [StructLayout(LayoutKind.Sequential)]
        struct LastInputInfo { public uint Size, Time; }

        [DllImport("kernel32.dll")]
        static extern bool GetSystemTimes(out FileTime idle, out FileTime kernel, out FileTime user);

        [DllImport("user32.dll")]
        static extern bool GetLastInputInfo(ref LastInputInfo info);

        readonly WindowsPlatform platform;   // the real one: the disturbance check needs GameRunningBesides
        readonly Stopwatch clock = Stopwatch.StartNew();
        bool haveLast;
        ulong lastIdle, lastTotal;
        TimeSpan lastAt;
        Process game;
        int gamePid;
        TimeSpan gameCpu;

        public WindowsPcProbe(WindowsPlatform platform) { this.platform = platform; }

        static ulong Ticks(FileTime t) { return ((ulong)t.High << 32) | t.Low; }

        static double Clamp(double v) { return v < 0 ? 0 : v > 100 ? 100 : v; }

        public PcSample Read(int pid)
        {
            TimeSpan now = clock.Elapsed;
            var s = new PcSample { At = now };
            try
            {
                FileTime idle, kernel, user;
                if (GetSystemTimes(out idle, out kernel, out user))
                {
                    ulong i = Ticks(idle), total = Ticks(kernel) + Ticks(user);   // kernel time includes the idle time
                    if (haveLast && total > lastTotal)
                    {
                        double span = total - lastTotal, busy = span - (i - lastIdle);
                        s.CpuTotal = Clamp(100.0 * busy / span);
                    }
                    lastIdle = i;
                    lastTotal = total;
                    haveLast = true;
                }
            }
            catch (Exception) { /* no CPU number: the PC then never counts as quiet */ s.CpuTotal = 100; }
            s.CpuGame = GameShare(pid, (now - lastAt).TotalSeconds);
            lastAt = now;
            s.IdleS = IdleSeconds();
            s.OnBattery = platform.OnBattery();
            s.Fullscreen = platform.Fullscreen();
            s.PlayerGame = platform.GameRunningBesides(pid);   // the job's own game never counts as the player's
            return s;
        }

        /// <summary>The job's game's CPU time over the interval, as a percent of the whole CPU. A game seen for the first time was started just before the interval began: its CPU time so far is the interval's.</summary>
        double GameShare(int pid, double seconds)
        {
            if (pid <= 0) { Forget(); return 0; }
            try
            {
                if (game == null || gamePid != pid)
                {
                    Forget();
                    game = Process.GetProcessById(pid);
                    gamePid = pid;
                    gameCpu = TimeSpan.Zero;
                }
                TimeSpan cpu = game.TotalProcessorTime;
                double used = (cpu - gameCpu).TotalSeconds;
                gameCpu = cpu;
                return seconds <= 0 ? 0 : Clamp(100.0 * used / (seconds * Environment.ProcessorCount));
            }
            catch (Exception) { return 0; }   // the game has ended, or Windows refuses: nothing is taken off the others
        }

        void Forget()
        {
            if (game != null) { game.Dispose(); game = null; }
            gamePid = 0;
        }

        /// <summary>Seconds since the last key press or mouse move in this Windows session. 0 (just now) when Windows will not say: a PC that cannot be read is never "quiet".</summary>
        static double IdleSeconds()
        {
            try
            {
                var info = new LastInputInfo { Size = (uint)Marshal.SizeOf(typeof(LastInputInfo)) };
                if (!GetLastInputInfo(ref info)) return 0;
                return unchecked((uint)Environment.TickCount - info.Time) / 1000.0;   // both are the 32-bit millisecond tick count, which wraps
            }
            catch (Exception) { return 0; }
        }
    }

    internal static class Native
    {
        const uint ProcessQueryLimitedInformation = 0x1000;
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, System.Text.StringBuilder name, ref int size);
        /// <summary>A process's exe path (works from the start of its life and across 32/64-bit), or null.</summary>
        public static string ImagePath(int pid)
        {
            IntPtr h = OpenProcess(ProcessQueryLimitedInformation, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                var sb = new System.Text.StringBuilder(1024);
                int size = sb.Capacity;
                return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString(0, size) : null;
            }
            finally { CloseHandle(h); }
        }

        public const int DisplayDeviceMirroring = 0x8;
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DisplayDevice
        {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DisplayDevice lpDisplayDevice, uint dwFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateHardLink(string newFileName, string existingFileName, IntPtr securityAttributes);

        /// <summary>A hard link to a file on the same drive (the cached art pack shows up in the job's game folder without a second copy). False when Windows says no.</summary>
        public static bool TryHardLink(string link, string existing)
        {
            try { return CreateHardLink(link, existing, IntPtr.Zero); }
            catch (Exception) { return false; }
        }

        /// <summary>The `--position` for a screenshot job's game window: outside every monitor (JobPlan.OffscreenPosition on the virtual screen, which spans all of them). The window is never seen; the code below
        /// that sends it to the bottom and marks it "no activate" stays as the fallback if Windows brings it on screen anyway.</summary>
        public static string OffscreenPosition()
        {
            System.Drawing.Rectangle v = SystemInformation.VirtualScreen;
            return JobPlan.OffscreenPosition(v.Left, v.Top);
        }

        /// <summary>The same for a window of this width (a `release` job's screens step takes 1920 to 3840 wide): it starts left of every monitor by its own width and a margin.</summary>
        public static string OffscreenPositionFor(int width)
        {
            System.Drawing.Rectangle v = SystemInformation.VirtualScreen;
            return JobPlan.OffscreenPosition(v.Left, v.Top, width);
        }

        // ---- Keeping the game's window out of the way -------------------------------------------------------------------------------

        delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] static extern int GetWindowLong32(IntPtr hWnd, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLong")] static extern int SetWindowLong32(IntPtr hWnd, int index, int value);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] static extern IntPtr GetWindowLong64(IntPtr hWnd, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] static extern IntPtr SetWindowLong64(IntPtr hWnd, int index, IntPtr value);

        const int GWL_EXSTYLE = -20;
        const long WS_EX_NOACTIVATE = 0x08000000L;
        const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10;
        static readonly IntPtr HWND_BOTTOM = new IntPtr(1);

        static long GetExStyle(IntPtr h) { return IntPtr.Size == 8 ? GetWindowLong64(h, GWL_EXSTYLE).ToInt64() : GetWindowLong32(h, GWL_EXSTYLE); }
        static void SetExStyle(IntPtr h, long v) { if (IntPtr.Size == 8) SetWindowLong64(h, GWL_EXSTYLE, new IntPtr(v)); else SetWindowLong32(h, GWL_EXSTYLE, (int)v); }

        static readonly object TameGate = new object();
        static readonly HashSet<IntPtr> Tamed = new HashSet<IntPtr>();
        static int tamedPid;
        static IntPtr persons = IntPtr.Zero;

        /// <summary>
        /// Best effort, called every poll while the game runs. A window of the game (it is created normal-sized, because a minimized Godot window does not draw) is marked
        /// "no activate" so a click never gives it the keyboard, and sent to the bottom of the stack; if it did become the active window, the window the person was using
        /// gets it back. Windows' own rule that a background process cannot take the foreground does most of the work; this covers the rest.
        /// </summary>
        public static void TendGameWindow(int pid)
        {
            lock (TameGate)
            {
                if (tamedPid != pid) { tamedPid = pid; Tamed.Clear(); }
                IntPtr fg = GetForegroundWindow();
                uint fgOwner;
                GetWindowThreadProcessId(fg, out fgOwner);
                if (fg != IntPtr.Zero && fgOwner != (uint)pid) persons = fg;
                var windows = new List<IntPtr>();
                EnumWindows((h, l) =>
                {
                    uint owner;
                    GetWindowThreadProcessId(h, out owner);
                    if (owner == (uint)pid && IsWindowVisible(h)) windows.Add(h);
                    return true;
                }, IntPtr.Zero);
                foreach (IntPtr h in windows)
                {
                    if (Tamed.Add(h))
                    {
                        SetExStyle(h, GetExStyle(h) | WS_EX_NOACTIVATE);
                        SetWindowPos(h, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                    }
                    if (fg == h && persons != IntPtr.Zero) SetForegroundWindow(persons);
                }
            }
        }
    }

    /// <summary>The "Start with Windows" switch: a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run (this user only, no admin).</summary>
    internal static class StartupEntry
    {
        const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string ValueName = "DeathMuffinTeam";

        public static bool IsOn()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(KeyPath))
                    return k != null && k.GetValue(ValueName) != null;
            }
            catch (Exception) { return false; }
        }

        public static void Set(bool on, string exePath)
        {
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(KeyPath))
            {
                if (k == null) return;
                if (on) k.SetValue(ValueName, "\"" + exePath + "\"");
                else k.DeleteValue(ValueName, false);
            }
        }
    }

    /// <summary>A plain text log next to the settings (app.log, at most about 1 MB, the previous one kept as app.old.log): what the app did, for the person to read.</summary>
    internal sealed class AppLog
    {
        readonly string file;
        readonly object gate = new object();

        public AppLog(string folder) { file = Path.Combine(folder, "app.log"); }

        public string FilePath { get { return file; } }

        public void Line(string text)
        {
            try
            {
                lock (gate)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(file));
                    var fi = new FileInfo(file);
                    if (fi.Exists && fi.Length > 1000000)
                    {
                        string old = Path.Combine(Path.GetDirectoryName(file), "app.old.log");
                        if (File.Exists(old)) File.Delete(old);
                        File.Move(file, old);
                    }
                    File.AppendAllText(file, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + text + "\r\n", new UTF8Encoding(false));
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
