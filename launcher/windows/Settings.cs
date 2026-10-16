using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace DeathMuffinLauncher
{
    /// <summary>
    /// Small JSON settings file next to the installed clients: %LOCALAPPDATA%\DeathMuffin\launcher-settings.json.
    /// Read with MiniJson and written by hand (no System.Web), so launcher/tests compiles this file and round-trips the real thing.
    /// </summary>
    internal sealed class Settings
    {
        public bool HighPerformanceGpu { get; set; } = true;
        /// <summary>Team only (DECISIONS B38): the launcher installs, updates and plays the test build instead of the normal game. Default off.</summary>
        public bool TestBuild { get; set; }

        public static string Root
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeathMuffin"); }
        }
        /// <summary>Where a channel's installed Godot client versions live (see ClientStore): client\ for the game, client-test\ for the test build.</summary>
        public static string InstallDir(ClientChannel channel) { return Channels.InstallDir(Root, channel); }

        public ClientChannel Channel { get { return Channels.Of(TestBuild); } }

        public static string DefaultFile { get { return Path.Combine(Root, "launcher-settings.json"); } }

        public static Settings Load(string file = null)
        {
            try
            {
                file = file ?? DefaultFile;
                if (File.Exists(file)) return FromJson(File.ReadAllText(file));
            }
            catch { /* corrupt or unreadable: fall back to defaults */ }
            return new Settings();
        }

        public void Save(string file = null)
        {
            try
            {
                file = file ?? DefaultFile;
                Directory.CreateDirectory(Path.GetDirectoryName(file));
                File.WriteAllText(file, ToJson(), new UTF8Encoding(false));
            }
            catch { /* settings are a convenience; never block play */ }
        }

        /// <summary>Same property names the file always had. A missing, mistyped or unknown key keeps its default; broken JSON gives the defaults.</summary>
        public static Settings FromJson(string json)
        {
            var s = new Settings();
            try
            {
                var d = MiniJson.Parse(json) as Dictionary<string, object>;
                if (d == null) return s;
                object v;
                if (d.TryGetValue("HighPerformanceGpu", out v) && v is bool) s.HighPerformanceGpu = (bool)v;
                if (d.TryGetValue("TestBuild", out v) && v is bool) s.TestBuild = (bool)v;
            }
            catch (FormatException) { /* defaults */ }
            return s;
        }

        public string ToJson()
        {
            return "{\"HighPerformanceGpu\":" + (HighPerformanceGpu ? "true" : "false") + ",\"TestBuild\":" + (TestBuild ? "true" : "false") + "}";
        }
    }
}
