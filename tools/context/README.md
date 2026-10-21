# Context: what the rules cost and where they live

Claude builds this game (terminal sessions, the subagents they start, and the Discord dev agent) and Codex terminal sessions review and
plan it. Every one of them carries rule text on every call, and every call re-reads the whole conversation so far. This folder measures both and keeps
an inventory of the rules, so the rule text can be reorganised without losing a boundary.

```
node tools/context/measure.mjs                   # rule text per audience and section, and the inventory check (exit 1 on a problem)
node tools/context/usage.mjs --since 2026-10-18 --until 2026-10-20   # per audience: the window's calls, context read, session-start context, peaks, files and commands
node tools/context/usage.mjs --who agent --tokens-only --json out.json
node tools/context/usage-codex.mjs --since 2026-10-14 --until 2026-10-20   # the same for Codex terminal sessions, from Codex's saved rollouts (tokens only)
node tools/context/make-baseline.mjs <out.json> --label <rev> --window <since>..<until> --agent-window <since>..<until>
node --test tools/context/test/*.test.mjs        # also in npm run test:server, so in CI
```

## The audiences

`surfaces.json` names what each audience always carries, the guides it reads when a task needs one, and what it is told to read first:

| Audience | Always loaded | How |
|---|---|---|
| session | `CLAUDE.md` | Claude Code loads it for a session started in the repository, and for one started elsewhere once it works in a checkout |
| codex | `AGENTS.md` | Codex loads it when it starts in the repository: it reads `AGENTS.md` from the project root down to its launch folder, at launch only |
| agent | `server/death-muffin/discord-agent/PROMPT-godot.md` | the runner appends its round's snapshot to every call (`runner/lib/agent.cjs`, `runner/lib/guides.cjs`); the agent runs `--restricted`, which does not load `CLAUDE.md` |

The agent's guides (`server/death-muffin/discord-agent/guides/*.md`: screenshots, clips, pictures, models, sound) are not always loaded: the
runner copies them into the job's worktree (`.dm-guides/`) and the core prompt tells the agent to Read the one a workflow needs
(server/death-muffin/discord-agent/README.md "Prompt and guides"). A guide is therefore never the home that keeps a protected rule.

`AGENTS.md` is `CLAUDE.md` byte for byte: `CLAUDE.md` is the one written source, and `node tools/context/sync-instructions.mjs` writes the
copy (`--check` only checks; its test runs in CI and fails on a missing, empty or stale copy; `regen-godot.sh` runs the write too). One
text, two delivery files, so neither tool needs to read the other's, and every rule written in `CLAUDE.md` has the same clauses in
`AGENTS.md` for the `codex` audience (`rules.json`, locked like the others in `protected.json`). The Discord runner treats `AGENTS.md` as
sensitive, like `CLAUDE.md` (`runner/lib/config.cjs` `tiers`).

How sure that is (`usage.mjs` reports it per audience as "the repo's CLAUDE.md was injected in N of M sessions", from the `instructions`
and `nested_memory` records Claude Code writes when it injects an instruction file; a file merely read does not count):

- **Agent: never.** 0 of 124 agent sessions with calls 2026-10-04 to 2026-10-20 had it injected, while every interactive session started
  in the home folder in that time has an `instructions` record (for its memory file), so the record was being written. A direct probe on
  2026-10-21 (Claude Code 2.1.284, a scratch folder whose `CLAUDE.md` held a code word, no tools): `claude -p --restricted` answered that it
  had no project instructions; the same call without `--restricted` returned the code word.
- **Session: usually, not always.** 2026-10-18 to 2026-10-20: 10 of 12 interactive sessions and 15 of 39 subagents. A session that starts
  outside the repo gets it only when it works in a checkout's folder (a subagent that reads files through the shell may never), so for
  subagents "always loaded" does not hold; their briefs carry the rules they need. `surfaces.json` still treats `CLAUDE.md` as the
  session audience's always-loaded text, which is what the rule check checks.
- **Codex: only when it starts in a checkout.** Before 2026-10-21 the repository had no `AGENTS.md`, `~/.codex/config.toml` names no
  fallback instruction file, and Codex does not read `CLAUDE.md` on its own; it learned the rules only when told to read them. Every Codex
  session on the game through 2026-10-21 started in the home folder, and Codex builds its instructions at launch, so a later `cd` or
  `git -C` into a checkout loads nothing: a Codex session that starts outside a checkout (or works on another worktree) must read that
  checkout's `AGENTS.md` first. `usage-codex.mjs` reports per session whether Codex recorded injecting an `AGENTS.md`, and from which
  folder ("Codex usage" below).

Token figures are estimates from characters: `charsPerToken` (2.7) is what the agent's own calls show, where the first call's context grew
about one token for every 2.7 characters its prompt grew between 2026-10-11 and 2026-10-20.

## The rule inventory

`rules.json` lists every rule in those files: who it is for, when it matters, its kind (boundary, principle, convention, protocol,
playbook), each place it is written with the verbatim clauses that must stay there, and the code that enforces it, if any. Clauses
match with whitespace ignored, so rewrapping a line changes nothing; deleting or rewording words does. `protected: true` marks
permission, spending, deployment and server-authority boundaries. A protected rule lists every instruction it depends on as its own
clause (a rule that joins several boundaries lists each); a heading, a bold label or a fragment under six words is refused.
`protected.json` locks each protected rule: its audiences, a digest of its clauses and the gaps already accepted (the ones recorded with
the baseline inventory on 2026-10-20). `node tools/context/measure.mjs --print-lock` prints the entries the inventory has now.

`measure.mjs` (and its test, in CI) fails when:

- `rules.json` is malformed: an unknown field or kind, an audience `surfaces.json` does not name, a rule with no home, a home with no
  clauses, a gap with no note or for an audience the rule does not have;
- a clause is no longer in its file (the rule was reworded, moved or deleted: update `rules.json` in the same change);
- a protected clause is a heading, a bold label or too short to be an instruction;
- a protected rule has no home in the always-loaded text of an audience it names, and no gap for it;
- a protected rule disappears, stops being protected, loses an audience or changes its clauses, or a new protected rule or a new gap on
  one appears, while `protected.json` still says otherwise;
- an enforcing file named by a rule does not exist;
- a `## ` section of an always-loaded file holds no inventoried rule (a new section: add its rules);
- a guide in `surfaces.json` does not exist, is also listed as always loaded, or holds no inventoried rule.

The context test also keeps the owner principles (DECISIONS B71) and the spend-limit line in the agent's prompt: removing one, or giving it an
agent gap again, fails CI.

What this proves and what it does not: the check is structural. It shows that the listed words are still in the always-loaded text and
that any change to a protected rule or its exceptions comes with a change to `protected.json`, which shows in the diff. It cannot tell
whether anyone reviewed that diff, whether reworded text still means the same, or whether a model follows the rule. The code named in
`enforced` is what holds a boundary regardless of the text.

## Usage

`usage.mjs` reads Claude Code's transcripts (`~/.claude/projects/*/*.jsonl`, and `<session>/subagents/*.jsonl`). A transcript records every
API call's usage, so nothing extra is logged at run time. A Discord job is recognised by its start folder (`wt/discord-<job>[-<round>]`),
any other session by where most of its records ran.

**The window** is UTC dates with both ends included: `--since D` counts from D 00:00:00Z and `--until D` up to, not including, the next
day's 00:00:00Z. Every API call and tool result counts by its own timestamp, so a session that started before the window counts only its
calls inside it (the report says how many sessions started before), and one still running after it stops counting at its end. Every
transcript is read: file dates say nothing reliable about a copied transcript's calls. `--cohort` is the other view, named as such in the
output: whole sessions whose first call falls in the window, for comparing sessions that started after a change.

Per audience it reports:

- the context read by the window's calls (cache reads, cache writes, uncached input) and the output written;
- the session-start context: the first call of each session, wherever the window begins (system prompt, tools, rule text and the first
  message). Every later call re-reads it as its prefix, so the report also gives how much of the window's context it makes up (session-start
  context times the window's calls). The first call inside a window is not the same thing and is not reported as startup;
- context peaks and calls per session, and the files and shell commands whose output filled the context;
- `whatIfCap`, a hypothetical: what the window's calls would have read had the session compacted whenever it passed a lower point. It
  replays the whole session, leaves out the cost of the summary and the work redone after a compaction (files read again, lost detail),
  and is an upper bound on a saving, not evidence of one; choosing a compaction point needs a measured trial.

Dollars are list-price equivalents: each call is priced by its own recorded model and cache-duration breakdown (`PRICES`, from the
claude-api skill's model table cached 2026-09-25; `PRICE_SOURCE` says so in the output). A model with no listed price is reported as
unpriced, and a total that leaves such calls out says it is incomplete. Sessions on a subscription pay in plan usage, which a transcript does
not record per call; nothing here shows how list-price dollars map onto plan usage, so compare plan usage on its own meter. Tokens by model
are reported either way. `--tokens-only` drops dollars, and paths outside a
checkout are reported as one bucket, so the output can be committed. Claude Code deletes old transcripts after a while, so a baseline
worth keeping is committed as numbers. The characters-to-tokens estimates in `measure.mjs` are text sizes; only `usage.mjs` reports what
the API counted.

## Codex usage

`usage-codex.mjs` does the same for Codex terminal sessions, from the rollouts Codex saves (`~/.codex/sessions/**/rollout-*.jsonl` and
`archived_sessions`; `--dir` for another folder). It starts nothing and logs nothing new, and reports tokens only: no dollars, and no
account, plan, rate-limit or session fields (`--list` prints session ids for choosing a selection; keep that output private).

```
node tools/context/usage-codex.mjs --since 2026-10-14 --until 2026-10-20          # per kind and place: responses, input (cached / not), output, starts, peaks, reads
node tools/context/usage-codex.mjs --session <id> --session <id> --json out.json  # named sessions only (or --sessions-file <private list>)
```

What a rollout records (Codex CLI 0.163, 2026-10-21), and how the reader uses it:

- `session_meta` (id, launch folder, CLI version and source: `cli`/`vscode` is a terminal, `exec` is `codex exec`, a `subagent` source is a
  child) and `turn_context` (each turn's folder and model). A response takes its turn's model; with none it is `unknown`.
- `token_usage_record`: one per response, with that response's `usage` and the turn's and thread's running totals. The reader counts the
  per-response usage once per `response_id`, across every file, oldest file first, so the copy a resumed or forked rollout carries is
  not counted again (and that session's start is reported as inherited, not as a real first response). The running totals are never
  summed; the last thread total is the check that a rollout was read whole.
- `event_msg` `token_count`: cumulative snapshots. Older rollouts have only these; a response is then derived as a rise of the total, a
  repeated snapshot adds nothing and a smaller total starts again from zero (a reset). One rise can hold several responses, so such
  responses are reported as uncertain and never used as one response's context size. In a rollout that has both, snapshots count only
  before the first record. Snapshots lag behind the records, so they are not the coverage check when records exist.
- `input_tokens` is the whole input; `cached_input_tokens` is the part of it served from the cache (reported as cached and not cached,
  never added on top); `reasoning_output_tokens` is part of `output_tokens`; `cache_write_input_tokens` is reported as recorded.
- Tool calls (`custom_tool_call` `exec` in code mode, `function_call`) are paired with their output by `call_id`. A call that ran exactly
  one shell command is counted by command, and a simple single-file read (`cat`, `sed -n`, `head`, ...) names its file. Several commands
  in one call, code with no recognisable command, and multi-file reads go into an unattributed bucket: characters returned are a proxy,
  not tokens a file cost. Truncated and image outputs are counted apart.
- Instructions: `world_state` `agents_md` (or, from older CLIs, a user message that starts `# AGENTS.md instructions for <folder>`)
  shows which AGENTS.md Codex injected and from which folder. A command that reads AGENTS.md or CLAUDE.md is an explicit read, not an
  injection; a person naming the file is neither. A rollout with no `world_state` at all is "unknown", never "not loaded".

Which sessions count: `dm` sessions ran mostly in a checkout; `mixed` sessions started elsewhere (every Codex review so far started in
the home folder and read the game by absolute paths) and ran commands that name a Death Muffin path, so they are reported apart rather
than credited to the game as a whole; `selected` sessions were named with `--session`/`--sessions-file`. What a command returned never
decides it. The window works as in `usage.mjs` (UTC dates, both ends included, responses and tool output by their own timestamps;
`--cohort` for whole sessions that started in it). Warnings say where evidence is missing (no usage recorded is unavailable, not zero).

## Stage 2 2026-10-21

`stage2-2026-10-21.json`: the agent's always-loaded prompt went from about 18,700 to about 8,600 estimated tokens (54% less) when the media
how-tos became guides (about 11,300 tokens together, read only by the turns that use one). The core is above the 7–8K aimed for because it
gained the owner principles and the paid-generation limits and keeps when pictures and videos apply, since that decides what an ordinary
visible change does. The same change rewrote the owner principles as short guidance with the firm safety rules apart (DECISIONS B71), which
also made `CLAUDE.md` about 500 tokens smaller. Agent gaps went from 7 to 3 (`never-patch-installed`, `shared-vps-one-render`: held by code;
`read-first`: the agent still does not read those files). Text sizes, not API usage: what a session actually reads shows in `usage.mjs` over a
window after the change.

## Baseline 2026-10-20

`baseline-2026-10-20.json` holds the numbers before any change to how rules are loaded (`measure.mjs` on main 2ccce622, `usage.mjs` over
2026-10-18 to 2026-10-20 for everyone and 2026-10-11 to 2026-10-20 for the agent, calls counted by their own timestamps; the windows were
closed when it was made, so `make-baseline.mjs` with the command in its `about` remakes it while the transcripts last). It records what sessions read at the time, old paths included, so
the retired-term rules in `tools/hygiene/retired.json` allow `tools/context/baseline-*.json`.
