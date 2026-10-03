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
        static readonly Color Muted = Color.FromArgb(160, 152, 172);
        static readonly Color Gold = Color.FromArgb(226, 190, 120);

        public static Icon AppIcon { get { return Icon.ExtractAssociatedIcon(Application.ExecutablePath); } }

        readonly Settings settings = Settings.Load();
        readonly Image art;
        readonly Label status = new GlassLabel();
        readonly Label updateLabel = new GlassLabel();
        readonly ThinBar bar = new ThinBar();
        readonly Label newsTitle = new GlassLabel();
        readonly Label newsBody = new GlassLabel();
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
            // 16:9-ish so the key art fills the window with almost no crop.
            ClientSize = new Size(1100, 620);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Bg;
            Font = new Font("Segoe UI", 9.5f);
            using (var s = typeof(LauncherForm).Assembly.GetManifestResourceStream("keyart.jpg")) art = Image.FromStream(s);

            // The key art covers the whole window; the controls sit on its dark left half, the necromancer stays clear on the right.
            var root = new Backdrop(art) { Dock = DockStyle.Fill };
            Controls.Add(root);

            int x = 40, w = 420;
            root.Controls.Add(Lbl("ONLINE WORLD", new Font("Segoe UI", 9f, FontStyle.Bold), Gold, x, 124, w, 18));
            root.Controls.Add(Lbl("Play the current live game with your online account.", Font, Muted, x, 144, w, 20));
            playBtn = Btn("PLAY ONLINE", x, 170, w, 50, true);
            playBtn.Font = new Font("Segoe UI", 12f, FontStyle.Bold);
            playBtn.Click += (s, e) => OpenGame(false, false);
            root.Controls.Add(playBtn);

            updateLabel.SetBounds(x, 228, w, 18);
            updateLabel.ForeColor = Muted;
            updateLabel.Text = "Checking for updates...";
            bar.SetBounds(x, 250, w, 4);
            bar.Visible = false;
            root.Controls.Add(updateLabel);
            root.Controls.Add(bar);

            root.Controls.Add(Lbl("OFFLINE EDITION", new Font("Segoe UI", 9f, FontStyle.Bold), Gold, x, 274, w, 18));
            root.Controls.Add(Lbl("Download the game once, then play without a network.", Font, Muted, x, 294, w, 20));
            downloadBtn = Btn("DOWNLOAD OFFLINE", x, 320, 200, 38, false);
            openBtn = Btn("OPEN OFFLINE", x + 220, 320, 200, 38, false);
            downloadBtn.Click += (s, e) => OpenGame(true, true);
            openBtn.Click += (s, e) => OpenGame(true, false);
            root.Controls.Add(downloadBtn);
            root.Controls.Add(openBtn);

            root.Controls.Add(Lbl("LATEST NEWS", new Font("Segoe UI", 9f, FontStyle.Bold), Gold, x, 378, w, 18));
            newsTitle.SetBounds(x, 398, w, 20);
            newsTitle.ForeColor = Ink;
            newsTitle.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            newsTitle.Text = "Loading...";
            newsBody.SetBounds(x, 420, w, 110);
            newsBody.ForeColor = Muted;
            newsLink.SetBounds(x, 538, 200, 18);
            newsLink.Text = "View all on GitHub";
            newsLink.BackColor = Color.Transparent;
            newsLink.LinkColor = VioletLight;
            newsLink.ActiveLinkColor = Ink;
            newsLink.LinkBehavior = LinkBehavior.HoverUnderline;
            newsLink.Visible = false;
            newsLink.LinkClicked += (s, e) => System.Diagnostics.Process.Start(Updates.CommitsUrl);
            root.Controls.Add(newsTitle);
            root.Controls.Add(newsBody);
            root.Controls.Add(newsLink);

            gpu.SetBounds(x + 220, 536, 200, 22);
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

            status.SetBounds(x, 588, 760, 20);
            status.ForeColor = Muted;
            root.Controls.Add(status);
            root.Controls.Add(Lbl("LAUNCHER " + Program.Version, new Font("Segoe UI", 8f, FontStyle.Bold), Muted, 900, 590, 170, 18, ContentAlignment.TopRight));
            foreach (var l in new Label[] { updateLabel, newsTitle, newsBody, status }) { l.AutoEllipsis = true; l.BackColor = Color.Transparent; }
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

        /// <summary>
        /// Full-window key art with a dark scrim over the left half (where the controls sit) and the title painted on top.
        /// The composite is rendered once per size, so transparent labels repainting over it stay cheap.
        /// </summary>
        sealed class Backdrop : System.Windows.Forms.Panel
        {
            readonly Image img;
            Bitmap frame;
            public Backdrop(Image img) { this.img = img; DoubleBuffered = true; BackColor = Bg; }

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
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                    g.Clear(Bg);
                    // "cover" the window with the art, centred.
                    float s = Math.Max((float)Width / img.Width, (float)Height / img.Height);
                    float dw = img.Width * s, dh = img.Height * s;
                    g.DrawImage(img, (Width - dw) / 2, (Height - dh) / 2, dw, dh);

                    // Left scrim: near-opaque behind the controls, gone by the necromancer.
                    var left = new Rectangle(0, 0, 640, Height);
                    using (var br = new LinearGradientBrush(left, Color.Black, Color.Black, 0f))
                    {
                        br.InterpolationColors = new ColorBlend
                        {
                            Colors = new[] { Color.FromArgb(232, Bg), Color.FromArgb(215, Bg), Color.FromArgb(120, Bg), Color.FromArgb(0, Bg) },
                            Positions = new[] { 0f, 0.62f, 0.82f, 1f },
                        };
                        g.FillRectangle(br, left);
                    }
                    // Bottom band for the status line and version.
                    var foot = new Rectangle(0, Height - 70, Width, 70);
                    using (var br = new LinearGradientBrush(new Rectangle(foot.X, foot.Y - 1, foot.Width, foot.Height + 1), Color.FromArgb(0, Bg), Color.FromArgb(220, Bg), 90f))
                        g.FillRectangle(br, foot);

                    using (var kicker = new Font("Segoe UI", 8.5f, FontStyle.Bold))
                    using (var title = new Font("Georgia", 34f, FontStyle.Bold))
                    using (var gold = new SolidBrush(Gold))
                    using (var ink = new SolidBrush(Color.FromArgb(244, 236, 252)))
                    using (var glow = new SolidBrush(Color.FromArgb(46, 150, 80, 255)))
                    {
                        g.DrawString("ENTER THE OSSUARY COVENANT", kicker, gold, 42, 30);
                        // Soft violet glow: the title offset a few px in each direction under the real one.
                        for (int dx = -3; dx <= 3; dx += 2)
                            for (int dy = -3; dy <= 3; dy += 2)
                                g.DrawString("DEATH MUFFIN", title, glow, 34 + dx, 46 + dy);
                        g.DrawString("DEATH MUFFIN", title, ink, 34, 46);
                    }
                    // Gold hairline that fades out to the right.
                    var line = new Rectangle(40, 104, 420, 1);
                    using (var br = new LinearGradientBrush(new Rectangle(line.X - 1, line.Y, line.Width + 2, 1), Color.FromArgb(200, Gold), Color.FromArgb(0, Gold), 0f))
                        g.FillRectangle(br, line);
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
