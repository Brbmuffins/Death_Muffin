using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace DeathMuffinLauncher
{
    internal sealed class ReleaseNotes
    {
        public string Sha = "";
        public string Date = "";
        /// <summary>The release's name from PATCH_NOTES.json ("" when the deploy fell back to commit subjects).</summary>
        public string Title = "";
        public List<string> Items = new List<string>();
    }

    /// <summary>Reads the two tiny files the deploy script publishes next to the play page.</summary>
    internal static class Updates
    {
        public const string PlayUrl = "https://muffindevelopment.com/death-muffin/play/";
        public const string OfflineUrl = "https://muffindevelopment.com/death-muffin/offline/";
        public const string PrecacheUrl = PlayUrl + "precache.html";
        public const string CommitsUrl = "https://github.com/Brbmuffins/Death_Muffin/commits/master";
        /// <summary>Every release's player notes (site page fed by play/patch-notes.json).</summary>
        public const string PatchNotesUrl = "https://muffindevelopment.com/death-muffin/patch-notes.html";
        /// <summary>The newest launcher zip (an exe cannot replace itself, so this is the one thing that opens a browser).</summary>
        public const string LauncherDownloadUrl = "https://github.com/Brbmuffins/Death_Muffin/releases/latest/download/DeathMuffinLauncher-win-x64.zip";
        const string LatestReleaseApi = "https://api.github.com/repos/Brbmuffins/Death_Muffin/releases/latest";
        public const string WebView2Url = "https://developer.microsoft.com/en-us/microsoft-edge/webview2/";

        static readonly HttpClient Http = Create();

        static HttpClient Create()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var c = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            c.DefaultRequestHeaders.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { NoCache = true };
            c.DefaultRequestHeaders.UserAgent.ParseAdd("DeathMuffinLauncher/" + Program.Version);
            return c;
        }

        /// <summary>The live release sha from release.txt ("sha iso-time"), or null if it cannot be read.</summary>
        public static async Task<string> FetchLiveShaAsync()
        {
            try
            {
                string text = await Http.GetStringAsync(PlayUrl + "release.txt?t=" + DateTime.UtcNow.Ticks).ConfigureAwait(true);
                string sha = (text ?? "").Trim().Split(' ')[0];
                return sha.Length >= 7 ? sha : null;
            }
            catch { return null; }
        }

        /// <summary>The newest release-notes.json, or null (older releases or offline).</summary>
        public static async Task<ReleaseNotes> FetchNotesAsync()
        {
            try
            {
                string json = await Http.GetStringAsync(PlayUrl + "release-notes.json?t=" + DateTime.UtcNow.Ticks).ConfigureAwait(true);
                var d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
                var n = new ReleaseNotes();
                object v;
                if (d.TryGetValue("sha", out v) && v != null) n.Sha = v.ToString();
                if (d.TryGetValue("date", out v) && v != null) n.Date = v.ToString();
                if (d.TryGetValue("title", out v) && v != null) n.Title = v.ToString();
                if (d.TryGetValue("items", out v) && v is System.Collections.IEnumerable list && !(v is string))
                    foreach (object o in list) if (o != null) n.Items.Add(o.ToString());
                return n;
            }
            catch { return null; }
        }

        /// <summary>The whole notes history (patch-notes.json, newest first), or null.</summary>
        public static async Task<List<ReleaseNotes>> FetchAllNotesAsync()
        {
            try
            {
                string json = await Http.GetStringAsync(PlayUrl + "patch-notes.json?t=" + DateTime.UtcNow.Ticks).ConfigureAwait(true);
                var d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
                var list = new List<ReleaseNotes>();
                object v;
                if (!d.TryGetValue("releases", out v) || !(v is System.Collections.IEnumerable) || v is string) return list;
                foreach (object o in (System.Collections.IEnumerable)v)
                {
                    var r = o as Dictionary<string, object>;
                    if (r == null) continue;
                    var n = new ReleaseNotes();
                    object x;
                    if (r.TryGetValue("date", out x) && x != null) n.Date = x.ToString();
                    if (r.TryGetValue("title", out x) && x != null) n.Title = x.ToString();
                    if (r.TryGetValue("items", out x) && x is System.Collections.IEnumerable && !(x is string))
                        foreach (object it in (System.Collections.IEnumerable)x) if (it != null) n.Items.Add(it.ToString());
                    if (n.Items.Count > 0) list.Add(n);
                }
                return list;
            }
            catch { return null; }
        }

        /// <summary>
        /// The live offline build id: the generated service worker names its cache "dm-offline-&lt;hash&gt;", and the hash changes with every
        /// offline deploy. Comparing it with the id saved at download time says whether the offline copy is out of date.
        /// </summary>
        public static async Task<string> FetchOfflineVersionAsync()
        {
            try
            {
                string js = await Http.GetStringAsync(OfflineUrl + "sw.js?t=" + DateTime.UtcNow.Ticks).ConfigureAwait(true);
                var m = System.Text.RegularExpressions.Regex.Match(js, "dm-offline-([0-9a-f]{6,})");
                return m.Success ? m.Groups[1].Value : null;
            }
            catch { return null; }
        }

        /// <summary>The newest launcher version on GitHub if it is newer than this one (tag launcher-v&lt;version&gt;), else null.</summary>
        public static async Task<string> FetchNewerLauncherAsync()
        {
            try
            {
                string json = await Http.GetStringAsync(LatestReleaseApi).ConfigureAwait(true);
                var d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
                object v;
                if (!d.TryGetValue("tag_name", out v) || v == null) return null;
                string tag = v.ToString();
                if (!tag.StartsWith("launcher-v", StringComparison.Ordinal)) return null;
                string latest = tag.Substring("launcher-v".Length);
                Version a, b;
                if (!Version.TryParse(latest, out a) || !Version.TryParse(Program.Version, out b)) return null;
                return a > b ? latest : null;
            }
            catch { return null; }
        }

        public static string FriendlyDate(string iso)
        {
            DateTime t;
            return DateTime.TryParse(iso, null, System.Globalization.DateTimeStyles.RoundtripKind, out t) ? t.ToLocalTime().ToString("d MMM yyyy") : "";
        }
    }
}
