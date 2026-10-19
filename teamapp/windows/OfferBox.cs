using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace DeathMuffinTeam
{
    /// <summary>
    /// The small box that asks about the jobs this PC may take: a list of the first ten, oldest first (each with how long it takes, who started the Discord thread it came from and the
    /// thread's name; a click picks one), a countdown (mode ask) for the picked one, its kind's own note (a benchmark: it starts once the PC is quiet and takes the whole screen) and
    /// Run now / Not now / Pause 2 hours. It never takes the keyboard or the focus: shown without activation, no-activate window style, no taskbar button, and neither its rows nor its
    /// buttons ask for focus. It sits in the bottom-right corner of the work area, where a notification would.
    /// </summary>
    internal sealed class OfferBox : Form
    {
        const int WS_EX_TOOLWINDOW = 0x00000080, WS_EX_NOACTIVATE = 0x08000000;

        const int Wide = 420, Pad = 18, RowHeight = 44, ListTop = 62, NoteHeight = 52, ButtonsHeight = 32, BottomPad = 14;

        readonly Label text = new Label();
        readonly Label more = new Label();
        readonly Label countdown = new Label();
        readonly Label note = new Label();
        readonly RuneButton[] buttons = new RuneButton[3];
        readonly List<JobRow> rows = new List<JobRow>();

        /// <summary>The person's click on a button.</summary>
        public event Action<OfferAnswer> Answered;
        /// <summary>The person's click on a job in the list (its id).</summary>
        public event Action<string> Chosen;

        public OfferBox()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;   // a notification: on top of other windows (never over a game: jobs wait while one runs), and it still never takes focus
            StartPosition = FormStartPosition.Manual;
            ClientSize = new Size(Wide, 200);
            BackColor = Art.Bg;
            Font = new Font("Segoe UI", 9.5f);
            DoubleBuffered = true;
            Text = "Death Muffin Team";
            AccessibleName = "Death Muffin Team job offer";

            var heading = new Label { Text = "DEATH MUFFIN TEAM", Font = new Font("Segoe UI", 8.5f, FontStyle.Bold), ForeColor = Art.Gold, BackColor = Color.Transparent, AutoSize = false, Bounds = new Rectangle(Pad, 14, Wide - 2 * Pad, 18) };
            text.Font = new Font("Segoe UI", 10.5f);
            text.ForeColor = Art.Ink;
            text.BackColor = Color.Transparent;
            text.AutoSize = false;
            text.AutoEllipsis = true;
            text.Bounds = new Rectangle(Pad, 36, Wide - 2 * Pad, 22);
            foreach (Label l in new[] { more, countdown, note })
            {
                l.ForeColor = Art.Muted;
                l.BackColor = Color.Transparent;
                l.AutoSize = false;
            }
            more.Font = new Font("Segoe UI", 8.5f);
            note.Font = new Font("Segoe UI", 9f);

            buttons[0] = Button("Run now", true, new Rectangle(Pad, 0, 108, ButtonsHeight), OfferAnswer.Yes);
            buttons[1] = Button("Not now", false, new Rectangle(136, 0, 100, ButtonsHeight), OfferAnswer.NotNow);
            buttons[2] = Button("Pause 2 hours", false, new Rectangle(246, 0, 116, ButtonsHeight), OfferAnswer.Pause);
            Controls.AddRange(new Control[] { heading, text, more, countdown, note, buttons[0], buttons[1], buttons[2] });
        }

        RuneButton Button(string label, bool primary, Rectangle bounds, OfferAnswer answer)
        {
            var b = new RuneButton(label, primary) { Bounds = bounds, TakesFocus = false, TabStop = false, Font = Font };
            b.Click += (s, e) => { var h = Answered; if (h != null) h(answer); };
            return b;
        }

        /// <summary>
        /// Shows what is on offer (called every second while the box is up; only what changed repaints): how many jobs wait, the list with the picked one marked, how many more wait past it,
        /// the countdown and the picked job's note. The box grows or shrinks with the list and stays in its corner.
        /// </summary>
        public void Apply(OfferView view)
        {
            int n = view.Rows.Count;
            string head = n <= 1 ? "A job is waiting" : n + view.More + " jobs are waiting: pick one";
            if (text.Text != head) text.Text = head;
            while (rows.Count < n)
            {
                var r = new JobRow { Font = Font };
                r.Click += (s, e) => { var h = Chosen; var row = (JobRow)s; if (h != null && row.JobId.Length > 0) h(row.JobId); };
                rows.Add(r);
                Controls.Add(r);
            }
            while (rows.Count > n)
            {
                JobRow last = rows[rows.Count - 1];
                rows.RemoveAt(rows.Count - 1);
                Controls.Remove(last);
                last.Dispose();
            }
            int y = ListTop;
            for (int i = 0; i < n; i++)
            {
                rows[i].Set(view.Rows[i]);
                rows[i].Bounds = new Rectangle(Pad - 6, y, Wide - 2 * Pad + 12, RowHeight);
                y += RowHeight;
            }
            string moreLine = view.More > 0 ? "and " + view.More + " more, listed as these are done" : "";
            if (more.Text != moreLine) more.Text = moreLine;
            more.Visible = moreLine.Length > 0;
            if (more.Visible) { more.Bounds = new Rectangle(Pad, y + 2, Wide - 2 * Pad, 18); y += 20; }
            y += 6;
            if (countdown.Text != view.Countdown) countdown.Text = view.Countdown;
            countdown.Bounds = new Rectangle(Pad, y, Wide - 2 * Pad, 20);
            y += 22;
            string line = view.Note ?? "";
            if (note.Text != line) note.Text = line;
            note.Visible = line.Length > 0;
            if (note.Visible) { note.Bounds = new Rectangle(Pad, y, Wide - 2 * Pad, NoteHeight - 4); y += NoteHeight; }
            foreach (RuneButton b in buttons) b.Top = y;
            int height = y + ButtonsHeight + BottomPad;
            if (ClientSize.Height != height)
            {
                ClientSize = new Size(Wide, height);
                if (Visible) PlaceInCorner();
            }
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

        /// <summary>Puts the box in the bottom-right corner of the work area.</summary>
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

        /// <summary>One job in the list: its words on the first line, who asked and the thread on the second; the picked one has a gold mark and a lighter ground. A click picks it; it never takes focus.</summary>
        sealed class JobRow : Control
        {
            OfferRow row = new OfferRow();
            bool hover;

            public string JobId { get { return row.Id; } }

            public JobRow()
            {
                Cursor = Cursors.Hand;
                TabStop = false;
                AccessibleRole = AccessibleRole.ListItem;
                SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
                SetStyle(ControlStyles.Selectable, false);
            }

            public void Set(OfferRow r)
            {
                bool same = row.Id == r.Id && row.Text == r.Text && row.Who == r.Who && row.Selected == r.Selected;
                row = r;
                AccessibleName = r.Text + (r.Who.Length > 0 ? ", " + r.Who : "") + (r.Selected ? " (picked)" : "");
                if (!same) Invalidate();
            }

            protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
            protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }

            protected override void OnPaint(PaintEventArgs e)
            {
                var g = e.Graphics;
                Color ground = row.Selected ? Color.FromArgb(38, 34, 70) : hover ? Color.FromArgb(24, 26, 44) : Art.Bg;
                using (var b = new SolidBrush(ground)) g.FillRectangle(b, ClientRectangle);
                if (row.Selected) using (var b = new SolidBrush(Art.Gold)) g.FillRectangle(b, 0, 4, 3, Height - 8);
                var top = new Rectangle(12, 4, Width - 18, 20);
                var bottom = new Rectangle(12, 23, Width - 18, 18);
                TextRenderer.DrawText(g, row.Text, Font, top, row.Selected ? Color.White : Art.Ink, TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
                if (row.Who.Length > 0)
                    using (var small = new Font(Font.FontFamily, 8.5f))
                        TextRenderer.DrawText(g, row.Who, small, bottom, row.Selected ? Art.Gold : Art.Muted, TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            }
        }
    }
}
