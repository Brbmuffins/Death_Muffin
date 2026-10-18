# client/next/meta: difficulty, the Omen, Soul Harvest, the Kill Chain

`DmNextMeta` (child `Meta` of `DmNextGame`, host only) owns no rules. It pushes the results to the nodes that act on them; the rules stay in
`DmContent.difficulty`, `DmVowsBoons`, `DmPlayerRules` (souls), `DmKillChain`. **Ascension is not in the game** (DECISIONS B36): the world runs without vows (`vow_fx` is the neutral one, heat 0, so the
rewards' rank is 0 and the corpse life is the base one), no Covenant Boon acts (the Bonded Dead do not rise), and a character's saved vows, boons and Ashes stay on the server, untouched: a build reads its progression without them
(`DmNextGame.without_ascension`). A kill's enemy is a core id.

```
Settings -> difficulty  --set_difficulty-->  director.difficulty, rewards.difficulty, bosses.difficulty
the Omen                --sync()---------->  director (wave size, elites), every rewards member (reward / shard multipliers)
                                             sync() runs from DmNextProgress.apply_progress: on load, on a purchase, after refresh_progress
```

## What each system changes
| System | Effect |
|---|---|
| Difficulty (`easy` / `medium` / `hard`) | enemy hp x0.75 / 1 / 1.2, damage x0.3 / 1 / 1.3, xp / gold / loot x0.75 / 1 / 1.3, elite chance +0 / 0 / +0.02; bosses read it through `DmBossNodeWorld.difficulty()`. Changing it in Settings toasts "the next dead to rise feel it" |
| The Omen | weekly, `DmNextMeta.omen_for(ms)` (`opts.omen` pins it for tests): wave size, elite chance, xp / gold x`rewardMult`, shards x`shardMult` (combat areas only), HUD chip (hidden in sanctuaries); the Tolling forces Bell-Tolled on every elite (the director's affix roll, `client/core/dm_affix_roll.gd`; native/README.md "Affixes") |
| Reaper soul bag | every kill that pays a Reaper (`DmSessionRewards.kill_earned`) banks a soul with a wisp (not Soul Harvest); see `client/next/rites/README.md` |
| Soul Harvest | your own kill (`DmSessionRewards.killer_paid`) banks a soul, for every party member's hero on the host (a joiner's HUD meter reads its caster's replicated `souls` / `soulsMax`, `DmNextHudVm.soul_state`); a full meter charges the next Marrow Spear / Miasma / Black Litany: free, 1.5 x radius / range (`DmRiteCaster._apply_cast` -> `intent["mult"]`). HUD meter + empowered slot flags |
| Kill Chain | `DmKillChain` per member, paid by `DmSessionRewards` (+5..25 % xp / gold); `chain_tier_up` -> banner float, sound, burst; the chain breaks on its 4 s window (sound, "Chain broken: N" from 10) and on death; HUD meter |
| Bone Ward chip | `wardPerThrall` x living thralls, at most 60 % (`DmNextHudVm._ward`) |

The rules for Ascension's parts (the world vows and their heat, the self vows, the boons, the Altar's panel calls) are still in the game's files; `sync()` is where they would be read again when Ascension returns (ROADMAP Phase 3).

## Known gaps
- The Omen's sky tint is not applied (the data has it, nothing reads it).
- The monk's beat meter (KNOWN-GAPS "Disciplines").
- Co-op: the host's difficulty rules the world; a joiner's own progression is not read. A joiner's meter fills, but the "charged" toast, float and burst are the host hero's only.

## Tests / cost
`client/tests/value.gd` plays the meta on the game scene (kills, the purse, brews and lifesteal, the belt, saving) and `client/tests/rites.gd` the Reaper's soul bank. `client/tests/boss_meta.gd` is the boss side. Cost: `DmNextMeta._process` is one compare per frame
(the chain's break); `sync()` runs on a load / purchase, never per frame; the HUD feeds allocate only while a chain is live.
