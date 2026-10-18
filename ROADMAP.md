# Roadmap

What gets built, in order. Two kinds of work run side by side: the **always-on** work (bugs, the team's requests, the polish list) and
**one phase at a time**, top to bottom. Inside a phase the next unchecked item is the work (Phase 2's tracks can run side by side), and
each phase ends with a "Done when" check. The technical detail of each gap is in [KNOWN-GAPS.md](KNOWN-GAPS.md), the reasons behind
choices in [DECISIONS.md](DECISIONS.md) (this plan's: B50), and the rules every change follows in [CLAUDE.md](CLAUDE.md).

Every item says what kind it is:
- **Fix:** something wrong or missing in the game or in our tools. It says what happens **now** and what it will be **after** the fix.
- **New:** something we add. It says what it gives us.
- **Decide:** a question only the team can answer, with Claude's recommendation.

## At a glance

- **Phase 1, settle the launch** (now until 2026-11-01): everything the old game had, one game instead of two, alerts when a
  server stops, and play reports that show how the game runs on players' PCs.
- **Phase 2, foundation:** the system that makes every Claude session and the Discord agent build the same way: the game's direction
  and how ideas become features, the content standards, the pipelines and automatic checks, the server owning every value, healthy code
  and short docs.
- **Phase 3, Ascension redesigned:** the first new feature, built on the foundation.
- **Phase 4, new content:** the look of the world, new places, enemies and bosses, the other five classes, quests and endgame, each with
  its toolkit built first.
- **Beside them all:** bugs first, the team's requests, and the polish list. **Later:** off-site backups, phones, and going public if the
  team decides to.

## Where we are (2026-10-18)

- **The rebuilt game is live** (launch day 2026-10-18, B49): the same game on a C++ combat core and Forward+ graphics. The biggest fight
  runs 3 to 4 times faster on Helix's PC (the Bell Sanctum's Full Party on Ultra: 61 to 224 fps); warbogar's PC plays it at 342 fps where the
  old game gave 41 in a lighter fight. The rebuild's record is B34-B50.
- Until 2026-11-01 one command puts the old game back (`server/death-muffin/launch-undo.sh`, B40); after that the old game's code goes.
- Ascension (the Altar, vows and heat, Ashes, Covenant Boons) left on launch day and comes back redesigned in Phase 3 (B36). Players'
  saved Ascension data is kept.
- **Now:** Phase 1, settling the launch.

## Waiting on Helix

1. **Decide: public or private code.** The repository is public on GitHub, so encrypting the game's files would hide nothing. Make it
   private (GitHub's free minutes for the automatic tests get tight: fewer test runs or a small bill), or stay public and drop the
   encryption? Holds up: the encryption item in Phase 2.
2. **Decide: a test lane for big changes.** Keep the launcher's Test build switch and the test server for big changes such as Ascension,
   while small fixes still go straight to live? Claude recommends yes: the test build caught the Reaper's first-cast stutters before players
   met them (B38 made it a one-off for the rebuild). Holds up: nothing before Phase 3.

## Always on

- **Bugs and crashes first:** in-game reports and automatic crash reports (#in-game-reports), then the bugs in KNOWN-GAPS that cost
  players something.
- **The team's requests** through the Discord agent ship after approval, as before: bug fixes, small polish, warbogar's armor sets. A
  bigger new feature is planned into a phase instead: it goes to "Ideas" below.
- **The polish list** (below), top first, between phase items.
- Every gameplay change is measured and ships no slower than what it replaces (CLAUDE.md "Performance budgets").

## Phase 1: settle the launch (until 2026-11-01)

Goal: the new game has everything the old one had, it is the only game, it is safe if something breaks, and we can see how it runs on
players' PCs.
- [ ] **Fix: Grave Surges are missing.** Now: since launch day no Grave Surge ever starts (they were left out of the rebuild). After: as in
  the old game, after about 100 seconds in a combat area a crypt bursts open nearby, three waves climb out, and clearing them pays the surge
  reward; the surge tip shows again. (Port `godot/next/areas/dm_grave_surge.gd` onto the combat core.)
- [ ] **Fix: the Discord agent tests and photographs the old game.** Now: its proposals are checked with the old game's tests and its
  before/after screenshots are taken in the old game, so the team approves pictures of a game nobody plays, and the live game's tests run
  only after the change is out. After: every proposal is tested on the live game and shows the live game's screenshots before anyone
  approves it. (The screenshot tool and its driver come over to `client/`; the agent's check runs the client's suites.)
- [ ] **Fix: nobody is told when the game's servers stop.** Now: only the database is watched; if the game's server, the lobby or the
  co-op relay stops, nobody knows until players notice. After: each one is watched every minute, and a failure posts to #build-alerts
  (KNOWN-GAPS "Operations").
- [ ] **New: play reports.** When a play session ends, the game sends a small summary: average and worst frame times, the graphics preset,
  the graphics card, and time and deaths per area (nothing personal). A page on the site shows them per release, beside the server's own
  numbers (XP and gold per hour, drops). It gives: how the game really runs on every player's PC, weak ones included (no GTX 970-class PC
  or laptop has run the benchmark yet), whether a release made it slower, and where players struggle.
- [ ] **Fix: crash reports cannot point inside the combat core.** Now: when the C++ combat core crashes, the report has the log but no
  location, because the core ships without its debug symbols. After: each crash report names the build and the line of code that crashed
  (the symbols of every published build are kept on the server).
- [ ] **Fix: first-use stutters.** Now: an effect is compiled the first time it is drawn, which stutters, unless it is on a warm-up list
  kept by hand (both Reaper stutter reports came from gaps in that list). After: Godot compiles every effect when the game is built (its
  shader baking option), and a test fails if an effect used in play could still stutter.
- [ ] **Fix: two copies of the game's code** (on 2026-11-01, when the undo window ends). Now: the old game's folder `godot/` is still
  there, most of the new game's scripts are copied from it, and the crowd and map tools, about 66 tool and server scripts and some tests still
  read it. After: `godot/` is deleted, the new game owns its files, every tool and test reads the new game, the Discord agent edits the new
  game directly, `server/death-muffin/launch-undo.sh` goes, and README.md and CLAUDE.md describe one game.

Done when: `godot/` is gone, every check and screenshot is of the live game, the servers are watched, and a week of play reports is in.

## Phase 2: foundation

Goal: every Claude session and the Discord agent understand what the game should be and build every part of it the same way, so the
team's ideas come out right the first time and little is redone. Nobody on the team writes code, so the written direction, standards,
pipelines and automatic checks are the framework. Six tracks that can run side by side; inside a track, top first. The toolkits for new
kinds of content (enemy parts, rite parts, maps, quests) are built in Phase 4 together with their first content.

### A. Direction and workflow: what we are making, and how an idea becomes a feature

- [ ] **Decide + New: the game vision, on one page,** written with the team. What Death Muffin is (the fantasy, the core loop, the feel of
  a fight), who it is for (friends, or the public one day), whether it will ever earn money (asset licences depend on it: the ElevenLabs
  plan in use excludes monetized games), the pillars that decide ties (performance first, polish over new content, necromancer focus, loot
  never vacuums, readable fights), and what the game will not be. It gives: the root every other standard follows, and the first thing every
  session reads.
- [ ] **Decide + New: who decides what.** Now the owner, Helix and warbogar can each approve everything. After: art, design and numbers,
  spend, and releases each name who approves them and who is asked, so two approvals never pull in different directions.
- [ ] **New: from idea to shipped.** Any feature bigger than a tweak gets a one-page spec first: the goal, what the player sees, the rules
  and numbers, the art and sound it needs, its budgets, and how we will know it works. The team approves the spec, then it is built with
  the recipes, passes the checks and the look check, is playtested and ships with its patch note. The Discord agent uses the same spec for
  bigger requests. It gives: the team sees what will be built before anything is built, which is where most rework is saved.
- [ ] **Decide + New: a playtest routine.** After each phase and each big change, a short team session with a checklist of what changed;
  findings go to KNOWN-GAPS or Ideas through the Discord agent, and the play reports give the numbers beside them.

### B. Content standards: the rulebook for new content

Today some of it exists: budgets for the hero, bosses and crowd creatures (CLAUDE.md "Performance budgets" and ASSET_PIPELINE.md, with
different numbers), the asset generation steps (ASSET_PIPELINE.md, `docs/BLENDER-PIPELINE.md`, `docs/TRIPO-ANIMATE-IN-PLACE.md`) and the
quality bar (`docs/GRAVECRAWL.md`). Missing: an art direction, a rigging or animation standard, budgets for gear, props and the world, and
any automatic check of a new asset. Each standard is one page in one folder of the docs; CLAUDE.md points every session to them.
- [ ] **Decide + New: the art direction guide.** Claude drafts it from today's look, the area moodboards (`docs/art/areas/`) and Gravecrawl's
  lessons, with example pictures; the team picks and approves. It sets the game's look in a paragraph, each area's palette and lighting mood,
  the colour rules (for example: enemies, heroes and the ground always differ in colour and brightness; violet for magic, gold for reward,
  red for danger; what each spell colour and loot rarity means), silhouettes that read at the game camera's distance (about 22 m), how shiny
  and how bright materials may be (Tripo's models come out metallic and white out under glow), how heroes, thralls and enemies are told
  apart (rims, glows), and the style of icons, portraits and UI frames. It gives: one page every new asset is checked against, and the
  target for the asset and effects rebuild.
- [ ] **Fix: budgets in two places, for three kinds of asset.** Now: ASSET_PIPELINE.md asks Tripo for a 12,000-triangle hero and a 14,000
  boss while CLAUDE.md caps both at 20,000, and nothing covers gear, props or the world. After: one table for the hero, bosses, crowd
  creatures, thrall variants, weapons and gear pieces, small, medium and large props, wall and floor pieces, effect meshes and UI art, each
  with triangles (a target and a hard cap), texture size, materials, bones and levels of detail, plus a budget per area (triangles in view,
  draw calls, lights). Starting numbers come from today's assets and are confirmed with the benchmark.
- [ ] **New: how one model serves Ultra, old PCs and phones.** Written rules for the quality tiers: each model is made once, at its budget,
  and the tools make the lighter versions (Godot already makes levels of detail for every model, and each preset decides how soon the lighter
  ones show); Ultra adds extras on top (shadows, ambient occlusion, more particles) rather than heavier models; Low thins the effects out;
  phones get the Low preset plus a phone pack with smaller textures in phone formats (B40). It gives: Ultra keeps looking its best while
  Low stays above the weak-PC floors, and nothing has to be remade when phones come.
- [ ] **New: the rigging standard.** One skeleton per body type (humanoid, which is Tripo's shared biped skeleton; four-legged; and today's
  bloated and robed kinds), bone names, the attachment points (right and left hand for weapons and shields, head for helms, shoulders and
  back for mantles), scale (1 unit = 1 m, a height range per kind), facing and the pivot at the feet, and a bone limit for phones. It gives:
  any new creature reuses the existing animations, gear and props, and goes straight into the crowd baker.
- [ ] **New: the animation standard.** The clips every kind of creature must have (idle, walk, run, attack, a second attack, hurt, death,
  rise, plus role clips such as cast or dig), their names, lengths, loops and frame rates; clips stay in place (the game moves the body); the
  moment each attack lands is marked so the damage lines up with the swing; the crowd baker's limits; and the known traps of Tripo's presets
  (its "hurt" is a 14-second lying-down clip). It gives: every creature moves and hits the same way, and a missing or broken clip is caught
  by a check instead of a player.
- [ ] **New: the effects standard.** The spell colour language, how big and bright an effect may be so a fight stays readable (immersive,
  not overwhelming), particle and overdraw budgets per tier, reusing the existing effects first, and every new effect warmed at load (the
  Phase 1 check). It also settles the licensed effect pack's 3D scenes, ruled out while players ran the old renderer and usable now
  (KNOWN-GAPS "Assets and effects").
- [ ] **New: the audio standard.** Loudness targets for music, ambience, effects and voices, formats, names, how many variations a sound
  needs, how long and how often a sound may play, and a licence record for every file (`docs/AUDIO-SOURCES.md` is that record today).
- [ ] **New: the UI and icon standard.** Icon size, style and frame; fonts and text sizes; the rarity and danger colours, never shown by
  colour alone (for colour-blind players); and how a new window fits the HUD budget (150 draw calls, 0.5 ms).
- [ ] **New: the writing standard and the lore bible,** written with the team. The voice (dark, with dry humour where it fits), naming
  patterns for items, enemies, places and rites, what a tooltip says and in what order, the patch-note style; and the world itself (its
  factions, history and places), which names, quests, bosses and the Codex then follow.
- [ ] **New: the game design rules and the balance sheet.** The power curve over levels 1 to 999 (item power by level and rarity, enemy
  health and damage by area level, XP and gold per minute, drop rates); enemy roles (melee, flanker, caster, hazard, support) and telegraph
  rules (every dangerous attack has a readable wind-up and a ground marker); how hits and kills feel (sound, flash, number and screen shake,
  each with its cap); a boss template (phases, telegraphs, adds, summoning key, scaling for a party, rewards); and area rules (size,
  fighting space, landmarks, spawn points, safe spots). A balance tool built on the seeded fight harness plays a fight without a screen and
  reports time to kill, damage taken and XP and gold per minute, so a new item or enemy is checked against the curve before anyone plays it.
  It gives: new items, enemies and areas fit the game without retuning everything around them.
- [ ] **New: rules for changing live content.** What happens to what players already own when content changes: an item id is never
  reused or deleted while anyone owns it, a removed item turns into something stated (gold or a replacement), a rebalance says whether owned
  items change too, and each change ships with its database migration. It gives: updates never break or silently change players'
  characters.
- [ ] **New: the look check and the review checklist.** A scene that shows a new model beside existing ones at the game camera's distance,
  in each area's light, on Low and on Ultra, with its triangle count, next to approved reference shots of each area. Every new visual asset
  is posted to the team with those shots and passes the checklist (art direction, budgets, rig, clips, readability) before it ships.

### C. Content pipelines and automatic checks: how content gets made, step by step

- [ ] **Fix: content is defined in several places.** Now: an enemy is defined in four places (`server/rules/content/enemies.ts`, two
  client data files and its special moves in the combat core), and an armor set touches several files and breaks tests that count items.
  After: each kind of content (enemies, items, rites, statuses, loot tables, sets, area rosters) lives in one source file, the tools write
  every other copy (client data, server rules, the server's item rows), and the build fails if a copy is out of date.
- [ ] **New: automatic checks for every new asset and content entry.** For models: triangles, texture sizes, materials, bones, levels of
  detail, the required clips, scale and pivot, a source and licence record. For data: required fields, ids that exist, numbers inside the
  balance sheet. They run before every push, in the Discord agent's check and in CI, and replace today's tests that pin counts. It gives:
  an over-budget model, a missing clip or a broken item cannot ship.
- [ ] **New: the rules reach every Claude by themselves.** CLAUDE.md, which every session reads first, points to the docs map; each recipe
  is also a Claude Code skill that loads by itself when a session is asked to do that job (sessions on the server and the Discord agent
  alike); the agent's proposals show the checklist's results (the automatic checks and the look-check shots). It gives: no session has to
  know where a rule lives to follow it.
- [ ] **New: a catalogue of what exists.** Every item, enemy, rite, area, model, animation, sound and effect with its picture and numbers,
  generated from the one home of each kind into a page the team can browse. The team and every session look there before asking for or
  making something new (reuse first). It gives: no duplicates and no paying twice for the same asset.
- [ ] **Fix: the character pipeline guide describes the old game.** Now: ASSET_PIPELINE.md sends new art through the old game's folder and
  says players run the old renderer, and its steps are spread over three pages. After: one guide for the new game from concept (the team
  approves the picture first) to Tripo model, cleanup to budget in Blender, rig, clips (Tripo's presets, the shared clip library, Blender
  recipes), build, levels of detail, crowd bake, look check and ship, each step with its tool and its check.
- [ ] **New: the props and world-kit pipeline.** How props and wall, floor and decoration pieces are made: budgets, the same sharpness
  everywhere (texel density), shared materials so they draw cheaply, collision and walkable-area rules, and lightmap layout for the lighting
  bake. It feeds the map pipeline in Phase 4.
- [ ] **New: recipes with their checks:** add an enemy, an item, a rite, a boss, an area, an armor set, a sound, a tip. Haunting Wraith
  (warbogar's Reaper ability, Discord proposal 565c7c, made on the old game) is built with the rite recipe as its first test.

### D. The server owns every value (finishing B19-B26 and B32)

- [ ] **Fix: area kills and soul shards are taken on the player's word.** Now: the necromancer save sends its area kills and shards and
  the server stores them, so a cheater could hand himself shards. After: the server counts them from the kill reports it accepted, as it
  already does for XP and gold.
- [ ] **New: cheat flags reach the team.** A Discord notice when a character trips a flag, a review of the flags for honest players caught
  by mistake (a false flag holds back part of an honest player's gain), and the old audit rows cleared.
- [ ] **New: a written way to roll one character back** to an earlier save (`character_save_versions`), for when a bug or an exploit
  damages a character.
- [ ] **New: encryption of the game's files** in the build, only if the code goes private (Waiting on Helix 1).

### E. Engineering standards and health

- [ ] **New: done means done.** CLAUDE.md says, for each kind of change (code, content, art, server, docs), what must be true before it
  ships: tests, measurements, screenshots, docs.
- [ ] **Fix: untyped code is allowed.** Now: GDScript without types still loads (under 1 % of the game's code), so some mistakes only
  show when a player hits them. After: Godot treats untyped code as an error, so those mistakes show the moment a test loads the game.
- [ ] **Fix: the rebuild's performance leftovers.** Now: in the biggest fight a rite's cast can take 2 to 4 ms in one frame and a big kill's
  rewards and loot 2 to 9 ms (measured on the VPS: a small hitch on a weaker PC), some code repeats work every frame, and some effects draw
  while empty. After: each one inside its budget, fixed and measured one at a time, the hitches first (KNOWN-GAPS "Performance").
- [ ] **Fix: some test suites fail at random.** Now: a few suites fail now and then under load or on timing (KNOWN-GAPS "Tools and
  tests"), so a red CI does not always mean a real problem. After: every suite passes every time, and red means broken.
- [ ] **Fix: leftovers from the web game.** Now: parts of the code still copy the old web game's exact math, and an asset list is kept by
  hand. After: plain Godot code and generated lists (KNOWN-GAPS "Leftovers from the web era").

### F. Organization and documentation

- [ ] **Fix: docs too long to read.** Now: `client/README.md` (171 KB) and `native/README.md` (97 KB) are mostly the rebuild's measurement
  history, more than a fresh Claude session can read before it starts working. After: short pages on how each system works now, with the
  history kept in git and DECISIONS.
- [ ] **New: one map of the docs:** which page holds which rule (the vision, the standards, the pipelines, the recipes, each system), so the
  Discord agent and every session find the rule before they build.
- [ ] **Fix: the repository after `godot/` goes.** Now: leftovers of the two-game setup. After: each top-level folder has one stated
  purpose, nothing is left over, and README.md's layout is true.
- [ ] **Decide + Fix: where big art files live.** Now: the repository holds about 520 MB of files, mostly art, and every version of every
  model stays in its history for good, so it grows with each new asset and every session's copy grows with it. After: before the asset
  rebuild starts, big art files move out of the main history, to Git's large-file storage or to an asset store outside git (Claude brings
  both with their monthly cost; the automatic tests download the art on every run, which decides it), so the repository stays small and fast.

Done when: the vision, who decides what, the spec template and the playtest routine are agreed; an enemy, an item and a rite can each be
added by following their recipes and pass the automatic checks and the look check; every standard in track B is written and approved;
the rules reach every session by themselves; the server owns every value; and the docs a session needs fit in one read.

## Phase 3: Ascension, redesigned (the first new feature, B36)

- [ ] **Decide: what Ascension becomes,** designed with Helix through the spec of track A: the Altar, vows and heat, Ashes, Covenant
  Boons, and the co-op rules (today a guest's Prelate kill counts for the host).
- [ ] **New: Ascension built on the foundation:** its data in one home, Ashes owned by the server from day one, measured like everything
  else.
- [ ] **New: players' saved boons, Ashes and best rank carried into it,** as the design decides (the rules for changing live content).

## Phase 4: new content (the look of the world, places, enemies, classes, quests)

Each kind starts by building its toolkit (the reusable parts and its recipe) together with its first piece of content: a toolkit built
before anyone knows the content is guesswork (CLAUDE.md: no speculative abstraction). Phase 4 starts when Phase 3 is done and so are the
first four items of the polish list; the order below is a first guess, set with Helix then.
- [ ] **New: the look of the world** (the asset and effects rebuild; Helix, 2026-10-16: its own plan and pipelines), following the art
  direction guide. First the map pipeline: areas built as scenes from reusable wall, floor and prop pieces with the lighting bake helper,
  instead of generated from the web game's map file (`world.json`) as now; then the maps revamped. Its notes: KNOWN-GAPS "Assets and effects".
- [ ] **New: new places:** new zones (the Hollow Court) made with the map pipeline.
- [ ] **New: new enemies and bosses.** First the enemy building blocks: each special move (the Censer's aura, the Gargoyle's dive, the
  Sexton's hook) is today a one-off written for its enemy; they become reusable parts that the data combines. Then new kinds and bosses
  with summoning keys, from the design rules' roles and boss template.
- [ ] **New: the other five classes** (Grave Warden, Bell Monk, Carrion Witch, Hollow Knight, Veilwalker; their data is in
  `client/data/content/`): first rite building blocks, then one class at a time with its kit (Shrouded suspension, the monk's beat meter,
  Bulwark).
- [ ] **New: quests.** First a quest system (objectives, quest givers, dialogue, rewards paid by the server), then quests written from the
  lore bible.
- [ ] **New: endgame depth:** weekly Omen variants, deeper Depths rewards, replay.

## Polish list

Worked through beside the phases, top first. Each change is shown to the team with screenshots before it ships.
- [ ] **Fix: four combat rules the rebuild found broken** (Helix, 2026-10-16: fix them after launch day; the old game had them too).
  - Toxic corpse pools. Now: they always hurt as if at level 1. After: they hurt at the area's level.
  - The plague bearer. Now: its toxic pool never appears when it dies. After: it leaves its pool.
  - The Mourning Bell wraith. Now: its heal on the monsters around it never happens. After: it heals them, as designed.
  - Bosses and statuses. Now: effects that make an enemy take more damage (Sanctify, a Marrow Spear's Fracture) do nothing to a boss.
    After: they work on bosses too, so those rites shorten boss fights.
- [ ] **Fix: the look pass** (moved after launch by Helix, B49). Now: blended effects (decals, telegraphs, particles) look wider and brighter
  than in the old game, most on Low and Medium; the Depths' walls are darker; the hero reads darker in bright areas (the Coliseum, the
  Cloister, the Pyre, the Wing) and brighter in dark ones; not every area is signed off. After: every preset looks like the old game or
  better, and Helix has signed off each area on their PC.
- [ ] **Fix: the Reaper is unfinished.** Now: she borrows the Mourner's body and other rites' icons, and has no armor set, no runes and no
  signature (R) rite. After: her own model and icons, an armor set, runes and a signature rite.
- [ ] **Fix: co-op gaps.**
  - Dropped players. Now: a dropped player lands in their own solo game and has to rejoin by hand. After: they are offered to rejoin the
    same party within a short window (a host who drops still ends the session, D6).
  - A guest's waystone map. Now: it lists the guest's own unlocked areas. After: it lists the host's world, where the party plays.
  - A guest's thrall hits. Now: a guest sees only the killing blow of its thralls. After: it sees every blow, as the host does.
  - A guest waking a boss. Now: if the guest's own account has not opened that boss's area, the boss wakes anyway, the server refuses the
    guest's payment and the guest is told only afterwards. After: the team decides whether a guest may wake a boss only the host has
    opened, and the guest is told before anything happens.
  - Boss rewards for guests. Now: a guest never gets a boss's first-kill bonus or trophy. After: guests get their own.
- [ ] **Decide + Fix: things built but never shown.** Now: thralls never wear their Legion kit or their discipline's look, water never
  ripples, the Prelate's candles never gutter, and the Plague Doctor's flask leaves a pool that hurts but cannot be seen. After: each one is
  shown to the team with screenshots; what they keep is switched on (the invisible pool at least gets drawn, so players can dodge it) and
  the rest is deleted.
- [ ] **Fix: two small bugs.** Gathering: now the last 8 seconds of gathering before quitting are lost; after, they are saved. Easy auto
  combat: now it walks the hero into pockets between tombstones and parks there; after, it walks around them.
- [ ] **New: necromancer polish from playtests:** combat feel and loot, readability of rites and statuses, gear and affix legibility, the
  first hour (the Next-step box, counsel tips, guide NPCs).
- [ ] **New: small additions:** colours in the chat window; an in-game leaderboard panel (today only the website shows it).

## Later

- **Fix: backups never leave this server** (Helix, 2026-10-18: a cloud storage bucket, set up later; B51). Now: the database is backed up
  every night, but onto the same server, and the raw art sources, the licensed packs and the private effect sheets exist only here, so losing
  the server would lose all of it. After: every night a copy of everything that is not in git goes to the cloud bucket, and a restore from
  it is tested.
- **New: phones.** The Mobile renderer, touch controls built with the HUD, phones join as guests. The game stays ready for them (B40:
  phone texture formats, shaders that run on Mobile, a scalable HUD) and Phase 2's quality tiers set their budgets.
- **New: going public, only if the vision says so.** Accounts with an email address and password recovery (none exist today), reporting
  and moderation for chat, a privacy policy and terms, a signed launcher and game so Windows does not warn new players, a review of the
  servers' capacity and of cheating, and a store or download page.
- Not planned: dedicated or VPS-hosted game sessions and host migration (the hybrid model stays, owner 2026-10-15; D6), translations, mod
  support.

## Ideas

Ideas and requests not planned yet, one line each with its date; each is sorted into a phase when that phase is planned. Bugs and gaps go
to KNOWN-GAPS.md instead.
- A hint for a party guest standing in a boss's rot (a guest's core lists no zones today; 2026-10-17).

## Done

- 2026-10-16 to 2026-10-18: **the rebuild**, a C++ combat core and Forward+ graphics under the same game (B34-B50).
- 2026-10-13 to 2026-10-15: **server authority**: the server rolls every drop, owns the bag and pays only what the kill ledger backs
  (B19-B26, B32).
- 2026-10-09: **the baseline cleanup**: one game, one branch, docs that say how things are (B1-B11).
