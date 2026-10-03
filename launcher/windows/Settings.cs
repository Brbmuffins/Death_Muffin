using System;
using System.IO;
using System.Web.Script.Serialization;

namespace DeathMuffinLauncher
{
    /// <summary>Small JSON settings file next to the WebView2 profile: %LOCALAPPDATA%\DeathMuffin\launcher-settings.json.</summary>
    internal sealed class Settings
    {
        public bool HighPerformanceGpu { get; set; } = true;
        /// <summary>Release sha whose files were last fully warmed into the profile's HTTP cache.</summary>
        public string LastPrecachedSha { get; set; } = "";

        public static string Root
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeathMuffin"); }
        }
        public static string ProfileDir { get { return Path.Combine(Root, "LauncherProfile"); } }
        static string FilePath { get { return Path.Combine(Root, "launcher-settings.json"); } }

        public static Settings Load()
        {
            try
            {
                if (File.Exists(FilePath))
                    return new JavaScriptSerializer().Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
            }
            catch { /* corrupt or unreadable: fall back to defaults */ }
            return new Settings();
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Root);
                File.WriteAllText(FilePath, new JavaScriptSerializer().Serialize(this));
            }
            catch { /* settings are a convenience; never block play */ }
        }
    }
}
