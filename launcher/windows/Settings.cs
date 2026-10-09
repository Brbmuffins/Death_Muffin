using System;
using System.IO;
using System.Web.Script.Serialization;

namespace DeathMuffinLauncher
{
    /// <summary>Small JSON settings file next to the installed client: %LOCALAPPDATA%\DeathMuffin\launcher-settings.json.</summary>
    internal sealed class Settings
    {
        public bool HighPerformanceGpu { get; set; } = true;
        public static string Root
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeathMuffin"); }
        }
        /// <summary>Installed Godot client versions (see ClientStore).</summary>
        public static string ClientDir { get { return Path.Combine(Root, "client"); } }
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
