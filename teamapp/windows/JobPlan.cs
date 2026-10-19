using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace DeathMuffinTeam
{
    /// <summary>One file a job downloads. Files with a cache key are kept across jobs (the art pack, the Godot debug template).</summary>
    internal sealed class PlanFile
    {
        public string Name = "";
        public Uri Url;
        public string Sha256 = "";
        public long Bytes;
        /// <summary>"" for a file that is only for this job; otherwise the folder name under cache\ that keeps it.</summary>
        public string CacheKey = "";

        public bool IsCached { get { return CacheKey.Length > 0; } }
    }

    /// <summary>
    /// A `shots` job's payload, checked. Everything here comes from the server, but the app still refuses anything that could leave the job's folder, reach another
    /// host, or change how the game starts: file names and URLs, checksums, the arguments the game is started with, and the graphics presets.
    /// </summary>
    internal sealed class JobPlan
    {
        public const string Kind = "shots";
        /// <summary>The debug build of Godot a job downloads, and the game's code pack it is started with: both must be in every job.</summary>
        public const string GameExe = "DeathMuffinDebug.exe";
        public const string MainPack = "DeathMuffinDebug.pck";   // Godot loads "<exe name>.pck" from the exe's folder by itself: export builds refuse --main-pack
        public const string Resolution = "1600x900";
        public const int MaxFiles = 12;
        public const int MaxArgs = 16;
        public const long MaxFileBytes = 8L << 30;
        public const int MaxPlanBytes = 65536;
        /// <summary>The server keeps at most this many pictures a job.</summary>
        public const int MaxUploads = 40;
        public const int MaxUploadBytes = 8 << 20;

        public static readonly string[] KnownPresets = { "low", "medium", "high", "ultra" };
        /// <summary>What the app sets itself: a payload that tries to pass one of these is refused (the game must stay offline, in the job's folder, on the preset asked for).</summary>
        static readonly string[] ReservedArgs =
        {
            "shot-plan", "shots", "preset", "assets-pack", "baked", "bench-dir", "shot", "online",
            "main-pack", "path", "script", "headless", "windowed", "fullscreen", "resolution", "position", "rendering-driver", "rendering-method", "log-file",
        };
        static readonly string[] DeviceNames = { "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9" };

        static readonly Regex NameRe = new Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$", RegexOptions.CultureInvariant);
        static readonly Regex CacheKeyRe = new Regex("^[a-z0-9][a-z0-9._-]{0,63}$", RegexOptions.CultureInvariant);
        static readonly Regex RevRe = new Regex("^[0-9a-f]{7,40}$", RegexOptions.CultureInvariant);
        static readonly Regex VersionRe = new Regex("^[A-Za-z0-9._-]{1,32}$", RegexOptions.CultureInvariant);
        static readonly Regex ArgRe = new Regex("^--([a-z][a-z0-9-]{0,30})(=[A-Za-z0-9_.,-]{1,40})?$", RegexOptions.CultureInvariant);
        static readonly Regex ShotRe = new Regex("[^a-z0-9_-]+", RegexOptions.CultureInvariant);

        public string Rev = "";
        public string GodotVersion = "";
        public List<PlanFile> Files = new List<PlanFile>();
        /// <summary>The proposal's shot plan as the JSON text written to plan.json for the game's --shot-plan.</summary>
        public string PlanJson = "";
        public int PlanShots;
        public List<string> Presets = new List<string>();
        /// <summary>The game's options after `--`, as the server sent them and checked (`--dev-offline` is added when missing).</summary>
        public List<string> Args = new List<string>();

        public PlanFile FileNamed(string name)
        {
            foreach (var f in Files) if (string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase)) return f;
            return null;
        }

        /// <summary>Parses and checks a payload (an object, or JSON text of one). File URLs must be on <paramref name="siteBase"/>'s scheme, host and port, under its team-files/ folder.</summary>
        public static bool TryParse(object payload, Uri siteBase, out JobPlan plan, out string error)
        {
            plan = null;
            error = null;
            var d = payload as Dictionary<string, object>;
            if (d == null && payload is string) d = MiniJson.TryObject((string)payload);
            if (d == null) { error = "The job has no details."; return false; }

            var p = new JobPlan();
            p.Rev = MiniJson.Str(d, "rev");
            if (p.Rev.Length > 0 && !RevRe.IsMatch(p.Rev)) { error = "The job names a build that is not a revision."; return false; }
            p.GodotVersion = MiniJson.Str(d, "godotVersion");
            if (p.GodotVersion.Length > 0 && !VersionRe.IsMatch(p.GodotVersion)) { error = "The job names a Godot version that is not valid."; return false; }

            var files = MiniJson.Arr(d, "files");
            if (files == null || files.Count == 0) { error = "The job lists no files to download."; return false; }
            if (files.Count > MaxFiles) { error = "The job lists too many files (" + files.Count + ")."; return false; }
            string prefix = siteBase.AbsolutePath;
            if (!prefix.EndsWith("/", StringComparison.Ordinal)) prefix += "/";
            prefix += TeamUrls.FilesPath;
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (object o in files)
            {
                var fd = o as Dictionary<string, object>;
                if (fd == null) { error = "The job has a file entry that is not valid."; return false; }
                var f = new PlanFile { Name = MiniJson.Str(fd, "name"), Sha256 = MiniJson.Str(fd, "sha256").ToLowerInvariant(), CacheKey = MiniJson.Str(fd, "cacheKey") };
                if (!SafeName(f.Name)) { error = "A file name in the job is not allowed: \"" + Shorten(f.Name) + "\"."; return false; }
                if (!seen.Add(f.Name)) { error = "The job lists " + f.Name + " twice."; return false; }
                if (!Hashing.IsHex64(f.Sha256)) { error = "The job gives no valid checksum for " + f.Name + "."; return false; }
                long? bytes = MiniJson.Int(fd, "bytes");
                if (bytes == null || bytes.Value < 1 || bytes.Value > MaxFileBytes) { error = "The job gives no valid size for " + f.Name + "."; return false; }
                f.Bytes = bytes.Value;
                if (f.CacheKey.Length > 0 && (!CacheKeyRe.IsMatch(f.CacheKey) || f.CacheKey.Contains(".."))) { error = "The cache name for " + f.Name + " is not allowed."; return false; }
                string urlErr;
                f.Url = CheckUrl(MiniJson.Str(fd, "url"), siteBase, prefix, out urlErr);
                if (f.Url == null) { error = "The download address of " + f.Name + " is not allowed (" + urlErr + ")."; return false; }
                p.Files.Add(f);
            }
            if (p.FileNamed(GameExe) == null || p.FileNamed(MainPack) == null) { error = "The job does not include " + GameExe + " and " + MainPack + "."; return false; }

            var plan0 = MiniJson.Obj(d, "plan");
            var shots = MiniJson.Arr(plan0, "shots");
            if (plan0 == null || shots == null || shots.Count == 0) { error = "The job has no shot plan."; return false; }
            p.PlanJson = MiniJson.Write(plan0);
            if (Encoding.UTF8.GetByteCount(p.PlanJson) > MaxPlanBytes) { error = "The shot plan is too big."; return false; }
            p.PlanShots = shots.Count;

            var presets = MiniJson.Arr(d, "presets");
            if (presets == null || presets.Count == 0 || presets.Count > KnownPresets.Length) { error = "The job names no graphics presets."; return false; }
            foreach (object o in presets)
            {
                string s = o as string;
                if (s == null || Array.IndexOf(KnownPresets, s) < 0) { error = "The job asks for a graphics preset that does not exist."; return false; }
                if (p.Presets.Contains(s)) { error = "The job lists the preset " + s + " twice."; return false; }
                p.Presets.Add(s);
            }

            object rawArgs;
            if (d.TryGetValue("args", out rawArgs) && rawArgs != null && !(rawArgs is List<object>)) { error = "The job's game options are not a list."; return false; }
            var args = MiniJson.Arr(d, "args") ?? new List<object>();
            if (args.Count > MaxArgs) { error = "The job passes too many game options."; return false; }
            foreach (object o in args)
            {
                string a = o as string;
                Match m = a == null ? null : ArgRe.Match(a);
                if (m == null || !m.Success) { error = "A game option in the job is not allowed: \"" + Shorten(o as string) + "\"."; return false; }
                if (Array.IndexOf(ReservedArgs, m.Groups[1].Value) >= 0) { error = "The job tries to set --" + m.Groups[1].Value + ", which the app sets itself."; return false; }
                if (!p.Args.Contains(a)) p.Args.Add(a);
            }
            if (!p.Args.Contains("--dev-offline")) p.Args.Insert(0, "--dev-offline");

            plan = p;
            return true;
        }

        static string Shorten(string s) { s = s ?? ""; return s.Length > 40 ? s.Substring(0, 40) + "..." : s; }

        /// <summary>A plain file name: letters, digits, dots, dashes and underscores, no path, no "..", no Windows device name.</summary>
        public static bool SafeName(string name)
        {
            if (string.IsNullOrEmpty(name) || !NameRe.IsMatch(name) || name.Contains("..") || name.EndsWith(".", StringComparison.Ordinal)) return false;
            string stem = name.Contains(".") ? name.Substring(0, name.IndexOf('.')) : name;
            return Array.IndexOf(DeviceNames, stem.ToLowerInvariant()) < 0;
        }

        static Uri CheckUrl(string s, Uri siteBase, string prefix, out string why)
        {
            why = "";
            if (string.IsNullOrEmpty(s) || s.Length > 400) { why = "missing"; return null; }
            string low = s.ToLowerInvariant();
            if (low.Contains("\\") || low.Contains("..") || low.Contains("%2e") || low.Contains("%2f") || low.Contains("%5c") || low.Contains("%00") || low.Contains("@") || low.Contains("#") || low.Contains("?"))
            { why = "unsafe characters"; return null; }
            Uri u;
            if (!Uri.TryCreate(s, UriKind.Absolute, out u)) { why = "not an address"; return null; }
            if (u.Scheme != siteBase.Scheme || !string.Equals(u.Host, siteBase.Host, StringComparison.OrdinalIgnoreCase) || u.Port != siteBase.Port) { why = "not on the game's server"; return null; }
            if (!u.AbsolutePath.StartsWith(prefix, StringComparison.Ordinal) || u.AbsolutePath.Length == prefix.Length || u.AbsolutePath.EndsWith("/", StringComparison.Ordinal)) { why = "not in the team files folder"; return null; }
            return u;
        }

        // ---- The command line ------------------------------------------------------------------------------------------------------

        /// <summary>The game's arguments for one preset: `--windowed --resolution 1600x900 -- <options> --shot-plan=<file> --shots=<dir> --preset=<preset>`. Paths use "/".</summary>
        public List<string> CommandArgs(string preset, string planFile, string shotsDir)
        {
            var a = new List<string> { "--windowed", "--resolution", Resolution, "--" };
            a.AddRange(Args);
            a.Add("--shot-plan=" + Slashes(planFile));
            a.Add("--shots=" + Slashes(shotsDir));
            a.Add("--preset=" + preset);
            return a;
        }

        public string CommandLine(string preset, string planFile, string shotsDir) { return CommandLineText.Join(CommandArgs(preset, planFile, shotsDir)); }

        static string Slashes(string path) { return path.Replace('\\', '/'); }

        public static string PresetLabel(string preset)
        {
            return string.IsNullOrEmpty(preset) ? "" : char.ToUpperInvariant(preset[0]) + preset.Substring(1);
        }

        // ---- Pictures to upload -----------------------------------------------------------------------------------------------------

        /// <summary>`low` and `bag-open.png` -> `low_bag-open.png`: the name the server accepts (`^[a-z0-9_-]{1,60}\.png$`). Null for a file that is not a .png.</summary>
        public static string UploadName(string preset, string fileName)
        {
            string f = fileName ?? "";
            f = f.Substring(Math.Max(f.LastIndexOf('/'), f.LastIndexOf('\\')) + 1);   // the last segment, whichever separator the path uses
            if (!f.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) return null;
            string shot = ShotRe.Replace(f.Substring(0, f.Length - 4).ToLowerInvariant(), "_").Trim('_');
            if (shot.Length == 0) shot = "shot";
            string head = preset + "_";
            int room = 60 - head.Length - 4;
            if (shot.Length > room) shot = shot.Substring(0, room);
            return head + shot + ".png";
        }

        /// <summary>Names for a preset's picture files, one each: a name that collides gets -2, -3 (names are unique across <paramref name="used"/>).</summary>
        public static List<KeyValuePair<string, string>> UploadNames(string preset, IEnumerable<string> files, HashSet<string> used)
        {
            var result = new List<KeyValuePair<string, string>>();
            var sorted = new List<string>(files);
            sorted.Sort(StringComparer.Ordinal);
            foreach (string file in sorted)
            {
                string name = UploadName(preset, file);
                if (name == null) continue;
                string stem = name.Substring(0, name.Length - 4);
                for (int n = 2; used.Contains(name); n++)
                {
                    string tail = "-" + n.ToString(CultureInfo.InvariantCulture);
                    name = (stem.Length + tail.Length > 56 ? stem.Substring(0, 56 - tail.Length) : stem) + tail + ".png";
                }
                used.Add(name);
                result.Add(new KeyValuePair<string, string>(file, name));
            }
            return result;
        }
    }

    /// <summary>Windows command-line quoting (the rules CommandLineToArgvW and the C runtime read back): a path with a space stays one argument.</summary>
    internal static class CommandLineText
    {
        public static string Quote(string arg)
        {
            arg = arg ?? "";
            if (arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return arg;
            var sb = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in arg)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { sb.Append('\\', slashes * 2 + 1).Append('"'); slashes = 0; continue; }
                sb.Append('\\', slashes).Append(c);
                slashes = 0;
            }
            sb.Append('\\', slashes * 2).Append('"');
            return sb.ToString();
        }

        public static string Join(IEnumerable<string> args)
        {
            var parts = new List<string>();
            foreach (string a in args) parts.Add(Quote(a));
            return string.Join(" ", parts);
        }
    }
}
