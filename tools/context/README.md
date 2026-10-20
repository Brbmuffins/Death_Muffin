# Context: what the rules cost and where they live

Claude does all the work on this game: sessions started in a checkout (and the subagents they start) and the Discord dev agent. Every
one of them carries rule text on every call, and every call re-reads the whole conversation so far. This folder measures both and keeps
an inventory of the rules, so the rule text can be reorganised without losing a boundary.

```
node tools/context/measure.mjs                   # rule text per audience and section, and the inventory check (exit 1 on a problem)
node tools/context/usage.mjs --since 2026-10-18  # per audience: calls, context read, the fixed start, peaks, files and commands that filled it
node tools/context/usage.mjs --who agent --tokens-only --json out.json
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
playbook), each place it is written with a verbatim anchor, and the code that enforces it, if any. `protected: true` marks permission,
spending, deployment and server-authority boundaries. `measure.mjs` (and its test, in CI) fails when:

- an anchor is no longer in its file (the rule was reworded, moved or deleted: update `rules.json` in the same change);
- a protected rule has no home in the always-loaded text of an audience it names, and no `gaps` note saying why;
- an enforcing file named by a rule does not exist;
- a `## ` section of an always-loaded file holds no inventoried rule (a new section: add its rules).

So moving rule text to a file that is read on demand is a visible decision: a protected rule cannot leave the always-loaded text without
a reviewed `gaps` note. `gaps` also records rules one audience has and the other lacks.

## Usage

`usage.mjs` reads Claude Code's transcripts (`~/.claude/projects/*/*.jsonl`, and `<session>/subagents/*.jsonl`). A transcript records every
API call's usage, so nothing extra is logged at run time. A Discord job is recognised by its start folder (`wt/discord-<job>[-<round>]`),
any other session by where most of its records ran. Per audience it reports the context read (cache reads, cache writes, uncached input),
the first call's context (the fixed start: system prompt, tools, rule text and the first message), how much of everything read the fixed
start makes up (first call times calls), peaks, the files and shell commands whose output filled the context, and an estimate of what
compacting at a lower point would have saved (`whatIfCap`: an upper bound, since work redone after a compaction is not counted). Dollars
are list prices (`PRICES`); a subscription pays in plan usage, but the ratio holds. `--tokens-only` drops dollars, and paths outside a
checkout are reported as one bucket, so the output can be committed. Claude Code deletes old transcripts after a while, so a baseline
worth keeping is committed as numbers.

## Baseline 2026-10-20

`baseline-2026-10-20.json` holds the numbers before any change to how rules are loaded (`measure.mjs` on main 2ccce622, `usage.mjs` over
2026-10-18 to 2026-10-20 for everyone and 2026-10-11 to 2026-10-20 for the agent). It records what sessions read at the time, old paths included, so
the retired-term rules in `tools/hygiene/retired.json` allow `tools/context/baseline-*.json`.
