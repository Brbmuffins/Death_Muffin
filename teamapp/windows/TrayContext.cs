using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace DeathMuffinTeam
{
    /// <summary>
    /// The app is a tray icon: no window of its own. This wires the real pieces (Windows platform, DPAPI, the server, the game process) to the TeamController and
    /// shows its answers: the tray menu (status, Run now, Pause 2 hours, Mode, sign in/out, start with Windows, folder, Quit), the offer box and balloons.
    /// </summary>
    internal sealed class TrayContext : ApplicationContext, ITeamUi
    {
        static readonly string ExePath = Application.ExecutablePath;

        readonly AppLog log;
        readonly DpapiProtector protector = new DpapiProtector();
        readonly TeamSettings settings;
        readonly TeamFolders folders = new TeamFolders(TeamSettings.Root);
        readonly TeamController controller;
        readonly HttpClient updateHttp = FileFetcher.CreateClient(Program.Version);
        readonly NotifyIcon tray = new NotifyIcon();
        readonly Control marshal = new Control();
        readonly System.Threading.CancellationTokenSource heartbeatCts = new System.Threading.CancellationTokenSource();
        readonly Timer evaluateTimer = new Timer { Interval = 1000 };
        readonly Timer updateTimer = new Timer { Interval = 30 * 1000 };

        readonly ToolStripMenuItem statusItem = new ToolStripMenuItem("Starting...") { Enabled = false };
        readonly ToolStripMenuItem runItem = new ToolStripMenuItem("Run now");
        readonly ToolStripMenuItem pauseItem = new ToolStripMenuItem("Pause 2 hours");
        readonly ToolStripMenuItem afkItem = new ToolStripMenuItem(TeamLogic.AfkEndText) { Visible = false };
        readonly ToolStripMenuItem afkShowItem = new ToolStripMenuItem(TeamLogic.AfkShowText) { Visible = false };
        bool afkHidden;   // the person hid the AFK notice: it stays hidden until they show it or AFK mode ends
        readonly ToolStripMenuItem[] modeItems = new ToolStripMenuItem[3];
        readonly ToolStripMenuItem signItem = new ToolStripMenuItem("Sign in...");
        readonly ToolStripMenuItem startupItem = new ToolStripMenuItem("Start with Windows") { CheckOnClick = true };

        OfferBox box;
        AfkNotice afkBox;
        bool signInOpen, exiting;
        int updateFailures;
        bool updateGaveUp;

        public TrayContext(AppLog log)
        {
            this.log = log;
            settings = TeamSettings.Load(protector);
            marshal.CreateControl();
            var unused = marshal.Handle;   // makes the control's handle on this (the UI) thread, so BeginInvoke works from the job's threads

            var transport = new HttpClientTransport(HttpClientTransport.CreateClient(Program.Version));
            var api = new TeamApi(transport, new Uri(TeamUrls.ApiBase));
            var platform = new WindowsPlatform(TeamSettings.Root);
            var probe = new WindowsPcProbe(platform);   // one reader for both: the controller reads while a benchmark waits, the runner while a job runs
            var runner = new JobRunner(api, folders, new FileFetcher(FileFetcher.CreateClient(Program.Version)), new ProcessGameHost(Native.TendGameWindow), platform, Native.TryHardLink, probe) { ShotsPosition = Native.OffscreenPosition, WindowPosition = Native.OffscreenPositionFor };
            controller = new TeamController(api, settings, () => settings.Save(protector), platform, runner, this, () => DateTime.UtcNow,
                Program.Version, Environment.MachineName, new Uri(TeamUrls.SiteBase), log.Line, probe);

            BuildMenu();
            try { tray.Icon = Icon.ExtractAssociatedIcon(ExePath); } catch (Exception) { tray.Icon = SystemIcons.Application; }
            tray.Text = "Death Muffin Team";
            tray.Visible = true;

            evaluateTimer.Tick += (s, e) => Guard(controller.EvaluateAsync());
            updateTimer.Tick += (s, e) => { updateTimer.Interval = 15 * 60 * 1000; Guard(CheckUpdateAsync()); };
            evaluateTimer.Start();
            updateTimer.Start();

            log.Line("started " + Program.Version);
            // After the message loop has started (the sign-in box, when needed, is a dialog and must not open inside the constructor).
            marshal.BeginInvoke(new Action(() => Guard(controller.StartAsync())));
            marshal.BeginInvoke(new Action(() => Guard(controller.HeartbeatLoopAsync(heartbeatCts.Token))));   // the long poll: idles until signed in
        }

        // ---- The menu ------------------------------------------------------------------------------------------------------------

        void BuildMenu()
        {
            var menu = new ContextMenuStrip { ShowImageMargin = false };
            var modeMenu = new ToolStripMenuItem("Mode");
            OfferMode[] modes = { OfferMode.Ask, OfferMode.Auto, OfferMode.Yes };
            for (int i = 0; i < modes.Length; i++)
            {
                OfferMode m = modes[i];
                var item = new ToolStripMenuItem(Modes.Label(m));
                item.Click += (s, e) => Guard(controller.SetModeAsync(m));
                modeItems[i] = item;
                modeMenu.DropDownItems.Add(item);
            }
            runItem.Click += (s, e) => Guard(controller.RunNowAsync());
            pauseItem.Click += (s, e) => Guard(controller.TogglePauseAsync());
            afkItem.Click += (s, e) => controller.EndAfk();
            afkShowItem.Click += (s, e) => OnUi(() => { afkHidden = false; afkShowItem.Visible = false; if (afkBox != null && !afkBox.Visible) { afkBox.PlaceInCorner(); afkBox.Show(); } });
            signItem.Click += (s, e) =>
            {
                if (controller.SignedIn) Guard(SignOutAsync());
                else ShowSignIn();
            };
            startupItem.Checked = StartupEntry.IsOn();
            startupItem.Click += (s, e) =>
            {
                try { StartupEntry.Set(startupItem.Checked, ExePath); }
                catch (Exception ex) { startupItem.Checked = !startupItem.Checked; Notify("Could not change the start-up setting", ex.Message, true); }
            };
            var folderItem = new ToolStripMenuItem("Open the app's folder");
            folderItem.Click += (s, e) => OpenPath(TeamSettings.Root);
            var logItem = new ToolStripMenuItem("Open the last job's log");
            logItem.Click += (s, e) =>
            {
                string last = folders.LatestLog();
                if (last != null) OpenPath(last); else Notify("No job yet", "There is no job log to open.", false);
            };
            var quitItem = new ToolStripMenuItem("Quit");
            quitItem.Click += (s, e) => Guard(QuitAsync());

            menu.Items.AddRange(new ToolStripItem[]
            {
                statusItem, new ToolStripMenuItem("Death Muffin Team " + Program.Version) { Enabled = false }, new ToolStripSeparator(),
                runItem, pauseItem, afkItem, afkShowItem, modeMenu, new ToolStripSeparator(),
                signItem, startupItem, folderItem, logItem, new ToolStripSeparator(), quitItem,
            });
            menu.Opening += (s, e) => RefreshMenu();
            tray.ContextMenuStrip = menu;
        }

        async Task SignOutAsync()
        {
            await controller.SignOutAsync();
            RefreshMenu();
        }

        void RefreshMenu()
        {
            OfferMode[] modes = { OfferMode.Ask, OfferMode.Auto, OfferMode.Yes };
            for (int i = 0; i < modes.Length; i++) modeItems[i].Checked = controller.Mode == modes[i];
            pauseItem.Text = controller.IsPaused ? "Resume" : "Pause 2 hours";
            signItem.Text = controller.SignedIn ? "Sign out" : "Sign in...";
            signItem.Enabled = !controller.IsBusy;
            runItem.Enabled = controller.SignedIn && !controller.IsBusy;
            startupItem.Checked = StartupEntry.IsOn();
        }

        static void OpenPath(string path)
        {
            try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
            catch (Exception) { }
        }

        // ---- ITeamUi (may be called from the job's threads: everything goes through the UI thread) -----------------------------------

        void OnUi(Action a)
        {
            if (exiting) return;
            if (marshal.InvokeRequired) { try { marshal.BeginInvoke(a); } catch (InvalidOperationException) { } }
            else a();
        }

        public void ShowOffer(OfferView view)
        {
            OnUi(() =>
            {
                if (box == null)
                {
                    box = new OfferBox();
                    box.Answered += a => Guard(controller.AnswerAsync(a));
                }
                box.Apply(view);
                if (!box.Visible)
                {
                    box.PlaceInCorner();
                    box.Show();   // OfferBox.ShowWithoutActivation: the keyboard and the focus stay where they were
                    log.Line("box shown at " + box.Bounds + " (screen " + Screen.PrimaryScreen.WorkingArea + "), visible " + box.Visible + ", handle " + box.IsHandleCreated);
                }
            });
        }

        public void SetAfk(bool on)
        {
            OnUi(() =>
            {
                afkItem.Visible = on;
                if (on)
                {
                    if (afkBox == null)
                    {
                        afkBox = new AfkNotice();
                        afkBox.Ended += () => controller.EndAfk();
                        afkBox.HideRequested += () => { afkHidden = true; afkBox.Hide(); afkShowItem.Visible = true; };
                    }
                    afkShowItem.Visible = afkHidden;
                    if (!afkHidden && !afkBox.Visible)
                    {
                        afkBox.PlaceInCorner();
                        afkBox.Show();   // AfkNotice.ShowWithoutActivation: the keyboard and the focus stay where they were
                    }
                }
                else
                {
                    afkHidden = false;   // the next AFK mode shows its notice again
                    afkShowItem.Visible = false;
                    if (afkBox != null) afkBox.Hide();
                }
            });
        }

        public void HideOffer()
        {
            OnUi(() => { if (box != null) { box.Hide(); } });
        }

        public void SetStatus(string text, StatusLevel level)
        {
            OnUi(() =>
            {
                statusItem.Text = text.Length > 90 ? text.Substring(0, 87) + "..." : text;
                string tip = "Death Muffin Team: " + text;
                tray.Text = tip.Length > 63 ? tip.Substring(0, 60) + "..." : tip;   // NotifyIcon.Text takes at most 63 characters
            });
        }

        public void Notify(string title, string text, bool error)
        {
            OnUi(() =>
            {
                tray.BalloonTipTitle = title.Length > 63 ? title.Substring(0, 63) : title;
                tray.BalloonTipText = text.Length > 250 ? text.Substring(0, 247) + "..." : text;
                tray.BalloonTipIcon = error ? ToolTipIcon.Error : ToolTipIcon.Info;
                tray.ShowBalloonTip(8000);
            });
        }

        public void NeedSignIn(string reason, bool openNow)
        {
            OnUi(() =>
            {
                RefreshMenu();
                if (openNow) ShowSignIn();
                else Notify("Death Muffin Team", reason + " (tray icon, Sign in)", true);
            });
        }

        public void Stopped(string message)
        {
            OnUi(() =>
            {
                Notify("Death Muffin Team stopped", message, true);
                var t = new Timer { Interval = 9000 };
                t.Tick += (s, e) => { t.Stop(); ExitNow(); };
                t.Start();
            });
        }

        void ShowSignIn()
        {
            if (signInOpen) return;
            signInOpen = true;
            try
            {
                using (var f = new SignInForm(controller.SignInAsync, settings.Username))
                    f.ShowDialog();
            }
            finally { signInOpen = false; }
            RefreshMenu();
            if (controller.Stopped) ExitNow();   // not on the team: the person has read the message
        }

        // ---- Updates and quitting --------------------------------------------------------------------------------------------------

        /// <summary>The app's self-update (SelfUpdate.cs): never while a job runs; after a swap the new copy starts and this one closes.</summary>
        async Task CheckUpdateAsync()
        {
            if (exiting || controller.IsBusy) return;
            TeamManifest m = await SelfUpdate.FetchAsync(updateHttp, TeamUrls.VersionUrl);
            bool newer = m != null && VersionCompare.Compare(m.Version, Program.Version) > 0;
            SelfUpdateAction act = SelfUpdate.Decide(m, Program.Version, controller.IsBusy, newer && SelfUpdate.FolderWritable(ExePath), updateFailures);
            if (act == SelfUpdateAction.GiveUp)
            {
                if (!updateGaveUp)
                {
                    updateGaveUp = true;
                    Notify("A newer version is available", "Version " + m.Version + " could not be installed here. Ask for the new app and replace this one.", false);
                    log.Line("update to " + m.Version + " not possible (folder not writable or failed " + updateFailures + " times)");
                }
                return;
            }
            if (act != SelfUpdateAction.Apply) return;
            log.Line("updating to " + m.Version);
            try
            {
                await SelfUpdate.DownloadAsync(updateHttp, m, ExePath, System.Threading.CancellationToken.None);
                if (controller.IsBusy || exiting) return;   // a job started meanwhile: the next check swaps it
                SelfUpdate.Swap(ExePath);
                Process.Start(new ProcessStartInfo(ExePath, Program.AfterUpdateArg) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(ExePath) });
                ExitNow();
            }
            catch (Exception ex)
            {
                updateFailures++;
                log.Line("update failed: " + ex.Message);
            }
        }

        async Task QuitAsync()
        {
            await controller.ShutDownAsync(TimeSpan.FromSeconds(20));
            ExitNow();
        }

        void ExitNow()
        {
            if (exiting) return;
            exiting = true;
            heartbeatCts.Cancel();
            evaluateTimer.Stop();
            updateTimer.Stop();
            if (box != null) { box.Close(); box = null; }
            if (afkBox != null) { afkBox.Close(); afkBox = null; }
            tray.Visible = false;
            tray.Dispose();
            ExitThread();
        }

        /// <summary>Runs a task from an event handler: whatever goes wrong is written to the app's log instead of crashing a tray app.</summary>
        async void Guard(Task t)
        {
            try { await t; }
            catch (Exception ex) { log.Line("error: " + ex); }
        }
    }
}
