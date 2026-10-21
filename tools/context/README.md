# Context: what the rules cost and where they live

Claude does all the work on this game: sessions started in a checkout (and the subagents they start) and the Discord dev agent. Every
one of them carries rule text on every call, and every call re-reads the whole conversation so far. This folder measures both and keeps
an inventory of the rules, so the rule text can be reorganised without losing a boundary.

```
node tools/context/measure.mjs                   # rule text per audience and section, and the inventory check (exit 1 on a problem)
node tools/context/usage.mjs --since 2026-10-18 --until 2026-10-20   # per audience: the window's calls, context read, session-start context, peaks, files and commands
node tools/context/usage.mjs --who agent --tokens-only --json out.json
node tools/context/make-baseline.mjs <out.json> --label <rev> --window <since>..<until> --agent-window <since>..<until>
node --test tools/context/test/*.test.mjs        # also in npm run test:server, so in CI
```

## The audiences

`surfaces.json` names what each audience always carries and what it is told to read first:

| Audience | Always loaded | How |
|---|---|---|
| session | `CLAUDE.md` | Claude Code loads it for any session started in the repository |
| agent | `server/death-muffin/discord-agent/PROMPT-godot.md` | the runner appends it to every call (`runner/lib/agent.cjs`); the agent runs `--restricted`, which does not load `CLAUDE.md` |

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
- a `## ` section of an always-loaded file holds no inventoried rule (a new section: add its rules).

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

## Baseline 2026-10-20

`baseline-2026-10-20.json` holds the numbers before any change to how rules are loaded (`measure.mjs` on main 2ccce622, `usage.mjs` over
2026-10-18 to 2026-10-20 for everyone and 2026-10-11 to 2026-10-20 for the agent, calls counted by their own timestamps; the windows were
closed when it was made, so `make-baseline.mjs` with the command in its `about` remakes it while the transcripts last). It records what sessions read at the time, old paths included, so
the retired-term rules in `tools/hygiene/retired.json` allow `tools/context/baseline-*.json`.
