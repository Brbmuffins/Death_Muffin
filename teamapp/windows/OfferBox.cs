using System;
using System.Drawing;
using System.Windows.Forms;

namespace DeathMuffinTeam
{
    /// <summary>
    /// The small box that asks about a job: what it is and how heavy, a countdown (mode ask) and Run now / Not now / Pause 2 hours. It never takes the keyboard or
    /// the focus: shown without activation, no-activate window style, not topmost, no taskbar button, and its buttons do not ask for focus. It sits in the
    /// bottom-right corner of the work area, where a notification would.
    /// </summary>
    internal sealed class OfferBox : Form
    {
        const int WS_EX_TOOLWINDOW = 0x00000080, WS_EX_NOACTIVATE = 0x08000000;

        readonly Label text = new Label();
        readonly Label countdown = new Label();

        /// <summary>The person's click.</summary>
        public event Action<OfferAnswer> Answered;

        public OfferBox()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = false;
            StartPosition = FormStartPosition.Manual;
            ClientSize = new Size(380, 134);
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

            var run = Button("Run now", true, new Rectangle(18, 90, 108, 32), OfferAnswer.Yes);
            var notNow = Button("Not now", false, new Rectangle(136, 90, 100, 32), OfferAnswer.NotNow);
            var pause = Button("Pause 2 hours", false, new Rectangle(246, 90, 116, 32), OfferAnswer.Pause);
            Controls.AddRange(new Control[] { heading, text, countdown, run, notNow, pause });
        }

        RuneButton Button(string label, bool primary, Rectangle bounds, OfferAnswer answer)
        {
            var b = new RuneButton(label, primary) { Bounds = bounds, TakesFocus = false, TabStop = false, Font = Font };
            b.Click += (s, e) => { var h = Answered; if (h != null) h(answer); };
            return b;
        }

        /// <summary>Shows what is on offer (called every second while the box is up; only changed text repaints).</summary>
        public void Apply(OfferView view)
        {
            if (text.Text != view.Text) text.Text = view.Text;
            if (countdown.Text != view.Countdown) countdown.Text = view.Countdown;
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
