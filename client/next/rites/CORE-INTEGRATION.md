# The Gravecaller's rites

How the rites run on the combat core. The rites' files, flow and how to add one: [README.md](README.md).

The rites (`next/rites/`, DECISIONS B42) are GDScript and call the core synchronously: a rite damages with `core.damage(id, amount, source)` and reads `{dealt, killed}` at once, so Wailing Skull's
extra leap on a kill, Bone Prison skipping the dead and the Litany's loops resolve inside the cast. `next/rites/` has every rite of the necromancer's and the Reaper's kits (her shared helper `DmReaperRites`: the cone and circle pick, the blow with its life steal, the soul bag).
The registry lists all 35; a rite with no module (the five later classes') is refused `unavailable`. `DmNextGame.attach_caster` gives the hero his `Rites` node (a `DmRiteCaster`; the game scene is its `DmRiteWorld`) and `DmRiteHotbar.wire`
connects the input. The numbers (spell power, cooldowns, costs, runes) are `DmAbilities`, `DmSimData` and `abilities.json`; the thralls' stats `DmThralls.raise_stats / colossus_stats`.

What a rite reaches creatures through (all on the caster `c`; the adapters belong to the game scene's `DmCoreHost` and live in `core/`):

| A rite needs | The caster gives |
|---|---|
| creatures near a point, one creature's place, radius and health | `c.foes_in_radius(pos, r)`, `c.foe(id)`: `DmFoe` snapshots (id, x, z, radius, hp, state, def, area), living, spawn order, edge distance (`core/dm_foe.gd`) |
| a blow, and whether it killed | `c.deal(id, amount)` returns `{dealt, killed}` (`c.hit` the bool); the hero is the source |
| a status on a creature | `c.apply_status / has_status / status_stacks / remove_status`; the DoT credit and Withered's hand-on are the core's events, connected once per caster |
| corpses | `c.corpses()` (`DmCoreCorpses`, `core/dm_core_corpses.gd`): `pick_corpse`, `corpses_in_radius`, atomic `consume`, `add_corpse`, `notes(id)`; records are `DmCoreCorpse` snapshots |
| the hero's legion | `c.thralls()` (`DmCoreLegion`, `core/dm_core_legion.gd`): `raise`, `rally`, `command_rend`, `near`, `list`; a thrall is an id and `info(id)` is the core's record; cap, formation, swing and death are the core's |
| lane, cone, circle, `pick_enemy` | the functions of `DmRiteModule`, answering from the core's radius query (edge distance, strict comparisons, spawn order, caps) |
| what a rite remembers of an enemy (contagious, the Chain Plague gap) | kept by enemy id in the rite's memory; the shroud's cover is `core.cover_miasma` |

Timers are the caster's (`c.after(ms, fn)` on the body's clock, a physics tick). Events and fx: `broadcast` -> `play` -> `DmRiteFx` through the `Vfx` and `AudioDirector` autoloads. The hero's own statuses are `DmStatusSet`. The cast flow (owner, cooldown, essence and cast lock through
`DmAbilities.cast_check / apply_cast_cost`, refund on a lost corpse race) is in `next/rites/README.md` "Flow". Where a rite meets the core:
- **Ossuary Wall is a core obstacle** (`DmCore.add_obstacle`, a 7 m by 0.8 m box): the core keeps every enemy on the surface out of it (one standing where it rises is put out through the nearer side) and an enemy's steering does not drive into it, so a body slides along it toward its goal and presses
  there; thralls and the hero pass. The core has no navigation avoidance, so a crowd does not curve around the wall's ends before reaching it.
- **A boss is in the rites' queries** by its id: the fan, the lance, the siphon, the skull, the Scythe's arc and Colossus Mantle's reflect reach it ([The bosses](../bosses/CORE-INTEGRATION.md)).
- **Withered's kill credit and its hand-on come from the event buffer**, at the end of the tick that killed: the DoT's `hit_resolved`, Contagion's and Plague Choir's spread to the neighbours, and the corpse-consumed beat of Requiem Wraiths' wisp. A rite's own blows are known at once
  (`killed` in the reply of `damage`), so nothing a player sees waits for it.
- **A status on an enemy or thrall is the core's** (`apply_status`): the hero is its source, so the last stacker of a Withered owns the kill; the Miasma's lift of the Shrouded ward is `cover_miasma` (0.35 s of game time, native/README.md "Affixes"), asked for every enemy in a cloud (the core ignores a body
  without the ward).
- **Carrion Seed's fields live in the corpse field's notes** (`DmCoreCorpses.notes`, dropped with the corpse); its arming and expiry run on the caster's clock in ms, and a seed ends with its corpse.
- **Two of the legion's moments are the core's events that the game acts on** (`DmLegionEvents`, `next/rites/dm_legion_events.gd`, the host's): a wraith raised with the Mourning Bell heals every living hero within the bell's range for its share of THEIR maximum health at each blow
  (`DmCoreHost.thrall_bell_heal`), and a plague bearer that falls other than crumbling leaves its owner's friendly rot cloud (`thrall_plague_pool` -> `rite_miasma.gd` `plague_pool`, the toxic Corpse Explosion's rules; the cloud is drawn on every peer by the caster's event).
  The core's toxic corpse pools hurt at the area's level: `DmCoreHost` hands the core the level of the enemies made in each area (`set_area_level`, once per change), which the director, the Depths floors and the bosses' adds already give them.
- **Spear rally's mark** is written to each thrall by the rite each tick while the mark lasts (`set_thrall_mark` from `thrall_info`'s target); the thrall does not read it. Legion size bounds the cost (Legion Champion 5 only).
- **Wraith Walk's green flame is the core's status** (`wraithfire`, a damage over time like Hemorrhage, its damage a second set by the cast), so its kill credit comes from the event buffer at the end of the tick, as Withered's does; the Reaper's swings, harvest and wisps strike through `deal` and
  know their kills at once. Her life steal counts the enemies a swing struck.
- Shots follow the simulation's position of their target. A blow of zero or less is refused (`damage`, a boss's too); no rite deals one.

`client/tests/rites.gd` casts every rite (table-driven), the refusals, the synchronous-kill cases, the kit's hotbar and the click-to-attack chase, and plays a fight; then the other three necromancers and the Reaper, each a real
character in a fresh game (her bag, souls paid and refused, every rite's damage with the souls' bonuses, the life steal, the wisps, Soul Harbinger's Raiment, a kill banking a soul, auto combat's pick).
