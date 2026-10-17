# Decisions

The owner's decisions that shape the code, so nobody (person or agent) undoes one by accident. Code, READMEs and commits cite them by id
(D1, B20). Each entry says what holds now; where a later decision changed one, it says which. New decisions get the next B number.
D1-D13 are the rebuild (2026-10-05/07), B1-B11 the baseline (2026-10-09/10), B12 onward one per decision since.

## Owner rules

- **Performance first** (2026-10-02/05): every change is measured before and after; event-driven over per-frame work; no per-frame
  allocations in hot paths; first-use work (shaders, effects, fonts) is warmed during loading. How it is measured: B11, B14.
- **Assets: reuse first** (2026-10-05): reuse the existing audio, models, animations and VFX (the Binbun effects, the `Vfx` autoload,
  spell colours). Generate (Tripo, ElevenLabs, Gemini) only when nothing usable exists.
- **Polish over new content; necromancer focus; immersive but capped, not overwhelming** (2026-10-02/03).
- **Loot never vacuums** (2026-10-04): items never fly to the player; a click picks one up (B15).
- **No Godot-vs-web parity target** (2026-10-05): the game is Godot-idiomatic; the web game's exact math is not a goal.

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
- **D8. Characters.** Online characters carried into the Godot game unchanged (same backend).
- **D9. The web game is retired** (history and `archive/legacy-web` only; B2).
- **D10. Online gate.** Online is open to everyone (B5); the gate (`front/dm_online_gate.gd`, the manifest's `online` block,
  `set-online.sh`) stays as the emergency off switch.
- **D11. Lobby:** a public list of Open sessions plus Closed (invite-only) parties (`deathmuffin-lobby`, :5192). Friends join through
  invites and asks (B18); six-digit codes have no UI.
- **D12. Party-session tables** (migration 041) are part of the backend schema.
- **D13. Disconnects get a rejoin window** (not built yet: KNOWN-GAPS.md). D6 still holds for the host.

## Baseline

- **B1. Online only for players.** The game starts online; offline is a test flag (`-- --dev-offline`, its own save, ignored by release
  exports since B19).
- **B2. One game.** The web game, offline and mobile web builds, Socket.IO realtime (:5191), WorldSim and the old co-op code are retired.
- **B3. Playable classes:** the four necromancer disciplines (1-4) and the Reaper (11, family `reaper`, warbogar 2026-10-11); the other five
  are greyed out as "Coming later". The backend accepts classes 1-4 and 11 only; `DmCharacterBuild.is_playable` allows those families.
- **B4. One launcher button** (Play/Update); the site's play page is the launcher download page.
- **B5. Online is open to everyone** (`set-online.sh on`).
- **B6. The repository** `Brbmuffins/Death_Muffin` is cleaned in place (installed launchers self-update from its releases).
- **B7. Rule sources live in `server/rules/`;** `tools/build-server-rules.mjs` compiles them to the `.cjs` files the backend loads.
- **B8. Test fixtures are committed** (`godot/tests/*/fixtures/`), so the suites run on their own.
- **B9. Two release tools:** `deploy-release.sh` (backend and release notes), `publish-godot-client.sh` (the client).
- **B10. Docs are a small truthful set:** README, ROADMAP, DECISIONS, KNOWN-GAPS, CLAUDE and short per-system READMEs; old docs are deleted,
  not bannered.
- **B11. Tests never assert wall-clock time** (2026-10-10): timings print as `INFO perf:` lines; deterministic counters (cold loads, nodes,
  draw calls, queries) stay real checks.

## Performance and agents

- **B12. Performance Phase B is pulled** (2026-10-10): in combat it crashed real players' GPUs. The work is kept in tag `archive/perf-phase-b`
  and comes back one part at a time in owner-approved test builds; creature instance uniforms are the first suspect.
- **B13. One approval carries through a ship conflict** (Helix, 2026-10-10): the Discord agent resolves a merge conflict itself and ships on
  the original ✅ only if it touches the approved files at the same or a lower tier with no new thread messages (at most twice); anything
  else asks again. Details: `server/death-muffin/discord-agent/README.md`.
- **B14. Performance is measured on real PCs** (Helix, 2026-10-12) with the in-game benchmark (B21); changes ship to `main` as usual, no
  side test builds. Known limits: Godot's separate render thread crashes this game (do not use it); ground loot must not add lights or
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
  (`ground.cjs`, migration 043); the host only relays the drawing to the members the server named.
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

## Server authority (owner, 2026-10-13: "I don't want any important data going untrusted"; phases in ROADMAP.md)

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
  Godot stays; the test build is the engine checkpoint (ROADMAP Gate B), the point where Unity would be reconsidered. Everything that runs
  for every creature every tick is a C++ GDExtension core (`native/`); the rest is GDScript (`client/`, B41). Nobody on the team writes code,
  so languages are chosen on merit, not on who can edit them. Replaces the step list of the old ROADMAP "Performance" section.
- **B35. Forward+ on every PC preset** (Helix, 2026-10-16). One renderer on PC: presets turn extras on and off, never need a restart, and
  there is one look to tune. Compatibility is only the automatic fallback (`fallback_to_opengl3`, the 4.7.2 default); the Mobile renderer
  is for phones. An "Ultra Low (old PCs)" option that restarts in Compatibility is added only if laptop runs show Low on Forward+ missing
  its floor while Compatibility meets it.
- **B36. Ascension leaves on launch day** (Helix, 2026-10-16: "it needs to be completely redesigned"). The Altar, vows, heat, Ashes and
  Covenant Boons are not rebuilt. Players' saved Ascension data stays on the server untouched; the redesign, the first feature after launch
  day, decides what it becomes. Heat leaves the party list, friends list and invites; the leaderboard ranks by boss kills, then total kills,
  then level. B26's heat rules end with it.
- **B37. The live game during the rebuild** (Helix, 2026-10-16). Bug fixes, warbogar's armor sets (also checked in the rebuild) and server
  safety work only. Feature requests go to ROADMAP "After launch day"; the Discord agent says so.
- **B38. A separate test build for the rebuild** (Helix, 2026-10-16: "its a huge overhaul"; the one exception to builds going straight to
  main, B14). The rebuild's code lives on main in its own project (B41). The launcher gets a Test build switch that
  installs the test build next to the normal game and keeps it updated; it plays on a test server with copies of the team's accounts, so it
  can never touch live characters. Team only at first.
- **B39. Performance without a goal to stop at** (Helix, 2026-10-16: "i want to get as MUCH performance as possible"). No frame-rate target;
  floors only for weaker PCs; nothing ships slower than what it replaces; Gate B needs at least twice today's speed in the Full Party fight.
  Each system has a time budget and each model a size budget, checked automatically (numbers in ROADMAP). Godot stays 4.7.2 until a
  deliberate, benchmarked upgrade.
- **B40. Ready for phones, and an undo for launch day** (Helix, 2026-10-16). From day one: textures also import in phone formats (a
  separate phone pack), every shader and effect runs on the Mobile renderer, the HUD is built from movable, scalable pieces, phones join co-op
  but never host, co-op messages carry a version (PC co-op still pairs identical builds until phones exist, B28), presets assume a phone runs
  Low. For 2 weeks after launch day the last old build stays downloadable and the server keeps accepting it, so one command undoes the launch.
- **B41. The rebuild is its own Godot project** (2026-10-16, Claude's call under B34). `client/` is a separate Godot project next to the
  live `godot/`, not folders inside it: Godot loads every GDExtension in a project, so a shared project would make the live game and its
  tests load the new C++ core, and shared assets would flip import settings (phone formats, lightmap UVs) between the two. The rebuild gets
  its own copies of the assets it uses (git stores identical files once). On launch day `client/` becomes the game.
- **B42. The combat core's contract** (2026-10-16, Claude's call under B34, from a map of today's runtime). The core owns enemies,
  thralls, corpses, statuses, affixes and the spatial grid; heroes and bosses are external entities GDScript updates each tick. Rites
  stay GDScript and call the core synchronously, so a kill still resolves inside the cast as today. Per-creature work never crosses into
  GDScript during a tick (one ordered event buffer instead); timers accumulate in doubles like today's; randomness is seeded per entity.
  Godot's RVO avoidance is replaced by the core's own steering and separation: the one planned difference in feel, judged by Helix in
  the test build. Details: native/README.md "Design".
- **B43. The client layer is today's GDScript** (2026-10-16, Claude's call under B34). `client/` carries today's scripts, scenes and data at
  the same paths, so `res://` paths and class names keep working. Files that never touch a creature are copies kept identical to `godot/` by
  `tools/rebuild/sync-code.mjs` (`client/code.list`), so a live bug fix reaches the rebuild with one command. Only the files at the seams (rites,
  the director, bosses, views, the HUD's enemy reads: 55 today) are ported to the core, and the 32 files that cannot load without them wait for their seam; `client/code.lock.json` records every copy and the version
  of each port's original, and the sync tool reports a port whose original changed since, so the fix can be carried over. The per-creature systems (`enemies/`, the per-creature parts
  of `sim/`, `next/thralls`, `next/corpses`, `next/affixes`, the entity views) are not copied: the core and the crowd view replace
  them. (`next/status` is copied for the status sets of heroes and bosses, which are external entities, B42; a ported file never calls it on an enemy or a thrall.) Same game by construction: the menus, rules, network code and rites are today's code.
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
- **B46. The panels are today's, on a ported adapter** (2026-10-16, Claude's call under B43). The rebuilt client's full UI is today's `DmGameUi` and every panel as
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
  changed on both sides). What is still not today's, and the bake's colour space, are listed in client/README.md "The look against today's game" and ROADMAP "Look pass".
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
