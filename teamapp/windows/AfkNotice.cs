using System;
using System.Drawing;
using System.Windows.Forms;

namespace DeathMuffinTeam
{
    /// <summary>
    /// The small notice that stays up while AFK mode is on: "AFK mode on: jobs run right away" and a button, End AFK mode. Like the offer box it never takes the keyboard or the focus: shown without
    /// activation, no-activate window style, not topmost, no taskbar button, and its button does not ask for focus. It sits in the bottom-right corner of the work area.
    /// </summary>
    internal sealed class AfkNotice : Form
    {
        const int WS_EX_TOOLWINDOW = 0x00000080, WS_EX_NOACTIVATE = 0x08000000;

        /// <summary>The person pressed End AFK mode.</summary>
        public event Action Ended;
        /// <summary>The person pressed Hide: the notice goes, AFK mode stays (the tray's Show AFK notice brings it back).</summary>
        public event Action HideRequested;

        public AfkNotice()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;   // Helix 2026-10-19: always on top while AFK mode is on (it still never takes focus); Hide puts it away
            StartPosition = FormStartPosition.Manual;
            ClientSize = new Size(380, 92);
            BackColor = Art.Bg;
            Font = new Font("Segoe UI", 9.5f);
            DoubleBuffered = true;
            Text = "Death Muffin Team";
            AccessibleName = "Death Muffin Team AFK mode";

            var heading = new Label { Text = "DEATH MUFFIN TEAM", Font = new Font("Segoe UI", 8.5f, FontStyle.Bold), ForeColor = Art.Gold, BackColor = Color.Transparent, AutoSize = false, Bounds = new Rectangle(18, 12, 344, 18) };
            var text = new Label { Text = TeamLogic.AfkText, Font = new Font("Segoe UI", 10.5f), ForeColor = Art.Ink, BackColor = Color.Transparent, AutoSize = false, AutoEllipsis = true, Bounds = new Rectangle(18, 32, 344, 22) };
            var end = new RuneButton(TeamLogic.AfkEndText, false) { Bounds = new Rectangle(18, 56, 140, 28), TakesFocus = false, TabStop = false, Font = Font };
            end.Click += (s, e) => { var h = Ended; if (h != null) h(); };
            var hide = new RuneButton(TeamLogic.AfkHideText, false) { Bounds = new Rectangle(168, 56, 90, 28), TakesFocus = false, TabStop = false, Font = Font };
            hide.Click += (s, e) => { var h = HideRequested; if (h != null) h(); };
            Controls.AddRange(new Control[] { heading, text, end, hide });
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
                return cp;
            }
        }

        /// <summary>Puts the notice in the bottom-right corner of the work area.</summary>
        public void PlaceInCorner()
        {
            Rectangle area = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(area.Right - Width - 16, area.Bottom - Height - 16);
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            Art.Quality(e.Graphics);
            Art.PaintFrame(e.Graphics, ClientSize);
        }
    }
}
