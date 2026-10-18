# Ops: health watch, nightly DB backup, nightly drift report, launcher release notice, pre-push hook

Install or update both from a committed revision: `server/death-muffin/ops/install.sh [rev]` (copies the scripts to
`/home/ubuntu/death-muffin/ops/`, installs the units, enables the timers). Never edit the installed copies.

## Health watch (timer `death-muffin-health-watch`, every minute)

`health-watch.mjs` checks the live game every minute and posts to #build-alerts when something goes down and when it comes back:

| Check | What it reads |
|---|---|
| Game server | `http://127.0.0.1:5190/api/health`: `status` ok and `db` connected |
| Public API | `https://muffindevelopment.com/death-muffin/api/health` (through nginx and Cloudflare, what players' games reach) |
| Lobby | `http://127.0.0.1:5192/health`: `ok` |
| Co-op relay | `deathmuffin-relay` active and something listening on UDP 5193 |
| Game download | `https://muffindevelopment.com/death-muffin/client/manifest.json` has a `version` |

A check must fail twice in a row (two minutes) before it alerts, so a single blip stays quiet; while a service stays down a reminder goes
out every 60 minutes; the recovery is posted too. Several failures in one run go out as one post, which mentions nobody. The state is
`~/death-muffin/ops/state/health.json`, and it changes only after a post went out, so a failed post is retried on the next run. Its journal
lines (`journalctl -u death-muffin-health-watch`) appear only while a check fails or a post goes out. `node health-watch.mjs --dry-run`
prints what it would post and changes nothing; the env overrides are in the script's header (tests:
`server/death-muffin/ops/health-watch.test.cjs`). The test services (ports 5194 to 5196) are not watched: the drift report covers them.

## Nightly DB backup

`backup-db.sh` (timer `death-muffin-db-backup`, 04:30 UTC): verified gzip `mysqldump` of `death_muffin` to
`~/death-muffin/backups/db/daily/` (newest 14), plus the first dump of each week in `weekly/` (8) and each month in `monthly/` (12).
Restore: `gunzip -c <file> | sudo mysql <db>` (into a scratch DB first if unsure).

## Nightly drift report (timer `death-muffin-drift-report`, daily 05:00 UTC, after the 04:30 backup; full report in the journal, and a #build-alerts post only when something drifted)

`drift-report.sh` compares the Death Muffin deployment on this VPS with `origin/main` and lists leftovers. It is read-only: it never changes, deletes, restarts or pushes anything (it only runs `git fetch`).

```
server/death-muffin/ops/drift-report.sh              # plain-text report; exit 0 clean, 3 drift
server/death-muffin/ops/drift-report.sh --json       # machine output
server/death-muffin/ops/drift-report.sh --discord    # also post an embed to #build-alerts when there is drift (the nightly timer runs it this way)
server/death-muffin/ops/drift-report.sh --discord --always   # post even when clean
```

Env: `REPO` (default `/home/ubuntu/vps-handoffs/DeathMuffin/game`), `DM_HOME` (`~/death-muffin`), `WWW` (`/var/www/death-muffin`). The webhook URL is read from `~/death-muffin/private/discord-build-alerts-webhook.url` (#build-alerts; `WEBHOOK_FILE` overrides) and never printed.

| # | Check |
|---|---|
| 1 | Installed discord-agent files, art tools and systemd units vs the repo |
| 2 | Live backend, gathering, necro-progress and lobby code vs the repo. Comments and blank lines are ignored; comment-only differences are a soft note, not drift |
| 3 | Published client `rev` vs commits that change shipped game files (`client/` and `native/src/`, not tests, tools or docs) merged after it |
| 4 | Extra remote/local branches and worktrees. `discord/*` jobs are listed as info and flagged after 7 days |
| 5 | Uncommitted changes in the main checkout |
| 6 | Unexpected files in the public docroot (allowed: the `server/death-muffin/site/` files plus `client`, `play`, `preview`; `play/` only `index.html`, `patch-notes.json`, `release-notes.json`) and secret-ish names |
| 7 | Services active, auth `/health` |
| 8 | Disk over 85%, size of `wt/` and `deploy/` (`deploy/` over 2 GB is drift, with a breakdown), old `backup-pre-release-*` folders (never pruned) |
| 9 | Newest file in `~/death-muffin/backups/db/` missing or older than 36 h |

Any worktree you create (including for this report's own branch) shows up in check 4 until it is removed.

## Launcher release notice (timer `death-muffin-launcher-notice`, every 10 min)

`launcher-release-notice.sh` posts each new GitHub Release tagged `launcher-v<version>` (built by `.github/workflows/launcher-windows.yml`)
to #build-alerts once: the version's changelog line from `launcher/windows/README.md` on `origin/main` (else the release body) and the
zip's download link. Public GitHub API, no token; webhook `~/death-muffin/private/discord-build-alerts-webhook.url`. Announced tags are
kept in `~/death-muffin/ops/state/launcher-announced.txt` (the first run records the existing releases without posting). #build-alerts
gets only these and the shipped-release notices from `announce-release.sh`: the GitHub commit feed into it (a repo webhook sharing the
channel's old webhook) was cut on 2026-10-12 by replacing that webhook.

## Pre-push hook (`git-pre-push.sh`)

`install.sh` installs it as the shared checkout's `pre-push` hook (in the common git dir, so every worktree has it). It refuses a push to
`main` while a Discord agent ship is running (`~/death-muffin/discord-agent/state/ship-active` exists): main moving mid-ship stops that ship
("master-moved") and its approver has to ✅ again. Branch pushes pass. The agent's ship, runner and `agit` run git with hooks off, so they
are never blocked. Override once: `DM_ALLOW_PUSH_DURING_SHIP=1 git push ...`. The drift report checks the installed hook matches `main`.
