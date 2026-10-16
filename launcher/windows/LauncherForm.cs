using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Net.NetworkInformation;
using System.Reflection;

using System.Windows.Forms;

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
        readonly StatusLine status = new StatusLine();
        readonly Label updateLabel = new GlassLabel();
        readonly Label newsTitle = new GlassLabel();
        // Scrollable so a whole release's notes fit (the old label showed six lines and cut the rest).
        readonly TextBox newsBody = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, TabStop = false, WordWrap = true };
        readonly LinkLabel newsLink = new LinkLabel();
        readonly RuneButton playBtn;
        readonly LinkLabel launcherLink = new LinkLabel();
        readonly LinkLabel playInstalledLink = new LinkLabel();
        readonly ThinBar dlBar = new ThinBar();
        readonly Timer netTimer = new Timer { Interval = 60000 };
        readonly LinkLabel settingsLink = new LinkLabel();
        readonly ContextMenuStrip settingsMenu = new ContextMenuStrip { ShowImageMargin = false, ShowCheckMargin = true };
        readonly ToolStripMenuItem gpuItem = new ToolStripMenuItem("Use high-performance GPU") { CheckOnClick = true };
        /// <summary>Team only (DECISIONS B38): hidden unless Settings is Ctrl+clicked, or the test build is already on so it can be turned off.</summary>
        readonly ToolStripMenuItem testItem = new ToolStripMenuItem("Test build (team only)") { CheckOnClick = true };
        /// <summary>Small footer marker, shown only while the test channel is active.</summary>
        readonly Label channelMarker = new GlassLabel();
        readonly Label dispatchHeading = new GlassLabel();
        /// <summary>A one-off message ("Game closed.") holds the footer status until this tick count, then the state's status returns.</summary>
        int flashUntil;
        readonly Timer flashTimer = new Timer { Interval = 6000 };
        readonly ToolTip tip = new ToolTip { ShowAlways = true };
        PatchNotesWindow patchWin;
        static readonly Color Orange = Color.FromArgb(244, 176, 128);
        static readonly Color Good = Color.FromArgb(150, 214, 160);
        static readonly Color PanelFill = Color.FromArgb(13, 15, 27);

        // ---- Layout (client area 1180 x 680, frame inset 15). ----
        const int PanelX = 20, PanelW = 410, PanelTop = 122, PanelBottom = 566;
        const int HeadGap = 8, SectionGap = 24;
        const int FooterTop = 584, FooterMid = 622;
        const int PlayW = 300, PlayH = 44, PlayX = 1180 - 15 - 24 - PlayW;
        // Footer status: it moves right by MarkerW to make room for the TEST BUILD marker.
        const int StatusX = 180, StatusW = PlayX - 180 - 130, MarkerW = 100;
        static int DividerY;

        // ---- Client state. Everything the play button shows is computed from these by PlayStateMachine / OnlineGate. ----
        /// <summary>The build line in use (settings.TestBuild): its install folder, manifest and notes. Changes only through SwitchChannelAsync.</summary>
        ClientChannel channel;
        /// <summary>The verified installed Godot client of the current channel, or null.</summary>
        InstalledClient installed;
        /// <summary>The current channel's manifest from the server, or null if it could not be read (the play button then shows the default online note).</summary>
        ClientManifest live;
        /// <summary>The server answered the last check. Starts true so nothing flashes "no internet" before the first check.</summary>
        bool reachable = true, checkedOnce, rechecking, recheckQueued;
        /// <summary>Self-update state (CheckLauncherAsync): one attempt at a time, and failures this session.</summary>
        bool selfUpdating;
        int selfUpdateFailures;
        static readonly string ExePath = Application.ExecutablePath;
        bool installing, installFailed;
        double installProgress = -1;
        string installError;
        System.Threading.CancellationTokenSource installCts;
        Process gameProc;
        bool running;
        string statusLink;

        public LauncherForm()
        {
            channel = settings.Channel;
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

            // Left reading panel (key art stays clear on the right): one heading style, one body size, even spacing.
            var heading = new Font("Segoe UI", 9f, FontStyle.Bold);
            var body = new Font("Segoe UI", 10f);
            int x = PanelX + 24, w = PanelW - 48, y = PanelTop + 20;
            root.Controls.Add(Lbl("REALM UPDATE", heading, Gold, x, y, w, 18));
            y += 18 + HeadGap;
            root.Controls.Add(Lbl("Your journey continues in the Ossuary Covenant.", body, Ink, x, y, w, 22));
            y += 24;
            updateLabel.SetBounds(x, y, w, 22);
            updateLabel.Font = body;
            updateLabel.ForeColor = Muted;
            updateLabel.Text = "Checking for updates...";
            root.Controls.Add(updateLabel);
            y += 24;
            // Shown only when a newer launcher exists but this folder cannot be updated in place (SelfUpdate.cs): it opens the zip in the browser.
            launcherLink.SetBounds(x, y, w, 18);
            StyleLink(launcherLink, new Font("Segoe UI", 9f));
            launcherLink.AutoEllipsis = true;
            launcherLink.Visible = false;
            launcherLink.LinkClicked += (s, e) => OpenExternalPage(Updates.LauncherDownloadUrl);
            root.Controls.Add(launcherLink);
            y += 18 + SectionGap;
            DividerY = y - SectionGap / 2;

            dispatchHeading.Text = "WORLD DISPATCH";
            dispatchHeading.Font = heading;
            dispatchHeading.ForeColor = Gold;
            dispatchHeading.SetBounds(x, y, w, 18);
            root.Controls.Add(dispatchHeading);
            y += 18 + HeadGap;
            // Two lines for the headline: long release titles wrap instead of being cut off.
            newsTitle.SetBounds(x, y, w, 46);
            newsTitle.ForeColor = Ink;
            newsTitle.Font = new Font("Georgia", 13f, FontStyle.Bold);
            newsTitle.Text = "Loading...";
            y += 46 + HeadGap;
            int linkY = PanelBottom - 16 - 20;
            newsBody.SetBounds(x, y, w, linkY - 8 - y);
            newsBody.ForeColor = Muted;
            newsBody.BackColor = PanelFill;
            newsBody.Font = body;
            newsLink.SetBounds(x, linkY, 200, 20);
            newsLink.Text = "All patch notes";
            StyleLink(newsLink, body);
            newsLink.Visible = false;
            // Opens inside the launcher (reads play/patch-notes.json), not the browser.
            newsLink.LinkClicked += (s, e) => ShowPatchNotes();
            root.Controls.Add(newsTitle);
            root.Controls.Add(newsBody);
            root.Controls.Add(newsLink);

            // Footer: version, status, Settings and the play button on one line; the button never moves.
            var small = new Font("Segoe UI", 9f);
            int line = FooterMid - 10;
            root.Controls.Add(Lbl("LAUNCHER " + Program.Version, new Font("Segoe UI", 9f, FontStyle.Bold), Muted, 44, line, 130, 20, ContentAlignment.MiddleLeft));
            channelMarker.Text = Channels.TestMarker;
            channelMarker.Font = new Font("Segoe UI", 9f, FontStyle.Bold);
            channelMarker.ForeColor = Orange;
            channelMarker.TextAlign = ContentAlignment.MiddleLeft;
            channelMarker.SetBounds(StatusX, line, MarkerW, 20);
            channelMarker.Visible = false;
            root.Controls.Add(channelMarker);
            status.SetBounds(StatusX, line, StatusW, 20);
            status.Font = small;
            root.Controls.Add(status);
            status.Changed += () => tip.SetToolTip(status, status.Detail.Length > 0 ? status.Detail : status.Text);

            settingsLink.SetBounds(PlayX - 110, line, 92, 20);
            settingsLink.Text = "\u2699 Settings";
            settingsLink.TextAlign = ContentAlignment.MiddleRight;
            StyleLink(settingsLink, small);
            settingsLink.LinkColor = Muted;
            settingsLink.LinkClicked += (s, e) =>
            {
                // The test build switch is for the team: a plain click never shows it (unless it is already on).
                testItem.Visible = Channels.ShowTestSwitch(settings.TestBuild, (ModifierKeys & Keys.Control) == Keys.Control);
                bool busy = running || installing;
                testItem.Enabled = !busy;
                testItem.ToolTipText = busy ? "Close the game and wait for downloads to finish before switching." : "Plays the rebuild's test build (installed next to the normal game, which is left alone).";
                settingsMenu.Show(settingsLink, new Point(0, -settingsMenu.PreferredSize.Height));
            };
            root.Controls.Add(settingsLink);
            gpuItem.Checked = settings.HighPerformanceGpu;
            gpuItem.ToolTipText = "Asks Windows to run the game on your dedicated graphics card.";
            gpuItem.CheckedChanged += (s, e) =>
            {
                settings.HighPerformanceGpu = gpuItem.Checked;
                settings.Save();
                if (Alive(gameProc)) Flash("GPU setting applies the next time the game starts.", StatusLevel.Busy);
            };
            settingsMenu.Items.Add(gpuItem);
            testItem.Checked = settings.TestBuild;
            testItem.Visible = false;
            testItem.CheckedChanged += async (s, e) => await SwitchChannelAsync(testItem.Checked);
            settingsMenu.Items.Add(testItem);
            settingsMenu.Renderer = new ToolStripProfessionalRenderer(new MenuColors());
            settingsMenu.ForeColor = Ink;
            settingsMenu.Font = small;

            // The one play button: Download / Update / Play / Game running (see PlayStateMachine). The game is online-only.
            playBtn = Btn("DOWNLOAD GAME", PlayX, FooterMid - PlayH / 2, PlayW, PlayH, true);
            playBtn.Click += (s, e) => OnPlayClick();
            root.Controls.Add(playBtn);
            playInstalledLink.SetBounds(PlayX, FooterMid + PlayH / 2 + 2, PlayW, 16);
            StyleLink(playInstalledLink, new Font("Segoe UI", 8.5f));
            playInstalledLink.TextAlign = ContentAlignment.TopCenter;
            playInstalledLink.Text = "Play the installed version instead";
            playInstalledLink.Visible = false;
            playInstalledLink.LinkClicked += (s, e) => LaunchGame();
            root.Controls.Add(playInstalledLink);
            dlBar.SetBounds(PlayX, FooterMid + PlayH / 2 + 4, PlayW, 4);
            dlBar.Visible = false;
            root.Controls.Add(dlBar);
            foreach (var l in new Label[] { updateLabel, newsTitle }) { l.AutoEllipsis = true; l.BackColor = Color.Transparent; }
            status.Click += (s, e) => { if (statusLink != null) OpenExternalPage(statusLink); };
            flashTimer.Tick += (s, e) => { flashTimer.Stop(); flashUntil = 0; ApplyUi(); };

            installed = ClientStore.ReadInstalled(Settings.InstallDir(channel));
            ApplyChannelChrome();
            // The check runs once a minute so a dev publishing a build or opening Online shows up without restarting the launcher.
            netTimer.Tick += async (s, e) => await RecheckAsync();
            netTimer.Enabled = true;
            NetworkChange.NetworkAvailabilityChanged += OnNetworkChanged;
            ApplyUi();
            Shown += async (s, e) => await InitAsync();
        }

        static void StyleLink(LinkLabel l, Font f)
        {
            l.Font = f;
            l.BackColor = Color.Transparent;
            l.LinkColor = Gold;
            l.ActiveLinkColor = Ink;
            l.LinkBehavior = LinkBehavior.HoverUnderline;
        }

        void OnNetworkChanged(object sender, NetworkAvailabilityEventArgs e)
        {
            // Raised on a thread-pool thread. Either way the real answer is a request to the live site.
            try { if (IsHandleCreated && !IsDisposed) BeginInvoke(new Action(async () => await RecheckAsync())); } catch { }
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

        /// <summary>Shows a one-off message in the footer status for a few seconds, then the state's own status returns.</summary>
        void Flash(string text, StatusLevel level, string link = null)
        {
            statusLink = link;
            status.Cursor = link != null ? Cursors.Hand : Cursors.Default;
            status.Set(text, level, "");
            flashUntil = Environment.TickCount + flashTimer.Interval;
            flashTimer.Stop();
            flashTimer.Start();
        }

        void SetStatus(string text) { Flash(text, StatusLevel.Ok); }

        void Warn(string text, string link) { Flash(text, StatusLevel.Warn, link); }

        async System.Threading.Tasks.Task InitAsync()
        {
            var news = ShowNewsAsync();
            await RecheckAsync();
            await news;
        }

        /// <summary>Everything that differs between the channels besides the data: window title, footer marker, news heading.</summary>
        void ApplyChannelChrome()
        {
            bool test = channel == ClientChannel.Test;
            Text = "Death Muffin Launcher" + (test ? " - " + Channels.TestMarker : "");
            channelMarker.Visible = test;
            status.Left = test ? StatusX + MarkerW : StatusX;
            status.Width = test ? StatusW - MarkerW : StatusW;
            dispatchHeading.Text = test ? "TEST BUILD DISPATCH" : "WORLD DISPATCH";
        }

        /// <summary>
        /// Turns the test channel on or off (the Settings checkbox). Each channel keeps its own install folder, manifest and notes, so nothing is
        /// copied, moved or deleted: this only changes which one the button, status and Play use. Not while the game runs or a download is going.
        /// </summary>
        async System.Threading.Tasks.Task SwitchChannelAsync(bool test)
        {
            var next = Channels.Of(test);
            if (next == channel) return;
            if (running || installing)
            {
                testItem.Checked = channel == ClientChannel.Test;   // refuse: put the checkbox back (this re-enters with next == channel)
                return;
            }
            settings.TestBuild = test;
            settings.Save();
            channel = next;
            installed = ClientStore.ReadInstalled(Settings.InstallDir(channel));
            live = null; reachable = true; checkedOnce = false;
            installFailed = false; installError = null;
            flashTimer.Stop(); flashUntil = 0; statusLink = null;
            newsTitle.Text = "Loading...";
            newsBody.Text = "";
            newsLink.Visible = false;
            if (Alive2(patchWin)) patchWin.Close();   // it shows the other channel's notes
            ApplyChannelChrome();
            ApplyUi();
            if (rechecking) recheckQueued = true;
            await InitAsync();
        }

        /// <summary>One check at a time. A channel switch during a check queues one more for the new channel.</summary>
        async System.Threading.Tasks.Task RecheckAsync()
        {
            if (rechecking || IsDisposed) return;
            rechecking = true;
            try
            {
                do
                {
                    recheckQueued = false;
                    await RecheckOnceAsync();
                }
                while (recheckQueued && !IsDisposed);
            }
            finally { rechecking = false; }
        }

        /// <summary>Asks the server for the manifest: the internet check, the game update check, the online lock and the launcher self-check in one request.</summary>
        async System.Threading.Tasks.Task RecheckOnceAsync()
        {
            var asked = channel;
            var r = await Updates.FetchManifestAsync(asked);
            if (asked != channel) return;   // switched channel while asking: this answer is for the other one (the queued check asks again)
            bool was = reachable, first = !checkedOnce;
            checkedOnce = true;
            reachable = r.Reachable;
            live = r.Manifest;   // null on any failure: Online stays locked
            ApplyUi();
            if (!first && r.Reachable != was)
            {
                if (r.Reachable) SetStatus("Back online.");
                else if (installed != null) Warn("No internet connection. The game needs it to sign in.", null);
                else Warn("No internet connection. Connect to download the game.", null);
            }
            if (r.Reachable) await CheckLauncherAsync();
        }

        /// <summary>
        /// The launcher's self-update, on every check (SelfUpdate.cs): a newer launcher is downloaded and swapped in, then the new one starts and
        /// this one closes. Never while the game runs or downloads (it waits for a later check); a folder it cannot write, or three failures,
        /// show the download link instead.
        /// </summary>
        async System.Threading.Tasks.Task CheckLauncherAsync()
        {
            if (selfUpdating) return;
            selfUpdating = true;
            try
            {
                var m = await Updates.FetchLauncherManifestAsync();
                bool newer = m != null && VersionCompare.Compare(m.Version, Program.Version) > 0;
                var act = SelfUpdate.Decide(m, Program.Version, running, installing, newer && SelfUpdate.FolderWritable(ExePath), selfUpdateFailures);
                launcherLink.Visible = act == SelfUpdateAction.LinkOnly;
                if (act == SelfUpdateAction.LinkOnly)
                {
                    launcherLink.Text = "Launcher " + m.Version + " available: click to download (opens your browser).";
                    launcherLink.Links.Clear();
                    launcherLink.Links.Add(0, launcherLink.Text.Length);
                }
                if (act != SelfUpdateAction.Apply) return;
                Flash("Updating the launcher to " + m.Version + "...", StatusLevel.Busy);
                try
                {
                    using (var http = Updates.CreateDownloadClient())
                        await SelfUpdate.DownloadAsync(http, m, ExePath, System.Threading.CancellationToken.None);
                    if (running || installing || IsDisposed) return;   // started meanwhile: the next check downloads it again and swaps
                    SelfUpdate.Swap(ExePath);
                    Process.Start(new ProcessStartInfo(ExePath) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(ExePath) });
                    Close();
                }
                catch (Exception ex)
                {
                    selfUpdateFailures++;
                    Warn("Launcher update failed (" + ex.Message + "). It will try again.", null);
                }
            }
            finally { selfUpdating = false; }
        }

        static string Short(string v) { return PlayStateMachine.ShortVersion(v); }

        /// <summary>
        /// Paints the play button, its caption and note from one place so the states cannot disagree.
        /// All decisions live in ClientLogic.cs (unit-tested); this only copies the result onto controls.
        /// </summary>
        void ApplyUi()
        {
            string installedVer = installed != null ? installed.Version : null;

            var ui = PlayStateMachine.Compute(new PlayInputs
            {
                InstalledVersion = installedVer, Live = live, NetReachable = reachable, Running = running,
                Downloading = installing, Progress = installProgress, Failed = installFailed, Error = installError, Channel = channel,
            });
            bool test = channel == ClientChannel.Test;
            if (!checkedOnce && installed == null && !installing)
            {
                ui.Text = test ? "CHECKING FOR THE TEST BUILD..." : "CHECKING FOR THE GAME...";
                ui.Enabled = false;
                ui.Action = PlayAction.None;
                ui.Note = "";
                ui.Status = test ? "Checking for the test build..." : "Checking for the game...";
                ui.Level = StatusLevel.Busy;
            }
            playBtn.Text = ui.Text;
            playBtn.Enabled = ui.Enabled;
            if (flashUntil == 0 || Environment.TickCount - flashUntil >= 0)
            {
                flashUntil = 0;
                statusLink = null;
                status.Cursor = Cursors.Default;
                status.Set(ui.Status, ui.Level, ui.FullNote);
            }
            playInstalledLink.Visible = ui.ShowPlayInstalledLink && !running;
            dlBar.Visible = ui.ShowBar;
            if (ui.ShowBar) dlBar.Value = ui.Bar;
            playBtn.AccessibleDescription = ui.FullNote;
            playAction = ui.Action;

            if (!checkedOnce) { }
            else if (!reachable) { updateLabel.Text = "No internet connection. Updates can't be checked."; updateLabel.ForeColor = Muted; }
            else if (live == null) { updateLabel.Text = test ? "No test build is published yet." : "No game build is published yet."; updateLabel.ForeColor = Muted; }
            else if (installed == null) { updateLabel.Text = (test ? "Test build " : "Build ") + Short(live.Version) + " ready to download."; updateLabel.ForeColor = VioletLight; }
            else if (VersionCompare.Compare(live.Version, installed.Version) > 0) { updateLabel.Text = "Update available: " + (test ? "test build " : "build ") + Short(live.Version) + "."; updateLabel.ForeColor = VioletLight; }
            else { updateLabel.Text = "Up to date: " + (test ? "test build " : "build ") + Short(installed.Version) + "."; updateLabel.ForeColor = Muted; }
            tip.SetToolTip(updateLabel, installed != null && live != null && VersionCompare.Compare(live.Version, installed.Version) > 0 ? "Installed: build " + Short(installed.Version) : null);
        }

        PlayAction playAction = PlayAction.None;

        void OnPlayClick()
        {
            switch (playAction)
            {
                case PlayAction.Download:
                case PlayAction.Update:
                    var _ = InstallAsync();
                    break;
                case PlayAction.Play:
                    LaunchGame();
                    break;
            }
        }

        static bool Alive(Process p)
        {
            try { return p != null && !p.HasExited; } catch (Exception) { return false; }
        }

        async System.Threading.Tasks.Task ShowNewsAsync()
        {
            var asked = channel;
            var n = await Updates.FetchNotesAsync(asked);
            if (asked != channel) return;   // switched channel meanwhile: the new channel's own news request fills the panel
            if (n == null || n.Items.Count == 0)
            {
                newsTitle.Text = asked == ClientChannel.Test ? "No test build notes yet." : "No release notes available.";
                return;
            }
            string d = Updates.FriendlyDate(n.Date);
            string name = n.Title.Length > 0 ? n.Title : "Release " + (n.Sha.Length > 7 ? n.Sha.Substring(0, 7) : n.Sha);
            newsTitle.Text = name + (d.Length > 0 ? "  -  " + d : "");
            // TextBox lines need CRLF; a blank line between items keeps long notes readable.
            newsBody.Text = "• " + string.Join("\r\n\r\n• ", n.Items);
            newsBody.SelectionStart = 0;
            newsLink.Visible = true;
        }

        /// <summary>Downloads the current channel's manifest files with a progress bar, verifies every SHA-256 and swaps the new version in (into that channel's own folder).</summary>
        async System.Threading.Tasks.Task InstallAsync()
        {
            var manifest = live;
            if (manifest == null || installing) return;
            string dir = Settings.InstallDir(channel);
            installing = true; installFailed = false; installError = null; installProgress = 0;
            installCts = new System.Threading.CancellationTokenSource();
            ApplyUi();
            SetStatus("Downloading the " + (channel == ClientChannel.Test ? "test build" : "game") + " (" + PlayStateMachine.Mb(manifest.TotalBytes) + ").");
            var progress = new Progress<InstallProgress>(p =>
            {
                installProgress = p.Fraction;
                var ui = PlayStateMachine.Compute(new PlayInputs { InstalledVersion = installed != null ? installed.Version : null, Live = manifest, Downloading = true, Progress = p.Fraction, Channel = channel });
                playBtn.Text = ui.Text;
                dlBar.Visible = true;
                dlBar.Value = p.Fraction;
            });
            try
            {
                using (var http = Updates.CreateDownloadClient())
                    await new ClientInstaller(http, dir).InstallAsync(manifest, installed, progress, installCts.Token);
                installed = ClientStore.ReadInstalled(dir);
                if (installed == null) throw new IOException("The downloaded files did not pass the final check.");
                SetStatus(channel == ClientChannel.Test ? "Test build downloaded. Press Play." : "Game downloaded. Press Play.");
            }
            catch (OperationCanceledException)
            {
                installFailed = true; installError = "Download cancelled. Downloaded parts are kept.";
            }
            catch (Exception ex)
            {
                installFailed = true;
                installError = "The download failed (" + ex.Message + "). Press Retry; finished files are kept.";
                Warn("Download failed. Check your connection and retry.", null);
            }
            finally
            {
                installing = false;
                installProgress = -1;
                if (installCts != null) installCts.Dispose();
                installCts = null;
            }
            ApplyUi();
        }

        /// <summary>
        /// Starts the Godot client with <c>-- --online</c> (the game is online-only and ignores the flag; it is passed to be explicit).
        /// Never refused because of the online lock: the game checks access at sign-in and shows its own message. Never passes a dev-only flag.
        /// </summary>
        void LaunchGame()
        {
            if (installed == null || !File.Exists(installed.ExePath))
            {
                installed = ClientStore.ReadInstalled(Settings.InstallDir(channel));
                ApplyUi();
                if (installed == null) { Warn(channel == ClientChannel.Test ? "The test build files are missing. Download them first." : "The game files are missing. Download them first.", null); return; }
            }
            if (Alive(gameProc)) { SetStatus("Game is already running."); return; }
            ApplyGpuPreference(installed.ExePath);
            try
            {
                // Everything after "--" is a user argument for the game: read it with OS.get_cmdline_user_args().
                var psi = new ProcessStartInfo(installed.ExePath, "-- --online")
                {
                    WorkingDirectory = installed.Dir, UseShellExecute = false,
                };
                var p = Process.Start(psi);
                p.EnableRaisingEvents = true;
                p.Exited += (s, e) => { try { BeginInvoke(new Action(() => OnGameExited(p))); } catch (Exception) { } };
                gameProc = p;
                running = true;
            }
            catch (Exception ex)
            {
                Warn("The game could not start: " + ex.Message, null);
            }
            ApplyUi();
        }

        void OnGameExited(Process p)
        {
            if (!ReferenceEquals(gameProc, p)) return;
            gameProc = null;
            running = false;
            SetStatus("Game closed.");
            ApplyUi();
        }

        /// <summary>
        /// Windows decides which GPU a game uses per executable (Settings > Graphics). The checkbox writes (or removes) that preference for
        /// the installed DeathMuffin.exe: "GpuPreference=2" is High performance.
        /// </summary>
        void ApplyGpuPreference(string exePath)
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\DirectX\UserGpuPreferences"))
                {
                    if (k == null) return;
                    if (settings.HighPerformanceGpu) k.SetValue(exePath, "GpuPreference=2;");
                    else if (k.GetValue(exePath) != null) k.DeleteValue(exePath, false);
                }
            }
            catch (Exception) { /* a preference, never a reason not to play */ }
        }

        void ShowPatchNotes()
        {
            if (Alive2(patchWin)) { patchWin.Activate(); return; }
            patchWin = new PatchNotesWindow(channel);
            patchWin.FormClosed += (s, e) => patchWin = null;
            patchWin.Show(this);
        }

        static bool Alive2(Form f) { return f != null && !f.IsDisposed; }

        /// <summary>The only browser launch: the newer launcher zip, for a folder the launcher cannot update in place.</summary>
        static void OpenExternalPage(string url)
        {
            try { Process.Start(url); } catch { }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            base.OnFormClosing(e);
            if (e.Cancel) return;
            NetworkChange.NetworkAvailabilityChanged -= OnNetworkChanged;
            netTimer.Stop();
            flashTimer.Stop();
            if (installCts != null) try { installCts.Cancel(); } catch (Exception) { }   // partial files stay for the next resume
            if (Alive2(patchWin)) patchWin.Close();
            // The game keeps running if the launcher is closed; it is a separate program now.
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

                    // A soft fade on the dark side of the art, then a subtle backing for the reading panel.
                    var left = new Rectangle(0, 0, 650, Height);
                    using (var br = new LinearGradientBrush(left, Color.Black, Color.Black, 0f))
                    {
                        br.InterpolationColors = new ColorBlend
                        {
                            Colors = new[] { Color.FromArgb(190, 7, 11, 24), Color.FromArgb(150, 8, 11, 25), Color.FromArgb(60, 8, 11, 25), Color.FromArgb(0, 8, 11, 25) },
                            Positions = new[] { 0f, 0.58f, 0.82f, 1f },
                        };
                        g.FillRectangle(br, left);
                    }
                    using (var shade = new SolidBrush(Color.FromArgb(150, PanelFill)))
                        g.FillRectangle(shade, PanelX, PanelTop, PanelW, PanelBottom - PanelTop);
                    using (var shade = new SolidBrush(Color.FromArgb(231, 7, 12, 27)))
                        g.FillRectangle(shade, 15, FooterTop, Width - 30, Height - 15 - FooterTop);
                    using (var blue = new Pen(Color.FromArgb(126, 94, 119, 173)))
                    using (var dim = new Pen(Color.FromArgb(60, 95, 115, 163)))
                    using (var goldLine = new Pen(Color.FromArgb(175, Gold)))
                    using (var divider = new Pen(Color.FromArgb(90, Gold)))
                    {
                        g.DrawRectangle(blue, 15, 15, Width - 31, Height - 31);
                        g.DrawRectangle(dim, 19, 19, Width - 39, Height - 39);
                        g.DrawRectangle(dim, PanelX, PanelTop, PanelW, PanelBottom - PanelTop);
                        g.DrawLine(divider, PanelX + 24, DividerY, PanelX + PanelW - 24, DividerY);
                        g.DrawLine(blue, 15, FooterTop, Width - 16, FooterTop);
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

        /// <summary>The footer status: a coloured indicator dot and one short line (ellipsis when long; the full note is the tooltip).</summary>
        sealed class StatusLine : Control
        {
            Color dot = Good;
            public string Detail { get; private set; } = "";
            /// <summary>Text, colour or detail changed (the form refreshes the tooltip).</summary>
            public event Action Changed;
            public StatusLine()
            {
                SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
                BackColor = Color.Transparent;
                ForeColor = Ink;
                AccessibleRole = AccessibleRole.StaticText;
            }

            public void Set(string text, StatusLevel level, string detail)
            {
                var c = level == StatusLevel.Warn ? Orange : level == StatusLevel.Busy ? VioletLight : Good;
                if (Text == text && dot == c && Detail == detail) return;
                dot = c;
                Detail = detail ?? "";
                AccessibleName = text;
                Text = text;
                Invalidate();
                if (Changed != null) Changed();
            }

            protected override void OnPaint(PaintEventArgs e)
            {
                var g = e.Graphics;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                int d = 8, cy = Height / 2;
                using (var glow = new SolidBrush(Color.FromArgb(70, dot))) g.FillEllipse(glow, 0, cy - d / 2 - 2, d + 4, d + 4);
                using (var b = new SolidBrush(dot)) g.FillEllipse(b, 2, cy - d / 2, d, d);
                var r = new Rectangle(d + 12, 0, Width - d - 12, Height);
                TextRenderer.DrawText(g, Text, Font, r, Art.Ink, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            }
        }

        /// <summary>Dark colours for the Settings menu so it matches the launcher instead of the light Windows default.</summary>
        sealed class MenuColors : ProfessionalColorTable
        {
            static readonly Color Back = Color.FromArgb(18, 20, 36), Hover = Color.FromArgb(51, 62, 101), Edge = Color.FromArgb(103, 124, 172);
            public override Color ToolStripDropDownBackground { get { return Back; } }
            public override Color ImageMarginGradientBegin { get { return Back; } }
            public override Color ImageMarginGradientMiddle { get { return Back; } }
            public override Color ImageMarginGradientEnd { get { return Back; } }
            public override Color MenuBorder { get { return Edge; } }
            public override Color MenuItemBorder { get { return Edge; } }
            public override Color MenuItemSelected { get { return Hover; } }
            public override Color CheckBackground { get { return Hover; } }
            public override Color CheckSelectedBackground { get { return Hover; } }
            public override Color CheckPressedBackground { get { return Hover; } }
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
