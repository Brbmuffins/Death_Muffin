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

        public static string FriendlyDate(string iso)
        {
            DateTime t;
            return DateTime.TryParse(iso, null, System.Globalization.DateTimeStyles.RoundtripKind, out t) ? t.ToLocalTime().ToString("d MMM yyyy") : "";
        }
    }
}
