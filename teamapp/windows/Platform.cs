using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

// Everything that needs Windows: DPAPI, the full-screen and battery checks, hard links, the game's window, the start-with-Windows switch.
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
            try { return p.MainModule.FileName.StartsWith(ownRoot, StringComparison.OrdinalIgnoreCase); }
            catch (Exception) { return false; }
        }

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
            try
            {
                var names = new List<string>();
                using (RegistryKey cls = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11cd-b6bb-00a0c91d1e40}"))
                {
                    if (cls == null) return "";
                    foreach (string sub in cls.GetSubKeyNames())
                    {
                        if (sub.Length != 4) continue;
                        using (RegistryKey k = cls.OpenSubKey(sub))
                        {
                            string desc = k == null ? null : k.GetValue("DriverDesc") as string;
                            if (!string.IsNullOrWhiteSpace(desc) && !names.Contains(desc.Trim())) names.Add(desc.Trim());
                        }
                    }
                }
                return string.Join(" + ", names);
            }
            catch (Exception) { return ""; }
        }
    }

    internal static class Native
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateHardLink(string newFileName, string existingFileName, IntPtr securityAttributes);

        /// <summary>A hard link to a file on the same drive (the cached art pack shows up in the job's game folder without a second copy). False when Windows says no.</summary>
        public static bool TryHardLink(string link, string existing)
        {
            try { return CreateHardLink(link, existing, IntPtr.Zero); }
            catch (Exception) { return false; }
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
