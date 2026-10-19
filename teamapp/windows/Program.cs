using System;
using System.Diagnostics;
using System.Threading;
using System.Windows.Forms;

namespace DeathMuffinTeam
{
    internal static class Program
    {
        /// <summary>Three-part version from the csproj, e.g. "0.1.0".</summary>
        public static string Version
        {
            get
            {
                var v = typeof(Program).Assembly.GetName().Version;
                return v.Major + "." + v.Minor + "." + v.Build;
            }
        }

        /// <summary>A copy started by a self-update passes this: the old copy is still closing, so wait for it instead of exiting.</summary>
        public const string AfterUpdateArg = "--after-update";

        [STAThread]
        private static void Main(string[] args)
        {
            bool afterUpdate = Array.IndexOf(args, AfterUpdateArg) >= 0;
            bool created;
            using (var one = new Mutex(true, "Local\\DeathMuffinTeam", out created))
            {
                bool owned = created;
                if (!owned && afterUpdate)
                {
                    try { owned = one.WaitOne(20000); }
                    catch (AbandonedMutexException) { owned = true; }
                }
                if (!owned) return;   // one copy per Windows user

                // What a self-update left behind: the previous exe (.old) and any half download (SelfUpdate.cs).
                SelfUpdate.CleanUp(Application.ExecutablePath);
                // The app and the game it starts run below normal priority: a job never competes with what the person is doing.
                try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal; } catch (Exception) { }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                var log = new AppLog(TeamSettings.Root);
                Application.ThreadException += (s, e) => log.Line("unexpected error: " + e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => log.Line("unexpected error: " + e.ExceptionObject);
                Application.Run(new TrayContext(log));
                try { one.ReleaseMutex(); } catch (ApplicationException) { }
            }
        }
    }
}
