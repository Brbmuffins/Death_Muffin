# Context: what the rules cost and where they live

Claude builds this game (terminal sessions, the subagents they start, and the Discord dev agent); Codex terminal sessions read the same
rules when one is used. Every one of them carries rule text on every call, and every call re-reads the whole conversation so far. This folder measures both and keeps
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

`surfaces.json` names what each audience always carries, the guides it reads when a task needs one, and the small entry points it starts a
task from (`discovery`: README.md's "Documentation map" section and the client index, measured as that section or file, never as the
whole root README). `references` lists the client guides a task may open; they are measured apart and never counted as startup:

| Audience | Always loaded | How |
|---|---|---|
| session | `CLAUDE.md`, which imports `AGENTS.md` (`delivery: claude-code`) | Claude Code loads it for a session started in the repository, and for one started elsewhere when it reads, writes or edits a file in a checkout; the `@AGENTS.md` line brings the rules in |
| codex | `AGENTS.md` (`delivery: raw`, `maxBytes` 32768) | Codex reads `AGENTS.md` as bytes from the project root down to its working folder when a session starts (and on its own lifecycle reloads: trust or permission changes, fork, resume; never on a shell `cd`), with no import expansion and a 32 KiB default budget |
| agent | `server/death-muffin/discord-agent/PROMPT-godot.md` | the runner appends its round's snapshot to every call (`runner/lib/agent.cjs`, `runner/lib/guides.cjs`); the agent runs `--restricted`, which does not load `CLAUDE.md` |

The agent's guides (`server/death-muffin/discord-agent/guides/*.md`: screenshots, clips, pictures, models, sound) are not always loaded: the
runner copies them into the job's worktree (`.dm-guides/`) and the core prompt tells the agent to Read the one a workflow needs
(server/death-muffin/discord-agent/README.md "Prompt and guides"). A guide is therefore never the home that keeps a protected rule.

**One source.** `AGENTS.md` is the one written source of the rules; `CLAUDE.md` is a maintainer comment and one `@AGENTS.md` line, which
Claude Code expands when it loads `CLAUDE.md` (code.claude.com/docs/en/memory; probed 2026-10-21: a start-up `instructions` record lists both
files, a nested load writes one `nested_memory` record each, the imported one naming its `parent`, and HTML comments are removed from both
before Claude sees them). `node tools/context/sync-instructions.mjs --check` (CI) fails when `CLAUDE.md` holds anything but that import
(text there would reach Claude only), when the import sits in code or a comment, or when `AGENTS.md` is missing, empty, over 32 KiB or
carries an import (Codex never follows one). Run bare (as `regen-godot.sh` does) it validates `AGENTS.md` first, then writes the import over
a missing `CLAUDE.md` or the old full copy, refuses any other text, and never writes `AGENTS.md`. Each rule therefore has one home for both
terminal tools (`rules.json`, locked in `protected.json`). The Discord runner treats both root files as sensitive (`runner/lib/config.cjs`
`tiers`). The agent loads neither (`--restricted`; probed again with the import).

**What each audience receives** (`measure.mjs` `delivered`): for `claude-code` delivery, the file with HTML comments outside code removed
plus the one supported import (a line that is exactly `@<relative path>`, outside code and comments, naming a file in the checkout that
imports nothing itself); for `raw`, the file as is. Protected-rule coverage, section coverage and sizes all use that text, so a clause
moved into a comment of `AGENTS.md` fails for Claude while Codex still has it, and an import anywhere it would not be followed is a problem.

How sure that is (`usage.mjs` reports it per audience as "rules confirmed in N, unknown in K of M sessions", from the `instructions` and
`nested_memory` records Claude Code writes when it injects an instruction file; a file merely read does not count; "Usage" below):

- **Agent: never.** 0 of 124 agent sessions with calls 2026-10-04 to 2026-10-20 had it injected, while every interactive session started
  in the home folder in that time has an `instructions` record (for its memory file), so the record was being written. A direct probe on
  2026-10-21 (Claude Code 2.1.284, a scratch folder whose `CLAUDE.md` held a code word, no tools): `claude -p --restricted` answered that it
  had no project instructions; the same call without `--restricted` returned the code word.
- **Session: usually, not always.** 2026-10-18 to 2026-10-20: 10 of 12 interactive sessions and 15 of 39 subagents. A session that starts
  outside the repo gets it only when it works in a checkout's folder, so for subagents "always loaded" does not hold; their briefs carry the
  rules they need. Which actions load a nested `CLAUDE.md` is Claude Code's: on 2026-10-21 (2.1.284) the Read tool did, a single-file shell
  `cat` did not (in `-p` and in an interactive session alike, for a plain `CLAUDE.md` and for the import alike), while earlier sessions'
  records show loads right after shell commands run inside a checkout. The import changes none of that; whenever `CLAUDE.md` loads, the
  rules come with it. `surfaces.json` still treats `CLAUDE.md` (with its import) as the session audience's always-loaded text.
- **Codex: only when it starts in a checkout.** Before 2026-10-21 the repository had no `AGENTS.md`, `~/.codex/config.toml` names no
  fallback instruction file, and Codex does not read `CLAUDE.md` on its own; it learned the rules only when told to read them. Every Codex
  session on the game through 2026-10-21 started in the home folder, and Codex keeps a project-instruction snapshot (reloaded on trust,
  permission, fork or resume events, not on a `cd` or `git -C`): a Codex session that starts outside a checkout (or works on another
  worktree) must read that checkout's `AGENTS.md` first. `usage-codex.mjs` reports per session whether Codex recorded injecting an `AGENTS.md`, and from which
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
- a guide in `surfaces.json` does not exist, is also listed as always loaded, or holds no inventoried rule;
- a discovery entry (a file, or a section by its heading), a reference guide or a step of a task route (`tasks.json`) does not exist, or a
  task's route no longer holds the words that answer its question;
- a measured surface has no valid size ceiling, or a ceiling names a surface that is not listed ("Size warnings" below);
- an import is not one the audience follows (not on its own line, outside the checkout, missing, twice, itself, an imported file importing
  again, or any import in a `raw` file), or a file is over its audience's `maxBytes`.

The context test also keeps the owner principles (DECISIONS B71) and the spend-limit line in the agent's prompt: removing one, or giving it an
agent gap again, fails CI.

What this proves and what it does not: the check is structural. It shows that the listed words are still in the always-loaded text and
that any change to a protected rule or its exceptions comes with a change to `protected.json`, which shows in the diff. It cannot tell
whether anyone reviewed that diff, whether reworded text still means the same, or whether a model follows the rule. The code named in
`enforced` is what holds a boundary regardless of the text.

## Size warnings

`ceilings` in `surfaces.json` gives each measured surface a warning ceiling in estimated tokens (the same estimator; no tokenizer):
each always-loaded file per audience, measured as the audience receives it (`CLAUDE.md`, and `AGENTS.md` imported or read directly, 4,500, the agent's core prompt source 10,500), each agent guide
(5,000), each discovery entry (the map section 800, the client index 4,000) and each reference guide (8,000). They were set on
2026-10-21 with room above Stage 3's sizes. `measure.mjs` prints every size as `~size / ceiling`, lists the ones above it as WARNING lines
(and `sizeWarnings` in `--json`, with the file or section, its size and its ceiling), and `npm run hygiene` prints the same warnings (a
warning annotation in GitHub Actions).

A size above its ceiling never fails: it asks the change's review to say why the file grew, or to move task-specific detail to the
system's guide. A ceiling is not room to fill and not a model limit; do not cut a safety rule to get under one, and do not raise one to
hide a warning. What fails is the configuration: a surface with no valid ceiling, or a ceiling for one that is not listed, so the warnings
cannot quietly stop covering a file. The figures are static text: the rendered prompt's filled placeholders, the conversation, the
round's snapshot and memory files are not in them (`usage.mjs` and `usage-codex.mjs` report what the API counted).

## Finding task context

Before 2026-10-21 every audience was told to read five documents first (README, ROADMAP, DECISIONS, KNOWN-GAPS and the 216 KB client
manual, about 124,000 estimated tokens together; the agent three of them). Nobody did: 0 of 85 agent sessions with calls 2026-10-11 to
2026-10-20 read `CLAUDE.md` or `README.md` and 1 read the client manual, and in `baseline-2026-10-20.json`'s window (2026-10-18 to
2026-10-20) the files sessions read most include ROADMAP.md in 1 of 12 interactive sessions and the client manual in 3 of 39 subagents.
Now `CLAUDE.md` (so `AGENTS.md`) says to start from README.md's "Documentation map": pick the task's row, read that one document, then the
system's guide and the code (rule `task-discovery`). The Discord agent's core says the same, and in a job whose worktree was made before
the split it reads only the old `client/README.md` section on the same subject; its media guides name the game's page for each workflow
with the same fallback (server/death-muffin/discord-agent/README.md "Prompt and guides"). The client manual became `client/README.md`, an index (the feature table and "Guides
by task"), and guides beside the code they describe; `doc-moves.json` records where each old section went. Nothing here shows that a model
follows the new route: that shows only in the reads `usage.mjs` and `usage-codex.mjs` report for sessions after the change.

**Task routes.** `tasks.json` holds six representative tasks (the minimap, a rite's clip with a tuned cooldown, a co-op guest's boss
reward, the Depths' worker thread, a backend save, a roadmap question), each with the words that answer it and two routes: the bounded
old sections that answered it at `a1f09add` (the right section only, as if the reader knew where it was) and the route now, from the map.
`node tools/context/measure.mjs --tasks` measures both with the same estimator; CI checks that every route now still holds its answer (the
`before` side needs that revision in the history, which a shallow CI clone does not have). The comparison is in `stage3-2026-10-21.json`.

**Navigation check.** `navigation.mjs` (run by `npm run hygiene`, so in CI) proves the routes resolve: the map's links, every old section of
the client manual still answered by its anchor in `client/README.md` on a row that links each new home, each new home and its heading,
and every Markdown link (fragment included) or quoted section reference (`path.md "Label"`) into those files. A reference to an old section
name of `client/README.md` fails, except in the files `doc-moves.json` keeps on purpose (the decision record, the baseline, and one comment
whose file is an input of the art pack's fingerprint). It proves navigability, not that a guide is complete.

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
- whether the repo's rules arrived (`instructions` in the JSON): `entryObserved` (a record named the root `CLAUDE.md`), `sourceObserved` (a
  record named the root `AGENTS.md`, the import), and per session `rulesLoaded`: `confirmed` when `AGENTS.md` was injected or an injected
  `CLAUDE.md` record's own text held rules (any `CLAUDE.md` from before the switch, judged by its content, never by its date), `unknown`
  when only the import stub or a record without its text was seen. `claudeMdLoaded` stays for comparisons with earlier reports and means
  only "a record named the root `CLAUDE.md`";
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
  child), `turn_context` (each turn's folder and model) and `thread_settings_applied`. A response takes its turn's model, else the model in
  effect at that point of the file; a setting that comes later never applies backwards, and with none it is `unknown`.
- `token_usage_record`: one per response, with that response's `usage`, the session and thread it belongs to, and the turn's and thread's
  running totals. The reader counts the per-response usage once per `response_id` across the selected files, oldest file first, so the
  copy a resumed or forked rollout carries is not counted again. The running totals are never summed into usage.
- `event_msg` `token_count`: cumulative snapshots. Older rollouts have only these; a response is then derived as a rise of the total, a
  repeated snapshot adds nothing and a smaller total starts again from zero (a reset). One rise can hold several responses, so such
  responses are reported as uncertain and never used as one response's context size. In a rollout that has both, responses come from
  snapshots only before the first record.
- **Coverage.** Each rollout's responses (copies included, so a copy is neither counted twice nor called missing) are checked against
  everything its cumulative counters vouch for: each series (the records' thread totals, the snapshots) is cut at its resets and the
  segments' last values added, and the larger series is the evidence. Snapshots usually lag the records, so they matter only where they
  show more (a newer snapshot after the last record, a record whose thread total is ahead of what came before it). What the evidence shows
  beyond the responses is reported as **uncovered** with a warning: kept apart from the usage totals, never dropped silently. Uncovered is
  per rollout, not split by the window.
- **Starts.** A session's start is `genuine` only when the rollout shows it: a `session_meta`, and an earliest response that is not a copy
  (not already counted, and recorded for this rollout's own session or thread) and is its thread's first (its thread total is its own
  usage, or a first snapshot equal to its last response). A copied earliest response is `inherited` (a fork or resume); anything else,
  such as a partial rollout whose first response already has history behind it, is `unknown`. Only genuine starts give the first-response
  figures.
- `input_tokens` is the whole input; `cached_input_tokens` is the part of it served from the cache (reported as cached and not cached,
  never added on top); `reasoning_output_tokens` is part of `output_tokens`; `cache_write_input_tokens` is reported as recorded.
- Tool calls (`custom_tool_call` `exec` in code mode, `function_call`) are paired with their output by `call_id`; an output another selected
  rollout already holds (the same call and text) is counted once, in the oldest. A call that ran exactly one shell command is counted by its
  program (base name only, variable assignments dropped), and a simple single-file read (`cat`, `sed -n`, `head`, ...) names its file,
  resolved without touching the disk against the command's own `workdir`, else the turn's or the session's folder. Only a file inside a
  checkout is named, relative to it; anything else is `(outside the repo)`, or `(unknown folder)` when no folder is known. Several commands
  in one call, code with no recognisable command, and multi-file reads go into an unattributed bucket: characters returned are a proxy,
  not tokens a file cost. Truncated and image outputs are counted apart.
- Instructions: `world_state` `agents_md` (or, from older CLIs, a user message that starts `# AGENTS.md instructions for <folder>`)
  shows which AGENTS.md Codex injected and from which folder. A command that reads a checkout's own AGENTS.md or CLAUDE.md (resolved as
  above) is an explicit read, not an injection; a person naming the file is neither. A rollout with no `world_state` at all is "unknown",
  never "not loaded".

Which sessions count: `dm` sessions ran mostly in a checkout; `mixed` sessions started elsewhere (every Codex review so far started in
the home folder and read the game by absolute paths) and ran commands that name, or run in, a Death Muffin folder, so they are reported
apart rather than credited to the game as a whole; with `--session`/`--sessions-file`, only the named sessions count (`selected`), chosen
before any copied response is matched. What a command returned never decides it. The window works as in `usage.mjs` (UTC dates, both ends
included, responses and tool output by their own timestamps; `--cohort` for whole sessions that started in it). Warnings say where
evidence is missing (no usage recorded is unavailable, not zero).

## Stage 3 2026-10-21

`stage3-2026-10-21.json` (start `a1f09add`). Text sizes, estimated tokens:

- **Always loaded:** Claude sessions `CLAUDE.md` ~3,300 -> ~3,700 (the "Finding task context" section, the never-weaken-a-test line and the
  copy note); Codex ~0 -> ~3,700 (`AGENTS.md`: the project rules it never had automatically, a correction rather than a saving); the agent's
  core ~8,600 -> ~8,800.
- **Before a task:** told to read first ~124,000 (sessions) and ~87,500 (agent) -> nobody is; every audience starts from the map (~600) and,
  for a client task, the client index (~3,100).
- **The client manual** ~80,000 -> the index ~3,100 and guides beside the code, opened one or two at a time (the largest about 6,400 with
  the system README they joined).
- **Task routes** (`--tasks`): against the bounded old sections (a reader who already knew which section to open), the new route goes from
  about 1,050 fewer (the minimap: the old section carried the HUD's budget too) to about 3,700 more (the map and the index on top of a small
  section); every route is at least 88% smaller than the sessions' read-first list and at least 83% smaller than the agent's (the co-op task;
  the clip task with its clips guide 87%). Each task's answer is found on both sides.

What it does not show: whether a model follows the map. The before windows of `usage.mjs` (Claude, 2026-10-14 to 2026-10-20) and
`usage-codex.mjs` (Codex, 2026-09-26 to 2026-10-20) are in the file; no session has worked on the new docs yet, so the runtime effect is
not measured. Compare later windows per tool and task class with the same commands; Claude's and Codex's cache figures are not the same
measure.

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
