using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Web.WebView2.WinForms;

namespace DeathMuffinLauncher
{
    internal sealed class LauncherForm : Form
    {
        static readonly Color Bg = Art.Bg;
        static readonly Color Violet = Art.Violet;
        static readonly Color VioletLight = Art.VioletLight;
        static readonly Color Ink = Art.Ink;
        static readonly Color Muted = Art.Muted;
        static readonly Color Gold = Art.Gold;

        public static Icon AppIcon { get { return Icon.ExtractAssociatedIcon(Application.ExecutablePath); } }

        readonly Settings settings = Settings.Load();
        readonly Label status = new GlassLabel();
        readonly Label updateLabel = new GlassLabel();
        readonly ThinBar bar = new ThinBar();
        readonly Label newsTitle = new GlassLabel();
        // Scrollable so a whole release's notes fit (the old label showed six lines and cut the rest).
        readonly TextBox newsBody = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, TabStop = false, WordWrap = true };
        readonly LinkLabel newsLink = new LinkLabel();
        readonly RuneButton playBtn, downloadBtn, openBtn;
        readonly LinkLabel launcherLink = new LinkLabel();
        readonly Label playNote = new GlassLabel(), dlNote = new GlassLabel(), openNote = new GlassLabel(), modeLabel = new GlassLabel();
        readonly ThinBar dlBar = new ThinBar();
        readonly Timer netTimer = new Timer { Interval = 20000 };
        readonly CheckBox gpu = new CheckBox();
        readonly WebView2 precacheWeb = new WebView2 { Size = new Size(1, 1), Location = new Point(0, 0) };
        GameWindow online, offline;
        PatchNotesWindow patchWin;
        static readonly Color Orange = Color.FromArgb(244, 176, 128);
        static readonly Color Good = Color.FromArgb(150, 214, 160);
        /// <summary>False once a check of the live site fails (no internet). Starts true so Play is usable while the first check runs.</summary>
        bool netOnline = true, rechecking, launcherChecked;
        string liveSha, liveOffline;
        // Offline download progress, driven by the status text the offline page relays (see OnOfflineStatus).
        bool downloading, downloadFailed, sawProgress;
        int downloadPct = -1;
        string downloadError;
        string precacheSha;
        bool precaching;
        string statusLink;
        /// <summary>WebView2 is missing or will not start: the game opens in a browser instead (see BrowserFallback). The only case where it does.</summary>
        bool useBrowser;

        public LauncherForm()
        {
            Text = "Death Muffin Launcher";
            Icon = AppIcon;
            // The art remains the centrepiece, with a permanent command deck below it.
            ClientSize = new Size(1180, 680);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Bg;
            Font = new Font("Segoe UI", 9.5f);

            // Native controls sit over a single painted frame, keeping the launch actions usable while art and news load.
            var root = new Backdrop() { Dock = DockStyle.Fill };
            Controls.Add(root);

            int x = 48, w = 350;
            root.Controls.Add(Lbl("THE LIVE REALM", new Font("Segoe UI", 9f, FontStyle.Bold), Gold, x, 145, w, 20));
            root.Controls.Add(Lbl("Your journey continues in the Ossuary Covenant.", new Font("Segoe UI", 10f), Ink, x, 170, w, 44));

            // 1. PLAY ONLINE: the normal game.
            playBtn = Btn("PLAY ONLINE   ›", 866, 563, 268, 64, true);
            playBtn.Font = new Font("Georgia", 16f, FontStyle.Bold);
            playBtn.Click += (s, e) => OpenGame(false, false);
            root.Controls.Add(playBtn);
            Note(playNote, 866, 638, 268, 16, "The live game. Needs internet.");
            root.Controls.Add(playNote);

            updateLabel.SetBounds(x, 226, w, 38);
            updateLabel.ForeColor = Muted;
            updateLabel.Text = "Checking for updates...";
            bar.SetBounds(x, 267, w, 5);
            bar.Visible = false;
            root.Controls.Add(updateLabel);
            root.Controls.Add(bar);
            // Shown only when GitHub has a newer launcher. It opens the zip in the browser: an exe cannot replace itself.
            launcherLink.SetBounds(x, 271, w, 16);
            launcherLink.BackColor = Color.Transparent;
            launcherLink.LinkColor = Gold;
            launcherLink.ActiveLinkColor = Ink;
            launcherLink.LinkBehavior = LinkBehavior.HoverUnderline;
            launcherLink.Font = new Font("Segoe UI", 8.5f);
            launcherLink.AutoEllipsis = true;
            launcherLink.Visible = false;
            launcherLink.LinkClicked += (s, e) => OpenExternalPage(Updates.LauncherDownloadUrl);
            root.Controls.Add(launcherLink);

            // 2 + 3. Offline edition: Download and Play are always both visible, each with its own one-line caption.
            root.Controls.Add(Lbl("OFFLINE EDITION  -  SAME ACCOUNT AND CHARACTER", new Font("Segoe UI", 8.5f, FontStyle.Bold), Gold, 40, 546, 520, 18));
            downloadBtn = Btn("DOWNLOAD OFFLINE", 40, 568, 252, 42, false);
            openBtn = Btn("PLAY OFFLINE", 308, 568, 252, 42, false);
            downloadBtn.Click += (s, e) => OpenGame(true, true);
            openBtn.Click += (s, e) => OpenGame(true, false);
            root.Controls.Add(downloadBtn);
            root.Controls.Add(openBtn);
            Note(dlNote, 40, 614, 252, 34, "");
            Note(openNote, 308, 614, 252, 34, "");
            dlBar.SetBounds(40, 652, 252, 4);
            dlBar.Visible = false;
            root.Controls.Add(dlNote);
            root.Controls.Add(openNote);
            root.Controls.Add(dlBar);

            root.Controls.Add(Lbl("WORLD DISPATCH", new Font("Segoe UI", 9f, FontStyle.Bold), Gold, x, 303, w, 20));
            newsTitle.SetBounds(x, 329, w, 38);
            newsTitle.ForeColor = Ink;
            newsTitle.Font = new Font("Georgia", 13f, FontStyle.Bold);
            newsTitle.Text = "Loading...";
            newsBody.SetBounds(x, 370, w, 117);
            newsBody.ForeColor = Muted;
            newsBody.BackColor = Color.FromArgb(14, 17, 31);
            newsBody.Font = new Font("Segoe UI", 9.5f);
            newsLink.SetBounds(x, 495, 200, 20);
            newsLink.Text = "All patch notes";
            newsLink.BackColor = Color.Transparent;
            newsLink.LinkColor = Gold;
            newsLink.ActiveLinkColor = Ink;
            newsLink.LinkBehavior = LinkBehavior.HoverUnderline;
            newsLink.Visible = false;
            // Opens inside the launcher (reads play/patch-notes.json), not the browser.
            newsLink.LinkClicked += (s, e) => ShowPatchNotes();
            root.Controls.Add(newsTitle);
            root.Controls.Add(newsBody);
            root.Controls.Add(newsLink);

            // Middle column: which mode is running, the GPU setting, and the status line.
            modeLabel.SetBounds(590, 568, 250, 20);
            modeLabel.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            root.Controls.Add(modeLabel);
            gpu.SetBounds(590, 590, 250, 22);
            gpu.Text = "Use high-performance GPU";
            gpu.ForeColor = Muted;
            gpu.BackColor = Color.Transparent;
            gpu.Checked = settings.HighPerformanceGpu;
            gpu.CheckedChanged += (s, e) =>
            {
                settings.HighPerformanceGpu = gpu.Checked;
                settings.Save();
                if (online != null || offline != null || precaching) SetStatus("GPU setting applies the next time the launcher starts.");
            };
            root.Controls.Add(gpu);

            status.SetBounds(590, 616, 250, 42);
            status.ForeColor = Muted;
            root.Controls.Add(status);
            root.Controls.Add(Lbl("LAUNCHER " + Program.Version, new Font("Segoe UI", 8f, FontStyle.Bold), Muted, 700, 546, 140, 16, ContentAlignment.TopRight));
            foreach (var l in new Label[] { updateLabel, newsTitle, status }) { l.AutoEllipsis = true; l.BackColor = Color.Transparent; }
            var statusTip = new ToolTip();
            status.TextChanged += (s, e) => statusTip.SetToolTip(status, status.Text);
            status.Click += (s, e) => { if (statusLink != null) OpenExternalPage(statusLink); };
            // 1x1 control that hosts the hidden precache page (WebView2 needs a window to initialise in).
            Controls.Add(precacheWeb);

            netTimer.Tick += async (s, e) => await RecheckNetworkAsync();
            NetworkChange.NetworkAvailabilityChanged += OnNetworkChanged;
            SetStatus("Ready. The online game updates when you open it.");
            UpdateMode();
            ApplyOfflineUi();
            Shown += async (s, e) => await InitAsync();
        }

        static void Note(Label l, int x, int y, int w, int h, string text)
        {
            l.SetBounds(x, y, w, h);
            l.Font = new Font("Segoe UI", 8.5f);
            l.ForeColor = Muted;
            l.BackColor = Color.Transparent;
            l.Text = text;
        }

        void OnNetworkChanged(object sender, NetworkAvailabilityEventArgs e)
        {
            // Raised on a thread-pool thread. Either way the real answer is a request to the live site.
            try { if (IsHandleCreated && !IsDisposed) BeginInvoke(new Action(async () => await RecheckNetworkAsync())); } catch { }
        }

        static Label Lbl(string text, Font f, Color c, int x, int y, int w, int h, ContentAlignment a = ContentAlignment.TopLeft)
        {
            var l = new GlassLabel { Text = text, Font = f, ForeColor = c, BackColor = Color.Transparent, TextAlign = a };
            l.SetBounds(x, y, w, h);
            return l;
        }

        static RuneButton Btn(string text, int x, int y, int w, int h, bool primary)
        {
            var b = new RuneButton(text, primary) { Font = new Font("Segoe UI", 10f, FontStyle.Bold) };
            b.SetBounds(x, y, w, h);
            return b;
        }

        void SetStatus(string text)
        {
            statusLink = null;
            status.Cursor = Cursors.Default;
            status.ForeColor = Muted;
            status.Text = text;
        }

        async System.Threading.Tasks.Task InitAsync()
        {
            // Play stays enabled whatever the WebView2 check says: without it the game opens in Chrome/Edge/Brave (or the default
            // browser) instead, so a missing or broken runtime never locks the player out.
            var rt = WebViewHost.CheckRuntime();
            if (rt.Problem != null || rt.Missing)
            {
                useBrowser = true;
                if (rt.Problem != null)
                    Warn("Launcher files are missing (unzip the whole folder to fix). The game will open in your browser meanwhile. (" + rt.Problem + ")", null);
                else
                    Warn("WebView2 is missing, so the game opens in your browser. Click here to install WebView2 and get the launcher's own game window.", Updates.WebView2Url);
                ApplyOfflineUi();
            }
            var news = ShowNewsAsync();
            string live = await Updates.FetchLiveShaAsync();
            if (live != null) liveSha = live;
            SetNetwork(live != null);
            if (live == null)
            {
                updateLabel.Text = "No internet connection. Updates can't be checked.";
            }
            else
            {
                await AfterOnlineAsync(live);
            }
            await news;
        }

        /// <summary>Everything that needs the live site: the game update check, the offline build id and the launcher self-check.</summary>
        async System.Threading.Tasks.Task AfterOnlineAsync(string live)
        {
            var offlineVer = Updates.FetchOfflineVersionAsync();
            var launcherVer = launcherChecked ? null : Updates.FetchNewerLauncherAsync();
            if (useBrowser)
                updateLabel.Text = "Playing in your browser (no update pre-download).";
            else if (string.Equals(live, settings.LastPrecachedSha, StringComparison.OrdinalIgnoreCase))
                updateLabel.Text = "Up to date (" + Short(live) + ").";
            else
            {
                updateLabel.Text = "Update available (" + Short(live) + "). Preparing files...";
                updateLabel.ForeColor = VioletLight;
                if (!precaching) await StartPrecacheAsync(live);
            }
            string ov = await offlineVer;
            if (ov != null) { liveOffline = ov; ApplyOfflineUi(); }
            if (launcherVer != null)
            {
                launcherChecked = true;
                string nv = await launcherVer;
                if (nv != null)
                {
                    launcherLink.Text = "Launcher " + nv + " available: click to download (opens your browser).";
                    launcherLink.Links.Clear();
                    launcherLink.Links.Add(0, launcherLink.Text.Length);
                    launcherLink.Visible = true;
                }
            }
        }

        /// <summary>Re-asks the live site; runs when Windows reports a network change and every 20 s while offline.</summary>
        async System.Threading.Tasks.Task RecheckNetworkAsync()
        {
            if (rechecking || IsDisposed) return;
            rechecking = true;
            try
            {
                string live = await Updates.FetchLiveShaAsync();
                bool was = netOnline;
                if (live != null) liveSha = live;
                SetNetwork(live != null);
                if (live != null && !was) await AfterOnlineAsync(live);
            }
            finally { rechecking = false; }
        }

        void SetNetwork(bool on)
        {
            bool changed = on != netOnline;
            netOnline = on;
            playBtn.Enabled = on;
            playNote.Text = on ? "The live game. Needs internet." : "No internet connection.";
            playNote.ForeColor = on ? Muted : Orange;
            netTimer.Enabled = !on;
            ApplyOfflineUi();
            if (!changed) return;
            if (on) { SetStatus("Back online."); return; }
            if (settings.OfflineDownloaded || useBrowser)
            {
                Warn("No internet connection. Online play is unavailable; Play offline works.", null);
                if (openBtn.Enabled) openBtn.Focus();
            }
            else
                Warn("No internet connection. Connect once to download the offline game, then you can play without internet.", null);
        }

        void Warn(string text, string link)
        {
            SetStatus(text);
            status.ForeColor = Orange;
            statusLink = link;
            if (link != null) status.Cursor = Cursors.Hand;
        }

        static string Short(string sha) { return sha.Length > 7 ? sha.Substring(0, 7) : sha; }

        /// <summary>The offline update check: the live offline build differs from the one that was downloaded.</summary>
        bool OfflineUpdateAvailable
        {
            get { return settings.OfflineDownloaded && liveOffline != null && settings.OfflineVersion.Length > 0 && !string.Equals(liveOffline, settings.OfflineVersion, StringComparison.OrdinalIgnoreCase); }
        }

        /// <summary>
        /// Paints the Download and Play offline buttons and their captions from one place, so the states cannot disagree:
        /// downloaded flag (saved) + downloading (live) + internet + WebView2/browser mode.
        /// </summary>
        void ApplyOfflineUi()
        {
            bool have = settings.OfflineDownloaded;
            dlBar.Visible = downloading && !useBrowser;
            dlNote.ForeColor = Muted;
            openNote.ForeColor = Muted;
            if (useBrowser)
            {
                // Download state lives in the browser, so the launcher cannot track it: both buttons just open the offline page there.
                downloadBtn.Text = "DOWNLOAD OFFLINE"; downloadBtn.Enabled = true;
                dlNote.Text = "Opens in your browser and saves the game there (≈105 MB).";
                openBtn.Text = "PLAY OFFLINE"; openBtn.Enabled = true; openBtn.Primary = !netOnline;
                openNote.Text = "No internet needed once downloaded. Same account; syncs when you're back online.";
                return;
            }
            if (downloading)
            {
                downloadBtn.Text = downloadPct >= 0 ? "DOWNLOADING... " + downloadPct + "%" : "DOWNLOADING...";
                downloadBtn.Enabled = false;
                dlNote.Text = "Keep the offline window open until it says Ready.";
                if (downloadPct >= 0) dlBar.Value = downloadPct / 100.0;
            }
            else if (downloadFailed)
            {
                downloadBtn.Text = "RETRY DOWNLOAD"; downloadBtn.Enabled = netOnline;
                dlNote.Text = downloadError ?? "The download stopped.";
                dlNote.ForeColor = Orange;
            }
            else if (have)
            {
                bool upd = OfflineUpdateAvailable;
                downloadBtn.Text = upd ? "UPDATE OFFLINE COPY" : "DOWNLOAD AGAIN";
                downloadBtn.Enabled = netOnline;
                string d = Updates.FriendlyDate(settings.OfflineDownloadedAt);
                string v = settings.OfflineVersion.Length > 0 ? "build " + Short(settings.OfflineVersion) : "";
                string when = (d + (d.Length > 0 && v.Length > 0 ? ", " : "") + v).Trim();
                dlNote.Text = "Downloaded ✓" + (when.Length > 0 ? " " + when : "") + (upd ? "\r\nA newer offline release is available." : "");
                dlNote.ForeColor = upd ? VioletLight : Good;
            }
            else
            {
                downloadBtn.Text = "DOWNLOAD OFFLINE"; downloadBtn.Enabled = netOnline;
                dlNote.Text = netOnline ? "Saves the game to this PC (≈105 MB)." : "Needs internet once. Saves the game to this PC (≈105 MB).";
            }
            downloadBtn.AccessibleDescription = dlNote.Text;
            openBtn.Text = "PLAY OFFLINE";
            if (have)
            {
                openBtn.Enabled = true;
                openBtn.Primary = !netOnline; // no internet: this is now the way in
                openNote.Text = "No internet needed. Same account; syncs when you're back online.";
            }
            else
            {
                openBtn.Enabled = false;
                openBtn.Primary = false;
                openNote.Text = "Download offline first.";
            }
            openBtn.AccessibleDescription = openNote.Text;
        }

        void UpdateMode()
        {
            if (Alive(online)) { modeLabel.Text = "Online game running"; modeLabel.ForeColor = VioletLight; }
            else if (Alive(offline)) { modeLabel.Text = "Offline game running"; modeLabel.ForeColor = Gold; }
            else { modeLabel.Text = "No game running"; modeLabel.ForeColor = Muted; }
        }

        static bool Alive(GameWindow w) { return w != null && !w.IsDisposed; }

        async System.Threading.Tasks.Task ShowNewsAsync()
        {
            var n = await Updates.FetchNotesAsync();
            if (n == null || n.Items.Count == 0)
            {
                newsTitle.Text = "No release notes available.";
                return;
            }
            string d = Updates.FriendlyDate(n.Date);
            string name = n.Title.Length > 0 ? n.Title : "Release " + Short(n.Sha);
            newsTitle.Text = name + (d.Length > 0 ? "  -  " + d : "");
            // TextBox lines need CRLF; a blank line between items keeps long notes readable.
            newsBody.Text = "• " + string.Join("\r\n\r\n• ", n.Items);
            newsBody.SelectionStart = 0;
            newsLink.Visible = true;
        }

        async System.Threading.Tasks.Task StartPrecacheAsync(string sha)
        {
            try
            {
                precaching = true;
                precacheSha = sha;
                bar.Value = 0;
                bar.Visible = true;
                var env = await WebViewHost.GetEnvironmentAsync(settings);
                await precacheWeb.EnsureCoreWebView2Async(env);
                precacheWeb.CoreWebView2.WebMessageReceived += OnPrecacheMessage;
                precacheWeb.CoreWebView2.Navigate(Updates.PrecacheUrl);
            }
            catch (Exception)
            {
                FinishPrecache(false, "Update check skipped. You can still play.");
            }
        }

        void OnPrecacheMessage(object sender, Microsoft.Web.WebView2.Core.CoreWebView2WebMessageReceivedEventArgs e)
        {
            string m = e.TryGetWebMessageAsString();
            if (m == null) return;
            if (m.StartsWith("dm-precache:", StringComparison.Ordinal))
            {
                string[] p = m.Substring("dm-precache:".Length).Split('/');
                int done, total;
                if (p.Length == 2 && int.TryParse(p[0], out done) && int.TryParse(p[1], out total) && total > 0)
                {
                    bar.Value = (double)done / total;
                    updateLabel.Text = "Updating game files... " + done + " / " + total;
                }
            }
            else if (m.StartsWith("dm-precache-done:", StringComparison.Ordinal))
            {
                bool ok = m.EndsWith(":ok", StringComparison.Ordinal);
                FinishPrecache(ok, ok ? null : "Some files could not be prepared; the game will fetch them when needed.");
            }
        }

        void FinishPrecache(bool ok, string message)
        {
            precaching = false;
            bar.Visible = false;
            if (ok)
            {
                settings.LastPrecachedSha = precacheSha;
                settings.Save();
                updateLabel.Text = "Up to date (" + Short(precacheSha) + ").";
                updateLabel.ForeColor = Muted;
            }
            else
            {
                updateLabel.Text = message;
                updateLabel.ForeColor = Muted;
            }
            try { if (precacheWeb.CoreWebView2 != null) precacheWeb.CoreWebView2.Navigate("about:blank"); } catch { }
        }

        /// <summary>Reads the status text the offline page relays and updates the saved "downloaded" state from it.</summary>
        void OnOfflineStatus(string t)
        {
            bool dirty = false;
            if (t.IndexOf("Ready to play without a network", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                bool finishedNow = downloading && sawProgress;
                if (!settings.OfflineDownloaded || settings.OfflineVersion.Length == 0 || finishedNow)
                {
                    settings.OfflineVersion = liveOffline ?? settings.OfflineVersion;
                    settings.OfflineDownloadedAt = DateTime.UtcNow.ToString("o");
                    dirty = true;
                }
                if (!settings.OfflineDownloaded) { settings.OfflineDownloaded = true; dirty = true; }
                downloading = false; downloadFailed = false; sawProgress = false; downloadPct = -1;
                SetStatus(finishedNow ? "Offline copy ready. You can play without internet." : t);
            }
            else if (t.StartsWith("Downloading game assets", StringComparison.OrdinalIgnoreCase))
            {
                downloading = true; downloadFailed = false; sawProgress = true;
                int c = t.IndexOf(':');
                if (c >= 0)
                {
                    string[] p = t.Substring(c + 1).Split('/');
                    int done, total;
                    if (p.Length == 2 && int.TryParse(p[0].Trim(), out done) && int.TryParse(p[1].Trim(), out total) && total > 0)
                        downloadPct = Math.Min(100, done * 100 / total);
                }
                SetStatus("Downloading the offline game" + (downloadPct >= 0 ? " (" + downloadPct + "%)" : "") + ". Keep the offline window open.");
            }
            else if (t.StartsWith("Download paused", StringComparison.OrdinalIgnoreCase) || t.IndexOf("unavailable", StringComparison.OrdinalIgnoreCase) >= 0 || t.IndexOf("needs a browser", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                downloading = false; downloadFailed = true; sawProgress = false; downloadPct = -1;
                downloadError = t;
                Warn(t, null);
            }
            else if (t.IndexOf("Download the game assets", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                // The page says the files are not (or no longer) in the cache, whatever we saved earlier.
                if (settings.OfflineDownloaded) { settings.OfflineDownloaded = false; dirty = true; }
                if (!downloading) SetStatus("The offline game is not downloaded yet. Press Download offline.");
            }
            if (dirty) settings.Save();
            ApplyOfflineUi();
        }

        /// <summary>
        /// Opens the online game (offlineEdition false), the offline edition (true), or the offline edition and starts its
        /// download (offlineEdition and download). Online and offline use the same account and sign each other out, so only one
        /// window is ever open: the other is closed first, after asking.
        /// </summary>
        void OpenGame(bool offlineEdition, bool download)
        {
            string url = offlineEdition ? Updates.OfflineUrl : Updates.PlayUrl;
            if (offlineEdition && download) url += "?download=1";
            if (useBrowser)
            {
                // Genuine fallback only (WebView2 missing/broken). Windows of a browser cannot be tracked or closed from here.
                OpenInBrowser(offlineEdition ? Updates.OfflineUrl + "?download=1" : url);
                return;
            }
            GameWindow same = offlineEdition ? offline : online;
            GameWindow other = offlineEdition ? online : offline;
            if (Alive(other))
            {
                string which = offlineEdition ? "online" : "offline";
                if (MessageBox.Show(this, "Close the " + which + " game first? Both use your account and would sign each other out.", "Death Muffin",
                        MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button1) != DialogResult.Yes)
                    return;
                other.Close();
            }
            if (offlineEdition && download)
            {
                downloading = true; downloadFailed = false; sawProgress = false; downloadPct = -1;
                ApplyOfflineUi();
            }
            if (Alive(same))
            {
                if (same.WindowState == FormWindowState.Minimized) same.WindowState = FormWindowState.Normal;
                if (download) same.NavigateTo(url); // already open: reload it with ?download=1 so Download still works
                same.Activate();
                if (download) SetStatus("Preparing the offline download.");
                return;
            }
            var w = new GameWindow(settings, url, offlineEdition);
            // WebView2 would not start after all: switch to the browser for this and every later launch this session.
            w.WebViewUnavailable += () =>
            {
                useBrowser = true;
                downloading = false;
                ApplyOfflineUi();
                Warn("The game window could not start (WebView2 problem), so it is opening in your browser instead.", Updates.WebView2Url);
                OpenInBrowser(offlineEdition ? Updates.OfflineUrl + "?download=1" : Updates.PlayUrl, true);
            };
            w.OfflineStatus += OnOfflineStatus;
            w.Failed += t =>
            {
                if (offlineEdition && downloading) { downloading = false; downloadFailed = true; downloadError = t; ApplyOfflineUi(); }
                SetStatus(t);
            };
            w.FormClosed += (s, e) =>
            {
                // Guard: a window replaced by the other mode must not null out its successor.
                if (offlineEdition) { if (ReferenceEquals(offline, w)) offline = null; }
                else if (ReferenceEquals(online, w)) online = null;
                if (offlineEdition && downloading) { downloading = false; sawProgress = false; downloadPct = -1; ApplyOfflineUi(); }
                UpdateMode();
            };
            if (offlineEdition) offline = w; else online = w;
            UpdateMode();
            SetStatus(download ? "Preparing the offline download." : offlineEdition ? "Offline game opening." : "Opening the Covenant.");
            if (!offlineEdition) w.Shown += (s, e) => SetStatus("Online game running.");
            else if (!download) w.Shown += (s, e) => SetStatus("Offline game running. Progress syncs next time you're online.");
            w.Show();
        }

        void ShowPatchNotes()
        {
            if (Alive2(patchWin)) { patchWin.Activate(); return; }
            patchWin = new PatchNotesWindow();
            patchWin.FormClosed += (s, e) => patchWin = null;
            patchWin.Show(this);
        }

        static bool Alive2(Form f) { return f != null && !f.IsDisposed; }

        /// <summary>Fallback only (WebView2 missing/broken): the browser window is outside the launcher, so say why.</summary>
        void OpenInBrowser(string url, bool keepStatus = false)
        {
            string used = BrowserFallback.Open(url);
            if (used == null) Warn("Could not open a browser, and WebView2 is unavailable. The game is at " + url, url);
            else if (!keepStatus) SetStatus("WebView2 is missing, so the game opened in " + used + ".");
        }

        /// <summary>Every remaining browser launch goes through here: the launcher zip, the WebView2 installer, and the fallback's own link.</summary>
        static void OpenExternalPage(string url)
        {
            try { System.Diagnostics.Process.Start(url); } catch { }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            base.OnFormClosing(e);
            if (e.Cancel) return;
            NetworkChange.NetworkAvailabilityChanged -= OnNetworkChanged;
            netTimer.Stop();
            foreach (var w in new[] { online, offline }) if (Alive(w)) w.Close();
            if (Alive2(patchWin)) patchWin.Close();
        }

        /// <summary>
        /// Key art inside a painted indigo frame. The composite is rendered once per size, so transparent
        /// labels and progress updates repaint cheaply.
        /// </summary>
        sealed class Backdrop : System.Windows.Forms.Panel
        {
            Bitmap frame;
            public Backdrop() { DoubleBuffered = true; BackColor = Bg; }

            protected override void OnPaintBackground(PaintEventArgs e)
            {
                if (frame == null || frame.Size != ClientSize) Compose();
                if (frame != null) e.Graphics.DrawImageUnscaled(frame, 0, 0);
            }

            protected override void Dispose(bool disposing)
            {
                if (disposing && frame != null) frame.Dispose();
                base.Dispose(disposing);
            }

            void Compose()
            {
                if (Width <= 0 || Height <= 0) return;
                if (frame != null) frame.Dispose();
                frame = new Bitmap(Width, Height);
                using (var g = Graphics.FromImage(frame))
                {
                    Art.Quality(g);
                    g.Clear(Bg);
                    // Keep the figure and cathedral unobstructed; only the naturally dark side carries reading content.
                    Art.DrawCover(g, ClientSize);

                    var left = new Rectangle(0, 0, 650, Height);
                    using (var br = new LinearGradientBrush(left, Color.Black, Color.Black, 0f))
                    {
                        br.InterpolationColors = new ColorBlend
                        {
                            Colors = new[] { Color.FromArgb(229, 7, 11, 24), Color.FromArgb(207, 8, 11, 25), Color.FromArgb(94, 8, 11, 25), Color.FromArgb(0, 8, 11, 25) },
                            Positions = new[] { 0f, 0.58f, 0.82f, 1f },
                        };
                        g.FillRectangle(br, left);
                    }
                    using (var shade = new SolidBrush(Color.FromArgb(164, 5, 9, 21)))
                        g.FillRectangle(shade, 20, 116, 410, 412);
                    using (var shade = new SolidBrush(Color.FromArgb(231, 7, 12, 27)))
                        g.FillRectangle(shade, 15, 536, Width - 30, 130);
                    using (var blue = new Pen(Color.FromArgb(126, 94, 119, 173)))
                    using (var dim = new Pen(Color.FromArgb(80, 95, 115, 163)))
                    using (var goldLine = new Pen(Color.FromArgb(175, Gold)))
                    {
                        g.DrawRectangle(blue, 15, 15, Width - 31, Height - 31);
                        g.DrawRectangle(dim, 19, 19, Width - 39, Height - 39);
                        g.DrawRectangle(dim, 20, 116, 410, 412);
                        g.DrawLine(goldLine, 46, 288, 398, 288);
                        g.DrawLine(blue, 15, 536, Width - 16, 536);
                        g.DrawLine(dim, 574, 551, 574, 651);
                        g.DrawLine(dim, 851, 551, 851, 651);
                        g.DrawLine(goldLine, 866, 633, 1134, 633);
                        // Corner strokes give the edge the feel of a game client, without covering the art.
                        g.DrawLine(goldLine, 15, 15, 74, 15);
                        g.DrawLine(goldLine, 15, 15, 15, 64);
                        g.DrawLine(goldLine, Width - 16, 15, Width - 75, 15);
                        g.DrawLine(goldLine, Width - 16, 15, Width - 16, 64);
                        g.DrawLine(goldLine, 15, Height - 16, 74, Height - 16);
                        g.DrawLine(goldLine, Width - 16, Height - 16, Width - 75, Height - 16);
                    }
                    using (var title = new Font("Georgia", 37f, FontStyle.Bold))
                    using (var kicker = new Font("Segoe UI", 8.5f, FontStyle.Bold))
                    using (var gold = new SolidBrush(Gold))
                    using (var pale = new SolidBrush(Ink))
                    {
                        g.DrawString("THE OSSUARY COVENANT", kicker, gold, 48, 38);
                        Art.DrawTitle(g, title, 40, 56);
                        g.DrawString("A WORLD OF DARK MAGIC", kicker, pale, 932, 41);
                        g.DrawString("01  /  WORLD NEWS", kicker, gold, 48, 120);
                        g.DrawString("STATUS", kicker, gold, 590, 546);
                        g.DrawString("ONLINE", kicker, gold, 866, 542);
                    }
                    using (var glow = new SolidBrush(Color.FromArgb(80, 149, 116, 255)))
                    using (var bright = new SolidBrush(Color.FromArgb(221, 193, 170, 255)))
                    {
                        g.FillEllipse(glow, 918, 37, 11, 11);
                        g.FillEllipse(bright, 921, 40, 5, 5);
                    }
                }
            }
        }

        /// <summary>Label drawn over the backdrop (transparent, double-buffered so progress updates don't flicker).</summary>
        sealed class GlassLabel : Label
        {
            public GlassLabel() { DoubleBuffered = true; BackColor = Color.Transparent; }
        }

        /// <summary>Thin owner-drawn progress bar (the stock ProgressBar ignores colours under visual styles).</summary>
        sealed class ThinBar : Control
        {
            double v;
            public ThinBar() { DoubleBuffered = true; }
            public double Value { get { return v; } set { v = Math.Max(0, Math.Min(1, value)); Invalidate(); } }
            protected override void OnPaint(PaintEventArgs e)
            {
                using (var back = new SolidBrush(Color.FromArgb(34, 26, 48))) e.Graphics.FillRectangle(back, ClientRectangle);
                using (var fill = new SolidBrush(Violet)) e.Graphics.FillRectangle(fill, 0, 0, (int)(Width * v), Height);
            }
        }
    }
}
