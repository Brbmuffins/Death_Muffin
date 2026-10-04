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
   ├─ per request: git worktree + branch discord/<id> from origin/master, `claude -p` (sandboxed, --resume per thread)
   ├─ verify (runner code, not the AI): commits clean · no Co-Authored-By · forbidden paths · secret scan · check.sh · tier
   ├─ propose: push branch, embed with tier / files / tests / migrations / compare link, ✅ ❌
   └─ ship.sh (only after an approver's ✅): deploy lock · merge onto master · re-gate · re-test · push master · deploy-release.sh
```

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
deploy scripts, package.json/lockfiles, configs, `.github`, `tools`, CLAUDE.md. Paths that would change the agent itself,
deploy scripts or `.env*` are refused outright (`forbiddenPaths`). `ship.sh` re-derives the tier from the merged diff under
the deploy lock, so an approver can never ship above their tier.

## Chat commands (in the thread, handled by the runner, not the AI)
`!status` · `!shot` (screenshot of the change) · `!cancel` · `!discard` (or ❌) · `!sync` (merge latest master, agent resolves conflicts) · `!model opus|sonnet|haiku`
(full approvers; "use opus" in a message works too) · `rollback` (mention in channel or thread): runs the newest deploy
backup's ROLLBACK.sh under the lock. Owner/full approvers any time, limited approvers only if their ship is the latest.
Rollback undoes the live release only; revert the commit on master afterwards.

## Safety summary
- AI box: `claude -p --restricted --permission-mode dontAsk`, tools = Read/Edit/Write/Glob/Grep + `agit` (filtered git) +
  `check.sh` (unshare -rnm: no network, home read-only except the worktree). No push, no deploy, no secrets in its env.
- Discord's 2000-character limit: agent replies are split across messages (code blocks kept balanced) and anything over ~4 messages is a preview plus `reply.md` (`runner/lib/discordText.cjs`). A long paste arrives as Discord's `message.txt`; the adapter reads text attachments from Discord's CDN only (≤100 KB each, ≤60,000 characters in all) into the person's message.
- Person text is wrapped as data (`<request from=… role=…>`, role from config); rules cannot be changed by messages.
- Runner redacts every outgoing string and audit field; mentions are disabled except the owner ping.
- Audit log: `state/audit.jsonl` (every request, proposal, approve/refuse, ship result, rollback); ships: `state/ships.jsonl`.
- ship + rollback + `deploy-release.sh` all take `~/death-muffin/deploy/.deploy.lock`.
- Residual risk: tests run **unsandboxed** inside `deploy-release.sh` on the merged tree. That is why test configs, package files and
  scripts are sensitive/forbidden, and why the proposal links the exact diff for a human to read before ✅.

## Install (from a committed revision; nothing starts by itself)
1. `bash server/death-muffin/discord-agent/install-runner.sh <rev>`: tooling to `~/death-muffin/discord-agent`, `config.json` (owner id from
   `/opt/crossworlds-bot/.env`), `secret`, systemd unit (not started).
2. `bash install-bot.sh <rev>` (sudo): `/opt/muffin/discord/dm-agent.js`, patched `bot.js` (backup kept), `/opt/muffin/dm-agent.env`.
3. `sudo systemctl enable --now death-muffin-discord-agent`, then `sudo systemctl restart muffin-discord`.

Tests (not wired into test:server; ~1 min, needs git): `node --test server/death-muffin/discord-agent/test/*.test.cjs`.

## Screenshots
The agent can look at its own change: it writes a scenario (`.dm-shot.json`) and runs `shot.sh` (`shoot.cjs` documents the format; dev server + headless Chromium in a no-network sandbox, ~1 min, one at a time). PNGs land in `<worktree>/.dm-shots/`, which together with `.dm-shot.json` is git-excluded (`createWorktree`), so they never dirty the tree or get committed.
- On demand: ask in the thread ("show me what it looks like") or use `!shot` (any requester; queues a turn that takes one).
- After every turn the runner posts new or changed PNGs to the thread (max 4, skips files over 8 MB with a note, each unchanged file once).
- A proposal attaches the current PNGs (newest first, max 4) and shows the first one as the embed image, next to ✅/❌.
- Transport: outbox ops carry `files: [{name, b64}]` (never redacted, names sanitized); the adapter sends them as Discord attachments. Existing job worktrees keep their old `info/exclude` until the next job is created (it is a shared file).

## Playable preview
Each proposal gets a "Try it" link: `https://muffindevelopment.com/death-muffin/preview/<jobid>/`, the branch's OFFLINE EDITION build (its own in-browser store and token key, so it cannot touch the live server or a real character).
- `preview.sh <jobid>` is run by the runner (never the AI, not in its allowedTools) from the job's worktree. Build: same sandbox as `check.sh` (no network, home read-only, scratch tmpfs over `node_modules/.vite`), `VITE_OFFLINE_BUILD=1`, base `<previewUrl path>/<jobid>/`, output `.dm-preview/` (git-excluded). The service-worker/PWA step is skipped on purpose, so a preview cannot interfere with `/play/` or `/offline/`.
- Publish (outside the sandbox): a "PREVIEW of <title>" banner is inserted into `index.html`, then rsync `--delete --link-dest=<live offline dir>` to `<previewRoot>/<jobid>/`. Job ids must match `^[0-9a-f]{6}$`; nothing outside that directory is written. `previewRoot` (default `/var/www/death-muffin/preview`, must exist and be writable by the runner user) and `previewUrl` are in config; `previewCmd` replaces the script (tests).
- Built in `propose()` before the embed is posted (typing indicator keeps running; 15 min cap). Success adds a "Try it" field; failure adds "Preview build failed" with a short reason and the proposal is posted anyway. `!preview` rebuilds it on an open proposal.
- The preview directory is deleted when the job ships, is discarded or is swept (`removeJobArtifacts`).
