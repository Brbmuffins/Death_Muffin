using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

// Everything that needs Windows: DPAPI, the full-screen and battery checks, the CPU and keyboard/mouse readings, the graphics card, hard links, the game's window, ComfyUI's job object, the start-with-Windows switch.
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

        readonly Dictionary<int, DateTime> launched = new Dictionary<int, DateTime>();   // process id -> when the app started it (UTC)

        /// <summary>A game the app itself started (ProcessGameHost): it is never the player's, even while it closes and Windows no longer gives its path.</summary>
        public void Launched(int pid) { lock (launched) launched[pid] = DateTime.UtcNow; }

        /// <summary>True when <paramref name="p"/> is a game the app started: its id is one the app launched and it started then (Windows reuses ids, so a player's
        /// later game with an old id is not ours); a process whose start time cannot be read any more (it is closing) with such an id is ours.</summary>
        bool LaunchedByUs(Process p)
        {
            DateTime at;
            lock (launched) if (!launched.TryGetValue(p.Id, out at)) return false;
            try { return Math.Abs((p.StartTime.ToUniversalTime() - at).TotalSeconds) < 30; }
            catch (Exception) { return true; }
        }

        /// <summary>True when the process is a game the app started, or runs from under the app's own folder (a job's game). A process whose path cannot be
        /// read otherwise counts as the player's.</summary>
        bool IsOurs(Process p)
        {
            if (LaunchedByUs(p)) return true;   // 2026-10-19: a closing benchmark game ("path unreadable") threw Helix's benchmark away
            // QueryFullProcessImageName, not p.MainModule: reading the modules fails for a moment while a game is still starting (ERROR_PARTIAL_COPY),
            // and a failure here counts as the player's game (2026-10-19: Helix's release benchmark was thrown away three times as "Death Muffin was started"
            // by its own game). An unreadable path still counts as the player's: the safe side when it really is theirs.
            string path = Native.ImagePath(p.Id);
            return path != null && path.StartsWith(ownRoot, StringComparison.OrdinalIgnoreCase);
        }

        bool WasLaunched(int pid) { lock (launched) return launched.ContainsKey(pid); }

        static string StartedAt(Process p)
        {
            try { return p.StartTime.ToUniversalTime().ToString("HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture) + " UTC"; }
            catch (Exception) { return "(time unreadable)"; }
        }

        /// <summary>True when the process has already ended (it can still be listed for a moment); false when that cannot be read.</summary>
        static bool Exited(Process p)
        {
            try { return p.HasExited; }
            catch (Exception) { return false; }
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
                    try
                    {
                        if ((!exclude.HasValue || p.Id != exclude.Value) && !Exited(p) && !IsOurs(p))
                        {
                            ids.Add(p.Id);
                            lastSeen = name + ".exe pid " + p.Id + " at " + (Native.ImagePath(p.Id) ?? "(path unreadable)") + " (" + Native.ParentOf(p.Id) + ", started " + StartedAt(p)
                                + ", " + (WasLaunched(p.Id) ? "an id the app launched" : "not an id the app launched") + "; the app's folder: " + ownRoot + ")";
                        }
                    }
                    finally { p.Dispose(); }
                }
            }
            return ids;
        }

        // ---- IPlayerGameWatch --------------------------------------------------------------------------------------------------------
        readonly HashSet<int> baseline = new HashSet<int>();

        readonly Dictionary<int, DateTime> seenSince = new Dictionary<int, DateTime>();   // a new game's id -> when it was first seen (UTC)

        /// <summary>A newly seen game counts as the player's once it has stayed open this long: a real game does; a "DeathMuffin.exe" listed for a moment does not
        /// (Helix's PC, 2026-10-19: one at the end of every benchmark run stopped the whole release check before its soak).</summary>
        public static readonly TimeSpan PlayerStays = TimeSpan.FromSeconds(3);

        public void Begin()
        {
            lock (seenSince)
            {
                baseline.Clear();
                seenSince.Clear();
                foreach (int id in RunningGames(null)) baseline.Add(id);
            }
        }

        volatile string lastSeen = "";
        public string LastSeen { get { return lastSeen; } }

        /// <summary>True when a game that was not running at <see cref="Begin"/> (and is not the job's own) has been open for <see cref="PlayerStays"/>: the first
        /// sighting only starts the clock, so a check made once (between two steps) is answered by the next ones.</summary>
        public bool PlayerStarted(int ownPid)
        {
            DateTime now = DateTime.UtcNow;
            lock (seenSince)
            {
                var current = new HashSet<int>();
                bool started = false;
                foreach (int id in RunningGames(ownPid > 0 ? (int?)ownPid : null))
                {
                    if (baseline.Contains(id)) continue;
                    current.Add(id);
                    DateTime since;
                    if (!seenSince.TryGetValue(id, out since)) seenSince[id] = since = now;
                    if (now - since >= PlayerStays) started = true;
                }
                foreach (int id in new List<int>(seenSince.Keys)) if (!current.Contains(id)) seenSince.Remove(id);
                return started;
            }
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
                    EachDisplayAdapter(k =>
                    {
                        string desc = k.GetValue("DriverDesc") as string;
                        if (!string.IsNullOrWhiteSpace(desc) && !names.Contains(desc.Trim())) names.Add(desc.Trim());
                    });
                }
                catch (Exception) { }
            }
            return string.Join(" + ", names);
        }

        /// <summary>
        /// The largest graphics card's memory in MiB, from the display adapters' registry entries (the driver writes HardwareInformation.qwMemorySize, in bytes; older drivers only the 32-bit
        /// HardwareInformation.MemorySize, which stops at 4 GB). 0 when no entry says.
        /// </summary>
        public long VramMb()
        {
            long best = 0;
            try
            {
                EachDisplayAdapter(k =>
                {
                    long bytes = RegistryBytes(k.GetValue("HardwareInformation.qwMemorySize"));
                    if (bytes <= 0) bytes = RegistryBytes(k.GetValue("HardwareInformation.MemorySize"));
                    best = Math.Max(best, bytes / (1024 * 1024));
                });
            }
            catch (Exception) { }
            return best;
        }

        static long RegistryBytes(object v)
        {
            if (v is long) return (long)v;
            if (v is int) return (long)(uint)(int)v;
            var b = v as byte[];
            if (b != null && b.Length >= 8) return BitConverter.ToInt64(b, 0);
            if (b != null && b.Length >= 4) return BitConverter.ToUInt32(b, 0);
            return 0;
        }

        /// <summary>Each display adapter's registry entry (the display class, {4d36e968-e325-11ce-bfc1-08002be10318}), one at a time: one that cannot be opened must not hide the others (0.1.0 reported nothing on Helix's PC).</summary>
        static void EachDisplayAdapter(Action<RegistryKey> each)
        {
            using (RegistryKey cls = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"))
            {
                if (cls == null) return;
                foreach (string sub in cls.GetSubKeyNames())
                {
                    if (sub.Length != 4) continue;
                    try
                    {
                        using (RegistryKey k = cls.OpenSubKey(sub))
                            if (k != null) each(k);
                    }
                    catch (Exception) { }
                }
            }
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
            s.DisplayOff = DisplayWatch.Off;
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

    /// <summary>
    /// Whether the PC's screen is on: Windows tells a window that registered for GUID_CONSOLE_DISPLAY_STATE (0 off, 1 on, 2 dimmed) every time it
    /// changes. One hidden window of the tray app listens (<see cref="Start"/>, on the interface thread); <see cref="Off"/> is read by the PC reader.
    /// </summary>
    internal sealed class DisplayWatch : NativeWindow
    {
        static readonly Guid ConsoleDisplayState = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");
        const int WmPowerBroadcast = 0x0218, PbtPowerSettingChange = 0x8013;
        static volatile bool off;
        static DisplayWatch instance;
        IntPtr registration = IntPtr.Zero;

        /// <summary>True while Windows says the screen is off (dimmed counts as on).</summary>
        public static bool Off { get { return off; } }

        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, int flags);
        [DllImport("user32.dll")] static extern bool UnregisterPowerSettingNotification(IntPtr handle);

        /// <summary>Starts listening (once; never throws: without it the screen counts as on).</summary>
        public static void Start()
        {
            if (instance != null) return;
            try
            {
                var w = new DisplayWatch();
                w.CreateHandle(new CreateParams());
                Guid g = ConsoleDisplayState;
                w.registration = RegisterPowerSettingNotification(w.Handle, ref g, 0);
                instance = w;
            }
            catch (Exception) { }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WmPowerBroadcast && m.WParam.ToInt64() == PbtPowerSettingChange && m.LParam != IntPtr.Zero)
            {
                try
                {
                    // POWERBROADCAST_SETTING: the setting's GUID (16 bytes), the data's length (4), the data (one DWORD here)
                    var setting = (Guid)Marshal.PtrToStructure(m.LParam, typeof(Guid));
                    if (setting == ConsoleDisplayState) off = Marshal.ReadInt32(m.LParam, 20) == 0;
                }
                catch (Exception) { }
            }
            base.WndProc(ref m);
        }
    }

    internal static class Native
    {
        const uint ProcessQueryLimitedInformation = 0x1000;
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, System.Text.StringBuilder name, ref int size);
        const uint Th32csSnapProcess = 0x2;
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct ProcessEntry32
        {
            public uint dwSize, cntUsage, th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID, cntThreads, th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
        }
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32FirstW")] static extern bool Process32First(IntPtr snap, ref ProcessEntry32 e);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32NextW")] static extern bool Process32Next(IntPtr snap, ref ProcessEntry32 e);

        /// <summary>For the job log: which process started <paramref name="pid"/> ("parent explorer.exe pid 1234"), from the process list (no handle on the process
        /// itself is needed, so it works for one whose path Windows will not give); "not listed" or "?" when it cannot be told.</summary>
        public static string ParentOf(int pid)
        {
            IntPtr snap = CreateToolhelp32Snapshot(Th32csSnapProcess, 0);
            if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return "?";
            try
            {
                var e = new ProcessEntry32 { dwSize = (uint)Marshal.SizeOf(typeof(ProcessEntry32)) };
                var names = new Dictionary<uint, string>();
                uint parent = 0;
                bool found = false;
                if (Process32First(snap, ref e))
                    do
                    {
                        names[e.th32ProcessID] = e.szExeFile;
                        if (e.th32ProcessID == (uint)pid) { parent = e.th32ParentProcessID; found = true; }
                    } while (Process32Next(snap, ref e));
                if (!found) return "not listed";
                string pn;
                return "parent " + (names.TryGetValue(parent, out pn) ? pn : "(ended)") + " pid " + parent;
            }
            catch (Exception) { return "?"; }
            finally { CloseHandle(snap); }
        }

        /// <summary>What Windows recorded about a crashed process <paramref name="pid"/>: the Application log's "Application Error" event (id 1000) for it, as
        /// "Windows: faulting module X, offset Y" (readable without admin rights); "" when there is none within 10 seconds or the log cannot be read. For a heap
        /// corruption the module is mostly ntdll.dll (where it was noticed, not who did it); for other crashes it names the culprit.</summary>
        public static string CrashRecord(int pid)
        {
            for (int attempt = 0; attempt < 5; attempt++)
            {
                try
                {
                    using (var log = new EventLog("Application"))
                    {
                        EventLogEntryCollection entries = log.Entries;
                        DateTime since = DateTime.Now.AddMinutes(-10);
                        for (int i = entries.Count - 1, seen = 0; i >= 0 && seen < 300; i--, seen++)
                        {
                            EventLogEntry e = entries[i];
                            if (e.TimeGenerated < since) break;
                            if (e.InstanceId != 1000 || e.Source != "Application Error") continue;
                            string m = e.Message ?? "";
                            System.Text.RegularExpressions.Match id = System.Text.RegularExpressions.Regex.Match(m, @"process id:\s*0x([0-9a-fA-F]+)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                            int got;
                            if (!id.Success || !int.TryParse(id.Groups[1].Value, System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture, out got) || got != pid) continue;
                            return "Windows: faulting module " + Field(m, "Faulting module name:") + ", offset " + Field(m, "Fault offset:");
                        }
                    }
                }
                catch (Exception) { return ""; }
                System.Threading.Thread.Sleep(2000);   // Windows writes the event while it handles the crash: it can come a moment after the exit
            }
            return "";
        }

        static string Field(string message, string label)
        {
            int i = message.IndexOf(label, StringComparison.OrdinalIgnoreCase);
            if (i < 0) return "?";
            int start = i + label.Length, end = start;
            while (end < message.Length && message[end] != ',' && message[end] != '\r' && message[end] != '\n') end++;
            return message.Substring(start, end - start).Trim();
        }

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

        // ---- ComfyUI's job object ----------------------------------------------------------------------------------------------------

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JobExtendedLimits info, int length);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        const int JobObjectExtendedLimitInformation = 9;
        const uint JobObjectLimitKillOnJobClose = 0x2000;

        [StructLayout(LayoutKind.Sequential)]
        struct JobBasicLimits
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }

        [StructLayout(LayoutKind.Sequential)]
        struct JobExtendedLimits
        {
            public JobBasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        /// <summary>
        /// Puts the app's own ComfyUI server in a Windows job object that ends it, and every process it started, when the job object closes: when the app stops the server (Dispose), and when the app
        /// ends any other way (a crash, Task Manager), because Windows closes the app's handles then. Null when Windows says no (the server still runs; the app's own stop still ends it).
        /// </summary>
        public static IDisposable ContainProcess(Process p)
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return null;
            var info = new JobExtendedLimits();
            info.Basic.LimitFlags = JobObjectLimitKillOnJobClose;
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, Marshal.SizeOf(typeof(JobExtendedLimits))) || !AssignProcessToJobObject(job, p.Handle))
            {
                CloseHandle(job);
                return null;
            }
            return new JobHandle(job);
        }

        sealed class JobHandle : IDisposable
        {
            IntPtr job;
            public JobHandle(IntPtr job) { this.job = job; }

            public void Dispose()
            {
                if (job == IntPtr.Zero) return;
                TerminateJobObject(job, 1);
                CloseHandle(job);
                job = IntPtr.Zero;
            }
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
        const long WS_EX_NOACTIVATE = 0x08000000L, WS_EX_TOOLWINDOW = 0x00000080L, WS_EX_APPWINDOW = 0x00040000L;
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out Rect r);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out Rect r);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
        [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr hWnd, ref WindowPlacement wp);
        [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr hWnd, ref WindowPlacement wp);
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);   // Windows 10 1607 and later
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeoutMs, out IntPtr result);
        const uint WM_NULL = 0, SMTO_ABORTIFHUNG = 0x2;
        [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct Pt { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] struct WindowPlacement { public int Length, Flags, ShowCmd; public Pt MinPosition, MaxPosition; public Rect NormalPosition; }
        const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;
        const int SW_HIDE = 0, SW_SHOWNOACTIVATE = 4;
        static readonly IntPtr HWND_TOP = IntPtr.Zero, HWND_BOTTOM = new IntPtr(1);
        static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);

        [ComImport, Guid("56FDF342-FD6D-11d0-958A-006097C9A090"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface ITaskbarList { void HrInit(); void AddTab(IntPtr hwnd); void DeleteTab(IntPtr hwnd); void ActivateTab(IntPtr hwnd); void SetActiveAlt(IntPtr hwnd); }
        [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090"), ClassInterface(ClassInterfaceType.None)]
        class TaskbarList { }

        /// <summary>Takes the window's taskbar button away now: the taskbar does it, so it needs no answer from the game (best effort).</summary>
        static void DropTaskbarButton(IntPtr h)
        {
            object o = null;
            try { o = new TaskbarList(); var t = (ITaskbarList)o; t.HrInit(); t.DeleteTab(h); }
            catch (Exception) { }
            finally { if (o != null) try { Marshal.ReleaseComObject(o); } catch (Exception) { } }
        }

        static long GetExStyle(IntPtr h) { return IntPtr.Size == 8 ? GetWindowLong64(h, GWL_EXSTYLE).ToInt64() : GetWindowLong32(h, GWL_EXSTYLE); }
        static void SetExStyle(IntPtr h, long v) { if (IntPtr.Size == 8) SetWindowLong64(h, GWL_EXSTYLE, new IntPtr(v)); else SetWindowLong32(h, GWL_EXSTYLE, (int)v); }

        static readonly object TameGate = new object();
        static readonly HashSet<IntPtr> Tamed = new HashSet<IntPtr>();
        static readonly Dictionary<IntPtr, int> FrontFrom = new Dictionary<IntPtr, int>();   // a benchmark window: when it was first seen (Environment.TickCount), until it had the focus
        static readonly HashSet<IntPtr> Fronted = new HashSet<IntPtr>();
        static int tamedPid;
        static IntPtr persons = IntPtr.Zero;

        /// <summary>
        /// Best effort, called every poll while the game runs. A window of the game is marked "no activate" so a click never gives it the keyboard, and sent to the bottom of the stack;
        /// if it did become the active window, the window the person was using gets it back. Windows' own rule that a background process cannot take the foreground does most of the work;
        /// this covers the rest. A run nobody should see (WindowWish.HiddenAt) starts minimized (GameOverride) and is restored outside every monitor (<see cref="RestoreOffscreen"/>),
        /// again whenever it is found minimized (a minimized Godot window does not draw), then kept there. A benchmark (WindowWish.InFront, full screen) is the opposite: brought in front with
        /// the focus (<see cref="BringToFront"/>) and otherwise left alone. Each call into the game's window waits until Godot answers.
        /// </summary>
        public static void TendGameWindow(int pid, WindowWish wish)
        {
            System.Drawing.Point? hiddenAt = wish.HiddenAt;
            System.Drawing.Size? clientSize = wish.ClientSize;
            lock (TameGate)
            {
                if (tamedPid != pid) { tamedPid = pid; Tamed.Clear(); FrontFrom.Clear(); Fronted.Clear(); }
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
                    bool fresh = Tamed.Add(h);
                    if (wish.InFront)
                    {
                        BringToFront(h);
                        continue;
                    }
                    if (hiddenAt.HasValue && IsIconic(h)) RestoreOffscreen(h, hiddenAt.Value, clientSize);
                    else if (fresh)
                    {
                        long ex = GetExStyle(h) | WS_EX_NOACTIVATE;
                        if (hiddenAt.HasValue) ex = (ex | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW;   // a run nobody should see: no taskbar button either
                        SetExStyle(h, ex);
                        SetWindowPos(h, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                    }
                    if (hiddenAt.HasValue && !IsIconic(h))
                    {
                        // kept outside every monitor: moved there the moment it appears, and back if the game places it on a monitor again
                        Rect r;
                        if (GetWindowRect(h, out r) && (r.Left != hiddenAt.Value.X || r.Top != hiddenAt.Value.Y))
                            SetWindowPos(h, HWND_BOTTOM, hiddenAt.Value.X, hiddenAt.Value.Y, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
                    }
                    if (fg == h && persons != IntPtr.Zero) SetForegroundWindow(persons);
                }
            }
        }

        /// <summary>
        /// A benchmark's window in front of everything with the focus, tried from the moment it appears for 15 s, until it has had the focus once; after that it is left alone, so a window the
        /// person picks over it stays picked. Windows does not let a program in the background hand out the focus, so this thread joins the input of the window in front for the moment of the
        /// switch (AttachThreadInput: the app sends no keys or clicks). Only once the game answers (WM_NULL within 50 ms): a call into a game still starting would wait, joined to the person's window.
        /// </summary>
        static void BringToFront(IntPtr h)
        {
            if (Fronted.Contains(h)) return;
            IntPtr fg = GetForegroundWindow();
            if (fg == h) { Fronted.Add(h); return; }
            int seen;
            if (!FrontFrom.TryGetValue(h, out seen)) FrontFrom[h] = seen = Environment.TickCount;
            if (unchecked(Environment.TickCount - seen) > 15000) return;
            IntPtr answer;
            if (SendMessageTimeout(h, WM_NULL, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 50, out answer) == IntPtr.Zero) return;
            uint ignored, me = GetCurrentThreadId();
            uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out ignored);
            bool joined = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
            try
            {
                SetWindowPos(h, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
                SetForegroundWindow(h);
            }
            finally { if (joined) AttachThreadInput(me, fgThread, false); }
            if (GetForegroundWindow() == h) Fronted.Add(h);
        }

        /// <summary>
        /// A minimized window of a run nobody should see, back at its normal size outside every monitor. Its taskbar button goes at once (the taskbar removes it while the game is still busy
        /// starting); once the game answers, the window is hidden (the restore has no button to animate from), gets "no activate" and no taskbar button for good, and its normal place is set to
        /// <paramref name="spot"/> and shown there without the focus, in one SetWindowPlacement (SetWindowPos would only move the minimized window). Then the size the run asks for is applied
        /// again, in real pixels: Windows created the window at most the screen's size and the game's own resize past it (`--qa-window`) came while it was minimized, which does not change
        /// the normal size, and this app's scaled view of a DPI-aware window may round it by a pixel. If the placement fails, the window is restored where it was and the next poll moves it.
        /// </summary>
        static void RestoreOffscreen(IntPtr h, System.Drawing.Point spot, System.Drawing.Size? clientSize)
        {
            DropTaskbarButton(h);
            ShowWindow(h, SW_HIDE);
            SetExStyle(h, (GetExStyle(h) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
            var wp = new WindowPlacement { Length = Marshal.SizeOf(typeof(WindowPlacement)) };
            bool placed = false;
            if (GetWindowPlacement(h, ref wp))
            {
                Rect n = wp.NormalPosition;
                wp.NormalPosition = new Rect { Left = spot.X, Top = spot.Y, Right = spot.X + (n.Right - n.Left), Bottom = spot.Y + (n.Bottom - n.Top) };
                wp.Flags = 0;
                wp.ShowCmd = SW_SHOWNOACTIVATE;
                placed = SetWindowPlacement(h, ref wp);
            }
            if (!placed) ShowWindow(h, SW_SHOWNOACTIVATE);
            SetWindowPos(h, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            if (clientSize.HasValue) SizeClient(h, clientSize.Value);
        }

        /// <summary>The window's inside (client area) at <paramref name="want"/> pixels, measured and set in real pixels (this app is not DPI aware; Godot is), the frame kept as it is.</summary>
        static void SizeClient(IntPtr h, System.Drawing.Size want)
        {
            IntPtr was = IntPtr.Zero;
            try { was = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2); } catch (EntryPointNotFoundException) { }
            try
            {
                Rect w, c;
                if (!GetWindowRect(h, out w) || !GetClientRect(h, out c)) return;
                int cw = c.Right - c.Left, ch = c.Bottom - c.Top;
                if (cw == want.Width && ch == want.Height) return;
                SetWindowPos(h, IntPtr.Zero, 0, 0, want.Width + (w.Right - w.Left - cw), want.Height + (w.Bottom - w.Top - ch), SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            }
            finally { if (was != IntPtr.Zero) SetThreadDpiAwarenessContext(was); }
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
