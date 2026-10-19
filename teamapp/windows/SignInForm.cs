using System;
using System.Drawing;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace DeathMuffinTeam
{
    /// <summary>
    /// Sign in with the game's account name and password. Only the team's accounts can: the server says "This account is not on the team." for any other, and the app stops.
    /// The password is sent once and never stored; the server answers with a team token (kept protected by Windows for this user) that does not touch the game's session.
    /// </summary>
    internal sealed class SignInForm : Form
    {
        readonly Func<string, string, Task<SignInResult>> signIn;
        readonly TextBox user = new TextBox();
        readonly TextBox password = new TextBox();
        readonly Label message = new Label();
        readonly RuneButton go = new RuneButton("SIGN IN", true);
        readonly RuneButton cancel = new RuneButton("Cancel", false);
        bool busy, closeOnly;

        public SignInForm(Func<string, string, Task<SignInResult>> signIn, string username)
        {
            this.signIn = signIn;
            Text = "Death Muffin Team: sign in";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(440, 276);
            BackColor = Art.Bg;
            Font = new Font("Segoe UI", 9.5f);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch (Exception) { }

            Controls.Add(Lbl("DEATH MUFFIN TEAM", new Font("Segoe UI", 9f, FontStyle.Bold), Art.Gold, 24, 20, 392, 18));
            Controls.Add(Lbl("Sign in with your Death Muffin account. Only the team's accounts can use this app.", Font, Art.Ink, 24, 44, 392, 40));
            Controls.Add(Lbl("Username", Font, Art.Muted, 24, 96, 392, 18));
            Field(user, 24, 116);
            Controls.Add(Lbl("Password", Font, Art.Muted, 24, 150, 392, 18));
            Field(password, 24, 170);
            password.UseSystemPasswordChar = true;

            message.ForeColor = Art.Orange;
            message.BackColor = Color.Transparent;
            message.SetBounds(24, 208, 392, 20);
            Controls.Add(message);

            go.SetBounds(236, 234, 100, 34);
            cancel.SetBounds(346, 234, 70, 34);
            go.Click += async (s, e) => await DoSignIn();
            cancel.Click += (s, e) => { DialogResult = DialogResult.Cancel; Close(); };
            Controls.Add(go);
            Controls.Add(cancel);
            user.Text = username ?? "";
            KeyPreview = true;
            KeyDown += async (s, e) => { if (e.KeyCode == Keys.Enter && !busy) { e.SuppressKeyPress = true; await DoSignIn(); } };
        }

        Label Lbl(string t, Font f, Color c, int x, int y, int w, int h)
        {
            return new Label { Text = t, Font = f, ForeColor = c, BackColor = Color.Transparent, AutoSize = false, Bounds = new Rectangle(x, y, w, h) };
        }

        void Field(TextBox t, int x, int y)
        {
            t.SetBounds(x, y, 392, 26);
            t.BackColor = Art.Panel;
            t.ForeColor = Art.Ink;
            t.BorderStyle = BorderStyle.FixedSingle;
            Controls.Add(t);
        }

        async Task DoSignIn()
        {
            if (closeOnly) { DialogResult = DialogResult.Cancel; Close(); return; }
            if (busy) return;
            busy = true;
            go.Enabled = false;
            message.ForeColor = Art.Muted;
            message.Text = "Signing in...";
            try
            {
                SignInResult r = await signIn(user.Text, password.Text);
                if (r.Ok) { DialogResult = DialogResult.OK; Close(); return; }
                message.ForeColor = Art.Orange;
                message.Text = r.Message;
                if (r.NotTeam) { closeOnly = true; go.Text = "CLOSE"; }
            }
            catch (Exception ex)
            {
                message.ForeColor = Art.Orange;
                message.Text = "Could not sign in: " + ex.Message;
            }
            finally
            {
                busy = false;
                go.Enabled = true;
            }
        }
    }
}
