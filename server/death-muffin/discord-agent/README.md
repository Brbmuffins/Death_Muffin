# Death Muffin Discord dev agent

@mention the Muffin Core bot in `#death-muffin`, describe feedback or an idea, and it works it out in a thread: answers
questions from the code, or makes a change on its own branch, proves tests pass, and posts a short proposal. An approver's ✅
ships it. Nothing the AI says can ship, push or deploy.

```
Discord #death-muffin ── Muffin Core bot (user `muffin`, /opt/muffin/discord/{bot,dm-agent}.js)    dumb transport, no authority
        │  loopback HTTP + shared secret (x-dm-secret)         /event /bind  (bot -> runner),  /poll /ack (long-poll outbox)
        ▼
Runner (user `ubuntu`, ~/death-muffin/discord-agent/runner/server.cjs, port 4321)
   allow-list · approver gate · rate limits · audit.jsonl · job queue · tier classifier · proposal builder
   ├─ per request: git worktree + branch discord/<id> from origin/{baseBranch} (web=master, godot=godot-port), `claude -p` (sandboxed, --resume per thread)
   ├─ verify (runner code, not the AI): commits clean · no Co-Authored-By · forbidden paths · secret scan · generated files re-derived · check.sh or check-godot.sh · tier
   ├─ propose: push branch, embed with tier / files / tests / migrations / compare link, ✅ ❌
   └─ ship.sh (only after an approver's ✅): deploy lock · merge onto {baseBranch} · re-gate · re-test · push · deploy script · (web only: best effort) merge into `mobile`, test, push, deploy-mobile.sh
```

## Modes (`mode` and `baseBranch` in `config.json`, owner-edited)

One runner serves one game at a time. `mode: "web"` + `baseBranch: "master"` (the defaults) is the three.js game exactly as before. For the
Godot 4 client set both: `"mode": "godot", "baseBranch": "godot-port"` (a restart picks it up). `baseBranch` must match `^[A-Za-z0-9._/-]+$` (and
not start with `-`, contain `..`, `//`, end in `/` or `.lock`); a bad value or mode makes the runner refuse to start. Everything that used to say
"master" uses it: the worktree base (`origin/<baseBranch>`), `!sync`, the ship merge and push, user-facing messages, the compare link.

| | web | godot |
|---|---|---|
| tests (agent + runner + ship.sh) | `check.sh` | `check-godot.sh` |
| playable preview | `preview.sh`, a web page | `preview-godot.sh`, a Windows `.zip` |
| screenshots | `shot.sh` / `!shot` | `shot-godot.sh` / `!shot` (windows and tooltips on the offline demo hero; before/after on proposals; see Screenshots) |
| generated files (`regen.sh`) | verified, tier-neutral | not used: they classify by path (server/** = sensitive), `regen.sh` is not in allowedTools |
| prompt | `PROMPT.md` | `PROMPT-godot.md` (same safety/refusal and reply sections, verbatim) |
| tier rules | `tiers` | `godotTiers` (picked into `cfg.tiers` by `loadConfig`; a `tiers` override is ignored in godot mode) |
| ship | merge, check, push, `deploy-release.sh`, mobile step | merge, check-godot, backup + `ROLLBACK.sh`, push, `publish-godot-client.sh`; `MOBILE: skipped` |
| rollback folder | `backup-pre-release-<hex>-<stamp>` (deploy-release.sh) | `backup-pre-release-godot-<stamp>` (ship.sh) |

**`check-godot.sh`**: the same sandbox as `check.sh` (`unshare -rnm`, loopback only, whole filesystem read-only, only the worktree writable, scratch tmpfs over
`node_modules/.vite`), with `HOME` and the XDG dirs in a fresh `/tmp/dmgodot.*` (inside the sandbox's private /tmp) so Godot's `user://` never touches the real home. It runs
`tools/godot/gen-fixtures.sh` (the golden fixtures are gitignored and generated from the frozen TypeScript game with the worktree's symlinked
`node_modules`), then `tools/godot/run-all-tests.sh` (one line per suite; `GODOT` defaults to `/home/ubuntu/tools/godot/godot`). The generator
rewrites the committed `godot/data/loot/content.json` and `.git` is read-only, so that file is snapshotted first and restored before the suites run (and on
exit). It ends with `GODOT TESTS: <n> suites, <n> passed, <n> failed` (that line is the "Tests" field of the proposal), exits non-zero on any failing
suite or step, and has a hard 40 minute limit. A run on the current godot-port takes about 10 to 13 minutes (50 suites).

**`preview-godot.sh <jobid>`**: runner-only. Inside the same kind of sandbox it imports the project and exports the `Windows Desktop` preset from
`godot/` (the installed export templates are linked read-only into the fresh `XDG_DATA_HOME`). Outside, it zips `DeathMuffin.exe`, `DeathMuffin.pck`,
`Play Preview (offline).bat` (`DeathMuffin.exe -- --offline`) and a README ("PREVIEW of <title>, offline edition, nothing saves to your real
character") to `<previewRoot>/<jobid>/DeathMuffin-Preview-<jobid>-win64.zip` (mode 644, ~220 MB; job ids `^[0-9a-f]{6}$`, no symlinked root or destination,
nothing else is left in that folder). The proposal's "Try it (Windows download)" field and `!preview` link to the zip; it is deleted with the job like
any preview. The build takes about a minute, and the runner allows 40.

**Godot ship** (`ship.sh`, `MODE=godot`), in order: deploy lock; fetch; check `EXPECT_HEAD`; scratch worktree at `origin/$BASE_BRANCH`; ff or no-ff merge (same
conflict handling); ship gate on the merged diff with the godot tiers; `check-godot.sh` on the merged tree; **rollback preparation, before anything is
pushed**: read `rev` from the live client manifest (`clientManifest`, default `/var/www/death-muffin/client/manifest.json`; must be hex and in the repo,
else `RESULT: backup-failed` and nothing changes), create `<deployDir>/backup-pre-release-godot-<UTC stamp>/`, save a fresh `git show
origin/master:server/death-muffin/publish-godot-client.sh` there (that script lives on master only) and write `ROLLBACK.sh`, which runs that saved
copy with `REPO=<repo>` for the previous revision (no manifest = first publish = `Rollback: none`); push `HEAD:refs/heads/$BASE_BRANCH`; publish the new
SHA with the saved copy (`deployCmd` replaces it in tests); print `Rollback: <path>`, `RESULT: live <sha12> <path>`, `MOBILE: skipped`. The runner
accepts only exact `backup-pre-release-godot-<yyyymmddThhmmssZ>` real directories (no symlinks) with a `ROLLBACK.sh` in godot mode, and only the
hex-named ones in web mode.

## Who can do what (`config.json`, owner-edited, never by the AI)

- `ownerIds`: always requester + approver of every tier; pinged on every ship/rollback by someone else.
- `projects.deathmuffin.requesters`: may talk to it and give work. Everyone else is ignored (no reply, audited).
- `projects.deathmuffin.approvers.{casual,gameplay,sensitive}`: who may ✅ a proposal of that tier. Anyone in `sensitive` is a
  full approver (all tiers, any rollback, no daily cap, may switch models). Someone only in `casual` is limited
  (casual ships only, `casualShipsPerDay` cap, may roll back only their own latest ship).
- Currently: owner + Helix (142812688358178816) full; add friends as requesters only (they can never ship).
- A user id must be digits; anything else (placeholders) is dropped on load.

Tiers come from the diff's **files** (`runner/lib/tiers.cjs`, rules in `lib/config.cjs`), strictest file wins:
casual = CSS, docs/README, PATCH_NOTES, UI help text, item/ability names+descriptions (string-only edits), balance numbers
within ±25% of current (numeric-only edits); gameplay = other `src/**`; sensitive = `server/**`, migrations, auth/session/authority,
deploy scripts, package.json/lockfiles, configs, `.github`, `tools`, CLAUDE.md. In godot mode (`godotTiers`): casual = `docs/**`, `*.md`,
`godot/**/*.md`, PATCH_NOTES.json (any content); gameplay = the rest of `godot/**`; sensitive = server, launcher, tools, CI, scripts, deploy, config,
`project.godot`, `export_presets.cfg`, and the client's net/front(login)/backend code and anything named auth, session, online, save, offline,
progress_sync, coop, login, account, token, relay, lobby, realtime or mock_backend, plus native libraries, `addons/` and the net/relay/offline/realtime/
online_local/front test suites, and the progression/economy authority mirrors (anything named progression, authority, ledger, economy, spend, kill*, gold_sink, vault/labor/legion rules, milestone, reward, unlock, seal, tradeGoods; `rules/progression/`, `data/progression/`); anything unmatched (the frozen web `src/`, root files) is sensitive. `forbiddenPaths` also lists `godot/export_presets.cfg`. Paths that would change the agent itself,
deploy scripts or `.env*` are refused outright (`forbiddenPaths`). `ship.sh` re-derives the tier from the merged diff under
the deploy lock, so an approver can never ship above their tier.

## Chat commands (in the thread, handled by the runner, not the AI)
`!status` · `!shot` (screenshot of the change) · `!cancel` · `!discard` (or ❌) · `!sync` (merge the latest base branch, agent resolves conflicts) · `!model opus|sonnet|haiku`
(full approvers; "use opus" in a message works too) · `rollback` (mention in channel or thread): runs the newest deploy
backup's ROLLBACK.sh under the lock. Owner/full approvers any time, limited approvers only if their ship is the latest.
Rollback undoes the live release only; revert the commit on the base branch afterwards.

## Generated files and phones
- `regen.sh` (agent-runnable, sandboxed like check.sh) rebuilds the generated server bundles, `docs/LOOT-TABLES.md` and the embedded
  realtime deploy script. Those paths are tier-neutral (and not "forbidden") ONLY when the runner (`runner/lib/generated.cjs`, in verify
  and again in `ship-gate.cjs`) re-runs regen.sh in a scratch worktree and finds them byte-identical. Any difference = refused.
- After the PC deploy is live, ship.sh (still holding the lock) merges the new master into `mobile` in a scratch worktree, runs check.sh,
  pushes `mobile`, runs `deploy-mobile.sh` and prints `MOBILE: live <sha12>`; on a conflict / failing tests it leaves `mobile` untouched and
  prints `MOBILE: pending <reason>` (the PC release stays live; the owner is pinged). `mobileBranch: ""` turns it off; a missing
  `origin/mobile` prints `MOBILE: skipped`. Test hook: `mobileDeployCmd` (replaces deploy-mobile.sh).

## Safety summary
- **One shared sandbox** (`sandbox-lib.sh`, sourced inside `unshare -rnm` by `check.sh`, `check-godot.sh`, `preview.sh`, `preview-godot.sh`, `shot.sh`, `shot-godot.sh`, `regen.sh`):
  every mount in `/proc/self/mountinfo` is remounted read-only (not just `/home/ubuntu`: `ubuntu` also owns `/var/www/death-muffin` incl. the published
  client, `/opt/*`, `/game*`, `/var/log`), `/tmp` and `/dev/shm` are private tmpfs (the host's are invisible), and only the job's worktree is re-opened
  writable. The ro remounts are made by root of the outer user namespace, so the payload then runs in a NESTED user+mount namespace
  (`unshare -Um --map-current-user`, from `dm_sandbox_run`) where those mounts are locked: it cannot remount them rw, unmount `/tmp`, or `unshare` its way
  out; nothing AI-influenced runs before the nesting. It fails closed: a mount that cannot be made read-only, or a write probe that still succeeds on a read-only mount, aborts the run (exit 99).
  `test/sandbox.test.cjs` runs each real script with stand-in tools that try to write `/var/www/death-muffin/client`, `/opt/*`, `/game`, `/home/ubuntu`,
  a sibling worktree and the host `/tmp`, after trying to remount `/` and its parents rw, umount `/tmp` and `/dev/shm`, and unshare again. `/proc`, `/sys`, `/dev` stay as they are (kernel views, root-owned); `/dev/shm` is private.
- AI box: `claude -p --restricted --permission-mode dontAsk`, tools = Read/Edit/Write/Glob/Grep + `agit` (filtered git) +
  `check.sh` and `regen.sh` (godot mode: `check-godot.sh` and `shot-godot.sh`) (unshare -rnm: no network, home read-only except the worktree). No push, no deploy, no secrets in its env.
- Discord's 2000-character limit: agent replies are split across messages (code blocks kept balanced) and anything over ~4 messages is a preview plus `reply.md` (`runner/lib/discordText.cjs`). A long paste arrives as Discord's `message.txt`; the adapter reads text attachments from Discord's CDN only (≤100 KB each, ≤60,000 characters in all) into the person's message.
- Person text is wrapped as data (`<request from=… role=…>`, role from config); rules cannot be changed by messages.
- Runner redacts every outgoing string and audit field; mentions are disabled except the owner ping.
- Audit log: `state/audit.jsonl` (every request, proposal, approve/refuse, ship result, rollback); ships: `state/ships.jsonl`.
- ship + rollback + `deploy-release.sh` all take `~/death-muffin/deploy/.deploy.lock`.
- Residual risk: tests run **unsandboxed** inside `deploy-release.sh` on the merged tree. That is why test configs, package files and
  scripts are sensitive/forbidden, and why the proposal links the exact diff for a human to read before ✅.

## Parallel jobs and long checks

- `maxConcurrentJobs` (1-3, live: 3) lets several threads work at once, so one person's long request does not queue everyone else. Ships
  still go one at a time behind the deploy lock. Git commands that hit a lock file another job is holding retry a few times (gitops.cjs).
- The check scripts run 10-20 min. The agent's `claude -p` gets `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` and a 42-minute Bash limit
  (`BASH_DEFAULT_TIMEOUT_MS`/`BASH_MAX_TIMEOUT_MS`), so the check call simply blocks until it finishes. `sleep`, `pgrep`, `ps`, `watch` and the like are on
  `--disallowedTools`. Why: on 2026-10-08 Claude Code moved a long check-godot.sh run into the background, the agent wrote
  `until ! pgrep -f check-godot.sh; do sleep 5; done`, pgrep matched the loop itself, and job e4388b hung for 35 minutes while every other thread waited.

## Install (from a committed revision; nothing starts by itself)
1. `bash server/death-muffin/discord-agent/install-runner.sh <rev>`: tooling to `~/death-muffin/discord-agent`, `config.json` (owner id from
   `/opt/crossworlds-bot/.env`), `secret`, systemd unit (not started).
2. `bash install-bot.sh <rev>` (sudo): `/opt/muffin/discord/dm-agent.js`, patched `bot.js` (backup kept), `/opt/muffin/dm-agent.env`.
3. `sudo systemctl enable --now death-muffin-discord-agent`, then `sudo systemctl restart muffin-discord`.

Tests (not wired into test:server; ~1 min, needs git and `unshare`/`zip`/`unzip`): `node --test server/death-muffin/discord-agent/test/*.test.cjs`.
The installer also copies `check-godot.sh`, `preview-godot.sh`, `shot-godot.sh`, `label-shot.py` and `PROMPT-godot.md`. To switch the live runner to Godot mode, edit `config.json` (`mode`, `baseBranch`), then restart the service.

## Screenshots
Web mode: the agent can look at its own change: it writes a scenario (`.dm-shot.json`) and runs `shot.sh` (`shoot.cjs` documents the format; dev server + headless Chromium in a no-network sandbox, ~1 min, one at a time). PNGs land in `<worktree>/.dm-shots/`, which together with `.dm-shot.json` is git-excluded (`createWorktree`), so they never dirty the tree or get committed.
- On demand: ask in the thread ("show me what it looks like") or use `!shot` (any requester; queues a turn that takes one).
- After every turn the runner posts new or changed PNGs to the thread (max 4, skips files over 8 MB with a note, each unchanged file once).
- A proposal attaches the current PNGs (newest first, max 4) and shows the first one as the embed image, next to ✅/❌.
- Transport: outbox ops carry `files: [{name, b64}]` (never redacted, names sanitized); the adapter sends them as Discord attachments. Existing job worktrees keep their old `info/exclude` until the next job is created (it is a shared file).

### Godot mode
`shot-godot.sh [plan.json]` (default `.dm-shot.json`; format in `godot/main/qa_ui_shots.gd` and `PROMPT-godot.md`: up to 4 shots of windows/tooltips, `open` / `hover` / `area` / `clip` / `give`) renders the branch's own client on the offline demo hero with a fixed
representative bag. Same sandbox as `check-godot.sh` (no network, read-only filesystem, only the worktree writable, private `/tmp` and a fresh HOME); inside it imports the project if `godot/.godot` is missing
(first run in a fresh worktree, about a minute), then `xvfb-run godot --rendering-driver opengl3 -- --offline --world-demo --qa --shot-plan=... --shots=<worktree>/.dm-shots/.raw`. It takes the shared `qa-browser.lock` (one renderer on the VPS) and has a hard 15 minute limit
(a run takes 1 to 5 minutes depending on load; it prints `render: cpu=.. wall=..`).
The label is burned in OUTSIDE the sandbox by `label-shot.py` (trusted code; Pillow): every raw PNG becomes `.dm-shots/<name>.png` with "BRANCH PREVIEW · not live · <branch>"; directory fds + `O_NOFOLLOW`, only real PNGs
under 12 MB, names `[a-z0-9-]{1,40}.png`; anything else is skipped (exit 3) and nothing unlabelled is ever published, so a branch that edits the QA code cannot drop the label.
The Godot side lives in the game repo (`godot/main/qa_ui_shots.gd`, inactive without `--qa`): **the branch the agent works on must contain it, i.e. it has to be merged into `godot-port` first**.
The agent is told (PROMPT-godot.md) to take pictures by default for visible changes (UI, windows, tooltips, HUD, visuals) and to skip them for logic/data/server work and pure Q&A.
On a proposal (`propose()`), when the agent left a plan and fresh pictures, the runner renders the same plan on an unchanged scratch worktree of the base (`base-<jobid>`, removed afterwards) and attaches
before/after pairs for the first two pictures (`before-<name>.png`, then `<name>.png`; the embed image is the first AFTER, plus a "Pictures" field). If the base cannot render (for instance it predates the QA shot-plan code) the proposal carries the AFTER pictures only.

## Playable preview (web; godot mode: see Modes)
Each proposal gets a "Try it" link: `https://muffindevelopment.com/death-muffin/preview/<jobid>/`, the branch's OFFLINE EDITION build (its own in-browser store and token key, so it cannot touch the live server or a real character).
- `preview.sh <jobid>` is run by the runner (never the AI, not in its allowedTools) from the job's worktree. Build: same sandbox as `check.sh` (no network, home read-only, scratch tmpfs over `node_modules/.vite`), `VITE_OFFLINE_BUILD=1`, base `<previewUrl path>/<jobid>/`, output `.dm-preview/` (git-excluded). The service-worker/PWA step is skipped on purpose, so a preview cannot interfere with `/play/` or `/offline/`.
- Publish (outside the sandbox): a "PREVIEW of <title>" banner is inserted into `index.html`, then rsync `--delete --link-dest=<live offline dir>` to `<previewRoot>/<jobid>/`. Job ids must match `^[0-9a-f]{6}$`; nothing outside that directory is written. `previewRoot` (default `/var/www/death-muffin/preview`, must exist and be writable by the runner user) and `previewUrl` are in config; `previewCmd` replaces the script (tests).
- Built in `propose()` before the embed is posted (typing indicator keeps running; 15 min cap). Success adds a "Try it" field; failure adds "Preview build failed" with a short reason and the proposal is posted anyway. `!preview` rebuilds it on an open proposal.
- The preview directory is deleted when the job ships, is discarded or is swept (`removeJobArtifacts`).

## Images from people
The adapter downloads image attachments (png/jpg/webp/gif, Discord CDN only, <= 8 MB each, <= 4 per message) and sends them to the runner as `images: [{name, b64}]` in the `/event` body; anything refused stays in the "not visible to the agent" note with the reason. The runner checks the bytes look like an image and writes them to `<worktree>/.dm-inbox/<msgId>-<name>` (git-excluded), appending `[image attached by NAME: .dm-inbox/... — Read it to see it]` to that message so the agent can `Read` it; for a new @mention the files are written in `bind()` once the worktree exists. A job keeps at most 40 MB of images (`job.inboxBytes`), then refuses with a note. Image bytes are never redacted or logged. `/event` accepts bodies up to 48 MB (4 x 8 MB as base64 is about 43 MB); every other route keeps the 1 MB cap.

## Rounds (one thread, many changes)
A thread no longer closes when its change ships (or is discarded, or swept after 7 idle days). The next message from an allowed requester starts a new ROUND in the same job record: a fresh branch `discord/<jobid>-<n>` and worktree cut from the current `origin/master`, proposal/shots/preview state reset, the claude session id kept (the runner also copies the session file into the new worktree's claude project dir, and falls back to a fresh session if it cannot be resumed), and the first prompt starts with a note that the earlier change is live. `job.history` records `{round, branch, shipSha | discarded, at}` and the audit log gets a `round` entry.
- A message sent while a ship is running is kept (shown as waiting). If the ship goes live, the next round starts at once and the message is processed there (attached images are carried over); if the ship fails, the job returns to idle/proposed and the message is handled on the same branch.
- Turns: `maxTurnsPerJob` (40) now counts per round; `maxTurnsPerThread` (120) is a hard cap over the whole thread.
- After a sweep a new message also starts a new round (the sweep only released the worktree; the thread and its context are still useful). Commands other than `!status` answer "nothing is open" in a closed thread.

## Deleted threads
The adapter forwards discord.js `threadDelete` for threads under the configured channel as `{type: 'thread-deleted', threadId, ...}`. The runner removes the job's worktree, local + remote branch and preview dir at once, sets `status: 'deleted'` (history `{deleted: true}`, audit `thread-deleted`) and posts nothing to that thread again (queued outbox ops are dropped). A running step is cancelled and cleaned up when it unwinds; a ship in progress is never interrupted: it finishes, then the cleanup runs and queued messages do not start a round. A deleted job ignores all further events and is skipped by the sweep.
