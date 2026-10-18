# Roadmap

What gets built next, in order. Two kinds of work run side by side: the **always-on** work (bugs, the team's requests, the polish list)
and **one phase at a time**, top to bottom. Inside a phase the next unchecked item is the work, and each phase ends with a "done when" check.
Bugs and gaps are listed in [KNOWN-GAPS.md](KNOWN-GAPS.md), the reasons behind choices in [DECISIONS.md](DECISIONS.md) (this plan's: B50),
and the rules every change follows in [CLAUDE.md](CLAUDE.md).

## Where we are (2026-10-18)

- **The rebuilt game is live** (launch day 2026-10-18, B49): the same game on a C++ combat core and Forward+ graphics. The biggest fight
  runs 3 to 4 times faster on Helix's PC (the Bell Sanctum's Full Party on Ultra: 61 to 224 fps); warbogar's PC plays it at 342 fps where the
  old game gave 41 in a lighter fight. The rebuild's record is B34-B50.
- Until 2026-11-01 one command puts the old game back (`server/death-muffin/launch-undo.sh`, B40); after that the old game's code goes.
- Ascension (the Altar, vows and heat, Ashes, Covenant Boons) left on launch day and comes back redesigned in Phase 3 (B36). Players'
  saved Ascension data is kept.
- **Now:** Phase 1, settling the launch.

## Waiting on Helix

Decisions only the team can make. Each one holds up only what it names.
1. **Public or private code.** The repository is public on GitHub, so encrypting the game's files would hide nothing. Make it private
   (GitHub's free minutes for the automatic tests get tight: fewer test runs or a small bill), or stay public and drop the encryption?
   Holds up: the encryption item in Phase 2.
2. **A test lane for big changes.** Keep the launcher's Test build switch and the test server for big changes such as Ascension, while
   small fixes still go straight to live? Claude recommends yes: the test build caught the Reaper's first-cast stutters before players met
   them (B38 made it a one-off for the rebuild). Holds up: nothing before Phase 3.

## Always on

- **Bugs and crashes first:** in-game reports and automatic crash reports (#in-game-reports), then the bugs in KNOWN-GAPS that cost
  players something.
- **The team's requests** through the Discord agent ship after approval, as before: bug fixes, small polish, warbogar's armor sets. A
  bigger new feature is planned into a phase instead: it goes to "Ideas" below.
- **The polish list** (below), top first, between phase items.
- Every gameplay change is measured and ships no slower than what it replaces (CLAUDE.md "Performance budgets").

## Phase 1: settle the launch (until 2026-11-01)

Goal: the new game has everything the old one had, it is the only game, and we can see how it runs on players' PCs.
- [ ] **Grave Surges come back.** They were left out of the rebuild and are missing since launch day: the wave director never starts one,
  so no crypt bursts open in a combat area with its three waves and its reward. Port `godot/next/areas/dm_grave_surge.gd` onto the core with
  the old game's rules, reward and tip.
- [ ] **The Discord agent checks and shows the real game.** Its checks run the old game's tests and its before/after screenshots render the
  old game (`server/death-muffin/discord-agent/shot-godot.sh`), so the team approves pictures of a game nobody plays, and the live game's
  tests run only after a ship is out (GitHub CI). Its checks run the suites of `client/`, and the screenshot tool (the QA driver and
  `shoot.gd`, left out of the rebuild) works in `client/`.
- [ ] **Play reports.** Each play session sends a small summary (average and worst frame times, the preset, the graphics card, time and
  deaths per area; nothing personal) and a page shows them. This also answers the weaker-PC question: no GTX 970-class PC or laptop has
  run the new game's benchmark yet.
- [ ] **Crash reports that name the cause.** The combat core ships without its debug symbols, so a crash inside it arrives without a place:
  keep the symbols of every published build, name the build in the report, and turn a crash address into a line of code.
- [ ] **First-use stutters, for good.** An effect compiles the first time it is drawn unless the hand-kept warm-up list has it (both of the
  Reaper's stutter reports). Turn on Godot's export-time shader baking (`shader_baker`), measure the first casts, and add a test that fails
  when an effect used in play is not warmed at load.
- [ ] **2026-11-01: the old game goes** (B40's window ends). `godot/` is deleted and its copies become `client/`'s own files
  (`tools/rebuild/sync-code.mjs` retires). Everything that still reads `godot/` reads `client/` or retires: the crowd baker and the area
  builder, about 66 tool and server scripts, the hygiene check's path rules, and the client tests that compare with the old game. The
  Discord agent edits `client/` directly, `server/death-muffin/launch-undo.sh` goes, and README.md and CLAUDE.md describe one game.

Done when: `godot/` is gone, every check and screenshot is of the live game, and a week of play reports is in.

## Phase 2: foundation

Goal: every kind of change is cheap, safe and done the same way by any fresh Claude session. Nobody on the team writes code, so the
rules, recipes and checks are the framework. (The toolkits for new kinds of content, such as enemy parts, maps and quests, are built in
Phase 4 together with their first content.)

**Content pipeline**
- [ ] **One home for each kind of content.** An enemy is defined in four places today (`server/rules/content/enemies.ts`,
  `client/data/content/enemies.json`, `client/data/combat/enemies.json` and its special moves in the combat core), and an armor set touches
  several files plus tests that count items. Each kind (enemies, items, rites, statuses, loot tables, sets, area rosters) gets one source;
  a generator writes every copy (client data, server rules, the server's item rows), and the build fails on a stale copy.
- [ ] **Content checks instead of counts:** a validator for each content file in CI (fields, ids that exist, numbers in range, every item
  with an icon and a server row, every enemy with a crowd model), replacing the tests that pin counts.

**The server owns every value** (finishing B19-B26 and B32)
- [ ] Area kills, shards and seals in the necromancer save come only from accepted reports (KNOWN-GAPS "Server authority").
- [ ] A Discord notice when a character trips a flag; `progress_audit` checked for rule false positives; the old audit rows cleared.
- [ ] A written way to roll one character back (`character_save_versions`).
- [ ] Encryption of the game's files in the build, if the code goes private (Waiting on Helix 1).

**Standards**
- [ ] **Done means done:** CLAUDE.md says, for each kind of change (code, content, art, server, docs), what must be true before it ships.
- [ ] **Every budget checked automatically** (CLAUDE.md "Performance budgets"), the art ones too (triangles, texture sizes, draw calls per
  area), so new content cannot ship over budget.
- [ ] **Typed code stays typed:** Godot's warning for untyped GDScript becomes an error (about 99 % of `client/` is typed today).

**Organization and documentation**
- [ ] **Docs a fresh session can read.** `client/README.md` (171 KB) and `native/README.md` (97 KB) are mostly the rebuild's measurement
  history: rewrite them as how each system works now (the history stays in git and DECISIONS).
- [ ] **Recipes** with their checks: add an enemy, an item, a rite, a boss, an area, an armor set, a sound, a tip. Haunting Wraith
  (warbogar's Reaper ability, Discord proposal 565c7c, made on the old game) is built with the rite recipe as its first test.
- [ ] **The repository after `godot/`:** each top-level folder with one stated purpose, nothing left over, README.md's layout true.

**Code upgrades**
- [ ] The web era's leftovers go (KNOWN-GAPS "Leftovers from the web era").
- [ ] The rebuild's performance follow-ups, measured one at a time: the spikes first (a rite's cast, a big kill's handlers, Bone Fan's
  pick in Easy auto combat), then the per-frame waste and the draw calls (KNOWN-GAPS "Performance").
- [ ] Test health: the flaky and exposed suites (KNOWN-GAPS "Tools and tests").

Done when: an enemy, an item and a rite can each be added by a written recipe that changes one data file plus its art, a mistake in it
fails the checks, the server owns every value, and the docs a session needs fit in one read.

## Phase 3: Ascension, redesigned (the first new feature, B36)

- [ ] Designed with Helix: what the Altar, vows and heat, Ashes and Covenant Boons become, and the co-op rules (today a guest's Prelate kill
  counts for the host: KNOWN-GAPS "Party and online").
- [ ] Built on the foundation: its data in one home, Ashes owned by the server from day one, measured like everything else.
- [ ] Players' saved boons, Ashes and best rank carried into it as the design decides.

## Phase 4: new content (lore, maps, enemies, classes, quests)

Each kind starts with its toolkit (the reusable parts and a recipe), built together with its first content: a toolkit built before the
content is known is guesswork (CLAUDE.md: no speculative abstraction). Phase 4 starts when Phase 3 is done and so are the first four items
of the polish list; the order below is a first guess, set with Helix then.
- [ ] **The lore bible,** written with the team: the world, its factions, history and tone, in one doc that names, quests, bosses and the
  Codex follow.
- [ ] **The look of the world** (Helix, 2026-10-16: the asset and effects rebuild, with its own plan and pipelines). First the map pipeline:
  areas made as scenes from reusable wall, floor and prop pieces with the lighting bake helper, in place of the web-era `world.json` they are
  generated from today; then the maps revamped. Notes for it: KNOWN-GAPS "Assets and effects".
- [ ] **New places:** new zones (the Hollow Court) on the map pipeline.
- [ ] **New enemies and bosses:** first the enemy building blocks (the core's one-off moves, such as the Censer's aura, the Gargoyle's dive
  and the Sexton's hook, become reusable parts that the data combines), then new kinds and bosses with summoning keys.
- [ ] **The other five classes** (Grave Warden, Bell Monk, Carrion Witch, Hollow Knight, Veilwalker; their data is in `client/data/content/`):
  first the rite building blocks, then one class at a time with its kit (Shrouded suspension, the monk's beat meter, Bulwark).
- [ ] **Quests:** first a quest system (objectives, givers, dialogue, rewards paid by the server), then quests written from the lore bible.
- [ ] **Endgame depth:** weekly Omen variants, deeper Depths rewards, replay.

## Polish list

Worked through beside the phases, top first; each change is shown to the team (screenshots) before it ships.
- [ ] **The rebuild's combat fixes** (Helix, 2026-10-16: fixed after launch day): toxic corpse pools at the area's level, the plague
  bearer's pool, the Mourning Bell wraith's heal, statuses raising the damage a boss takes, and Fracture on bosses (KNOWN-GAPS "Combat and
  statuses").
- [ ] **The look pass** (Gate D, moved after launch by Helix, B49): effects on Low and Medium, the lifts, the Depths' walls, the hero in
  bright and dark areas; then Helix signs off every area on their PC (KNOWN-GAPS "Look").
- [ ] **The Reaper's first pass finished:** her own model, armor set, runes and signature (R) rite (KNOWN-GAPS "Disciplines").
- [ ] **Co-op gaps:** rejoin after a drop (D13), a guest's waystone map, a guest seeing its thralls' hits, a guest waking a boss its own
  account has sealed, first-kill rewards for guests (KNOWN-GAPS "Party and online").
- [ ] **Built but never shown:** the thralls' legion kit and discipline looks, water ripples, the Prelate's candles, the Plague Doctor's
  flask pool; each shown to the team, then wired or deleted (KNOWN-GAPS "Built but never shown").
- [ ] **Necromancer polish from playtests:** combat feel and loot, readability of rites and statuses, gear and affix legibility, the first
  hour (Next-step box, counsel tips, guide NPCs).
- [ ] Small: the chat window's colours; the in-game leaderboard panel (KNOWN-GAPS "UI").

## Later

- **Phones:** the Mobile renderer, phones join as guests (B40 keeps the game ready: phone texture formats, Mobile-safe shaders, a
  scalable HUD).
- Not planned: dedicated or VPS-hosted sessions and host migration (the hybrid model stays, owner 2026-10-15; D6), translations, mod support.

## Ideas

Ideas and requests not planned yet, one line each with its date; each is sorted into a phase when that phase is planned. Bugs and gaps go
to KNOWN-GAPS.md instead.
- A hint for a party guest standing in a boss's rot (a guest's core lists no zones today: KNOWN-GAPS "Party and online"; 2026-10-17).

## Done

- 2026-10-16 to 2026-10-18: **the rebuild**, a C++ combat core and Forward+ graphics under the same game (B34-B50).
- 2026-10-13 to 2026-10-15: **server authority**: the server rolls every drop, owns the bag and pays only what the kill ledger backs
  (B19-B26, B32).
- 2026-10-09: **the baseline cleanup**: one game, one branch, docs that say how things are (B1-B11).
