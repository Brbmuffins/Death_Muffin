using System;
using System.Collections.Generic;
using System.Drawing;
using System.Text;
using System.Windows.Forms;

namespace DeathMuffinLauncher
{
    /// <summary>Every release's player notes, shown inside the launcher (read from play/patch-notes.json), so no browser is needed.</summary>
    internal sealed class PatchNotesWindow : Form
    {
        readonly TextBox body = new TextBox
        {
            Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None,
            Dock = DockStyle.Fill, WordWrap = true, BackColor = Color.FromArgb(14, 17, 31), ForeColor = Art.Ink, Font = new Font("Segoe UI", 10f),
        };

        public PatchNotesWindow()
        {
            Text = "Death Muffin - Patch notes";
            Icon = LauncherForm.AppIcon;
            BackColor = Art.Bg;
            ClientSize = new Size(640, 640);
            MinimumSize = new Size(420, 320);
            StartPosition = FormStartPosition.CenterParent;
            Padding = new Padding(16);
            body.Text = "Loading patch notes...";
            Controls.Add(body);
            Shown += async (s, e) => await LoadAsync();
        }

        async System.Threading.Tasks.Task LoadAsync()
        {
            List<ReleaseNotes> all = await Updates.FetchAllNotesAsync();
            if (IsDisposed) return;
            if (all == null || all.Count == 0)
            {
                body.Text = all == null ? "Could not load patch notes. Check your internet connection and try again." : "No patch notes have been published yet.";
                return;
            }
            var sb = new StringBuilder();
            foreach (var r in all)
            {
                string d = Updates.FriendlyDate(r.Date);
                sb.Append((r.Title.Length > 0 ? r.Title : "Release").ToUpperInvariant());
                if (d.Length > 0) sb.Append("  -  ").Append(d);
                sb.Append("\r\n\r\n");
                foreach (string it in r.Items) sb.Append("• ").Append(it).Append("\r\n\r\n");
                sb.Append("\r\n");
            }
            body.Text = sb.ToString();
            body.SelectionStart = 0;
            body.SelectionLength = 0;
        }
    }
}
