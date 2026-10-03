# Legendary sets (build-defining, Diablo-style)

Owner request (2026-10-02): "gear sets that really define how you play, like Diablo". Approved plan: one rare legendary
set per necromancer discipline (necromancer first), five pieces (head, chest, hands, legs, feet — the existing armor parts).
2 pieces = a nudge, 4 pieces = changes a mechanic, 5 pieces = defines the build. Tuned up on 2 Oct 2026 (first live values were weaker: harness mean ×1.13 clear speed / ×0.96 damage taken → now ×1.17 / ×0.86; at the intended band clear speed is spawn-limited, so the gain shows as survival). Other families get theirs later.

| Set id | Name | Discipline | 2 pieces | 4 pieces | 5 pieces |
|---|---|---|---|---|---|
| `legion_unburied` | Legion of the Unburied | Gravecaller | Thralls hit +10% harder | **Bursting Dead**: Thralls attack +10% faster · Thralls burst when they die (100% of their health as damage to enemies around them) | **Legion Champion**: Thralls have +40% health · +2 thrall cap · Every 4th thrall you raise is a Champion (bigger, with 2x damage and health) · Marrow Spear rallies your legion: every thrall charges the target and hits +100% harder for 4 s |
| `colossus_mantle` | Colossus Mantle | Ossuary | +8% maximum health · Thralls have +50% health · Thralls hit +30% harder | **Reflecting Ward**: 8% less damage taken per thrall · Bone Ward reflects 100% of the damage it blocks back at the attacker | **Colossus**: +10% maximum health · Black Litany barrier +4% max health per corpse · 35% less damage taken while 3 or more thralls stand · When the Black Litany barrier breaks it shatters into bone shards for 6x its size |
| `requiem_wraiths` | Requiem of Wraiths | Mourner | +20% maximum health · +70% essence regeneration | **Wisps**: Thralls have +30% health · Consumed corpses heal +4% max health · Consuming a corpse summons a healing wisp for 14 s | **Requiem**: Thralls hit +70% harder · Thralls attack +30% faster · Soul Harvest fills 3x faster · When Soul Harvest empowers a rite, every wraith and wisp releases a nova (600% of your spell power) |
| `plague_choir` | Plague Choir | Rotweaver | +12% maximum health · Miasma is +40% wider | **Contagion**: +3 max Withered stacks · Enemies that die in your Miasma spread their Withered stacks to enemies nearby | **Chain Plague**: +8% maximum health · Miasma is +25% wider · An enemy that reaches 8 Withered stacks bursts into a new Miasma cloud (stack cap at least 8) |

Contract (commit on `dm/legendary-base`): the mechanics are `DisciplineMods` fields in `src/content/disciplines.ts`, all numeric
with 0 = off (`soulHarvestRateMult` is a multiplier, 1 = normal), and `SetAddKey` / `SetMultKey` in `src/content/setBonuses.ts`
accept them, so a set bonus folds them in through the existing `applySetMods` / `withSetBonuses` path. Data/drops/UI and the
sim mechanics are built separately against this contract. Migration number reserved: **025** (024 is relic runes).

## Drop rules (polish pass, 2026-10-03)

Boss 7% per kill (Ossuary onward), elite 0.3% in the scaled areas, 70% of drops are your discipline's set. A drop now **favours pieces you do not hold**
(`pickLegendaryItem(..., owned)`: worn or in the bag; the Vault is not asked), so a set fills in about five drops instead of the eleven a uniform pick
needs, and a repeat only follows a full set. The server's ground-rate ceiling for a legendary piece lost its one-in-five discount for the same reason
(the piece you are missing can take every drop of its set). `owned` is read only when a legendary actually drops.
