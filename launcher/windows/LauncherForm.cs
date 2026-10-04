using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
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
        readonly CheckBox gpu = new CheckBox();
        readonly WebView2 precacheWeb = new WebView2 { Size = new Size(1, 1), Location = new Point(0, 0) };
        GameWindow online, offline;
        string precacheSha;
        bool precaching;
        string statusLink;
        /// <summary>WebView2 unavailable: Play/Offline open the game in a browser instead (see BrowserFallback).</summary>
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
            playBtn = Btn("PLAY ONLINE   ›", 866, 563, 268, 74, true);
            playBtn.Font = new Font("Georgia", 16f, FontStyle.Bold);
            playBtn.Click += (s, e) => OpenGame(false, false);
            root.Controls.Add(playBtn);

            updateLabel.SetBounds(x, 226, w, 38);
            updateLabel.ForeColor = Muted;
            updateLabel.Text = "Checking for updates...";
            bar.SetBounds(x, 267, w, 5);
            bar.Visible = false;
            root.Controls.Add(updateLabel);
            root.Controls.Add(bar);

            root.Controls.Add(Lbl("OFFLINE EDITION", new Font("Segoe UI", 8.5f, FontStyle.Bold), Gold, x, 550, w, 18));
            downloadBtn = Btn("DOWNLOAD OFFLINE", x, 582, 160, 42, false);
            openBtn = Btn("PLAY OFFLINE", x + 173, 582, 160, 42, false);
            downloadBtn.Click += (s, e) => OpenGame(true, true);
            openBtn.Click += (s, e) => OpenGame(true, false);
            root.Controls.Add(downloadBtn);
            root.Controls.Add(openBtn);
            root.Controls.Add(Lbl("Download once to play without a connection.", new Font("Segoe UI", 8.5f), Muted, x, 635, w, 24));

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
            newsLink.LinkClicked += (s, e) => System.Diagnostics.Process.Start(Updates.PatchNotesUrl);
            root.Controls.Add(newsTitle);
            root.Controls.Add(newsBody);
            root.Controls.Add(newsLink);

            gpu.SetBounds(465, 590, 200, 22);
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

            status.SetBounds(465, 624, 377, 38);
            status.ForeColor = Muted;
            root.Controls.Add(status);
            root.Controls.Add(Lbl("LAUNCHER " + Program.Version, new Font("Segoe UI", 8f, FontStyle.Bold), Muted, 995, 650, 139, 18, ContentAlignment.TopRight));
            foreach (var l in new Label[] { updateLabel, newsTitle, status }) { l.AutoEllipsis = true; l.BackColor = Color.Transparent; }
            var statusTip = new ToolTip();
            status.TextChanged += (s, e) => statusTip.SetToolTip(status, status.Text);
            status.Click += (s, e) => { if (statusLink != null) System.Diagnostics.Process.Start(statusLink); };
            // 1x1 control that hosts the hidden precache page (WebView2 needs a window to initialise in).
            Controls.Add(precacheWeb);

            SetStatus("Ready. The online game updates when you open it.");
            Shown += async (s, e) => await InitAsync();
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
            // Play stays enabled whatever the check says: without WebView2 the game opens in Chrome/Edge/Brave (or the default
            // browser) instead, so a missing or broken runtime never locks the player out.
            var rt = WebViewHost.CheckRuntime();
            if (rt.Problem != null || rt.Missing)
            {
                useBrowser = true;
                if (rt.Problem != null)
                    Warn("Launcher files are missing (unzip the whole folder to fix). Play will open in your browser for now. (" + rt.Problem + ")", null);
                else
                    Warn("WebView2 not found, so Play opens the game in your browser. Click here to install WebView2 for the game window.", Updates.WebView2Url);
                updateLabel.Text = "Playing in your browser (no update pre-download).";
                await ShowNewsAsync();
                return;
            }
            var news = ShowNewsAsync();
            string live = await Updates.FetchLiveShaAsync();
            if (live == null)
            {
                updateLabel.Text = "Could not check for updates (offline?). You can still play.";
            }
            else if (string.Equals(live, settings.LastPrecachedSha, StringComparison.OrdinalIgnoreCase))
            {
                updateLabel.Text = "Up to date (" + Short(live) + ").";
            }
            else
            {
                updateLabel.Text = "Update available (" + Short(live) + "). Preparing files...";
                updateLabel.ForeColor = VioletLight;
                await StartPrecacheAsync(live);
            }
            await news;
        }

        void Warn(string text, string link)
        {
            SetStatus(text);
            status.ForeColor = Color.FromArgb(244, 176, 128);
            statusLink = link;
            if (link != null) status.Cursor = Cursors.Hand;
        }

        static string Short(string sha) { return sha.Length > 7 ? sha.Substring(0, 7) : sha; }

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

        void OpenGame(bool offlineEdition, bool install)
        {
            string url = offlineEdition ? Updates.OfflineUrl : Updates.PlayUrl;
            if (useBrowser) { OpenInBrowser(url); return; }
            GameWindow existing = offlineEdition ? offline : online;
            if (existing != null && !existing.IsDisposed)
            {
                if (!install) { existing.Activate(); existing.WindowState = existing.WindowState == FormWindowState.Minimized ? FormWindowState.Normal : existing.WindowState; return; }
                existing.Close();
            }
            var w = new GameWindow(settings, url, offlineEdition, install);
            // WebView2 would not start after all: switch to the browser for this and every later launch this session.
            w.WebViewUnavailable += () => { useBrowser = true; OpenInBrowser(url); };
            w.OfflineStatus += t => SetStatus(t);
            w.Failed += t => SetStatus(t);
            w.FormClosed += (s, e) => { if (offlineEdition) offline = null; else online = null; };
            if (offlineEdition) offline = w; else online = w;
            SetStatus(install ? "Preparing offline download" : offlineEdition ? "Offline edition open. Download assets before disconnecting." : "Opening the Covenant");
            if (!offlineEdition) w.Shown += (s, e) => SetStatus("Online game ready.");
            w.Show();
        }

        void OpenInBrowser(string url)
        {
            string used = BrowserFallback.Open(url);
            if (used == null) Warn("Could not open a browser. Visit " + url + " to play.", url);
            else SetStatus("Opened the game in " + used + ".");
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            base.OnFormClosing(e);
            if (e.Cancel) return;
            foreach (var w in new[] { online, offline }) if (w != null && !w.IsDisposed) w.Close();
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
                        g.DrawLine(dim, 441, 551, 441, 651);
                        g.DrawLine(dim, 851, 551, 851, 651);
                        g.DrawLine(goldLine, 866, 647, 1134, 647);
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
                        g.DrawString("CLIENT SETTINGS", kicker, gold, 465, 556);
                        g.DrawString("ENTER THE REALM", kicker, gold, 866, 542);
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
