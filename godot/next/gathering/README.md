# godot/next/gathering: gathering and professions on the rebuild

`DmNextGather` (child `Gather` of `DmNextGame`, same path on every peer) wires the current game's gathering onto the slice. It adds no rules:
`DmGatherLoop` (walk -> work -> batch -> adopt the server's answer), `DmGathering` (timings, yields, success chance, XP curve, blockers, Auto's next node),
`DmSkills`, `DmNodeViews` (hover / selected ring, progress arc under the hero, spent look), `DmGatherSession` (AFK report) are used as they are.

## Playing it
- 64 nodes (Acre 41, Fen 9, Cloister 3, Pyre 3, Graves 2, Ossuary 2, Nave 2, Sanctum 2: `DmData.world()["nodes"]`) with the world builder's models. Hover = ring + the node card
  (needs / XP per success / spent); click = walk to the ring and work (stations and NPCs win a click over a node, as in the current game, enemies over both).
- Cycle = `ticks x 600 ms`; each cycle is rolled for feel, successes take 1 off the node's yield (host), cycles are batched to the backend (8 s / 40), which rolls the real
  finds, checks the time budget, grants items / XP / gold; the reply is adopted (skills, bag, gold, charm banner, "Found: ...", level-up banner + sound + counsel event).
- Rich nodes: 1.5 x yield, half respawn. Spent nodes show their spent look and respawn on the host's clock; Auto (setting, default on) walks to the next live node of the kind and
  waits for a respawn; Auto off stops with "The X is spent.". Refusals use the rules' words ("Requires ...", "Your bag is full.", "Nothing to gather here.", the backend's text).
- Stops: any movement / click / rite, a panel, a hit, death, a full bag. AFK in the Acre from the Skills tab (`DmNextUiHost.start_afk / stop_gathering / afk_status / afk_active`) with the report.
- Professions: the existing Skills tab (P) reads the same backend rows; stations (kiln, sawpit, fire, cauldron, grinder, shelf) craft from gathered materials through the existing panels.

## Authority and replication (REBUILD D1 / D4)
Host: loop, node yields (`_remaining`), respawn clock, backend calls (`api.gather`, `api.begin_afk_gather`, online `DmApi` or `DmOffline.make_api`: same calls). Nothing of value comes from node
state. Every peer: the depleted set, as `_rpc_state(id, live)` events + `_rpc_full` for a joiner (1 s after it joins), spent looks on each peer's builder.
A client peer has the node set and views but no loop yet (its gather intent is not forwarded to the host: its character has no backend api in the slice, see `next/README.md`).

## Cost
Idle: ~1 us per frame (10 Hz tick; the respawn check is 4 Hz and only while a node is spent); working: ~80 us per frame (per-frame only while a loop runs, for the progress arc). Picking is the current
area's nodes within 26 x 22 m of the hero at 10 Hz. No per-frame scan of nodes. Test: frame median ~7.4 ms headless while gathering.

## The Acre glue (`dm_next_acre.gd`, child `Acre` of `DmNextGame`, host with the real HUD; test `tests/next_acre_guide`)
`DmNextAcre` is the "DmGame" that two unchanged classes of the current client talk to: `DmLaborerViews` (visible Grave Laborers) and `DmGameLabor` (the labor / garden / contract notices and timers). It
exposes the few members they read (`api`, `hero_id`, `builder`, `world_root`, `settings`, `gatherer`, `chronicle`, `prog`, `toast`, `banner`, `emit_game_event`, `play_sfx`, ...).
- **Laborers.** Up to four pooled models (`skeleton_thrall` and friends, built on the first Acre visit) stand at their posts and chop / dig / fish; nothing is built, fetched or updated outside the Acre
  (`set_active(area == "acre")` from `area_changed`). Hover = card ("<skill line> · click to open the Laborers (H)") + glow, click = the Laborers panel; a laborer competes with nodes by screen distance
  with the web's 18 px bonus (`DmNextGather.pick` / `hover_at` / `click_at` ask `Acre.pick_laborer`). After the panel assigns / recalls / collects, the posts refresh 0.8 s later.
- **Notices** (`DmGameLabor`, the web's numbers): garden check 4 s after the world is ready then every 60 s, labor check 6 s then every 5 min: "Your laborers have gathered about N finds (H)" (30+ minutes of work, on
  arrival), "A laborer has filled up" (once per fill), "N plots are ready / still growing in your garden (U)". `refresh_contracts` feeds the Contracts summary.
- **Panel results** (`DmUiPanelsB` calls `on_labor_collected` / `on_garden_result` / `on_contract_delivered` when the host has them; `DmNextUiHost` forwards to `Acre`, `DmGame` forwards to its `DmGameLabor`):
  the gold of a contract / a collected laborer is credited (the server returns it and never writes it: before this the Godot panels dropped it), the chronicle counters, the finds report under the laborer, "Harvested N x ...",
  "Grave Gardening N" banner, charm banners, "Order filled" (and the day's bonus).
- **Cost:** per frame one bool test + `DmGameLabor`'s three timers, laborers update only while the hero is in the Acre (48 m animate range); headless median frame 7.2-7.3 ms with four laborers working, the same with the glue off
  (`tests/next_acre_guide`).

## Not done
- Gather bests (AFK report records) are kept per session, not stored; the chronicle counter is only fed when the progression carries one.
- Remote players do not see a gatherer's tool / gesture or the host's laborers; clients cannot start gathering (above).
- The laborer models are first built on the first Acre visit (one ~5 ms frame headless); `DmNextWarmup` does not draw them yet (rendered cost unmeasured).
