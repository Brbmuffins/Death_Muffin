using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

namespace DeathMuffinTeam
{
    /// <summary>The launcher's look (launcher/windows/Art.cs): the colours and the owner-drawn rune button.</summary>
    internal static class Art
    {
        public static readonly Color Bg = Color.FromArgb(7, 6, 10);
        public static readonly Color Panel = Color.FromArgb(13, 15, 27);
        public static readonly Color Violet = Color.FromArgb(124, 58, 237);
        public static readonly Color VioletLight = Color.FromArgb(198, 164, 255);
        public static readonly Color Ink = Color.FromArgb(240, 234, 248);
        public static readonly Color Muted = Color.FromArgb(178, 170, 190);
        public static readonly Color Gold = Color.FromArgb(232, 196, 126);
        public static readonly Color Orange = Color.FromArgb(244, 176, 128);
        public static readonly Color Good = Color.FromArgb(150, 214, 160);

        public static void Quality(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        }

        /// <summary>A small framed panel in the launcher's indigo: the background of the offer box and the sign-in box.</summary>
        public static void PaintFrame(Graphics g, Size size)
        {
            using (var fill = new SolidBrush(Bg)) g.FillRectangle(fill, 0, 0, size.Width, size.Height);
            using (var outer = new Pen(Color.FromArgb(103, 124, 172)))
            using (var inner = new Pen(Color.FromArgb(60, 225, 224, 255)))
            using (var gold = new Pen(Gold))
            {
                g.DrawRectangle(outer, 0, 0, size.Width - 1, size.Height - 1);
                g.DrawRectangle(inner, 3, 3, size.Width - 7, size.Height - 7);
                g.DrawLine(gold, 12, 3, 52, 3);
                g.DrawLine(gold, size.Width - 53, size.Height - 4, size.Width - 13, size.Height - 4);
            }
        }
    }

    /// <summary>
    /// Owner-drawn flat button (the launcher's). The stock Button draws disabled text in dark grey, which on the violet primary button read as black on purple; this one
    /// always paints light text with clear hover/pressed/disabled states. <see cref="TakesFocus"/> false keeps a click from asking for the keyboard (the offer box).
    /// </summary>
    internal sealed class RuneButton : Control
    {
        bool primary;
        bool hover, down;

        public bool Primary { get { return primary; } set { if (primary != value) { primary = value; Invalidate(); } } }

        /// <summary>False for the offer box: a click on it must not move the keyboard to it.</summary>
        public bool TakesFocus { get; set; }

        public RuneButton(string text, bool primary)
        {
            this.primary = primary;
            TakesFocus = true;
            Text = text;
            Cursor = Cursors.Hand;
            TabStop = true;
            AccessibleRole = AccessibleRole.PushButton;
            AccessibleName = text;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { if (TakesFocus) Focus(); down = true; Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Cursor = Enabled ? Cursors.Hand : Cursors.Default; Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { AccessibleName = Text; Invalidate(); base.OnTextChanged(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override bool IsInputKey(Keys keyData)
        {
            if ((keyData & Keys.KeyCode) == Keys.Enter || (keyData & Keys.KeyCode) == Keys.Space) return true;
            return base.IsInputKey(keyData);
        }
        protected override void OnKeyUp(KeyEventArgs e)
        {
            if (Enabled && (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space)) { OnClick(EventArgs.Empty); e.Handled = true; }
            base.OnKeyUp(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            if (Width < 2 || Height < 2) return;
            Color top, bottom, border, text;
            if (!Enabled)
            {
                top = Color.FromArgb(30, 34, 49); bottom = Color.FromArgb(20, 24, 38);
                border = Color.FromArgb(58, 70, 94); text = Color.FromArgb(150, 155, 174);
            }
            else if (primary)
            {
                top = down ? Color.FromArgb(73, 65, 143) : hover ? Color.FromArgb(119, 109, 211) : Color.FromArgb(94, 84, 181);
                bottom = down ? Color.FromArgb(39, 29, 91) : hover ? Color.FromArgb(72, 54, 159) : Color.FromArgb(51, 39, 125);
                border = hover ? Color.FromArgb(255, 226, 171) : Art.Gold; text = Color.White;
            }
            else
            {
                top = down ? Color.FromArgb(25, 31, 54) : hover ? Color.FromArgb(51, 62, 101) : Color.FromArgb(32, 43, 74);
                bottom = down ? Color.FromArgb(16, 21, 39) : hover ? Color.FromArgb(31, 39, 72) : Color.FromArgb(20, 28, 52);
                border = hover ? Art.VioletLight : Color.FromArgb(103, 124, 172); text = Art.Ink;
            }
            using (var b = new LinearGradientBrush(ClientRectangle, top, bottom, 90f)) g.FillRectangle(b, ClientRectangle);
            using (var p = new Pen(border))
            using (var inset = new Pen(Color.FromArgb(primary ? 85 : 42, 225, 224, 255)))
            {
                g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
                g.DrawRectangle(inset, 3, 3, Width - 7, Height - 7);
            }
            if (Focused && TakesFocus) ControlPaint.DrawFocusRectangle(g, new Rectangle(5, 5, Width - 10, Height - 10), text, bottom);
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, text, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        }
    }
}
