# godot/next/rites: the necromancer's rites

`DmRiteCaster` (`dm_rite_caster.gd`) is a Node named `Rites`, a child of every player body on every peer (same NodePath, because RPCs resolve by path).
It is the shared plumbing: intent RPC, owner / cooldown / essence validation through `DmAbilities`, event broadcast, once-per-peer playback, state
replication. **Each rite is its own module** `rite_<id>.gd` (a `DmRiteModule`), listed with one line in `dm_rite_registry.gd`. 25 rites are registered:
bone_needle, bone_fan, rot_lance (primaries); miasma, marrow_spear, exhume, black_litany, corpse_explosion, grave_offering, bone_mantle, carrion_seed,
wailing_skull, ivory_cleave, bone_storm, soul_siphon, grave_step, veil_step, grave_frost, bone_prison, grave_hands, rally_dead; signatures
ossuary_wall, command_rend, dirge, plague_bloom. Numbers come from the shared rules (`DmAbilities`, `DmSimData`, `DmCombatData`, `abilities.json`), not from the modules.

Other files: `dm_rite_hotbar.gd` (`DmRiteHotbar.rite_for_slot` / `wire(game)`: LMB = kit `defaultPrimary`, 1-4 = `defaultLoadout`, RMB = kit `rmb`,
slot 6 / R = the discipline's signature at level 10), `dm_rite_gestures.gd` (cast gestures), `dm_rite_legends.gd` (legendary-set effects),
`game/dm_rite_fx.gd` (`DmRiteFx`, all visuals and sounds).

## Flow (DECISIONS.md D1)
1. Owner: `request_cast(rite, aim, target_id := -1)` -> `_rpc_cast` (reliable) to the host. No client prediction.
2. Host `_apply_cast`: sender must own the body (else `rejected_intents++`), finite aim, known rite, `module.validate`, `DmAbilities.cast_check`
   (dead / locked / busy / cooldown / essence), range and target. A refusal goes back as `cast_rejected(rite, reason)`.
3. Host pays essence and cooldown (`apply_cast_cost`), `module.resolve` does the damage / statuses / corpse use, then `broadcast`s events.
4. Every peer (host and solo included) plays each event once via `module.play` and emits `event_played`; `hit_number(pos, amount, crit)` feeds floating numbers.
5. Vitals live on the host. When the body has `DmPlayerRules` vitals the caster works ON them (`shares_vitals()`): one essence pool the HUD, rites and brews share.
   The owner receives `{essence, max_essence, cooldowns, alive}` by RPC (10 Hz while essence changes). Host hook: `hit_resolved(rite, enemy_id, amount, crit, killed)`.

## Adding a rite
1. `rite_<id>.gd`: `extends DmRiteModule`, `func _init(): id = "<id>"` (`steps = true` if it ticks on the host). Modules are shared singletons: per-caster state in `c.mem(id)`.
2. Override: `validate(c, intent) -> String` (host, before anything is spent; "" = go), `resolve(c, intent) -> String` (host, cost paid; return a reason to refund),
   `play(c, ev)` (every peer, from the event only), `step(c, dt)` (host per physics tick).
3. One line in `dm_rite_registry.gd`; run `godot --headless --path godot --import` once.
4. Add checks to `tests/rites/`. Caster API for modules: `c.p`, `c.mods`, `c.now_ms`, `c.body`, `c.world`, `c.fx`, `c.rand()`, `c.mem(id)`, `c.after()`, `c.broadcast()`, `c.gain_essence()`, `c.add_barrier()`, `c.heal()`.

## DmRiteWorld (duck-typed; `DmNextGame` implements it)
`enemies_in_radius(pos, r)`, `enemy_by_id(id)`, `enemy_id(enemy)`; optional `rite_build(peer_id)` (`{stats, discipline, loadout, runes}`), `aim_point()`,
`aim_target_id()`, `on_rite_event(ev)`, `corpses` (the `DmCorpseField`), `area_of(peer)`. Thralls come from the body's `Thralls` host.

## Weapon line, runes, legendary sets
- Weapon line on the primary (`rite_bone_needle.gd`, rules `DmWeaponLine` in `p["loadout"]`): Staff = longer reach and pierce, Wand = damage / cadence,
  Sickle = a Withered stack per needle, Scythe = no projectile, a 100 deg arc `_reap` (event `reap`, +4 essence a hit). Test: `tests/next_combat_odds/run.gd`.
- Runes: `rite_build()["runes"]` carries the bag's sockets (`sync_runes()` on every bag change); a module reads its rune per cast (`DmAbilities.rune`). All 11 runes of
  `data/content/runes.json` are live (Splinters, Marrow-Tap, Volley, Ossuary Ring, Impaling, Mass Grave, Bone Colossus, Creeping Rot, Contagion, Hollow Choir, Requiem). Test: `tests/next_runes/run.gd`.
- Legendary sets: `DmRiteCaster._set_mods` resolves `DmLegend.sim_legend_of(mods)` into `caster.legend` and the legion (`DmThrallHost.set_legend`). Plague Choir lives in
  `rite_miasma.gd`, `spearRally` in `rite_marrow_spear.gd`, Colossus Mantle's guard / reflect / shatter run in `DmHeroBody.take_damage` via `DmRiteCaster.legend_hurt`.
- Known deviation: a toxic Corpse Explosion's rot pool also bursts corpses for the Rotweaver (the original sim's did not).

## Tests
`tests/rites/run.gd` (needle, miasma, shared plumbing), `control_run.gd`, `corpse_run.gd`, `projectile_run.gd`, `signature_run.gd`; `tests/next_runes/run.gd`;
`tests/next_combat_odds/run.gd` (weapon line, sound coverage of all 25 rites); `tests/next_clarity/cues_run.gd` (cast cues).

## Known gaps
- The Soul Harvest empowered cast (x1.5 spear) and the `legend` rally event fx are not ported.
- Bone Mantle, Carrion Seed, Grave Offering, Grave Step, Veil Step, Grave Frost, Bone Prison, Grave Hands have no default hotbar slot.
