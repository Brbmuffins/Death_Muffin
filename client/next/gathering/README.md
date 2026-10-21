# client/next/gathering: gathering and professions

`DmNextGather` (child `Gather` of `DmNextGame`, same path on every peer) wires gathering into DmNextGame. It adds no rules:
`DmGatherLoop` (walk -> work -> batch -> adopt the server's answer; the batch the loop has not sent yet goes with the game's `flush_all` when the player leaves, logs out, switches character or closes the window: first, before the Chronicle that counts its finds is saved, and it waits for a batch still out and sends what queued behind it), `DmGathering` (timings, yields, success chance, XP curve, blockers, Auto's next node),
`DmSkills`, `DmNodeViews` (hover / selected ring, progress arc under the hero, spent look), `DmGatherSession` (AFK report) (all in `client/game/`) are used as they are.
How it plays on the area scenes (a cycle, the server call and its refusals, the stops, AFK, the Acre's panels and notices, the laborers, cost and gaps) is "Gathering and the Acre" below; this guide also keeps the numbers of the world and who owns what.

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

## Gathering and the Acre

Gathering (the nodes of the world, the professions, AFK) and the Acre (the Grave Laborers, the garden, the Sexton's contracts) on the game scene (`next/gathering/`; the loop, the rules and the panels are `game/dm_gather_loop.gd`, `rules/gathering/` and `ui/`):

| piece | here |
|---|---|
| the nodes | the 68 of `world.json` are props of the area scenes (group `GatherNodes`, one holder named by the node's id, placed and turned as the data says). `DmNextWorld` hands the lights-only builder their holders (`node_views`) and each area's root (`area_nodes`), the two members the copied `DmNodeViews` reads. It swaps a node between its live look (the scene's prop) and its spent look (the pipeline's spent model, built the first time a node is spent, or the stand-in), draws the hover and selected rings and the progress arc under the hero, and makes a rich node a little bigger with a glow disc |
| the Gather node | `DmNextGather` (child `Gather` of `DmNextGame` on every peer at the same path, made right after the session starts so a guest has it before its relay hold is released). The host runs the loop for its own hero, owns each node's yield (`1.5 x` for a rich node) and respawn clock (half for a rich node) and credits through the backend; every peer holds the spent set, replicated as the host's RPCs (`_rpc_state`, and `_rpc_full` for a joiner) |
| hover, click | `DmNextInput` asks the node 10 times a second (`hover_at`) unless a station or a person is under the cursor; a click that is not on a drop, an enemy, a station or a person walks to the node (`click_at`). Cost: the nodes of the current area within 26 x 22 m of the hero, about 0.1 ms a pick; nothing is built by hovering |
| a cycle | `ticks x 600 ms` (the node's `ticks`; 2.4 s for a first-tier node). The client rolls each cycle for feel (the gesture, the floating XP, the sound); a success takes one off the node's yield; at none the node is spent (its model swaps, the card says "Spent. It will return soon.") and Auto (the Settings toggle, on by default) walks to the next live node of its kind or waits beside it for the respawn; Auto off ends with "The X is spent." |
| the server | the cycles go to `POST /api/gather` in batches (8 s, 40 cycles, or when the work stops), after the bag is saved. The server decides what was found, the XP and the level from its own dice and its time budget (a burst of 3 beyond what the time allows, 1,800 cycles an hour); the client adopts its answer: the bag, the professions (`skills.adopt`), the gold, the Chronicle's `gathered.<skill>` count, a "Found: ..." toast for each extra, the level-up banner and the counsel's `skill_up`, the rare-find banner for a pet charm. A refusal is shown in the server's words and the cycles are dropped; offline or a 5xx keeps them and tries again 10 s later. Quitting, logging out and switching character send what is still queued first, through the same route (`DmNextGame.flush_all` runs the loop's flush before the Chronicle's and the progression's, and waits for a batch still out and sends what queued behind it), so the last 8 s are paid and counted too. The client's own rolls never mint a thing: cycles it rolled as failures are paid too |
| stops | walking by hand, a click on the ground, a panel, a rite, death, a full bag ("Your bag is full." before it starts); a level the skill has not reached is refused in the rules' words ("Requires ...") and GM mode opens every tier to the client's gate |
| AFK | from the Skills tab (P), in the Acre only ("Visit the Sexton's Acre for safe AFK gathering."): `begin_afk_gather`, then the loop with no burst; stopping shows the report (`gather_report`) and keeps the best session in the counsel store under the original key |
| the Acre's glue | `DmNextAcre` (child `Acre` of the host, with the real HUD; it reads the world's lights-only builder) is the host object `DmLaborerViews` and `DmGameLabor` talk to: the garden check 4 s after the game is ready and every 60 s ("N plots are ready / still growing in your garden (U)"), the labor check 6 s after and every 5 min ("Your laborers have gathered about N finds (H)" after 30 minutes of work, "A laborer has filled up"), the panels' results (`on_labor_collected`, `on_garden_result`, `on_contract_delivered`: the gold the server paid, the Chronicle, the report hung under the laborer, "Harvested N x ...", "Grave Gardening N", "Order filled"), and the feeds the Sexton and the Next box read (`labor_summary`, `contract_summary`, the skills' levels, the bosses beaten) |
| the panels | the Acre ledger (Skills P, Garden U, Laborers H, Contracts), the AFK report and the node and laborer cards are `DmGameUi` panels, warmed with the others (`DmNextGame.WARM_PANELS`); `DmNextUiHost` forwards their calls to the Gather node and the Acre |

**The Grave Laborers are views, not bodies of the core.** Up to four pooled `DmCreature` models (the legion's art, `skeleton_thrall` and its kin) stand at their posts in the Acre and chop, dig or fish; each is a full skeleton with
a tool in its hand, none is a thrall of anyone's legion, and none exists outside the Acre: they are made on the first visit and hidden, not updated and not fetched anywhere else. A crowd goes in the core's arrays; four
characters are the same kind of thing as the hub's three people, so they stay nodes, and the count is capped by the labor rules (`DmLabor.MAX_SLOTS`, 4). A laborer competes with the nodes for the hover by screen distance
(an 18 px bonus), and a click on one opens the Laborers (H).

*Cost.* An idle frame of the Gather node and the Acre's glue is about 4 us (measured once; the tests no longer print it): the Gather node accumulates a clock, ticks at 10 Hz (the views' pulse, the loop's update), and while a loop runs it ticks every frame for
the progress arc; the respawn check runs at 4 Hz only while a node is spent; the Acre's glue is three timers and, in the Acre only, up to four laborers within 48 m. No node or script exists per creature, and nothing is scanned across all nodes.

*Tests.* `tests/gathering.gd` plays it on the local mock with a game clock the mock follows (the whole world, the HUD and panels, no real server): the nodes in the scenes and their views, all 68 hovered and clicked (a level refused in the
rules' words), a node worked from the click to the server's answer and to spent and back (the walk, the cycle's length, the batch, the bag, the XP, the Chronicle, the respawn), the stops, Auto off, the server's dice
(a level-up, the extras, a charm, the burst, a spent hour), AFK and its report, the laborers (none built outside the Acre, three at their posts, the hover card, a click, three hours of work, a collection with its gold), the garden (plant,
harvest, a level), a contract, the Sexton's greeting, the guidance feeds and the Next box's state, the notices of a full laborer and a ready plot, each skill's find and XP, the Sawpit's plank from gathered logs, every node's stand spot and yield, leaving mid-gather (the cycles not yet sent are paid by the server before the game goes, a batch still out is waited for and what queued behind it goes too, the Chronicle's count of them is saved after them) and a relaunch that keeps the results. `tests/chapterhouse/run.gd` also crafts at every forge station, reforges an affixed piece and sends a bug report. `tests/coop.gd` checks that a node the host spends is spent on the guest.

*Gaps.* A node's live look is the area scene's prop, which the lighting bake lit; its spent model is built at run time, so it is lit by the area's real-time light and ambient, and the bake's light of the live model
stays on the ground around it. Never looked at on a GPU. The laborers' models are first built on the first Acre visit (`DmNextWarmup` does not draw them yet, so the first look at their materials on a GPU is unmeasured). Gathering is the host's: a guest holds the nodes and their views but has no loop (its character has no backend api on the host), so it cannot gather, and it does not see the host's laborers or the tool in
a gatherer's hand.

## Tests
`client/tests/gathering.gd` (all 68 nodes hovered and clicked, a node worked through the server, the stops, AFK and its report, the laborers, the garden, a contract, the Sexton's guidance feeds, the idle cost of the Gather node and the glue, leaving mid-gather); `client/tests/coop.gd` checks that a node the host spends is spent on the guest.

## Known gaps
- Remote players do not see a gatherer's tool / gesture or the host's laborers; clients cannot start gathering (above).
- The laborer models are first built on the first Acre visit; `DmNextWarmup` does not draw them yet (rendered cost unmeasured). A node's spent look is built at run time and lit by the real-time light, not the bake; never looked at on a GPU.
