# Roadmap

What gets built, in order. Two kinds of work run side by side: the **always-on** work (bugs, the team's requests, a steady stream of
things players notice, the polish list) and **one phase at a time**, top to bottom. Inside a phase the next unchecked item is the work
(Phase 2's tracks can run side by side), and each phase ends with a "Done when" check. The technical detail of each gap is in
[KNOWN-GAPS.md](KNOWN-GAPS.md), the reasons behind choices in [DECISIONS.md](DECISIONS.md) (this plan's: B50 and B56), and the rules
every change follows in [CLAUDE.md](CLAUDE.md).

Every item says what kind it is:
- **Fix:** something wrong or missing in the game or in our tools. It says what happens **now** and what it will be **after** the fix.
- **New:** something we add. It says what it gives us.
- **Decide:** a question only the team can answer, with Claude's recommendation.

## At a glance

- **Phase 1, settle the launch,** as soon as possible: alerts when a server stops, Grave Surges back, crash reports that point at the
  cause, the Discord agent working on the new game and the old game's code gone, checks for War's content, no first-use stutters, play
  reports, and the team app (screenshots and benchmarks on team PCs).
- **Phase 2, the foundation's core:** the game vision, how we work, the look, the size limits and the balance rules, content data in one
  place with automatic checks, recipes for what is made today, and the server owning every value. Done when three real pieces of content
  have gone through it cleanly. The rest of the standards are written when their first content arrives.
- **Phase 3, Ascension redesigned:** the first new feature, planned with Helix during Phase 2 and built right after it.
- **Phase 4, new content:** the look of the world, new places, enemies and bosses, the other five classes, quests and endgame, each with its
  toolkit and its standards built first.
- **Beside them all:** bugs first, the team's requests, something players notice every week or two, and the polish list. **Later:**
  off-site backups, phones, and 1.0, the first public release.

## Where we are (2026-10-19)

- **The rebuilt game is live** (launch day 2026-10-18, B49): the same game on a C++ combat core and Forward+ graphics. The biggest fight
  runs 3 to 4 times faster on Helix's PC (the Bell Sanctum's Full Party on Ultra: 61 to 224 fps); warbogar's PC plays it at 342 fps where the
  old game gave 41 in a lighter fight. The rebuild's record is B34-B50.
- The old game is retired (B57; its source is tag `archive/old-game`): a rollback publishes an earlier build of the game.
- **Now: Phase 1, settling the launch.** Done: alerts when a server stops, Grave Surges back, crash reports that point inside the combat
  core, the Discord agent working on the live game, document-only changes that ship no update, checks for War's content, play reports,
  shaders baked into every release, the old game's folder deleted (its tests moved to the game), and the team app's first job (pictures on a
  real graphics card, proven on Helix's PC) and its other jobs (B58, B62: checks of a revision before it goes live, clips and "pick one", before and after,
  pictures without `!shot`), and a free team PC starting every release before players get it (B61). Left: War's PCs on the team app, the
  stutter fixes the checks turn up on a weaker card, and the Ultra Low decision once the numbers are in.
- Ascension (the Altar, vows and heat, Ashes, Covenant Boons) left on launch day and comes back redesigned in Phase 3 (B36). Players'
  saved Ascension data is kept.

## Waiting on Helix

One open question: whether the Discord agent runs the team PCs' checks as tests at 🧪 and ✅ (built, on hold; Phase 1, the team app, with Claude's
recommendation). Answered on 2026-10-18: the code stays public until 1.0 and goes private, with the game's files encrypted, for that
first public release (B52); big changes get a test lane (B53); off-site backups go to a cloud storage bucket later (B51); the team PC
helper is a separate team app for War, Muffins and Helix (B54, B55); the roadmap is slimmed as Claude advised (B56); the old game's code
goes as soon as nothing depends on it (B57).

## Always on

- **Bugs and crashes first:** in-game reports and automatic crash reports (#in-game-reports), then the bugs in KNOWN-GAPS that cost
  players something.
- **The team's requests** through the Discord agent ship after approval, as before: bug fixes, small polish, warbogar's armor sets. A
  bigger new feature is planned into a phase instead: it goes to "Ideas" below.
- **Something players notice, every week or two:** an item from the polish list or a fix players asked for ships with its patch notes, so
  the game keeps moving while the foundation is built.
- **The polish list** (below), top first, between phase items.
- Every gameplay change is measured and ships no slower than what it replaces (CLAUDE.md "Performance budgets").

## Phase 1: settle the launch

Goal: the new game has everything the old one had, it is the only game, we hear when something breaks, and we can see how it runs on
players' PCs. Everything here is done as soon as possible, in this order (Helix, 2026-10-18: "we can do these things asap"; B57).
- [x] **Fix: nobody was told when the game's servers stopped.** Done 2026-10-18: the game server and its database, the public API, the
  lobby, the co-op relay and the game download are checked every minute; a failure that lasts two minutes posts to #build-alerts, a
  reminder follows every hour while it lasts, and the recovery is posted too (`server/death-muffin/ops/health-watch.mjs`; ops README
  "Health watch").
- [x] **Fix: Grave Surges are missing.** Done 2026-10-18: after about 100 seconds in a combat area a crypt bursts open nearby, three waves climb
  out, and clearing them in time pays the surge reward; the surge tip shows again (`client/next/areas/dm_grave_surge.gd`; client README "Grave Surges").
- [x] **Fix: crash reports could not point inside the combat core.** Done 2026-10-18: the core writes a crash note while the game crashes
  (each stack frame's module and offset, where Godot's log says "???"), the next start's automatic crash report carries it, every publish keeps
  that build's symbols, and `node tools/crash/symbolize.mjs <report id>` names the function and source line (native/README.md "Crash notes").
  The Windows half is confirmed on a real PC by the team app's crash check (KNOWN-GAPS "Stability").
- [x] **Fix: the Discord agent tested and photographed the old game.** Done 2026-10-18: it makes its changes in the game (`client/`) directly;
  every proposal is tested on the game (the quick check runs the suites the change can affect), with the combat core, the import and the
  crowd's bakes taken from a cache built only from `main` (today `tools/check/prep.sh --warm`), so a check does not rebuild them;
  its screenshots are the game's, rendered on the server the way it plays (until the team app takes them over), and a "Try it" preview without
  new art uses the art pack of the player's installed game instead of carrying its own 500 MB. Fixed 2026-10-19: the co-op and friends
  suites (coop, coop_bosses, lobby) start the real lobby, which a job's copy of the game could not run without the lobby's packages, so
  every check that picked them failed (War's Haunting Wraith, three times on 2026-10-18); the check now brings those packages in. Fixed
  2026-10-19: a round ran its whole check twice, about 20 minutes each (the agent in its turn, then the runner before the proposal); the
  agent now runs only the suites it names (`check-godot.sh --rerun`), and the whole check is the runner's.
- [x] **Fix: the Discord agent's checks were slow and failed late, or for reasons outside the change.** Done 2026-10-19. Now → after: the
  game's suites ran one at a time (the old game's runner ran 8 at once; that was lost in the switch), so a check took 20 to 35 minutes → side by
  side again, the slowest first, the lobby and relay suites in a lane of their own, each failure once more alone (all 112 suites in about 6.5
  minutes; a spell-sized change's check about 5 minutes end to end, co-op included). A job was checked against the main it started from, so
  suites main had gained failed only at ship → the check runs with the latest main merged into the branch, and a ship of the same code skips
  its tests. A broken test setup cost repair turns and an hour of checks → the failing suites run on clean main first, and if they fail there
  too the thread is told plainly, with no repair turn. The automatic re-run could pass a check with a folder suite still failing → it reads
  every suite and counts against the summary. Three tests named the number of spells or abilities → they compare the spell registry with the
  spell files and the two ability tables with each other.
- [x] **Fix: testing was slow, and sessions and the Discord agent each did it their own way** (B59). Done 2026-10-19. Now → after: four
  separate setups built the game for every checkout (about 7 minutes for a new worktree) → one setup with one shared cache (about 15
  seconds); CI took 20 to 24 minutes and sessions waited for it while the agent shipped on its own quick check → CI runs every suite on
  every push in about 4 minutes and is the one gate for everyone, the deploy and publish scripts included; approvals that wait for a ship
  still go out together, now with one CI run for all of them; tests that broke when a spell or an area was added compare the game's data
  with itself instead.
- [x] **Fix: the Discord agent made people wait for tests between every round** (B63). Done 2026-10-19. Now → after: each round of back and
  forth waited about 3 minutes for CI before its proposal → rounds are drafts, proposed at once; 🧪 tests on request and ✅ tests and ships; a
  ship whose tests fail comes back fixed for one more ✅; ❌ asks before it throws the work away.
- [x] **Fix: the next test build could break testing and the Discord agent again unnoticed** (B63). Done 2026-10-19. Now → after: a new suite
  nobody listed never ran → CI fails until it is listed; the agent's own tests ran only by hand → in CI; a renamed folder silently dropped its
  protection from the agent's rules → CI fails until the rules follow; nothing stopped a workflow from asking for a paid GitHub machine → CI
  refuses it; an expired GitHub token left the checks stuck → they carry on without it, and the nightly report warns two weeks ahead; the
  first real request was the only test of a reinstalled agent → its practice run proves it end to end first.
- [x] **Fix: a document change from the Discord agent shipped a game update.** Done 2026-10-18: an approved change that touches only
  documents (Markdown files, docs/) goes to `main` and stops there, with no game build, deploy or notice, and the thread says so; when someone
  shares an idea the roadmap lacks, the agent offers to add it to "Ideas" with its section (server/death-muffin/discord-agent/README.md).
- [x] **Fix: the old game's folder was still in the repository** (B57). Done 2026-10-19: the old game's test suites that covered code the
  game runs moved to `client/tests` (111 suites now, their reference files beside them), and the folder is deleted (tag `archive/old-game`
  keeps its source; a check refuses new references to it).
- [x] **Fix: War's content pipelines ran on trust, not on checks.** Done 2026-10-18: the Discord agent's check, and CI over every model,
  refuses a model over its cap (gear 4,000 triangles, props 6,000, heroes and other characters 20,000), with more than one material, gear
  with a skeleton, or a hero body without the shared skeleton and its combat clips (`tools/assets/check-models.mjs`); the tool that installs a
  new sound brings it to the game's loudness (-20 LUFS) and writes it into the licence record, docs/AUDIO-SOURCES.md. Armor sets still touch
  about five files by hand (KNOWN-GAPS "Content pipelines").
- [ ] **Fix: first-use stutters.** Now: every release bakes the game's shaders into its pack (since 2026-10-19; the art pack's are baked the
  next time its art changes), and since 2026-10-19 a test fails when play draws a material the loading screen never drew
  (`client/tests/warm_coverage.gd`: every rite of the five disciplines, a fight, a boss, waves, loot, worn gear and pets); it found nine
  gaps (a dropped item's icon, name and light, and six pieces of worn gear and pets) and the warm-up now draws them. The test cannot see
  lighting variants, presets other than High, the other areas and bosses, UI panels, death and respawn, or other players' effects. The team
  app's stutter test ran on Helix's RTX 4070 SUPER on 2026-10-19 (every rite of the five classes once, High): p99 2.8 ms, the worst frame 40 ms
  on the Reaper's Soul Burst, which was the bar greying six spells at once (fixed the same day: the greyed icons are baked on loading); five
  casts went over 8 ms (Ossuary Wall 14, Grave Frost 10, Ivory Cleave 9, Exhume 8), and the casts still compiled 395 shader pipelines, the same
  ones again in every new game (Soul Siphon 18 each time). The two runs after the fix (releases 1852fe7 and 578df6f, 2026-10-19) had no cast
  over 8 ms (worst 6.6 and 6.5 ms, p99 2.4 ms; the third, of b0b717a, one: the Mourner's Bone Needle at 12.9 ms, 5.6 the run before) and still about 400 compilations, which Godot builds in the background, so on that card they no
  longer show as hitches; a weaker card (War's GTX 970) is the open question. The repeats are not materials freed and made again (a material
  made again does not compile again in Godot 4.7.2: a small test on the server's software renderer, 2026-10-19). Since 2026-10-19 the stutter test
  counts each kind of compilation apart, and #build-alerts says how many ran in the background, so the next runs show which ones make a frame wait.
  After: the warm-up also draws what those casts compile, a new game compiles nothing the one before it did, and the next stutter test shows no
  cast over 8 ms.
- [x] **New: play reports.** Done 2026-10-19: when a play session ends (log out, switch character, quit; a crash is sent at the next start) the
  game sends a small summary: average, p99 and worst frame times, hitches, the graphics preset and card, time and deaths per area, and where
  the session ended (nothing personal). The site's play reports page shows them per release, beside the server's own numbers over the same
  party sessions (kills, boss kills, and the XP and gold the saves paid, per player-hour) (`server/death-muffin/backend/play-reports.cjs`,
  client/next/perf/README.md "Play reports"). It gives: how the game really runs on every player's PC, weak ones included, whether a release
  made it slower, where players struggle or stop, and whether polish is making the game more fun.
- [ ] **New: the team app** (Helix, 2026-10-18: for War, Muffins and Helix only, B54; its own app, not the players' launcher, B55). A small
  Windows app, installed only on the three team PCs, with the launcher's look and its own automatic updates; a bug in it can be fixed in
  minutes and never reaches players. It runs jobs that need a real graphics card, which the server does not have; the server keeps
  everything with keys or passwords and everything that changes the live game, and checks each result before using it. Only those three
  accounts can sign in to it, and the server's job routes accept only them. When jobs come in, a small box lists them, oldest first, with how heavy each is
  and whose Discord thread it came from (pick one: Run now / Not now / Pause 2 hours), and without an answer the picked one runs by itself after 5 minutes,
  except while Death Muffin or another full-screen game or movie is running (Windows hides the question then, and a party's host runs the
  whole party's fight) or a laptop is on battery: then it waits for a yes or for the game to close. It never takes the keyboard or mouse,
  runs at low priority (a benchmark at normal priority, once the PC has been left alone) and stops if the game starts; it uses its own folder and plays offline (never the player's game, settings or
  account), runs only builds and kits our server made, and uploads only its results. Each PC can also run without asking (War's spare
  Alienware, if he sets it) or only on a yes. Every job asks the same way, benchmarks included (Helix, 2026-10-19). Its jobs, in this order
  (B58: all of them in Phase 1):
  - Screenshots of a proposal on Low and Ultra, posted to the thread by our server. Live since 2026-10-19 and proven on Helix's PC that
    night (0.1.1: four pictures in 40 s of play; 0.1.0 could not start the game and reported no graphics card). With a team PC online they
    replace the server's pictures; with none, the server renders them on `!shot`.
  - Benchmarks of a release build on a team PC (a fast PC, War's Intel Arc, the Alienware's GTX 970: the weak-PC floor of B39), on the
    benchmarks page marked as team runs. A benchmark starts once the PC has been left alone, and a run disturbed halfway is thrown out
    and retried, so its numbers are honest. Built 2026-10-19 with app 0.2.0 (now a step of the checks below), which also brought silent runs, screenshot runs that never show a window, a fresh folder for every run, cancels that
    reach the PC within 30 s, and AFK mode (Helix's design: once a job ran by itself because nobody answered, the next jobs run without
    the 5-minute wait until the person ends it or starts a game).
  - Built 2026-10-19 with app 0.3.0 (one release for all of these, B58):
    - Pictures without `!shot`: with a team PC online, the Discord agent writes a shot plan for every visible change and the team PC
      renders it, before and after side by side (the unchanged game and the change), on Low and Ultra.
    - Clips and "pick one": a few seconds of a spell or effect recorded by the game itself (1920x1080 at 60 frames a second since app 0.4.5, made into an mp4 on the
      team PC; only the spell, not the loading), posted as videos; for a choice (War's Haunting Wraith at three speeds) each option is numbered and the thread
      asks which one. Model previews are clips too: the new piece worn by a hero, turning.
    - Scripted clips (B64, 2026-10-19): a clip can set its scene up and say what happens when, with the words of the game's own list
      (`client/main/qa_clip_steps.json`: the HUD on screen, mortal or harmful stand-ins, the Reaper's souls, no top-up, casts at set times).
      A video that needs a new word gets it in the same change from the Discord agent, with no change to its runner.
    - Release checks: a fresh install and boot, quitting while loading (the old 4-core crash), the windows and HUD at 1080p, 1440p, 4K
      and ultrawide and the largest UI size, the stutter test (every rite of every discipline, each cast's worst frame and pipeline
      compilations), the benchmark, and a 30-minute soak (memory and frame times per minute). Since B62 (Helix, 2026-10-19) they run
      BEFORE a release, when its shipper asks, never after it: `server/death-muffin/team-check.sh <rev> --checks ... [--compare]` builds
      the revision, runs the chosen steps on a team PC (with `--compare` the live build first, on the same PC, so every number reads live
      build -> this change) and writes a summary and contact sheets for whoever asked: a session posts them to a new thread or a DM (it
      asks the person which). Approval never waits for them.
    - Decide: the Discord agent runs these checks as tests at its test runs (🧪 / `!test` and the ship's own CI): a pass posts nothing, a
      failure is fixed and tested again, and the thread hears only what needs a person's review (before and after pictures of a visible
      change, a choice, a problem it could not fix). Built on the server's side, on hold for Helix. Claude's recommendation: `screens` with
      `--compare` only for changes to windows or the HUD, `stutter` only when a rite changes; the benchmark and the soak stay a session's,
      on request (they hold a PC for 5 to 35 minutes).
    - Jobs reach a PC within about a second (the PC's check-in waits on the server).
  - Proven on Helix's PC (RTX 4070 SUPER) on 2026-10-19 with apps 0.3.1 to 0.3.9: a full release check with every step (24 pictures at
    their exact sizes, the stutter test, the benchmark at Low 691 and Medium 597 fps with no hitches, 30 minutes of soak with flat memory).
    Its first finding was a real bug: the Windows release build crashed while closing, after every quit; since 2026-10-19 it ends its own
    process once its shutdown is done (B60; the cause inside the engine is in KNOWN-GAPS "Stability"), and the next release check passed
    every step with no crash (Low 676, Medium 639 fps). The app updates itself between jobs,
    so a check never runs on an old app.
  - Decide: a team PC runs the Discord agent's branch before anyone has reviewed it (found 2026-10-19). Pictures and videos are made from the
    change itself, so its game code runs on Helix's PC; it runs offline in its own folder, but game code can still reach the PC (run a program,
    read a file). Today only War, Muffins and Helix can ask the agent for changes, which limits the risk. Claude's recommendation: before team PCs
    take jobs from anyone else (or War's PCs join), scan the branch's game code for calls that reach outside the game (programs, files outside
    its folder, the network) and refuse a team build that has one; the video steps themselves (B64) are data and never bring code.
  - Still to do: War's PCs (the Intel Arc and the Alienware's GTX 970) have not signed in to the app yet, so the release checks and
    benchmarks cover one graphics card; the weak-PC floor (B39) and the Ultra Low decision below wait on them.
  - Fix: a release that does not start on Windows reached players before any team PC tried it (the server's boot test runs the Linux build).
    Done 2026-10-19 (B61): before the switch to a new build, a free team PC starts it to the first screen and quits one while it loads
    (about 10 seconds); if the game fails there, the build is not published and the publish says why. No free PC, or none taking it within
    2.5 minutes, lets the release go out as before (`server/death-muffin/team-gate.sh`; README "Pre-release check"). Proven on Helix's PC
    the same day: taken after 5 seconds, passed in 14.
  - With the art rebuild (Phase 4): lighting bakes on the strongest graphics card available instead of by hand, the result coming back as
    a proposal.
  - Later: a co-op test between two team PCs.
- [ ] **Decide: an "Ultra Low (old PCs)" option** (B35). Once the play reports and the GTX 970 benchmark show how Low runs on weak PCs: if
  Low on the new renderer misses the laptop floor (60 fps in normal play, 45 in the biggest fight), add an option that restarts the game in
  the old, lighter renderer. Claude recommends deciding from those numbers, not before.

Done when: the old game's folder is gone, every check and screenshot is of the live game, the servers are watched, and a week of play reports is in.

## Phase 2: the foundation's core

Goal: every Claude session and the Discord agent understand what the game should be and build what we make today the same way, so the
team's ideas come out right the first time and little is redone. Nobody on the team writes code, so the written direction, a few strong
standards, the pipelines and the automatic checks are the framework. It holds only what every piece of content needs; each other
standard is written when its first content arrives, because rules written before anyone knows the content are guesswork (CLAUDE.md: no
speculative abstraction). Written when first needed, each an item where it lands:
- The effects standard: with Haunting Wraith, the rite recipe's first test (track C).
- The UI standard: before Ascension's windows (Phase 3).
- The rigging and animation standard, and enemy roles, the boss template and area rules: with the first new creature, boss and place
  (Phase 4).
- The props and world-kit pipeline, and where big art files live: at the start of the art rebuild (Phase 4).
- The audio rules started with Phase 1's loudness check (every new sound at -20 LUFS) and grow with the next sounds.

Five tracks that can run side by side; inside a track, top first. All standards live in three pages (the look, the tech art, design and
writing) plus one "How we work" page; CLAUDE.md points every session to them.

### A. Direction and how we work

- [ ] **Decide + New: the game vision, on one page,** written with the team. What Death Muffin is (the fantasy, the core loop, the feel of
  a fight), who it is for (friends now, the public from 1.0, B52), which platforms (Windows now, phones later, anything else such as the
  Steam Deck), whether it will ever earn money (asset licences depend on it: the ElevenLabs plan in use excludes monetized games), the
  pillars that decide ties (performance first, polish over new content, necromancer focus, loot never vacuums, readable fights), and what
  the game will not be. It gives: the root every other standard follows, and the first thing every session reads.
- [ ] **Decide + New: "How we work", on one page,** in plain words for Helix, War and Muffins:
  - Who decides what and who works on what. Now the owner, Helix and warbogar can each approve everything, and nothing says who works on
    which part. After: art, design and numbers, spend and releases each name who approves them and who is asked; each person has a lane
    (for example: Helix with the terminal sessions on the phases; War with the Discord agent on content whose pipeline works, and on
    concepts and lore ideas for later; Muffins on the direction and money); a roadmap item someone starts is marked "in progress: who,
    date", so two people or sessions never take the same work.
  - From idea to shipped: any feature bigger than a tweak gets a one-page plan first (the goal, what the player sees, the rules and
    numbers, the art and sound it needs, its budgets, how we will know it works); the team approves it, then it is built with the recipes,
    passes the checks and the look check, is playtested and ships with its patch note. The Discord agent uses the same plan for bigger
    requests. This is where most rework is saved.
  - The playtest routine: after each phase and each big change, a short team session with a checklist of what changed; findings go to
    KNOWN-GAPS or Ideas through the Discord agent, beside the play reports' numbers.
  - Done means done: for each kind of change (code, content, art, server, docs), what must be true before it ships.
  - How to ask the Discord agent for something, what a proposal, a ✅, the test lane and the team app do, what Fix, New and Decide mean,
    and where to look (this roadmap, Ideas, the catalogue).
- [ ] **Fix: the test lane for big changes cannot be used** (Helix, 2026-10-18: keep it; B53). Now: the launcher's Test build switch, the
  test server and its lobby and relay still exist, but since launch day the game only talks to the live server, so no new test build can
  be made. After: a big change (Ascension, a new class, the map revamp) is published to the test channel first, from `main` or a
  short-lived branch, built so it reaches only the test server (and the live build only the live one); the test server's copies of the
  team's accounts are refreshed when asked; the team plays it there before it goes live, and one script puts it live: it checks that CI
  passed the merged files, waits for the Discord agent to be idle and holds the deploy lock, deploys and publishes, reinstalls the agent if
  its files changed, and requires a clean drift report and the agent's practice run, stopping at the first failure (B63). Small fixes and
  everyday requests still go straight to live.
- [ ] **Decide + New: Ascension's one-page plan,** written with Helix through "From idea to shipped", so Phase 3 starts building the day
  this phase ends: what the Altar, vows and heat, Ashes and Covenant Boons become, and the co-op rules (today a guest's Prelate kill counts
  for the host).

### B. The core standards: the look, the tech art, design and writing

Today some of it exists: budgets for the hero, bosses and crowd creatures (CLAUDE.md "Performance budgets" and ASSET_PIPELINE.md, with
different numbers), the asset generation steps (ASSET_PIPELINE.md, `docs/BLENDER-PIPELINE.md`, `docs/TRIPO-ANIMATE-IN-PLACE.md`), the
gear's attachment rules (inside `client/data/slice/necro_gear.json`), the quality bar (`docs/GRAVECRAWL.md`) and the model check of Phase 1
(`tools/assets/check-models.mjs`: triangle caps, one material, the shared skeleton, the combat clips). Missing: an art direction, one set of
budgets for every kind of asset, and checks for everything but models.
- [ ] **Decide + New: the look (the art direction).** Claude drafts it from today's look, the area moodboards (`docs/art/areas/`) and
  Gravecrawl's lessons, with example pictures; the team picks and approves. It sets the game's look in a paragraph, each area's palette and
  lighting mood, the colour rules (for example: enemies, heroes and the ground always differ in colour and brightness; violet for magic,
  gold for reward, red for danger; what each spell colour and loot rarity means), silhouettes that read at the game camera's distance
  (about 22 m), how shiny and how bright materials may be (Tripo's models come out metallic and white out under glow), how heroes, thralls
  and enemies are told apart (rims, glows), and the style of icons, portraits and UI frames. It gives: one page every new asset is checked
  against, and the target for the art rebuild.
- [ ] **Fix: budgets in two places, for three kinds of asset (the tech art page).** Now: ASSET_PIPELINE.md asks Tripo for a 12,000-triangle
  hero and a 14,000 boss while CLAUDE.md caps both at 20,000, the model check holds its own caps for gear, props and characters, and nothing covers
  the world. After: one table for the hero,
  bosses, crowd creatures, thrall variants, weapons and gear pieces, props, wall and floor pieces, effect meshes and UI art, each with
  triangles (a target and a hard cap), texture size, materials, bones and levels of detail, plus a budget per area (triangles in view, draw
  calls, lights); the gear's attachment rules (axes, size, grip point, anchor bone) move here from `necro_gear.json`. Starting numbers come
  from today's assets and are confirmed with the benchmark.
- [ ] **New: how one model serves Ultra, old PCs and phones (the tech art page).** Each model is made once, at its budget, and the tools
  make the lighter versions (Godot already makes levels of detail for every model, and each preset decides how soon the lighter ones show);
  Ultra adds extras on top (shadows, ambient occlusion, more particles) rather than heavier models; Low thins the effects out; phones get the
  Low preset plus a phone pack with smaller textures in phone formats (B40), and a check proves every shader and effect also runs on the
  phone renderer. It gives: Ultra keeps looking its best while Low stays above the weak-PC floors, and nothing has to be remade when phones
  come.
- [ ] **New: the balance sheet (the design page).** The power curve over levels 1 to 999 (item power by level and rarity, enemy health and
  damage by area level, XP and gold per minute, drop rates, where gold comes from and where it goes) and how hits and kills feel (sound,
  flash, number and screen shake, each with its cap). A balance tool built on the seeded fight harness plays a fight without a screen and
  reports time to kill, damage taken and XP and gold per minute, so a new item or enemy is checked against the curve before anyone plays
  it. It gives: new items and enemies fit the game without retuning everything around them.
- [ ] **New: rules for changing live content (the design page).** What happens to what players already own when content changes: an item
  id is never reused or deleted while anyone owns it, a removed item turns into something stated (gold or a replacement), a rebalance says
  whether owned items change too, and each change ships with its database migration. It gives: updates never break or silently change
  players' characters.
- [ ] **New: the writing rules and the lore bible (the writing page),** the lore written with the team alongside the rest. The voice
  (dark, with dry humour where it fits), naming patterns for items, enemies, places and rites, what a tooltip says and in what order, the
  patch-note style; and the world itself (its factions, history and places), which names, quests, bosses and the Codex then follow.
- [ ] **New: the look check and the review checklist.** A scene that shows a new model beside existing ones at the game camera's distance,
  in each area's light, on Low and on Ultra, with its triangle count, next to approved reference shots of each area. Every new visual asset
  is posted to the team with those shots and passes the checklist (the look, the budgets, the rig, the clips, readability) before it ships.

### C. Content pipelines and automatic checks

- [ ] **Fix: content is defined in several places.** Now: an enemy is defined in four places (`server/rules/content/enemies.ts`, two
  client data files and its special moves in the combat core), and an armor set touches several files and breaks tests that count items.
  After: each kind of content (enemies, items, rites, statuses, loot tables, sets, area rosters) lives in one source file, the tools write
  every other copy (client data, server rules, the server's item rows), and the build fails if a copy is out of date.
- [ ] **New: automatic checks for every new asset and content entry.** Models already get triangles, materials, the skeleton and the
  combat clips checked (Phase 1); still to add for models: texture sizes, bones, levels of detail, scale and pivot, a source and licence record. For data: required fields, ids that exist, numbers inside the
  balance sheet. They run before every push, in the Discord agent's check and in CI (the tests that pinned counts already compare the data
  with itself, B59). It gives:
  an over-budget model, a missing clip or a broken item cannot ship.
- [ ] **New: the rules reach every Claude by themselves.** CLAUDE.md, which every session reads first, points to the docs map; each recipe
  is also a Claude Code skill that loads by itself when a session is asked to do that job (sessions on the server and the Discord agent
  alike); the agent's proposals show the checklist's results (the automatic checks and the look-check shots). It gives: no session has to
  know where a rule lives to follow it.
- [ ] **Fix: the character pipeline guide is spread over three pages.** Now: ASSET_PIPELINE.md, `docs/BLENDER-PIPELINE.md` and
  `docs/TRIPO-ANIMATE-IN-PLACE.md` each hold part of the steps, and none covers the crowd bake or the look check. After: one guide for the new game from concept (the team
  approves the picture first) to Tripo model, cleanup to budget in Blender, rig, clips (Tripo's presets, the shared clip library, Blender
  recipes), build, levels of detail, crowd bake, look check and ship, each step with its tool and its check.
- [ ] **New: recipes, with their checks, for what is made today:** an armor set, an item, a sound, a tip, and a rite. Haunting Wraith
  (warbogar's Reaper ability, Discord job 565c7c, being rebuilt on the live game since 2026-10-18) is the rite recipe's first test, and the effects
  standard is written with it (how big and bright an effect may be so a fight stays readable, particle budgets per tier, reusing existing
  effects first, every new effect warmed at load, and whether the licensed effect pack's 3D scenes can be used now: KNOWN-GAPS "Assets and
  effects"). The enemy, boss and area recipes come with their first content in Phase 4.
- [ ] **New: a catalogue of what exists.** Every item, enemy, rite, area, model, animation, sound and effect with its picture and numbers,
  generated from the one home of each kind into a page the team can browse. The team and every session look there before asking for or
  making something new (reuse first). It gives: no duplicates and no paying twice for the same asset.

### D. The server owns every value (finishing B19-B26 and B32)

- [ ] **Fix: area kills and soul shards are taken on the player's word.** Now: the necromancer save sends its area kills and shards and
  the server stores them, so a cheater could hand himself shards. After: the server counts them from the kill reports it accepted, as it
  already does for XP and gold.
- [ ] **New: cheat flags reach the team.** A Discord notice when a character trips a flag, a review of the flags for honest players caught
  by mistake (a false flag holds back part of an honest player's gain), and the old audit rows cleared.
- [ ] **New: a written way to roll one character back** to an earlier save (`character_save_versions`), for when a bug or an exploit
  damages a character.

### E. Engineering health and docs

- [ ] **New: an automatic secret scan.** The repository is public and many sessions push to it, but only a scan each session runs by hand
  keeps keys and passwords out. After: every push is scanned before it leaves the server and again in CI, and one with a secret is refused.
- [x] **Fix: a document-only push runs every test.** Done 2026-10-19 (B59): each push to `main` ran all the suites (about 20 minutes), even
  when only a document changed → a push that changes only documents runs the document checks; game changes run everything, on six
  machines with the build products from the cache (about 4 minutes).
- [ ] **New: a security watch on the server's packages.** The game's server, lobby and relay use outside code packages that get security
  fixes. After: a weekly check lists packages with known holes, and they are updated on purpose, tested, like any change.
- [ ] **Fix: untyped code is allowed.** Now: GDScript without types still loads (under 1 % of the game's code), so some mistakes only
  show when a player hits them. After: Godot treats untyped code as an error, so those mistakes show the moment a test loads the game.
- [ ] **Fix: the rebuild's performance leftovers.** Now: in the biggest fight a rite's cast can take 2 to 4 ms in one frame and a big kill's
  rewards and loot 2 to 9 ms (measured on the VPS: a small hitch on a weaker PC), some code repeats work every frame, and some effects draw
  while empty. After: each one inside its budget, fixed and measured one at a time, the hitches first (KNOWN-GAPS "Performance").
- [ ] **Fix: some test suites fail at random.** Now: a few suites fail now and then under load or on timing (KNOWN-GAPS "Tools and
  tests"; the HUD suite and `qa_shots` fixed 2026-10-19), so a red CI does not always mean a real problem, and with CI as the gate (B59) a
  random failure blocks a ship. After: every suite passes every time, and red means broken.
- [ ] **Fix: leftovers from the web game.** Now: parts of the code still copy the old web game's exact math, and an asset list is kept by
  hand. After: plain Godot code and generated lists (KNOWN-GAPS "Leftovers from the web era").
- [ ] **Fix: docs too long to read.** Now: `client/README.md` is 175 KB (its comparisons with the old game are gone since 2026-10-18, but
  its measurements and details remain) and `native/README.md` 55 KB, more than a fresh Claude session can read before it starts working. After: short pages on how each system works now, with the
  history kept in git and DECISIONS.
- [ ] **New: one map of the docs:** which page holds which rule (the vision, How we work, the three standards pages, the pipelines, the
  recipes, each system), so the Discord agent and every session find the rule before they build.
- [ ] **Fix: the repository after the old game's folder went.** Now: leftovers of the two-game setup. After: each top-level folder has one stated
  purpose, nothing is left over, and README.md's layout is true.

Done when: the vision and "How we work" are agreed; three real pieces (Haunting Wraith, War's next armor set and one new item) have gone
through their recipes and the automatic checks and the look check without trouble; the look, the tech art and the design and writing
pages are written and approved; the rules reach every session by themselves; the server owns every value; and the docs a session needs
fit in one read.

## Phase 3: Ascension, redesigned (the first new feature, B36)

Built right after Phase 2, from the one-page plan written during it.
- [ ] **New: the UI standard, before Ascension's windows:** icon size, style and frame; fonts and text sizes; the rarity and danger
  colours, never shown by colour alone (for colour-blind players); and how a new window fits the HUD budget (150 draw calls, 0.5 ms).
- [ ] **New: Ascension built on the foundation:** its data in one home, Ashes owned by the server from day one, played on the test lane
  first, measured like everything else.
- [ ] **New: players' saved boons, Ashes and best rank carried into it,** as the plan decides (the rules for changing live content).

## Phase 4: new content (the look of the world, places, enemies, classes, quests)

Each kind starts by building its toolkit and writing its standard (the reusable parts, the rules and its recipe) together with its first
piece of content. Phase 4 starts when Phase 3 is done and so are the first four items of the polish list; the order below is a first guess,
set with Helix then.
- [ ] **New: the look of the world** (the art rebuild; Helix, 2026-10-16: its own plan and pipelines), following the look page. First:
  - **Decide + Fix: where big art files live.** Now: the repository holds about 520 MB of files, mostly art, and every version of every
    model stays in its history for good, so it grows with each new asset and every session's copy grows with it. After: big art files move
    out of the main history, to Git's large-file storage or to an asset store outside git (Claude brings both with their monthly cost; the
    automatic tests download the art on every run, which decides it), so the repository stays small and fast.
  - **New: the props and world-kit pipeline:** how props and wall, floor and decoration pieces are made (budgets, the same sharpness
    everywhere, shared materials so they draw cheaply, collision and walkable-area rules, lightmap layout), with the team app baking the
    lighting.
  - **New: the map pipeline:** areas built as scenes from those pieces with the lighting bake, instead of generated from the web game's map
    file (`world.json`) as now.
  Then the maps revamped. Its notes: KNOWN-GAPS "Assets and effects".
- [ ] **New: new places:** first the area rules and the area recipe (size, fighting space, landmarks, spawn points, safe spots), then new
  zones (the Hollow Court) made with the map pipeline.
- [ ] **New: new enemies and bosses.** First the rigging and animation standard (one skeleton per body type, attachment points, scale, the
  clips every kind of creature must have, attacks marked where they land, Tripo's traps), enemy roles and telegraph rules, the boss
  template (phases, telegraphs, adds, summoning key, party scaling, rewards), the enemy and boss recipes, and the enemy building blocks
  (each special move, such as the Censer's aura, the Gargoyle's dive and the Sexton's hook, is today a one-off written for its enemy; they
  become reusable parts that the data combines). Then new kinds and bosses with summoning keys.
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
  - Bosses and statuses. Done 2026-10-19: Fracture (Marrow Spear, Ivory Cleave, Bone Prison) did nothing to a boss → a boss takes 15% more
    a stack, up to 45%, like any enemy, so those rites shorten boss fights. (Sanctify is an enemy priest's blessing that makes its target
    take less; it now protects a boss too.)
- [ ] **Fix: the look pass** (moved after launch by Helix, B49). Now: blended effects (decals, telegraphs, particles) look wider and
  brighter than in the old game, most on Low and Medium; the Depths' walls are darker; the hero reads darker in bright areas (the Coliseum,
  the Cloister, the Pyre, the Wing) and brighter in dark ones; not every area is signed off. After: every preset looks like the old game or
  better, and Helix has signed off each area on their PC.
- [ ] **Fix: the Reaper is unfinished.** Now: she has her rites, a signature (R) rite and a legendary armor set with its own body, but she
  borrows the Mourner's body outside that set and other rites' icons, and has no runes. After: her own model and icons, and runes.
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
  - What a guest brings. Now: a guest cannot call an Empowered boss, and a guest's Colossus Mantle effects, Covenant Seal and Nightfall
    dimming do not reach the host's game. After: a guest's gear and choices work in the party as they do solo.
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
  every night, but onto the same server, and the raw art sources, the licensed packs and the private effect sheets exist only here, so losing
  the server would lose all of it. After: every night a copy of everything that is not in git goes to the cloud bucket, and a restore from
  it is tested.
- **New: phones.** The Mobile renderer, touch controls built with the HUD, phones join as guests. The game stays ready for them (B40:
  phone texture formats, shaders that run on Mobile, a scalable HUD) and Phase 2's quality tiers set their budgets.
- **New: 1.0, the first public release** (B52). The repository goes private and the game's files are encrypted in the build; accounts
  get an email address and password recovery (none exist today); chat gets reporting and moderation; a privacy policy and terms; a signed
  launcher and game so Windows does not warn new players; a review of the servers' capacity and of cheating; a licence check of every asset
  against how the game is offered (Tripo models, ElevenLabs sounds and music, the sound and effect packs); the test runs fitted to the paid
  minutes of a private repository (about $80 to $115 a month at the 2026-10-19 pace; first an Actions budget of $0 with "Stop usage", and the
  drafts' background CI runs off, B63); and a store or download page.
- Not planned: dedicated or VPS-hosted game sessions and host migration (the hybrid model stays, owner 2026-10-15; D6), translations, mod
  support.

## Risks we are carrying

- **One server holds everything:** the game, its database and every backup, until the cloud bucket exists (Later). Phase 1's alerts at least
  tell us when something stops.
- **Every line is written by Claude:** when usage runs out or the service is down, all building pauses. The docs, recipes and checks
  (Phase 2) make any fresh session able to continue; nothing depends on one session's memory.
- **The code is public until 1.0:** cheaters can read how the server checks them. The server owns every value (Phase 2, track D), and the code
  goes private for 1.0 (B52).
- **Licences:** the ElevenLabs plan in use excludes monetized games, and every asset's licence matters once the game is offered to the
  public. The vision decides about money (Phase 2, track A); 1.0 checks every licence.
- **No way back to the old game** (B57): problems are fixed forward or rolled back to an earlier build of the new game, so the crash
  reports, alerts and play reports (Phase 1) are how we learn about them.
- **A long foundation:** players see little new while it is built. Something players notice ships every week or two (Always on), Phase 2
  holds only the core, and Ascension follows it directly.

## Ideas

New ideas and requests from anyone land here first, one line each with its date and the section it would belong to. They wait here
until the team says yes, because every unchecked item in a phase or the polish list is treated as approved work by every session. When a
phase is planned, its ideas move into its checklist as Fix or New items (or straight away, when Helix says so). Bugs and gaps go to
KNOWN-GAPS.md instead.
- A hint for a party guest standing in a boss's rot (a guest's core lists no zones today). Section: polish list, co-op gaps. 2026-10-17.
- A results card when a session ends: what you reached, kills, gold, time, and your personal best (Gravecrawl's lesson 3,
  `docs/GRAVECRAWL.md`). Section: polish list. 2026-10-18.
- A one-click invite link: copy it, a friend clicks it, the game opens and joins the party (Gravecrawl's lesson 9). Section: polish list,
  co-op gaps. 2026-10-18.
- A check that a new player's first fight starts within seconds of entering the world (Gravecrawl's lesson 2). Section: polish list, the
  first hour. 2026-10-18.
- The party session on each drop (a column on `character_drop_events` set from the claim's session id) and the XP and gold a member earns in
  a session on its `party_session_members` row, so the play reports' server numbers get drops per hour and an exact XP and gold per
  session instead of the progress saves' time window. Section: Phase 2, track D. 2026-10-18.
- Split the Discord agent runner's `runner/core.cjs` (about 2,000 lines) by job: pictures and videos, ships, threads, so each change to it is
  smaller and its reinstall and practice run less risky. Section: Phase 2, track E. 2026-10-19.

## Done

- 2026-10-16 to 2026-10-18: **the rebuild**, a C++ combat core and Forward+ graphics under the same game (B34-B50).
- 2026-10-13 to 2026-10-15: **server authority**: the server rolls every drop, owns the bag and pays only what the kill ledger backs
  (B19-B26, B32).
- 2026-10-09: **the baseline cleanup**: one game, one branch, docs that say how things are (B1-B11).
