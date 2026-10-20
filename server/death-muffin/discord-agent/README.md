# Death Muffin Discord dev agent

@mention the Muffin Core bot in `#death-muffin`, describe feedback or an idea, and it works it out in a thread: answers
questions from the code, or makes a change on its own branch and posts a short proposal (a draft: rounds of back and forth wait for no
tests). 🧪 runs every test on it; an approver's ✅ tests it and ships it. Nothing the AI says can ship, push or deploy.

```
Discord #death-muffin ── Muffin Core bot (user `muffin`, /opt/muffin/discord/{bot,dm-agent}.js)    dumb transport, no authority
        │  loopback HTTP + shared secret (x-dm-secret)         /event /bind  (bot -> runner),  /poll /ack (long-poll outbox)
        ▼
Runner (user `ubuntu`, ~/death-muffin/discord-agent/runner/server.cjs, port 4321)
   allow-list · approver gate · rate limits · audit.jsonl · job queue · tier classifier · proposal builder
   ├─ per request: git worktree + branch discord/<id> from origin/{baseBranch} (`main`), `claude -p` (sandboxed, --resume within a round)
   ├─ verify (runner code, not the AI): latest base merged in · commits clean · no Co-Authored-By · forbidden paths · secret scan · generated files re-derived · GitHub CI on the pushed branch (`ci.sh`; `check-godot.sh` with `ciGate: false`) on 🧪 / `!test` and before a ship (every round with `drafts: false`) · tier
   ├─ propose: push branch, embed with tier / files / tests / migrations / compare link, ✅ 🧪 ❌ (✅ ❌ once tested)
   └─ ship.sh (only after an approver's ✅): merge onto {baseBranch}, with every other waiting approval (one batch) · re-gate each · CI on the merged change (none needed when it is the proposal's files) · deploy lock · push · publish-godot-client.sh
```

Where it fits beside CI and the team app: README.md "How a change reaches players". The steps of one request, in order: a thread and a turn, a draft
proposal, 🧪 or ✅, CI on the merge, the ship (below).

## A request, from thread to live

**Drafts (Helix, 2026-10-19: "i dont see the point of doing any tests until the idea i have is actually built out"; `drafts`, default on with the
CI gate, off without it).** A round runs every gate but the tests and is proposed at once, marked "Not tested yet", with ✅ 🧪 ❌ (audit `proposal`
with `draft: true`); its push starts CI in the background, and nobody waits for it. 🧪 or `!test` (anyone the agent works for; audit
`test-requested`) queues a test run as a job step (`job.testing`): `verify` with the tests on, which merges the latest base in, waits for CI and
does the re-run and clean-base checks below. A pass on the proposed commit marks that proposal tested where it stands (`test-passed`, the thread
says so; ✅ then ships without waiting again); a failure says so and gets the agent's fix-up turns, and a tested proposal follows that needs a
fresh ✅. ✅ on a draft ships it: the ship's CI wait is the test (the proposal's own run when the merged tree is the same files), and ship.sh's local
check never skips an untested proposal (`PROPOSAL_UNTESTED`). A ship whose tests fail (`ship-tests-failed`) says so, and the same test run follows
(`repost`): the agent fixes it and a tested proposal comes back for one more ✅; suites that fail on the base too stop it with "⚠ Not this change".
❌ on a proposal asks first ("Discard this change?", audit `discard-asked`), and ❌ on that question discards (`discard-confirmed`); a typed
`!discard` or "discard this" does not ask.

**The CI gate (DECISIONS B59; `ciGate`, default on).** `verify` pushes the job's branch and waits for GitHub CI's verdict on its exact
files (`ci.sh wait <head>`, audit `ci-check`): every suite, the backend and lobby tests, hygiene and the model check; the proposal's "Tests" reads
`CI — every suite passed (<run link>)`. Failing suites come back from the run's annotations as `<suite> (CI) exit=1` lines, so 1-3 of them get one
re-run here (`check-godot.sh --rerun`) and the clean-base check works as before; CI failing outside the suites runs the local check to say what it
is; no verdict at all (GitHub down, `ci-unavailable`) runs the full set here. The ship merges, gates, then takes CI's verdict: on the proposal when the
merged tree is the same files, else on the merged change pushed as `ship/<job>` (removed afterwards); 1-3 failing suites get one re-run here. Only
then it takes the deploy lock (the wait never blocks another deploy) and pushes, if the base branch did not move meanwhile (`master-moved`, shipped
again by itself). **Batch:** approvals that wait for a ship go out with the next one (`BATCH`): each merged and gated with its own approver's tier,
one CI run, one push, one publish, every thread told it is live (the ships log's `batchedWith`). A batch that cannot ship as one (CI failed, a
conflict or a gate between its changes; audit `batch-split`) is queued again one change at a time (`solo`), so the one that breaks it comes back
with the reason. While GitHub is down the owner sets `ciGate: false` in `config.json`: the local check and the backlog below come back.

**After an approval, nobody needs to type `!sync` (2026-10-10, DECISIONS B13).** If the ship hits a merge conflict, the runner queues the sync itself
(audit `auto-sync`): the agent merges the base branch in and resolves the conflict, checks run, and a proposal is posted. When the resolved change
touches only files the approved proposal touched, its tier is not higher, and nobody wrote in the thread meanwhile, it ships on the ORIGINAL
approval (audit `approved` with `carried: true`; the thread names the files). Otherwise it needs a fresh ✅ and the thread says why
(`carry-refused`). At most 2 carried syncs per human approval. If the base branch moved during the push itself (`master-moved`, nothing
changed on the branch), the ship is queued again by itself (`auto-reship`, at most twice per proposal).

A message sent while a turn runs is handled by the next turn, and the finished turn posts no proposal for the outdated state (audit `proposal-skipped`), so one proposal comes with everything. Screenshot runs (`shot-godot.sh`, `--qa --shot-plan`) skip the game's start-up warm-up (software GL: 192 s -> 41 s per start).
A reply to an open proposal that changes nothing (a thank-you, a question) is answered, and the proposal stays as it is: same commit and clean
workspace means no new checks, preview or re-post (`proposal-kept` in the audit log), and ✅ works right away. The prompt also tells the agent to run
no check for such messages.
Rollback undoes the live release only; revert the commit on the base branch afterwards.

**Documents only:** an approved change that touches only Markdown files and `docs/` is pushed and stops there: no backend or lobby deploy, no client publish, no release notice (`RESULT: docs`;
the thread is told no game update went out, the ships log records `type: docs`).

## Who can do what (`config.json`, owner-edited, never by the AI)

- `ownerIds`: always requester + approver of every tier. Failures (deploy/publish problems) and rollbacks by someone else get a plain `⚠` line in the thread; nobody is tagged (owner, 2026-10-10). The one ping: a proposal (and a resolved merge that needs a fresh ✅) tags the person who started the thread (`job.creatorId`, else `job.lastAsker`) so it is not missed (Helix, 2026-10-11; the thread's owner since 2026-10-19: "@ war its his thread"); only that user, never roles or @everyone, and not on a re-proposal that ships on a carried approval. A ship pings nobody: releases are announced in #build-alerts by `announce-release.sh`. The runner never posts in the channel itself, only in threads.
- `projects.deathmuffin.requesters`: may talk to it and give work. Everyone else is ignored (no reply, audited).
- `projects.deathmuffin.approvers.{casual,gameplay,sensitive}`: who may ✅ a proposal of that tier. Anyone in `sensitive` is a
  full approver (all tiers, any rollback, no daily cap, may switch models). Someone only in `casual` is limited
  (casual ships only, `casualShipsPerDay` cap, may roll back only their own latest ship).
- Currently: the owner, Helix and warbogar are full approvers (warbogar is also the one sound user); add friends as requesters only (they can never ship).
- A user id must be digits; anything else (placeholders) is dropped on load.

Tiers come from the diff's **files** (`runner/lib/tiers.cjs`, rules in `lib/config.cjs`), strictest file wins:
Tiers (`tiers`): casual = `docs/**`, `*.md`,
`client/**/*.md`, PATCH_NOTES.json (any content); gameplay = the rest of `client/**`; sensitive = server, launcher, tools, CI, scripts, deploy, config,
the combat core (`native/`), `project.godot`, `export_presets.cfg`, `client/main`, `client/core`, the files the art pack is fingerprinted by
(`client/crowd/`, the creature and model code), and the client's net/front(login)/session code and anything named auth, session, online, save, offline,
progress_sync, coop, login, account, token, relay, lobby, realtime or mock_backend, plus native libraries, `addons/` and the net/relay/offline/realtime/
online_local/front test suites, and the progression/economy authority mirrors (anything named progression, authority, ledger, economy, spend, kill*, gold_sink, vault/labor/legion rules, milestone, reward, unlock, seal, tradeGoods; `rules/progression/`, `data/progression/`); anything unmatched (root files) is sensitive. `forbiddenPaths` also lists `client/export_presets.cfg`. Paths that would change the agent itself,
deploy scripts or `.env*` are refused outright (`forbiddenPaths`). `ship.sh` re-derives the tier from the merged diff under
the deploy lock, so an approver can never ship above their tier.

One ship at a time. A ✅ while another ship runs queues the proposal (the thread says how many are ahead) and it ships by
itself when its turn comes, in approval order (`job.shipQueued` in jobs.json, so the queue survives a runner restart). When its turn comes
the runner re-checks it: a proposal that moved on (new round or head), an approver who lost the tier, or a casual approver's daily cap
drops it from the queue with a note in the thread.

## Chat commands (in the thread, handled by the runner, not the AI)
`!status` · `!credits` (your model-generation budget) · `!shot` (screenshot of the change) · `!clips` (record the last short videos again on a team PC) · `!cancel` · `!test` (or 🧪: every test on the open change, nothing ships) · `!discard` (or ❌ and ❌ again on the question it asks, or plain words like "discard this" / "you can discard this as a test") · `!sync` (merge the latest base branch, agent resolves conflicts) · `!model opus|sonnet|haiku`
(full approvers; "use opus" in a message works too) · `rollback` (mention in channel or thread): runs the newest deploy
backup's ROLLBACK.sh under the lock. Owner/full approvers any time, limited approvers only if their ship is the latest.

`!cancel` (or a bare `stop` / `cancel` while something runs; requester or owner; a near-miss such as `cencel` or `stpo` gets "Did you mean !cancel?" and is not passed to the agent) stops the current step, agent turn or the runner's own check run,
killing the whole process tree (Claude's Bash tool and `timeout` start their own process groups, so a group kill alone orphaned test runs).
Messages queued before it are dropped, and no review or repair turn follows; the branch and worktree stay, and the next message continues.
A ship cannot be cancelled. An idle job is closed by the sweep after 7 days without activity. Housekeeping (`tidy()`, at start and with every sweep)
clears a job's pointer to a workspace that is gone and drops messages stuck in a finished job for over an hour (audit `stale-queue-dropped`).

## Threads

### Thread names

The thread opens with a cleaned copy of the request (mentions, the bot's name and filler like "hey, can you" removed, sentence case, at most 60 characters, else `Death Muffin request`). When the agent writes `.dm-title` (2-6 words, see `PROMPT-godot.md`) the runner sanitizes it (one line, no mentions, links, markdown or control characters, redacted, at most 57 characters) and renames the thread to it; a different title in a later round renames again. A marker shows the state: `🔧` the agent is working (set as soon as a turn starts), `📝` waiting for approval or shipping (a ship does not rename: Discord's 2 renames per 10 minutes are kept for the `✅`), `✅` shipped, `❌` discarded. `runner/lib/threadTitle.cjs` keeps only the newest wanted name per thread and sends at most 2 renames per 10 minutes per thread (Discord's limit), dropping no-ops. Renames are fire-and-forget ops (`{ rename: { threadId, name } }`) that the adapter applies with `setName`; failures are logged and skipped, archived threads are not touched. `job.title` in `jobs.json` is the current title, so a restart does not rename again; `!status` shows it. The bot started the thread, and Discord lets a thread's owner edit its name, so no new permission should be needed; if renames fail with "Missing Permissions" in the bot log, give the bot **Manage Threads** in `#death-muffin`.

Finished threads are archived so `#death-muffin` only lists live work (owner, 2026-10-11). Every 10 minutes the runner (`archiveQuiet`) archives a shipped or discarded job's thread after an hour without activity (`archiveAfterMin`, default 60) and an idle thread without a proposal after a day (`archiveIdleAfterMin`, default 1440); an open proposal, a running or queued job and a pending rename are never archived. The adapter applies `{ archive: { threadId } }` ops with `setArchived` and acks them (re-sent each minute while the bot is away). Archived threads stay in the channel's Threads list for anyone to browse; a message in one reopens it and it is archived again once quiet. `job.archived` in `jobs.json` records it.

### Rounds (one thread, many changes)
A thread does not close when its change ships (or is discarded, or swept after 7 idle days). The next message from an allowed requester starts a new ROUND in the same job record: a fresh branch `discord/<jobid>-<n>` and worktree cut from the current `origin/<baseBranch>`, proposal/shots/preview state reset, and a FRESH claude session (owner, 2026-10-10: resuming carried every earlier round into each step; one thread read 10M cached tokens). The first prompt starts with a note that this is a new round plus a one-line summary of the thread's earlier rounds (`job.history`: `{round, branch, shipSha | discarded, title, at}`). Follow-ups inside a round still resume that round's conversation. The audit log gets a `round` entry.
- A message sent while a ship is running is kept (shown as waiting). If the ship goes live, the next round starts at once and the message is processed there (attached images are carried over); if the ship fails, the job returns to idle/proposed and the message is handled on the same branch.
- Turns: `maxTurnsPerJob` (40) now counts per round; `maxTurnsPerThread` (120) is a hard cap over the whole thread.
- Step budget inside a turn (2026-10-11: a session re-reads its whole conversation on every step, so cost grows with steps x context; one 176-step, 443K-token session was a third of three days' spend). Every claude call gets `--max-turns <handoffEveryTurns>` (default 40; 0 = none). When a session stops there (`error_max_turns`), the runner asks that same session (`--max-turns 6`, context still cached) to commit finished work and write `.dm-handoff.md` (git-excluded: request, done, left, key files, gotchas, next step), then starts a FRESH session with the note plus the original request and carries on (audit `handoff {n, note}`, runs log `handoff`/`step`). Nothing is posted to the thread; one runner turn = one `job.turns`. After `maxHandoffs` (default 5) the turn stops with a plain "needed more than N sessions ... say continue" line; committed work stays.
- After a sweep a new message also starts a new round (the sweep only released the worktree; the thread and its context are still useful). Commands other than `!status` answer "nothing is open" in a closed thread.

### Images from people
The adapter downloads image attachments (png/jpg/webp/gif, Discord CDN only, <= 8 MB each, <= 4 per message) and sends them to the runner as `images: [{name, b64}]` in the `/event` body; anything refused stays in the "not visible to the agent" note with the reason. The runner checks the bytes look like an image and writes them to `<worktree>/.dm-inbox/<msgId>-<name>` (git-excluded), appending `[image attached by NAME: .dm-inbox/... — Read it to see it]` to that message so the agent can `Read` it; for a new @mention the files are written in `bind()` once the worktree exists. A job keeps at most 40 MB of images (`job.inboxBytes`), then refuses with a note. Image bytes are never redacted or logged. `/event` accepts bodies up to 48 MB (4 x 8 MB as base64 is about 43 MB); every other route keeps the 1 MB cap.

### Deleted threads
The adapter forwards discord.js `threadDelete` for threads under the configured channel as `{type: 'thread-deleted', threadId, ...}`. The runner removes the job's worktree, local + remote branch and preview dir at once, sets `status: 'deleted'` (history `{deleted: true}`, audit `thread-deleted`) and posts nothing to that thread again (queued outbox ops are dropped). A running step is cancelled and cleaned up when it unwinds; a ship in progress is never interrupted: it finishes, then the cleanup runs and queued messages do not start a round. A deleted job ignores all further events and is skipped by the sweep.

## Pictures and videos

### Screenshots
**With a team PC online, pictures are automatic** (Helix, 2026-10-19: "no need to require !shot"; "Team PC pictures" below): the agent writes a shot plan for every visible change and the team PC renders it. **With none, only on request** (Helix, 2026-10-12): the agent renders on the server when the request asks for a picture or someone says `!shot`, never by default (PROMPT-godot.md); a proposal without pictures has a "Screenshots" field offering `!shot`.
`shot-godot.sh [plan.json]` (default `.dm-shot.json`; format in `client/main/qa_ui_shots.gd` and `PROMPT-godot.md`: up to 4 shots of windows/tooltips or the hero wearing gear, `open` / `hover` / `area` / `clip` / `give` / `equip` / `discipline` / `view` / `turn` / `anim`) renders the branch's own client on the dev-offline demo hero with a fixed
representative bag. Same sandbox as `check-godot.sh` (no network, read-only filesystem, only the worktree writable, private `/tmp` and a fresh HOME), in two runs:
the game's build products (`prep.sh`, above), then the branch's own `client/tools/qa_shots.sh <plan> <worktree>/.dm-shots/.raw <class>` (the plan's discipline,
default 2): Forward+ on the software Vulkan driver under `xvfb-run`, falling back to OpenGL 3 with a line saying so. Only the rendering holds the shared
`qa-browser.lock` (one renderer on the VPS), with a hard 15 minute limit (two shots take about 5 minutes).
The label is burned in OUTSIDE the sandbox by `label-shot.py` (trusted code; Pillow): every raw PNG becomes `.dm-shots/<name>.png` with "BRANCH PREVIEW · not live · <branch>"; directory fds + `O_NOFOLLOW`, only real PNGs
under 12 MB, names `[a-z0-9-]{1,40}.png`; anything else is skipped (exit 3) and nothing unlabelled is ever published, so a branch that edits the QA code cannot drop the label.
The game's side is `client/main/qa_driver.gd` and `client/main/qa_ui_shots.gd`, started only by `--qa` / `--shot-plan=` on a dev-offline debug start.
The agent is told (PROMPT-godot.md) to take pictures by default for visible changes (UI, windows, tooltips, HUD, visuals) and to skip them for logic/data/server work and pure Q&A.
On a proposal (`propose()`), when the agent left a plan and fresh pictures, the runner renders the same plan on an unchanged scratch worktree of the base (`base-<jobid>`, removed afterwards) and attaches
AFTER pictures right away (the embed image is the first). BEFORE pictures are off (owner, 2026-10-10: each was one more software-GL render in the shared queue); with `cfg.beforeShots: true`, the BEFORE/AFTER pairs for the first two pictures (`before-<name>.png`, then `<name>.png`) follow as a separate message once the base is rendered in the background, so a busy renderer never holds the job's slot. If the base cannot render (for instance it predates the QA shot-plan code) no pair message follows.

**Team PC pictures** (teamapp/README.md; the backend's "Team jobs" in server/death-muffin/README.md). A team PC (War's, Muffins' or Helix's) has a real graphics card, so with one
online the pictures need no `!shot` and come as BEFORE and AFTER pairs:

1. **The turn starts.** For every message that reaches the agent the runner asks the backend who is online (`GET /internal/team/pcs`: PCs seen in the last 2 minutes, a paused one
   left out because it declines every job). With one, the message gets a note ("A team PC is online right now ...") and the agent writes a shot plan (`.dm-shot.json`, PROMPT-godot.md
   "Screenshots") for every change players can see and renders nothing itself; a plan left by an earlier turn is deleted first, since it described an earlier change. With none, a note says
   so and everything is as before: pictures only on request (`!shot`), rendered on the server. `!shot` with a team PC online asks the agent for the plan only. The runner remembers the answer
   for the turn (`job.teamTurn`, `job.shotAsked`); a sync or fix-up turn asks nothing and sends no pictures.
2. **The proposal** goes out without server pictures. When the worktree has a plan and a PC is still online, its "Screenshots" field says "Pictures from a team PC follow" ("More pictures"
   when the agent rendered some on the server anyway; a plan with no PC left only offers `!shot`). A `!shot` on an open proposal (nothing changed) or on no proposal at all sends the plan
   for the current head the same way and says so in the thread.
3. **Before and after** (`teamShots` in `runner/core.cjs`, in the background; `cfg.teamShots: false` turns all of it off). The runner builds the branch for the team PC
   (`preview-godot.sh <jobid> --team`: a debug export, the live art pack hard-linked when the art is unchanged, files under `/var/www/death-muffin/team-files/<random>/`) and, when the
   branch has commits, the unchanged game too (a scratch worktree `teambase-<jobid>` at `job.base`, built the same way, removed afterwards, 25 minute limit). It queues ONE `shots` job,
   "Pictures of a change (before and after), about 3 minutes", whose payload carries `builds: [{label: "before", files}, {label: "after", files}]` instead of `files`, the shot plan and
   the presets Low and Ultra, with `requestedBy` and `thread` (the thread starter's name and the thread's name, which the team app's job list shows; a clip job carries them too); the app runs every preset on each build, shares the files both builds have (same hash) and uploads `<label>_<preset>_<shot>.png`. The runner checks the job
   every 20 s for up to 45 minutes and cancels it when a newer proposal, a discard or a thread delete makes the answer pointless.
4. **The thread** gets, a preset at a time (Low, then Ultra) and in the plan's order, each shot as a pair: BEFORE (the game as it is now), then AFTER (this change), at most two pairs a
   post and 20 MB (a post Discord refuses is lost), a pair never split. Every picture is labelled by `label-shot.py` like the server's ("BRANCH PREVIEW · not live · <branch>": the base branch's name on BEFORE, the job's branch on
   AFTER) and posted only after the label step; names are `before-low-<shot>.png` / `after-low-<shot>.png`, and the post says whose PC and card made them (`bogar1's PC, Intel Arc B580`).
5. **Screen sizes.** A shot plan may carry `resolutions`: up to 4 different sizes from `1920x1080`, `2560x1440`, `3840x2160` and `3440x1440` (default: only the standard 1920x1080, team app 0.4.7), which
   the prompt asks for on UI changes (windows, tooltips, the HUD). `readShotPlan` (`runner/lib/clips.cjs`) checks the list: a list that is not allowed is dropped and the first post says so
   ("The screen sizes asked for were not usable ..., so the standard size was used"). A valid list stays in the plan the app gets and is also set beside it as the payload's `resolutions`;
   the app runs every size and the pictures keep their size in the name (`before-low-1920x1080-a.png`). A job holds at most 40 pictures (builds x presets x shots x sizes): over that the
   job renders Ultra only, and when it is still too many the BEFORE pictures go; the first post says which.
6. **Fallbacks, all best effort.** The base would not build, or the branch has no commits of its own: one job with one build (`files`, "Screenshots of a change, about 2 minutes") and AFTER
   pictures only, flat as before ("Low then Ultra"; the post says there is no BEFORE). The pair's job fails (the plan uses a window or item only the change has, which the unchanged game
   cannot run): the same plan is asked again as one build, once. No team PC online by the time the proposal is posted: the server-rendered picture on request, as before. A failed build or
   job is audited (`team-shots`) and, when the proposal said pictures follow, said in the thread in one line ("⚠ No pictures from a team PC this time (<reason>). Say `!shot` to ask again.").
   Nothing here widens an approval: the team PC only renders, a human still ✅.

`cfg.teamApi` is the backend the runner calls (with the runner's secret), `cfg.teamResultsDir` where it keeps the uploaded files (the runner only reads files it lists for the job, inside
that job's folder), `cfg.teamPollMs` how often a job is checked. Tests replace the build and label steps with `cfg.teamBuildCmd` / `cfg.teamLabelCmd` and run against a fake backend
(`test/e2e.test.cjs`: `teamBackend`).

### Clips and choices (short videos, "pick one")

`runner/lib/clips.cjs`, `clipStage` in `runner/core.cjs`. When a request is about how something moves or looks in motion (speed, size,
timing, colour), or the agent wants the requester to choose between a few values, it writes `.dm-clip.json` instead of changing anything (PROMPT-godot.md "Clips and choices"; only when a
team PC is online):

```json
{"plan": {"discipline": "reaper", "clips": [{"name": "wraith", "area": "graves", "cast": "haunting_wraith", "at": "pack", "enemies": 6, "seconds": 5, "camera": "follow"}]},
 "variants": [{"label": "slow", "title": "slow (speed 4)", "tune": {"combat/abilities": {"haunting_wraith": {"speed": 4}}}}, {"label": "fast", "title": "fast (speed 14)", "tune": {"combat/abilities": {"haunting_wraith": {"speed": 14}}}}]}
```

- **The runner validates it before anything is sent** (`readClipRequest`): at most 32 KB, a regular file; the plan is the game's clip plan (`--clip-plan`: discipline, an optional `equip`
  (1 to 12 item ids the hero wears for every clip), 1 to 4 clips of at most 8 seconds, each `name`, `cast` (the rite; a turntable clip needs none), `area` (default graves), `at` pack or
  ahead, `enemies` 0 to 12, `seconds` (default 5), `camera` follow, wide or turntable, an optional `equip` that replaces the plan's list for that clip, optional `setup` and `steps` checked against the game's word list in the job's own branch
  (`client/main/qa_clip_steps.json`: known words and arguments, their types and ranges, a step's `at` within the clip; a clip whose steps cast needs no `cast`; a branch without the file is told to merge main), and no other field); 1 to 4 variants with a unique `label` (lowercase letters, digits,
  dashes, at most 24), a `title` of at most 60 characters and a `tune` (the game's data overrides, `{"<DmDb path>": {<nested keys>: <value>}}`: values only text, numbers and true/false, at most 64,
  at most 6 levels deep; the game itself refuses a key that does not exist, so a typo fails loudly). A bad file goes back to the agent to fix, twice; then the thread gets one readable line
  ("I could not make the short videos: variant 1 has an unknown field ...") and the turn carries on without. The file is removed whatever the answer.
- **The job.** With a team PC online (none: "Short videos need a team PC online, and none is right now ... Say `!clips` once a team PC is on"; the request is kept), the runner builds the branch for
  it as above and queues a `clip` job, "Short videos of a change: N options, about M minutes" (M from the clips' seconds: each option is one game run), payload `{rev, godotVersion, files, plan,
  variants: [{label, tune}], presets: ["high"], args}`. The app runs the game once per variant (1920x1080, 60 frames a second), makes each clip into `<label>_<clip>.mp4` on the PC (under 8 MB, Discord's
  limit for the bot) and uploads it (teamapp/README.md "The clip job"). The turn ends at once (no proposal; the slot is free) and the waiting goes on in the background, for up to 45 minutes.
- **The thread** gets each video as its own post (one at a time, each sent before the next is queued, so a few large videos never pile up in memory) numbered by option, "1 · slow (speed 4)" (and the clip's name when an option has several clips), then "Recorded on <who> with the offline demo
  character on this branch (not the live game). Which do you like best? Reply with its number." A video over 8 MB or missing is named in that last post instead.
- **Model previews** (a new or changed armor set, weapon or helm; PROMPT-godot.md "Clips and choices"): ONE variant with an empty tune and a clip with `camera: "turntable"` and the gear in
  `equip`, so the requester sees the piece turning on a hero in the game's own lighting. With a single option nothing is a choice: the video is posted under its title (no number, no
  question, no `job.clipAsk`) and the turn is **not** held back: its proposal goes out as usual (the team build is made before the check, a couple of minutes) and the video follows it.
- **The reply is a normal message.** The agent's next turn starts with a note listing the options' values as people saw them (so a fresh session knows what "the second one" was), and it applies
  the chosen values as a normal change: data or code the change really reads (a tune only existed for the recording), tests, commit, proposal (with a shot plan when visible). The proposal clears
  the question (`job.clipAsk`).
- **`!clips`** records the last request again (`job.lastClip`, kept across restarts; also after "no team PC online"): same plan and options, the branch as it is now.

### Release checks
A team PC can check a revision before it goes live (install and boot, quitting while the art loads, the standard screens at four sizes, a stutter
pass over every rite, the benchmark, a soak): `server/death-muffin/team-check.sh`, run by a session when someone asks (server/death-muffin/README.md
"Team jobs", DECISIONS B62); nothing runs after a release. Every client publish, the ship's included, first has a free team PC start the build and quit
it while loading (`team-gate.sh`, B61). The agent does not start these checks and does not run them as part of its tests (Helix, 2026-10-20, B62). PROMPT-godot.md only tells it they
exist and where to point people.

### Playable preview
The Windows zip (`preview-godot.sh`, see above) is built only on request: the proposal's "Try it" field says to use `!preview` (owner, 2026-10-10:
44 previews were built in a day and none was downloaded; each is a full import + export). `cfg.previewOnProposal: true` brings back building one with every
proposal. A failed build says so with a short reason. The
preview folder is deleted when the job ships, is discarded or is swept (`removeJobArtifacts`). `previewRoot` (default `/var/www/death-muffin/preview`, must exist and be
writable by the runner user) and `previewCmd` (replaces the script, tests) are in config.

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
agent turn ── told the files are ready: build-art.sh <id> per model (sandboxed: tools/build-characters.mjs, then dequantize into client/assets/slice/models/...), commits specs + records + GLB,
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
agent turn ── build-sound.sh <id> <take> (sandboxed sound-build.mjs: levels the take to -20 LUFS, peaks at most -1.5 dBTP, a plain gain; sfx ->
              client/assets/audio/eleven/<id>.wav mono 16-bit, music -> .mp3; writes the sound's row in docs/AUDIO-SOURCES.md, the licence record),
              wires it in, commits spec + asset + .import + docs/AUDIO-SOURCES.md, then the usual proposal / ✅ ship
```

- Key: `/home/ubuntu/death-muffin/private/elevenlabs-api-key` (`soundKeyFile`), hidden inside every sandbox by `sandbox-lib.sh`, registered with `redact.cjs` (plus an `sk_` pattern).
  The key has no `user_read` permission, so the balance cannot be read; the cost comes from ElevenLabs' `character-cost` header per take (a 1 s effect cost 11 credits, 2026-10-11).
- Ledger: `eleven-ledger.json` (tools dir, mode 600): `{id, ts, userId, userName, jobId, specId, kind, seconds, variants, files, credits, result}`. `!credits` shows a sound user's total.
- A take that already exists is not generated again, so a retry pays only for missing takes. Audit events: `sound-start`, `sound-result`, `sound-refused`, `sound-invalid`.
- Config keys (optional): `soundUsers` (Discord ids), `soundKeyFile`, `soundRunScript` (`<toolsDir>/sound-run.mjs`), `soundLedgerFile`.
- Tests: `test/sound.test.cjs` (validation, refusal, ledger, a fake ElevenLabs server for sound-run.mjs; no API is called) and `test/sound-build.test.cjs`
  (levelling and the licence row, on real ffmpeg takes).

## In-game bug reports (#in-game-reports)

Every new player report (Settings -> Report a bug) gets its own thread in #in-game-reports (`bugChannelId`), so the devs see what is reported.
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

## Under the hood: checks, previews and the ship

The agent works only on the game (`client/`, DECISIONS B57: the retired web game's mode, its scripts and its tests are gone; a config that says
`"mode": "web"` is refused, `"mode": "godot"` is accepted and ignored). `baseBranch` (default `main`) must match `^[A-Za-z0-9._/-]+$` (not start with `-`,
contain `..`, `//`, end in `/` or `.lock`); a bad value makes the runner refuse to start. It is used for the worktree base (`origin/<baseBranch>`), `!sync`,
the ship merge and push, messages and the compare link.

Tests: GitHub CI through `ci.sh` (`tools/check/ci.sh`, installed here; `check-godot.sh` for a re-run of 1-3 suites, the agent's `--rerun <suites>`, and everything
with `ciGate: false`) · generated files `regen-godot.sh` · preview `preview-godot.sh` (a Windows `.zip`) · screenshots `shot-godot.sh` / `!shot` (or a team PC, no `!shot`)
· prompt `PROMPT-godot.md` · tier rules `tiers` · ship: merge, CI or check-godot, backup + `ROLLBACK.sh`, push, backend and lobby when changed,
`publish-godot-client.sh` · rollback folder `backup-pre-release-godot-<stamp>`.

**Progress notes** while a turn runs: `🔧 <pct>% · <sentence> · ⏱ <min> min`. The agent writes `.dm-status` as `<pct>% · <sentence>` (prompt
`PROMPT-godot.md`); fewer thread posts (owner, 2026-10-10): the first status posts at once, later ones only when it changed and at most every
`statusEveryMin` (default 15); no timed notes, no "On it" line, no "checks found a problem" line (fix-up turns are in the audit log only).
While `check-godot.sh` runs it keeps
`<done> <total>` suites in `.dm-check-progress`, and the note's percentage moves from the agent's number toward 95% (`progressNote` in
`runner/core.cjs`). Both files are git-ignored. Model generation posts `🎨 Still generating "<id>"` with the minutes instead.

**The game's build products** (`tools/check/prep.sh`, installed here as `prep.sh`; the game's one setup, tools/check/README.md): a job's worktree has
no combat core library, Godot import, crowd bakes or lobby packages (git does not hold them, and a fresh build takes minutes). `prep.sh --warm <base>
<worktree> [--windows]` runs OUTSIDE the sandbox (called by `check-godot.sh`, `shot-godot.sh` and `preview-godot.sh`): it makes sure the shared cache
`~/death-muffin/build-cache/` (`DM_BUILD_CACHE`) holds them for the job's base revision (where its branch left `origin/main`: approved code), building
whatever is missing in a scratch worktree of that revision with that revision's own `prep.sh`; with everything cached it only checks the keys. It never
writes into the job's worktree and never builds a job's files, so a job cannot plant a library, an imported scene or a bake that another job loads.
Inside the caller's sandbox, `prep.sh --read-only <worktree>` copies in what is cached for the job's own inputs, so only what the job changed is
rebuilt there (the core on its own copy of godot-cpp in `.dm-native-cache/`, git-ignored; the shared one is read-only), stores nothing, and imports.
A job that changes the lobby's `package-lock.json` gets a plain line that its packages are not cached (the sandbox cannot download them).
`DM_PREP` names a stand-in (tests).

**`check-godot.sh`**: the shared sandbox (`unshare -rnm`, loopback only, whole filesystem read-only, only the worktree writable, scratch tmpfs over
`node_modules/.vite`), with `HOME` and the XDG dirs in a fresh `/tmp/dmgodot.*` (inside the sandbox's private /tmp) so Godot's `user://` never touches the real home. In order: the repo hygiene check
(`tools/hygiene/check.mjs`, the same `npm run hygiene` CI runs: a stale doc link, missing path or retired term fails with `GODOT TESTS: repo hygiene FAILED`); a change
that only touches Markdown files stops there (`GODOT TESTS: skipped, docs-only change`); the model check on the models the change adds or edits
(`tools/assets/check-models.mjs --changed`); the game's build products (above; `GODOT TESTS: preparing the game FAILED` when they cannot be made; before the sandbox it also
links the lobby's packages (the main checkout's lobby `node_modules`) into a worktree that has none, since coop, coop_bosses and lobby/ui start the real lobby); then
`tools/rebuild/run-client-tests.sh` (one line per suite, `<suite> <file> exit=<code> <result>`; `GODOT` defaults to `/home/ubuntu/tools/godot/godot`; suites side by side, 8 by
default and fewer on a busy machine, the slowest first, the real-socket suites in a lane of their own, each failure once more alone: its header). While the suites run it writes
`<done> <total>` to `.dm-check-progress` in the worktree (removed at the end) for the progress notes. It has two modes. **Quick** (default; the runner before a proposal): `tools/rebuild/affected-suites.mjs` picks the suites for the change (changed suites; suites referencing a changed file by `res://` path or
`class_name`, one level through non-test dependents; for changed `client/data` files the scripts that load them, by path or DmDb accessor; plus a smoke set
`code_load core_smoke game_scene`; a `client/data/content/*.json` change also runs `rules_core`, which reads every content table) and `run-client-tests.sh --only <list>`
runs them. It prints `ALL` (every suite) for central changes (`project.godot`, `export_presets.cfg`, the combat core `native/`, `client/main`, `client/core`, `client/rules/core`,
`client/net` (except a change that only adds lines to `dm_api.gd` / `dm_mock_backend.gd`: that selects the suites using the added `func` names and `/api/...` routes, one level
through dependents), `client/session`, the shared test helpers, the runner), more than 40 changed `.gd` files, or more than 60% of suites selected; nothing for docs-only.
**`--full`** runs every suite (without the CI gate, `ship.sh` passes it for a sensitive-tier change; other ships run the quick check on the merged tree).
**`--rerun a,b`** runs hygiene plus exactly those suites, one at a time: when a check fails only 1-3 suites (nothing outside the suites), the runner (before a proposal;
audit `flake-rerun`) and `ship.sh` re-run just those once before an agent turn is spent or the ship fails; a pass reads `... — passed (x passed on a re-run)`. The failure
handed to the agent leaves out the passing suite lines. The agent may run the check only this way, naming the suites it needs
(`Bash(<tools>/check-godot.sh --rerun *)`; a name is a suite of `client/tests`, `/` allowed, no dots): to debug the suites the runner reported failing, or the
test it wrote. The whole quick check is the runner's, after the turn, so a round runs it once; the fix-up turn names the command, and art and sound imports use `--rerun code_load`.
`DM_TEST_JOBS=N` adds `--jobs N`. The progress total is the number of selected suites. It ends with
`GODOT TESTS: quick (14 suites) — 14 passed` or `GODOT TESTS: full (109 suites) — 109 passed` (`, N FAILED` on failure; `targeting fell back to all` is noted); the proposal's
"Tests" field reads `quick check: N suites — ...`. It exits non-zero on any failing suite or step, and has a hard 85 minute limit.

**Before the check** (`cfg.syncBeforeCheck: false` turns it off) the runner merges the latest base branch into the job's branch (a commit
`Merge main into discord/<job> before the check`, audit `pre-sync`) and measures the job's work from it, so the check tests what a ship would merge and a ship of
the same tree skips its tests; a conflict is undone (`pre-sync` with `ok: false`) and left to the ship's own sync. Merge commits never become a proposal's title
or bullets. **After a failed check** (`cfg.baseCheck: false` turns it off) the failing suites, at most 6, run with `--rerun` on a clean copy of the base
(`<worktreeRoot>/basecheck-<job>`, removed after; audit `base-check`). Any that fail there too stop the job with "⚠ Not this change: ... fail on main without
this change too" (audit `infra-failed`): nothing is proposed and no repair turn is spent, since no change in the job can fix the test setup or main. The
automatic re-run of 1-3 failing suites (the runner's `failedSuites`, and `ship.sh`) reads every suite line, folder runners such as `relay/udp` too, and
is skipped when those lines do not account for the summary's `N FAILED`, so a failure it cannot name never rides on another suite's passing re-run.

**`regen-godot.sh`** (the agent's, DECISIONS B65): the files the game derives from its sources, made in the same sandbox as `check-godot.sh` (no network, only the
worktree writable, a private HOME): `node tools/generate-armor-assets.mjs` (the sets' client data copies, the content manifest, item icons, the new migration),
`npm run build:server-rules` (the backend's `*-rules.cjs` bundles) and `UPDATE_LOOT_PARITY=1 vitest run server/rules/gameplay/__tests__/` (the loot rules' tests, rewriting
the recorded answers `client/tests/rules_loot/fixtures` holds), each up to 10 minutes and run even when one before it failed, then `git status`; exit 1 when a step
failed. The agent runs it after any edit under `server/rules/` and for an armor set (PROMPT-godot.md); CI's "Generated files are current" step and the rules tests
fail a change whose generated files are not exactly the generators' output, so a forgotten run never ships. `test/sandbox.test.cjs` runs it with stand-in generators
that try to write outside the worktree.

**`preview-godot.sh <jobid>`**: runner-only. The game's build products with the Windows core (`prep.sh --warm --windows`), then inside the same kind of sandbox the
export of the `Windows Desktop` preset from `client/` (the installed export templates are linked read-only into the fresh `XDG_DATA_HOME`). The art: when nothing the
art pack is made of (`tools/godot/assets-fp.sh --paths`, `main`'s copy) differs from the live build's revision (the client manifest's `rev`), the zip carries no pack
and its `.bat` starts the game with the installed game's pack (`--assets-pack=%LOCALAPPDATA%\DeathMuffin\client\DeathMuffin.assets.pck`, and says to install the
game first when it is missing); otherwise `tools/godot/assets-pack.sh` builds the branch's own pack into the zip (about 500 MB). Outside, it zips `DeathMuffin.exe`,
`DeathMuffin.pck`, the core's DLL, the pack when there is one, `Play Preview (offline).bat` (starts `-- --dev-offline`) and a README ("nothing saves to your real
character") to `<previewRoot>/<jobid>/DeathMuffin-Preview-<jobid>-win64.zip` (mode 644; job ids `^[0-9a-f]{6}$`, no symlinked root or destination, nothing else is
left in that folder). The proposal's "Try it (Windows download)" field and `!preview` link to the zip; it is deleted with the job like any preview. The runner
allows 40 minutes.

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
publishes it. Then **the lobby**: `deploy-lobby.sh --if-changed --wait $LOBBY_WAIT_MIN <sha>` from the revision itself (default 30 min wait for running parties to end; `Lobby: unchanged` or `Lobby: deployed <sha12>, rollback <path>`, which the godot `ROLLBACK.sh` runs with `--force` after the backend rollback; a lobby that never empties is `RESULT: deploy-failed <sha12> lobby busy` with the client untouched; `lobbyDeployCmd` replaces it in tests, and with `deployCmd` alone the step is skipped). The runner
accepts only exact `backup-pre-release-godot-<yyyymmddThhmmssZ>` real directories (no symlinks) with a `ROLLBACK.sh`.

## Without the CI gate (GitHub down)

With `ciGate: false` in `config.json` (the owner sets it while GitHub is down) every round is tested here before its proposal (`check-godot.sh`, quick by
default, "Under the hood" above), drafts are off, and a ship re-runs the check on the merged tree (`--full` for a sensitive change).

**Ship speed (owner, 2026-10-10; with `ciGate: false`).** The ship's re-test is skipped when the merged tree is exactly the proposal's (main did not move since), which already
passed the same quick check (never for a draft); a sensitive change still runs the full suite. **Backlog:** when another approved ship is waiting, the current one merges, tests
and pushes but does not publish (`DEFER_PUBLISH=1`, `RESULT: merged`; the thread is told it goes live with the next publish). The next publish carries it:
its notice lists both changes under both titles, and the waiting thread gets "🚀 Live" and closes (`healOtherPublishes`, logged in the ships log with
`batchedWith`). If nothing else ships, the runner publishes the merged one by itself (`drainShipQueue`). **One test run at a time:** `check-godot.sh` takes
`~/death-muffin/test-slot.lock` (shared with the ship; created by the installer) and waits for it, so parallel jobs no longer slow each
other down. A job's check gets the import from the shared cache (`prep.sh`), and so does the client publish.

## When the client publish fails

- ship.sh tries `publish-godot-client.sh` 3 times (30 s, 90 s apart) before giving up: a one-off Godot crash heals inside the ship.
- Still failing: the merge is already on the base branch, only the client is missing. The thread says so (the job stays usable), the owner is
  pinged, and the runner retries by itself after `publishAutoRetryMin` (10). Approvers can retry any time: ✅ on the failure message or `!retry`.
  A retry is `PUBLISH_ONLY=1 PUBLISH_SHA=<sha> ship.sh`: same lock and fresh rollback, no merge/tests/push, and it refuses to publish anything older
  than the live client (`RESULT: live-already`). Any later ship whose client contains the stuck commit posts "Live" in that thread too.
  When the release goes live that way (retry or a later ship), the job ends like a normal ship (`shipped`, ✅ title, worktree, branch and preview
  removed) if the thread has not moved on: idle, nothing queued or proposed, and a clean workspace whose HEAD is inside the published release.
  A thread that already works on its next change keeps its workspace (the sweep closes it later).

## Parallel jobs and long checks

- `maxConcurrentJobs` (1-3, live: 3) lets several threads work at once, so one person's long request does not queue everyone else. Ships
  still go one at a time behind the deploy lock. Git commands that hit a lock file another job is holding retry a few times (gitops.cjs).
- Run here, all 109 suites take about 6 to 7 minutes side by side (the full check, only without the CI gate; CI takes about 3 minutes); the quick check of a
  spell-sized change (42 suites, co-op included) about 5 minutes end to end, prep and hygiene included; the agent runs only the suites it names. The agent's `claude -p` gets `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` and a 55-minute Bash limit (turn limit 60 min, check-godot.sh hard limit 85 min)
  (`BASH_DEFAULT_TIMEOUT_MS`/`BASH_MAX_TIMEOUT_MS`), so the check call simply blocks until it finishes. `sleep`, `pgrep`, `ps`, `watch` and the like are on
  `--disallowedTools`. Why: a backgrounded check plus an agent-written `pgrep` wait loop matched itself and hung a job (and the queue) for 35 minutes.

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
  `check-godot.sh --rerun <suites>`, `regen-godot.sh` and `shot-godot.sh` (unshare -rnm: no network, home read-only except the worktree). No push, no deploy, no secrets in its env.
- Discord's 2000-character limit: agent replies are split across messages (code blocks kept balanced) and anything over ~4 messages is a preview plus `reply.md` (`runner/lib/discordText.cjs`). A long paste arrives as Discord's `message.txt`; the adapter reads text attachments from Discord's CDN only (≤100 KB each, ≤60,000 characters in all) into the person's message.
- Person text is wrapped as data (`<request from=… role=…>`, role from config); rules cannot be changed by messages.
- Runner redacts every outgoing string and audit field; mentions are disabled (no post tags anyone).
- Audit log: `state/audit.jsonl` (every request, proposal, approve/refuse, ship result, rollback); ships: `state/ships.jsonl`.
- ship + rollback + `deploy-release.sh` all take `~/death-muffin/deploy/.deploy.lock`.
- Residual risk: `ship.sh` re-runs `check-godot.sh` on the merged tree in the same sandbox, but `publish-godot-client.sh` exports the project outside it. That is why test configs, package files and
  scripts are sensitive/forbidden, and why the proposal links the exact diff for a human to read before ✅.

## Install (from a committed revision; nothing starts by itself)
1. `bash server/death-muffin/discord-agent/install-runner.sh <rev>`: tooling to `~/death-muffin/discord-agent`, `config.json` (owner id from
   `/opt/crossworlds-bot/.env`), `secret`, systemd unit (not started).
2. `bash install-bot.sh <rev>` (sudo): `/opt/muffin/discord/dm-agent.js`, patched `bot.js` (backup kept), `/opt/muffin/dm-agent.env`. When the live `bot.js` already loads `./dm-agent` but carries other hooks too (the Hammy Xchange agent patches the same file from its own repo), it leaves `bot.js` alone and updates only the adapter and env (old adapter backed up); a `bot.js` without the hook is refused as before.
3. `sudo systemctl enable --now death-muffin-discord-agent`, then `sudo systemctl restart muffin-discord`.

Tests (part of CI's backend job; about 2 minutes, need git, `unshare`, `zip` and `unzip`): `node --test server/death-muffin/discord-agent/test/*.test.cjs`.

**Practice run** (Helix, 2026-10-19: so a promoted test build or a reinstall cannot break the agent unnoticed): after every `install-runner.sh`
and every test build that goes live, with the agent restarted and idle, run `node ~/death-muffin/discord-agent/runner/canary.cjs` before it takes
requests (about 4 minutes). It drives the installed runner and the live Discord adapter with a fake Discord (nothing is posted) and a stand-in for
`claude` (one harmless commit, no AI cost) through a whole proposal on the real repo: the installed copies equal `main`, the live agent is idle,
request -> thread -> worktree -> gates -> pushed branch -> a draft proposal with ✅ 🧪 ❌, the agent's own check in its sandbox
(`check-godot.sh --rerun code_load`), 🧪 -> GitHub CI on the branch -> "Tests passed", then `!discard` removes the branch and the workspace. It
never ships. One `CANARY <step> ok|FAILED` line per step, then `CANARY PASSED` (exit 0) or `CANARY FAILED: <step>` (exit 1). A trial before a
merge: `DEST=<dir> NO_SYSTEMD=1 bash install-runner.sh <rev>`, then `node <dir>/runner/canary.cjs --rev <rev> --adapter <repo>/server/death-muffin/discord-agent/bot/dm-agent.cjs`.
The installer also copies `check-godot.sh`, `regen-godot.sh`, `tools/check/prep.sh` (as `prep.sh`), `preview-godot.sh`, `shot-godot.sh`, `label-shot.py`, `render-model.sh`, `render-model.py`, `art-run.sh`, `build-art.sh`, `build-sound.sh`, `sound-build.mjs` and `PROMPT-godot.md`, installs the trusted art tools to `art-tools/`, and creates an empty `tripo-budget.json` if there is none (never overwritten). The live `config.json` must say `"mode": "godot", "baseBranch": "main"`; edit it and restart the service to change.
