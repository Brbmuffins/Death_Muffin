# godot/next/status: DmStatusSet

One component per body: a `DmStatusSet` child named `Statuses` (`DmStatusSet.attach(body)`, called on EVERY peer right after the body spawns,
same NodePath because RPCs resolve by path). `DmStatusSet.ensure(body)` is the host-only fallback (tests, solo helpers): it makes a
non-replicating set on demand. Spawners of enemies, thralls and players should `attach` every body.

## Contract
```
apply(id, source: Node = null, stacks = 1, duration = -1 (rule default), params = {dps, cap, amount})   # host only, no-op elsewhere
remove(id) / clear() / absorb(dmg) -> leftover (barrier)
has(id) / stacks(id) / remaining(id) / source_of(id) / ids()
speed_mult() attack_rate_mult() damage_taken_mult() damage_dealt_mult() is_stunned() is_silenced()
advance(dt)            # fixed 0.1 s steps; _physics_process calls it (deterministic hosts/tests call it themselves)
signals: changed, expired(id), dot_damage(id, amount, source, killed, target)   # dot_damage host only
static: of(body) ensure(body) attach(body) hit(target, amount, from, allow_stagger) warm()
```
- **Ownership of multipliers**: the set writes `speed_mult` and `attack_rate_mult` on the owner (when it has them) only when the status set
  changes. Nobody else writes them. `damage_taken_mult()` IS applied centrally, once: every owner's `take_damage` (DmEnemy, DmThrall, DmHeroBody) calls
  `DmStatusSet.scale_taken(self, amount)` on entry, so rites, thralls, DoTs, zones and enemy blows all get it. `DmStatusSet.hit` is now a plain pass-through
  (never multiplies); a new owner type's `take_damage` must call `scale_taken` itself. `damage_dealt_mult()` (hex) is for the attacker's damage code (thralls).
- **Kill credit**: DoT ticks call `owner.take_damage(amount, source, false)` (the owner applies the multiplier; `dot_damage` reports the scaled amount) in 0.25 s lumps; `source` is the Node that applied (bleed: the
  strongest-dps applier, withered: the last stacker). `dot_damage` carries `killed`.
- Owner hooks used when present: `hp`, `max_hp`, `def` (frenzy), `take_damage`, `stun(s)`, `creature` (shrouded opacity), signals `died`
  (set clears itself) and `statuses_cleared` (drops bleed/withered/root/slow/chill, like a ghoul's dig-in).
- Duration of 1e9 = permanent (frenzy, shrouded). Frenzy is automatic for defs with the `frenzy` trait (hp below `FRENZY.atFrac`).

## Statuses (numbers from DmSimData; ids in `DmStatusSet.IDS`)
| id | rule |
|---|---|
| `slow` (0.3 s default) / `ward_slow` | move x `MIASMA_SLOW` / `WATCHMANS_WARD_SLOW`; slows take the strongest (min), never stack; re-apply keeps the longer time |
| `chill` | `CHILL` moveMult + attackRateMult, durationS |
| `root` | move 0 for `BONE_PRISON.rootS` (still turns and swings) |
| `stun` / `silence` | flags; stun also calls `owner.stun(seconds)` when it starts or extends |
| `bleed` | dot, `HEMORRHAGE.durationS`, time always resets, stronger `dps` wins and takes ownership |
| `withered` | dot, stacks x dps per second, `params.cap`, time resets to `WITHERED.durationMs`, strongest dps, last stacker owns |
| `fracture` | taken x (1 + `perStack` x stacks), cap `FRACTURE.maxStacks`, `durationMs` |
| `hex` | dealt x `BONE_HEX.damageMult` |
| `sanctified` | taken x `SANCTIFIED.damageTakenMult` |
| `incensed` | `CENSER` moveMult + attackRateMult, `hasteS` (Censer Bearer pulse) |
| `frenzy` / `shrouded` | `FRENZY` moves/rate / `AFFIX_TUNING.shrouded` taken; permanent |
| `barrier` | `params.amount` (+`cap`) soaks damage through `absorb()`, `BONE_MANTLE.durationS` |

## Replication
Host sends `PackedByteArray`, 4 bytes per status (id, stacks, remaining in 0.1 s), only when an id appears/disappears or stacks change
(refreshes are silent), reliable, plus a full sync to a peer that connects later. Clients hold id/stacks/remaining-at-send for visuals and
never tick or write multipliers. Replication happens only for `attach`ed sets.

## Visuals (every peer, from replicated state)
Motes as in `DmEntityViews` (withered rot, fracture dust, bleed, chill frost, sanctified, frenzy, incense) through `Vfx.emit`, one reused
dictionary per id (no allocation), within 30 m of the camera, running only while the body has statuses. Shrouded sets the creature opacity to
0.38; the Censer Bearer gets its ring decal and smoke. The bleed mote uses only crimson.

## Tests / known gaps
Suites: `tests/status/run.gd`, `tests/next_combat_odds/run.gd` (A: ward, B: boss immunity).
- Player-side Bone Ward / Colossus guard stay in `DmPlayerRules` / `DmHeroBody._ward` (computed from the living thralls on every hit), not here. Barrier here has no decay (the 6 s duration only).
- Bosses (`DmBoss`) carry a set and show `slow` / `root` / `chill` but the brain ignores them: bosses are immune.
- `shrouded` does not suspend itself inside friendly miasma: the world code should remove/apply it.
- The elite-affix rings/auras belong to the enemy_fx track.
