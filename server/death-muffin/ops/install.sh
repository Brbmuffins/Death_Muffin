#!/usr/bin/env bash
# Install (or update) the Death Muffin ops jobs from a COMMITTED revision: scripts to ~/death-muffin/ops/ (outside every checkout),
# units to systemd, timers enabled. Does not run the jobs.   install.sh [rev]
set -euo pipefail
REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
REV="${1:-origin/main}"
DEST=/home/ubuntu/death-muffin/ops
SRC=server/death-muffin/ops
git -C "$REPO" fetch -q origin
mkdir -p "$DEST"
for f in backup-db.sh drift-report.sh launcher-release-notice.sh health-watch.mjs team-report.sh; do
  # the new copy keeps its extension (node only reads a .mjs file as a module) and must pass its syntax check, or the install stops here
  tmp="$DEST/.new.$f"
  git -C "$REPO" show "$REV:$SRC/$f" >"$tmp" && chmod 755 "$tmp"
  case "$f" in *.mjs) node --check "$tmp" ;; *) bash -n "$tmp" ;; esac || { rm -f "$tmp"; echo "install.sh: $f failed its syntax check; nothing installed for it" >&2; exit 1; }
  mv "$tmp" "$DEST/$f"
done
# the shared checkout's pre-push hook (no push to main while a Discord agent ship runs); hooks live in the common git dir, so every worktree has it
HOOKS="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/hooks"; mkdir -p "$HOOKS"
git -C "$REPO" show "$REV:$SRC/git-pre-push.sh" >"$HOOKS/pre-push.new" && chmod 755 "$HOOKS/pre-push.new" && bash -n "$HOOKS/pre-push.new" && mv "$HOOKS/pre-push.new" "$HOOKS/pre-push"
for u in death-muffin-db-backup.service death-muffin-db-backup.timer death-muffin-drift-report.service death-muffin-drift-report.timer death-muffin-launcher-notice.service death-muffin-launcher-notice.timer death-muffin-health-watch.service death-muffin-health-watch.timer death-muffin-team-report.service death-muffin-team-report.timer; do
  git -C "$REPO" show "$REV:$SRC/$u" | sudo tee "/etc/systemd/system/$u" >/dev/null
done
sudo systemctl daemon-reload
sudo systemctl enable --now death-muffin-db-backup.timer death-muffin-drift-report.timer death-muffin-launcher-notice.timer death-muffin-health-watch.timer death-muffin-team-report.timer
systemctl list-timers death-muffin-db-backup.timer death-muffin-drift-report.timer death-muffin-launcher-notice.timer death-muffin-health-watch.timer death-muffin-team-report.timer --no-pager
