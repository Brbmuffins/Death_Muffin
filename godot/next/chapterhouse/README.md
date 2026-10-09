# godot/next/chapterhouse: the hub made live

`DmChapterhouse` (`dm_chapterhouse.gd`, child `Chapterhouse` of `DmNextGame`) is the hub controller: NPCs you can talk to, stations that open
panels, waystone travel and recall (T), door seals, interactable hover / click / prompts. `DmHubNpcs` (`dm_hub_npcs.gd`, extends `DmNpcViews`
in `game/`) draws the NPCs with a tiered update. Content comes from `areas.json` interactables, `npcs.json` and `DmCovenantDialogue`.

## Behaviour
- Interactables: `pick(screen)`, `hover_at`, `click_at`, `interact(it)`, `interact_prompt(it)`. Range 2.6 m, pick radius 60 px, waystone range 5 m.
- Signals: `npc_interact(id)` and `station_interact(id)` (forwarded by `DmNextUiHost` to the panels), `interacted(it)` for things the hub does not own
  (boss altars, Depths stairs; `DmBossHost` and `DmDepths` listen), `seal_broken(area)`, `travelled(area)`.
- Seals: the hub owns them (`apply_seals`, `start_seals`); breaking one opens the door and enables that area's navmesh region.
  `travel(area)` serves every waystone whose seal is broken, else "<Area> is still sealed.".
- Recall: `start_recall()` (1.5 s), `cancel_recall()`, `finish_recall()`. `teleport_to` moves the host's body only.
- Cost: one 10 Hz tick, a 5 Hz NPC refresh, per-frame animation only for NPCs near the player (far NPCs frozen, mid at 15 Hz).

## Tests
`godot --headless --path godot --script res://tests/chapterhouse/run.gd` (NPCs, stations, travel / recall, seals, prompts, idle cost on the dev-offline backend).
`tests/chapterhouse/shoot.gd` takes screenshots.

## Known gaps
- Travel and recall teleport on the host only.
