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
        static readonly Color Bg = Color.FromArgb(7, 6, 10);
        static readonly Color Panel = Color.FromArgb(16, 12, 22);
        static readonly Color Violet = Color.FromArgb(124, 58, 237);
        static readonly Color VioletLight = Color.FromArgb(198, 164, 255);
        static readonly Color Ink = Color.FromArgb(232, 226, 240);
        static readonly Color Muted = Color.FromArgb(138, 130, 148);

        public static Icon AppIcon { get { return Icon.ExtractAssociatedIcon(Application.ExecutablePath); } }

        readonly Settings settings = Settings.Load();
        readonly Image art;
        readonly Label status = new Label();
        readonly Label updateLabel = new Label();
        readonly ThinBar bar = new ThinBar();
        readonly Label newsTitle = new Label();
        readonly Label newsBody = new Label();
        readonly LinkLabel newsLink = new LinkLabel();
        readonly Button playBtn, downloadBtn, openBtn;
        readonly CheckBox gpu = new CheckBox();
        readonly WebView2 precacheWeb = new WebView2 { Size = new Size(1, 1), Location = new Point(0, 0) };
        GameWindow online, offline;
        string precacheSha;
        bool precaching;

        public LauncherForm()
        {
            Text = "Death Muffin Launcher";
            Icon = AppIcon;
            ClientSize = new Size(1000, 620);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Bg;
            Font = new Font("Segoe UI", 9.5f);
            using (var s = typeof(LauncherForm).Assembly.GetManifestResourceStream("covenant.jpg")) art = Image.FromStream(s);

            var left = new ArtPanel(art) { Dock = DockStyle.Left, Width = 400 };
            var right = new System.Windows.Forms.Panel { Dock = DockStyle.Fill, BackColor = Panel };
            Controls.Add(right);
            Controls.Add(left);

            int x = 40, w = 520;
            right.Controls.Add(Lbl("DEATH MUFFIN", new Font("Georgia", 26f, FontStyle.Bold), VioletLight, x, 24, w, 46));
            right.Controls.Add(Lbl("Enter the Ossuary Covenant", new Font("Segoe UI", 11f), Ink, x, 72, 380, 22));
            right.Controls.Add(Lbl("LAUNCHER " + Program.Version, new Font("Segoe UI", 8f, FontStyle.Bold), Muted, x + 380, 76, 140, 18, ContentAlignment.TopRight));

            right.Controls.Add(Lbl("ONLINE WORLD", new Font("Segoe UI", 9f, FontStyle.Bold), Violet, x, 116, w, 18));
            right.Controls.Add(Lbl("Play the current live game with your online account.", Font, Muted, x, 136, w, 20));
            playBtn = Btn("PLAY ONLINE", x, 162, 250, 44, true);
            playBtn.Click += (s, e) => OpenGame(false, false);
            right.Controls.Add(playBtn);

            updateLabel.SetBounds(x, 214, w, 18);
            updateLabel.ForeColor = Muted;
            updateLabel.Text = "Checking for updates...";
            bar.SetBounds(x, 236, w, 6);
            bar.Visible = false;
            right.Controls.Add(updateLabel);
            right.Controls.Add(bar);

            right.Controls.Add(Lbl("OFFLINE EDITION", new Font("Segoe UI", 9f, FontStyle.Bold), Violet, x, 262, w, 18));
            right.Controls.Add(Lbl("Download the game once, then play without a network.", Font, Muted, x, 282, w, 20));
            downloadBtn = Btn("DOWNLOAD OFFLINE", x, 308, 250, 38, false);
            openBtn = Btn("OPEN OFFLINE", x + 270, 308, 250, 38, false);
            downloadBtn.Click += (s, e) => OpenGame(true, true);
            openBtn.Click += (s, e) => OpenGame(true, false);
            right.Controls.Add(downloadBtn);
            right.Controls.Add(openBtn);

            right.Controls.Add(Lbl("LATEST NEWS", new Font("Segoe UI", 9f, FontStyle.Bold), Violet, x, 366, w, 18));
            newsTitle.SetBounds(x, 386, w, 20);
            newsTitle.ForeColor = Ink;
            newsTitle.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            newsTitle.Text = "Loading...";
            newsBody.SetBounds(x, 408, w, 128);
            newsBody.ForeColor = Muted;
            newsLink.SetBounds(x, 540, 200, 18);
            newsLink.Text = "View all on GitHub";
            newsLink.LinkColor = VioletLight;
            newsLink.ActiveLinkColor = Ink;
            newsLink.LinkBehavior = LinkBehavior.HoverUnderline;
            newsLink.Visible = false;
            newsLink.LinkClicked += (s, e) => System.Diagnostics.Process.Start(Updates.CommitsUrl);
            right.Controls.Add(newsTitle);
            right.Controls.Add(newsBody);
            right.Controls.Add(newsLink);

            gpu.SetBounds(x + 300, 538, 220, 22);
            gpu.Text = "Use high-performance GPU";
            gpu.ForeColor = Muted;
            gpu.Checked = settings.HighPerformanceGpu;
            gpu.CheckedChanged += (s, e) =>
            {
                settings.HighPerformanceGpu = gpu.Checked;
                settings.Save();
                if (online != null || offline != null || precaching) SetStatus("GPU setting applies the next time the launcher starts.");
            };
            right.Controls.Add(gpu);

            status.SetBounds(x, 576, w, 20);
            status.ForeColor = Muted;
            right.Controls.Add(status);
            foreach (var l in new Label[] { updateLabel, newsTitle, newsBody, status }) l.AutoEllipsis = true;
            // 1x1 control that hosts the hidden precache page (WebView2 needs a window to initialise in).
            Controls.Add(precacheWeb);

            SetStatus("Ready. The online game updates when you open it.");
            Shown += async (s, e) => await InitAsync();
        }

        static Label Lbl(string text, Font f, Color c, int x, int y, int w, int h, ContentAlignment a = ContentAlignment.TopLeft)
        {
            var l = new Label { Text = text, Font = f, ForeColor = c, BackColor = Color.Transparent, TextAlign = a };
            l.SetBounds(x, y, w, h);
            return l;
        }

        static Button Btn(string text, int x, int y, int w, int h, bool primary)
        {
            var b = new Button
            {
                Text = text,
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 10f, FontStyle.Bold),
                ForeColor = Color.White,
                BackColor = primary ? Violet : Color.FromArgb(34, 26, 48),
                Cursor = Cursors.Hand,
                UseVisualStyleBackColor = false,
            };
            b.FlatAppearance.BorderColor = primary ? VioletLight : Color.FromArgb(70, 54, 100);
            b.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(147, 90, 245) : Color.FromArgb(52, 40, 74);
            b.SetBounds(x, y, w, h);
            return b;
        }

        void SetStatus(string text) { status.Text = text; }

        async System.Threading.Tasks.Task InitAsync()
        {
            if (WebViewHost.RuntimeVersion() == null)
            {
                SetStatus("The game needs Microsoft Edge WebView2 Runtime. Download: " + Updates.WebView2Url);
                updateLabel.Text = "WebView2 Runtime not found.";
                status.ForeColor = Color.FromArgb(240, 160, 120);
                status.Cursor = Cursors.Hand;
                status.Click += (s, e) => System.Diagnostics.Process.Start(Updates.WebView2Url);
                playBtn.Enabled = downloadBtn.Enabled = openBtn.Enabled = false;
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
            newsTitle.Text = "Release " + Short(n.Sha) + (d.Length > 0 ? "  -  " + d : "");
            newsBody.Text = "• " + string.Join("\n• ", n.Items.GetRange(0, Math.Min(n.Items.Count, 6)));
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
            GameWindow existing = offlineEdition ? offline : online;
            if (existing != null && !existing.IsDisposed)
            {
                if (!install) { existing.Activate(); existing.WindowState = existing.WindowState == FormWindowState.Minimized ? FormWindowState.Normal : existing.WindowState; return; }
                existing.Close();
            }
            var w = new GameWindow(settings, offlineEdition ? Updates.OfflineUrl : Updates.PlayUrl, offlineEdition, install);
            w.OfflineStatus += t => SetStatus(t);
            w.Failed += t => SetStatus(t);
            w.FormClosed += (s, e) => { if (offlineEdition) offline = null; else online = null; };
            if (offlineEdition) offline = w; else online = w;
            SetStatus(install ? "Preparing offline download" : offlineEdition ? "Offline edition open. Download assets before disconnecting." : "Opening the Covenant");
            if (!offlineEdition) w.Shown += (s, e) => SetStatus("Online game ready.");
            w.Show();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            base.OnFormClosing(e);
            if (e.Cancel) return;
            foreach (var w in new[] { online, offline }) if (w != null && !w.IsDisposed) w.Close();
        }

        /// <summary>The painted covenant art with the title laid over its lower edge.</summary>
        sealed class ArtPanel : System.Windows.Forms.Panel
        {
            readonly Image img;
            public ArtPanel(Image img) { this.img = img; DoubleBuffered = true; BackColor = Bg; }

            protected override void OnPaint(PaintEventArgs e)
            {
                var g = e.Graphics;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
                // "cover" the panel with the art, centred.
                float s = Math.Max((float)Width / img.Width, (float)Height / img.Height);
                float dw = img.Width * s, dh = img.Height * s;
                g.DrawImage(img, (Width - dw) / 2, (Height - dh) / 2, dw, dh);
                var fade = new Rectangle(0, Height - 260, Width, 260);
                using (var br = new LinearGradientBrush(fade, Color.FromArgb(0, 7, 6, 10), Color.FromArgb(235, 7, 6, 10), 90f))
                    g.FillRectangle(br, fade);
                using (var f1 = new Font("Segoe UI", 8.5f, FontStyle.Bold))
                using (var f2 = new Font("Georgia", 40f, FontStyle.Bold))
                using (var gold = new SolidBrush(Color.FromArgb(226, 190, 120)))
                using (var white = new SolidBrush(Color.FromArgb(240, 232, 250)))
                {
                    g.DrawString("THE CINDER PYRE IS OPEN", f1, gold, 32, Height - 190);
                    g.DrawString("DEATH", f2, white, 26, Height - 168);
                    g.DrawString("MUFFIN", f2, white, 26, Height - 110);
                }
            }
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
