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
        // Finds the offline edition's download panel, relays its status text to the launcher, and (when INSTALL) clicks Download.
        const string OfflinePanelScript = @"(function () {
    const INSTALL = __INSTALL__;
    let attempts = 0;
    function findPanel() {
        const status = document.querySelector('[data-offline-status]');
        const button = document.querySelector('[data-offline-download]');
        if (!status || !button) {
            if (++attempts < 120) setTimeout(findPanel, 500);
            return;
        }
        const report = () => window.chrome.webview.postMessage('dm-status:' + status.textContent);
        new MutationObserver(report).observe(status, { childList: true, subtree: true, characterData: true });
        report();
        if (!INSTALL) return;
        let waits = 0;
        function start() {
            if (button.hidden) return;
            if (!status.textContent.includes('Download the game assets') || button.disabled) {
                if (++waits < 120) setTimeout(start, 500);
                return;
            }
            button.click();
        }
        start();
    }
    findPanel();
})();";

        readonly WebView2 web = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(7, 6, 10) };
        readonly Label loading = new Label
        {
            Text = "Loading Death Muffin",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleCenter,
            ForeColor = Color.FromArgb(198, 164, 255),
            BackColor = Color.FromArgb(7, 6, 10),
            Font = new Font("Georgia", 18f),
        };
        readonly Settings settings;
        readonly string url;
        readonly bool offline;
        readonly bool install;

        /// <summary>Raised with text from the offline edition's download panel ("dm-status:...").</summary>
        public event Action<string> OfflineStatus;
        /// <summary>Raised if the window could not start or navigate.</summary>
        public event Action<string> Failed;

        public GameWindow(Settings settings, string url, bool offline, bool install)
        {
            this.settings = settings;
            this.url = url;
            this.offline = offline;
            this.install = install;
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
                            ? "Offline game unavailable. Connect once and download the offline edition."
                            : "Online game unavailable. Check your connection.");
                        loading.Text = "Online game unavailable. Check your connection.";
                        if (offline) loading.Text = "Offline game unavailable. Connect once and download the offline edition.";
                        loading.Visible = true;
                        return;
                    }
                    loading.Visible = false;
                    if (offline)
                        core.ExecuteScriptAsync(OfflinePanelScript.Replace("__INSTALL__", install ? "true" : "false"));
                };
                core.Navigate(url);
            }
            catch (Exception ex)
            {
                if (Failed != null) Failed("Game window could not start. " + ex.Message);
                Close();
            }
        }

        static void OpenExternal(string uri)
        {
            Uri u;
            if (Uri.TryCreate(uri, UriKind.Absolute, out u) && (u.Scheme == Uri.UriSchemeHttps || u.Scheme == Uri.UriSchemeHttp))
                System.Diagnostics.Process.Start(u.ToString());
        }

        /// <summary>Navigate again (used when Download/Open Offline is pressed while the window is already open).</summary>
        public void Reload() { if (web.CoreWebView2 != null) web.CoreWebView2.Reload(); }
    }
}
