# Daily bug-report agent

Players file reports in-game (**Settings → Report a bug**, or the HUD button; `godot/game_ui/dm_bug_report_view.gd`). They land in the `bug_reports` table
(migration `029-bug-reports.sql`, routes in `backend/bug-reports.cjs`: 10 per account per day, 2,000 characters, client
context such as area/level/discipline/release and the last five uncaught client errors; with "Attach my game log" ticked, the end of the Godot log, crashed session first, stored as `context.log`).

`death-muffin-bug-agent.timer` runs `run-bug-agent.sh` every 2 minutes (owner 2026-10-10: reports are handled in near real time). A tick
with no `new` report exits at once and writes nothing; a lock keeps runs from overlapping (a report filed mid-run waits for the next tick).
A report that a run could not settle stays `new` and is retried; after 3 attempts it is set aside (`attempts.json` in the state dir) and
the owner is told once in #death-muffin.

1. `reports-cli.cjs list` reads up to 25 `new` reports (minus set-aside ones). None → stop (no agent run).
2. A fresh worktree `wt/bug-agent-<date>-<time>` on branch `bugfix/reports-<date>-<time>` is cut from `origin/main` (one per run).
3. Headless Claude (`claude -p`, Opus) gets `PROMPT.md` with the reports (log included) embedded as data. It fixes what it can confirm,
   one commit per report (`Bug report #<id>: …`), and writes a verdict per report.
4. The script re-runs the checks on the branch, applies the verdicts to the DB (players see the status and the
   `note`; `fixed` is downgraded to `triaged` if the branch is red), writes `~/death-muffin/bug-agent/runs/<date>.md`
   and posts the summary to the Discord release webhook. A branch with no commits is deleted.

**Discord.** Every post goes to `~/death-muffin/private/discord-deathmuffin-webhook.url` (the Death Muffin channel) when
that file exists, else to the older `discord-github-webhook.url` (MuffinCore alerts). Two kinds: the daily triage summary
(fixes on the branch, awaiting review) and, from `announce-release.sh` (run by every client publish and backend deploy), **"Player-reported bugs fixed — live now"** when a
release contains `Bug report #<id>: …` commits. That step also sets those reports to `released`, which players see
as *Fixed — live now*.

**Nothing ships on its own.** The owner (or a Claude session) reviews `bugfix/reports-<date>`, merges it and ships with
`publish-godot-client.sh` as usual.

## Why it is boxed in

Report text is written by players, so it is treated as untrusted input (prompt injection):

- `--restricted` (file tools confined to the worktree, user settings and MCP ignored), `--permission-mode dontAsk`, and an
  allowlist: Read/Edit/Write/Glob/Grep, `agit` (a few git verbs, no hooks, no flags that touch files outside the repo or
  stage everything) and `check.sh` (the Godot suites against the committed fixtures: quick by default, only the suites the change affects via `tools/godot/affected-suites.mjs`; `--full` runs every suite, 10 to 35 min; via `sandbox-lib.sh` in fresh user/network/mount namespaces: no network,
  whole filesystem read-only except the worktree).
- The agent never sees the database or `.env`; it cannot deploy or push. Verdicts are validated (ids from the batch,
  known statuses, capped notes) before they are written.
- The systemd unit runs with `ProtectHome=read-only` plus a short `ReadWritePaths` list.
- The tooling is installed to `~/death-muffin/bug-agent/` by `install.sh` from a committed revision, outside any checkout,
  so the agent cannot edit its own rules.

## Operate

```bash
server/death-muffin/bug-agent/install.sh [rev]          # install/update tooling + enable the timer
~/death-muffin/bug-agent/run-bug-agent.sh --dry-run    # show pending reports
sudo systemctl start death-muffin-bug-agent.service    # run now
journalctl -u death-muffin-bug-agent -n 100            # last run; full logs in ~/death-muffin/bug-agent/runs/
sudo mysql death_muffin -e "SELECT id,status,category,LEFT(message,80) FROM bug_reports ORDER BY id DESC LIMIT 20"
```
