# Legendary sets (build-defining, Diablo-style)

Owner request (2026-10-02): "gear sets that really define how you play, like Diablo". Approved plan: one rare legendary
set per necromancer discipline (necromancer first), five pieces (head, chest, hands, legs, feet — the existing armor parts).
2 pieces = a nudge, 4 pieces = changes a mechanic, 5 pieces = defines the build. Tuned up on 2 Oct 2026 (first live values were weaker: harness mean ×1.13 clear speed / ×0.96 damage taken → now ×1.17 / ×0.86; at the intended band clear speed is spawn-limited, so the gain shows as survival). Other families get theirs later.

| Set id | Name | Discipline | 2 pieces | 4 pieces | 5 pieces |
|---|---|---|---|---|---|
| `legion_unburied` | Legion of the Unburied | Gravecaller | Thralls hit +25% harder | Thralls attack +10% faster; **thralls burst on death** (`thrallDeathBurst` 0.8 of their max HP) | **Legion Champion**: +2 thrall cap (`thrallCap`), every 4th thrall is a Champion (`championEvery` 4), Marrow Spear rallies the legion (`spearRally` 1) |
| `colossus_mantle` | Colossus Mantle | Ossuary | Thralls have +35% health and hit +15% harder | **Bone Ward reflects** 60% of what it blocks (`wardReflect` 0.6) | **Colossus**: 30% less damage taken with 3+ thralls (`colossusGuard` 0.3), Litany barrier shatters for 4x its size (`litanyShatter` 4) |
| `requiem_wraiths` | Requiem of Wraiths | Mourner | +40% essence regeneration, +10% max health | **Wisps**: consuming a corpse summons a healing wisp for 10 s (`corpseWisp` 10) and heals 2% max health (`corpseHeal` 0.02) | **Requiem**: Soul Harvest fills 2x faster (`soulHarvestRateMult` 2), thralls attack +15% faster, empowering a rite makes every wraith/wisp nova (`wraithNova` 1.2) |
| `plague_choir` | Plague Choir | Rotweaver | Miasma is +25% wider, +8% max health | **Contagion**: deaths in Miasma spread Withered (`miasmaSpreadsWithered` 1) | **Chain Plague**: at 8 Withered stacks an enemy bursts into a new Miasma (`witheredBurstAt` 8) |

Contract (commit on `dm/legendary-base`): the mechanics are `DisciplineMods` fields in `src/content/disciplines.ts`, all numeric
with 0 = off (`soulHarvestRateMult` is a multiplier, 1 = normal), and `SetAddKey` / `SetMultKey` in `src/content/setBonuses.ts`
accept them, so a set bonus folds them in through the existing `applySetMods` / `withSetBonuses` path. Data/drops/UI and the
sim mechanics are built separately against this contract. Migration number reserved: **025** (024 is relic runes).

## Drop rules (polish pass, 2026-10-03)

Boss 7% per kill (Ossuary onward), elite 0.3% in the scaled areas, 70% of drops are your discipline's set. A drop now **favours pieces you do not hold**
(`pickLegendaryItem(..., owned)`: worn or in the bag; the Vault is not asked), so a set fills in about five drops instead of the eleven a uniform pick
needs, and a repeat only follows a full set. The server's ground-rate ceiling for a legendary piece lost its one-in-five discount for the same reason
(the piece you are missing can take every drop of its set). `owned` is read only when a legendary actually drops.
