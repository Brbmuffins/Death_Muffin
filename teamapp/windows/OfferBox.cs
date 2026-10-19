using System;
using System.Drawing;
using System.Windows.Forms;

namespace DeathMuffinTeam
{
    /// <summary>
    /// The small box that asks about a job: what it is and how heavy, a countdown (mode ask), a job kind's own note (a benchmark: it starts once the PC is quiet, normal priority, a touch restarts it)
    /// and Run now / Not now / Pause 2 hours. It never takes the keyboard or the focus: shown without activation, no-activate window style, not topmost, no taskbar button, and its buttons do not
    /// ask for focus. It sits in the bottom-right corner of the work area, where a notification would.
    /// </summary>
    internal sealed class OfferBox : Form
    {
        const int WS_EX_TOOLWINDOW = 0x00000080, WS_EX_NOACTIVATE = 0x08000000;

        const int BaseHeight = 134, NoteHeight = 52;   // the note may take three lines

        readonly Label text = new Label();
        readonly Label countdown = new Label();
        readonly Label note = new Label();
        readonly RuneButton[] buttons = new RuneButton[3];

        /// <summary>The person's click.</summary>
        public event Action<OfferAnswer> Answered;

        public OfferBox()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;   // a notification: on top of other windows (never over a game: jobs wait while one runs), and it still never takes focus
            StartPosition = FormStartPosition.Manual;
            ClientSize = new Size(380, BaseHeight);
            BackColor = Art.Bg;
            Font = new Font("Segoe UI", 9.5f);
            DoubleBuffered = true;
            Text = "Death Muffin Team";
            AccessibleName = "Death Muffin Team job offer";

            var heading = new Label { Text = "DEATH MUFFIN TEAM", Font = new Font("Segoe UI", 8.5f, FontStyle.Bold), ForeColor = Art.Gold, BackColor = Color.Transparent, AutoSize = false, Bounds = new Rectangle(18, 14, 344, 18) };
            text.Font = new Font("Segoe UI", 10.5f);
            text.ForeColor = Art.Ink;
            text.BackColor = Color.Transparent;
            text.AutoSize = false;
            text.AutoEllipsis = true;
            text.Bounds = new Rectangle(18, 36, 344, 22);
            countdown.ForeColor = Art.Muted;
            countdown.BackColor = Color.Transparent;
            countdown.AutoSize = false;
            countdown.Bounds = new Rectangle(18, 62, 344, 20);

            note.Font = new Font("Segoe UI", 9f);
            note.ForeColor = Art.Muted;
            note.BackColor = Color.Transparent;
            note.AutoSize = false;
            note.Bounds = new Rectangle(18, 84, 344, NoteHeight - 4);
            note.Visible = false;

            buttons[0] = Button("Run now", true, new Rectangle(18, 90, 108, 32), OfferAnswer.Yes);
            buttons[1] = Button("Not now", false, new Rectangle(136, 90, 100, 32), OfferAnswer.NotNow);
            buttons[2] = Button("Pause 2 hours", false, new Rectangle(246, 90, 116, 32), OfferAnswer.Pause);
            Controls.AddRange(new Control[] { heading, text, countdown, note, buttons[0], buttons[1], buttons[2] });
        }

        RuneButton Button(string label, bool primary, Rectangle bounds, OfferAnswer answer)
        {
            var b = new RuneButton(label, primary) { Bounds = bounds, TakesFocus = false, TabStop = false, Font = Font };
            b.Click += (s, e) => { var h = Answered; if (h != null) h(answer); };
            return b;
        }

        /// <summary>Shows what is on offer (called every second while the box is up; only changed text repaints). A note makes the box taller, the buttons keep their place under it.</summary>
        public void Apply(OfferView view)
        {
            if (text.Text != view.Text) text.Text = view.Text;
            if (countdown.Text != view.Countdown) countdown.Text = view.Countdown;
            string line = view.Note ?? "";
            if (note.Text != line) note.Text = line;
            bool has = line.Length > 0;
            int height = has ? BaseHeight + NoteHeight : BaseHeight;
            if (note.Visible != has) note.Visible = has;
            if (ClientSize.Height != height)
            {
                ClientSize = new Size(ClientSize.Width, height);
                foreach (RuneButton b in buttons) b.Top = height - BaseHeight + 90;
                if (Visible) PlaceInCorner();
            }
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
    }
}
