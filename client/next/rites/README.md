# client/next/rites: the necromancer's rites

`DmRiteCaster` (`dm_rite_caster.gd`) is a Node named `Rites`, a child of every player body on every peer (same NodePath, because RPCs resolve by path).
It is the shared plumbing: intent RPC, owner / cooldown / essence validation through `DmAbilities`, event broadcast, once-per-peer playback, state
replication. **Each rite is its own module** `rite_<id>.gd` (a `DmRiteModule`), listed with one line in `dm_rite_registry.gd`. 34 rites are registered; the last nine
are the Reaper's (family `reaper`, class 11; shared helpers in `dm_reaper_rites.gd`): scythe_sweep (LMB), scythe_throw, reap, wraith_walk,
soul_burst (keys 1-4), harvest_spin (RMB) and unleash_souls (R, her kit's signature: 1 soul and then the rest of the bag become homing wisps that strike the enemy nearest
to each and circle her while there is none; host state `mem("unleash_souls").wisps`; the Reaper's armor set Soul Harbinger's Raiment, `DmReaperSet`, adds rite keys to her mods
while worn: 2 pieces `scytheRadiusMult` 2 for scythe_throw, 4 pieces `soulShield` (the wisps' damage becomes barrier, refreshed by the next release), 5 pieces `soulScythes` 15 (a scythe_throw left where each wisp lands); its pieces are the legendary items `leg_soul_harbingers_<part>`, `server/rules/content/legendarySets.ts`).
Her soul bag is her only resource (the HUD's energy orb shows it; `p["resource"]` is an inert full bar): `p["souls"]` (size `soulsMax` 30, 10 at the start),
filled one soul per enemy that dies near her (`DmNextMeta._bank_reaper_soul` on `kill_earned`, the wisp loops round the corpse for a second and then flies to her),
worth +2% rite damage a soul in `DmAbilities.sp`. Every rite but scythe_sweep has a `soulCost` in abilities.json that `DmAbilities.cast_check` (refusal `souls`) and
`apply_cast_cost` take (throw 3, reap 5, wraith_walk 4, harvest_spin 2, soul_burst 6 and then the rest of the bag); reap, wraith_walk and soul_burst add damage per soul paid. She fights in melee without thralls, so `DmPlayerRules.take_damage`
cuts her damage taken (REAPER `damageTakenMult`) and refuses every blow while `p["phasedUntil"]` (Wraith Walk's rush) runs, and `DmReaperRites.strike` heals her
`leechPerHit` of her max health per enemy struck, at most `leechSwingCap` a swing (the thrown scythe passes `leech = false`).
A ninth Reaper rite, scythe_weave (Grimoire only; free, 0.45 s, toward the cursor): her fast single-target strike, power 0.7 on the nearest enemy in a 3.6 m, 35-degree-either-side cone, leeching on the hit; the strokes alternate between an overhead chop and a rising cut (`p.weaveStroke`, drawn as vertical beams; the gesture switches to the pseudo-rite `scythe_weave:rise`, clip `slam` for the chop, `flick` for the rise); on a held hotbar key `DmCombatInput`'s hold repeat strikes again the moment its cooldown ends. An eighth Reaper rite, soul_harvest (Grimoire only, not on the default bar; free, 5 s, 9 m): every enemy struck puts 1 soul in the bag and heals `harvestHealPerMob` of max health, at most `harvestHealCap`; it also sets `p.harvestAmp`, which makes `DmAbilities.sp` `harvestNextMult` (x2) until her next spell (not a primary, not another Soul Harvest) resolves, where `DmRiteCaster._apply_cast` clears it. The necromancer rites:
bone_needle, bone_fan, rot_lance (primaries); miasma, marrow_spear, exhume, black_litany, corpse_explosion, grave_offering, bone_mantle, carrion_seed,
wailing_skull, ivory_cleave, bone_storm, soul_siphon, grave_step, veil_step, grave_frost, bone_prison, grave_hands, rally_dead; signatures
ossuary_wall, command_rend, dirge, plague_bloom. Numbers come from the shared rules (`DmAbilities`, `DmSimData`, `DmCombatData`, `abilities.json`), not from the modules.

How the rites sit on the combat core (the rites stay GDScript and call the core synchronously, so a kill resolves inside the cast; an enemy is an id or a `DmFoe` snapshot; the table of what a module uses where it used nodes; which files are ports) is
client/README.md "The Gravecaller's rites"; what differs from the old game is native/README.md "Differences from today's game".

Other files: `dm_rite_hotbar.gd` (`DmRiteHotbar.rite_for_slot` / `wire(game)`: LMB = kit `defaultPrimary`, 1-4 = `defaultLoadout`, RMB = kit `rmb`,
slot 6 / R = the discipline's signature at level 10), `dm_rite_gestures.gd` (cast gestures; the Reaper's rites play the Mourner rig's own combat clips, `DmAvatar.REAPER_CLIPS`: sweep / spin = `sweep`, reap = `slam`, throw = `flick`, wraith walk = `channel`, soul burst = `summon`, each timed so its release frame lands on the cast and played faster the shorter the rite's cooldown got, e.g. under haste), `dm_rite_legends.gd` (legendary-set effects),
`client/game/dm_rite_fx.gd` (`DmRiteFx`, all visuals and sounds).

## Flow (DECISIONS.md D1)
1. Owner: `request_cast(rite, aim, target_id := -1)` -> `_rpc_cast` (reliable) to the host. No client prediction.
2. Host `_apply_cast`: sender must own the body (else `rejected_intents++`), finite aim, known rite, `module.validate`, `DmAbilities.cast_check`
   (dead / locked / busy / cooldown / essence), range and target. A refusal goes back as `cast_rejected(rite, reason)`.
3. Host pays essence and cooldown (`apply_cast_cost`), `module.resolve` does the damage / statuses / corpse use, then `broadcast`s events.
4. Every peer (host and solo included) plays each event once via `module.play` and emits `event_played`; `hit_number(pos, amount, crit)` feeds floating numbers.
5. Vitals live on the host. When the body has `DmPlayerRules` vitals the caster works ON them (`shares_vitals()`): one essence pool the HUD, rites and brews share.
   The owner receives `{essence, max_essence, cooldowns, alive, souls, soulsMax}` by RPC (10 Hz while essence or souls change; a guest's HUD reads its Soul Harvest meter from it). Host hook: `hit_resolved(rite, enemy_id, amount, crit, killed)`.

## Adding a rite
1. `rite_<id>.gd`: `extends DmRiteModule`, `func _init(): id = "<id>"` (`steps = true` if it ticks on the host). Modules are shared singletons: per-caster state in `c.mem(id)`.
2. Override: `validate(c, intent) -> String` (host, before anything is spent; "" = go), `resolve(c, intent) -> String` (host, cost paid; return a reason to refund),
   `play(c, ev)` (every peer, from the event only), `step(c, dt)` (host per physics tick).
3. One line in `dm_rite_registry.gd`; run `godot --headless --path client --import` once.
4. Add checks to `client/tests/rites.gd`. Caster API for modules: `c.p`, `c.mods`, `c.now_ms`, `c.body`, `c.world`, `c.fx`, `c.rand()`, `c.mem(id)`, `c.after()`, `c.broadcast()`, `c.gain_essence()`, `c.add_barrier()`, `c.heal()`; for creatures
   `c.foe(id)`, `c.foes_in_radius(pos, r)`, `c.deal(id, amount) -> {dealt, killed}`, `c.apply_status / has_status / status_stacks / remove_status`, `c.corpses()` and `c.thralls()`; the lane, cone, circle and `pick_enemy` helpers are `DmRiteModule`'s.

## DmRiteWorld (duck-typed; `DmNextGame` implements it)
`enemies_in_radius(pos, r)` (ids), `enemy_position(id)`, `enemy_alive(id)`; optional `rite_build(peer_id)` (`{stats, discipline, loadout, runes}`), `aim_point()`,
`aim_target_id()`, `on_rite_event(ev)`, `area_of(peer)`. The corpse field and the legion are the core's, reached through the caster (`c.corpses()`, `c.thralls()`).

## Weapon line, runes, legendary sets
- Weapon line on the primary (`rite_bone_needle.gd`, rules `DmWeaponLine` in `p["loadout"]`): Staff = longer reach and pierce, Wand = damage / cadence,
  Sickle = a Withered stack per needle, Scythe = no projectile, a 100 deg arc `_reap` (event `reap`, +4 essence a hit).
- Runes: `rite_build()["runes"]` carries the bag's sockets (`sync_runes()` on every bag change); a module reads its rune per cast (`DmAbilities.rune`). All 11 runes of
  `client/data/content/runes.json` are live (Splinters, Marrow-Tap, Volley, Ossuary Ring, Impaling, Mass Grave, Bone Colossus, Creeping Rot, Contagion, Hollow Choir, Requiem).
- Legendary sets: `DmRiteCaster._set_mods` resolves `DmLegend.sim_legend_of(mods)` into `caster.legend` and the legion (`push_legend`). Plague Choir lives in
  `rite_miasma.gd`, `spearRally` in `rite_marrow_spear.gd`, Colossus Mantle's guard / reflect / shatter run in `DmHeroBody.take_damage` via `DmRiteCaster.legend_hurt`, Requiem Wraiths in `dm_rite_legends.gd`.
- Known deviation: a toxic Corpse Explosion's rot pool also bursts corpses for the Rotweaver (the original sim's did not).

## Tests
`client/tests/rites.gd` casts every rite against the old game's formulas (table-driven with the copied rules code), the refusals, the synchronous-kill cases, the kit's hotbar and the click-to-attack chase, plays a fight, then the other three necromancers and the Reaper (a weapon line case and the runes included);
`client/tests/core_status.gd` and `core_corpses.gd` / `core_thralls.gd` the core's half. Not covered in the client: the old game's separate runes suite (all 11 runes' numbers), its weapon-line odds and its sound coverage of all 25 rites.

## Known gaps
- The Legion Champion 5 rally mark (`spearRally`) has no event fx.
- Bone Mantle, Carrion Seed, Grave Offering, Grave Step, Veil Step, Grave Frost, Bone Prison, Grave Hands have no default hotbar slot (the Grimoire puts them on the keys).
