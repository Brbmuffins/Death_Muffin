using System;
using System.Windows.Forms;

namespace DeathMuffinLauncher
{
    internal static class Program
    {
        /// <summary>Three-part version from the csproj, e.g. "0.2.0".</summary>
        public static string Version
        {
            get
            {
                var v = typeof(Program).Assembly.GetName().Version;
                return v.Major + "." + v.Minor + "." + v.Build;
            }
        }

        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new LauncherForm());
        }
    }
}
