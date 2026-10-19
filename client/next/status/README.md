# client/next/status: DmStatusSet

`DmStatusSet` (`dm_status_set.gd`) is one component per **hero body and per boss**: a child named `Statuses` (`DmStatusSet.attach(body)`, called on EVERY peer right after the body spawns,
same NodePath because RPCs resolve by path; `DmNextGame.attach_caster` does it for a hero, `DmBoss._ready` for a boss). `DmStatusSet.ensure(body)` is the host-only fallback (tests, solo helpers): it makes a
non-replicating set on demand. **The statuses of enemies and thralls are not here: they are the core's** (`native/src/core/status.h`, a port of this class with the same rule table, one implementation for enemies and thralls; native/README.md "Design").
A status is put on one of those bodies only through `DmCoreHost.apply_status` (a caster's `c.apply_status`), which sends a boss's id to the boss's own set and every other id to the core. Never call `DmStatusSet` on an enemy or a thrall.

## Contract
```
apply(id, source: Node = null, stacks = 1, duration = -1 (rule default), params = {dps, cap, amount})   # host only, no-op elsewhere
remove(id) / clear() / absorb(dmg) -> leftover (barrier)
has(id) / stacks(id) / remaining(id) / source_of(id) / ids()
speed_mult() attack_rate_mult() damage_taken_mult() damage_dealt_mult() is_stunned() is_silenced()
advance(dt)            # fixed 0.1 s steps; _physics_process calls it (deterministic hosts/tests call it themselves)
signals: changed, expired(id), dot_damage(id, amount, source, killed, target), withered_died   # dot_damage host only
static: of(body) ensure(body) attach(body) hit(target, amount, from, allow_stagger) warm()
```
- **Ownership of multipliers**: the set writes `speed_mult` and `attack_rate_mult` on the owner (when it has them) only when the status set
  changes. Nobody else writes them. `damage_taken_mult()` is applied once by the owner's `take_damage` through `DmStatusSet.scale_taken(self, amount)`: `DmHeroBody` and `DmBoss` do (below).
  `DmStatusSet.hit` is a plain pass-through (never multiplies). `damage_dealt_mult()` (hex) is for the attacker's damage code.
- **Kill credit**: DoT ticks call `owner.take_damage(amount, source, false)` (the owner applies the multiplier; `dot_damage` reports the scaled amount) in 0.25 s lumps; `source` is the Node that applied (bleed: the
  strongest-dps applier, withered: the last stacker). `dot_damage` carries `killed`. `DmStatusSet.dealing_dot` is true while a DoT tick is dealt, so damage listeners such as lifesteal skip it.
- Owner hooks used when present: `hp`, `max_hp`, `def` (frenzy), `take_damage`, `stun(s)`, signals `died` (the set clears itself, after `withered_died`) and `statuses_cleared` (drops bleed/withered/root/slow/chill).
- Duration of 1e9 = permanent (frenzy, shrouded). Frenzy is automatic for defs with the `frenzy` trait (hp below `FRENZY.atFrac`).

## Statuses (numbers from the data files; ids in `DmStatusSet.IDS`, the same wire order as the core's `client/core/dm_status_rules.gd`)
| id | rule |
|---|---|
| `slow` (0.3 s default) / `ward_slow` | move x `MIASMA_SLOW` / `WATCHMANS_WARD_SLOW`; slows take the strongest (min), never stack; re-apply keeps the longer time |
| `chill` | `CHILL` moveMult + attackRateMult, durationS |
| `root` | move 0 for `BONE_PRISON.rootS` (still turns and swings) |
| `stun` / `silence` | flags; stun also calls `owner.stun(seconds)` when it starts or extends |
| `bleed` / `wraithfire` | dot, `HEMORRHAGE.durationS`, time always resets, stronger `dps` wins and takes ownership (`wraithfire` is Wraith Walk's green flame, a bleed that burns) |
| `withered` | dot, stacks x dps per second, `params.cap`, time resets to `WITHERED.durationMs`, strongest dps, last stacker owns |
| `fracture` | taken x (1 + `perStack` x stacks), cap `FRACTURE.maxStacks`, `durationMs` |
| `hex` | dealt x `BONE_HEX.damageMult` |
| `sanctified` | taken x `SANCTIFIED.damageTakenMult` |
| `incensed` | `CENSER` moveMult + attackRateMult, `hasteS` (Censer Bearer pulse) |
| `frenzy` / `shrouded` | `FRENZY` moves/rate / `AFFIX_TUNING.shrouded` taken; permanent |
| `barrier` | `params.amount` (+`cap`) soaks damage through `absorb()`, `BONE_MANTLE.durationS` |

## Replication
Host sends `PackedByteArray`, 4 bytes per status (id, stacks, remaining in 0.1 s), only when an id appears/disappears or stacks change
(refreshes are silent), reliable, plus a full sync to a peer that connects later. Guests hold id/stacks/remaining-at-send for visuals and
never tick or write multipliers. Replication happens only for `attach`ed sets (heroes and bosses). The core's own statuses ride its reliable batches in the same 4-byte layout (native/README.md "Co-op: snapshots, events and the puppet core").

## Visuals (every peer, from replicated state)
The set's motes (withered rot, fracture dust, bleed, chill frost, sanctified, frenzy, incense) through `Vfx.emit`, one reused dictionary per id (no allocation), within 30 m of the camera, running only while the body has statuses. The tells of the
core's bodies are `DmEnemyFx`'s (`client/next/enemy_fx/README.md`: the ambient pass over `status_changed`), and the Censer Bearer's ring and smoke are its status tell's, not this node's.

## Tests / known gaps
`client/tests/core_status.gd` holds the core's set (the 0.1 s step, DoT lumps, stacking and ownership, multipliers, stun, dig-in clear, Withered on death, wire bytes); `client/tests/rites.gd` and the boss suites
use a hero's and a boss's set.
- Player-side Bone Ward / Colossus guard stay in `DmPlayerRules` / `DmHeroBody._ward` (computed from the living thralls on every hit), not here. Barrier here has no decay (the 6 s duration only).
- Bosses (`DmBoss`) carry a set and show `slow` / `root` / `chill` but the brain ignores them: bosses are immune to them. The damage-taken multipliers do count: `DmBoss.take_damage`
  scales every blow by `scale_taken` like any body (a Marrow Spear's Fracture makes the King take more, an enemy priest's Sanctify less), and `DmCoreHost.damage` reports the scaled blow. The
  brain's own Fracture is a separate source (only the Abbess's broken niches feed it) and multiplies with a player's.
