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
   ├─ verify (runner code, not the AI): commits clean · no Co-Authored-By · forbidden paths · secret scan · generated files re-derived · check.sh · tier
   ├─ propose: push branch, embed with tier / files / tests / migrations / compare link, ✅ ❌
   └─ ship.sh (only after an approver's ✅): deploy lock · merge onto master · re-gate · re-test · push master · deploy-release.sh · (best effort) merge master into `mobile`, test, push, deploy-mobile.sh
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
`!status` · `!cancel` · `!discard` (or ❌) · `!sync` (merge latest master, agent resolves conflicts) · `!model opus|sonnet|haiku`
(full approvers; "use opus" in a message works too) · `rollback` (mention in channel or thread): runs the newest deploy
backup's ROLLBACK.sh under the lock. Owner/full approvers any time, limited approvers only if their ship is the latest.
Rollback undoes the live release only; revert the commit on master afterwards.

## Generated files and phones
- `regen.sh` (agent-runnable, sandboxed like check.sh) rebuilds the generated server bundles, `docs/LOOT-TABLES.md` and the embedded
  realtime deploy script. Those paths are tier-neutral (and not "forbidden") ONLY when the runner (`runner/lib/generated.cjs`, in verify
  and again in `ship-gate.cjs`) re-runs regen.sh in a scratch worktree and finds them byte-identical. Any difference = refused.
- After the PC deploy is live, ship.sh (still holding the lock) merges the new master into `mobile` in a scratch worktree, runs check.sh,
  pushes `mobile`, runs `deploy-mobile.sh` and prints `MOBILE: live <sha12>`; on a conflict / failing tests it leaves `mobile` untouched and
  prints `MOBILE: pending <reason>` (the PC release stays live; the owner is pinged). `mobileBranch: ""` turns it off; a missing
  `origin/mobile` prints `MOBILE: skipped`. Test hook: `mobileDeployCmd` (replaces deploy-mobile.sh).

## Safety summary
- AI box: `claude -p --restricted --permission-mode dontAsk`, tools = Read/Edit/Write/Glob/Grep + `agit` (filtered git) +
  `check.sh` and `regen.sh` (unshare -rnm: no network, home read-only except the worktree). No push, no deploy, no secrets in its env.
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
