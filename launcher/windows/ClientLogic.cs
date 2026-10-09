using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

// Pure logic for the Godot client flow (manifest, versions, hashes, button state machines). No WinForms and no
// System.Web, so launcher/tests compiles this file on Linux too.
namespace DeathMuffinLauncher
{
    /// <summary>Tiny strict JSON reader (objects -> Dictionary, arrays -> List, numbers -> double). Throws FormatException.</summary>
    internal static class MiniJson
    {
        public static object Parse(string s)
        {
            if (s == null) throw new FormatException("null json");
            int i = 0;
            object v = Value(s, ref i, 0);
            Ws(s, ref i);
            if (i != s.Length) throw new FormatException("trailing characters");
            return v;
        }

        static void Ws(string s, ref int i) { while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n' || s[i] == '﻿')) i++; }

        static object Value(string s, ref int i, int depth)
        {
            if (depth > 32) throw new FormatException("too deep");
            Ws(s, ref i);
            if (i >= s.Length) throw new FormatException("unexpected end");
            char c = s[i];
            if (c == '{')
            {
                i++;
                var d = new Dictionary<string, object>();
                Ws(s, ref i);
                if (i < s.Length && s[i] == '}') { i++; return d; }
                while (true)
                {
                    Ws(s, ref i);
                    if (i >= s.Length || s[i] != '"') throw new FormatException("expected key");
                    string k = Str(s, ref i);
                    Ws(s, ref i);
                    if (i >= s.Length || s[i] != ':') throw new FormatException("expected :");
                    i++;
                    d[k] = Value(s, ref i, depth + 1);
                    Ws(s, ref i);
                    if (i >= s.Length) throw new FormatException("unexpected end");
                    if (s[i] == ',') { i++; continue; }
                    if (s[i] == '}') { i++; return d; }
                    throw new FormatException("expected , or }");
                }
            }
            if (c == '[')
            {
                i++;
                var l = new List<object>();
                Ws(s, ref i);
                if (i < s.Length && s[i] == ']') { i++; return l; }
                while (true)
                {
                    l.Add(Value(s, ref i, depth + 1));
                    Ws(s, ref i);
                    if (i >= s.Length) throw new FormatException("unexpected end");
                    if (s[i] == ',') { i++; continue; }
                    if (s[i] == ']') { i++; return l; }
                    throw new FormatException("expected , or ]");
                }
            }
            if (c == '"') return Str(s, ref i);
            if (Lit(s, ref i, "true")) return true;
            if (Lit(s, ref i, "false")) return false;
            if (Lit(s, ref i, "null")) return null;
            int st = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            double n;
            if (i == st || !double.TryParse(s.Substring(st, i - st), NumberStyles.Float, CultureInfo.InvariantCulture, out n)) throw new FormatException("bad value");
            return n;
        }

        static bool Lit(string s, ref int i, string w)
        {
            if (string.CompareOrdinal(s, i, w, 0, w.Length) != 0) return false;
            i += w.Length;
            return true;
        }

        static string Str(string s, ref int i)
        {
            i++; // opening quote
            var sb = new StringBuilder();
            while (true)
            {
                if (i >= s.Length) throw new FormatException("unterminated string");
                char c = s[i++];
                if (c == '"') return sb.ToString();
                if (c != '\\') { sb.Append(c); continue; }
                if (i >= s.Length) throw new FormatException("bad escape");
                char e = s[i++];
                switch (e)
                {
                    case '"': sb.Append('"'); break;
                    case '\\': sb.Append('\\'); break;
                    case '/': sb.Append('/'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case 'u':
                        int code;
                        if (i + 4 > s.Length || !int.TryParse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out code)) throw new FormatException("bad \\u");
                        sb.Append((char)code);
                        i += 4;
                        break;
                    default: throw new FormatException("bad escape");
                }
            }
        }
    }

    internal sealed class ManifestFile
    {
        public string Path = "";
        public long Size;
        public string Sha256 = "";
        public Uri Url;
    }

    /// <summary>The server's client manifest: which Godot build is current, its files and the online lock.</summary>
    internal sealed class ClientManifest
    {
        public const string ExeName = "DeathMuffin.exe";

        public string Version = "";
        public string BuiltAt = "";
        public string Rev = "";
        public List<ManifestFile> Files = new List<ManifestFile>();
        public bool OnlineEnabled;
        /// <summary>online.staff is a literal true: the Godot client lets only staff/GM accounts in (it asks the server); the launcher cannot tell, so it only shows the message.</summary>
        public bool OnlineStaff;
        public string OnlineMessage = "";
        /// <summary>The manifest text exactly as downloaded (saved next to the install so it can be checked later).</summary>
        public string Raw = "";

        public long TotalBytes { get { long t = 0; foreach (var f in Files) t += f.Size; return t; } }

        static bool SafeVersion(string v)
        {
            if (string.IsNullOrEmpty(v) || v.Length > 64 || !char.IsLetterOrDigit(v[0])) return false;
            foreach (char c in v) if (!(c < 128 && (char.IsLetterOrDigit(c) || c == '.' || c == '_' || c == '-'))) return false;
            return true;
        }

        public static bool SafeVersionName(string v) { return SafeVersion(v); }

        static bool SafePath(string p)
        {
            if (string.IsNullOrEmpty(p) || p.Length > 200 || p[0] == '/') return false;
            foreach (char c in p) if (!(c < 128 && (char.IsLetterOrDigit(c) || c == '.' || c == '_' || c == '-' || c == '/'))) return false;
            foreach (string seg in p.Split('/')) if (seg.Length == 0 || seg == "." || seg == "..") return false;
            return true;
        }

        public static bool IsHex64(string s)
        {
            if (s == null || s.Length != 64) return false;
            foreach (char c in s) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
            return true;
        }

        /// <summary>Parses and validates the manifest. File URLs must be on the same scheme and host as <paramref name="manifestUrl"/>.</summary>
        public static bool TryParse(string json, Uri manifestUrl, out ClientManifest manifest, out string error, bool enforceHost = true)
        {
            manifest = null;
            error = null;
            try
            {
                var root = MiniJson.Parse(json) as Dictionary<string, object>;
                if (root == null) { error = "manifest is not an object"; return false; }
                var m = new ClientManifest { Raw = json };
                m.Version = Str(root, "version");
                if (!SafeVersion(m.Version)) { error = "bad version"; return false; }
                m.BuiltAt = Str(root, "built_at");
                m.Rev = Str(root, "rev");
                var files = root.ContainsKey("files") ? root["files"] as List<object> : null;
                if (files == null || files.Count == 0) { error = "no files"; return false; }
                var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (object o in files)
                {
                    var d = o as Dictionary<string, object>;
                    if (d == null) { error = "bad file entry"; return false; }
                    var f = new ManifestFile { Path = Str(d, "path"), Sha256 = Str(d, "sha256").ToLowerInvariant() };
                    if (!SafePath(f.Path)) { error = "unsafe file path"; return false; }
                    if (!seen.Add(f.Path)) { error = "duplicate file " + f.Path; return false; }
                    if (!IsHex64(f.Sha256)) { error = "bad sha256 for " + f.Path; return false; }
                    object sz = d.ContainsKey("size") ? d["size"] : null;
                    if (!(sz is double) || (double)sz < 0 || (double)sz != Math.Floor((double)sz) || (double)sz > 1e12) { error = "bad size for " + f.Path; return false; }
                    f.Size = (long)(double)sz;
                    string url = Str(d, "url");
                    Uri u;
                    if (url.Length == 0) u = new Uri(manifestUrl, f.Path);
                    else if (!Uri.TryCreate(manifestUrl, url, out u)) { error = "bad url for " + f.Path; return false; }
                    if (enforceHost && (u.Scheme != manifestUrl.Scheme || !string.Equals(u.Host, manifestUrl.Host, StringComparison.OrdinalIgnoreCase) || u.Port != manifestUrl.Port))
                    { error = "file url leaves the server: " + f.Path; return false; }
                    f.Url = u;
                    m.Files.Add(f);
                }
                if (!seen.Contains(ExeName)) { error = ExeName + " missing from manifest"; return false; }
                var online = root.ContainsKey("online") ? root["online"] as Dictionary<string, object> : null;
                // Only a literal JSON true unlocks online. "true", 1 or a missing block all stay locked.
                if (online != null)
                {
                    m.OnlineEnabled = online.ContainsKey("enabled") && online["enabled"] is bool && (bool)online["enabled"];
                    m.OnlineStaff = online.ContainsKey("staff") && online["staff"] is bool && (bool)online["staff"];
                    m.OnlineMessage = Str(online, "message");
                }
                manifest = m;
                return true;
            }
            catch (FormatException ex) { error = "invalid manifest: " + ex.Message; return false; }
        }

        static string Str(Dictionary<string, object> d, string k)
        {
            object v;
            return d.TryGetValue(k, out v) && v is string ? (string)v : "";
        }
    }

    internal static class VersionCompare
    {
        /// <summary>Compares build versions like "20261004.153012-ab12cd3": the dotted part before '-' or '+' numerically, the suffix ignored. Non-numeric versions fall back to ordinal order.</summary>
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

        /// <summary>True when the file exists, has the expected size and the expected SHA-256 (case-insensitive hex).</summary>
        public static bool Verify(string path, long size, string sha256)
        {
            try
            {
                var fi = new FileInfo(path);
                return fi.Exists && fi.Length == size && string.Equals(Sha256Hex(path), sha256, StringComparison.OrdinalIgnoreCase);
            }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }
    }

    // ---- Online notice ------------------------------------------------------------------------------------------------------

    /// <summary>
    /// Death Muffin has one play path: online. The launcher never blocks PLAY on the online lock, because the game itself checks access
    /// at sign-in and shows its own message. The lock (online.enabled / online.staff / online.message) only produces a note under the button.
    /// </summary>
    internal static class OnlineGate
    {
        public const string DefaultMessage = "Online opens soon";
        public const string NoInternetNote = "No internet connection: the game needs it to sign in.";

        /// <summary>Short label for the lock: the developers' message (trimmed to one line) or the default.</summary>
        public static string LockMessage(ClientManifest live)
        {
            string m = live == null ? "" : (live.OnlineMessage ?? "").Replace('\r', ' ').Replace('\n', ' ').Trim();
            if (m.Length == 0) return DefaultMessage;
            return m.Length > 70 ? m.Substring(0, 69) + "…" : m;
        }

        /// <summary>Online is open to everyone only when a manifest was read and it says a literal enabled:true. Anything else (unreadable, missing,
        /// false, staff-only where the launcher cannot know if this user is staff) is "not known to be open".</summary>
        public static bool IsOpen(ClientManifest live) { return live != null && live.OnlineEnabled; }

        /// <summary>The note shown under PLAY about signing in: no internet, or the manifest message when online is not open. Empty when open.</summary>
        public static string Notice(ClientManifest live, bool netReachable)
        {
            if (!netReachable) return NoInternetNote;
            return IsOpen(live) ? "" : LockMessage(live);
        }
    }

    // ---- The one game button -----------------------------------------------------------------------------------------------

    internal enum PlayAction { None, Download, Update, Play }

    internal sealed class PlayInputs
    {
        /// <summary>Version of the verified installed client, or null.</summary>
        public string InstalledVersion;
        /// <summary>The live manifest, or null if it could not be read.</summary>
        public ClientManifest Live;
        /// <summary>The server answered at all (a missing/invalid manifest still counts as reachable).</summary>
        public bool NetReachable = true;
        /// <summary>The game process started by the launcher is still open.</summary>
        public bool Running;
        public bool Downloading;
        /// <summary>0..1, or negative when unknown.</summary>
        public double Progress = -1;
        public bool Failed;
        public string Error;
    }

    internal sealed class PlayUi
    {
        public string Text = "";
        public bool Enabled;
        public PlayAction Action = PlayAction.None;
        public string Note = "";
        /// <summary>Sign-in note (no internet / "Online opens soon"), shown after Note when the game is installed.</summary>
        public string Notice = "";
        public bool Warn;
        public bool ShowBar;
        public double Bar;
        /// <summary>"Play installed version instead" link, shown when an update is pending or a download failed but a copy exists.</summary>
        public bool ShowPlayInstalledLink;

        /// <summary>Note and Notice as one line.</summary>
        public string FullNote { get { return Notice.Length == 0 ? Note : Note + "  " + Notice; } }
    }

    internal static class PlayStateMachine
    {
        public static string Mb(long bytes) { return Math.Max(1, (long)Math.Round(bytes / 1048576.0)).ToString(CultureInfo.InvariantCulture) + " MB"; }

        public static string ShortVersion(string v) { return v != null && v.Length > 22 ? v.Substring(0, 22) : (v ?? ""); }

        public static PlayUi Compute(PlayInputs i)
        {
            var ui = new PlayUi();
            bool have = i.InstalledVersion != null;
            bool canFetch = i.NetReachable && i.Live != null;
            if (i.Downloading)
            {
                int pct = i.Progress >= 0 ? (int)Math.Min(100, Math.Floor(i.Progress * 100)) : -1;
                ui.Text = pct >= 0 ? "DOWNLOADING " + pct + "%" : "DOWNLOADING...";
                ui.Note = "Keep the launcher open until it finishes.";
                ui.ShowBar = true;
                ui.Bar = Math.Max(0, i.Progress);
                return ui;
            }
            if (i.Running)
            {
                ui.Text = "GAME RUNNING";
                ui.Note = "Close the game window to play or update again.";
                return ui;
            }
            if (i.Failed)
            {
                ui.Text = "RETRY DOWNLOAD";
                ui.Enabled = canFetch;
                ui.Action = have ? PlayAction.Update : PlayAction.Download;
                ui.Note = string.IsNullOrEmpty(i.Error) ? "The download stopped. Already downloaded parts are kept." : i.Error;
                ui.Warn = true;
                ui.ShowPlayInstalledLink = have;
                return ui;
            }
            if (have)
            {
                // PLAY is never locked by the online state: the game shows its own sign-in message. We only add a note.
                ui.Notice = OnlineGate.Notice(i.Live, i.NetReachable);
                if (canFetch && VersionCompare.Compare(i.Live.Version, i.InstalledVersion) > 0)
                {
                    ui.Text = "UPDATE GAME";
                    ui.Enabled = true;
                    ui.Action = PlayAction.Update;
                    ui.Note = "New build available (" + Mb(i.Live.TotalBytes) + "). Installed: " + ShortVersion(i.InstalledVersion) + ".";
                    ui.ShowPlayInstalledLink = true;
                    return ui;
                }
                ui.Text = "PLAY";
                ui.Enabled = true;
                ui.Action = PlayAction.Play;
                ui.Note = "Build " + ShortVersion(i.InstalledVersion) + (canFetch ? ", up to date." : ".");
                return ui;
            }
            ui.Text = "DOWNLOAD GAME";
            if (canFetch)
            {
                ui.Enabled = true;
                ui.Action = PlayAction.Download;
                ui.Note = "Saves the game to this PC (" + Mb(i.Live.TotalBytes) + "). Needs internet.";
            }
            else if (!i.NetReachable)
                ui.Note = "No internet connection. Connect to download the game.";
            else
            {
                ui.Text = "GAME NOT AVAILABLE YET";
                ui.Note = "The game build is not published yet. Try again later.";
            }
            return ui;
        }
    }
}
