# Decisions

The owner's decisions that shape the code, so nobody (person or agent) undoes one by accident. Code, READMEs and commits cite them by id
(D1, B20). Each entry says what holds now; where a later decision changed one, it says which. New decisions get the next B number.
D1-D13 are the rebuild (2026-10-05/07), B1-B11 the baseline (2026-10-09/10), B12 onward one per decision since.

## Owner rules

- **Performance first** (2026-10-02/05): every change is measured before and after; event-driven over per-frame work; no per-frame
  allocations in hot paths; first-use work (shaders, effects, fonts) is warmed during loading. How it is measured: B11, B14. Performance
  may be spent on purpose (B71).
- **Assets: reuse first** (2026-10-05): reuse the existing audio, models, animations and VFX (the Binbun effects, the `Vfx` autoload,
  spell colours). Generate (Tripo, ElevenLabs, Gemini) only when nothing usable exists. Since B71 the principle is "fit the game's look".
- **Polish over new content; necromancer focus; immersive but capped, not overwhelming** (2026-10-02/03). Since B71: polish first is a
  default, the necromancer set is the current phase, and "easy to read" is the principle.

## Foundations (the rebuild)

- **D1. Trust model.** The host's Godot game runs its session (combat, enemies, corpses, thralls, waves, bosses); clients send intents
  (move, cast, interact) to the host. The backend owns everything that persists or has value: accounts, characters, inventory, gold, shards,
  loot rolls, progression and the kill ledger. A cheating host can spoil its own session but cannot mint value (B19-B26 made this hold).
- **D2. Party size: 4 players** (`DmSession.MAX_PLAYERS`).
- **D3. Connectivity.** Listen-server host through the VPS relay (the lobby lists sessions and forwards packets over WebSocket, plus the UDP lane of B31; no port
  forwarding). Client side is `DmRelayPeer` (a `MultiplayerPeerExtension`); `ENetMultiplayerPeer` for LAN and tests.
- **D4. The mock backend is for tests only** (`DmMockBackend`, `net/offline/`, behind `-- --dev-offline`; see B1).
- **D5. Solo first.** Solo play is polished before more party features; the session structure keeps online working.
- **D6. Host quits = session ends** for everyone; members keep what the backend credited. No host migration; VPS-hosted sessions are not planned.
- **D7. One branch.** Everything ships from `main`; old work is in `archive/*` tags (the web game: `archive/legacy-web`).
- **D10. Online gate.** Online is open to everyone (`set-online.sh on`); the gate (`front/dm_online_gate.gd`, the manifest's `online` block,
  `set-online.sh`) stays as the emergency off switch.
- **D11. Lobby:** a public list of Open sessions plus Closed (invite-only) parties (`deathmuffin-lobby`, :5192). Friends join through
  invites and asks (B18); six-digit codes have no UI.
- **D13. Disconnects get a rejoin window** (built 2026-10-20): a member whose connection drops (not one who left or was removed) is offered its party again for 5 minutes, also when it is Closed; the player decides, it never joins by itself, and no seat is held. D6 still holds for the host.

## Baseline

- **B1. Online only for players.** The game starts online; offline is a test flag (`-- --dev-offline`, its own save, ignored by release
  exports since B19).
- **B2. One game.** The web game, offline and mobile web builds, Socket.IO realtime (:5191), WorldSim and the old co-op code are retired.
- **B3. Playable classes:** the four necromancer disciplines (1-4) and the Reaper (11, family `reaper`, warbogar 2026-10-11); the other five
  are greyed out as "Coming later". The backend accepts classes 1-4 and 11 only; `DmCharacterBuild.is_playable` allows those families.
- **B4. One launcher button** (Play/Update); the site's play page is the launcher download page.
- **B7. Rule sources live in `server/rules/`;** `tools/build-server-rules.mjs` compiles them to the `.cjs` files the backend loads.
- **B8. Test fixtures are committed** (`client/tests/*/fixtures/`), so the suites run on their own.
- **B10. Docs are a small truthful set:** README, ROADMAP, DECISIONS, KNOWN-GAPS, AGENTS (B72) and short per-system READMEs; old docs are deleted,
  not bannered.
- **B11. Tests never assert wall-clock time** (2026-10-10): timings print as `INFO perf:` lines; deterministic counters (cold loads, nodes,
  draw calls, queries) stay real checks.

## Performance and agents

- **B12. Performance Phase B is pulled** (2026-10-10): in combat it crashed real players' GPUs. The work is kept in tag `archive/perf-phase-b`
  (creature instance uniforms and GPU-simulated particles were the suspects on the Compatibility renderer); the game is Forward+ since B49.
- **B13. One approval carries through a ship conflict** (Helix, 2026-10-10): the Discord agent resolves a merge conflict itself and ships on
  the original ✅ only if it touches the approved files at the same or a lower tier with no new thread messages (at most twice); anything
  else asks again. Details: `server/death-muffin/discord-agent/README.md`.
- **B14. Performance is measured on real PCs** (Helix, 2026-10-12) with the in-game benchmark (B21); changes ship to `main` as usual (big
  changes go through the test lane, B53). Known limits: Godot's separate render thread crashes this game (do not use it); ground loot must not add lights or
  per-item materials; physics catch-up is capped at 3 steps a frame.
- **B27. Player bug reports go to the devs, not to an agent** (owner, 2026-10-14: "so the devs can actually see what's being reported and
  worked on"). Each new report opens a #in-game-reports thread with its game log attached; the Discord agent works on one only when a dev
  @-mentions it there. The bug-fix agent that ran every 2 minutes is retired. Details: `server/death-muffin/discord-agent/README.md`.

## Loot, runes, social, benchmark

- **B15. Loot: click to pick up** (2026-10-12). No loot rules in Settings. Gold and soul shards go straight to the purse; items stay on the
  ground 3 minutes and only a click picks one up (walking over takes nothing). Runes go straight into the bag with a chat line (which runes
  can drop: B17). Legendaries and new runes are announced to the party; co-op loot is personal.
- **B16. Dropping gear for the party** (2026-10-12). Gear only. A dropped piece lies on the session's ground until the session ends; the dropper
  and members who were there when it was found may take it, first pickup wins, up to 20 per player per session. The server owns it
  (`ground.cjs`, migration 043); the host only relays the drawing to the members the server named. Any gear may be dropped; a member who may not
  take it never sees it, and the dropper gets no message about it (Helix, 2026-10-18).
- **B17. Learned runes** (2026-10-13). Learn in the Reliquary spends a rune and the character knows it for good (`runes.cjs`, migration 044);
  a socket holds a choice of learned runes, changed out of combat only. A rune the character has (learned, bag, sockets, Vault) never drops.
  Each elite in a rune ground that leaves no new rune raises the next chance by 5% of the base (at most 3x, per session); a new rune resets it.
- **B18. Social window and friends** (2026-10-13: "no more copy pasting invite codes"). One Social window (O) with Friends and Party (F) tabs.
  Friends are mutual (`friends.cjs`, migration 045). The lobby shows online friends' class, level, area and party to mutual friends only,
  reading each list from the backend with that player's own token. Parties are Open (listed) or Closed (invite only; friends can ask).
  2026-10-14 (owner): new parties are Open by default, and a player who left can rejoin a live session (backend keeps their old member row).
- **B21. Benchmark setups and a public run history** (2026-10-13). The player picks room, class, fight size and length; every enemy has the
  same health and damage in every room. Bell Sanctum + Gravecaller + Standard + Full is the setup that compares PCs. Every finished run goes to
  the backend (`benchmark_runs`) and the site shows the history; only staff can delete runs.

## Server authority (owner, 2026-10-13: "I don't want any important data going untrusted"; what is left: ROADMAP Phase 2)

- **B19. Phase 0: closed doors and GM mode.** The backend takes no value it cannot back: the web-era reward routes are gone; adding an item
  by name, loading a client-made save and naming gear to roll are GM-mode only; a guard that cannot run refuses the write (503) instead of
  saving unchecked. **GM mode** is for the owner's and Helix's accounts (testing): an allowed account is a normal player until it switches GM
  mode on (Settings, `gm-mode.cjs`, migration 046); every switch and every GM write is logged and its characters are marked on the leaderboard.
- **B20. The server decides drops** (Phase 1; "instant drops is a must"). Each character has a drop tape per kind (kill, elite, boss, surge,
  Depths floor and chest): one secret-derived seed per event, dealt ahead, so a drop appears the instant a kill lands. A pickup is a claim:
  the server rolls the same event (`lootRules.ts` = `godot/rules/loot/loot.gd`, parity fixture) with facts from its own records, bounds the
  rest, and grants exactly its roll once. Boss drops are backed by paid summons, not a rate (spamming low bosses is normal; no limit).
- **B22. Guests' builds come from the server** (2026-10-14). The host builds each member's hero from the server's record of it (level,
  class, stats, worn gear, boons, vows, upgrade tiers, rune sockets) and reads it again when its gear changes, never from what the member's
  client says. A guest's party kills are judged in the host's world as the server records it.
- **B23. Saves send gains; the server owns every gold source** (Phase 2). A save carries the XP and gold earned since the last acknowledged
  one, under a sequence number paid once; the client adopts the backend's totals. Gathering, labor, contracts and selling pay their gold on
  the server (an affixed piece sells at its affixed price).
- **B24. Every value change is on record; bosses are paid for, not rationed** (Phase 2). Every server write of gold, XP or soul shards adds a
  value-ledger row with its reason, in the write's own transaction (the record refunds and rollbacks start from). The kill ledger pays boss
  kills from paid summons first. A party session's reports are deduplicated by batch number and do not move the player's own report order.
- **B25. Only the server writes a bag** (Phase 2; "build it out the right way from the beginning"). The client never sends its bag: every
  change is a server operation that answers with the bag (claims, gathering, crafting, moving, equipping, selling, salvaging, dropping,
  learning, sorting, using a consumable). A sip leaves the shown bag at once and is replayed on top of any answer that lands before its batch.
  The whole-bag save is a GM-mode tool (tests seed bags with it).
- **B26. Heat that adds up, shown everywhere** (Phase 3; "self vows should pay"; "always show it"). A session's heat is the host's world vows;
  each player's rewards run at that heat plus their own self vows (solo: their own world and self vows). The backend caps a carried kill the
  same way from the host's record, never the report. "Heat N · Difficulty" (also "Heat 0 · Medium") shows in the friends list, invites, the
  Party window and over the HUD's party list, with "+N yours" for one's own self vows; the lobby's copy is display only.
- **B33. The launcher updates itself** (owner, 2026-10-15). From 0.9.0 the launcher reads its own `manifest.json` (served at /death-muffin/launcher/) on our server
  (`publish-launcher.sh`, from the CI-built GitHub release) and swaps its own exe (rename the running one to `.old`, move the verified
  download in, restart), only while the game is neither running nor downloading. A release reaches players only when published on the VPS;
  versions only go up. Our server instead of the GitHub API: no rate limit, a SHA-256 to check, and we choose when it goes live.
- **B34. The rebuild** (Helix, 2026-10-16; "i want the game built correctly, have a strong, scalable, simple foundation"). The client is
  rebuilt underneath as the same game: same rules, numbers and timing, differences written down, improvements proposed, never slipped in.
  Godot stays; the test build is the engine checkpoint (Gate B, B50), the point where Unity would be reconsidered. Everything that runs
  for every creature every tick is a C++ GDExtension core (`native/`); the rest is GDScript (`client/`). Nobody on the team writes code,
  so languages are chosen on merit, not on who can edit them. Replaces the step list of the old ROADMAP "Performance" section.
- **B35. Forward+ on every PC preset** (Helix, 2026-10-16). One renderer on PC: presets turn extras on and off, never need a restart, and
  there is one look to tune. Compatibility is only the automatic fallback (`fallback_to_opengl3`, the 4.7.2 default); the Mobile renderer
  is for phones. An "Ultra Low (old PCs)" option that restarts in Compatibility is added only if laptop runs show Low on Forward+ missing
  its floor while Compatibility meets it.
- **B36. Ascension leaves on launch day** (Helix, 2026-10-16: "it needs to be completely redesigned"). The Altar, vows, heat, Ashes and
  Covenant Boons are not rebuilt. Players' saved Ascension data stays on the server untouched; the redesign, the first feature after launch
  day, decides what it becomes. Heat leaves the party list, friends list and invites; the leaderboard ranks by boss kills, then total kills,
  then level. B26's heat rules end with it. Done 2026-10-20 (Helix: "hide both"): the Altar no longer opens the Ascension panel and no row
  shows Heat, behind one switch (`DmAscension.OPEN`) the redesign turns back on.
- **B38. A separate test build for the rebuild** (Helix, 2026-10-16: "its a huge overhaul"; the one exception to builds going straight to
  main, B14). The launcher gets a Test build switch that
  installs the test build next to the normal game and keeps it updated; it plays on a test server with copies of the team's accounts, so it
  can never touch live characters. Team only at first. Kept after the rebuild for big changes (B53).
- **B39. Performance without a goal to stop at** (Helix, 2026-10-16: "i want to get as MUCH performance as possible"). No frame-rate target;
  floors only for weaker PCs; performance is spent only on purpose (B71; it was "nothing ships slower than what it replaces"); Gate B needs at least twice today's speed in the Full Party fight.
  Each system has a time budget and each model a size budget, checked automatically (today's numbers in B71). Godot stays 4.7.2 until a
  deliberate, benchmarked upgrade.
- **B40. Ready for phones** (Helix, 2026-10-16). From day one: textures also import in phone formats (a
  separate phone pack), every shader and effect runs on the Mobile renderer, the HUD is built from movable, scalable pieces, phones join co-op
  but never host, co-op messages carry a version (PC co-op still pairs identical builds until phones exist, B28), presets assume a phone runs
  Low.
- **B42. The combat core's contract** (2026-10-16, Claude's call under B34, from a map of today's runtime). The core owns enemies,
  thralls, corpses, statuses, affixes and the spatial grid; heroes and bosses are external entities GDScript updates each tick. Rites
  stay GDScript and call the core synchronously, so a kill still resolves inside the cast as today. Per-creature work never crosses into
  GDScript during a tick (one ordered event buffer instead); timers accumulate in doubles like today's; randomness is seeded per entity.
  Godot's RVO avoidance is replaced by the core's own steering and separation: the one planned difference in feel, judged by Helix in
  the test build. Details: native/README.md "Design".
- **B44. Co-op on the core** (2026-10-16, Claude's call under B34 and B40). The host plays the real game on its core; a guest holds a PUPPET core that shows what the host sends (snapshots, batches,
  a baseline: native/README.md "Co-op"), and its hero is an external of the HOST's core, so enemies chase and hit it there, its casts are intents the host resolves (as today's rites already were) and
  its thralls are the host's bodies. The session, the relay peer, the rites' RPCs and the King's replication stay today's code; only the per-creature traffic is the core's. The snapshot (up to 1.7 KB) is cut
  by body ranges into packets of at most 1,300 B (`DmCore.snapshot_parts`), each applied by the guest as it arrives: the old rule of staying under the 1,392-byte packet, with nothing to reassemble and a lost part
  costing 50 ms of its bodies. The hello carries the core's wire version next to the build (B40), so even two dev builds refuse each other when the formats differ. The rebuild uses its own lobby and relay (ports
  5195 and 5196, the test backend's signing key), pinned in `DmConfig` like the API (B38); they were installed on 2026-10-16 once Helix agreed. Until the Social window comes with the panels, a party is
  made and joined by launch arguments. Kill credit is the host's, once; a guest's died events draw and credit nothing.
- **B45. Graphics presets on Forward+** (2026-10-16, Claude's call under B35 and B39). The rebuilt client keeps today's four presets and their ids (a player's saved
  setting carries over) and today's crowd caster counts, MSAA, anisotropy, resolution floors, effects quality and moon shadow numbers; what Forward+ changes: no
  prop-light count and no prop shadow range (the area's lights are baked into its lightmap and the rest are drawn in clusters), screen-space ambient occlusion on
  High and Ultra (Forward+ only), the crowd's shadow policy instead of a per-node caster budget, and FSR 1 instead of bilinear when Auto resolution lowers the 3D
  scale (sharper at no real cost). The brightness lift is Forward+'s own, one number per area calibrated against today's game (B48). The benchmark plays at the player's preset, as
  today's does, so Gate B compares like with like (`client/game/dm_graphics_preset.gd`, `client/next/perf/dm_next_perf.gd`, `client/tests/presets.gd`).
- **B46. The panels are today's, on a ported adapter** (2026-10-16, Claude's call under B34). The rebuilt client's full UI is today's `DmGameUi` and every panel as
  copies, on `DmNextUiHost` ported to the core (the host contract: character, bag, progression, settings, casts, the HUD's view-model), exactly as today's game
  composes them. The adapter takes over what the rebuild's own HUD host (`DmNextHud`) did from the core (the view-model from the core's arrays, the numbers from its
  events, the floats' caps) and the bag stays the loot node's (`DmNextLoot`), so value does not depend on the panels; `DmNextHud` retires. Chosen over keeping
  `DmNextHud` and porting the panels onto it: every panel and the panel host stay copies (a live fix reaches the rebuild by the sync), and only one file carries
  the difference. The HUD's budget (0.5 ms, 150 draw calls) holds the whole UI; measured with the benchmark's HUD on/off rounds.
- **B47. The whole world loads; the core keeps the navmesh** (2026-10-16, Claude's call under B34). The rebuilt game loads every area but the Depths at the start,
  as today's builder builds them all, and the hero starts and gets up in the Chapterhouse. The Chapterhouse node (seals, gates, waystones, the recall, stations,
  people) comes over with the areas rather than after the bosses: it is what opens the doors, so moving between areas needs it. The combat core keeps its own copy
  of the navmesh (a grid of the regions' triangles, `NavGrid`) for the per-tick "keep to the navmesh" step and the hero's moves: Godot's closest-point query walks
  every polygon of the map, which cost 7x more with every area loaded than with the Graves alone (and was most of the core's step even then). The copy follows the
  seals and doors; a sealed region is not walkable (today's query still counts it and the gate's collider stops bodies instead).
- **B48. Today's colours on Forward+** (2026-10-17, Claude's call under B35 and B45, after Helix's first test-build screenshots: a darker, purpler ground, beige pools, white glare). Today's
  Compatibility renderer reads every vertex colour as sRGB and multiplies a material's colours in sRGB, Forward+ does both in linear light. The rebuilt client matches today's look by making
  Forward+ do what Compatibility does where it shows (the pools' and the particles' vertex colours as sRGB, the effects' shader colours converted, the floors' and walls' tints lifted by the
  measured ratio of their textures) and by an exposure lift calibrated per area (the bake carries each area's light differently, so no one number fits all twelve) instead of retuning each light, so the lights keep today's numbers (a fix that stays right when a light is
  changed on both sides). What is still not today's, and the bake's colour space, are listed in client/README.md "The look against today's game"; the look pass is on the ROADMAP's polish list (B50).
- **B49. Launch day** (Helix, 2026-10-18: "launch", twice, the second time after hearing that the look pass, Gate D, was not done). `client/` is the
  game: its endpoints are the live server's (`net/dm_config.gd`; B38 turned round, the build never reaches the test server), `publish-godot-client.sh`
  exports it by default, and the test channel keeps its last test build. The look pass's two open items (effects on Low and Medium, Helix's sign-off
  of every area) moved to the ROADMAP's polish list (B50). The Discord agent ships `client/`. The old game's code went on the same day (B57).
- **B50. The roadmap after launch** (Helix, 2026-10-18: "building systems, frameworks, pipelines, code upgrades, rules/guidelines/standards/requirements,
  organization, updated documentation now and then working on lore, classes, quests, maps later ... you structure this project"; the structure is
  Claude's call). ROADMAP.md runs one phase at a time (settle the launch, foundation, Ascension redesigned, new content) beside always-on work:
  bugs and crashes first, the team's requests through the Discord agent as before, and a polish list. A bigger new feature goes to ROADMAP
  "Ideas" until its phase is planned; a bug or gap goes to KNOWN-GAPS.md. Each kind of new content gets its toolkit (reusable parts and a recipe)
  together with its first content, not before (no speculative abstraction). The performance budgets are in B71.
  The same day Helix asked for content standards and a clearer list ("hard to determine what is being listed as something that needs to be
  fixed or something that needs to be added"): every ROADMAP item says whether it is a Fix (what happens now, what it will be after), New
  (what it gives) or Decide (the question and Claude's recommendation), and Phase 2 starts with the content standards (the art direction,
  one budget table per asset type and quality tier, rigging, animation, effects, audio, UI, writing and lore, the design rules, the look
  check), because new content stays cohesive and runs on every PC only if those rules exist before it. Asked whether that is everything
  needed for every session to build the team's ideas consistently, the roadmap gained the layer above the standards (the game vision, who
  decides what, a one-page spec for every feature, a playtest routine), the rules reaching every session by themselves (CLAUDE.md, recipes
  as Claude Code skills), a catalogue of what exists, rules for changing live content, and Phase 1's alerts and off-site backups.
  A full review the same day added team lanes with "in progress" marks and a plain-words team guide, an automatic secret scan, test
  runs that skip the game suites for document-only pushes, a watch on the server's packages, the Ultra Low decision of B35, the move of the
  31 system guides before the old game's code goes, the remaining co-op and first-hour gaps, and a list of the risks we carry.
  The rebuild's record, which the ROADMAP held as checklists (git keeps them): Gate A (the old game on Forward+ runs on Helix's PC) passed
  2026-10-16. Gate B, the engine checkpoint: the Full Party fight in the Hollow Graves at 3.1 times the old game's speed on Helix's PC
  (RTX 4070 SUPER, 1440p Ultra: 77 to 242 fps, p95 18.1 to 5.1 ms) and 4.6 times in the VPS processor test (14.9 to 3.2 ms a frame), the rule
  tests and the seeded scenario comparison inside their tolerances (native/README.md "Proof of same game"). Gate C: every rule test holds,
  Helix's playtest found no issue against the old game, nothing slower (the Bell Sanctum's Full Party on Helix's PC: Low 594, High 343, Ultra
  224 fps against the old game's 61 on Ultra; warbogar's PC, i7-8700K and Arc B580 at 1080p High: 342 fps against the old game's 41 in the
  lighter Standard fight), co-op on two real PCs (Helix and warbogar, 2026-10-18). The old HUD was about 550 of the old game's 800 draw calls;
  the new one 117 to 120 and 0.07 ms on Helix's PC. Open at launch: a weaker PC's benchmark (ROADMAP Phase 1, play reports) and Gate D, the
  look pass (ROADMAP polish list).
- **B51. Off-site backups: a cloud storage bucket, later** (Helix, 2026-10-18: "we will eventually use a cloud storage bucket but it will be
  later"). Until it exists the nightly database dumps stay on the VPS with the art sources and private files (KNOWN-GAPS "Operations"); the
  item is under ROADMAP "Later".
- **B52. Public code until 1.0** (Helix, 2026-10-18: "Public code for now. private and encryption for our first public release 1.0 build").
  The GitHub repository stays public (secrets never go in it, AGENTS.md); for 1.0, the first public release, it goes private and the build
  encrypts the game's files (the encryption left open since authority Phase 0, B19). Until then encryption is not worked on: with the code
  public it would hide nothing.
- **B53. A test lane for big changes** (Helix, 2026-10-18: "Lets do a test lane as well"). B38's test build becomes the rule for big
  changes (Ascension, a new class, the map revamp): they go to the launcher's test channel and the test server first and the team plays
  them there; small fixes and everyday requests still go straight to main and live (B14). A test build reaches only the test server and
  the live build only the live one.
- **B54. The team PC helper, for the team's accounts only** (Helix, 2026-10-18: "Lets move forward with it but only allow War, muffins and
  helix accounts access to the feature on the launcher"; Helix holds the owner's authority for the project). It lives in its own team app,
  not the launcher (B55). A helper
  that runs jobs needing a real graphics card on team PCs: screenshots of proposals, benchmarks, the stutter test, a release crash check and
  lighting bakes (ROADMAP Phase 1). Only the accounts of brbmuffins, Helix and warbogar can use it: they sign in to it in the launcher and
  the server's job routes accept only those accounts (a list on the server), so hiding the option is not the protection. It asks before a
  job and runs by itself after 5 minutes without an answer, but never while Death Muffin or another full-screen game or movie is running or
  a laptop is on battery; it runs only builds and kits the server made, plays offline in its own folder, and uploads only results. Keys,
  passwords and anything that changes the live game stay on the server. A launcher release reaches every player, so it ships after tests
  and Helix's final OK.
- **B55. The team PC helper is its own team app** (2026-10-18, Claude's call, Helix agreed: "yes make all those changes"). Not inside the
  players' launcher: a launcher bug reaches every player and launchers only update forward (a broken updater means reinstalling by hand),
  while a small separate app with the launcher's look and its own updates is installed only on the three team PCs, can be fixed in minutes
  and puts no team-only code in front of players. B54's rules hold for it. It starts with screenshots; benchmarks, the stutter test, the
  release crash check and lighting bakes are added each when needed.
- **B56. A slimmer foundation, standards when their content arrives** (2026-10-18, Claude's review of the roadmap, Helix agreed). The
  roadmap had close to 50 setup items before players saw much new; small projects stall in that gap. Phase 2 holds only the core: the game
  vision, one "How we work" page (who decides, lanes and in-progress marks, one-page plans, playtests, done means done, the team guide), the
  look, one budget table with the quality tiers, the balance sheet and the rules for changing live content, the writing rules and lore,
  content data in one place with automatic checks, recipes for what is made today, the rules reaching every session, the server owning
  every value, and engineering health; it is done when three real pieces of content went through it cleanly. Every other standard is
  written with its first content (effects with Haunting Wraith, UI before Ascension's windows, rigging, animation, enemy, boss and area rules
  with the first new creature, boss and place, the world-kit pipeline and art storage with the art rebuild), in three standards pages
  instead of eleven. Phase 1 was ordered around 2026-11-01 (B57 dropped the date). Ascension's plan is written
  during Phase 2 so it is built right after. Something players notice ships every week or two, and the play reports also say how often and
  how long people play and where they stop.
- **B57. The old game goes as soon as possible** (Helix, 2026-10-18: "nov 1 is irrelevent. we can do these things asap. no need ot wait.
  the currentl ive build is solid"). The two-week launch undo window planned with B40 ends early: Phase 1 runs as soon as possible, and the old game's code, its
  last build, `launch-undo.sh` and the server paths only it used go as soon as the Discord agent and the tools work on `client/` (the system
  guides move first). An archive tag keeps the old game's source; from then on a rollback goes to an earlier build of the new game. Done on
  2026-10-18: tag `archive/old-game`.
- **B58. The team app gets every job that needs a real graphics card, now** (Helix, 2026-10-19: "all", "and add them now"). Besides the
  screenshots and release benchmarks: short clips of a change, before and after pictures, the stutter test, a release crash check, a
  fresh-install check, the screen sizes and UI scales, every graphics card maker the team has, a 30-minute soak test and model previews,
  all in Phase 1 (ROADMAP "New: the team app", in that order), built one after another once app 0.2.0 has landed. Every job asks the same
  way (the box and the PC's mode), benchmarks included. Claude's recommendation was the same list with the screen sizes and the soak
  test in Phase 2; Helix wanted them now.
- **B59. One setup, and CI as the one gate, for sessions and the Discord agent alike** (Helix, 2026-10-19: "the way we do testing for
  sessions and discord agents is a mess", then "start"; Claude's design). Every checkout (a session's worktree, an agent job, a CI machine,
  a publish) gets the combat core, Godot's import, the crowd's bakes and the lobby's packages from one setup, `tools/check/prep.sh`, through
  one cache keyed by what each is made of; nothing made from uncommitted files or inside the agent's sandbox is stored. CI runs every suite
  on every branch push, split over six machines, and a run on `main` is never cancelled. A change is merged, deployed or published only once
  CI passed its exact files (`tools/check/ci.sh`); the VPS runs single suites while working, and the full set only when GitHub is down.
  Approvals that wait for a ship still go out together: they merge as one tree that CI tests once. Tests compare the game's data with
  itself, never typed totals or tuning values (a spell War added broke a count; a typed spell speed broke War's faster Haunting Wraith). Replaces the morning's rule (444da1ad: wait about 20 minutes for CI with a
  local quick check beside it) and the agent's own preparation and cache. On 2026-10-20 (Helix: "scan ALL tests for issues like this and fix them", after the Haunting Wraith's one-cast clip broke when War removed its cooldown) every game suite and every server test was audited: typed totals and tuning values are read from the data, and a scenario that only holds for today's numbers derives its expectation from the data or sets the number itself (`DmQaTune.apply`); what the game still keeps as inline literals is listed in KNOWN-GAPS.
- **B60. A Windows release build ends its own process after the game's shutdown** (Claude, 2026-10-19, with Helix's crash files). The
  release engine's last teardown crashes on Windows after every quit, the benchmark's and a player's alike (0xC0000374 heap corruption or
  0xC0000005 at the same engine code; the debug engine with the same pack, art and combat core closes cleanly; KNOWN-GAPS "Stability"). Once
  the game's own shutdown has run (saves, the play report, the party left, the crash lock removed), `DmMain.end_process` ends the process
  (`OS.kill` on itself, exit code 0) instead of `quit()`. A debug build, Linux, and any exit code that is not 0 keep the engine's teardown, so
  leak reports and the tests still see it. Revisit when Godot is upgraded or the cause is found.
- **B61. A team PC starts every release before players get it, when one is free** (Claude, 2026-10-19; ROADMAP Phase 1, the team app: "a
  crash should stop the release"). The server's boot test runs the Linux build, so nothing checked that the Windows build starts before
  players had it. Now the publish, after its boot test and before the switch, asks the team app for one short job any free team PC may take:
  start this build's own files to the first screen and quit one while it loads (about 10 seconds; `team-gate.sh`). If the game fails there
  (does not start, stops with an error, or leaves a crash report) the build is not published, and the publish says why. If no PC is free
  (off, paused, in a game, on battery, or busy with a release check), none takes it within 2.5 minutes, or the PC gives up for its own reasons
  (a download, the player starting the game), the release goes out as before. Releases are never held hostage by a PC being off; the cost
  is at most about 3 minutes a release, usually seconds.
- **B62. The team PCs check a change before it goes live, when its shipper asks, never after** (Helix, 2026-10-19: "we do not need to be
  running release checks every time we push something to live... we use it before we push something to live"; then "go, no waiting for
  checks"). Replaces B58's release checks after every client release (a 40-minute job on each team PC, posted to #build-alerts), which
  held the PC after each release and reported after players already had the build. Now `team-check.sh` builds a revision (its release
  build through the publish's own steps, publishing nothing, and its debug build), runs the steps its shipper picks on a team PC (with
  `--compare` the live build first on the same PC, so the numbers read live build -> this change) and writes a summary and contact sheets
  for whoever asked; a session posts them to a new thread or a DM after asking the person which. The Discord agent does not run them during its 🧪 and ✅ tests (planned as silent tests on 2026-10-19; Helix, 2026-10-20: "no to the team app tests"). Approving a change never waits for them;
  the publish's 14-second check (B61) is the one automatic check, and it runs before the switch. #build-alerts gets release notices and
  server alerts only.
- **B63. Discord agent proposals are drafts; the tests run when someone asks or ships, and the next big change cannot break testing unnoticed**
  (Helix, 2026-10-19: "we need to make sure the discord agent and tests dont break again the next time we make a test build and push it to
  live", "if i have to wait for tests to run between every single itteration its going to take forever", then "start"; Claude's design).
  Replaces B59's "a proposal waits for CI". A round of back and forth is proposed at once, marked "Not tested yet", with three reactions: ✅
  tests it and ships it, 🧪 (or `!test`) runs every test without shipping, ❌ discards it after asking once (one tap could throw away hours of
  work). Every push still starts CI in the background, so ✅ and 🧪 often find the answer waiting. Nothing untested ships: the ship waits for CI
  on exactly what goes live (B59), and when those tests fail the agent fixes it and a tested proposal comes back for one more ✅ (a fix made to
  pass a test can change how something plays, so someone sees it first). Without the CI gate (GitHub down) every proposal is tested first, as
  before. So that a promoted test build (B53) or a reinstall cannot break testing or the agent unnoticed (the 2026-10-18 launch did both): CI
  fails when a suite file is missing from the suite list, when a path the agent's rules name no longer exists, or when a workflow asks for a
  paid or self-hosted machine; the agent's own tests run in CI; an expired GitHub token falls back to the slower limit, and the nightly
  drift report warns two weeks before it expires; and after every reinstall and every test build that goes live, the agent's practice run
  (`runner/canary.cjs`) takes a harmless change through the whole path with a fake Discord before the agent takes requests.
- **B64. Videos are scripted with the game's own words, never with code** (Helix, 2026-10-19: "we will need a LOT more clip options or allow custom
  requests", then "start"; Claude's design). A clip may carry `setup` (the scene before recording) and `steps` (what happens when), lists of words
  with arguments defined by the game in `client/main/qa_clip_steps.json`; the recorder carries them out and the Discord agent's runner checks a
  request against the branch's own copy of that list. A new kind of video is a game change the agent can make itself (the word, its handler, a
  test), reviewed like any change, and usable in that change's videos at once; the runner needs no change. Free-form scripts were turned down: a
  script can do anything a program can on the team PC that records it, a word only what the recorder allows. Also from Helix the same evening
  ("@ war its his thread"): a proposal tags the person who started the thread, not whoever asked last.
- **B65. The Discord agent makes its own generated files; commands inside its sandbox are Claude's call** (Helix, 2026-10-19: "okay go with
  that then", after Claude's recommendation). An armor set or any rule change needs three generators (the armor-set assets, the server rule
  bundles, the loot rules' recorded answers), and the agent could run none of them, so a set from a thread stopped halfway until a session
  ran them. The agent now runs `regen-godot.sh`, all three in the same sandbox as its tests (no network, no keys, only its own copy writable),
  and CI fails any change whose generated files are not exactly the generators' output. The sandbox is the boundary, and the agent already runs
  any code inside it through the tests it writes, so a new command inside it adds no reach: such commands are Claude's call from now on. Anything
  that reaches past the sandbox (deploying, publishing, pushing, spending, keys, the network, who may approve) still needs Helix.
- **B66. A proposal gets as few pictures as show the change** (Helix, 2026-10-20: "why is the discord agent calling for before and after and low
  and high quality screenshots when really sometimes only 1 high quality screenshot is required?", then "yes build it"). Every team PC picture
  job used to render each shot four times: the unchanged game and the change, each on Low and Ultra. Now a shot is one AFTER picture on Ultra.
  The agent's shot plan asks for more only when it helps: `"before": true` for BEFORE and AFTER pairs when the change reworks something that
  already exists and the difference is easy to miss, and `"presets"` with Low for lights, shadows and effects that Low thins out. Anyone in the
  thread can ask for them, also in words after `!shot`. The unchanged game is built only when BEFORE is asked for, so most picture jobs are
  quicker too.
- **B67. The Depths stay solo** (Helix, 2026-10-20: "solo only"). A Depths run is for one player: the stair turns a party away and says why,
  and a party descending together is not planned. Settles the co-op gaps' Depths question (ROADMAP polish list).
- **B68. A party guest may wake a boss the host has opened** (Helix, 2026-10-20: "option A"). In a party, a guest may wake the boss of any
  area open in the host's world, even one its own account has not opened, and pays for it itself: its own soul shards, or its own Covenant
  Seal and gold for an Empowered call. The server judges the summon in the host's world only for a live party the guest is an active member
  of (`party-sessions.cjs partyHostOf`); the guest's own seals stay as they are, and outside a party nothing changes.
- **B69. The first goal after the Hollow Graves is the Gravedigger King** (Helix, 2026-10-20: "go with your rec"). Right after entering the
  Graves the Next-step line said "Ossuary seal: 0/300 kills", a steep first goal. Until the Gravedigger King has been beaten, the Next-step
  box and the Prior's advice lead to him first: gather his 2 soul shards, then summon him at the King's Grave; the Ossuary seal comes after
  he falls. Only the order changes (his shard hint is priority 65, above the seal's 60; a boss whose shards are in hand stays 86).
- **B70. Every flat picture is a kind, and the Discord agent puts pictures in the game itself** (Helix, 2026-10-20: "maybe in the future
  the agent will be asked to do a lot more than just an ability icon", then "build it"). War asked for unique Reaper icons; the agent made
  concepts but could not shrink or install them (UI art was copied by hand) and the images were lost when the round shipped. Now
  `tools/pictures/kinds.json` lists each kind of picture (folder, size, size limit, import, tiling, style pictures, prompt recipe) and
  `tools/pictures/build.mjs` turns a concept into one; a new kind is one entry, not a new tool. The agent runs it through `build-picture.sh`
  in its sandbox (no keys, no network, no spend: Claude's call under B65); picking a concept needs no ✅, the proposal is the review. A
  concept naming a kind gets the kind's recipe and style pictures, so new art matches the old. The runner keeps every concept a thread was
  shown and puts it back in each later round (14 days after the thread goes quiet they are deleted). The HUD's second copy of 92 pictures
  (`client/assets/game/art`) is gone: one copy each, in `client/assets/ui_art`. Effect sprites are not a kind yet (ROADMAP Ideas).
- **B71. Owner principles are principles, not laws** (Helix, 2026-10-21: "its a principal.. not a hard law with explicit details"). The rules
  file (AGENTS.md since B72) keeps four short principles (performance first, smooth on weaker PCs, easy to read, fit the game's look) and, apart, the firm safety rules
  (the backend owns value, old clients keep running, propose-then-approve, spending limits from the owner). Performance can be spent on
  purpose: a visual upgrade the team approves may make the game slower, with its cost measured and known; slowdowns nobody meant to cause are
  fixed (this replaces B39's "nothing ships slower than what it replaces"). Polish before new content is a default when Claude picks the
  work, not a rule against requests; the four necromancer disciplines and the Reaper are the current phase (ROADMAP), not a principle. Loot
  never vacuums is the B15 feature and loot item ids are held by a unit test, so neither is a principle any more. Today's performance
  targets (they can change as the game grows; each has an automatic check or gets one in ROADMAP Phase 2): a 2020-era laptop at Low never
  below 60 fps in normal play or 45 in the biggest fight; a GTX 970-class PC at Medium never below 60 in the biggest fight. The biggest fight
  is the benchmark's Full Party fight (4 necromancers with about 32 thralls, 72 enemies and a boss, all run by the host). In the headless
  Full Party fight on the VPS (the stand-in for a weaker processor) the combat core takes at most 4 ms a tick and the rest of the main thread
  4 ms a frame; the HUD at most 0.5 ms and 150 draw calls on Helix's PC. Crowd models at most 5,000 triangles (the Bone Colossus 6,000) and
  1024-pixel textures with levels of detail; the hero and bosses at most 20,000 and 2048. Godot stays 4.7.2 until a deliberate, benchmarked
  upgrade.
- **B72. AGENTS.md is the rules' one source; CLAUDE.md imports it** (Helix, 2026-10-21, after Codex's plan reviews). Codex reads `AGENTS.md`
  directly, as bytes and with no imports, and Claude Code reads `CLAUDE.md`, which is now one `@AGENTS.md` line (plus a comment Claude never
  sees). Before, `CLAUDE.md` was the source and `AGENTS.md` a generated copy (Stage 3). Kept as a one-line import rather than deleting
  `CLAUDE.md` (Claude reads `AGENTS.md` natively only when no `CLAUDE.md` exists, depending on version and settings) or a symlink (Windows
  checkouts; edits refuse to go through it). Probed before building: the import loads at start and on a nested load, comments are removed from
  the imported file too, and `--restricted` (the agent) loads neither file. `sync-instructions.mjs --check` keeps the shape; the rule check
  measures each audience on the text it receives; `usage.mjs` counts the rules as arrived only from the source or from a `CLAUDE.md` whose own
  text held them. The global `~/.codex/AGENTS.md` pointer was left out (a Codex setting, its own decision).
- **B32. Enforce on; saves are gains only; migrations tracked** (owner, 2026-10-15, after the architecture audit). Live runs
  `AUTHORITY_KILLS=enforce` and `AUTHORITY_MODE=enforce`: a save pays only the XP and gold the kill ledger and the per-minute ceilings back,
  and stat raises by save are refused. `save-progress` without `gains` (clients before B23) answers 426 "out of date" instead of taking
  totals. Backend migrations are recorded in `schema_migrations` and applied by `migrate.sh` (deploy-release.sh runs it; 001-054 baselined),
  and a backend or lobby deploy that fails after installing rolls itself back.
- **B28. Updating while people play** (owner, 2026-10-15). A player keeps the build they started until they restart it from the launcher, so
  every release goes live next to older running clients. Co-op: release builds only party with the same build (`DmSession.PROTOCOL` 2: the
  hello carries `DmBuild.version()`; the host refuses a different release build and the reason says which side is behind and to restart from
  the launcher; dev builds skip the check). A running release build reads the client manifest a minute after loading and every 5 minutes
  (`DmUpdateCheck`) and shows one toast per newer build right away, even mid-fight (owner: "alert about a new update mid fight"). Each backend deploy must keep accepting what the previous client
  sends: add routes and fields freely, but remove or tighten one only a release after the client stopped using it. The lobby restarts only
  when no party is running (`deploy-lobby.sh`).
- **B29. Crashes report themselves** (owner, 2026-10-15). A release build writes `user://session.lock` at start and removes it on a normal
  shutdown (`DmCrashWatch`). A lock left at the next start means the last run never shut down (crash, killed freeze, PC off); that run's log
  tail is sent once the player is in an online world, as a bug report (`context.crash = true`, message "Automatic crash report ..."), which
  opens an #in-game-reports thread like any report, and the player gets a toast saying so. Built in-house rather than Sentry: no account,
  and the reports land where the devs already look.
- **B30. Two packs, so updates are small** (owner, 2026-10-15). `DeathMuffin.pck` holds code, data and UI (~14 MB) and changes every
  release; `DeathMuffin.assets.pck` holds `res://assets` (art, models, audio, ~264 MB), loaded first by the `Packs` autoload
  (`main/dm_packs.gd`). Godot's export is not byte-reproducible, so the publish reuses the last assets pack while a fingerprint of everything
  that goes into it is unchanged; the launcher then sees the same SHA-256 and copies it from the installed build. The assets pack carries no
  project files (`tools/godot/pck_extract.py` keeps only assets and their imported files), so an old one never overrides newer code.
- **B31. Co-op over UDP when it can** (owner, 2026-10-15: "our own UDP relay"). Next to the lobby WebSocket, each member opens an ENet lane
  to our relay (`deathmuffin-relay`, UDP 5193; `godot/net/relay/dm_udp_relay.gd`) with a ticket from the lobby, so unreliable packets
  (movement) are really unreliable and a lost packet no longer stalls the rest. Same star through our server: players never see each other's
  address (the server's own address is visible to players' games, the website stays behind Cloudflare). Each direction switches with a
  marker on the WebSocket, so reliable packets stay in order; a lane that fails or drops falls back to the WebSocket. The lobby stays the
  source of truth for membership. Chosen over WebRTC peer-to-peer (no third-party plugin, no shared IPs, one port).
