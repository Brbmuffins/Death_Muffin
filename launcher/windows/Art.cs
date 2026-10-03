using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

namespace DeathMuffinLauncher
{
    /// <summary>The embedded key art and the shared look (colours, painted title) used by the launcher and the loading screen.</summary>
    internal static class Art
    {
        public static readonly Color Bg = Color.FromArgb(7, 6, 10);
        public static readonly Color Violet = Color.FromArgb(124, 58, 237);
        public static readonly Color VioletLight = Color.FromArgb(198, 164, 255);
        public static readonly Color Ink = Color.FromArgb(240, 234, 248);
        public static readonly Color Muted = Color.FromArgb(178, 170, 190);
        public static readonly Color Gold = Color.FromArgb(232, 196, 126);

        static Bitmap keyArt;

        /// <summary>
        /// Decoded once into a standalone bitmap: Image.FromStream needs its stream for the image's whole lifetime, so the
        /// resource stream is copied out and closed.
        /// </summary>
        public static Bitmap KeyArt
        {
            get
            {
                if (keyArt == null)
                    using (var s = typeof(Art).Assembly.GetManifestResourceStream("keyart.jpg"))
                    using (var img = Image.FromStream(s))
                        keyArt = new Bitmap(img);
                return keyArt;
            }
        }

        public static void Quality(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        }

        /// <summary>Draws the key art scaled to cover <paramref name="size"/>, centred horizontally; <paramref name="focusX"/> (0..1) picks which part stays in view when the sides are cropped.</summary>
        public static void DrawCover(Graphics g, Size size, float focusX = 0.5f)
        {
            var img = KeyArt;
            float s = Math.Max((float)size.Width / img.Width, (float)size.Height / img.Height);
            float dw = img.Width * s, dh = img.Height * s;
            g.DrawImage(img, (size.Width - dw) * focusX, (size.Height - dh) / 2, dw, dh);
        }

        /// <summary>"DEATH MUFFIN" with a soft violet glow (the title offset a few px under the real one).</summary>
        public static void DrawTitle(Graphics g, Font font, float x, float y, StringFormat format = null)
        {
            using (var ink = new SolidBrush(Ink))
            using (var glow = new SolidBrush(Color.FromArgb(46, 150, 80, 255)))
            {
                for (int dx = -3; dx <= 3; dx += 2)
                    for (int dy = -3; dy <= 3; dy += 2)
                        g.DrawString("DEATH MUFFIN", font, glow, x + dx, y + dy, format);
                g.DrawString("DEATH MUFFIN", font, ink, x, y, format);
            }
        }
    }

    /// <summary>
    /// Owner-drawn flat button. The stock Button draws disabled text in dark grey, which on the violet primary button read as
    /// black on purple; this one always paints light text with clear hover/pressed/disabled states.
    /// </summary>
    internal sealed class RuneButton : Control
    {
        readonly bool primary;
        bool hover, down;

        public RuneButton(string text, bool primary)
        {
            this.primary = primary;
            Text = text;
            Cursor = Cursors.Hand;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Cursor = Enabled ? Cursors.Hand : Cursors.Default; Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            Color fill, border, text;
            if (!Enabled)
            {
                fill = Color.FromArgb(30, 26, 38); border = Color.FromArgb(58, 52, 70); text = Color.FromArgb(150, 144, 160);
            }
            else if (primary)
            {
                fill = down ? Color.FromArgb(104, 44, 210) : hover ? Color.FromArgb(147, 90, 245) : Art.Violet;
                border = Art.VioletLight; text = Color.White;
            }
            else
            {
                fill = down ? Color.FromArgb(28, 22, 40) : hover ? Color.FromArgb(56, 44, 80) : Color.FromArgb(36, 28, 52);
                border = hover ? Art.VioletLight : Color.FromArgb(96, 76, 136); text = Art.Ink;
            }
            using (var b = new SolidBrush(fill)) g.FillRectangle(b, ClientRectangle);
            using (var p = new Pen(border)) g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, text, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        }
    }
}
