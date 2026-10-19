# client/next/gathering: gathering and professions

`DmNextGather` (child `Gather` of `DmNextGame`, same path on every peer) wires gathering into DmNextGame. It adds no rules:
`DmGatherLoop` (walk -> work -> batch -> adopt the server's answer; the batch the loop has not sent yet goes with the game's `flush_all` when the player leaves or closes the window), `DmGathering` (timings, yields, success chance, XP curve, blockers, Auto's next node),
`DmSkills`, `DmNodeViews` (hover / selected ring, progress arc under the hero, spent look), `DmGatherSession` (AFK report) (all in `client/game/`) are used as they are.
How it plays on the area scenes (a cycle, the server call and its refusals, the stops, AFK, the Acre's panels and notices, the laborers, cost and gaps) is client/README.md "Gathering and the Acre"; this guide keeps the numbers of the world and who owns what.

## Playing it
- 68 nodes (Acre 45, Fen 9, Cloister 3, Pyre 3, Graves 2, Ossuary 2, Nave 2, Sanctum 2: `DmData.world()["nodes"]`), props of the area scenes (group `GatherNodes`). Hover = ring + the node card
  (needs / XP per success / spent); click = walk to the ring and work (stations and NPCs win a click over a node, enemies over both).
- Rich nodes: 1.5 x yield, half respawn. Auto (setting, default on) walks to the next live node of the kind and waits for a respawn; Auto off stops with "The X is spent.". Refusals use the rules' words ("Requires ...", "Your bag is full.", "Nothing to gather here.", the backend's text).
- Professions: the Skills tab (P) reads the same backend rows; stations (kiln, sawpit, fire, cauldron, grinder, shelf) craft from gathered materials through the existing panels. The best AFK session of each skill is kept in the counsel store.

## Authority and replication (DECISIONS.md D1 / D4)
Host: loop, node yields (`_remaining`), respawn clock, backend calls (`api.gather`, `api.begin_afk_gather`, online `DmApi` or `DmOffline.make_api`: same calls). Nothing of value comes from node
state. Every peer: the depleted set, as `_rpc_state(id, live)` events + `_rpc_full` for a joiner (1 s after it joins), spent looks on each peer's world.
A client peer has the node set and views but no loop (its character has no backend api on the host): it cannot gather.

## The Acre glue (`dm_next_acre.gd`, child `Acre` of `DmNextGame`, host with the real HUD)
`DmNextAcre` is the host object that two classes from `client/game/` talk to: `DmLaborerViews` (visible Grave Laborers, at most four pooled models, views and not bodies of the core) and `DmGameLabor` (the labor / garden / contract notices and timers). It exposes the few members they read
(`api`, `hero_id`, `builder`, `world_root`, `settings`, `gatherer`, `chronicle`, `prog`, `toast`, `banner`, `emit_game_event`, `play_sfx`, ...); `builder` is the world's lights-only builder, where the old game had its full one.
Nothing is built, fetched or updated outside the Acre (`set_active(area == "acre")` from `area_changed`); `DmUiPanelsB` calls `on_labor_collected` / `on_garden_result` / `on_contract_delivered` when the host has them and `DmNextUiHost` forwards to `Acre`.

## Tests
`client/tests/gathering.gd` (all 68 nodes hovered and clicked, a node worked through the server, the stops, AFK and its report, the laborers, the garden, a contract, the Sexton's guidance feeds, the idle cost of the Gather node and the glue); `client/tests/coop.gd` checks that a node the host spends is spent on the guest.

## Known gaps
- Remote players do not see a gatherer's tool / gesture or the host's laborers; clients cannot start gathering (above).
- The laborer models are first built on the first Acre visit; `DmNextWarmup` does not draw them yet (rendered cost unmeasured). A node's spent look is built at run time and lit by the real-time light, not the bake; never looked at on a GPU.
