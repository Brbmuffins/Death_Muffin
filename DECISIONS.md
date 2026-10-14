# Decisions

Owner decisions that shape the code. D1-D13 are the 2026-10-05 and 2026-10-07 rebuild decisions; B1-B10 the 2026-10-09 (B11: 2026-10-10)
baseline decisions; B12 the 2026-10-10 Phase B rollback, B13 the carried approval after a ship conflict, B14 how performance work is measured (and what it taught). Where a later decision overrode one, the entry says so.

## Rebuild decisions

**D1. Trust model (default).** The host's Godot game is authoritative for its session: combat, enemies, corpses, thralls,
waves, bosses. Clients send intents (move, cast, interact) as RPCs to the host. The backend stays authoritative for anything
that persists or has value: accounts, characters, inventory, gold and shards, loot rolls (server-rolled), progression saves,
and the kill ledger with its sanity caps. A cheating host can ruin its own session but cannot mint items or gold beyond what
the backend's caps accept.

**D2. Party size: 4 players** (owner, 2026-10-05). One constant, `DmSession.MAX_PLAYERS := 4`.

**D3. Connectivity (default).** Listen-server host, connected through a relay on the VPS: the lobby service lists and creates
sessions and forwards opaque packets between host and clients over WebSocket, so no port forwarding is needed. Client side is
`DmRelayPeer`, a `MultiplayerPeerExtension`, so session code is plain Godot high-level multiplayer; `ENetMultiplayerPeer` is
used for LAN and tests.

**D4. No offline edition (reversed by B1).** The local GDScript backend (`DmMockBackend`, `net/offline/`) is the dev/test
backend behind `-- --dev-offline` only.

**D5. Solo first, online in the back seat** (owner, 2026-10-05). The game is built on the session structure so online works,
and solo play is polished first. Still the working order: necromancer combat, loot and first hour before more party features.

**D6. Host quits = session ends** for everyone; each member keeps what the backend already credited. No host migration.
Hosting on the VPS (headless Godot) is a future option, not planned.

**D7. Branches.** The Godot line ships from `main`, the only branch. Old work is in `archive/*` tags; the web game is `archive/legacy-web`.

**D8. Characters.** Existing online characters carry into the Godot game unchanged (same backend). Offline characters are not carried over (B1).

**D9. Web retirement.** The three.js game is retired; its code lives in git history and tag `archive/legacy-web` only (see B2).

**D10. Online gate.** Online was staff-first, then opened to everyone (B5). The gate code (`front/dm_online_gate.gd`, the
manifest's `online` block, `set-online.sh`) stays as the emergency off switch.

**D11. Lobby = a public list of Open sessions plus Closed (invite-only) parties** (`deathmuffin-lobby`, :5192; it follows the manifest gate).
Since B18 friends join through invites and asks; the six-digit codes have no UI (the lobby still accepts them).

**D12. Party-session tables (migration 041)** are part of the backend schema.

**D13. Disconnects get a rejoin window** (not built, see KNOWN-GAPS.md). D6 still holds for the host.

## Rules the owner set during the rebuild

- **Performance first** (2026-10-05, 2026-10-02): anything added must perform; every change is measured before and after or
  it is not merged; event-driven over per-frame work; no per-frame allocations in hot paths; first-use work (shaders,
  effects, fonts) is warmed during loading, never mid-play; tests never assert wall-clock time (see below).
- **Assets: reuse first** (2026-10-05): reuse the existing audio, models, animations and VFX (the Binbun effects, the `Vfx`
  autoload, spell colours). A different effect is fine if it saves real time and performs at least as well. Generate (Tripo
  models, ElevenLabs audio, Gemini concepts) only when something needed does not exist or is unusable.
- **Polish over new content; necromancer focus; immersive but capped, not overwhelming** (2026-10-02/03).
- **Loot never vacuums** (2026-10-04): items never fly to the player; since 2026-10-12 they are picked up by a click (B15).
- **No Godot-vs-web parity target** (2026-10-05): the rebuild is Godot-idiomatic; bit-exact web simulation math was dropped.

## Baseline decisions, 2026-10-09

- **B1. Online only for players.** The game starts online by default. Offline launch is a testing flag (`-- --dev-offline`) with
  its own save; the "offline:" token is wiped on an online start.
- **B2. One game.** The web game, offline and mobile web builds, Socket.IO realtime (:5191), the old `DmGame` path, WorldSim and
  co-op code are retired. The Godot line is `main`; tag `archive/legacy-web` keeps the web game.
- **B3. Necromancer-only baseline.** Four necromancer disciplines are playable (`DmCharacterBuild.is_playable`, backend
  `MAX_DISCIPLINE_INDEX` 4). The other five are greyed out as "Coming later" and rebuilt later. Online characters of a
  non-necro discipline switch to a necro discipline. Amended 2026-10-11 (warbogar): the Reaper (class 11, family `reaper`; 10 stays the unknown-class fallback the golden fixtures use) is the first
  non-necromancer class to ship; the backend accepts classes 1-4 and 11 only, and `DmCharacterBuild.is_playable` allows the necromancer and reaper families.
- **B4. One launcher button.** Launcher 0.7.0: a single online Play/Update button; the site's play page is replaced by the
  launcher download page.
- **B5. Online open to everyone** (`set-online.sh on`); the staff gate is off.
- **B6. Repository.** No fresh repo: `Brbmuffins/Death_Muffin` is cleaned in place, because installed launchers self-update from
  its releases. Default branch `main`; old branches became `archive/*` tags.
- **B7. Rule sources live in `server/rules/`** (moved out of `src/`); `tools/build-server-rules.mjs` compiles them to the
  `.cjs` files the backend loads. Nothing live depends on a client source tree.
- **B8. Test fixtures are committed** (trimmed golden fixtures under `godot/tests/*/fixtures/`), so the suites run without the
  deleted TypeScript game.
- **B9. `deploy-release.sh` is backend plus release notes only.** The client goes out with `publish-godot-client.sh`.
- **B10. Docs: a small truthful set.** README, ROADMAP, DECISIONS, KNOWN-GAPS, CLAUDE, plus short per-system READMEs. Web-era
  docs are deleted, not bannered; they stay in git history and in tag `archive/legacy-web`.
- **B11. Tests never assert wall-clock time** (owner, 2026-10-10): timings print as `INFO perf:` lines only; FPS is judged on real hardware (F3 overlay). Deterministic counters (cold loads, node, draw-call and query counts) stay real checks.
- **B12. Performance Phase B is pulled from `main`** (owner, 2026-10-10). In combat it crashed real players' GPUs to the desktop (NVIDIA and AMD, Compatibility renderer, no trace in the log); the build before it was confirmed stable. The ground-loot icons and a bad import were ruled out. The work (shared creature materials with instance uniforms, GPU-simulated motes, prop MultiMesh, prop lights capped at 8, opt-in Mobile renderer, GPU-time resolution governor, threading options) is kept in tag `archive/perf-phase-b`. It comes back one part at a time in owner-approved test builds; creature instance uniforms are the first suspect.
- **B13. One approval carries through a ship conflict** (Helix, 2026-10-10: "a second approval is not required"). When a Discord agent ship hits a merge conflict, the runner syncs by itself and the agent resolves it; the resolved change ships on the original ✅ if it touches only the approved files, at the same or a lower tier, with no new messages in the thread (at most twice per approval). Anything else asks for a fresh ✅. Trade-off accepted: the conflict resolution is AI-written after the approval. `server/death-muffin/discord-agent/README.md` has the details.
- **B14. Performance work is measured on real PCs** (Helix, 2026-10-12). The in-game benchmark (a held offline fight in the Bell
  Sanctum plus a render breakdown) is the measuring stick on testers' PCs; changes ship to `main` as usual (the 2026-10-11/12 side test
  builds were a one-off, their script was removed). Learned on the way: Godot 4.7's separate render thread (`--render-thread separate`)
  crashes this game on its first UI frame (engine race, not fixable in game code); thinking thralls / far enemies at 30 Hz cost thralls
  half their hits for about 0.6 ms and was removed; loot on the ground was the GPU hog of big fights (a light per soul shard, a new
  material per beam): shards carry no light now and beams share one material per rarity; physics catch-up is capped at 3 steps a frame
  so an overloaded moment slows briefly instead of spiralling into a freeze.
- **B15. Loot rework: click to pick up** (owner, 2026-10-12, team thread "Loot rework" in #feedback-ideas). The Settings loot rules
  (per rarity: on the ground / auto-loot / sell for gold) are gone: Sell sold about a third of the gear (every armour piece counts as a set
  piece and 6 of 14 affixes are necromancer affixes, both protected), and auto-loot covered gear only. Now gold and soul shards go straight
  to the purse; items stay on the ground 3 minutes (was 60 s) and only a click picks one up (the hero walks there; walking over takes
  nothing). Runes go straight into the bag with a chat line and never repeat one the account owns (bag, sockets, Vault): a known rune
  becomes another of its source's pool the player lacks, or soul shards (1/2/3 by rarity) when they own the whole pool (replaced by B17:
  a rune the player has does not drop at all). Legendaries and new runes are a chat line, for the whole party in co-op. Co-op loot stays
  personal.
- **B16. Dropping gear for the party** (owner, 2026-10-12). Gear only (materials merge into stacks, runes have no instance, so neither can
  remember where it was found). A dropped piece lies on the session's ground until the session ends, then it is gone (3 min loot expiry does
  not apply). The dropper and members who were in the session when it was found may take it, only during that session; first pickup wins.
  The server owns it (`ground.cjs`, migration 043): roll-gear stamps the session and time on each piece, drop and pickup are one locked
  transaction each, a bag save cannot name a piece on the ground, and the host only relays the drawing to the members the server named.
  Up to 20 pieces per player per session. Unclaimed pieces of an ended session are deleted.
- **B17. Learned runes** (owner, 2026-10-13). A rune still drops as an item (straight into the bag, B15), but Learn in the Reliquary spends
  it and the character knows that rune for good (`character_runes`, migration 044, `backend/runes.cjs`); an empty socket of its rite takes
  it at once. A socket holds a choice, not an item: any learned rune of the rite goes in or out without touching the bag, out of combat only
  (the client's busy rule: hurt in the last 4 s, three living dead within 9 m, or a boss awake). A rune the character has (learned, bag,
  sockets, Vault) does not drop at all: no shards, no other rune (the kill ledger's shard allowance for known runes is gone); spare copies can be kept, vaulted or ground. Loadouts apply learned runes only. Rising drop
  chance: each elite in a rune-shedding ground that leaves no new rune (a duplicate counts as none) adds 5% of the base chance to the
  next (at most 3x), a new rune landing starts it over; kept per character for the session (`DmRewardsMember.rune_dry`), and the authority ceiling allows the 3x peak. Migration
  044 counts every socketed rune as learned; runes in bags and the Vault stay items to learn.
- **B18. Social window and friends** (owner, 2026-10-13: "no more copy pasting invite codes to each other"). One Social window on O with a
  Friends tab and the Party tab (F still opens Party); O was the Contracts key, Contracts keeps no key of its own (a tab of the Acre ledger, P).
  Friends are mutual (a request the other side accepts), kept by the backend (`friends.cjs`, migration 045); no "appear offline". The lobby
  shows online friends (class, level, area, party) to mutual friends only, reading each player's list from the backend with that player's own
  token, so it needs no database. Parties are Open (listed, anyone joins) or Closed (invite only; friends can ask to join). Codes were dropped
  from the UI: no more copy-pasting. In the world the game keeps one lobby socket for this, polled by a 10 Hz timer (no per-frame work).
- **B19. Server authority, Phase 0** (owner, 2026-10-13: "I don't want any important data going untrusted"). The backend no longer
  takes value it cannot back: the web-era reward routes are gone, adding an item by name and loading a client-made save are GM-mode
  only, a first progress import starts blank, and a value guard that cannot run refuses the write (503, the client retries) instead of
  saving unchecked. Release exports ignore `--dev-offline` / `--world-demo` (editor and test runs keep them). **GM mode** stays for the
  owner's and Helix's accounts (testing): an allowed account is a normal player until it switches GM mode on (Settings -> GM mode,
  `gm-mode.cjs`, migration 046); only then do the guards step aside. Every switch and every write in GM mode is logged, and its
  characters carry a GM mark on the leaderboard. The rest of the plan (server-rolled drops, intents instead of totals, enforce) is
  in ROADMAP.md.
- **B20. Server-decided drops** (owner, 2026-10-13: server authority Phase 1; "instant drops is a must"). The client no longer names what
  dropped. Each character has a drop tape per kind (kill, elite, boss, surge): one seed per event, derived from a server secret and dealt
  to the client ahead of time, so a drop still appears the instant a kill lands (`DmLoot.roll_event`). Picking it up is a claim: the server
  rolls the same event from the same seed (`server/rules/gameplay/lootRules.ts`, kept equal to `godot/rules/loot/loot.gd` by the parity
  fixture) with facts it takes from its own records where it has them, bounds the rest, spends the tape no faster than the kill ledger
  accepts kills, and grants exactly its roll once. Gear affixes come from the same tape. Gold, XP and shards are still the client's claim
  until Phase 2.
- **B21. Benchmark setups and a public run history** (owner, 2026-10-13). The benchmark lets the player pick the room, class, fight size and
  length; the room keeps its own enemy kinds and abilities (their cost is part of what is measured), but every enemy has the same health and
  damage in every room (the old Bell Sanctum average, no elites) so kills cost the same everywhere. Bell Sanctum + Gravecaller + Standard +
  Full stays the one setup that compares PCs. Every finished run is sent automatically to the backend (`benchmark_runs`) and anyone can see the
  history on the site; only staff (role admin / gm) can delete runs.
- **B22. Guests' builds come from the server** (owner, 2026-10-14: "guest's gear set bonuses don't work on co-op"; the 2026-10-13 rule
  "all player data server-side"). A host builds a party member's hero from the server's record of that member (a host-only party-session
  endpoint: level, class, stats, worn slots, boons, vows, upgrade tiers), never from what the member's client says, and reads it again when
  the member's worn gear changes. A guest's party kills are judged in the host's world as the server records it (the host character's
  level and Ascension). Audit mode never changes what a claimed drop is: past a bound it logs and rolls with the client's value up to the
  hard limits; the rising rune chance is bounded in roll order, and a guest tracks its own.
