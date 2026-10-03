using System;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;

namespace DeathMuffinLauncher
{
    /// <summary>
    /// One shared WebView2 environment for the whole process: the game window and the hidden precache page use the same
    /// persistent profile (shader cache + HTTP cache survive restarts), and WebView2 requires every WebView on one profile to
    /// be created with identical browser arguments.
    /// </summary>
    internal static class WebViewHost
    {
        static Task<CoreWebView2Environment> env;

        /// <summary>
        /// Chromium switches for the game. Microsoft documents browser flags as unsupported for production use (they may change),
        /// so each one is harmless if ignored. See launcher/windows/README.md for what each does.
        /// </summary>
        public static string BrowserArguments(bool highPerformanceGpu)
        {
            string args = "--disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows";
            if (highPerformanceGpu) args = "--force_high_performance_gpu " + args;
            return args;
        }

        /// <summary>Result of the start-up check: the runtime version, or why it could not be read.</summary>
        public sealed class RuntimeCheck
        {
            /// <summary>Installed runtime version, or null.</summary>
            public string Version;
            /// <summary>True only when WebView2 itself says no runtime is installed (and the registry agrees).</summary>
            public bool Missing;
            /// <summary>Set when the check failed for another reason (usually launcher files missing beside the exe).</summary>
            public string Problem;
        }

        /// <summary>
        /// Asks WebView2 for the installed runtime. Only a WebView2RuntimeNotFoundException means "not installed"; anything else
        /// (no WebView2Loader.dll / Core dll next to the exe, e.g. run from inside the zip) is reported as a launcher-files problem,
        /// and the registry is checked as a second opinion so a working install is never reported as missing.
        /// </summary>
        public static RuntimeCheck CheckRuntime()
        {
            var r = new RuntimeCheck();
            try { r.Version = QueryVersion(); }
            catch (WebView2RuntimeNotFoundException) { r.Missing = true; }
            catch (Exception ex) { r.Problem = ex.GetType().Name + ": " + ex.Message; }
            if (r.Version == null && r.Problem == null) r.Missing = true;
            if (r.Version == null)
            {
                string reg = RegistryVersion();
                if (reg != null) { r.Version = reg; r.Missing = false; }
            }
            if (r.Problem == null && LooksUnextracted()) r.Problem = "The launcher is running from inside the zip.";
            return r;
        }

        // Separate, non-inlined so a missing Microsoft.Web.WebView2.Core.dll throws inside CheckRuntime's try instead of when
        // the caller is compiled.
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        static string QueryVersion() { return CoreWebView2Environment.GetAvailableBrowserVersionString(); }

        /// <summary>The Evergreen runtime registers itself under EdgeUpdate (machine-wide, 32-bit view, or per-user).</summary>
        static string RegistryVersion()
        {
            const string key = @"Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
            foreach (var path in new[] { @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\" + key, @"HKEY_LOCAL_MACHINE\SOFTWARE\" + key, @"HKEY_CURRENT_USER\Software\" + key })
            {
                try
                {
                    var v = Microsoft.Win32.Registry.GetValue(path, "pv", null) as string;
                    if (!string.IsNullOrEmpty(v) && v != "0.0.0.0") return v;
                }
                catch { }
            }
            return null;
        }

        /// <summary>Opening the exe straight from a zip in Explorer copies only the exe to a temp folder, without the DLLs.</summary>
        static bool LooksUnextracted()
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            return !System.IO.File.Exists(System.IO.Path.Combine(dir, "Microsoft.Web.WebView2.Core.dll"))
                || !System.IO.Directory.Exists(System.IO.Path.Combine(dir, "runtimes"));
        }

        public static Task<CoreWebView2Environment> GetEnvironmentAsync(Settings settings)
        {
            if (env == null)
            {
                var options = new CoreWebView2EnvironmentOptions(additionalBrowserArguments: BrowserArguments(settings.HighPerformanceGpu));
                env = CoreWebView2Environment.CreateAsync(null, Settings.ProfileDir, options);
            }
            return env;
        }
    }
}
