using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace DeathMuffinTeam
{
    /// <summary>Protects a secret for the current Windows user (DPAPI, CurrentUser) and gives it back. Tests use a stand-in; Platform.cs has the real one.</summary>
    internal interface ITokenProtector
    {
        /// <summary>Base64 text that only this Windows user can turn back into <paramref name="plain"/>.</summary>
        string Protect(string plain);
        /// <summary>The secret, or null when the text is not ours or cannot be opened by this user (another account, a restored profile).</summary>
        string Unprotect(string protectedText);
    }

    /// <summary>
    /// %LOCALAPPDATA%\DeathMuffinTeam\settings.json: who is signed in (the team token DPAPI-protected, never in plain text), this PC's id, its mode and a pause.
    /// No password is ever stored. Read and written with MiniJson, so teamapp/tests round-trips the real thing.
    /// </summary>
    internal sealed class TeamSettings
    {
        public string Username = "";
        /// <summary>The team token in plain text, in memory only. Saved protected.</summary>
        public string Token = "";
        public string PcId = "";
        public OfferMode Mode = OfferMode.Ask;
        public DateTime PausedUntilUtc = DateTime.MinValue;

        public static string Root
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeathMuffinTeam"); }
        }

        public static string DefaultFile { get { return Path.Combine(Root, "settings.json"); } }

        public bool SignedIn { get { return Token.Length > 0; } }

        /// <summary>This PC's id for the server: 32 hex digits, made once ([A-Za-z0-9_-]{8,64} is what the server accepts).</summary>
        public void EnsurePcId()
        {
            if (PcId.Length < 8) PcId = Guid.NewGuid().ToString("N");
        }

        public bool IsPaused(DateTime nowUtc) { return TeamLogic.PausedAt(PausedUntilUtc, nowUtc); }

        public void ClearSignIn() { Token = ""; }

        public static TeamSettings Load(ITokenProtector protector, string file = null)
        {
            try
            {
                file = file ?? DefaultFile;
                if (File.Exists(file)) return FromJson(File.ReadAllText(file), protector);
            }
            catch (IOException) { /* unreadable: start signed out */ }
            catch (UnauthorizedAccessException) { }
            return new TeamSettings();
        }

        public void Save(ITokenProtector protector, string file = null)
        {
            try
            {
                file = file ?? DefaultFile;
                Directory.CreateDirectory(Path.GetDirectoryName(file));
                string tmp = file + ".tmp";
                File.WriteAllText(tmp, ToJson(protector), new UTF8Encoding(false));
                if (File.Exists(file)) File.Replace(tmp, file, null);
                else File.Move(tmp, file);
            }
            catch (IOException) { /* settings are a convenience; the app keeps working */ }
            catch (UnauthorizedAccessException) { }
        }

        /// <summary>A missing, mistyped or unknown key keeps its default; broken JSON gives the defaults; a secret that cannot be opened signs the person out.</summary>
        public static TeamSettings FromJson(string json, ITokenProtector protector)
        {
            var s = new TeamSettings();
            var d = MiniJson.TryObject(json);
            if (d == null) return s;
            s.Username = Clip(MiniJson.Str(d, "username"), 80);
            string pc = MiniJson.Str(d, "pcId");
            if (System.Text.RegularExpressions.Regex.IsMatch(pc, "^[A-Za-z0-9_-]{8,64}$")) s.PcId = pc;
            s.Mode = Modes.Parse(MiniJson.Str(d, "mode"));
            DateTime until;
            if (DateTime.TryParse(MiniJson.Str(d, "pausedUntil"), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out until))
                s.PausedUntilUtc = until.ToUniversalTime();
            string tok = MiniJson.Str(d, "token");
            if (tok.Length > 0) s.Token = protector.Unprotect(tok) ?? "";
            return s;
        }

        public string ToJson(ITokenProtector protector)
        {
            var d = new Dictionary<string, object>
            {
                { "username", Username },
                { "token", Token.Length > 0 ? protector.Protect(Token) : "" },
                { "pcId", PcId },
                { "mode", Modes.Wire(Mode) },
                { "pausedUntil", PausedUntilUtc > DateTime.MinValue ? PausedUntilUtc.ToString("o", System.Globalization.CultureInfo.InvariantCulture) : "" },
            };
            return MiniJson.Write(d);
        }

        static string Clip(string s, int max) { return s.Length > max ? s.Substring(0, max) : s; }
    }
}
