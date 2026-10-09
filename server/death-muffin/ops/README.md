# Ops: weekly drift report

`drift-report.sh` compares the Death Muffin deployment on this VPS with `origin/main` and lists leftovers. It is read-only: it never changes, deletes, restarts or pushes anything (it only runs `git fetch`).

```
server/death-muffin/ops/drift-report.sh              # plain-text report; exit 0 clean, 3 drift
server/death-muffin/ops/drift-report.sh --json       # machine output
server/death-muffin/ops/drift-report.sh --discord    # also post an embed when there is drift
server/death-muffin/ops/drift-report.sh --discord --always   # post even when clean
```

Env: `REPO` (default `/home/ubuntu/vps-handoffs/DeathMuffin/game`), `DM_HOME` (`~/death-muffin`), `WWW` (`/var/www/death-muffin`). The webhook URL is read from `~/death-muffin/private/discord-deathmuffin-webhook.url` and never printed.

| # | Check |
|---|---|
| 1 | Installed discord-agent and bug-agent files, art tools and systemd units vs the repo |
| 2 | Live backend, gathering, necro-progress and lobby code vs the repo. Comments and blank lines are ignored; comment-only differences are a soft note, not drift |
| 3 | Published client `rev` vs commits touching `godot/` merged after it |
| 4 | Extra remote/local branches and worktrees. `discord/*` jobs are listed as info and flagged after 7 days; `bugfix/reports-*` after 3 days |
| 5 | Uncommitted changes in the main checkout |
| 6 | Unexpected files in the public docroot (allowed: the `server/death-muffin/site/` files plus `client`, `play`, `preview`; `play/` only `index.html`, `patch-notes.json`, `release-notes.json`) and secret-ish names |
| 7 | Services active, bug-agent timer enabled, auth `/health` |
| 8 | Disk over 85%, size of `wt/` and `deploy/`, old `backup-pre-release-*` folders (never pruned) |
| 9 | Newest file in `~/death-muffin/backups/db/` missing or older than 36 h |

To run weekly, use a systemd timer or cron calling it with `--discord`. Any worktree you create (including for this report's own branch) shows up in check 4 until it is removed.
