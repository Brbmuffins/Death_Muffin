using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace DeathMuffinTeam
{
    /// <summary>
    /// The small notice that stays up while AFK mode is on: "AFK mode on: jobs run right away", what runs and what is queued (<see cref="SetJobs"/>, Helix 2026-10-19), and the buttons End AFK mode
    /// and Hide. Like the offer box it never takes the keyboard or the focus: shown without activation, no-activate window style, no taskbar button, and its buttons do not ask for focus. It sits
    /// in the bottom-right corner of the work area and grows upwards with its lines.
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
            end = new RuneButton(TeamLogic.AfkEndText, false) { Bounds = new Rectangle(18, 56, 140, 28), TakesFocus = false, TabStop = false, Font = Font };
            end.Click += (s, e) => { var h = Ended; if (h != null) h(); };
            hide = new RuneButton(TeamLogic.AfkHideText, false) { Bounds = new Rectangle(168, 56, 90, 28), TakesFocus = false, TabStop = false, Font = Font };
            hide.Click += (s, e) => { var h = HideRequested; if (h != null) h(); };
            Controls.AddRange(new Control[] { heading, text, end, hide });
        }

        const int LinesTop = 56, LineHeight = 18, MaxLines = 8;
        readonly RuneButton end, hide;
        readonly List<Label> lineLabels = new List<Label>();

        /// <summary>What runs and what is queued, a line each (TeamLogic.AfkJobLines; at most 8, a long one ends in "..."). The buttons move below them and the notice keeps its bottom-right corner.</summary>
        public void SetJobs(IList<string> lines)
        {
            int n = lines == null ? 0 : Math.Min(lines.Count, MaxLines);
            while (lineLabels.Count < n)
            {
                var l = new Label { Font = Font, ForeColor = Art.Ink, BackColor = Color.Transparent, AutoSize = false, AutoEllipsis = true, UseMnemonic = false };
                lineLabels.Add(l);
                Controls.Add(l);
            }
            for (int i = 0; i < lineLabels.Count; i++)
            {
                Label l = lineLabels[i];
                l.Visible = i < n;
                if (i >= n) continue;
                string t = lines[i] ?? "";
                l.Text = t;
                l.ForeColor = t.StartsWith("Running", StringComparison.Ordinal) || t.StartsWith("Queued", StringComparison.Ordinal) || t.StartsWith("Waiting", StringComparison.Ordinal) ? Art.Gold : Art.Ink;
                l.Bounds = new Rectangle(18, LinesTop + i * LineHeight, 344, LineHeight);
            }
            int buttons = LinesTop + n * LineHeight + (n > 0 ? 6 : 0);
            end.Top = buttons;
            hide.Top = buttons;
            int bottom = Bottom;
            ClientSize = new Size(ClientSize.Width, buttons + 28 + 8);
            if (Visible) Top = bottom - Height;   // grows upwards: the corner stays where it was
            Invalidate();
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
