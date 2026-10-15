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
