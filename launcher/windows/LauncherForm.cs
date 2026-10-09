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
        readonly Label status = new GlassLabel();
        readonly Label updateLabel = new GlassLabel();
        readonly Label newsTitle = new GlassLabel();
        // Scrollable so a whole release's notes fit (the old label showed six lines and cut the rest).
        readonly TextBox newsBody = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, TabStop = false, WordWrap = true };
        readonly LinkLabel newsLink = new LinkLabel();
        readonly RuneButton playBtn, openBtn;
        readonly LinkLabel launcherLink = new LinkLabel();
        readonly LinkLabel playInstalledLink = new LinkLabel();
        readonly Label playNote = new GlassLabel(), openNote = new GlassLabel(), modeLabel = new GlassLabel();
        readonly ThinBar dlBar = new ThinBar();
        readonly Timer netTimer = new Timer { Interval = 60000 };
        readonly CheckBox gpu = new CheckBox();
        readonly ToolTip tip = new ToolTip { ShowAlways = true };
        PatchNotesWindow patchWin;
        static readonly Color Orange = Color.FromArgb(244, 176, 128);
        static readonly Color Good = Color.FromArgb(150, 214, 160);

        // ---- Client state. Everything the two buttons show is computed from these by OfflineStateMachine / OnlineGate. ----
        /// <summary>The verified installed Godot client, or null.</summary>
        InstalledClient installed;
        /// <summary>The live manifest from the server, or null if it could not be read (this is also what keeps Online locked).</summary>
        ClientManifest live;
        /// <summary>The server answered the last check. Starts true so nothing flashes "no internet" before the first check.</summary>
        bool reachable = true, checkedOnce, rechecking, launcherChecked;
        bool installing, installFailed;
        double installProgress = -1;
        string installError;
        System.Threading.CancellationTokenSource installCts;
        Process gameProc;
        RunningMode running = RunningMode.None;
        string statusLink;

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

            // 1. PLAY ONLINE: fully wired, but greyed out until the developers unlock it in the server manifest.
            playBtn = Btn("PLAY ONLINE   ›", 866, 563, 268, 64, true);
            playBtn.Font = new Font("Georgia", 16f, FontStyle.Bold);
            playBtn.Click += (s, e) => LaunchGame(true);
            root.Controls.Add(playBtn);
            Note(playNote, 866, 638, 268, 16, "");
            root.Controls.Add(playNote);

            updateLabel.SetBounds(x, 226, w, 38);
            updateLabel.ForeColor = Muted;
            updateLabel.Text = "Checking for updates...";
            root.Controls.Add(updateLabel);
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

            // 2. The one offline button: Download / Update / Play depending on state (see OfflineStateMachine).
            root.Controls.Add(Lbl("OFFLINE EDITION  -  PLAYS ON THIS PC", new Font("Segoe UI", 8.5f, FontStyle.Bold), Gold, 40, 546, 520, 18));
            openBtn = Btn("DOWNLOAD OFFLINE GAME", 40, 568, 520, 42, false);
            openBtn.Click += (s, e) => OnOfflineClick();
            root.Controls.Add(openBtn);
            Note(openNote, 40, 614, 520, 18, "");
            root.Controls.Add(openNote);
            playInstalledLink.SetBounds(40, 632, 520, 16);
            playInstalledLink.BackColor = Color.Transparent;
            playInstalledLink.LinkColor = Gold;
            playInstalledLink.ActiveLinkColor = Ink;
            playInstalledLink.LinkBehavior = LinkBehavior.HoverUnderline;
            playInstalledLink.Font = new Font("Segoe UI", 8.5f);
            playInstalledLink.Text = "Play the installed version instead";
            playInstalledLink.Visible = false;
            playInstalledLink.LinkClicked += (s, e) => LaunchGame(false);
            root.Controls.Add(playInstalledLink);
            dlBar.SetBounds(40, 654, 520, 4);
            dlBar.Visible = false;
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
                if (Alive(gameProc)) SetStatus("GPU setting applies the next time the game starts.");
            };
            root.Controls.Add(gpu);

            status.SetBounds(590, 616, 250, 42);
            status.ForeColor = Muted;
            root.Controls.Add(status);
            root.Controls.Add(Lbl("LAUNCHER " + Program.Version, new Font("Segoe UI", 8f, FontStyle.Bold), Muted, 700, 546, 140, 16, ContentAlignment.TopRight));
            foreach (var l in new Label[] { updateLabel, newsTitle, status }) { l.AutoEllipsis = true; l.BackColor = Color.Transparent; }
            status.TextChanged += (s, e) => tip.SetToolTip(status, status.Text);
            status.Click += (s, e) => { if (statusLink != null) OpenExternalPage(statusLink); };

            installed = ClientStore.ReadInstalled(Settings.ClientDir);
            // The check runs once a minute so a dev unlocking Online (or publishing a build) shows up without restarting the launcher.
            netTimer.Tick += async (s, e) => await RecheckAsync();
            netTimer.Enabled = true;
            NetworkChange.NetworkAvailabilityChanged += OnNetworkChanged;
            SetStatus("Ready.");
            UpdateMode();
            ApplyUi();
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

        void SetStatus(string text)
        {
            statusLink = null;
            status.Cursor = Cursors.Default;
            status.ForeColor = Muted;
            status.Text = text;
        }

        void Warn(string text, string link)
        {
            SetStatus(text);
            status.ForeColor = Orange;
            statusLink = link;
            if (link != null) status.Cursor = Cursors.Hand;
        }

        async System.Threading.Tasks.Task InitAsync()
        {
            var news = ShowNewsAsync();
            await RecheckAsync();
            await news;
        }

        /// <summary>Asks the server for the manifest: the internet check, the game update check, the online lock and the launcher self-check in one request.</summary>
        async System.Threading.Tasks.Task RecheckAsync()
        {
            if (rechecking || IsDisposed) return;
            rechecking = true;
            try
            {
                var r = await Updates.FetchManifestAsync();
                bool was = reachable, first = !checkedOnce;
                checkedOnce = true;
                reachable = r.Reachable;
                live = r.Manifest;   // null on any failure: Online stays locked
                ApplyUi();
                if (!first && r.Reachable != was)
                {
                    if (r.Reachable) SetStatus("Back online.");
                    else if (installed != null) Warn("No internet connection. Play offline works.", null);
                    else Warn("No internet connection. Connect once to download the game.", null);
                }
                if (r.Reachable && !launcherChecked)
                {
                    launcherChecked = true;
                    string nv = await Updates.FetchNewerLauncherAsync();
                    if (nv != null)
                    {
                        launcherLink.Text = "Launcher " + nv + " available: click to download (opens your browser).";
                        launcherLink.Links.Clear();
                        launcherLink.Links.Add(0, launcherLink.Text.Length);
                        launcherLink.Visible = true;
                    }
                }
            }
            finally { rechecking = false; }
        }

        static string Short(string v) { return OfflineStateMachine.ShortVersion(v); }

        /// <summary>
        /// Paints both buttons, their captions and the status lines from one place so the states cannot disagree.
        /// All decisions live in ClientLogic.cs (unit-tested); this only copies the result onto controls.
        /// </summary>
        void ApplyUi()
        {
            string installedVer = installed != null ? installed.Version : null;

            var on = OnlineGate.Compute(live, installedVer);
            playBtn.Enabled = on.Enabled && !installing;
            playNote.Text = on.Note;
            playNote.ForeColor = on.Locked ? VioletLight : Muted;
            tip.SetToolTip(playBtn, on.Tip);
            playBtn.AccessibleDescription = on.Locked ? "Locked. " + on.Note : on.Note;

            var off = OfflineStateMachine.Compute(new OfflineInputs
            {
                InstalledVersion = installedVer, Live = live, NetReachable = reachable, Running = running,
                Downloading = installing, Progress = installProgress, Failed = installFailed, Error = installError,
            });
            if (!checkedOnce && installed == null && !installing)
            {
                off.Text = "CHECKING FOR THE GAME...";
                off.Enabled = false;
                off.Action = OfflineAction.None;
                off.Note = "";
            }
            openBtn.Text = off.Text;
            openBtn.Enabled = off.Enabled;
            // Violet emphasis goes to whichever play path is open: offline while Online is locked or unreachable.
            openBtn.Primary = !on.Enabled;
            openNote.Text = off.Note;
            openNote.ForeColor = off.Warn ? Orange : Muted;
            playInstalledLink.Visible = off.ShowPlayInstalledLink && running == RunningMode.None;
            dlBar.Visible = off.ShowBar;
            if (off.ShowBar) dlBar.Value = off.Bar;
            openBtn.AccessibleDescription = off.Note;
            offlineAction = off.Action;

            if (!checkedOnce) { }
            else if (!reachable) { updateLabel.Text = "No internet connection. Updates can't be checked."; updateLabel.ForeColor = Muted; }
            else if (live == null) { updateLabel.Text = "No game build is published yet."; updateLabel.ForeColor = Muted; }
            else if (installed == null) { updateLabel.Text = "Game not downloaded yet (build " + Short(live.Version) + " available)."; updateLabel.ForeColor = VioletLight; }
            else if (VersionCompare.Compare(live.Version, installed.Version) > 0) { updateLabel.Text = "Update available (build " + Short(live.Version) + "). Installed: " + Short(installed.Version) + "."; updateLabel.ForeColor = VioletLight; }
            else { updateLabel.Text = "Up to date (build " + Short(installed.Version) + ")."; updateLabel.ForeColor = Muted; }
        }

        OfflineAction offlineAction = OfflineAction.None;

        void OnOfflineClick()
        {
            switch (offlineAction)
            {
                case OfflineAction.Download:
                case OfflineAction.Update:
                    var _ = InstallAsync();
                    break;
                case OfflineAction.Play:
                    LaunchGame(false);
                    break;
            }
        }

        void UpdateMode()
        {
            if (running == RunningMode.Online) { modeLabel.Text = "Online game running"; modeLabel.ForeColor = VioletLight; }
            else if (running == RunningMode.Offline) { modeLabel.Text = "Offline game running"; modeLabel.ForeColor = Gold; }
            else { modeLabel.Text = "No game running"; modeLabel.ForeColor = Muted; }
        }

        static bool Alive(Process p)
        {
            try { return p != null && !p.HasExited; } catch (Exception) { return false; }
        }

        async System.Threading.Tasks.Task ShowNewsAsync()
        {
            var n = await Updates.FetchNotesAsync();
            if (n == null || n.Items.Count == 0)
            {
                newsTitle.Text = "No release notes available.";
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

        /// <summary>Downloads the live manifest's files with a progress bar, verifies every SHA-256 and swaps the new version in.</summary>
        async System.Threading.Tasks.Task InstallAsync()
        {
            var manifest = live;
            if (manifest == null || installing) return;
            installing = true; installFailed = false; installError = null; installProgress = 0;
            installCts = new System.Threading.CancellationTokenSource();
            ApplyUi();
            SetStatus("Downloading the game (" + OfflineStateMachine.Mb(manifest.TotalBytes) + ").");
            var progress = new Progress<InstallProgress>(p =>
            {
                installProgress = p.Fraction;
                var ui = OfflineStateMachine.Compute(new OfflineInputs { InstalledVersion = installed != null ? installed.Version : null, Live = manifest, Downloading = true, Progress = p.Fraction });
                openBtn.Text = ui.Text;
                dlBar.Visible = true;
                dlBar.Value = p.Fraction;
            });
            try
            {
                using (var http = Updates.CreateDownloadClient())
                    await new ClientInstaller(http, Settings.ClientDir).InstallAsync(manifest, installed, progress, installCts.Token);
                installed = ClientStore.ReadInstalled(Settings.ClientDir);
                if (installed == null) throw new IOException("The downloaded files did not pass the final check.");
                SetStatus("Game downloaded. You can play offline.");
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
        /// Starts the Godot client. online=false is the offline edition (<c>-- --offline</c>); online=true passes <c>-- --online</c> and is
        /// refused unless the server manifest has unlocked it. Only one game runs at a time (both sign in to the same account), so a
        /// running game of the other mode is closed first, after asking.
        /// </summary>
        void LaunchGame(bool online)
        {
            if (installed == null || !File.Exists(installed.ExePath))
            {
                installed = ClientStore.ReadInstalled(Settings.ClientDir);
                ApplyUi();
                if (installed == null) { Warn("The game files are missing. Download them first.", null); return; }
            }
            // Locked is locked: even if something calls this path, an unreadable manifest or enabled:false stops here.
            if (online && !OnlineGate.IsOpen(live)) { Warn(OnlineGate.LockMessage(live) + ".", null); return; }
            if (Alive(gameProc))
            {
                var want = online ? RunningMode.Online : RunningMode.Offline;
                if (running == want) { SetStatus((online ? "Online" : "Offline") + " game is already running."); return; }
                string which = online ? "offline" : "online";
                if (MessageBox.Show(this, "Close the " + which + " game first? Both use your account and would sign each other out.", "Death Muffin",
                        MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button1) != DialogResult.Yes)
                    return;
                CloseGame();
            }
            ApplyGpuPreference(installed.ExePath);
            try
            {
                // Everything after "--" is a user argument for the game: read it with OS.get_cmdline_user_args().
                var psi = new ProcessStartInfo(installed.ExePath, online ? "-- --online" : "-- --offline")
                {
                    WorkingDirectory = installed.Dir, UseShellExecute = false,
                };
                var p = Process.Start(psi);
                p.EnableRaisingEvents = true;
                p.Exited += (s, e) => { try { BeginInvoke(new Action(() => OnGameExited(p))); } catch (Exception) { } };
                gameProc = p;
                running = online ? RunningMode.Online : RunningMode.Offline;
                SetStatus(online ? "Online game running." : "Offline game running.");
            }
            catch (Exception ex)
            {
                Warn("The game could not start: " + ex.Message, null);
            }
            UpdateMode();
            ApplyUi();
        }

        void OnGameExited(Process p)
        {
            if (!ReferenceEquals(gameProc, p)) return;   // an older process replaced by the other mode
            gameProc = null;
            running = RunningMode.None;
            UpdateMode();
            SetStatus("Game closed.");
            ApplyUi();
        }

        void CloseGame()
        {
            var p = gameProc;
            if (p == null) return;
            try
            {
                p.CloseMainWindow();
                if (!p.WaitForExit(4000)) p.Kill();   // our own child process only
                p.WaitForExit(2000);
            }
            catch (Exception) { }
            OnGameExited(p);
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
            patchWin = new PatchNotesWindow();
            patchWin.FormClosed += (s, e) => patchWin = null;
            patchWin.Show(this);
        }

        static bool Alive2(Form f) { return f != null && !f.IsDisposed; }

        /// <summary>The only remaining browser launch: the newer launcher zip (an exe cannot replace itself).</summary>
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
