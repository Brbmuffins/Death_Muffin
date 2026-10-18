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

- **Phase 1, settle the launch** (now; the old game's code goes on 2026-11-01): everything the old game had, the team PC helper
  (screenshots, benchmarks and bakes on team PCs), one game instead of two, alerts when a server stops, and play reports that show how the
  game runs on players' PCs.
- **Phase 2, foundation:** the system that makes every Claude session and the Discord agent build the same way: the game's direction
  and how ideas become features, the content standards, the pipelines and automatic checks, the server owning every value, healthy code
  and short docs.
- **Phase 3, Ascension redesigned:** the first new feature, built on the foundation.
- **Phase 4, new content:** the look of the world, new places, enemies and bosses, the other five classes, quests and endgame, each with
  its toolkit built first.
- **Beside them all:** bugs first, the team's requests, and the polish list. **Later:** off-site backups, phones, and 1.0, the first public
  release.

## Where we are (2026-10-18)

- **The rebuilt game is live** (launch day 2026-10-18, B49): the same game on a C++ combat core and Forward+ graphics. The biggest fight
  runs 3 to 4 times faster on Helix's PC (the Bell Sanctum's Full Party on Ultra: 61 to 224 fps); warbogar's PC plays it at 342 fps where
  the old game gave 41 in a lighter fight. The rebuild's record is B34-B50.
- Until 2026-11-01 one command puts the old game back (`server/death-muffin/launch-undo.sh`, B40); after that the old game's code goes.
- Ascension (the Altar, vows and heat, Ashes, Covenant Boons) left on launch day and comes back redesigned in Phase 3 (B36). Players'
  saved Ascension data is kept.
- **Now:** Phase 1, settling the launch.

## Waiting on Helix

Nothing right now. Answered on 2026-10-18: the code stays public until 1.0 and goes private, with the game's files encrypted, for that
first public release (B52); big changes get a test lane (B53); off-site backups go to a cloud storage bucket later (B51).

## Always on

- **Bugs and crashes first:** in-game reports and automatic crash reports (#in-game-reports), then the bugs in KNOWN-GAPS that cost
  players something.
- **The team's requests** through the Discord agent ship after approval, as before: bug fixes, small polish, warbogar's armor sets. A
  bigger new feature is planned into a phase instead: it goes to "Ideas" below.
- **The polish list** (below), top first, between phase items.
- Every gameplay change is measured and ships no slower than what it replaces (CLAUDE.md "Performance budgets").

## Phase 1: settle the launch

Goal: the new game has everything the old one had, it is the only game, it is safe if something breaks, and we can see how it runs on
players' PCs. The old game's removal is fixed on 2026-11-01, when the undo window ends; the other items run until they are done.
- [ ] **Fix: the Discord agent tests and photographs the old game.** Now: its proposals are checked with the old game's tests, its
  before/after screenshots are rendered from the old game on the server (minutes of software drawing next to the live game servers), and
  its "Try it" previews are builds of the old game too, so the team approves pictures of a game nobody plays. After: every proposal is
  tested on the live game, its screenshots come from a team PC through the team PC helper below (the server's slower pictures only when
  no PC is available, marked as such), and its previews are the live game. (The screenshot tool and its driver come over to `client/`.)
- [ ] **New: the team PC helper, in the launcher** (Helix, 2026-10-18: approved, for the accounts of War, Muffins and Helix only; B54).
  Jobs that need a real graphics card or Windows, which the server does not have, run on team PCs; the server keeps everything with keys or
  passwords and everything that changes the live game, and checks each result before using it. Only those three accounts can turn it on:
  they sign in to it in the launcher, and the server's job routes accept only them (hiding the option is not the protection). Each of them
  turns it on for their own PC and picks the job types it takes. When a job comes in, a small box says what it is and how heavy
  ("Screenshots of a change, about 1 minute": Run now / Not now / Pause 2 hours), and without an answer it runs by itself after 5 minutes,
  except while Death Muffin or another full-screen game or movie is running (Windows hides the question then, and a party's host runs the
  whole party's fight) or a laptop is on battery: then it waits for a yes or for the game to close. It never takes the keyboard or mouse,
  runs at low priority and stops if the game starts; it uses its own folder and plays offline (never the player's game, settings or
  account), runs only builds and kits our server made, and uploads only its results. Each PC can also run without asking (War's spare
  Alienware, if he sets it) or only on a yes. A new launcher reaches every player, so the release that carries the helper goes out only
  after it is tested and Helix gives the final OK. Its job types, in order:
  - Screenshots of a proposal on Low and Ultra, posted to the thread by our server (the item above).
  - Benchmarks for every release on a fast PC and on the Alienware's GTX 970 (the weak-PC floor of B39), on the benchmarks page; a
    benchmark waits until nothing else is loading the PC, and a run disturbed halfway is thrown out and retried, so its numbers are honest.
  - The stutter test of Phase 1's first-use item: every rite and effect played on a real graphics card, each hitch reported.
  - A release crash check: a release candidate plays a few minutes on two different graphics cards before it goes live, and quits while it
    is still loading (which crashed the old game on 4-core PCs); a crash stops the release.
  - Lighting bakes: when an area changes, the bake kit runs on the strongest graphics card available instead of by hand, and the result
    comes back as a proposal.
  - Later: a co-op test between two team PCs.
- [ ] **Fix: a document change from the Discord agent ships a game update.** Now: every change the agent ships also publishes a new game
  build, even when it only touches documents, so adding a line to this roadmap from Discord would send every player an update notice.
  After: a change that touches only documents goes to `main` with no new build and no notice, and the agent adds a team member's idea to
  "Ideas" (with its section) on an approver's ✅.
- [ ] **Fix: War's content pipelines run on trust, not on checks.** Now: armor sets, models and sounds come out right because the Discord
  agent follows a long set of written steps, and nothing checks the result. The agent may ask Tripo for up to 14,000 triangles for any model
  (so far every gear piece is under 3,500 and every hero body about 12,000 or less); new sounds are not matched in loudness and are left out
  of the licence record. After (ahead of Phase 2's full checks): the agent's check refuses a model over its budget, with more than one
  material or a different skeleton, and a hero body without its combat clips; the tools bring every new sound to the same loudness and write
  it into the licence record (KNOWN-GAPS "Content pipelines").
- [ ] **Fix: Grave Surges are missing.** Now: since launch day no Grave Surge ever starts (they were left out of the rebuild). After: as in
  the old game, after about 100 seconds in a combat area a crypt bursts open nearby, three waves climb out, and clearing them pays the surge
  reward; the surge tip shows again. (Port `godot/next/areas/dm_grave_surge.gd` onto the combat core.)
- [ ] **Fix: nobody is told when the game's servers stop.** Now: only the database is watched; if the game's server, the lobby or the
  co-op relay stops, nobody knows until players notice. After: each one is watched every minute, and a failure posts to #build-alerts
  (KNOWN-GAPS "Operations").
- [ ] **New: play reports.** When a play session ends, the game sends a small summary: average and worst frame times, the graphics preset,
  the graphics card, and time and deaths per area (nothing personal). A page on the site shows them per release, beside the server's own
  numbers (XP and gold per hour, drops). It gives: how the game really runs on every player's PC, weak ones included (no GTX 970-class PC
  or laptop has run the benchmark yet), whether a release made it slower, and where players struggle.
- [ ] **Decide: an "Ultra Low (old PCs)" option** (B35). Once the play reports and the GTX 970 benchmark show how Low runs on weak PCs: if
  Low on the new renderer misses the laptop floor (60 fps in normal play, 45 in the biggest fight), add an option that restarts the game in
  the old, lighter renderer. Claude recommends deciding from those numbers, not before.
- [ ] **Fix: crash reports cannot point inside the combat core.** Now: when the C++ combat core crashes, the report has the log but no
  location, because the core ships without its debug symbols. After: each crash report names the build and the line of code that crashed
  (the symbols of every published build are kept on the server).
- [ ] **Fix: first-use stutters.** Now: an effect is compiled the first time it is drawn, which stutters, unless it is on a warm-up list
  kept by hand (both Reaper stutter reports came from gaps in that list). After: Godot compiles every effect when the game is built (its
  shader baking option), and a test fails if an effect used in play could still stutter.
- [ ] **Fix: two copies of the game's code** (on 2026-11-01, when the undo window ends). Now: the old game's folder `godot/` is still there,
  most of the new game's scripts are copied from it, and the crowd and map tools, about 66 tool and server scripts and some tests still read
  it; the 31 short system guides (how each system works and its known gaps) live only in `godot/`. After: the system guides move into
  `client/` first, then `godot/` is deleted, the new game owns its files, every tool and test reads the new game, the Discord agent edits
  the new game directly, `server/death-muffin/launch-undo.sh` goes, and README.md and CLAUDE.md describe one game.

Done when: `godot/` is gone, every check and screenshot is of the live game, the servers are watched, and a week of play reports is in.

## Phase 2: foundation

Goal: every Claude session and the Discord agent understand what the game should be and build every part of it the same way, so the
team's ideas come out right the first time and little is redone. Nobody on the team writes code, so the written direction, standards,
pipelines and automatic checks are the framework. Six tracks that can run side by side; inside a track, top first. The toolkits for new
kinds of content (enemy parts, rite parts, maps, quests) are built in Phase 4 together with their first content.

### A. Direction and workflow: what we are making, and how an idea becomes a feature

- [ ] **Decide + New: the game vision, on one page,** written with the team. What Death Muffin is (the fantasy, the core loop, the feel of
  a fight), who it is for (friends now, the public from 1.0, B52), which platforms (Windows now, phones later, anything else such as the
  Steam Deck), whether it will ever earn money (asset licences depend on it: the ElevenLabs
  plan in use excludes monetized games), the pillars that decide ties (performance first, polish over new content, necromancer focus, loot
  never vacuums, readable fights), and what the game will not be. It gives: the root every other standard follows, and the first thing every
  session reads.
- [ ] **Decide + New: who decides what, and who works on what.** Now the owner, Helix and warbogar can each approve everything, and nothing
  says who is working on which part. After: art, design and numbers, spend, and releases each name who approves them and who is asked;
  each person has a lane (for example: Helix with the terminal sessions on the phases; War with the Discord agent on content whose pipeline
  works, and on concepts and lore ideas for later content; Muffins on the direction and money); and a roadmap item someone starts is marked
  "in progress: who, date", so two people or sessions never take the same work.
- [ ] **New: a team guide in plain words.** One page for Helix, War and Muffins: how to ask the Discord agent for something, what a
  proposal, a ✅, the test lane and the team PC helper do, what Fix, New and Decide mean here, and where to look (this roadmap, Ideas, the
  catalogue). It gives: everyone works the same way without asking how.
- [ ] **Fix: the test lane for big changes cannot be used** (Helix, 2026-10-18: keep it; B53). Now: the launcher's Test build switch, the
  test server and its lobby and relay still exist, but since launch day the game only talks to the live server, so no new test build can be
  made. After: a big change (Ascension, a new class, the map revamp) is published to the test channel first, from `main` or a short-lived
  branch, built so it reaches only the test server (and the live build only the live one); the test server's copies of the team's accounts
  are refreshed when asked; the team plays it there before it goes live. Small fixes and everyday requests still go straight to live.
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
- [ ] **Decide + New: the art direction guide.** Claude drafts it from today's look, the area moodboards (`docs/art/areas/`) and
  Gravecrawl's lessons, with example pictures; the team picks and approves. It sets the game's look in a paragraph, each area's palette and
  lighting mood, the colour rules (for example: enemies, heroes and the ground always differ in colour and brightness; violet for magic,
  gold for reward, red for danger; what each spell colour and loot rarity means), silhouettes that read at the game camera's distance (about
  22 m), how shiny and how bright materials may be (Tripo's models come out metallic and white out under glow), how heroes, thralls and
  enemies are told apart (rims, glows), and the style of icons, portraits and UI frames. It gives: one page every new asset is checked
  against, and the target for the asset and effects rebuild.
- [ ] **Fix: budgets in two places, for three kinds of asset.** Now: ASSET_PIPELINE.md asks Tripo for a 12,000-triangle hero and a 14,000
  boss while CLAUDE.md caps both at 20,000, and nothing covers gear, props or the world. After: one table for the hero, bosses, crowd
  creatures, thrall variants, weapons and gear pieces, small, medium and large props, wall and floor pieces, effect meshes and UI art, each
  with triangles (a target and a hard cap), texture size, materials, bones and levels of detail, plus a budget per area (triangles in view,
  draw calls, lights). Starting numbers come from today's assets and are confirmed with the benchmark.
- [ ] **New: how one model serves Ultra, old PCs and phones.** Written rules for the quality tiers: each model is made once, at its budget,
  and the tools make the lighter versions (Godot already makes levels of detail for every model, and each preset decides how soon the
  lighter ones show); Ultra adds extras on top (shadows, ambient occlusion, more particles) rather than heavier models; Low thins the
  effects out; phones get the Low preset plus a phone pack with smaller textures in phone formats (B40), and a check proves every shader and
  effect also runs on the phone renderer. It gives: Ultra keeps looking its best while Low stays above the weak-PC floors, and nothing has
  to be remade when phones come.
- [ ] **New: the rigging standard.** One skeleton per body type (humanoid, which is Tripo's shared biped skeleton; four-legged; and today's
  bloated and robed kinds), bone names, the attachment points (right and left hand for weapons and shields, head for helms, shoulders and
  back for mantles), scale (1 unit = 1 m, a height range per kind), facing and the pivot at the feet, and a bone limit for phones. It gives:
  any new creature reuses the existing animations, gear and props, and goes straight into the crowd baker.
- [ ] **New: the animation standard.** The clips every kind of creature must have (idle, walk, run, attack, a second attack, hurt, death,
  rise, plus role clips such as cast or dig), their names, lengths, loops and frame rates; clips stay in place (the game moves the body);
  the moment each attack lands is marked so the damage lines up with the swing; the crowd baker's limits; and the known traps of Tripo's
  presets (its "hurt" is a 14-second lying-down clip). It gives: every creature moves and hits the same way, and a missing or broken clip is
  caught by a check instead of a player.
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
  health and damage by area level, XP and gold per minute, drop rates, where gold comes from and where it goes); enemy roles (melee,
  flanker, caster, hazard, support) and telegraph rules (every dangerous attack has a readable wind-up and a ground marker); how hits and
  kills feel (sound, flash, number and screen shake, each with its cap); a boss template (phases, telegraphs, adds, summoning key, scaling
  for a party, rewards); and area rules (size, fighting space, landmarks, spawn points, safe spots). A balance tool built on the seeded
  fight harness plays a fight without a screen and reports time to kill, damage taken and XP and gold per minute, so a new item or enemy is
  checked against the curve before anyone plays it. It gives: new items, enemies and areas fit the game without retuning everything around
  them.
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

### E. Engineering standards and health

- [ ] **New: done means done.** CLAUDE.md says, for each kind of change (code, content, art, server, docs), what must be true before it
  ships: tests, measurements, screenshots, docs.
- [ ] **New: an automatic secret scan.** The repository is public and many sessions push to it, but only a scan each session runs by hand
  keeps keys and passwords out. After: every push is scanned before it leaves the server and again in CI, and one with a secret is refused.
- [ ] **Fix: a document-only push runs every test.** Now: each push to `main` runs all the suites (about 20 minutes), even when only a
  document changed. After: a push that changes only documents runs the document checks; game changes run everything, as now. This also
  keeps the free test minutes in reach once the code goes private for 1.0.
- [ ] **New: a security watch on the server's packages.** The game's server, lobby and relay use outside code packages that get security
  fixes. After: a weekly check lists packages with known holes, and they are updated on purpose, tested, like any change.
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
  both with their monthly cost; the automatic tests download the art on every run, which decides it), so the repository stays small and
  fast.

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
  instead of generated from the web game's map file (`world.json`) as now; then the maps revamped. Its notes: KNOWN-GAPS "Assets and
  effects".
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
- [ ] **Fix: the look pass** (moved after launch by Helix, B49). Now: blended effects (decals, telegraphs, particles) look wider and
  brighter than in the old game, most on Low and Medium; the Depths' walls are darker; the hero reads darker in bright areas (the Coliseum,
  the Cloister, the Pyre, the Wing) and brighter in dark ones; not every area is signed off. After: every preset looks like the old game or
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
  - Players in different areas. Now: only the host's area gets waves; a member fighting in another area meets no new enemies until the
    host's area empties. After: each area a member fights in gets its own waves.
  - The Depths. Now: they are solo only. After: decide whether a party can descend together, and build it if so.
  - What a guest brings. Now: a guest cannot call an Empowered boss, and a guest's Colossus Mantle effects, Covenant Seal and Nightfall dimming
    do not reach the host's game. After: a guest's gear and choices work in the party as they do solo.
  - Late joiners. Now: someone who joins during a boss fight does not see the pools already burning. After: they see the fight as it is.
  - Friends online. Now: friends show as online only once they are in the world, not at character select or in the launcher. After: they
    show as online whenever the game is open.
- [ ] **Decide + Fix: things built but never shown.** Now: thralls never wear their Legion kit or their discipline's look, water never
  ripples, the Prelate's candles never gutter, and the Plague Doctor's flask leaves a pool that hurts but cannot be seen. After: each one is
  shown to the team with screenshots; what they keep is switched on (the invisible pool at least gets drawn, so players can dodge it) and
  the rest is deleted.
- [ ] **Fix: two small bugs.** Gathering: now the last 8 seconds of gathering before quitting are lost; after, they are saved. Easy auto
  combat: now it walks the hero into pockets between tombstones and parks there; after, it walks around them.
- [ ] **Fix: seven tips never show.** Now: the counsel has tips for the Depths (going in alone, a new floor, a floor's affix), a loadout
  check, a weapon change, a set bonus gained and an Omen told, but nothing ever triggers them. After: each shows once at its moment, or is
  deleted if the team does not want it.
- [ ] **Decide: the first goal after the Hollow Graves.** Now: right after entering the Graves the Next-step line says "Ossuary seal: 0/300
  kills", a steep first goal. After: the team picks a softer first goal, and the Next-step box leads there.
- [ ] **New: necromancer polish from playtests:** combat feel and loot, readability of rites and statuses, gear and affix legibility, the
  rest of the first hour (the Next-step box, counsel tips, guide NPCs).
- [ ] **New: small additions:** colours in the chat window; an in-game leaderboard panel (today only the website shows it).

## Later

- **Fix: backups never leave this server** (Helix, 2026-10-18: a cloud storage bucket, set up later; B51). Now: the database is backed up
  every night, but onto the same server, and the raw art sources, the licensed packs and the private effect sheets exist only here, so
  losing the server would lose all of it. After: every night a copy of everything that is not in git goes to the cloud bucket, and a restore
  from it is tested.
- **New: phones.** The Mobile renderer, touch controls built with the HUD, phones join as guests. The game stays ready for them (B40:
  phone texture formats, shaders that run on Mobile, a scalable HUD) and Phase 2's quality tiers set their budgets.
- **New: 1.0, the first public release** (B52). The repository goes private and the game's files are encrypted in the build; accounts
  get an email address and password recovery (none exist today); chat gets reporting and moderation; a privacy policy and terms; a signed
  launcher and game so Windows does not warn new players; a review of the servers' capacity and of cheating; a licence check of every asset
  against how the game is offered (Tripo models, ElevenLabs sounds and music, the sound and effect packs); the test runs fitted to the paid
  minutes of a private repository; and a store or download page.
- Not planned: dedicated or VPS-hosted game sessions and host migration (the hybrid model stays, owner 2026-10-15; D6), translations, mod
  support.

## Risks we are carrying

- **One server holds everything:** the game, its database and every backup, until the cloud bucket exists (Later). Phase 1's alerts at least
  tell us when something stops.
- **Every line is written by Claude:** when usage runs out or the service is down, all building pauses. The docs, recipes and checks
  (Phase 2) make any fresh session able to continue; nothing depends on one session's memory.
- **The code is public until 1.0:** cheaters can read how the server checks them. The server owns every value (Phase 2, track D), and the
  code goes private for 1.0 (B52).
- **Licences:** the ElevenLabs plan in use excludes monetized games, and every asset's licence matters once the game is offered to the
  public. The vision decides about money (Phase 2, track A); 1.0 checks every licence.
- **The undo window ends on 2026-11-01:** after that the old build cannot come back, so the new game's crash reports and play reports
  (Phase 1) are how we learn about problems.

## Ideas

New ideas and requests from anyone land here first, one line each with its date and the section it would belong to. They wait here
until the team says yes, because every unchecked item in a phase or the polish list is treated as approved work by every session. When a
phase is planned, its ideas move into its checklist as Fix or New items (or straight away, when Helix says so). Bugs and gaps go to
KNOWN-GAPS.md instead.
- A hint for a party guest standing in a boss's rot (a guest's core lists no zones today). Section: polish list, co-op gaps. 2026-10-17.

## Done

- 2026-10-16 to 2026-10-18: **the rebuild**, a C++ combat core and Forward+ graphics under the same game (B34-B50).
- 2026-10-13 to 2026-10-15: **server authority**: the server rolls every drop, owns the bag and pays only what the kill ledger backs
  (B19-B26, B32).
- 2026-10-09: **the baseline cleanup**: one game, one branch, docs that say how things are (B1-B11).
