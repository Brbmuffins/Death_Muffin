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
   ├─ per request: git worktree + branch discord/<id> from origin/{baseBranch} (`main`) with main's Godot import cache copied in, `claude -p` (sandboxed, --resume within a round)
   ├─ verify (runner code, not the AI): commits clean · no Co-Authored-By · forbidden paths · secret scan · generated files re-derived · check-godot.sh · tier
   ├─ propose: push branch, embed with tier / files / tests / migrations / compare link, ✅ ❌
   └─ ship.sh (only after an approver's ✅): deploy lock · merge onto {baseBranch} · re-gate · re-test (skipped when the merged tree is the proposal's) · push · publish-godot-client.sh (deferred when another approved ship waits)
```

## Mode and branch (`mode` and `baseBranch` in `config.json`, owner-edited)

The live config must say `"mode": "godot", "baseBranch": "main"` (a restart picks changes up). Set both keys explicitly: the runner code still has a
retired web mode and defaults to `mode: "web"`, `baseBranch: "master"`. `baseBranch` must match `^[A-Za-z0-9._/-]+$` (not start with `-`, contain `..`, `//`, end in `/` or `.lock`);
a bad value or mode makes the runner refuse to start. It is used for the worktree base (`origin/<baseBranch>`), `!sync`, the ship merge and push, messages and the compare link.

In godot mode: tests `check-godot.sh` (agent, runner and ship.sh) · preview `preview-godot.sh` (a Windows `.zip`) · screenshots `shot-godot.sh` / `!shot`
· prompt `PROMPT-godot.md` · tier rules `godotTiers` (picked into `cfg.tiers` by `loadConfig`) · ship: merge, check-godot, backup + `ROLLBACK.sh`, push,
`publish-godot-client.sh` · rollback folder `backup-pre-release-godot-<stamp>`.

**Progress notes** while a turn runs: `🔧 <pct>% · <sentence> · ⏱ <min> min`. The agent writes `.dm-status` as `<pct>% · <sentence>` (prompt
`PROMPT-godot.md`); fewer thread posts (owner, 2026-10-10): the first status posts at once, later ones only when it changed and at most every
`statusEveryMin` (default 15); no timed notes, no "On it" line, no "checks found a problem" line (fix-up turns are in the audit log only).
While `check-godot.sh` runs it keeps
`<done> <total>` suites in `.dm-check-progress`, and the note's percentage moves from the agent's number toward 95% (`progressNote` in
`runner/core.cjs`). Both files are git-ignored. Model generation posts `🎨 Still generating "<id>"` with the minutes instead.
The auth backend (`deploy-release.sh`) is not part of a ship; the owner runs it. The web-mode scripts in this folder (`check.sh`, `preview.sh`, `shot.sh`, `regen.sh`) are unused.

**`check-godot.sh`**: the same sandbox as `check.sh` (`unshare -rnm`, loopback only, whole filesystem read-only, only the worktree writable, scratch tmpfs over
`node_modules/.vite`), with `HOME` and the XDG dirs in a fresh `/tmp/dmgodot.*` (inside the sandbox's private /tmp) so Godot's `user://` never touches the real home. It runs
`tools/godot/gen-fixtures.sh` only if the revision still has it (golden fixtures are committed on `main`), then `tools/godot/run-all-tests.sh` (one line per suite; `GODOT` defaults to `/home/ubuntu/tools/godot/godot`). The committed `godot/data/loot/content.json` is snapshotted and restored around the generator. While the suites run it writes `<done> <total>` to `.dm-check-progress` in the worktree (removed at the end) for the progress notes. It has two modes. **Quick** (default; the agent in its turn and the runner before a proposal): `tools/godot/affected-suites.mjs` picks the suites for the change (changed suite dirs; suites referencing a changed file by `res://` path or `class_name`, one level through non-test dependents; for changed `godot/data` files the scripts that load them, by path or DmDb accessor; plus a smoke set `data status backend next`, about 20 s; a `godot/data/content/*.json` change also runs `rules-core`, which checks the manifest counts) and `run-all-tests.sh --only <list>` runs them. It prints `ALL` (every suite) for central changes (`project.godot`, `export_presets.cfg`, autoloads, `godot/rules/core`, `godot/net` (except a change that only adds lines to `dm_api.gd` / `dm_mock_backend.gd`: that selects the suites using the added `func` names and `/api/...` routes, one level through dependents),
`godot/session`, `godot/tests/common`, `tools/godot/*`), more than 40 changed `.gd` files, or more than 60% of suites selected; nothing for docs-only; a revision without the selector or `--only` also runs everything. **`--full`** (`ship.sh` passes it only for a sensitive-tier change; other ships run the quick check on the merged tree, dev build, owner 2026-10-10) runs every suite, about 2 minutes (8 at once, fewer when the machine is busy; a suite that fails in the pool is retried alone; each suite's time limit is 10x its usual time from `tools/godot/suite-times.tsv`, 4-30 min, and a suite that times out, `exit=124 timed out after ...`, is neither retried alone nor re-run). **`--rerun a,b`** runs hygiene plus exactly those suites, one at a time: when a check fails only 1-3 suites (nothing outside the suites), the runner (before a proposal; audit `flake-rerun`) and `ship.sh` re-run just those once before an agent turn is spent or the ship fails; a pass reads `... — passed (x passed on a re-run)`. The failure handed to the agent leaves out the passing suite lines. `DM_TEST_JOBS=N` adds `--jobs N`. The progress total is the number of selected suites. It ends with `GODOT TESTS: quick (14 suites) — 14 passed` or `GODOT TESTS: full (70 suites) — 70 passed` (`, N FAILED` on failure; `targeting fell back to all` is noted); the proposal's "Tests" field reads `quick check: N suites — ...`. It exits non-zero on any failing
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
copy with `REPO=<repo>` for the previous revision (no manifest = first publish = `Rollback: none`); push `HEAD:refs/heads/$BASE_BRANCH`; **the backend**:
`NO_ANNOUNCE=1 deploy-release.sh --if-changed <sha> [migrations]` (a no-op printing `Backend: unchanged` when every server file the revision installs
matches the installed copy; otherwise its own server tests, DB backup and rollback, `Backend: deployed <sha12>, rollback <path>`, and the godot
`ROLLBACK.sh` runs that backend rollback before republishing the old client; a failure is `RESULT: deploy-failed <sha12> backend` with the client
untouched; `backendDeployCmd` replaces it in tests, and with `deployCmd` alone the step is skipped); publish the new SHA with the saved copy (`deployCmd`
replaces it in tests); print `Rollback: <path>`, `RESULT: live <sha12> <path>`. A deferred merge (`RESULT: merged`) gets its backend from the ship that
publishes it. The runner
accepts only exact `backup-pre-release-godot-<yyyymmddThhmmssZ>` real directories (no symlinks) with a `ROLLBACK.sh`.

## Who can do what (`config.json`, owner-edited, never by the AI)

- `ownerIds`: always requester + approver of every tier. Failures (deploy/publish problems) and rollbacks by someone else get a plain `⚠` line in the thread; nobody is tagged (owner, 2026-10-10). The one ping: a proposal (and a resolved merge that needs a fresh ✅) tags the requester (`job.lastAsker`, else the thread's creator) so it is not missed (Helix, 2026-10-11); only that user, never roles or @everyone, and not on a re-proposal that ships on a carried approval. A ship pings nobody: releases are announced in #build-alerts by `announce-release.sh`. The runner never posts in the channel itself, only in threads.
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
`!status` · `!credits` (your model-generation budget) · `!shot` (screenshot of the change) · `!cancel` · `!discard` (or ❌, or plain words like "discard this" / "you can discard this as a test") · `!sync` (merge the latest base branch, agent resolves conflicts) · `!model opus|sonnet|haiku`
(full approvers; "use opus" in a message works too) · `rollback` (mention in channel or thread): runs the newest deploy
backup's ROLLBACK.sh under the lock. Owner/full approvers any time, limited approvers only if their ship is the latest.

`!cancel` (or a bare `stop` / `cancel` while something runs; requester or owner; a near-miss such as `cencel` or `stpo` gets "Did you mean !cancel?" and is not passed to the agent) stops the current step, agent turn or the runner's own check run,
killing the whole process tree (Claude's Bash tool and `timeout` start their own process groups, so a group kill alone orphaned test runs).
Messages queued before it are dropped, and no review or repair turn follows; the branch and worktree stay, and the next message continues.
A ship cannot be cancelled. An idle job is closed by the sweep after 7 days without activity. Housekeeping (`tidy()`, at start and with every sweep)
clears a job's pointer to a workspace that is gone and drops messages stuck in a finished job for over an hour (audit `stale-queue-dropped`).

**After an approval, nobody needs to type `!sync` (2026-10-10, DECISIONS B13).** If the ship hits a merge conflict, the runner queues the sync itself
(audit `auto-sync`): the agent merges the base branch in and resolves the conflict, checks run, and a proposal is posted. When the resolved change
touches only files the approved proposal touched, its tier is not higher, and nobody wrote in the thread meanwhile, it ships on the ORIGINAL
approval (audit `approved` with `carried: true`; the thread names the files). Otherwise it needs a fresh ✅ and the thread says why
(`carry-refused`). At most 2 carried syncs per human approval. If the base branch moved during the push itself (`master-moved`, nothing
changed on the branch), the ship is queued again by itself (`auto-reship`, at most twice per proposal).

**Ship speed (owner, 2026-10-10).** The ship's re-test is skipped when the merged tree is exactly the proposal's (main did not move since), which already
passed the same quick check; a sensitive change still runs the full suite. **Backlog:** when another approved ship is waiting, the current one merges, tests
and pushes but does not publish (`DEFER_PUBLISH=1`, `RESULT: merged`; the thread is told it goes live with the next publish). The next publish carries it:
its notice lists both changes under both titles, and the waiting thread gets "🚀 Live" and closes (`healOtherPublishes`, logged in the ships log with
`batchedWith`). If nothing else ships, the runner publishes the merged one by itself (`drainShipQueue`). **One test run at a time:** `check-godot.sh` takes
`~/death-muffin/test-slot.lock` (shared with the ship; created by the installer) and waits for it, so parallel jobs no longer slow each
other down. Fresh worktrees (jobs, ships) start from the main checkout's Godot import cache (~14 s instead of ~70 s); the
client publish still imports from scratch.
A message sent while a turn runs is handled by the next turn, and the finished turn posts no proposal for the outdated state (audit `proposal-skipped`), so one proposal comes with everything. Screenshot runs (`shot-godot.sh`, `--qa --shot-plan`) skip the game's start-up warm-up (software GL: 192 s -> 41 s per start).
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
- Runner redacts every outgoing string and audit field; mentions are disabled (no post tags anyone).
- Audit log: `state/audit.jsonl` (every request, proposal, approve/refuse, ship result, rollback); ships: `state/ships.jsonl`.
- ship + rollback + `deploy-release.sh` all take `~/death-muffin/deploy/.deploy.lock`.
- Residual risk: `ship.sh` re-runs `check-godot.sh` on the merged tree in the same sandbox, but `publish-godot-client.sh` exports the project outside it. That is why test configs, package files and
  scripts are sensitive/forbidden, and why the proposal links the exact diff for a human to read before ✅.

## Parallel jobs and long checks

- `maxConcurrentJobs` (1-3, live: 3) lets several threads work at once, so one person's long request does not queue everyone else. Ships
  still go one at a time behind the deploy lock. Git commands that hit a lock file another job is holding retry a few times (gitops.cjs).
- The full check runs about 2 min (suites in parallel) (sensitive ships only; proposals and the agent get the quick check, a few minutes). The agent's `claude -p` gets `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` and a 55-minute Bash limit (turn limit 60 min, check-godot.sh hard limit 85 min)
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

## New models and armor sets (concepts -> Tripo -> renders -> in game), approval-gated and credit-capped

Someone asks in a thread for a new character, creature, boss, prop, piece of gear or a whole armor set. The agent never holds a key and cannot call an API; it writes SPECS, the runner does the generating. People see every stage in the thread (the way the 2026-10-11 necromancer gear was made), so the requester can steer it without the owner stepping in.

```
agent turn ── writes art-manifest/gemini-jobs/<id>.json per piece + .dm-concept-request.json {ids (1-8), note}
runner     ── validates the concept jobs, checks the requester has a model budget (or is the owner) and the round has made < 24 concepts, then runs
              art-run.sh --concept <id> per piece (Gemini only: no Tripo key, no credits from the budget) and posts the images numbered in the thread
people     ── reply: change / keep / drop, "build 1 and 3". The agent re-requests changed concepts, then for the chosen pieces:
agent turn ── writes art-manifest/tripo-specs/<id>.json per piece + .dm-art-request.json {ids (1-6, a whole set in one request), note}
runner     ── validates against allow-lists (below), prices it, posts the concepts it will build from (pinned by sha256) and the request:   New character: warlock  (or New set: N models)
              Will be generated: Concept image (Gemini) -> 3D model (Tripo, up to 7000 faces, detailed textures) -> rig (biped) -> 6 animations: idle, walk, ...
              Estimated cost: up to 145 credits (image to model 60 + rig 25 + 6 animations x 10)      Helix's budget: 1000 of 1000 left -> 855 after this      Tripo balance now: 3910
              ✅ spend the credits (the owner / Helix / warbogar) · ❌ cancel · nothing is spent until a ✅
approver ✅ ── owner or any full approver (self-approval allowed, like code ships). Re-checked live: estimate <= requester's remaining budget AND <= Tripo balance, else "Not started"
runner     ── per model, in order: art-run.sh in the job's worktree: flock -> balance before -> gemini.mjs (skipped: the shown concept is reused; a concept that changed
              since it was shown is refused, one nobody saw is deleted and regenerated) -> tripo.mjs run --yes -> balance after. One ledger entry per model; a failure stops the
              set and offers the rest again. Posts Tripo's preview images and the REAL spend
agent turn ── told the files are ready: build-art.sh <id> per model (sandboxed: tools/build-characters.mjs, then dequantize into godot/assets/slice/models/...), commits specs + records + GLB,
              check-godot.sh (adds .import/textures), render-model.sh <ids> (sandboxed Blender, front/side/back sheet, posted after the turn), wires the models in where asked,
              in-game shots of a hero wearing gear (shot plan "equip" + "view": "hero"), PATCH_NOTES, then the usual proposal / ✅ ship (art files make it a sensitive-tier proposal: full approvers only)
```

- **render-model.sh / render-model.py**: `render-model.sh <id> [<id> ...]` (1-6 ids, new or existing models) runs Blender (`BLENDER`, default `/home/ubuntu/tools/blender/blender`, Cycles on the CPU, 4 threads, 24 samples, `nice -n 10`; about 20 s for three models) in the check-godot.sh sandbox, composes one sheet (a row per model: front three-quarter, side, back) with Pillow, and `label-shot.py` burns in the preview label: `.dm-shots/models-<first id>.png`. It holds the screenshot lock (`qa-browser.lock`) and stops after 10 minutes.
- **Keys never enter the agent.** `art-run.sh` gets `TRIPO_API_KEY` / `GEMINI_API_KEY` in its own environment only (read by the runner from `<repo>/.ai-keys.local`, `artKeysFile`); they are never written, logged or committed, every posted line goes through `redact.cjs` (the key values are registered as known secrets, plus `tsk_` / `AIza` / `AQ.` patterns), and `sandbox-lib.sh` binds `/dev/null` over `.ai-keys.local` and the runner `secret` inside every sandbox (check / shot / preview / build-art), so even a test script cannot read them. `agentEnv()` has no keys and `art-run.sh` is not in the agent's allowed tools.
- **Trusted tools.** The runner runs COPIES of `tools/ai/{common,gemini,tripo}.mjs` installed to `art-tools/` (with their own copy of `sharp`), pointed at the worktree with `DM_ART_ROOT`. The worktree's own `tools/` and `node_modules` (which the agent can edit) are never executed by a process that holds keys.
- **What runs is what was approved.** The validated canonical specs are stored in the job record at request time; at ✅ the runner rewrites the spec files from that copy (an agent edit after the offer changes nothing) and re-checks that no path the tools write to is a symlink.
- **Validation (`runner/lib/art.cjs`)**: id `[a-z0-9_]{3,40}` and not an existing model; no extra fields anywhere; `input`/`out` exactly `art-src/concepts/<id>.png`; model `P1-20260311`; `face_limit` integer 300-14000; texture `standard|detailed`; rig `biped` (`v1.0-20240301`) or `quadruped` (`v2.5-20260210`, `preset:quadruped:walk` only); at most 10 distinct known presets, `animationMode: single`; rig <=> id not starting `prop_`; Gemini `aspect`/`size`/`model`/`post.{resize,format}` limited, up to 3 refs that are `art-src/concepts/*.png` real images or reference sheets committed at the repo root. A bad request goes back to the agent to fix (twice), then is dropped. Anything over 400 estimated credits per model, or 1,200 for a set, is refused whatever the budget. Concept requests (`.dm-concept-request.json`) are checked the same way for their Gemini jobs.
- **Estimate** = the highest credits ever charged per step type in the base branch's `art-manifest/tripo/*.json` (read from git, not the worktree), never below the measured floors (model 60, rig 25, clip 10; rig-check is free). Typical: prop 60 (50 with standard textures), rigged character with 6 clips 145, bone_golem-sized 9 clips 175.
- **Budgets**: `tripo-budget.json` (next to `config.json`, mode 600, owner-edited, read fresh on every use): `{"<discord id>": <credits>}`. Unlisted users, bad values and negatives = 0 -> "has no model-generation budget", nothing offered. The owner is not exempt. `!credits` shows your numbers. Remaining = budget - the sum of ACTUAL credits in the ledger.
- **Ledger**: `tripo-ledger.json` (same folder, mode 600, outside every repo): one entry per run `{id, ts, userId, userName, jobId, specId, estimate, approverId, status started|done|failed|interrupted, credits, balanceBefore, balanceAfter, result, note, finishedAt}`. The `started` entry is written BEFORE anything is spent; credits are balance-before minus balance-after (a run that fails midway still records what it spent; a killed run is read from a fresh balance; if the balance cannot be read the estimate is charged). If the runner itself dies mid-run, the next start closes the open entry from the balance delta (`interrupted`).
- **One run at a time**: an in-process flag plus `flock` on `state/tripo.lock` inside `art-run.sh` (a second run gives up as `busy` without touching the account). Tripo's own resume (`state.json` in `art-src/tripo/<id>/`) means a retry never pays twice: after a failure the thread gets a fresh request (same estimate, updated budget) and a ✅ resumes.
- **Never without a ✅ / never unapproved**: nothing is spent at request time; only `isFull` approvers' ✅ on that exact request message starts it (others' reactions are removed); `!discard`/❌ clears a pending request; a thread that is running, shipping or generating turns a ✅ away. Audit events: `art-offered`, `art-approve-attempt`, `art-approved`, `art-approve-refused`, `art-refused`, `art-start`, `art-result`, `art-cancelled`, `art-invalid`, `art-reconciled`.
- Config keys (all optional, defaults shown; `config.json` is not edited): `artKeysFile` (`<repo>/.ai-keys.local`), `artToolsDir` (`<toolsDir>/art-tools`), `artRunScript`, `artLockFile` (`<toolsDir>/state/tripo.lock`), `artLockWaitSec` (1800), `artBudgetFile`, `artLedgerFile`.
- Tests: `test/art.test.cjs` (validation, pricing, budget/ledger math, every refusal path, approval gating, resume, flock, crash settlement, install) with fake Tripo/Gemini tools in `test/fake-art/`; no API is called and no credits are spent.

## New sounds (ElevenLabs), no budget gate

```
agent turn ── writes audio-manifest/eleven/<id>.json {id, kind sfx|music, prompt, duration_seconds, variants, loop?, prompt_influence?} + .dm-sound-request.json {id, note}
runner     ── runner/lib/sound.cjs validates (no extra fields; sfx 0.5-30 s, 1-4 takes; music 10-180 s, 1-2 takes, instrumental; prompt 10-1000/2000 chars; no symlinks).
              The asker (job.lastAsker) must be in soundUsers (config.json; the owner always is). Then it runs right away, no ✅ and no budget:
              the owner authorized sound users to spend any amount of the ElevenLabs balance (2026-10-11).
              sound-run.mjs (trusted copy in the tools dir, ELEVENLABS_API_KEY in its env only) -> audio-src/eleven/<id>/v<n>.mp3 (git-ignored), takes posted in the thread
agent turn ── build-sound.sh <id> <take> (sandboxed ffmpeg: sfx -> godot/assets/audio/eleven/<id>.wav mono 16-bit, music -> .mp3), wires it in, commits spec + asset + .import,
              then the usual proposal / ✅ ship
```

- Key: `/home/ubuntu/death-muffin/private/elevenlabs-api-key` (`soundKeyFile`), hidden inside every sandbox by `sandbox-lib.sh`, registered with `redact.cjs` (plus an `sk_` pattern).
  The key has no `user_read` permission, so the balance cannot be read; the cost comes from ElevenLabs' `character-cost` header per take (a 1 s effect cost 11 credits, 2026-10-11).
- Ledger: `eleven-ledger.json` (tools dir, mode 600): `{id, ts, userId, userName, jobId, specId, kind, seconds, variants, files, credits, result}`. `!credits` shows a sound user's total.
- A take that already exists is not generated again, so a retry pays only for missing takes. Audit events: `sound-start`, `sound-result`, `sound-refused`, `sound-invalid`.
- Config keys (optional): `soundUsers` (Discord ids), `soundKeyFile`, `soundRunScript` (`<toolsDir>/sound-run.mjs`), `soundLedgerFile`.
- Tests: `test/sound.test.cjs` (validation, refusal, ledger, a fake ElevenLabs server for sound-run.mjs); no API is called.

## In-game bug reports (#manual-bugs)

Every new player report (Settings -> Report a bug) gets its own thread in #manual-bugs (`bugChannelId`), so the devs see what is reported.
Every `bugPollMin` (2) minutes the runner reads the `new` reports (`reports-cli.cjs list`, installed beside the runner), and the bot posts each one:
category, reporter, the message quoted, area / level / discipline / solo or co-op / client release, and `bug-report-<id>.txt` with the full
context and game log. The post opens the thread (`🐞 #<id> <message>`, player text scrubbed of mentions and links; nobody is pinged) and the
report becomes `triaged` ("Looked at", with a thank-you note for the player). `state/report-threads.json` keeps a report from being posted twice;
at most `bugThreadsPerHour` (10) threads an hour, the rest stay `new` until the next hour.

Nothing works on a report by itself (the old 2-minute bug-fix agent is retired): the devs talk it over in the thread, and the agent starts only
when someone @-mentions Muffin Core there. Its fresh session then gets the report and log as player data (never instructions), and it runs like
any thread: proposal, ✅ ships. A fix commit is titled `Bug report #<id>: …`, so `announce-release.sh` marks the report released ("Fixed — live
now"). Once a change is open in the thread, replies go to it without a mention. A report thread nobody picked up is archived after 48 h quiet
(`archiveReportAfterMin`); the 7-day sweep skips report threads that never had a workspace. `!report` / `!report <id>` still work in any thread.

## Thread names

The thread opens with a cleaned copy of the request (mentions, the bot's name and filler like "hey, can you" removed, sentence case, at most 60 characters, else `Death Muffin request`). When the agent writes `.dm-title` (2-6 words, see `PROMPT-godot.md`) the runner sanitizes it (one line, no mentions, links, markdown or control characters, redacted, at most 57 characters) and renames the thread to it; a different title in a later round renames again. A marker shows the state: `🔧` the agent is working (set as soon as a turn starts), `📝` waiting for approval or shipping (a ship does not rename: Discord's 2 renames per 10 minutes are kept for the `✅`), `✅` shipped, `❌` discarded. `runner/lib/threadTitle.cjs` keeps only the newest wanted name per thread and sends at most 2 renames per 10 minutes per thread (Discord's limit), dropping no-ops. Renames are fire-and-forget ops (`{ rename: { threadId, name } }`) that the adapter applies with `setName`; failures are logged and skipped, archived threads are not touched. `job.title` in `jobs.json` is the current title, so a restart does not rename again; `!status` shows it. The bot started the thread, and Discord lets a thread's owner edit its name, so no new permission should be needed; if renames fail with "Missing Permissions" in the bot log, give the bot **Manage Threads** in `#death-muffin`.

Finished threads are archived so `#death-muffin` only lists live work (owner, 2026-10-11). Every 10 minutes the runner (`archiveQuiet`) archives a shipped or discarded job's thread after an hour without activity (`archiveAfterMin`, default 60) and an idle thread without a proposal after a day (`archiveIdleAfterMin`, default 1440); an open proposal, a running or queued job and a pending rename are never archived. The adapter applies `{ archive: { threadId } }` ops with `setArchived` and acks them (re-sent each minute while the bot is away). Archived threads stay in the channel's Threads list for anyone to browse; a message in one reopens it and it is archived again once quiet. `job.archived` in `jobs.json` records it.

## Install (from a committed revision; nothing starts by itself)
1. `bash server/death-muffin/discord-agent/install-runner.sh <rev>`: tooling to `~/death-muffin/discord-agent`, `config.json` (owner id from
   `/opt/crossworlds-bot/.env`), `secret`, systemd unit (not started).
2. `bash install-bot.sh <rev>` (sudo): `/opt/muffin/discord/dm-agent.js`, patched `bot.js` (backup kept), `/opt/muffin/dm-agent.env`. When the live `bot.js` already loads `./dm-agent` but carries other hooks too (the Hammy Xchange agent patches the same file from its own repo), it leaves `bot.js` alone and updates only the adapter and env (old adapter backed up); a `bot.js` without the hook is refused as before.
3. `sudo systemctl enable --now death-muffin-discord-agent`, then `sudo systemctl restart muffin-discord`.

Tests (not wired into test:server; ~1 min, needs git and `unshare`/`zip`/`unzip`): `node --test server/death-muffin/discord-agent/test/*.test.cjs`.
The installer also copies `check-godot.sh`, `preview-godot.sh`, `shot-godot.sh`, `label-shot.py`, `render-model.sh`, `render-model.py`, `art-run.sh`, `build-art.sh` and `PROMPT-godot.md`, installs the trusted art tools to `art-tools/`, and creates an empty `tripo-budget.json` if there is none (never overwritten). The live `config.json` must say `"mode": "godot", "baseBranch": "main"`; edit it and restart the service to change.

## Screenshots
Only on request (Helix, 2026-10-12): the agent renders when the request asks for a picture or someone says `!shot`, never by default (PROMPT-godot.md); a proposal without pictures has a "Screenshots" field offering `!shot`.
`shot-godot.sh [plan.json]` (default `.dm-shot.json`; format in `godot/main/qa_ui_shots.gd` and `PROMPT-godot.md`: up to 4 shots of windows/tooltips or the hero wearing gear, `open` / `hover` / `area` / `clip` / `give` / `equip` / `discipline` / `view` / `turn` / `anim`) renders the branch's own client on the dev-offline demo hero with a fixed
representative bag. Same sandbox as `check-godot.sh` (no network, read-only filesystem, only the worktree writable, private `/tmp` and a fresh HOME); inside it imports the project if `godot/.godot` is missing
(first run in a fresh worktree, about a minute), then `xvfb-run godot --rendering-driver opengl3 -- --dev-offline --class=<plan discipline, default 2> --qa --shot-plan=... --shots=<worktree>/.dm-shots/.raw`. It takes the shared `qa-browser.lock` (one renderer on the VPS) and has a hard 15 minute limit
(a run takes 1 to 5 minutes depending on load; it prints `render: cpu=.. wall=..`).
The label is burned in OUTSIDE the sandbox by `label-shot.py` (trusted code; Pillow): every raw PNG becomes `.dm-shots/<name>.png` with "BRANCH PREVIEW · not live · <branch>"; directory fds + `O_NOFOLLOW`, only real PNGs
under 12 MB, names `[a-z0-9-]{1,40}.png`; anything else is skipped (exit 3) and nothing unlabelled is ever published, so a branch that edits the QA code cannot drop the label.
The Godot side lives in the game repo (`godot/main/qa_ui_shots.gd`, inactive without `--qa`): **the branch the agent works on must contain it, i.e. it has to be merged into `main`**.
The agent is told (PROMPT-godot.md) to take pictures by default for visible changes (UI, windows, tooltips, HUD, visuals) and to skip them for logic/data/server work and pure Q&A.
On a proposal (`propose()`), when the agent left a plan and fresh pictures, the runner renders the same plan on an unchanged scratch worktree of the base (`base-<jobid>`, removed afterwards) and attaches
AFTER pictures right away (the embed image is the first). BEFORE pictures are off (owner, 2026-10-10: each was one more software-GL render in the shared queue); with `cfg.beforeShots: true`, the BEFORE/AFTER pairs for the first two pictures (`before-<name>.png`, then `<name>.png`) follow as a separate message once the base is rendered in the background, so a busy renderer never holds the job's slot. If the base cannot render (for instance it predates the QA shot-plan code) no pair message follows.

## Playable preview
Godot mode builds the Windows zip (`preview-godot.sh`, see above) only on request: the proposal's "Try it" field says to use `!preview` (owner, 2026-10-10:
44 previews were built in a day and none was downloaded; each is a full import + export). `cfg.previewOnProposal: true` brings back building one with every
proposal (web mode always does). A failed build says so with a short reason. The
preview folder is deleted when the job ships, is discarded or is swept (`removeJobArtifacts`). `previewRoot` (default `/var/www/death-muffin/preview`, must exist and be
writable by the runner user) and `previewCmd` (replaces the script, tests) are in config.

## Images from people
The adapter downloads image attachments (png/jpg/webp/gif, Discord CDN only, <= 8 MB each, <= 4 per message) and sends them to the runner as `images: [{name, b64}]` in the `/event` body; anything refused stays in the "not visible to the agent" note with the reason. The runner checks the bytes look like an image and writes them to `<worktree>/.dm-inbox/<msgId>-<name>` (git-excluded), appending `[image attached by NAME: .dm-inbox/... — Read it to see it]` to that message so the agent can `Read` it; for a new @mention the files are written in `bind()` once the worktree exists. A job keeps at most 40 MB of images (`job.inboxBytes`), then refuses with a note. Image bytes are never redacted or logged. `/event` accepts bodies up to 48 MB (4 x 8 MB as base64 is about 43 MB); every other route keeps the 1 MB cap.

## Rounds (one thread, many changes)
A thread does not close when its change ships (or is discarded, or swept after 7 idle days). The next message from an allowed requester starts a new ROUND in the same job record: a fresh branch `discord/<jobid>-<n>` and worktree cut from the current `origin/<baseBranch>`, proposal/shots/preview state reset, and a FRESH claude session (owner, 2026-10-10: resuming carried every earlier round into each step; one thread read 10M cached tokens). The first prompt starts with a note that this is a new round plus a one-line summary of the thread's earlier rounds (`job.history`: `{round, branch, shipSha | discarded, title, at}`). Follow-ups inside a round still resume that round's conversation. The audit log gets a `round` entry.
- A message sent while a ship is running is kept (shown as waiting). If the ship goes live, the next round starts at once and the message is processed there (attached images are carried over); if the ship fails, the job returns to idle/proposed and the message is handled on the same branch.
- Turns: `maxTurnsPerJob` (40) now counts per round; `maxTurnsPerThread` (120) is a hard cap over the whole thread.
- Step budget inside a turn (2026-10-11: a session re-reads its whole conversation on every step, so cost grows with steps x context; one 176-step, 443K-token session was a third of three days' spend). Every claude call gets `--max-turns <handoffEveryTurns>` (default 40; 0 = none). When a session stops there (`error_max_turns`), the runner asks that same session (`--max-turns 6`, context still cached) to commit finished work and write `.dm-handoff.md` (git-excluded: request, done, left, key files, gotchas, next step), then starts a FRESH session with the note plus the original request and carries on (audit `handoff {n, note}`, runs log `handoff`/`step`). Nothing is posted to the thread; one runner turn = one `job.turns`. After `maxHandoffs` (default 5) the turn stops with a plain "needed more than N sessions ... say continue" line; committed work stays.
- After a sweep a new message also starts a new round (the sweep only released the worktree; the thread and its context are still useful). Commands other than `!status` answer "nothing is open" in a closed thread.

## Deleted threads
The adapter forwards discord.js `threadDelete` for threads under the configured channel as `{type: 'thread-deleted', threadId, ...}`. The runner removes the job's worktree, local + remote branch and preview dir at once, sets `status: 'deleted'` (history `{deleted: true}`, audit `thread-deleted`) and posts nothing to that thread again (queued outbox ops are dropped). A running step is cancelled and cleaned up when it unwinds; a ship in progress is never interrupted: it finishes, then the cleanup runs and queued messages do not start a round. A deleted job ignores all further events and is skipped by the sweep.
