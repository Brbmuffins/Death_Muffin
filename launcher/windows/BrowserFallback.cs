using System;
using System.Diagnostics;
using System.IO;

namespace DeathMuffinLauncher
{
    /// <summary>
    /// Used when WebView2 is missing or will not start: opens the game in an installed Chromium browser as its own app window
    /// (--app, no tabs or address bar), or in the default browser (Firefox etc.) when no Chromium browser is found. The browser's
    /// normal profile is used, so the player stays logged in there; the launcher's performance flags only apply inside WebView2.
    /// </summary>
    internal static class BrowserFallback
    {
        static readonly string[][] Candidates =
        {
            new[] { "Google Chrome", "chrome.exe", @"Google\Chrome\Application\chrome.exe" },
            new[] { "Microsoft Edge", "msedge.exe", @"Microsoft\Edge\Application\msedge.exe" },
            new[] { "Brave", "brave.exe", @"BraveSoftware\Brave-Browser\Application\brave.exe" },
        };

        /// <summary>Opens <paramref name="url"/> and returns the name of the browser used, or null if nothing could be started.</summary>
        public static string Open(string url)
        {
            foreach (var c in Candidates)
            {
                string exe = Find(c[1], c[2]);
                if (exe == null) continue;
                try
                {
                    Process.Start(new ProcessStartInfo(exe, "--app=\"" + url + "\"") { UseShellExecute = false });
                    return c[0];
                }
                catch { }
            }
            try
            {
                Process.Start(url);
                return "your default browser";
            }
            catch { return null; }
        }

        static string Find(string exeName, string relative)
        {
            // Installers register their exe under App Paths (machine-wide or per-user).
            foreach (var hive in new[] { "HKEY_LOCAL_MACHINE", "HKEY_CURRENT_USER" })
            {
                try
                {
                    var p = Microsoft.Win32.Registry.GetValue(hive + @"\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\" + exeName, "", null) as string;
                    if (!string.IsNullOrEmpty(p) && File.Exists(p.Trim('"'))) return p.Trim('"');
                }
                catch { }
            }
            foreach (var root in new[]
            {
                Environment.GetEnvironmentVariable("ProgramFiles"),
                Environment.GetEnvironmentVariable("ProgramFiles(x86)"),
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            })
            {
                if (string.IsNullOrEmpty(root)) continue;
                string p = Path.Combine(root, relative);
                if (File.Exists(p)) return p;
            }
            return null;
        }
    }
}
