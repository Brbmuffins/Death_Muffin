# The story, lore and the game's words

Use this for anything about the story or the words players read: a lore question, a #lore brainstorm, a name for an item, enemy, place or
rite, a Codex entry, a boss line, a tooltip.

## Where it is

- **What players read today** is in the game's data, `client/data/content/`: `codex.json` (the Codex: the rites, the disciplines, the dead),
  `bosses.json` (the bosses), `areas.json` (the places), `dialogue.json` (what the prior, the sexton and the apothecary say, and the boss
  hints), `enemies.json` (enemy names) and `abilities.json` (spell names and descriptions). The Codex panel's rows are `client/data/panels_a/codex_rows.json`.
- **The team's working draft of the story** is `docs/LORE.md`. Nothing in it is settled or in the game until the team says so: its last two
  sections ("Never answered, on purpose", "Ideas still floating") are open on purpose.
- **What is planned**: `ROADMAP.md`, "the writing rules and the lore bible" (the voice, naming patterns, what a tooltip says, the world).
  Those rules are not written yet, so there is no house style to quote: follow what the game's own text already does.
- **What was decided and why**: search `DECISIONS.md` for the name or "lore".

## Before you answer

- Search before you say something is not there. Grep the name and close spellings (plural, with and without "the", a typo the team might
  make) across `client/data/` and `docs/`. If nothing turns up, say what you searched ("not in the Codex, the bosses or LORE.md"), never
  just "that does not exist".
- Say where each fact comes from: **in the game** (the data files), **in the draft** (`docs/LORE.md`), or **an idea** (yours or a teammate's,
  not decided). Never present the draft or an idea as settled, and never write a list of "decided" points the team did not say yes to.
- When the game and the draft disagree, say so plainly: the game is what players have, the draft is where the team wants to go.

## Writing it

- Brainstorming: a few ideas at a time, each in a sentence or two, and ask which ones the team likes. Build on what they pick rather than
  starting over. A long write-up only when someone asks for one.
- Keep names and facts consistent with the draft and the game; when an idea changes something already written, say what it changes.
- In-game text is short: a tooltip or Codex line reads at a glance. Match the length and tone of the entries around it in the same file.
