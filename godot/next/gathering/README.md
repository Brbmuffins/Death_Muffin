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

## Not done
- Laborers: the Laborers tab (H) works through the backend (assign / collect via the existing panel); the visible laborers in the Acre (`DmLaborerViews`) and `DmGameLabor`'s timers / notices are not wired.
- Garden (U) and Contracts (O) open from the Skills tab and work through the backend; their world notices (`DmGameLabor.note_garden`) are not wired.
- Gather bests (AFK report records) are kept per session, not stored; the chronicle counter is only fed when the progression carries one.
- Remote players do not see a gatherer's tool / gesture; clients cannot start gathering (above).
