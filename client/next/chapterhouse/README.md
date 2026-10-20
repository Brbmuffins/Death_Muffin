# client/next/chapterhouse: the hub made live

`DmChapterhouse` (`dm_chapterhouse.gd`, child `Chapterhouse` of `DmNextGame`) is the hub controller: NPCs you can talk to, stations that open
panels, waystone travel and recall (T), door seals, interactable hover / click / prompts. `DmHubNpcs` (`dm_hub_npcs.gd`, extends `DmNpcViews`
in `client/game/`) draws the NPCs with a tiered update, and only when the Chapterhouse area is loaded. Content comes from `areas.json` interactables, `npcs.json` and `DmCovenantDialogue`.

## Behaviour
- Interactables: `pick(screen)`, `hover_at`, `click_at`, `interact(it)`, `interact_prompt(it)`. Range 2.6 m, pick radius 60 px, waystone range 5 m.
- Signals: `npc_interact(id)` and `station_interact(id)` (forwarded by `DmNextUiHost` to the panels), `interacted(it)` for things the hub does not own
  (boss altars, Depths stairs; `DmBossHost` and `DmDepths` listen), `seal_broken(area)`, `travelled(area)`.
- Seals: the hub owns them (`apply_seals`, `start_seals`, `check_seals`: the kills in the area before reach a seal's count); breaking one raises the gate and joins that area's navmesh region, through `DmNextWorld`
  (`set_unlocked`, `set_door_open`), and shows the "A seal breaks" banner (`announce_seal`). A party guest has the host's seals: `apply_seals` and `check_seals` do nothing on a guest (client/README.md "Co-op on the core").
- Travel: `travel(area)` serves every waystone whose seal is broken, from beside a waystone or in the Chapterhouse, else "<Area> is still sealed."; the thralls are recalled to the hero (`move_body`).
- Recall: `start_recall()` (T, 1.5 s standing still), `cancel_recall()` (any movement), `finish_recall()`. `teleport_to` moves the host's own body.
- A guest asks the host (`DmNextParty.ask_travel`): the host picks the destination (`guest_destination`), moves the guest's body (`move_body`) and answers with the jump the guest plays (`arrived`) or the reason it refused (`travel_refused`).
- Cost: one 10 Hz tick, a 5 Hz NPC refresh, per-frame animation only for NPCs near the player (far NPCs frozen, mid at 15 Hz).

## Tests
`client/tests/world.gd` (seals, gates, waystone travel, the recall), `client/tests/coop.gd` (the host's seals on a guest, a guest's waystone map, jump and recall), `client/tests/panels.gd` (the stations' panels open).
