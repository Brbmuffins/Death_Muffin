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
   ├─ per request: git worktree + branch discord/<id> from origin/{baseBranch} (`main`), `claude -p` (sandboxed, --resume per thread)
   ├─ verify (runner code, not the AI): commits clean · no Co-Authored-By · forbidden paths · secret scan · generated files re-derived · check-godot.sh · tier
   ├─ propose: push branch, embed with tier / files / tests / migrations / compare link, ✅ ❌
   └─ ship.sh (only after an approver's ✅): deploy lock · merge onto {baseBranch} · re-gate · re-test · push · publish-godot-client.sh
```

## Mode and branch (`mode` and `baseBranch` in `config.json`, owner-edited)

The live config must say `"mode": "godot", "baseBranch": "main"` (a restart picks changes up). Set both keys explicitly: the runner code still has a
retired web mode and defaults to `mode: "web"`, `baseBranch: "master"`. `baseBranch` must match `^[A-Za-z0-9._/-]+$` (not start with `-`, contain `..`, `//`, end in `/` or `.lock`);
a bad value or mode makes the runner refuse to start. It is used for the worktree base (`origin/<baseBranch>`), `!sync`, the ship merge and push, messages and the compare link.

In godot mode: tests `check-godot.sh` (agent, runner and ship.sh) · preview `preview-godot.sh` (a Windows `.zip`) · screenshots `shot-godot.sh` / `!shot`
· prompt `PROMPT-godot.md` · tier rules `godotTiers` (picked into `cfg.tiers` by `loadConfig`) · ship: merge, check-godot, backup + `ROLLBACK.sh`, push,
`publish-godot-client.sh` · rollback folder `backup-pre-release-godot-<stamp>`.

**Progress notes** while a turn runs: `🔧 <pct>% · <sentence> · ⏱ <min> min`. The agent writes `.dm-status` as `<pct>% · <sentence>` (prompt
`PROMPT-godot.md`); a new status posts at once (at most every 3 min), otherwise a note every 5 min. While `check-godot.sh` runs it keeps
`<done> <total>` suites in `.dm-check-progress`, and the note's percentage moves from the agent's number toward 95% (`progressNote` in
`runner/core.cjs`). Both files are git-ignored. Model generation posts `🎨 Still generating "<id>"` with the minutes instead.
The auth backend (`deploy-release.sh`) is not part of a ship; the owner runs it. The web-mode scripts in this folder (`check.sh`, `preview.sh`, `shot.sh`, `regen.sh`) are unused.

**`check-godot.sh`**: the same sandbox as `check.sh` (`unshare -rnm`, loopback only, whole filesystem read-only, only the worktree writable, scratch tmpfs over
`node_modules/.vite`), with `HOME` and the XDG dirs in a fresh `/tmp/dmgodot.*` (inside the sandbox's private /tmp) so Godot's `user://` never touches the real home. It runs
`tools/godot/gen-fixtures.sh` only if the revision still has it (golden fixtures are committed on `main`), then `tools/godot/run-all-tests.sh` (one line per suite; `GODOT` defaults to `/home/ubuntu/tools/godot/godot`). The committed `godot/data/loot/content.json` is snapshotted and restored around the generator. While the suites run it writes `<done> <total>` to `.dm-check-progress` in the worktree (removed at the end) for the progress notes. It has two modes. **Quick** (default; the agent in its turn and the runner before a proposal): `tools/godot/affected-suites.mjs` picks the suites for the change (changed suite dirs; suites referencing a changed file by `res://` path or `class_name`, one level through non-test dependents; for changed `godot/data` files the scripts that load them, by path or DmDb accessor; plus a smoke set `data status session_report next next_front`, about 90 s) and `run-all-tests.sh --only <list>` runs them. It prints `ALL` (every suite) for central changes (`project.godot`, `export_presets.cfg`, autoloads, `godot/rules/core`, `godot/net`, `godot/session`, `godot/tests/common`, `tools/godot/*`), more than 40 changed `.gd` files, or more than 60% of suites selected; nothing for docs-only; a revision without the selector or `--only` also runs everything. **`--full`** (`ship.sh` always passes it) runs every suite, about 9 minutes (6 at once, fewer when the machine is busy; a suite that fails in the pool is retried alone). `DM_TEST_JOBS=N` adds `--jobs N`. The progress total is the number of selected suites. It ends with `GODOT TESTS: quick (14 suites) — 14 passed` or `GODOT TESTS: full (101 suites) — 101 passed` (`, N FAILED` on failure; `targeting fell back to all` is noted); the proposal's "Tests" field reads `quick check: N suites — ...; full suite runs at ship`. It exits non-zero on any failing
suite or step, and has a hard 85 minute limit. Before the suites it runs the repo hygiene check (`tools/hygiene/check.mjs`, the same `npm run hygiene` CI runs), so a proposal or ship with a stale doc link, missing path or retired term fails with `GODOT TESTS: repo hygiene FAILED`. A change that only touches Markdown files still gets the hygiene check but skips the suites (`GODOT TESTS: skipped, docs-only change`).

**`preview-godot.sh <jobid>`**: runner-only. Inside the same kind of sandbox it imports the project and exports the `Windows Desktop` preset from
`godot/` (the installed export templates are linked read-only into the fresh `XDG_DATA_HOME`). Outside, it zips `DeathMuffin.exe`, `DeathMuffin.pck`,
`Play Preview (offline).bat` (starts `-- --dev-offline`) and a README ("nothing saves to your real character") to `<previewRoot>/<jobid>/DeathMuffin-Preview-<jobid>-win64.zip` (mode 644, ~220 MB; job ids `^[0-9a-f]{6}$`, no symlinked root or destination,
nothing else is left in that folder). The proposal's "Try it (Windows download)" field and `!preview` link to the zip; it is deleted with the job like
any preview. The build takes about a minute, and the runner allows 40.

**Godot ship** (`ship.sh`, `MODE=godot`), in order: deploy lock; fetch; check `EXPECT_HEAD`; scratch worktree at `origin/$BASE_BRANCH`; ff or no-ff merge (same
conflict handling); ship gate on the merged diff with the godot tiers; `check-godot.sh` on the merged tree; **rollback preparation, before anything is
pushed**: read `rev` from the live client manifest (`clientManifest`, default `/var/www/death-muffin/client/manifest.json`; must be hex and in the repo,
else `RESULT: backup-failed` and nothing changes), create `<deployDir>/backup-pre-release-godot-<UTC stamp>/`, save a fresh `git show
origin/main:server/death-muffin/publish-godot-client.sh` there (a copy from `origin/main`, whatever `baseBranch` is) and write `ROLLBACK.sh`, which runs that saved
copy with `REPO=<repo>` for the previous revision (no manifest = first publish = `Rollback: none`); push `HEAD:refs/heads/$BASE_BRANCH`; publish the new
SHA with the saved copy (`deployCmd` replaces it in tests); print `Rollback: <path>`, `RESULT: live <sha12> <path>`. The runner
accepts only exact `backup-pre-release-godot-<yyyymmddThhmmssZ>` real directories (no symlinks) with a `ROLLBACK.sh`.

## Who can do what (`config.json`, owner-edited, never by the AI)

- `ownerIds`: always requester + approver of every tier; pinged on every ship/rollback by someone else.
- `projects.deathmuffin.requesters`: may talk to it and give work. Everyone else is ignored (no reply, audited).
- `projects.deathmuffin.approvers.{casual,gameplay,sensitive}`: who may ✅ a proposal of that tier. Anyone in `sensitive` is a
  full approver (all tiers, any rollback, no daily cap, may switch models). Someone only in `casual` is limited
  (casual ships only, `casualShipsPerDay` cap, may roll back only their own latest ship).
- Currently: owner + Helix (142812688358178816) full; add friends as requesters only (they can never ship).
- A user id must be digits; anything else (placeholders) is dropped on load.

Tiers come from the diff's **files** (`runner/lib/tiers.cjs`, rules in `lib/config.cjs`), strictest file wins:
Tiers (godot mode, `godotTiers`): casual = `docs/**`, `*.md`,
`godot/**/*.md`, PATCH_NOTES.json (any content); gameplay = the rest of `godot/**`; sensitive = server, launcher, tools, CI, scripts, deploy, config,
`project.godot`, `export_presets.cfg`, and the client's net/front(login)/backend code and anything named auth, session, online, save, offline,
progress_sync, coop, login, account, token, relay, lobby, realtime or mock_backend, plus native libraries, `addons/` and the net/relay/offline/realtime/
online_local/front test suites, and the progression/economy authority mirrors (anything named progression, authority, ledger, economy, spend, kill*, gold_sink, vault/labor/legion rules, milestone, reward, unlock, seal, tradeGoods; `rules/progression/`, `data/progression/`); anything unmatched (root files) is sensitive. `forbiddenPaths` also lists `godot/export_presets.cfg`. Paths that would change the agent itself,
deploy scripts or `.env*` are refused outright (`forbiddenPaths`). `ship.sh` re-derives the tier from the merged diff under
the deploy lock, so an approver can never ship above their tier.

One ship at a time. A ✅ while another ship runs queues the proposal (the thread says how many are ahead) and it ships by
itself when its turn comes, in approval order (`job.shipQueued` in jobs.json, so the queue survives a runner restart). When its turn comes
the runner re-checks it: a proposal that moved on (new round or head), an approver who lost the tier, or a casual approver's daily cap
drops it from the queue with a note in the thread.

## Chat commands (in the thread, handled by the runner, not the AI)
`!status` · `!credits` (your model-generation budget) · `!shot` (screenshot of the change) · `!cancel` · `!discard` (or ❌) · `!sync` (merge the latest base branch, agent resolves conflicts) · `!model opus|sonnet|haiku`
(full approvers; "use opus" in a message works too) · `rollback` (mention in channel or thread): runs the newest deploy
backup's ROLLBACK.sh under the lock. Owner/full approvers any time, limited approvers only if their ship is the latest.

`!cancel` (or a bare `stop` / `cancel` while something runs; requester or owner; a near-miss such as `cencel` or `stpo` gets "Did you mean !cancel?" and is not passed to the agent) stops the current step, agent turn or the runner's own check run,
killing the whole process tree (Claude's Bash tool and `timeout` start their own process groups, so a group kill alone orphaned test runs).
Messages queued before it are dropped, and no review or repair turn follows; the branch and worktree stay, and the next message continues.
A ship cannot be cancelled. An idle job is closed by the sweep after 7 days without activity.
A reply to an open proposal that changes nothing (a thank-you, a question) is answered, and the proposal stays as it is: same commit and clean
workspace means no new checks, preview or re-post (`proposal-kept` in the audit log), and ✅ works right away. The prompt also tells the agent not to
run `check-godot.sh` for such messages.
Rollback undoes the live release only; revert the commit on the base branch afterwards.

## Safety summary
- **One shared sandbox** (`sandbox-lib.sh`, sourced inside `unshare -rnm` by `check-godot.sh`, `preview-godot.sh` and `shot-godot.sh`):
  every mount in `/proc/self/mountinfo` is remounted read-only (not just `/home/ubuntu`: `ubuntu` also owns `/var/www/death-muffin` incl. the published
  client, `/opt/*`, `/game*`, `/var/log`), `/tmp` and `/dev/shm` are private tmpfs (the host's are invisible), and only the job's worktree is re-opened
  writable. The ro remounts are made by root of the outer user namespace, so the payload then runs in a NESTED user+mount namespace
  (`unshare -Um --map-current-user`, from `dm_sandbox_run`) where those mounts are locked: it cannot remount them rw, unmount `/tmp`, or `unshare` its way
  out; nothing AI-influenced runs before the nesting. It fails closed: a mount that cannot be made read-only, or a write probe that still succeeds on a read-only mount, aborts the run (exit 99).
  `test/sandbox.test.cjs` runs each real script with stand-in tools that try to write `/var/www/death-muffin/client`, `/opt/*`, `/game`, `/home/ubuntu`,
  a sibling worktree and the host `/tmp`, after trying to remount `/` and its parents rw, umount `/tmp` and `/dev/shm`, and unshare again. `/proc`, `/sys`, `/dev` stay as they are (kernel views, root-owned); `/dev/shm` is private.
- AI box: `claude -p --restricted --permission-mode dontAsk`, tools = Read/Edit/Write/Glob/Grep + `agit` (filtered git) +
  `check-godot.sh` and `shot-godot.sh` (unshare -rnm: no network, home read-only except the worktree). No push, no deploy, no secrets in its env.
- Discord's 2000-character limit: agent replies are split across messages (code blocks kept balanced) and anything over ~4 messages is a preview plus `reply.md` (`runner/lib/discordText.cjs`). A long paste arrives as Discord's `message.txt`; the adapter reads text attachments from Discord's CDN only (≤100 KB each, ≤60,000 characters in all) into the person's message.
- Person text is wrapped as data (`<request from=… role=…>`, role from config); rules cannot be changed by messages.
- Runner redacts every outgoing string and audit field; mentions are disabled except the owner ping.
- Audit log: `state/audit.jsonl` (every request, proposal, approve/refuse, ship result, rollback); ships: `state/ships.jsonl`.
- ship + rollback + `deploy-release.sh` all take `~/death-muffin/deploy/.deploy.lock`.
- Residual risk: `ship.sh` re-runs `check-godot.sh` on the merged tree in the same sandbox, but `publish-godot-client.sh` exports the project outside it. That is why test configs, package files and
  scripts are sensitive/forbidden, and why the proposal links the exact diff for a human to read before ✅.

## Parallel jobs and long checks

- `maxConcurrentJobs` (1-3, live: 3) lets several threads work at once, so one person's long request does not queue everyone else. Ships
  still go one at a time behind the deploy lock. Git commands that hit a lock file another job is holding retry a few times (gitops.cjs).
- The full check runs about 9 min (suites in parallel) (ship only; proposals and the agent get the quick check, a few minutes). The agent's `claude -p` gets `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` and a 55-minute Bash limit (turn limit 60 min, check-godot.sh hard limit 85 min)
  (`BASH_DEFAULT_TIMEOUT_MS`/`BASH_MAX_TIMEOUT_MS`), so the check call simply blocks until it finishes. `sleep`, `pgrep`, `ps`, `watch` and the like are on
  `--disallowedTools`. Why: a backgrounded check plus an agent-written `pgrep` wait loop matched itself and hung a job (and the queue) for 35 minutes.

## When the client publish fails

- ship.sh tries `publish-godot-client.sh` 3 times (30 s, 90 s apart) before giving up: a one-off Godot crash heals inside the ship.
- Still failing: the merge is already on the base branch, only the client is missing. The thread says so (the job stays usable), the owner is
  pinged, and the runner retries by itself after `publishAutoRetryMin` (10). Approvers can retry any time: ✅ on the failure message or `!retry`.
  A retry is `PUBLISH_ONLY=1 PUBLISH_SHA=<sha> ship.sh`: same lock and fresh rollback, no merge/tests/push, and it refuses to publish anything older
  than the live client (`RESULT: live-already`). Any later ship whose client contains the stuck commit posts "Live" in that thread too.
  When the release goes live that way (retry or a later ship), the job ends like a normal ship (`shipped`, ✅ title, worktree, branch and preview
  removed) if the thread has not moved on: idle, nothing queued or proposed, and a clean workspace whose HEAD is inside the published release.
  A thread that already works on its next change keeps its workspace (the sweep closes it later).

## New models (Gemini concept -> Tripo), approval-gated and credit-capped

Someone asks in a thread for a new character, creature, boss or prop. The agent never holds a key and cannot call an API; it writes SPECS, the runner does the spending after an approver's check.

```
agent turn ── writes art-manifest/gemini-jobs/<id>.json (one concept job) + art-manifest/tripo-specs/<id>.json (generation / rig / animations) + .dm-art-request.json {id, note}
runner     ── validates against allow-lists (below), prices it, posts the request:   New character: warlock
              Will be generated: Concept image (Gemini) -> 3D model (Tripo, up to 7000 faces, detailed textures) -> rig (biped) -> 6 animations: idle, walk, ...
              Estimated cost: up to 145 credits (image to model 60 + rig 25 + 6 animations x 10)      Helix's budget: 1000 of 1000 left -> 855 after this      Tripo balance now: 3910
              ✅ spend the credits (the owner / Helix / warbogar) · ❌ cancel · nothing is spent until a ✅
approver ✅ ── owner or any full approver (self-approval allowed, like code ships). Re-checked live: estimate <= requester's remaining budget AND <= Tripo balance, else "Not started"
runner     ── art-run.sh in the job's worktree: flock -> balance before -> gemini.mjs -> tripo.mjs run --yes -> balance after.  Posts the concept + Tripo's preview image and the REAL spend
agent turn ── told the files are ready: build-art.sh <id> (sandboxed: tools/build-characters.mjs, then dequantize into godot/assets/slice/models/...), commits specs + records + GLB,
              check-godot.sh (adds .import/textures), wires the model in where asked, PATCH_NOTES, then the usual proposal / ✅ ship (art files make it a sensitive-tier proposal: full approvers only)
```
- **Keys never enter the agent.** `art-run.sh` gets `TRIPO_API_KEY` / `GEMINI_API_KEY` in its own environment only (read by the runner from `<repo>/.ai-keys.local`, `artKeysFile`); they are never written, logged or committed, every posted line goes through `redact.cjs` (the key values are registered as known secrets, plus `tsk_` / `AIza` / `AQ.` patterns), and `sandbox-lib.sh` binds `/dev/null` over `.ai-keys.local` and the runner `secret` inside every sandbox (check / shot / preview / build-art), so even a test script cannot read them. `agentEnv()` has no keys and `art-run.sh` is not in the agent's allowed tools.
- **Trusted tools.** The runner runs COPIES of `tools/ai/{common,gemini,tripo}.mjs` installed to `art-tools/` (with their own copy of `sharp`), pointed at the worktree with `DM_ART_ROOT`. The worktree's own `tools/` and `node_modules` (which the agent can edit) are never executed by a process that holds keys.
- **What runs is what was approved.** The validated canonical specs are stored in the job record at request time; at ✅ the runner rewrites the spec files from that copy (an agent edit after the offer changes nothing) and re-checks that no path the tools write to is a symlink.
- **Validation (`runner/lib/art.cjs`)**: id `[a-z0-9_]{3,40}` and not an existing model; no extra fields anywhere; `input`/`out` exactly `art-src/concepts/<id>.png`; model `P1-20260311`; `face_limit` integer 300-14000; texture `standard|detailed`; rig `biped` (`v1.0-20240301`) or `quadruped` (`v2.5-20260210`, `preset:quadruped:walk` only); at most 10 distinct known presets, `animationMode: single`; rig <=> id not starting `prop_`; Gemini `aspect`/`size`/`model`/`post.{resize,format}` limited, up to 3 refs that are `art-src/concepts/*.png` real images or reference sheets committed at the repo root. A bad request goes back to the agent to fix (twice), then is dropped. Anything over 400 estimated credits is refused whatever the budget.
- **Estimate** = the highest credits ever charged per step type in the base branch's `art-manifest/tripo/*.json` (read from git, not the worktree), never below the measured floors (model 60, rig 25, clip 10; rig-check is free). Typical: prop 60 (50 with standard textures), rigged character with 6 clips 145, bone_golem-sized 9 clips 175.
- **Budgets**: `tripo-budget.json` (next to `config.json`, mode 600, owner-edited, read fresh on every use): `{"<discord id>": <credits>}`. Unlisted users, bad values and negatives = 0 -> "has no model-generation budget", nothing offered. The owner is not exempt. `!credits` shows your numbers. Remaining = budget - the sum of ACTUAL credits in the ledger.
- **Ledger**: `tripo-ledger.json` (same folder, mode 600, outside every repo): one entry per run `{id, ts, userId, userName, jobId, specId, estimate, approverId, status started|done|failed|interrupted, credits, balanceBefore, balanceAfter, result, note, finishedAt}`. The `started` entry is written BEFORE anything is spent; credits are balance-before minus balance-after (a run that fails midway still records what it spent; a killed run is read from a fresh balance; if the balance cannot be read the estimate is charged). If the runner itself dies mid-run, the next start closes the open entry from the balance delta (`interrupted`).
- **One run at a time**: an in-process flag plus `flock` on `state/tripo.lock` inside `art-run.sh` (a second run gives up as `busy` without touching the account). Tripo's own resume (`state.json` in `art-src/tripo/<id>/`) means a retry never pays twice: after a failure the thread gets a fresh request (same estimate, updated budget) and a ✅ resumes.
- **Never without a ✅ / never unapproved**: nothing is spent at request time; only `isFull` approvers' ✅ on that exact request message starts it (others' reactions are removed); `!discard`/❌ clears a pending request; a thread that is running, shipping or generating turns a ✅ away. Audit events: `art-offered`, `art-approve-attempt`, `art-approved`, `art-approve-refused`, `art-refused`, `art-start`, `art-result`, `art-cancelled`, `art-invalid`, `art-reconciled`.
- Config keys (all optional, defaults shown; `config.json` is not edited): `artKeysFile` (`<repo>/.ai-keys.local`), `artToolsDir` (`<toolsDir>/art-tools`), `artRunScript`, `artLockFile` (`<toolsDir>/state/tripo.lock`), `artLockWaitSec` (1800), `artBudgetFile`, `artLedgerFile`.
- Tests: `test/art.test.cjs` (validation, pricing, budget/ledger math, every refusal path, approval gating, resume, flock, crash settlement, install) with fake Tripo/Gemini tools in `test/fake-art/`; no API is called and no credits are spent.

## Thread names

The thread opens with a cleaned copy of the request (mentions, the bot's name and filler like "hey, can you" removed, sentence case, at most 60 characters, else `Death Muffin request`). When the agent writes `.dm-title` (2-6 words, see `PROMPT-godot.md`) the runner sanitizes it (one line, no mentions, links, markdown or control characters, redacted, at most 57 characters) and renames the thread to it; a different title in a later round renames again. A marker shows the state: `📝` waiting for approval, `✅` shipped, `❌` discarded. `runner/lib/threadTitle.cjs` keeps only the newest wanted name per thread and sends at most 2 renames per 10 minutes per thread (Discord's limit), dropping no-ops. Renames are fire-and-forget ops (`{ rename: { threadId, name } }`) that the adapter applies with `setName`; failures are logged and skipped, archived threads are not touched. `job.title` in `jobs.json` is the current title, so a restart does not rename again; `!status` shows it. The bot started the thread, and Discord lets a thread's owner edit its name, so no new permission should be needed; if renames fail with "Missing Permissions" in the bot log, give the bot **Manage Threads** in `#death-muffin`.

## Install (from a committed revision; nothing starts by itself)
1. `bash server/death-muffin/discord-agent/install-runner.sh <rev>`: tooling to `~/death-muffin/discord-agent`, `config.json` (owner id from
   `/opt/crossworlds-bot/.env`), `secret`, systemd unit (not started).
2. `bash install-bot.sh <rev>` (sudo): `/opt/muffin/discord/dm-agent.js`, patched `bot.js` (backup kept), `/opt/muffin/dm-agent.env`.
3. `sudo systemctl enable --now death-muffin-discord-agent`, then `sudo systemctl restart muffin-discord`.

Tests (not wired into test:server; ~1 min, needs git and `unshare`/`zip`/`unzip`): `node --test server/death-muffin/discord-agent/test/*.test.cjs`.
The installer also copies `check-godot.sh`, `preview-godot.sh`, `shot-godot.sh`, `label-shot.py`, `art-run.sh`, `build-art.sh` and `PROMPT-godot.md`, installs the trusted art tools to `art-tools/`, and creates an empty `tripo-budget.json` if there is none (never overwritten). The live `config.json` must say `"mode": "godot", "baseBranch": "main"`; edit it and restart the service to change.

## Screenshots
`shot-godot.sh [plan.json]` (default `.dm-shot.json`; format in `godot/main/qa_ui_shots.gd` and `PROMPT-godot.md`: up to 4 shots of windows/tooltips, `open` / `hover` / `area` / `clip` / `give`) renders the branch's own client on the dev-offline demo hero with a fixed
representative bag. Same sandbox as `check-godot.sh` (no network, read-only filesystem, only the worktree writable, private `/tmp` and a fresh HOME); inside it imports the project if `godot/.godot` is missing
(first run in a fresh worktree, about a minute), then `xvfb-run godot --rendering-driver opengl3 -- --world-demo --qa --shot-plan=... --shots=<worktree>/.dm-shots/.raw`. It takes the shared `qa-browser.lock` (one renderer on the VPS) and has a hard 15 minute limit
(a run takes 1 to 5 minutes depending on load; it prints `render: cpu=.. wall=..`).
The label is burned in OUTSIDE the sandbox by `label-shot.py` (trusted code; Pillow): every raw PNG becomes `.dm-shots/<name>.png` with "BRANCH PREVIEW · not live · <branch>"; directory fds + `O_NOFOLLOW`, only real PNGs
under 12 MB, names `[a-z0-9-]{1,40}.png`; anything else is skipped (exit 3) and nothing unlabelled is ever published, so a branch that edits the QA code cannot drop the label.
The Godot side lives in the game repo (`godot/main/qa_ui_shots.gd`, inactive without `--qa`): **the branch the agent works on must contain it, i.e. it has to be merged into `main`**.
The agent is told (PROMPT-godot.md) to take pictures by default for visible changes (UI, windows, tooltips, HUD, visuals) and to skip them for logic/data/server work and pure Q&A.
On a proposal (`propose()`), when the agent left a plan and fresh pictures, the runner renders the same plan on an unchanged scratch worktree of the base (`base-<jobid>`, removed afterwards) and attaches
AFTER pictures right away (the embed image is the first); the BEFORE/AFTER pairs for the first two pictures (`before-<name>.png`, then `<name>.png`) follow as a separate message once the base is rendered in the background, so a busy renderer never holds the job's slot. If the base cannot render (for instance it predates the QA shot-plan code) no pair message follows.

## Playable preview
Each proposal gets a "Try it (Windows download)" link to the zip built by `preview-godot.sh` (see above), built in `propose()` before the embed is posted
(15 min cap). A failure adds "Preview build failed" with a short reason and the proposal is posted anyway. `!preview` rebuilds it on an open proposal. The
preview folder is deleted when the job ships, is discarded or is swept (`removeJobArtifacts`). `previewRoot` (default `/var/www/death-muffin/preview`, must exist and be
writable by the runner user) and `previewCmd` (replaces the script, tests) are in config.

## Images from people
The adapter downloads image attachments (png/jpg/webp/gif, Discord CDN only, <= 8 MB each, <= 4 per message) and sends them to the runner as `images: [{name, b64}]` in the `/event` body; anything refused stays in the "not visible to the agent" note with the reason. The runner checks the bytes look like an image and writes them to `<worktree>/.dm-inbox/<msgId>-<name>` (git-excluded), appending `[image attached by NAME: .dm-inbox/... — Read it to see it]` to that message so the agent can `Read` it; for a new @mention the files are written in `bind()` once the worktree exists. A job keeps at most 40 MB of images (`job.inboxBytes`), then refuses with a note. Image bytes are never redacted or logged. `/event` accepts bodies up to 48 MB (4 x 8 MB as base64 is about 43 MB); every other route keeps the 1 MB cap.

## Rounds (one thread, many changes)
A thread does not close when its change ships (or is discarded, or swept after 7 idle days). The next message from an allowed requester starts a new ROUND in the same job record: a fresh branch `discord/<jobid>-<n>` and worktree cut from the current `origin/<baseBranch>`, proposal/shots/preview state reset, the claude session id kept (the runner also copies the session file into the new worktree's claude project dir, and falls back to a fresh session if it cannot be resumed), and the first prompt starts with a note that the earlier change is live. `job.history` records `{round, branch, shipSha | discarded, at}` and the audit log gets a `round` entry.
- A message sent while a ship is running is kept (shown as waiting). If the ship goes live, the next round starts at once and the message is processed there (attached images are carried over); if the ship fails, the job returns to idle/proposed and the message is handled on the same branch.
- Turns: `maxTurnsPerJob` (40) now counts per round; `maxTurnsPerThread` (120) is a hard cap over the whole thread.
- After a sweep a new message also starts a new round (the sweep only released the worktree; the thread and its context are still useful). Commands other than `!status` answer "nothing is open" in a closed thread.

## Deleted threads
The adapter forwards discord.js `threadDelete` for threads under the configured channel as `{type: 'thread-deleted', threadId, ...}`. The runner removes the job's worktree, local + remote branch and preview dir at once, sets `status: 'deleted'` (history `{deleted: true}`, audit `thread-deleted`) and posts nothing to that thread again (queued outbox ops are dropped). A running step is cancelled and cleaned up when it unwinds; a ship in progress is never interrupted: it finishes, then the cleanup runs and queued messages do not start a round. A deleted job ignores all further events and is skipped by the sweep.
