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

        /// <summary>Null when the WebView2 Runtime is not installed.</summary>
        public static string RuntimeVersion()
        {
            try { return CoreWebView2Environment.GetAvailableBrowserVersionString(); }
            catch { return null; }
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
