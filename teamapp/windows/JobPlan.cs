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

    /// <summary>One game build of a `shots` job that has two (before and after a change): its label and its own files (the files both builds share are downloaded once).</summary>
    internal sealed class PlanBuild
    {
        /// <summary>"" for a job with one build; otherwise `before` or `after`.</summary>
        public string Label = "";
        public List<PlanFile> Files = new List<PlanFile>();
    }

    /// <summary>One game run of a `clip` job: a label for the videos it makes (`slow`; `clip` when the job gives none) and the data overrides for the run (`--tune`), as the JSON text written to its tune file.</summary>
    internal sealed class ClipVariant
    {
        public string Label = JobPlan.ClipLabelDefault;
        /// <summary>The tune object as JSON text, or null for a run with no `--tune`.</summary>
        public string TuneJson;

        public bool HasTune { get { return TuneJson != null; } }
    }

    /// <summary>One window size of a `release` job's `screens` step.</summary>
    internal sealed class ScreenSize
    {
        public int Width, Height;

        public string Text { get { return Width.ToString(CultureInfo.InvariantCulture) + "x" + Height.ToString(CultureInfo.InvariantCulture); } }
    }

    /// <summary>One benchmark run of a `bench` job: the graphics preset and the game's own setup (`--bench-room`, `--bench-class`, `--bench-size`, `--bench-length`).</summary>
    internal sealed class BenchSetup
    {
        public string Preset = "", Room = "", Size = "", Length = "";
        public int Class;

        /// <summary>"graves, full_party, standard, class 2" (the log's words for the setup; the preset is named beside it).</summary>
        public string Describe() { return Room + ", " + Size + ", " + Length + ", class " + Class.ToString(CultureInfo.InvariantCulture); }
    }

    /// <summary>
    /// A job's payload, checked (kind `shots`: screenshots of a proposal on some presets, of one build or of a before and an after build; kind `clip`: short videos of a change, one game run for each
    /// variant to choose from; kind `bench`: the game's own benchmark on some setups). Everything here comes from the
    /// server, but the app still refuses anything that could leave the job's folder, reach another host, or change how the game starts: file names and URLs, checksums, the
    /// arguments the game is started with, the graphics presets and the benchmark setups.
    /// </summary>
    internal sealed class JobPlan
    {
        public const string ShotsKind = "shots";
        public const string BenchKind = "bench";
        public const string ClipKind = "clip";
        /// <summary>The release checks of a new client on a team PC: steps run in order, each result uploaded as it finishes, a step that fails does not stop the next.</summary>
        public const string ReleaseKind = "release";
        /// <summary>The two builds a `release` job lists: the RELEASE files (install, quit while loading, bench) and the DEBUG build of the same revision (screens, stutter, soak).</summary>
        public const string ReleaseBuild = "release";
        public const string DebugBuild = "debug";
        public static readonly string[] ReleaseSteps = { "install", "quit-loading", "screens", "stutter", "bench", "soak" };
        public static readonly string[] DefaultResolutions = { "1920x1080", "2560x1440", "3840x2160", "3440x1440" };
        public const int MaxScreenSizes = 6;
        public const int MaxUiScales = 3;
        public const int DefaultSoakMinutes = 30;
        public const int MaxSoakMinutes = 120;
        /// <summary>The server takes 120 files a release job: this many pictures leave room for each step's result file.</summary>
        public const int MaxReleaseUploads = 110;
        /// <summary>The label of the videos of a clip job that names no variants (or a variant with no label): `clip_<name>.mjpeg`.</summary>
        public const string ClipLabelDefault = "clip";
        /// <summary>A clip job's limits: the server takes at most 48 MB a clip; the game writes at most 4 clips of 8 seconds a run, at 30 frames per game second (the engine's --fixed-fps).</summary>
        public const int MaxClips = 4;
        public const int MaxVariants = 4;
        public const int MaxClipSeconds = 8;
        public const int MaxTuneBytes = 32 * 1024;
        public const int MaxClipBytes = 48 << 20;
        public const int ClipFps = 30;
        /// <summary>The graphics preset of a clip job that names none.</summary>
        public const string ClipPresetDefault = "high";
        /// <summary>The debug build of Godot a `shots` job downloads, and the game's code pack it is started with: both must be in every such job.</summary>
        public const string GameExe = "DeathMuffinDebug.exe";
        public const string MainPack = "DeathMuffinDebug.pck";   // Godot loads "<exe name>.pck" from the exe's folder by itself: export builds refuse --main-pack
        /// <summary>The files of a `bench` job: the RELEASE build (honest numbers), its code pack (the game loads `DeathMuffin.pck` beside `DeathMuffin.exe` itself, as above), the combat core and the art pack.</summary>
        public const string BenchExe = "DeathMuffin.exe";
        public static readonly string[] BenchFiles = { BenchExe, "DeathMuffin.pck", "libdmcore.windows.template_release.x86_64.dll", "DeathMuffin.assets.pck" };
        public const int MaxSetups = 6;
        /// <summary>The server takes a run of at most this many bytes of JSON.</summary>
        public const int MaxRunBytes = 64 * 1024;
        public const string Resolution = "1600x900";
        public const int MaxFiles = 12;
        public const int MaxArgs = 16;
        public const long MaxFileBytes = 8L << 30;
        public const int MaxPlanBytes = 65536;
        /// <summary>The server keeps at most this many pictures a job.</summary>
        public const int MaxUploads = 40;
        public const int MaxUploadBytes = 8 << 20;

        public static readonly string[] KnownPresets = { "low", "medium", "high", "ultra" };
        /// <summary>The labels a `shots` job's builds may have (the pictures of the first are the "before").</summary>
        public static readonly string[] BuildLabels = { "before", "after" };
        public static readonly string[] BenchSizes = { "light", "standard", "heavy", "full_party" };
        /// <summary>The lengths the game knows (`--bench-length`): a length it does not know silently becomes its `full`, so no other word is accepted.</summary>
        public static readonly string[] BenchLengths = { "quick", "full" };
        /// <summary>What the app sets itself: a payload that tries to pass one of these is refused (the game must stay offline, in the job's folder, on the preset asked for).</summary>
        static readonly string[] ReservedArgs =
        {
            "shot-plan", "shots", "preset", "assets-pack", "baked", "shot", "online",
            "benchmark", "bench-dir", "bench-room", "bench-class", "bench-size", "bench-length", "bench-preset", "bench-quit", "audio-driver",
            "main-pack", "path", "script", "headless", "windowed", "fullscreen", "resolution", "position", "rendering-driver", "rendering-method", "log-file",
            "clip-plan", "clips", "tune", "fixed-fps",
            "boot-check", "quit-while-loading", "stutter", "stutter-out", "soak", "soak-out", "ui-scale",
        };
        static readonly string[] DeviceNames = { "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9" };

        static readonly Regex NameRe = new Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$", RegexOptions.CultureInvariant);
        static readonly Regex CacheKeyRe = new Regex("^[a-z0-9][a-z0-9._-]{0,63}$", RegexOptions.CultureInvariant);
        static readonly Regex RevRe = new Regex("^[0-9a-f]{7,40}$", RegexOptions.CultureInvariant);
        static readonly Regex VersionRe = new Regex("^[A-Za-z0-9._-]{1,32}$", RegexOptions.CultureInvariant);
        static readonly Regex ArgRe = new Regex("^--([a-z][a-z0-9-]{0,30})(=[A-Za-z0-9_.,-]{1,40})?$", RegexOptions.CultureInvariant);
        static readonly Regex ShotRe = new Regex("[^a-z0-9_-]+", RegexOptions.CultureInvariant);
        static readonly Regex TokenRe = new Regex("^[a-z][a-z0-9_-]{0,31}$", RegexOptions.CultureInvariant);
        static readonly Regex VariantLabelRe = new Regex("^[a-z0-9][a-z0-9-]{0,23}$", RegexOptions.CultureInvariant);
        /// <summary>A planned clip's name (the game writes `<name>.mjpeg`): with a variant's label of up to 24 characters and the `_` it stays inside the server's 60.</summary>
        static readonly Regex ClipNameRe = new Regex("^[a-z0-9][a-z0-9_-]{0,31}$", RegexOptions.CultureInvariant);
        static readonly Regex ResolutionRe = new Regex("^([0-9]{3,4})x([0-9]{3,4})$", RegexOptions.CultureInvariant);
        static readonly Regex BootOkRe = new Regex("(?:^|\\s)BOOT OK ([0-9]{1,9})(?:\\s|$)", RegexOptions.CultureInvariant | RegexOptions.Multiline);
        static readonly Regex UiScaleRe = new Regex("^[0-9]{1,2}(\\.[0-9]{1,3})?$", RegexOptions.CultureInvariant);

        /// <summary>`shots`, `clip` or `bench`.</summary>
        public string Kind = ShotsKind;
        public string Rev = "";
        public string GodotVersion = "";
        /// <summary>The files to download (of the first build, for a `shots` job that has two).</summary>
        public List<PlanFile> Files = new List<PlanFile>();
        /// <summary>`shots` with two builds (`before` and `after`): every build's own files, in the order sent. Empty for a job with one build (then <see cref="Files"/> is all of it).</summary>
        public List<PlanBuild> Builds = new List<PlanBuild>();
        /// <summary>`shots`: the proposal's shot plan as the JSON text written to plan.json for the game's --shot-plan; `clip`: the clip plan, written to plan.json for --clip-plan.</summary>
        public string PlanJson = "";
        public int PlanShots;
        /// <summary>`clip`: the names of the planned clips (the game writes `<name>.mjpeg` for each).</summary>
        public List<string> ClipNames = new List<string>();
        /// <summary>`clip`: one game run for each variant, 1 to 4.</summary>
        public List<ClipVariant> Variants = new List<ClipVariant>();
        public List<string> Presets = new List<string>();
        /// <summary>`release`: the steps to run, in the order they run (the payload may name any subset, in any order).</summary>
        public List<string> Steps = new List<string>();
        /// <summary>`shots`: the window sizes each preset is taken at (`resolutions`: one to four of the standard ones; none: the one 1600x900 window). `release`, `screens`: the window sizes, the UI scales to take each at besides the default one (none: the default only), the graphics preset, and the shot plan written to plan.json.</summary>
        public List<ScreenSize> ScreenSizes = new List<ScreenSize>();
        public List<string> UiScales = new List<string>();
        public string ScreensPreset = "high";
        /// <summary>`release`, `soak`: how many minutes the game's `--soak` scenario runs.</summary>
        public int SoakMinutes = DefaultSoakMinutes;
        /// <summary>`bench`, and the `bench` step of a `release` job: the runs, in order.</summary>
        public List<BenchSetup> Setups = new List<BenchSetup>();
        /// <summary>The game's options after `--`, as the server sent them and checked (`shots` adds `--dev-offline` when missing).</summary>
        public List<string> Args = new List<string>();
        /// <summary>When the job's life ends (the offer's expiry): a `bench` job stops waiting for a quiet PC then. Null when not known.</summary>
        public DateTime? ExpiresAtUtc;

        public PlanFile FileNamed(string name)
        {
            foreach (var f in Files) if (string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase)) return f;
            return null;
        }

        /// <summary>The builds a job downloads and runs: the two of a before/after `shots` job, or one build with no label.</summary>
        public List<PlanBuild> AllBuilds()
        {
            if (Builds.Count > 0) return Builds;
            return new List<PlanBuild> { new PlanBuild { Label = "", Files = Files } };
        }

        /// <summary>The build with this label, or null.</summary>
        public PlanBuild BuildNamed(string label)
        {
            foreach (var b in Builds) if (b.Label == label) return b;
            return null;
        }

        public bool HasStep(string step) { return Steps.Contains(step); }

        /// <summary>The kinds of job this version can run.</summary>
        public static bool RunsKind(string kind) { return kind == ShotsKind || kind == ClipKind || kind == ReleaseKind || kind == BenchKind; }

        /// <summary>A `shots` payload, checked (see the other overload).</summary>
        public static bool TryParse(object payload, Uri siteBase, out JobPlan plan, out string error)
        {
            return TryParse(ShotsKind, payload, siteBase, out plan, out error);
        }

        /// <summary>Parses and checks a payload (an object, or JSON text of one) of a job of this kind. File URLs must be on <paramref name="siteBase"/>'s scheme, host and port, under its team-files/ folder.</summary>
        public static bool TryParse(string kind, object payload, Uri siteBase, out JobPlan plan, out string error)
        {
            plan = null;
            error = null;
            if (!RunsKind(kind)) { error = "This version of the team app cannot run " + Shorten(kind) + " jobs."; return false; }
            var d = payload as Dictionary<string, object>;
            if (d == null && payload is string) d = MiniJson.TryObject((string)payload);
            if (d == null) { error = "The job has no details."; return false; }

            var p = new JobPlan { Kind = kind };
            p.Rev = MiniJson.Str(d, "rev");
            if (p.Rev.Length > 0 && !RevRe.IsMatch(p.Rev)) { error = "The job names a build that is not a revision."; return false; }
            p.GodotVersion = MiniJson.Str(d, "godotVersion");
            if (p.GodotVersion.Length > 0 && !VersionRe.IsMatch(p.GodotVersion)) { error = "The job names a Godot version that is not valid."; return false; }

            string prefix = siteBase.AbsolutePath;
            if (!prefix.EndsWith("/", StringComparison.Ordinal)) prefix += "/";
            prefix += TeamUrls.FilesPath;

            object rawBuilds;
            d.TryGetValue("builds", out rawBuilds);
            if (rawBuilds != null)
            {
                // Two builds: each has its own files, and `files` (if the job sends it too) is not used. A screenshots job's are before and after a change; a release job's are the release files and the debug build.
                if (kind != ShotsKind && kind != ReleaseKind) { error = "Only a screenshots job has a before and an after build."; return false; }
                if (!ParseBuilds(rawBuilds, siteBase, prefix, p, kind == ReleaseKind ? new[] { ReleaseBuild, DebugBuild } : BuildLabels, out error)) return false;
                p.Files = p.Builds[0].Files;
            }
            else if (kind == ReleaseKind) { error = "The job lists no builds to download."; return false; }
            else
            {
                var files = MiniJson.Arr(d, "files");
                if (files == null || files.Count == 0) { error = "The job lists no files to download."; return false; }
                if (!ParseFiles(files, "", siteBase, prefix, p.Files, out error)) return false;
            }
            if (kind == BenchKind)
            {
                foreach (string need in BenchFiles)
                    if (p.FileNamed(need) == null) { error = "The job does not include " + need + "."; return false; }
                if (!ParseSetups(d, p, out error)) return false;
            }
            else if (kind == ReleaseKind)
            {
                if (!ParseRelease(d, p, out error)) return false;
            }
            else
            {
                foreach (PlanBuild b in p.AllBuilds())
                    if (FileIn(b.Files, GameExe) == null || FileIn(b.Files, MainPack) == null)
                    { error = (b.Label.Length > 0 ? "The " + b.Label + " build does not" : "The job does not") + " include " + GameExe + " and " + MainPack + "."; return false; }
                if (kind == ClipKind ? !ParseClips(d, p, out error) : !ParseShots(d, p, out error)) return false;
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
            if ((kind == ShotsKind || kind == ClipKind) && !p.Args.Contains("--dev-offline")) p.Args.Insert(0, "--dev-offline");

            plan = p;
            return true;
        }

        static PlanFile FileIn(List<PlanFile> files, string name)
        {
            foreach (var f in files) if (string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase)) return f;
            return null;
        }

        /// <summary>Checks a list of file entries (names, checksums, sizes, cache names, addresses) and adds them to <paramref name="into"/>. <paramref name="who"/> names the build in a message ("" for a job with one).</summary>
        static bool ParseFiles(List<object> files, string who, Uri siteBase, string prefix, List<PlanFile> into, out string error)
        {
            error = null;
            if (files.Count == 0) { error = "The " + (who.Length > 0 ? who + " build lists" : "job lists") + " no files to download."; return false; }
            if (files.Count > MaxFiles) { error = "The job lists too many files (" + files.Count + ")."; return false; }
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
                into.Add(f);
            }
            return true;
        }

        /// <summary>
        /// `shots` with `builds`: one or two builds labelled `before` and `after`, or a `release` job's `release` and `debug` builds (<paramref name="labels"/>; each at most once), each with its own files. A file the builds share
        /// keeps one cache name and one checksum (the cache holds one file for a name, and the first build's game folder must not change under the second's download).
        /// </summary>
        static bool ParseBuilds(object raw, Uri siteBase, string prefix, JobPlan p, string[] labels, out string error)
        {
            error = null;
            var list = raw as List<object>;
            if (list == null || list.Count == 0 || list.Count > labels.Length) { error = "The job lists no builds (" + string.Join(" and ", labels) + " are allowed)."; return false; }
            var cached = new Dictionary<string, string>();
            foreach (object o in list)
            {
                var bd = o as Dictionary<string, object>;
                if (bd == null) { error = "A build in the job is not valid."; return false; }
                string label = MiniJson.Str(bd, "label");
                if (Array.IndexOf(labels, label) < 0) { error = "A build in the job has a label that is not allowed: \"" + Shorten(label) + "\" (use " + string.Join(" or ", labels) + ")."; return false; }
                foreach (PlanBuild earlier in p.Builds)
                    if (earlier.Label == label) { error = "The job lists the " + label + " build twice."; return false; }
                var files = MiniJson.Arr(bd, "files");
                var b = new PlanBuild { Label = label };
                if (files == null || !ParseFiles(files, label, siteBase, prefix, b.Files, out error))
                {
                    if (files == null) error = "The " + label + " build lists no files to download.";
                    return false;
                }
                foreach (PlanFile f in b.Files)
                {
                    if (!f.IsCached) continue;
                    string key = f.CacheKey + "|" + f.Name, id = f.Sha256 + "|" + f.Bytes, was;
                    if (cached.TryGetValue(key, out was) && was != id) { error = "The builds give the cache name " + f.CacheKey + " to different files."; return false; }
                    cached[key] = id;
                }
                p.Builds.Add(b);
            }
            return true;
        }

        /// <summary>
        /// `release`: the steps (a subset of <see cref="ReleaseSteps"/>, each once, in any order: the job runs them in the order of the list), the builds the steps need (the release files for install,
        /// quit-loading and bench; the debug build for screens, stutter and soak), and each step's settings: `setups` (bench; the Low and Medium Full Party fight when none is given), `screens`
        /// (`plan`: the standard shots, `resolutions`: up to 6 sizes, the four standard ones when none is given, `uiScales`: up to 3 values besides the default one, `preset`: `high` when none is given)
        /// and `soak` (`minutes`: 1 to 120, 30 when none is given).
        /// </summary>
        static bool ParseRelease(Dictionary<string, object> d, JobPlan p, out string error)
        {
            error = null;
            var steps = MiniJson.Arr(d, "steps");
            if (steps == null || steps.Count == 0) { error = "The job lists no steps."; return false; }
            var named = new List<string>();
            foreach (object o in steps)
            {
                string st = o as string;
                if (st == null || Array.IndexOf(ReleaseSteps, st) < 0) { error = "The job names a step this app does not know: \"" + Shorten(st) + "\"."; return false; }
                if (named.Contains(st)) { error = "The job lists the step " + st + " twice."; return false; }
                named.Add(st);
            }
            foreach (string st in ReleaseSteps) if (named.Contains(st)) p.Steps.Add(st);   // the order they run in, whatever order they were listed in

            bool needsRelease = p.HasStep("install") || p.HasStep("quit-loading") || p.HasStep("bench");
            bool needsDebug = p.HasStep("screens") || p.HasStep("stutter") || p.HasStep("soak");
            PlanBuild rel = p.BuildNamed(ReleaseBuild), dbg = p.BuildNamed(DebugBuild);
            if (needsRelease)
            {
                if (rel == null) { error = "The job has no release build for its steps."; return false; }
                foreach (string need in BenchFiles)
                    if (FileIn(rel.Files, need) == null) { error = "The release build does not include " + need + "."; return false; }
            }
            if (needsDebug)
            {
                if (dbg == null) { error = "The job has no debug build for its steps."; return false; }
                if (FileIn(dbg.Files, GameExe) == null || FileIn(dbg.Files, MainPack) == null) { error = "The debug build does not include " + GameExe + " and " + MainPack + "."; return false; }
            }

            if (p.HasStep("bench"))
            {
                object rawSetups;
                d.TryGetValue("setups", out rawSetups);
                if (rawSetups == null)
                {
                    foreach (string preset in new[] { "low", "medium" }) p.Setups.Add(new BenchSetup { Preset = preset, Room = "graves", Class = 2, Size = "full_party", Length = "full" });
                }
                else if (!ParseSetups(d, p, out error)) return false;
            }

            if (p.HasStep("screens"))
            {
                var screens = MiniJson.Obj(d, "screens");
                var plan0 = MiniJson.Obj(screens, "plan");
                var shots = MiniJson.Arr(plan0, "shots");
                if (plan0 == null || shots == null || shots.Count == 0) { error = "The job has no shot plan for its screens step."; return false; }
                p.PlanJson = MiniJson.Write(plan0);
                if (Encoding.UTF8.GetByteCount(p.PlanJson) > MaxPlanBytes) { error = "The shot plan is too big."; return false; }
                p.PlanShots = shots.Count;
                var sizes = MiniJson.Arr(screens, "resolutions");
                var texts = new List<string>();
                if (sizes == null || sizes.Count == 0) texts.AddRange(DefaultResolutions);
                else
                {
                    if (sizes.Count > MaxScreenSizes) { error = "The screens step has too many window sizes (no more than " + MaxScreenSizes + " are allowed)."; return false; }
                    foreach (object o in sizes) texts.Add(o as string ?? "");
                }
                foreach (string t in texts)
                {
                    Match m = ResolutionRe.Match(t);
                    int w = m.Success ? int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : 0, h = m.Success ? int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture) : 0;
                    if (!m.Success || w < 640 || w > 7680 || h < 360 || h > 4320) { error = "The screens step asks for a window size that is not allowed: \"" + Shorten(t) + "\"."; return false; }
                    foreach (ScreenSize earlier in p.ScreenSizes)
                        if (earlier.Width == w && earlier.Height == h) { error = "The screens step lists the size " + t + " twice."; return false; }
                    p.ScreenSizes.Add(new ScreenSize { Width = w, Height = h });
                }
                object rawScales;
                if (screens.TryGetValue("uiScales", out rawScales) && rawScales != null)
                {
                    var scales = rawScales as List<object>;
                    if (scales == null || scales.Count > MaxUiScales) { error = "The screens step's UI scales are not a list of up to " + MaxUiScales + "."; return false; }
                    foreach (object o in scales)
                    {
                        string v = o is string ? (string)o : o is double ? ((double)o).ToString("0.###", CultureInfo.InvariantCulture) : "";
                        if (!UiScaleRe.IsMatch(v) || double.Parse(v, CultureInfo.InvariantCulture) <= 0) { error = "A UI scale in the screens step is not allowed: \"" + Shorten(v) + "\"."; return false; }
                        if (!p.UiScales.Contains(v)) p.UiScales.Add(v);
                    }
                }
                string preset = MiniJson.Str(screens, "preset");
                if (preset.Length > 0)
                {
                    if (Array.IndexOf(KnownPresets, preset) < 0) { error = "The screens step asks for a graphics preset that does not exist."; return false; }
                    p.ScreensPreset = preset;
                }
            }

            if (p.HasStep("soak"))
            {
                var soak = MiniJson.Obj(d, "soak");
                long? minutes = MiniJson.Int(soak, "minutes");
                if (soak != null && soak.ContainsKey("minutes") && (minutes == null || minutes.Value < 1 || minutes.Value > MaxSoakMinutes)) { error = "The soak step's minutes must be a whole number from 1 to " + MaxSoakMinutes + "."; return false; }
                if (minutes != null) p.SoakMinutes = (int)minutes.Value;
            }
            return true;
        }

        /// <summary>
        /// `clip`: the clip plan (1 to 4 clips, each with a name that is a safe token, at most 8 seconds long), the variants (1 to 4, each a label and an optional tune object; none given is one run labelled `clip`)
        /// and the one graphics preset (`high` when none is given).
        /// </summary>
        static bool ParseClips(Dictionary<string, object> d, JobPlan p, out string error)
        {
            error = null;
            var plan0 = MiniJson.Obj(d, "plan");
            var clips = MiniJson.Arr(plan0, "clips");
            if (plan0 == null || clips == null || clips.Count == 0) { error = "The job has no clip plan."; return false; }
            if (clips.Count > MaxClips) { error = "The clip plan has too many clips (" + clips.Count + "; no more than " + MaxClips + " are allowed)."; return false; }
            p.PlanJson = MiniJson.Write(plan0);
            if (Encoding.UTF8.GetByteCount(p.PlanJson) > MaxPlanBytes) { error = "The clip plan is too big."; return false; }
            foreach (object o in clips)
            {
                var cd = o as Dictionary<string, object>;
                if (cd == null) { error = "A clip in the plan is not valid."; return false; }
                string name = MiniJson.Str(cd, "name");
                if (!ClipNameRe.IsMatch(name)) { error = "A clip in the plan has a name that is not allowed: \"" + Shorten(name) + "\"."; return false; }
                if (p.ClipNames.Contains(name)) { error = "The clip plan lists " + name + " twice."; return false; }
                object seconds;
                if (cd.TryGetValue("seconds", out seconds) && seconds != null && !(seconds is double && (double)seconds > 0 && (double)seconds <= MaxClipSeconds))
                { error = "The clip " + name + " is longer than " + MaxClipSeconds + " seconds (or its length is not a number)."; return false; }
                p.ClipNames.Add(name);
            }
            p.PlanShots = p.ClipNames.Count;

            object rawVariants;
            d.TryGetValue("variants", out rawVariants);
            if (rawVariants != null && !(rawVariants is List<object>)) { error = "The job's variants are not a list."; return false; }
            var variants = rawVariants as List<object>;
            if (variants == null || variants.Count == 0) p.Variants.Add(new ClipVariant());
            else
            {
                if (variants.Count > MaxVariants) { error = "The job has too many variants (" + variants.Count + "; no more than " + MaxVariants + " are allowed)."; return false; }
                foreach (object o in variants)
                {
                    var vd = o as Dictionary<string, object>;
                    if (vd == null) { error = "A variant in the job is not valid."; return false; }
                    string label = MiniJson.Str(vd, "label");
                    if (label.Length == 0) label = ClipLabelDefault;
                    else if (!VariantLabelRe.IsMatch(label)) { error = "A variant in the job has a label that is not allowed: \"" + Shorten(label) + "\"."; return false; }
                    foreach (ClipVariant earlier in p.Variants)
                        if (earlier.Label == label) { error = "The job lists the variant " + label + " twice."; return false; }
                    var v = new ClipVariant { Label = label };
                    object tune;
                    if (vd.TryGetValue("tune", out tune) && tune != null)
                    {
                        if (!(tune is Dictionary<string, object>)) { error = "The tune of the variant " + label + " is not an object."; return false; }
                        v.TuneJson = MiniJson.Write(tune);
                        if (Encoding.UTF8.GetByteCount(v.TuneJson) > MaxTuneBytes) { error = "The tune of the variant " + label + " is too big."; return false; }
                    }
                    p.Variants.Add(v);
                }
            }

            object rawPresets;
            d.TryGetValue("presets", out rawPresets);
            if (rawPresets != null && !(rawPresets is List<object>)) { error = "The job names no graphics presets."; return false; }
            var presets = rawPresets as List<object>;
            if (presets == null || presets.Count == 0) p.Presets.Add(ClipPresetDefault);
            else
            {
                if (presets.Count != 1) { error = "A clip job uses one graphics preset."; return false; }
                string s = presets[0] as string;
                if (s == null || Array.IndexOf(KnownPresets, s) < 0) { error = "The job asks for a graphics preset that does not exist."; return false; }
                p.Presets.Add(s);
            }
            return true;
        }

        /// <summary>`shots`: the proposal's shot plan and the presets to take it on.</summary>
        static bool ParseShots(Dictionary<string, object> d, JobPlan p, out string error)
        {
            error = null;
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

            // `resolutions` (optional): each preset is taken at each of these window sizes (none: the one 1600x900 window as ever)
            object rawSizes;
            d.TryGetValue("resolutions", out rawSizes);
            if (rawSizes != null)
            {
                var sizes = rawSizes as List<object>;
                if (sizes == null || sizes.Count == 0 || sizes.Count > DefaultResolutions.Length) { error = "The job names no window sizes (1 to " + DefaultResolutions.Length + " of " + string.Join(", ", DefaultResolutions) + ")."; return false; }
                foreach (object o in sizes)
                {
                    string t = o as string;
                    if (t == null || Array.IndexOf(DefaultResolutions, t) < 0) { error = "The job asks for a window size that is not allowed: \"" + Shorten(t) + "\" (use " + string.Join(", ", DefaultResolutions) + ")."; return false; }
                    Match m = ResolutionRe.Match(t);
                    foreach (ScreenSize earlier in p.ScreenSizes)
                        if (earlier.Text == t) { error = "The job lists the window size " + t + " twice."; return false; }
                    p.ScreenSizes.Add(new ScreenSize { Width = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture), Height = int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture) });
                }
            }
            return true;
        }

        /// <summary>`bench`: 1 to 6 setups, each a known preset, fight size and length, a room that is a safe token and a class number.</summary>
        static bool ParseSetups(Dictionary<string, object> d, JobPlan p, out string error)
        {
            error = null;
            var setups = MiniJson.Arr(d, "setups");
            if (setups == null || setups.Count == 0 || setups.Count > MaxSetups) { error = "The job lists no benchmark setups (1 to " + MaxSetups + " are allowed)."; return false; }
            foreach (object o in setups)
            {
                var sd = o as Dictionary<string, object>;
                if (sd == null) { error = "A benchmark setup in the job is not valid."; return false; }
                var s = new BenchSetup { Preset = MiniJson.Str(sd, "preset"), Room = MiniJson.Str(sd, "room"), Size = MiniJson.Str(sd, "size"), Length = MiniJson.Str(sd, "length") };
                if (Array.IndexOf(KnownPresets, s.Preset) < 0) { error = "A benchmark setup asks for a graphics preset that does not exist."; return false; }
                if (!TokenRe.IsMatch(s.Room)) { error = "A benchmark setup names a room that is not allowed: \"" + Shorten(s.Room) + "\"."; return false; }
                long? cls = MiniJson.Int(sd, "class");
                if (cls == null || cls.Value < 1 || cls.Value > 20) { error = "A benchmark setup names a class that does not exist."; return false; }
                s.Class = (int)cls.Value;
                if (Array.IndexOf(BenchSizes, s.Size) < 0) { error = "A benchmark setup asks for a fight size that does not exist: \"" + Shorten(s.Size) + "\"."; return false; }
                if (Array.IndexOf(BenchLengths, s.Length) < 0) { error = "A benchmark setup asks for a length that does not exist: \"" + Shorten(s.Length) + "\"."; return false; }
                p.Setups.Add(s);
            }
            return true;
        }

        /// <summary>The offer's `expiresAt` (ISO 8601, UTC) as a time, or null when it is missing or not a time.</summary>
        public static DateTime? ParseExpiry(string iso)
        {
            DateTime t;
            if (string.IsNullOrEmpty(iso) || !DateTime.TryParse(iso, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out t)) return null;
            return t;
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

        /// <summary>
        /// What goes ahead of `--` for every game the app starts: `--windowed --resolution 1600x900 --audio-driver Dummy` and, when given, `--position X,Y` (a clip run also has the engine's
        /// `--fixed-fps 30`, which makes the game run 30 frames per game second whatever the time reading each frame takes). The Dummy audio driver still mixes (the game's CPU cost stays real) but nothing is heard.
        /// </summary>
        static List<string> WindowArgs(string position, bool fixedFps = false, string resolution = Resolution)
        {
            var a = new List<string> { "--windowed", "--resolution", resolution, "--audio-driver", "Dummy" };
            if (fixedFps) { a.Add("--fixed-fps"); a.Add(ClipFps.ToString(CultureInfo.InvariantCulture)); }
            if (!string.IsNullOrEmpty(position)) { a.Add("--position"); a.Add(position); }
            a.Add("--");
            return a;
        }

        /// <summary>
        /// The game window's `--position` for a screenshot job: outside every monitor, 1700 px left of the virtual screen's left edge (the window is 1600 wide) and level with its top edge, so the window
        /// is never seen. <paramref name="virtualLeft"/> and <paramref name="virtualTop"/> are the virtual screen's (SystemInformation.VirtualScreen: every monitor together; negative when a
        /// monitor sits left of or above the main one).
        /// </summary>
        public static string OffscreenPosition(int virtualLeft, int virtualTop, int windowWidth = 1600)
        {
            return (virtualLeft - windowWidth - 100).ToString(CultureInfo.InvariantCulture) + "," + virtualTop.ToString(CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// The game's arguments for one preset: `--windowed --resolution 1600x900 --audio-driver Dummy [--position X,Y] -- <options> --shot-plan=<file> --shots=<dir> --preset=<preset>`. Paths use "/".
        /// <paramref name="position"/> (see <see cref="OffscreenPosition"/>) keeps the window off every monitor; null leaves it where Godot puts it.
        /// </summary>
        public List<string> CommandArgs(string preset, string planFile, string shotsDir, string position = null, ScreenSize size = null)
        {
            var a = WindowArgs(position, false, size == null ? Resolution : size.Text);
            a.AddRange(Args);
            a.Add("--shot-plan=" + Slashes(planFile));
            a.Add("--shots=" + Slashes(shotsDir));
            a.Add("--preset=" + preset);
            return a;
        }

        public string CommandLine(string preset, string planFile, string shotsDir, string position = null) { return CommandLineText.Join(CommandArgs(preset, planFile, shotsDir, position)); }

        /// <summary>
        /// A `clip` run's arguments: `--windowed --resolution 1600x900 --audio-driver Dummy --fixed-fps 30 [--position X,Y] -- <options> --preset=<preset> --clip-plan=<file> --clips=<dir> [--tune=<file>]`
        /// (`--tune` only for a variant that has one). The window follows the screenshots' rules (silent, outside every monitor when a position is given). Paths use "/".
        /// </summary>
        public List<string> ClipCommandArgs(ClipVariant variant, string preset, string planFile, string clipsDir, string tuneFile, string position = null)
        {
            var a = WindowArgs(position, true);
            a.AddRange(Args);
            a.Add("--preset=" + preset);
            a.Add("--clip-plan=" + Slashes(planFile));
            a.Add("--clips=" + Slashes(clipsDir));
            if (variant.HasTune) a.Add("--tune=" + Slashes(tuneFile));
            return a;
        }

        public string ClipCommandLine(ClipVariant variant, string preset, string planFile, string clipsDir, string tuneFile, string position = null)
        {
            return CommandLineText.Join(ClipCommandArgs(variant, preset, planFile, clipsDir, tuneFile, position));
        }


        // ---- The `release` job's commands -------------------------------------------------------------------------------------------

        /// <summary>The game's options for a run of the debug build: `--dev-offline` first (a debug build only starts its QA tools offline), then the job's own.</summary>
        List<string> DebugArgs()
        {
            var a = new List<string>(Args);
            if (!a.Contains("--dev-offline")) a.Insert(0, "--dev-offline");
            return a;
        }

        /// <summary>
        /// The `install` and `quit-loading` steps' arguments for the RELEASE exe: `--windowed --resolution 1600x900 --audio-driver Dummy [--position X,Y] -- --boot-check` and, for quit-loading, `--quit-while-loading`.
        /// Nothing else is passed (the release build is started as a player's would be, offline or not as it decides), and its window stays outside every monitor when a position is given.
        /// </summary>
        public static List<string> BootCheckArgs(bool quitWhileLoading, string position = null)
        {
            var a = WindowArgs(position);
            a.Add("--boot-check");
            if (quitWhileLoading) a.Add("--quit-while-loading");
            return a;
        }

        /// <summary>The `screens` step's arguments for one window size and UI scale ("" = the default one): the debug build, `--resolution WxH`, the shot plan, the pictures' folder, the preset and `--ui-scale=<value>` when there is one.</summary>
        public List<string> ScreensCommandArgs(ScreenSize size, string uiScale, string planFile, string shotsDir, string position = null)
        {
            var a = WindowArgs(position, false, size.Text);
            a.AddRange(DebugArgs());
            a.Add("--shot-plan=" + Slashes(planFile));
            a.Add("--shots=" + Slashes(shotsDir));
            a.Add("--preset=" + ScreensPreset);
            if (!string.IsNullOrEmpty(uiScale)) a.Add("--ui-scale=" + uiScale);
            return a;
        }

        /// <summary>The `stutter` step's arguments: the debug build's QA scenario `--stutter`, which writes its JSON into <paramref name="outDir"/> (`--stutter-out`).</summary>
        public List<string> StutterCommandArgs(string outDir, string position = null)
        {
            var a = WindowArgs(position);
            a.AddRange(DebugArgs());
            a.Add("--stutter");
            a.Add("--stutter-out=" + Slashes(outDir));
            return a;
        }

        /// <summary>The `soak` step's arguments: the debug build's QA scenario `--soak=<minutes>`, which writes its JSON into <paramref name="outDir"/> (`--soak-out`).</summary>
        public List<string> SoakCommandArgs(string outDir, string position = null)
        {
            var a = WindowArgs(position);
            a.AddRange(DebugArgs());
            a.Add("--soak=" + SoakMinutes.ToString(CultureInfo.InvariantCulture));
            a.Add("--soak-out=" + Slashes(outDir));
            return a;
        }

        /// <summary>The name a window size and UI scale give their pictures: `1920x1080`, or `1920x1080_s1-5` for a UI scale of 1.5 (a name has no dot).</summary>
        public static string ScreensTag(ScreenSize size, string uiScale)
        {
            return string.IsNullOrEmpty(uiScale) ? size.Text : size.Text + "_s" + uiScale.Replace('.', '-');
        }

        /// <summary>The milliseconds from `BOOT OK &lt;ms&gt;` in the game's output (the release build's boot check), or null when there is no such line.</summary>
        public static long? ParseBootMs(string output)
        {
            if (string.IsNullOrEmpty(output)) return null;
            Match m = BootOkRe.Match(output);
            long ms;
            return m.Success && long.TryParse(m.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out ms) ? (long?)ms : null;
        }

        static string Slashes(string path) { return path.Replace('\\', '/'); }

        public static string PresetLabel(string preset)
        {
            return string.IsNullOrEmpty(preset) ? "" : char.ToUpperInvariant(preset[0]) + preset.Substring(1);
        }

        /// <summary>
        /// A `bench` setup's arguments: `--windowed --resolution 1600x900 --audio-driver Dummy -- --benchmark --bench-room=.. --bench-class=.. --bench-size=.. --bench-length=.. --bench-preset=..
        /// --bench-dir=<dir> --bench-quit` and the job's own options. No `--main-pack` (a release template refuses it: Godot loads `DeathMuffin.pck` beside the exe), no `--dev-offline`
        /// (`--bench-dir` already keeps the run a trial that sends nothing) and no `--position`: the window stays on screen (the PC is idle, and an off-screen window may be treated differently by the
        /// desktop compositor). Paths use "/".
        /// </summary>
        public List<string> BenchCommandArgs(BenchSetup s, string benchDir)
        {
            var a = WindowArgs(null);
            a.AddRange(new[]
            {
                "--benchmark",
                "--bench-room=" + s.Room, "--bench-class=" + s.Class.ToString(CultureInfo.InvariantCulture), "--bench-size=" + s.Size, "--bench-length=" + s.Length,
                "--bench-preset=" + s.Preset, "--bench-dir=" + Slashes(benchDir), "--bench-quit",
            });
            a.AddRange(Args);
            return a;
        }

        public string BenchCommandLine(BenchSetup s, string benchDir) { return CommandLineText.Join(BenchCommandArgs(s, benchDir)); }

        /// <summary>
        /// The run the game queued in `<benchDir>\pending.json`: its last entry (DmBenchHistory.record appends the run to the queue, the payload DmApi.post_benchmark sends). False, with a
        /// sentence for the member, when the game left no run, left one it cancelled, or left one the server would refuse for its size.
        /// </summary>
        public static bool TryReadBenchRun(string benchDir, string label, out Dictionary<string, object> run, out string error)
        {
            run = null;
            error = null;
            string text;
            try
            {
                string file = Path.Combine(benchDir, "pending.json");
                if (!File.Exists(file)) { error = "The game finished the benchmark on " + label + " but left no result."; return false; }
                text = File.ReadAllText(file);
            }
            catch (IOException) { error = "The result of the benchmark on " + label + " could not be read."; return false; }
            catch (UnauthorizedAccessException) { error = "The result of the benchmark on " + label + " could not be read."; return false; }
            object parsed;
            try { parsed = MiniJson.Parse(text); }
            catch (FormatException) { error = "The result of the benchmark on " + label + " is damaged."; return false; }
            var list = parsed as List<object>;
            if (list == null || list.Count == 0) { error = "The game finished the benchmark on " + label + " but left no result."; return false; }
            var last = list[list.Count - 1] as Dictionary<string, object>;
            if (last == null) { error = "The result of the benchmark on " + label + " is damaged."; return false; }
            if (MiniJson.Bool(last, "cancelled")) { error = "The benchmark on " + label + " was cancelled before it finished."; return false; }
            if (Encoding.UTF8.GetByteCount(MiniJson.Write(last)) > MaxRunBytes) { error = "The result of the benchmark on " + label + " is too big to send."; return false; }
            run = last;
            return true;
        }

        // ---- Pictures and clips to upload ---------------------------------------------------------------------------------------------

        /// <summary>
        /// `low` and `bag-open.png` -> `low_bag-open.png`: the name the server accepts (`^[a-z0-9_-]{1,60}\.png$`). Null for a file that is not a .png. A job with two builds passes
        /// `before_low` (the build and the preset) for <paramref name="preset"/>: `before_low_bag-open.png`.
        /// </summary>
        public static string UploadName(string preset, string fileName) { return UploadNameCore(preset, fileName, ".png"); }

        /// <summary>Names for a preset's picture files, one each: a name that collides gets -2, -3 (names are unique across <paramref name="used"/>).</summary>
        public static List<KeyValuePair<string, string>> UploadNames(string preset, IEnumerable<string> files, HashSet<string> used) { return UploadNamesCore(preset, files, used, ".png"); }

        /// <summary>`slow` and `wraith.mjpeg` -> `slow_wraith.mjpeg`: the name the server accepts for a clip (`^[a-z0-9][a-z0-9_-]{0,59}\.mjpeg$`). Null for a file that is not a .mjpeg.</summary>
        public static string ClipUploadName(string label, string fileName) { return UploadNameCore(label, fileName, ".mjpeg"); }

        /// <summary>Names for a variant's clip files, one each, unique across <paramref name="used"/> like <see cref="UploadNames"/>.</summary>
        public static List<KeyValuePair<string, string>> ClipUploadNames(string label, IEnumerable<string> files, HashSet<string> used) { return UploadNamesCore(label, files, used, ".mjpeg"); }

        /// <summary>The whole name stays within 60 characters including its extension (the server takes up to 60 before it).</summary>
        static string UploadNameCore(string prefix, string fileName, string ext)
        {
            string f = fileName ?? "";
            f = f.Substring(Math.Max(f.LastIndexOf('/'), f.LastIndexOf('\\')) + 1);   // the last segment, whichever separator the path uses
            if (!f.EndsWith(ext, StringComparison.OrdinalIgnoreCase)) return null;
            string shot = ShotRe.Replace(f.Substring(0, f.Length - ext.Length).ToLowerInvariant(), "_").Trim('_');
            if (shot.Length == 0) shot = "shot";
            string head = prefix + "_";
            int room = 60 - head.Length - ext.Length;
            if (shot.Length > room) shot = shot.Substring(0, room);
            return head + shot + ext;
        }

        static List<KeyValuePair<string, string>> UploadNamesCore(string prefix, IEnumerable<string> files, HashSet<string> used, string ext)
        {
            var result = new List<KeyValuePair<string, string>>();
            var sorted = new List<string>(files);
            sorted.Sort(StringComparer.Ordinal);
            foreach (string file in sorted)
            {
                string name = UploadNameCore(prefix, file, ext);
                if (name == null) continue;
                string stem = name.Substring(0, name.Length - ext.Length);
                for (int n = 2; used.Contains(name); n++)
                {
                    string tail = "-" + n.ToString(CultureInfo.InvariantCulture);
                    int keep = 60 - ext.Length;
                    name = (stem.Length + tail.Length > keep ? stem.Substring(0, keep - tail.Length) : stem) + tail + ext;
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
