# Roadmap

What gets built, in order. The **always-on** work (bugs, the team's requests, something players notice every week or two, the polish
list) runs beside **one phase at a time**, top to bottom. Inside a phase the next unchecked item is the work (Phase 2's tracks can run side
by side), and a "Done when" check ends it. The technical detail of each gap is in [KNOWN-GAPS.md](KNOWN-GAPS.md), the reasons in
[DECISIONS.md](DECISIONS.md) (this plan's: B50 and B56), and the rules every change follows in [CLAUDE.md](CLAUDE.md).

Every item says what kind it is: **Fix** (what happens **now** and what it will be **after**), **New** (what it gives) or **Decide** (a
question only the team can answer, with Claude's recommendation).

## Where we are (2026-10-20)

- **The rebuilt game is live** since launch day, 2026-10-18 (B49): the same game on a C++ combat core and Forward+ graphics, its biggest
  fight 3 to 4 times faster (the Bell Sanctum's Full Party on Ultra, Helix's PC: 61 to 224 fps). The old game is retired (B57, tag
  `archive/old-game`): a rollback publishes an earlier build of the game.
- **Now: Phase 1, settle the launch.** Everything in it is built; left are two decisions and a week of play reports (2026-10-26 at the
  earliest).
- **Next:** Phase 2, the foundation's core (the vision, how we work, the standards, content in one place with checks, recipes, the server
  owning every value); Phase 3, Ascension redesigned (it left on launch day; players' saved Ascension data is kept, B36); Phase 4, new
  content (the look of the world, places, enemies and bosses, the other five classes, quests, endgame). **Later:** off-site backups, phones,
  and 1.0, the first public release.

## Waiting on Helix

Nothing right now. Each Decide item says what it waits for.

## Always on

- **Bugs and crashes first:** in-game reports and automatic crash reports (#in-game-reports), then the bugs in KNOWN-GAPS that cost
  players something.
- **The team's requests** through the Discord agent ship after approval: bug fixes, small polish, warbogar's armor sets and rites. A bigger
  new feature goes to "Ideas" below and is planned into a phase.
- **Something players notice, every week or two:** the next polish-list item (top first) or a fix players asked for, with its patch notes,
  so the game keeps moving while the foundation is built.
- Every gameplay change is measured and ships no slower than what it replaces (CLAUDE.md "Performance budgets").

## Phase 1: settle the launch

Goal: the new game has everything the old one had, it is the only game, we hear when something breaks, and we see how it runs on
players' PCs (Helix, 2026-10-18: "we can do these things asap").

Done, 2026-10-18 to 2026-10-20 (how each works is in the page named):
- [x] **Fix: nobody was told when the game's servers stopped.** Every service is checked each minute; an outage posts to #build-alerts
  (`server/death-muffin/ops/health-watch.mjs`).
- [x] **Fix: Grave Surges are missing.** Back (`client/next/areas/dm_grave_surge.gd`).
- [x] **Fix: crash reports could not point inside the combat core.** Crash notes and every build's symbols name the function and line
  (native/README.md "Crash notes"; the Windows half has not met a real crash yet).
- [x] **Fix: the Discord agent tested the old game, slowly.** It works on the game, checks against the latest main, its proposals are
  drafts (🧪 tests, ✅ tests and ships, B63), and a document-only change ships no update (server/death-muffin/discord-agent/README.md).
- [x] **Fix: testing was slow and done two ways** (B59). One setup (`tools/check/prep.sh`), CI the one gate for everyone (about 4
  minutes), and tests that read every number from the game's data, so new content never breaks one (tools/check/README.md). CI also stops
  the next big change from breaking testing unnoticed (B63).
- [x] **Fix: the old game's folder was still in the repository** (B57). Deleted 2026-10-19; its useful suites moved to `client/tests`.
- [x] **Fix: War's content pipelines ran on trust.** Models over their caps or off the shared skeleton are refused
  (`tools/assets/check-models.mjs`), and new sounds are levelled to -20 LUFS and recorded (docs/AUDIO-SOURCES.md).
- [x] **New: play reports.** Frame times, hitches, graphics card and time per area from every session, per release on the site
  (client/next/perf/README.md "Play reports").
- [x] **New: the team app** (B54, B55, B58, B60-B62, B64, B66). A tray app on the three team PCs that makes proposal pictures and videos,
  runs benchmarks and release checks, and starts every release before players get it; proven on Helix's PC, app 0.4.7 (teamapp/README.md).
- [x] **Fix: first-use stutters.** Done 2026-10-20: every new game, and every Settings save, threw away the shader pipelines the loading
  screen had compiled (setting the soft-shadow filter, even to its own value, makes Godot 4.7.2 drop them all), so each game compiled about
  420 again while casting → the preset tells the renderer only what changed. The stutter test on Brbmuffins' RX 6600, the live build against
  the fix: 424 compilations (237 making a frame wait) → 10, all in the background; the worst cast 19.4 ms (Wraith Walk) → 6.5 ms, none over
  8 ms. The warm-up's blind spots (lighting variants, other presets, areas and bosses, panels, death, other players' effects) remain
  (`client/tests/warm_coverage.gd`); weaker cards are watched through the play reports.

Open:
- [ ] **Decide: a team PC runs the Discord agent's unreviewed branch** (found 2026-10-19). Pictures and videos are made from the change
  itself, so its game code runs on the team PC: offline and in its own folder, but able to reach the PC (run a program, read a file). Today
  only War, Muffins and Helix can ask the agent for changes, which limits the risk. Claude recommends: before team PCs take jobs from anyone
  else, refuse a team build whose game code reaches outside the game (programs, files outside its folder, the network); the video steps
  are data and bring no code (B64). Waits for: anyone outside the team getting the agent.
- [ ] **Decide: an "Ultra Low (old PCs)" option** (B35). If Low on the new renderer misses the laptop floor (60 fps in normal play, 45 in
  the biggest fight), add an option that restarts the game in the old, lighter renderer. Waits for: the play reports from weak PCs.

Done when: the old game's folder is gone, every check and screenshot is of the live game, the servers are watched (all three done), and a
week of play reports is in.

## Phase 2: the foundation's core

Goal: every Claude session and the Discord agent know what the game should be and build what we make today the same way, so the team's
ideas come out right the first time and little is redone. Nobody on the team writes code, so the written direction, a few strong
standards, the pipelines and the automatic checks are the framework. It holds only what every piece of content needs; every other
standard is written with its first content (CLAUDE.md: no speculative abstraction):
- the effects standard and the rite recipe: from Haunting Wraith (track C);
- the UI standard: before Ascension's windows (Phase 3);
- the rigging and animation standard, enemy roles, the boss template and area rules: with the first new creature, boss and place (Phase 4);
- the props and world-kit pipeline and where big art files live: at the start of the art rebuild (Phase 4);
- the audio rules: started with Phase 1's loudness check (-20 LUFS), they grow with the next sounds.

All standards live in three pages (the look, the tech art, design and writing) plus one "How we work" page; CLAUDE.md points every
session to them. Five tracks run side by side; inside a track, top first.

### A. Direction and how we work

- [ ] **Decide + New: the game vision, on one page,** written with the team: the fantasy, the core loop and the feel of a fight; who it is
  for (friends now, the public from 1.0, B52); the platforms (Windows now, phones later, others such as the Steam Deck); whether it will
  ever earn money (asset licences depend on it); the pillars that decide ties (performance first, polish over new content, necromancer
  focus, loot never vacuums, readable fights); and what it will not be. It gives: the root every standard follows, read first by every
  session.
- [ ] **Decide + New: "How we work", on one page,** in plain words for Helix, War and Muffins:
  - Who decides and who works on what. Now: the owner, Helix and warbogar can each approve everything, and nobody has a lane. After: art,
    design and numbers, spend and releases each name who approves and who is asked; each person has a lane (for example Helix with the
    terminal sessions on the phases, War with the Discord agent on content whose pipeline works, Muffins on the direction and money); an
    item someone starts is marked "in progress: who, date", so two people or sessions never take the same work.
  - From idea to shipped: anything bigger than a tweak gets a one-page plan first (the goal, what the player sees, the rules and numbers,
    the art and sound, its budgets, how we will know it works); once approved it is built with the recipes, passes the checks and the look
    check, is playtested and ships with its patch note. The Discord agent uses the same plan for bigger requests.
  - The playtest routine: after each phase and each big change, a short team session with a checklist of what changed; findings go to
    KNOWN-GAPS or Ideas.
  - Done means done: what must be true before each kind of change (code, content, art, server, docs) ships.
  - The team guide: how to ask the Discord agent for something, what a proposal, 🧪, ✅, the test lane and the team app do, what Fix, New
    and Decide mean, and where to look.
- [ ] **Fix: the test lane for big changes cannot be used** (B53). Now: the launcher's Test build switch, the test server and its lobby and
  relay exist, but the game only talks to the live server, so no test build can be made. After: a big change (Ascension, a new class, the
  map revamp) is published to the test channel first and reaches only the test server; the team's accounts there are refreshed on request;
  one script puts it live (CI passed, the Discord agent idle, the deploy lock held, deploy and publish, the agent reinstalled if its files
  changed, a clean drift report and practice run, stopping at the first failure). Small changes still go straight to live.
- [ ] **Decide + New: Ascension's one-page plan,** written with Helix through "From idea to shipped", so Phase 3 starts building the day
  this phase ends: what the Altar, vows and heat, Ashes and Covenant Boons become, and the co-op rules (today a guest's Prelate kill counts
  for the host).

### B. The core standards: the look, the tech art, design and writing

What exists: budgets for the hero, bosses and crowd (CLAUDE.md "Performance budgets" and ASSET_PIPELINE.md, with different numbers), the
asset generation steps (ASSET_PIPELINE.md, `docs/BLENDER-PIPELINE.md`, `docs/TRIPO-ANIMATE-IN-PLACE.md`), the gear's attachment rules
(inside `client/data/slice/necro_gear.json`), the quality bar (`docs/GRAVECRAWL.md`) and Phase 1's model check. Missing: an art direction,
one budget table for every kind of asset, and checks for everything but models.
- [ ] **Decide + New: the look (the art direction).** Claude drafts it, with example pictures, from today's look, the area moodboards
  (`docs/art/areas/`) and Gravecrawl's lessons; the team picks and approves. It sets the game's look in a paragraph, each area's palette and
  light, the colour rules (enemies, heroes and the ground always differ in colour and brightness; violet for magic, gold for reward, red
  for danger; what each spell colour and loot rarity means), silhouettes that read from the game camera (about 22 m), how shiny and bright
  materials may be (Tripo's models come out metallic and white out under glow), how heroes, thralls and enemies are told apart, and the
  style of icons, portraits and UI frames. It gives: one page every new asset is checked against, and the art rebuild's target.
- [ ] **Fix: budgets in two places, for three kinds of asset (the tech art page).** Now: ASSET_PIPELINE.md asks Tripo for a 12,000-triangle
  hero and a 14,000 boss while CLAUDE.md caps both at 20,000, the model check holds its own caps, and nothing covers the world. After: one
  table (hero, bosses, crowd creatures, thrall variants, weapons and gear, props, wall and floor pieces, effect meshes, UI art) with
  triangles (a target and a hard cap), texture size, materials, bones and levels of detail, plus a budget per area (triangles in view, draw
  calls, lights); the gear's attachment rules move here. Starting numbers come from today's assets, confirmed with the benchmark.
- [ ] **New: one model for Ultra, old PCs and phones (the tech art page).** Each model is made once, at its budget, and the tools make the
  lighter versions (Godot's levels of detail, each preset deciding how soon they show); Ultra adds extras (shadows, ambient occlusion, more
  particles) rather than heavier models; Low thins the effects out; phones get Low plus a phone pack with smaller textures in phone formats
  (B40), and a check proves every shader and effect runs on the phone renderer. It gives: Ultra at its best, Low above the weak-PC floors,
  and nothing remade when phones come.
- [ ] **New: the balance sheet (the design page).** The power curve over levels 1 to 999 (item power by level and rarity, enemy health and
  damage by area level, XP and gold per minute, drop rates, where gold comes from and goes) and how hits and kills feel (sound, flash,
  number and screen shake, each capped). A balance tool on the seeded fight harness plays a fight without a screen and reports time to
  kill, damage taken and XP and gold per minute. It gives: new items and enemies fit the game without retuning everything around them.
- [ ] **New: rules for changing live content (the design page).** An item id is never reused or deleted while anyone owns it, a removed
  item turns into something stated (gold or a replacement), a rebalance says whether owned items change too, and each change ships with its
  database migration. It gives: updates never break or silently change players' characters.
- [ ] **New: the writing rules and the lore bible (the writing page),** written with the team: the voice (dark, with dry humour where it
  fits), naming patterns for items, enemies, places and rites, what a tooltip says and in what order, the patch-note style; and the world
  (its factions, history and places), which names, quests, bosses and the Codex then follow.
- [ ] **New: the look check and the review checklist.** A scene that shows a new model beside existing ones from the game camera, in each
  area's light, on Low and Ultra, with its triangle count, next to approved reference shots of each area. Every new visual asset is posted
  to the team with those shots and passes the checklist (the look, the budgets, the rig, the clips, readability) before it ships.

### C. Content pipelines and automatic checks

- [ ] **Fix: content is defined in several places.** Now: an enemy lives in four places (`server/rules/content/enemies.ts`, two client data
  files and its special moves in the combat core), an armor set touches about five files, and a new weapon's Atlas row is written by hand
  (KNOWN-GAPS "Content pipelines"). After: each kind of content (enemies, items, rites, statuses, loot tables, sets, area rosters) has one
  source file, the tools write every other copy, and the build fails if a copy is out of date.
- [ ] **New: automatic checks for every new asset and content entry.** Models already get triangles, materials, the skeleton and the
  combat clips checked (Phase 1); still to add: texture sizes, bones, levels of detail, scale and pivot, a source and licence record; for
  data: required fields, ids that exist, numbers inside the balance sheet. They run before every push, in the Discord agent's check and in
  CI. It gives: an over-budget model, a missing clip or a broken item cannot ship.
- [ ] **New: the rules reach every Claude by themselves.** CLAUDE.md points to the docs map; each recipe is also a Claude Code skill that
  loads by itself when a session (on the server or the Discord agent) is asked for that job; the agent's proposals show the checklist's
  results. It gives: no session has to know where a rule lives to follow it.
- [ ] **Fix: the character pipeline guide is spread over three pages.** Now: ASSET_PIPELINE.md, `docs/BLENDER-PIPELINE.md` and
  `docs/TRIPO-ANIMATE-IN-PLACE.md` each hold part of the steps, and none covers the crowd bake or the look check. After: one guide from
  concept (the team approves the picture first) through the Tripo model, cleanup to budget in Blender, rig, clips, build, levels of detail,
  crowd bake and look check to ship, each step with its tool and its check.
- [ ] **New: recipes, with their checks, for what is made today:** an armor set, an item, a sound, a tip, and a rite. Haunting Wraith (War's
  Reaper rite, live since 2026-10-18, built before any recipe) is what the rite recipe and the effects standard are written from: how big
  and bright an effect may be so a fight stays readable, particle budgets per tier, existing effects first, every new effect warmed at
  load, and whether the licensed effect pack's 3D scenes can be used now (KNOWN-GAPS "Assets and effects"). The next new rite is the
  recipe's first test. The enemy, boss and area recipes come with their first content in Phase 4.
- [ ] **New: a catalogue of what exists.** Every item, enemy, rite, area, model, animation, sound and effect with its picture and numbers,
  generated from each kind's one home into a page the team can browse; the team and every session look there before asking for or making
  something new. It gives: no duplicates and no paying twice for the same asset.

### D. The server owns every value (finishing B19-B26 and B32)

- [ ] **Fix: area kills and soul shards are taken on the player's word.** Now: the necromancer save sends them and the server stores them,
  so a cheater could hand himself shards. After: the server counts them from the kill reports it accepted, as it does for XP and gold.
- [ ] **New: cheat flags reach the team:** a Discord notice when a character trips a flag, a review of the flags for honest players caught
  by mistake (a false flag holds back part of an honest player's gain), and the old audit rows cleared.
- [ ] **New: a written way to roll one character back** to an earlier save (`character_save_versions`) when a bug or an exploit damages it.

### E. Engineering health and docs

- [ ] **New: an automatic secret scan.** Now: the repository is public and only a scan each session runs by hand keeps keys out. After:
  every push is scanned before it leaves the server and again in CI, and one with a secret is refused.
- [ ] **New: a security watch on the server's packages:** a weekly list of the server's, lobby's and relay's outside packages with known
  holes, updated on purpose and tested like any change.
- [ ] **Fix: untyped code is allowed.** Now: GDScript without types still loads (under 1 % of the game's code), so some mistakes only show
  when a player hits them. After: Godot treats untyped code as an error, so they show the moment a test loads the game.
- [ ] **Fix: the rebuild's performance leftovers.** Now: in the biggest fight a rite's cast can take 2 to 4 ms in one frame and a big
  kill's rewards and loot 2 to 9 ms (measured on the VPS: a small hitch on a weaker PC), some code repeats work every frame, and some
  effects draw while empty. After: each inside its budget, fixed and measured one at a time, the hitches first (KNOWN-GAPS "Performance").
- [ ] **Fix: some test suites fail at random.** Now: a few fail now and then under load or on timing (KNOWN-GAPS "Tools and tests"), and
  with CI as the gate a random failure blocks a ship. After: every suite passes every time, and red means broken.
- [ ] **Fix: leftovers from the web game.** Now: parts of the code still copy the web game's exact math, and an asset list is kept by hand.
  After: plain Godot code and generated lists (KNOWN-GAPS "Leftovers from the web era").
- [ ] **Fix: docs too long to read.** Now: `client/README.md` is 204 KB and `native/README.md` 56 KB, more than a fresh Claude session can
  read before it starts working. After: short pages on how each system works now, the history kept in git and DECISIONS.
- [ ] **New: one map of the docs:** which page holds which rule (the vision, How we work, the standards pages, the pipelines, the recipes,
  each system), so the Discord agent and every session find the rule before they build.
- [ ] **Fix: the repository after the old game's folder went.** Now: leftovers of the two-game setup. After: each top-level folder has one
  stated purpose, nothing is left over, and README.md's layout is true.

Done when: the vision and "How we work" are agreed; three real pieces (the next new rite, War's next armor set and one new item) have gone
through their recipes, the automatic checks and the look check without trouble; the look, the tech art, and the design and writing pages
are approved; the rules reach every session by themselves; the server owns every value; and the docs a session needs fit in one read.

## Phase 3: Ascension, redesigned (the first new feature, B36)

Built right after Phase 2, from the one-page plan written during it.
- [ ] **New: the UI standard, before Ascension's windows:** icon size, style and frame; fonts and text sizes; the rarity and danger
  colours, never shown by colour alone (for colour-blind players); and how a new window fits the HUD budget (150 draw calls, 0.5 ms).
- [ ] **New: Ascension built on the foundation:** its data in one home, Ashes owned by the server from day one, played on the test lane
  first, measured like everything else.
- [ ] **New: players' saved boons, Ashes and best rank carried into it,** as the plan decides (the rules for changing live content).

## Phase 4: new content

Each kind starts by building its toolkit and writing its standard (the reusable parts, the rules and its recipe) together with its first
piece of content. Phase 4 starts when Phase 3 is done and so are the first four items of the polish list; the order below is a first guess,
set with Helix then.
- [ ] **New: the look of the world** (the art rebuild; Helix, 2026-10-16: its own plan and pipelines), following the look page. First:
  - **Decide + Fix: where big art files live.** Now: the repository holds about 520 MB, mostly art, and every version of every model stays
    in its history for good, so every copy grows with each new asset. After: big art files move to Git's large-file storage or an asset
    store outside git (Claude brings both with their monthly cost; CI downloads the art on every run, which decides it).
  - **New: the props and world-kit pipeline:** budgets, the same sharpness everywhere, shared materials so they draw cheaply, collision
    and walkable-area rules, lightmap layout; the team app bakes the lighting on the strongest graphics card and returns it as a proposal.
  - **New: the map pipeline:** areas built as scenes from those pieces with the lighting bake, instead of generated from the web game's map
    file (`world.json`).

  Then the maps revamped (notes: KNOWN-GAPS "Assets and effects").
- [ ] **New: new places:** first the area rules and the area recipe (size, fighting space, landmarks, spawn points, safe spots), then new
  zones (the Hollow Court) made with the map pipeline.
- [ ] **New: new enemies and bosses.** First the rigging and animation standard (one skeleton per body type, attachment points, scale, the
  clips every kind of creature must have, attacks marked where they land, Tripo's traps), enemy roles and telegraph rules, the boss
  template (phases, telegraphs, adds, summoning key, party scaling, rewards), the enemy and boss recipes, and enemy building blocks (each
  special move, such as the Censer's aura, the Gargoyle's dive and the Sexton's hook, is a one-off today; they become parts the data
  combines). Then new kinds and bosses with summoning keys.
- [ ] **New: the other five classes** (Grave Warden, Bell Monk, Carrion Witch, Hollow Knight, Veilwalker; their data is in
  `client/data/content/`): first rite building blocks, then one class at a time with its kit (Shrouded suspension, the monk's beat meter,
  Bulwark).
- [ ] **New: quests:** first a quest system (objectives, quest givers, dialogue, rewards paid by the server), then quests written from the
  lore bible.
- [ ] **New: endgame depth:** weekly Omen variants, deeper Depths rewards, replay.

## Polish list

Worked through beside the phases, top first. Each change is shown to the team with screenshots before it ships.
- [x] **Fix: three combat rules the rebuild found broken** (Helix, 2026-10-16). Done 2026-10-20: toxic corpse pools hurt at the level the
  area's enemies are made at (were level 1); a fallen plague bearer leaves its rot pool (5 s, slows and withers); each Mourning Bell wraith
  blow heals the heroes within 14 m, owner and party, by 2% of their health, as the item says (thralls are not healed, the old game's design).
- [ ] **Fix: the look pass** (B49). Now: blended effects (decals, telegraphs, particles) look wider and brighter than in the old game, most
  on Low and Medium; the Depths' walls are darker; the hero reads darker in bright areas (the Coliseum, the Cloister, the Pyre, the Wing) and
  brighter in dark ones. After: every preset looks like the old game or better, and Helix has signed off each area on their PC.
- [ ] **Fix: the Reaper is unfinished.** Now: she has her rites (Haunting Wraith since 2026-10-18), a signature (R) rite and a legendary
  set with its own body, but borrows the Mourner's body outside that set and other rites' icons, and has no runes. After: her own model,
  icons and runes.
- [ ] **Fix: co-op gaps** (now → after; KNOWN-GAPS "Party and online"):
  - Done 2026-10-20: a dropped player landed in their own solo game → for 5 minutes a notice and a Rejoin button in Social offer the same
    party back (a host who drops still ends the session, D6; no seat is held, so a party that filled up answers "full").
  - A guest's waystone map lists the guest's own unlocked areas → the host's world, where the party plays.
  - A guest sees only the killing blow of its thralls → every blow, as the host does.
  - A guest whose account has not opened a boss's area wakes the boss anyway, has its payment refused and is told afterwards → the team
    decides whether a guest may wake a boss only the host has opened, and the guest is told before anything happens.
  - A guest never gets a boss's first-kill bonus or trophy → guests get their own.
  - Only the host's area gets waves → each area a member fights in gets its own.
  - The Depths are solo only → decide whether a party can descend together, and build it if so.
  - A guest cannot call an Empowered boss, and its Colossus Mantle effects, Covenant Seal and Nightfall dimming do not reach the host's
    game → a guest's gear and choices work in the party as they do solo.
  - Someone who joins during a boss fight does not see the pools already burning → sees the fight as it is.
  - Done 2026-10-20: friends showed as online only once in the world → from sign-in, at character select and while the world loads (the
    launcher has no login, so not there).
- [ ] **Decide + Fix: things built but never shown.** Now: thralls never wear their Legion kit or their discipline's look, water never
  ripples, the Prelate's candles never gutter, and the Plague Doctor's flask leaves a pool that hurts but cannot be seen. After: each is
  shown to the team with screenshots; what they keep is switched on (the invisible pool at least gets drawn, so players can dodge it) and
  the rest is deleted.
- [x] **Fix: Easy auto combat parks the hero between tombstones.** Done 2026-10-20: it walked straight at the nearest enemy and stopped in
  pockets between the graves → when a grave or wall is in the way it follows the navmesh's path round it.
- [x] **Fix: seven tips never show.** Done 2026-10-20: the Depths (going in alone, a new floor, a floor's affix, and its chest), the
  loadouts, a weapon change, a set bonus gained and the Omen had tips nothing triggered → each shows once at its moment.
- [ ] **Decide: the first goal after the Hollow Graves.** Now: right after entering the Graves the Next-step line says "Ossuary seal: 0/300
  kills", a steep first goal. After: the team picks a softer first goal, and the Next-step box leads there.
- [ ] **New: necromancer polish from playtests:** combat feel and loot, readability of rites and statuses, gear and affix legibility, the
  rest of the first hour (the Next-step box, counsel tips, guide NPCs).
- [ ] **New: small additions:** colours in the chat window; an in-game leaderboard panel (today only the website shows it).

## Later

- **Fix: backups never leave this server** (B51). Now: the database is backed up every night, but onto the same server, and the raw art
  sources, the licensed packs and the private effect sheets exist only here. After: every night a copy of everything not in git goes to a
  cloud storage bucket, and a restore from it is tested.
- **New: phones.** The Mobile renderer, touch controls built with the HUD, phones join as guests. The game stays ready for them (B40: phone
  texture formats, shaders that run on Mobile, a scalable HUD) and Phase 2's quality tiers set their budgets.
- **New: a co-op test between two team PCs** (the team app).
- **New: 1.0, the first public release** (B52). The repository goes private and the game's files are encrypted in the build; accounts get
  an email address and password recovery (none exist today); chat gets reporting and moderation; a privacy policy and terms; a signed
  launcher and game so Windows does not warn new players; a review of the servers' capacity and of cheating; a licence check of every asset
  against how the game is offered (Tripo models, ElevenLabs sounds and music, the sound and effect packs); the test runs fitted to a private
  repository's paid minutes (about $80 to $115 a month at the 2026-10-19 pace; first an Actions budget of $0 with "Stop usage", and the
  drafts' background CI runs off, B63); and a store or download page.
- Not planned: dedicated or VPS-hosted game sessions and host migration (the hybrid model stays, owner 2026-10-15; D6), translations, mod
  support.

## Risks we are carrying

- **One server holds everything,** every backup included, until the cloud bucket exists (Later); Phase 1's alerts tell us when something
  stops.
- **Every line is written by Claude:** when usage runs out or the service is down, all building pauses. The docs, recipes and checks
  (Phase 2) let any fresh session continue; nothing depends on one session's memory.
- **The code is public until 1.0:** cheaters can read how the server checks them. The server owns every value (Phase 2, track D), and the
  code goes private for 1.0 (B52).
- **Licences:** the ElevenLabs plan in use excludes monetized games. The vision decides about money (Phase 2, track A); 1.0 checks every
  licence.
- **No way back to the old game** (B57): problems are fixed forward or rolled back to an earlier build of the new game, so the crash
  reports, alerts and play reports are how we learn about them.
- **A long foundation:** players see little new while it is built. Something players notice ships every week or two (Always on), Phase 2
  holds only the core, and Ascension follows it directly.

## Ideas

New ideas and requests from anyone land here first, one line each with its date and the section it would belong to. They wait here until
the team says yes, because every unchecked item in a phase or the polish list is treated as approved work by every session. When a phase
is planned, its ideas move into its checklist as Fix or New items (or straight away, when Helix says so). Bugs and gaps go to
KNOWN-GAPS.md instead.
- A hint for a party guest standing in a boss's rot (a guest's core lists no zones today). Section: polish list, co-op gaps. 2026-10-17.
- A results card when a session ends: what you reached, kills, gold, time, and your personal best (Gravecrawl's lesson 3,
  `docs/GRAVECRAWL.md`). Section: polish list. 2026-10-18.
- A one-click invite link: copy it, a friend clicks it, the game opens and joins the party (Gravecrawl's lesson 9). Section: polish list,
  co-op gaps. 2026-10-18.
- A check that a new player's first fight starts within seconds of entering the world (Gravecrawl's lesson 2). Section: polish list, the
  first hour. 2026-10-18.
- The party session on each drop (a column on `character_drop_events` set from the claim's session id) and the XP and gold a member earns in
  a session on its `party_session_members` row, so the play reports get drops per hour and exact XP and gold per session. Section: Phase 2,
  track D. 2026-10-18.
- Split the Discord agent runner's `runner/core.cjs` (about 2,000 lines) by job (pictures and videos, ships, threads), so each change to it
  is smaller and its reinstall and practice run less risky. Section: Phase 2, track E. 2026-10-19.

## Done

- 2026-10-16 to 2026-10-18: **the rebuild**, a C++ combat core and Forward+ graphics under the same game (B34-B50).
- 2026-10-13 to 2026-10-15: **server authority**: the server rolls every drop, owns the bag and pays only what the kill ledger backs
  (B19-B26, B32).
- 2026-10-09: **the baseline cleanup**: one game, one branch, docs that say how things are (B1-B11).
