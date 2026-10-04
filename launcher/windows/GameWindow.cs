using System;
using System.Drawing;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace DeathMuffinLauncher
{
    /// <summary>A separate window hosting the game (online or offline edition) in the shared WebView2 profile.</summary>
    internal sealed class GameWindow : Form
    {
        // Relays the offline edition's download-panel status text to the launcher. Read-only: the download itself is started
        // by the page via ?download=1, so nothing here clicks buttons or depends on the wording.
        const string OfflinePanelScript = @"(function () {
    let attempts = 0;
    function findPanel() {
        const status = document.querySelector('[data-offline-status]');
        if (!status) {
            if (++attempts < 120) setTimeout(findPanel, 500);
            return;
        }
        const report = () => window.chrome.webview.postMessage('dm-status:' + status.textContent);
        new MutationObserver(report).observe(status, { childList: true, subtree: true, characterData: true });
        report();
    }
    findPanel();
})();";

        readonly WebView2 web = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(7, 6, 10) };
        readonly LoadingScreen loading = new LoadingScreen { Text = "Opening the Covenant", Dock = DockStyle.Fill };
        readonly Settings settings;
        readonly string url;
        readonly bool offline;
        string target;

        /// <summary>Raised with text from the offline edition's download panel ("dm-status:...").</summary>
        public event Action<string> OfflineStatus;
        /// <summary>Raised if the window could not start or navigate.</summary>
        public event Action<string> Failed;
        /// <summary>Raised (instead of Failed) when WebView2 itself could not start; the launcher then uses a browser. The window closes.</summary>
        public event Action WebViewUnavailable;

        public GameWindow(Settings settings, string url, bool offline)
        {
            this.settings = settings;
            this.url = url;
            this.offline = offline;
            target = url;
            Text = "Death Muffin " + (offline ? "Offline" : "Online");
            BackColor = Color.FromArgb(7, 6, 10);
            ClientSize = new Size(1280, 760);
            MinimumSize = new Size(800, 500);
            StartPosition = FormStartPosition.CenterScreen;
            Controls.Add(web);
            Controls.Add(loading);
            loading.BringToFront();
            Icon = LauncherForm.AppIcon;
            Shown += async (s, e) => await StartAsync();
        }

        async System.Threading.Tasks.Task StartAsync()
        {
            try
            {
                var env = await WebViewHost.GetEnvironmentAsync(settings);
                await web.EnsureCoreWebView2Async(env);
                var core = web.CoreWebView2;
                core.Settings.AreDevToolsEnabled = false;
                core.Settings.IsStatusBarEnabled = false;
                core.Settings.AreDefaultContextMenusEnabled = false;
                // Links that leave the game open in the real browser instead of replacing the game.
                core.NewWindowRequested += (s, e) => { e.Handled = true; OpenExternal(e.Uri); };
                core.NavigationStarting += (s, e) =>
                {
                    Uri u;
                    if (Uri.TryCreate(e.Uri, UriKind.Absolute, out u) && u.Host != "muffindevelopment.com" && u.Scheme != "about" && u.Scheme != "data" && u.Scheme != "blob")
                    {
                        e.Cancel = true;
                        OpenExternal(e.Uri);
                    }
                };
                core.WebMessageReceived += (s, e) =>
                {
                    string m = e.TryGetWebMessageAsString();
                    if (m != null && m.StartsWith("dm-status:", StringComparison.Ordinal) && OfflineStatus != null)
                        OfflineStatus(m.Substring("dm-status:".Length).Trim());
                };
                core.NavigationCompleted += (s, e) =>
                {
                    if (!e.IsSuccess)
                    {
                        if (Failed != null) Failed(offline
                            ? "Offline game unavailable. If it is not downloaded yet, connect once and press Download for offline."
                            : "Online game unavailable. Check your connection.");
                        loading.Text = "Online game unavailable. Check your connection.";
                        if (offline) loading.Text = "Offline game unavailable. Connect once and download it first.";
                        loading.Failed = true;
                        loading.Visible = true;
                        return;
                    }
                    loading.Visible = false;
                    if (offline) core.ExecuteScriptAsync(OfflinePanelScript);
                };
                core.Navigate(target);
            }
            catch (Exception ex)
            {
                if (WebViewUnavailable != null) WebViewUnavailable();
                else if (Failed != null) Failed("Game window could not start. " + ex.Message);
                Close();
            }
        }

        static void OpenExternal(string uri)
        {
            Uri u;
            if (Uri.TryCreate(uri, UriKind.Absolute, out u) && (u.Scheme == Uri.UriSchemeHttps || u.Scheme == Uri.UriSchemeHttp))
                System.Diagnostics.Process.Start(u.ToString());
        }

        /// <summary>Navigate the open window (Download pressed while the offline window is already open). Safe before WebView2 has started.</summary>
        public void NavigateTo(string newUrl)
        {
            target = newUrl;
            if (web.CoreWebView2 == null) return; // StartAsync will use the new target
            loading.Failed = false;
            loading.Visible = true;
            web.CoreWebView2.Navigate(newUrl);
        }
    }

    /// <summary>
    /// Shown over the game window until the page has loaded: the key art with the title and status near the bottom and a thin
    /// sliding bar. The art + scrim + title are composed once per size; only the bar animates.
    /// </summary>
    internal sealed class LoadingScreen : Control
    {
        readonly Timer tick = new Timer { Interval = 33 };
        Bitmap frame;
        float phase;
        bool failed;

        public LoadingScreen()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = Art.Bg;
            tick.Tick += (s, e) => { phase = (phase + 0.012f) % 1f; Invalidate(BarRect()); };
        }

        /// <summary>Error state: the bar stops and the status turns warm orange.</summary>
        public bool Failed { get { return failed; } set { failed = value; Invalidate(); SyncTimer(); } }

        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
        protected override void OnVisibleChanged(EventArgs e) { SyncTimer(); base.OnVisibleChanged(e); }
        protected override void OnHandleCreated(EventArgs e) { SyncTimer(); base.OnHandleCreated(e); }
        void SyncTimer() { tick.Enabled = Visible && IsHandleCreated && !failed; }

        protected override void Dispose(bool disposing)
        {
            if (disposing) { tick.Dispose(); if (frame != null) frame.Dispose(); }
            base.Dispose(disposing);
        }

        Rectangle BarRect() { return new Rectangle(Width / 2 - 160, Height - 74, 320, 3); }

        void Compose()
        {
            if (frame != null) frame.Dispose();
            frame = new Bitmap(Width, Height);
            using (var g = Graphics.FromImage(frame))
            {
                Art.Quality(g);
                g.Clear(Art.Bg);
                Art.DrawCover(g, ClientSize);
                // Darken the lower third so the title and status read over the graveyard.
                var band = new Rectangle(0, Height * 55 / 100, Width, Height - Height * 55 / 100);
                using (var br = new System.Drawing.Drawing2D.LinearGradientBrush(new Rectangle(band.X, band.Y - 1, band.Width, band.Height + 1), Color.FromArgb(0, Art.Bg), Color.FromArgb(235, Art.Bg), 90f))
                    g.FillRectangle(br, band);
                using (var title = new Font("Georgia", 38f, FontStyle.Bold))
                using (var center = new StringFormat { Alignment = StringAlignment.Center })
                    Art.DrawTitle(g, title, Width / 2f, Height - 178, center);
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (Width <= 0 || Height <= 0) return;
            if (frame == null || frame.Size != ClientSize) Compose();
            var g = e.Graphics;
            g.DrawImageUnscaled(frame, 0, 0);
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using (var f = new Font("Segoe UI", 11f, FontStyle.Bold))
            using (var b = new SolidBrush(failed ? Color.FromArgb(244, 176, 128) : Art.Gold))
            using (var center = new StringFormat { Alignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter })
                g.DrawString(Text.ToUpperInvariant(), f, b, new RectangleF(20, Height - 106, Width - 40, 24), center);
            if (failed) return;
            var bar = BarRect();
            using (var back = new SolidBrush(Color.FromArgb(44, 34, 62))) g.FillRectangle(back, bar);
            // A violet highlight sliding across the track (indeterminate: the page gives no progress until it has loaded).
            int seg = 90, x = bar.X - seg + (int)((bar.Width + seg) * phase);
            var hl = Rectangle.Intersect(bar, new Rectangle(x, bar.Y, seg, bar.Height));
            if (hl.Width > 0) using (var fill = new SolidBrush(Art.VioletLight)) g.FillRectangle(fill, hl);
        }
    }
}
