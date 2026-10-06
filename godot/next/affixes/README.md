# DmAffixSet: elite affixes (Bell-Tolled, Hungering, Shrouded, Vengeful)

A child node `Affixes` of the `DmEnemy`, created by the director's spawn function (every peer) only on bodies that carry an affix, so a normal enemy has no
node and no per-frame cost. Numbers: `DmSimData.AFFIX_TUNING`; looks and sounds: the current game's (`DmEntityViews._dress_affix` / `_affix_moment`).
`DmAffixSet.of(body)`, `has(kind)`, meta `dm_affix_list` (PackedStringArray; the target frame / HUD chips read it), `dm_affixes` (count, Depths).

## Rolling (`DmAffixSet.roll`, `DmWaveDirector.spawn`)
Elite: the Omen's affix if it forces one (the Tolling: Bell-Tolled), else one of the four; in the Depths plus `pick_extra_affixes` (one more every 5
depths, max 3 extra, distinct). The Depths run passes its own roll as `over.affix_list` (omen first). Non-elite: Nightfall's shroud (`NIGHTFALL_SHROUD_CHANCE`,
once per pick, the whole pack). Replicated in the spawn data (`affix_list`).

## Rules (host only, `_physics_process`; not while rising / stunned / burrowed, like the sim)
| affix | rule |
|---|---|
| Bell-Tolled | every 6 s a ring (r 3) is telegraphed for 0.9 s at the body's spot (the enemy's `telegraph` signal, kind `toll`, so `DmEnemyFx` draws it), then every hero / thrall inside takes blow x 0.6 (`dm_take_enemy_hit` kind `toll`) |
| Hungering | every 4 s (retry 0.5 s) while hurt: the nearest corpse within 5 m is consumed through `DmCorpseField.consume(id, 1, "devoured")` (atomic: a rite that got there first wins) and heals 15% max hp (capped at the missing hp); fewer corpses for the necromancer's rites |
| Shrouded | the `shrouded` status (taken x 0.5 through `DmStatusSet.scale_taken`, opacity 0.38); lifted while a friendly Miasma / rot cloud covers it (`rite_miasma` stamps meta `dm_miasma_ms` on bodies flagged `dm_shrouded`, held 0.35 s); `strip_shroud()` removes it for good (Last Light / Warden sweep) |
| Vengeful | on death 3 `risen` on a 1.4 m ring around the fall, as strong as the body (level / hp / damage multipliers), spawned by the host through the director |

## Look / moments (every peer, exactly once)
Persistent rings at spawn (bell ring, drool glow, shroud glow, vengeful cracks; killed on death), 10 Hz motes only within 30 m of the camera (drool, embers, shroud wisps).
One-off beats (`tell` | `toll` | `hungering` | `vengeful` | `unveil`) are a reliable RPC from the host (`Affixes/_rpc_moment`), played locally on the host; the `moment`
signal fires on each peer once per beat. `vfx` / `audio` are instance vars (tests inject counting back-ends).

## Cost (tests/next_affixes: 30 enemies, 6 affixed elites)
Frame median +0.1 ms headless (noise level); the component tick is ~3 us for all four affixes; the shroud check runs at 10 Hz, motes at 10 Hz.

## Target-frame chips
`DmNextHudVm._affix_chips` (next/hud) reads `dm_affix_list` (set on every peer by `attach`, so a joined client has it; `strip_shroud` updates it).

## Not done
The floating "+N" heal number (the `moment` carries the position; the amount is the hp change),
wiring `strip_shroud()` to the rebuilt Last Light / Warden rites if/when they exist.
