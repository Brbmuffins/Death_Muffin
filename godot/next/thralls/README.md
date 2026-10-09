# godot/next/thralls: the necromancer's raised dead on the session structure

`DmThrall` (`dm_thrall.gd`, scenes `thrall_base.tscn` + `warrior/shieldbearer/hound/wraith/archer/bonemage/plaguebearer/colossus.tscn`) is a
CharacterBody3D (FLOATING) + NavigationAgent3D with an explicit state machine (`RISING IDLE MOVE ATTACK DEAD`, wire ids append-only), same idioms as
`DmEnemy`. `DmThrallHost` (`dm_thrall_host.gd`) is one per player: it raises, caps, seats, queries and replicates the legion. Numbers come from the
existing rules (`DmThralls`, `DmSimData.RALLY/CHILL/BONE_HEX/PLAGUE_BURST/LEGEND/SIGNATURE.rend`, `DmSimConsts.THRALL_*/FOLLOW_*`); no new numbers
except scan period 0.25 s, repath 0.3 s, corpse linger 1.4 s.

## Host brain (DECISIONS.md D1; solo = the same path with one player)
- Follow: ring of 1.9 m around the owner, seats dealt by rank among the living (`formation_rank/count`, set by the host), 1.35x pace when > 6 m behind,
  seat-velocity catch-up (the `FOLLOW_*` constants). Owner > 24 m away: teleport next to the owner and drop the target.
- Acquire: nearest enemy within 10 m of the thrall AND within 11 m of the owner (leash 13 m drops a target). Scan every 0.25 s only while without a
  target (staggered), repath <= every 0.3 s and only when the goal moved > 1 m, goals closer than 3 m are walked straight.
- Blow: instant at swing start: `damage x (rally 1.4) x (hag hex 0.7) x mark_mult` via `DmEnemy.take_damage(amount, thrall)`, cadence `attackInterval`,
  reach `range + target.radius`. Kind extras: wraith chill + `bell_heal`, bone mage hex (`status_applied`, the status track applies them), colossus cleave 0.6x in 2.4 m.
  Plague bearer ruptures on death (2.5x dmg, `plague_pool` signal for the zone), `death_burst_frac` (Legion of the Unburied) on "killed".
- Dies: `kill(reason)` reasons `killed crumbled sacrificed decayed`; `lifetime_s > 0` = decay (echo); owner dead/gone = crumble. Body frees itself after 1.4 s.
- Soft separation between the legion (host loop computes a push velocity, no transform writes).
- Credit: a blow's `from` is the thrall node: `thrall.owner_peer` is the peer to credit (rewards track: `DmEnemy.damaged/died` carry `from`).

## Integration with DmNextGame (the one entry point)
On EVERY peer, right after a player body spawns (next to `attach_caster(body)`), same name/path:
```gdscript
DmThrallHost.attach(body, game)      # child "Thralls" of the body; thralls live under `game`, corpses = game.corpses, area = game.area_of(peer)
```
Then the rites call `body.get_node("Thralls").raise(intent, aim)` on the host (exhume / Mass Grave / Bone Colossus), `.rally(secs, focus)`,
`.command_rend(point)`, `.sacrifice(n)` (Black Litany), `.refresh(...)`, `.raise_bonded(intent)`; queries `list() count() places_used() by_id() near()`;
signals `raised(thrall, corpse_rec)`, `thrall_died(thrall, reason)`, `exhume_failed(why)`; `legend` (DmLegend mods: championEvery, thrallDeathBurst; kept current by the caster through `set_legend(l)` on every gear change, taken from the sibling `Rites` when the host attaches), `legion_id`, `kit`.
Replication is inside the host (RPC on the host node, 15 Hz partial unreliable + 1 Hz full reliable, tested over ENet). Every thrall gets a `DmStatusSet`
(`attach`, every peer); thrall blows go through `DmStatusSet.hit`, so enemy damage-taken multipliers apply; wraith chill / bone-mage hex are applied with
`DmStatusSet.ensure(enemy).apply`. Statuses write `speed_mult` / `attack_rate_mult` on the thrall; `take_damage(amount, from)` exists for DoTs; `stun(s)`.

## Raise (`DmThrallHost.raise(intent, aim) -> {ok, thralls, crumbled, why}`)
intent = the exhume intent `{kind, cap, hp, damage, attackSpeedMult, allyHeal?, count? (Mass Grave), colossus?, r?}`. Flow: `pick_corpse(aim, exhume radius 3.2,
range 13, owner pos, area)` -> read the record -> **`consume(id, peer, "consumed")`** (false = lost the race: `why "gone"`) -> make room (`DmThralls.make_room`: oldest
ordinary first, Colossus last, weights 1 / 2) -> stats `DmThralls.raise_stats` (kind from the corpse, empowered x1.5, champion every N) -> spawn rising at the corpse.
Mass Grave: `corpses_in_radius` + consume each (statMult when > 1); Colossus: the nearest 3-5 within r, all consumed, else `few`. `why`: `no_corpse gone few owner_dead not_empty`.
Corpse contract = the real `DmCorpseField` (`pick_corpse(aim, pick_r, max_range, from_pos, area) -> DmSimCorpse|null`, `consume(id, by_peer, reason) -> bool`,
`corpses_in_radius(pos, r, filter, area, include_echo)`); the test double in `tests/thralls/run.gd` has the same names/signatures.

## Enemies target thralls
Thralls join group `dm_target` and implement `dm_alive()` (false while rising/dead), `dm_take_enemy_hit(dmg, from)` and the new optional
`dm_target_weight()` (shieldbearer 0.55, others 1.1: target picking multiplies the distance). `DmEnemy.find_target` multiplies the squared distance by the
weight squared when the target has that method (the range test uses the weighted distance, same rule). Players/dummies are unchanged (1.0).

## Replication
`host.snapshot(full) -> Array` of `{id, s: get_net_state(), i?: spawn_info()}` and `apply_snapshot(arr, full)` (puppets are built / eased / dropped; a thrall that
died is sent once more with state DEAD). `attach`ed hosts send them by RPC themselves. Puppets own no brain: swing counter, death, rally come from the snapshot.

## Visuals (every peer; existing assets, no new ones)
Models, props (bone sword/shield/bow/staff, kit weapons/armour), tint/emissive/rim from `DmEntityViews` (`LEGION`, `THRALL_LOOK`, `THRALL_RIM_OWN/ALLY`); the legion's
own colour = `exhume.spirit` teal rim + a `Vfx` ground ring decal that follows the body (gold = champion, blue = wraith, dimmed `other` = an ally's thrall); the
current rise (sigil + motes + dirt + sfx) and fall (bone chips, soul motes, sfx) looks, rally gives a warm emissive. `DmThrall.warm()` preloads the models (the host calls it).

## Tests / known gaps
Suite: `tests/thralls/run.gd` (corpse field double with the real signatures), plus `tests/rites/` for raising.
Needs physics layer 4 named "thrall" (`DmThrall.LAYER_THRALL = 8`: thralls collide with the world only).
The sim's exhume intent shape (`kind, cap, hp, damage, ...`) is still the contract between rites and the host.
