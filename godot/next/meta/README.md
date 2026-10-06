# godot/next/meta: difficulty, vows, boons, the Omen, Soul Harvest, the Kill Chain

`DmNextMeta` (child `Meta` of `DmNextGame`, host only) owns no rules. It reads the character's progression (`DmProgression`: vows, boons) and pushes the
results to the nodes that act on them, the way `DmGame` did through `sim.difficulty`, `sync_world_vows`, `g.omen` and `rewards.chain`. Rules stay in
`DmContent.difficulty`, `DmAscension` / `DmVowsBoons`, `DmPlayerRules` (souls), `DmKillChain`.

```
Settings -> difficulty  --set_difficulty-->  director.difficulty, rewards.difficulty, bosses.difficulty
prog (vows, boons)      --sync()---------->  director (vow_fx, omen, size_extra), bosses.vow_fx, rewards (heat, vow_levels, per-member omen), corpse life
                                             sync() runs from DmNextProgress.apply_progress: on load, on a purchase, after refresh_progress (the Altar)
```

## What each system changes (numbers are the current client's)
| System | Effect |
|---|---|
| Difficulty (`easy` / `medium` / `hard`) | enemy hp x0.75 / 1 / 1.2, damage x0.3 / 1 / 1.3, xp / gold / loot x0.75 / 1 / 1.3, elite chance +0 / 0 / +0.02; bosses read it through `DmBossNodeWorld.difficulty()`. Changing it in Settings toasts "the next dead to rise feel it" |
| World vows (`scope: world`) | Elder Dead: +3 levels a rank (enemies, boss and Surge rewards); Iron Dead hp x1.25; Swollen Waves wave size x1.25; Deacon Host deacon weight x(1+rank); Elite Surge +8 % elites; Thin Graves corpses -25 %; Prelate Echo -> `DmBossNodeWorld.echoes()`. Swearing a different set clears the hunting grounds |
| Heat (world vows) | `rewards.ascension`: xp and gold x(1 + 0.05 heat), capped at heat 30; carried in the kill reports as `rank`. An old save's rank N is N steps of Elder Dead (the backend maps it) |
| Self vows (`scope: self`) | Frail Vessel, Famished, Brittle Thralls, Dry Cellar reach the hero through `DmCharacterBuild` (stats, regen, thrall hp; the belt reads `noFlasks`) |
| Boons | all through `DmCharacterBuild` -> `DmHeroBody.refresh_stats` + `DmRiteCaster.refresh_stats`: Vigil (max hp), Marrow Font (essence regen), Legion Pact (+1 thrall cap), Grave Feast (corpse heal on Exhume / Offering), Bone Ward (ward per thrall), Hollow Sacrifice / Carrion Bloom (caster mods), Soul Hunger (Soul Harvest meter -8 a rank, min 10), Lingering Dead (corpse life x1.5 a rank, `corpses.life_mult`), Bone Tithe / Quickened Coin (upgrade prices, `DmProgression`), Swift Seals (seal kills), First Rites / Shard Keeper (the starting tier / shards after an ascension), Bonded Dead (a thrall rises 1.5 s after entering a hunting ground with none: `DmNextMeta._bonded_dead`) |
| The Omen | weekly, `DmNextMeta.omen_for(ms)` (the same rotation as `DmGame._omen_for`; `opts.omen` pins it for tests): wave size, elite chance, xp / gold x`rewardMult`, shards x`shardMult` (combat areas only), HUD chip (hidden in sanctuaries) |
| Soul Harvest | your own kill (`DmSessionRewards.killer_paid`) banks a soul; a full meter charges the next Marrow Spear / Miasma / Black Litany: free, 1.5 x radius / range (`DmRiteCaster._apply_cast` -> `intent["mult"]`). HUD meter + empowered slot flags |
| Kill Chain | `DmKillChain` per member, paid by `DmSessionRewards` (+5..25 % xp / gold); `chain_tier_up` -> banner float, sound, burst; the chain breaks on its 4 s window (sound, "Chain broken: N" from 10) and on death; HUD meter |
| Bone Ward chip | `wardPerThrall` x living thralls, at most 60 % (`DmNextHudVm._ward`) |

## The Altar
The Ascension panel (`DmUiPanelsA`) calls `api.necro_ascend / necro_vows / necro_unlock / necro_boon` itself and then `refresh_progress()`; the rebuild's
`refresh_progress` adopts the backend state (`DmProgression.adopt` -> `synced` -> `DmNextProgress.apply_progress` -> `DmNextMeta.sync`), so a vow, a boon or an
ascension reaches the world at once, online and offline alike. `DmNextUiHost.do_ascend() / do_swear(vows) / do_open(key)` are the same calls without the
panel (each returns "" or the Altar's refusal); ascend and swear flush the pending kills first, because the run's tally decides the Ashes. A `vow:` / `boon:` key
opens it with shards, a bare boon id buys the next rank with Ashes.

## Not here
- Elite affixes: the Tolling's Bell-Tolled elites (`omen.affix`) wait for the affix track; the Omen's sky tint is not applied by the current client either.
- Soul Harvest's wraith nova on a charged cast (legendary `wraithNova`), the jade ring under a charged hero, the monk's beat meter.
- Co-op: the host's difficulty and vows rule the world; a joiner's own progression is not read (REBUILD phase 4).

## Test / cost
`godot --headless --path godot --script res://tests/next_meta/run.gd` (offline backend, two accounts; relaunches). Cost: `DmNextMeta._process` is two compares per frame
(chain break, Bonded Dead timer); `sync()` runs on a load / purchase, never per frame; the HUD feeds allocate only while a chain is live.
