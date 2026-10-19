using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

// The team app's decisions, with no WinForms and no Windows calls, so teamapp/tests compiles this file on Linux too.
namespace DeathMuffinTeam
{
    /// <summary>Where the app talks to: the game's site. Everything it downloads must be on this host (JobPlan).</summary>
    internal static class TeamUrls
    {
        public const string SiteBase = "https://muffindevelopment.com/death-muffin/";
        /// <summary>The game's API. The team routes are under its own nginx location, /death-muffin/api/team/ (a 9 MB body limit for the pictures), which
        /// reaches the backend's /team/ routes (server/death-muffin/nginx-locations.conf).</summary>
        public const string ApiBase = SiteBase + "api/";
        /// <summary>The app's own manifest, {version, url, sha256} (the SelfUpdate pattern of the launcher).</summary>
        public const string VersionUrl = SiteBase + "teamapp/version.json";
        /// <summary>Where the server keeps the builds a job downloads (JobPlan accepts only URLs under it).</summary>
        public const string FilesPath = "team-files/";
    }

    /// <summary>How a PC treats a job offer (the server stores it per PC): ask first, run without asking, or only on a yes.</summary>
    internal enum OfferMode { Ask, Auto, Yes }

    internal static class Modes
    {
        public static string Wire(OfferMode m) { return m == OfferMode.Auto ? "auto" : m == OfferMode.Yes ? "yes" : "ask"; }

        /// <summary>The server's word for a mode; anything unknown is the careful default, ask.</summary>
        public static OfferMode Parse(string s)
        {
            if (s == "auto") return OfferMode.Auto;
            if (s == "yes") return OfferMode.Yes;
            return OfferMode.Ask;
        }

        public static string Label(OfferMode m)
        {
            return m == OfferMode.Auto ? "Run without asking" : m == OfferMode.Yes ? "Only on a yes" : "Ask";
        }
    }

    /// <summary>What the person did with the offer box (or the tray menu).</summary>
    internal enum OfferAnswer { None, Yes, NotNow, Pause }

    /// <summary>
    /// Run: start the job now. Ask: show the box (or keep it up) and wait. Wait: do nothing visible now, look again in a moment.
    /// Decline: tell the server this PC will not take the job (TeamLogic.DeclineReason says why).
    /// </summary>
    internal enum OfferDecision { Run, Ask, Wait, Decline }

    internal static class TeamLogic
    {
        /// <summary>Mode "ask": a box nobody answered runs by itself after this long.</summary>
        public static readonly TimeSpan AutoRunAfter = TimeSpan.FromMinutes(5);
        public static readonly TimeSpan PauseFor = TimeSpan.FromHours(2);
        /// <summary>
        /// The heartbeat is a long poll: it asks the server to hold it up to this many seconds while it has nothing to say, so an offer or a cancel reaches the PC in about a second, and the next one is sent
        /// right after the answer.
        /// </summary>
        public const int HeartbeatWaitS = 25;
        /// <summary>A heartbeat gets this long (the server holds it up to <see cref="HeartbeatWaitS"/>) before the app gives up on it.</summary>
        public static readonly TimeSpan HeartbeatTimeout = TimeSpan.FromSeconds(40);
        /// <summary>The wait after a heartbeat that failed: the first time, the second, the third and every time after.</summary>
        public static readonly TimeSpan[] HeartbeatBackoff = { TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(30) };
        /// <summary>
        /// A heartbeat with nothing new in its answer is not followed by another sooner than this after it was sent: a server that does not hold requests (an older one), an offer that waits for a yes (the server
        /// answers at once while one is queued for this PC) or a cancel list the PC already knows would otherwise be asked again and again without a pause.
        /// </summary>
        public static readonly TimeSpan HeartbeatMinCycle = TimeSpan.FromSeconds(5);

        /// <summary>
        /// How long to wait before the next heartbeat. After <paramref name="failures"/> failures in a row: 5 s, then 15 s, then 30 s (and 30 s after that). After an answer with something new (an offer
        /// the PC had not seen, or a cancel of the job it runs): none. After any other answer: what is left of <see cref="HeartbeatMinCycle"/> since it was sent (none when the server held it for long).
        /// </summary>
        public static TimeSpan HeartbeatPause(int failures, bool news, TimeSpan sinceSent)
        {
            if (failures > 0) return HeartbeatBackoff[Math.Min(failures, HeartbeatBackoff.Length) - 1];
            if (news) return TimeSpan.Zero;
            TimeSpan left = HeartbeatMinCycle - sinceSent;
            return left > TimeSpan.Zero ? left : TimeSpan.Zero;
        }
        /// <summary>One game run (a screenshots preset, a clip variant) is stopped after this long.</summary>
        public static readonly TimeSpan RunLimit = TimeSpan.FromMinutes(10);
        /// <summary>One benchmark setup's run is stopped after this long.</summary>
        public static readonly TimeSpan BenchRunLimit = TimeSpan.FromMinutes(15);
        public const int KeepJobFolders = 3;
        public const int KeepCacheKeys = 4;

        /// <summary>
        /// The one decision about an offered job. A yes always runs it. A no or a pause declines it. A paused PC declines everything. Otherwise a full-screen
        /// app (a game, a film, a presentation), Death Muffin itself, or a laptop on battery means "not now, and not visibly": the box stays hidden and the job
        /// waits for that to end. With nothing in the way, mode auto runs, mode yes asks forever, and mode ask asks and runs by itself once the box has
        /// been up for five minutes without an answer (<paramref name="elapsed"/> counts from when the box was shown, so a wait never eats it). In AFK mode
        /// (<paramref name="afk"/>, mode ask only: the person has been away since a box ran out) a job runs at once, with no box and no wait.
        /// </summary>
        public static OfferDecision Decide(OfferMode mode, OfferAnswer answer, TimeSpan elapsed, bool fullscreen, bool gameRunning, bool onBattery, bool paused, bool afk = false)
        {
            if (answer == OfferAnswer.Yes) return OfferDecision.Run;
            if (answer == OfferAnswer.NotNow || answer == OfferAnswer.Pause) return OfferDecision.Decline;
            if (paused) return OfferDecision.Decline;
            if (fullscreen || gameRunning || onBattery) return OfferDecision.Wait;
            if (mode == OfferMode.Auto) return OfferDecision.Run;
            if (mode == OfferMode.Yes) return OfferDecision.Ask;
            if (afk) return OfferDecision.Run;
            return elapsed >= AutoRunAfter ? OfferDecision.Run : OfferDecision.Ask;
        }

        /// <summary>The notice's words while AFK mode is on, and its button.</summary>
        public const string AfkText = "AFK mode on: jobs run right away";
        public const string AfkEndText = "End AFK mode";

        /// <summary>
        /// True when this decision switches AFK mode on: mode ask, nobody answered, the box has been up its five minutes and the job runs by itself. A yes (Run now), the other modes (they never ask, or never
        /// run by themselves) and a decision that is not Run never do.
        /// </summary>
        public static bool EntersAfk(OfferMode mode, OfferAnswer answer, TimeSpan elapsed, OfferDecision decision, bool afk)
        {
            return !afk && mode == OfferMode.Ask && answer == OfferAnswer.None && decision == OfferDecision.Run && elapsed >= AutoRunAfter;
        }

        /// <summary>Why AFK mode ends by itself, in plain words, or "" when it goes on: the player started Death Muffin or a full-screen app came up (they are back), or the PC was paused.</summary>
        public static string AfkEndReason(bool afk, bool gameRunning, bool fullscreen, bool paused)
        {
            if (!afk) return "";
            if (gameRunning) return "Death Muffin was started";
            if (fullscreen) return "a full-screen app came up";
            if (paused) return "the PC was paused";
            return "";
        }

        public static bool LeavesAfk(bool afk, bool gameRunning, bool fullscreen, bool paused) { return AfkEndReason(afk, gameRunning, fullscreen, paused).Length > 0; }

        /// <summary>The reason the server records for a decline: not_now (the person said no) or paused (a pause, or they chose Pause 2 hours).</summary>
        public static string DeclineReason(OfferAnswer answer, bool paused)
        {
            return answer == OfferAnswer.NotNow ? "not_now" : "paused";
        }

        /// <summary>Why a job is waiting, in plain words, or "" when nothing is in the way.</summary>
        public static string WaitReason(bool fullscreen, bool gameRunning, bool onBattery)
        {
            if (gameRunning) return "Death Muffin is open";
            if (fullscreen) return "a full-screen app is open";
            if (onBattery) return "this PC is on battery";
            return "";
        }

        /// <summary>"about 1 minute", "about 3 minutes", "less than a minute", "about 2 hours".</summary>
        public static string HowLong(int weightS)
        {
            if (weightS < 45) return "less than a minute";
            if (weightS < 90) return "about 1 minute";
            if (weightS < 3600) return "about " + (int)Math.Round(weightS / 60.0) + " minutes";
            int hours = (int)Math.Round(weightS / 3600.0);
            return "about " + hours + (hours == 1 ? " hour" : " hours");
        }

        /// <summary>The box's first line: what the job is and how heavy ("Screenshots of a change, about 1 minute").</summary>
        public static string OfferText(string title, int weightS) { return OfferText("", title, weightS); }

        /// <summary>
        /// The same for a job of this kind: the server's title when it sent one, else the kind's own words (<see cref="DefaultTitle"/>) - "Short videos of a change, about 3 minutes" for a clip job.
        /// </summary>
        public static string OfferText(string kind, string title, int weightS)
        {
            title = (title ?? "").Trim();
            if (title.Length == 0) title = DefaultTitle(kind);
            return EndsWithDuration(title) ? title : title + ", " + HowLong(weightS);
        }

        static readonly System.Text.RegularExpressions.Regex DurationRe = new System.Text.RegularExpressions.Regex(
            "(about [0-9]+ (minutes?|hours?)|less than a minute)[.!]?$", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant);

        /// <summary>
        /// Does the title already say how long the job takes ("Release checks of 20261019.1, about 40 minutes", "..., about 1 hour", "..., less than a minute")? The server titles its jobs that way, and the box
        /// must not say it twice.
        /// </summary>
        public static bool EndsWithDuration(string title) { return DurationRe.IsMatch((title ?? "").Trim()); }

        /// <summary>What the box calls a job whose title is empty: its kind in plain words.</summary>
        public static string DefaultTitle(string kind)
        {
            if (kind == JobPlan.ClipKind) return "Short videos of a change";
            if (kind == JobPlan.ReleaseKind) return "Release checks of the new client";
            if (kind == JobPlan.ShotsKind) return "Screenshots of a change";
            if (kind == JobPlan.BenchKind) return "Benchmark of the new release";
            return "A job";
        }

        /// <summary>
        /// The offer box's note for a job kind. A release job's checks start the game several times; its benchmark and soak steps wait for a quiet PC. A benchmark is offered like any job (the same box, modes and exceptions); the note says what happens after the yes: it starts only once the PC has been left
        /// alone for a minute, runs at normal priority (a lower one would skew the numbers) and starts over if the keyboard or mouse is touched. "" for the others.
        /// </summary>
        public static string OfferNote(string kind)
        {
            if (kind == JobPlan.ReleaseKind) return "The game starts several times, off screen and silent. The benchmark and the soak test wait for the PC to be left alone for a minute and run at normal priority.";
            return kind == JobPlan.BenchKind ? "It starts once the PC has been left alone for a minute, and runs at normal priority. Touching the mouse or keyboard restarts it." : "";
        }

        /// <summary>"4:12" for the box's countdown.</summary>
        public static string Clock(TimeSpan t)
        {
            if (t < TimeSpan.Zero) t = TimeSpan.Zero;
            return ((int)t.TotalMinutes).ToString(CultureInfo.InvariantCulture) + ":" + t.Seconds.ToString("00", CultureInfo.InvariantCulture);
        }

        public static bool PausedAt(DateTime pausedUntilUtc, DateTime nowUtc) { return pausedUntilUtc > nowUtc; }
    }

    internal static class VersionCompare
    {
        /// <summary>Compares dotted versions like "0.1.0" numerically (a suffix after '-' or '+' is ignored); anything non-numeric falls back to ordinal order.</summary>
        public static int Compare(string a, string b)
        {
            a = a ?? ""; b = b ?? "";
            long[] x = Nums(a), y = Nums(b);
            if (x == null || y == null) return Math.Sign(string.CompareOrdinal(a, b));
            for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
            {
                long p = i < x.Length ? x[i] : 0, q = i < y.Length ? y[i] : 0;
                if (p != q) return p < q ? -1 : 1;
            }
            return 0;
        }

        static long[] Nums(string v)
        {
            int cut = v.IndexOfAny(new[] { '-', '+' });
            string core = cut >= 0 ? v.Substring(0, cut) : v;
            if (core.Length == 0) return null;
            string[] parts = core.Split('.');
            var r = new long[parts.Length];
            for (int i = 0; i < parts.Length; i++)
                if (!long.TryParse(parts[i], NumberStyles.None, CultureInfo.InvariantCulture, out r[i])) return null;
            return r;
        }
    }

    internal static class Hashing
    {
        public static bool IsHex64(string s)
        {
            if (s == null || s.Length != 64) return false;
            foreach (char c in s) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
            return true;
        }

        public static string Sha256Hex(string path)
        {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16))
            using (var sha = SHA256.Create())
            {
                byte[] h = sha.ComputeHash(fs);
                var sb = new StringBuilder(64);
                foreach (byte b in h) sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }

        /// <summary>True when the file exists, has the expected size (when size is above 0) and the expected SHA-256 (case-insensitive hex).</summary>
        public static bool Verify(string path, long size, string sha256)
        {
            try
            {
                var fi = new FileInfo(path);
                if (!fi.Exists || (size > 0 && fi.Length != size)) return false;
                return string.Equals(Sha256Hex(path), sha256, StringComparison.OrdinalIgnoreCase);
            }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }
    }

    /// <summary>The numbers the heartbeat reports about this PC (what the Discord agent's runner reads to decide whether to offer a job).</summary>
    internal sealed class PcState
    {
        public bool GameRunning, Fullscreen, OnBattery, Busy, Paused;

        public Dictionary<string, object> ToJson()
        {
            return new Dictionary<string, object>
            {
                { "gameRunning", GameRunning }, { "fullscreen", Fullscreen }, { "onBattery", OnBattery }, { "busy", Busy }, { "paused", Paused },
            };
        }
    }
}
