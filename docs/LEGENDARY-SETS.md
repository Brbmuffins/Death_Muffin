# Legendary sets (build-defining, Diablo-style)

Owner request (2026-10-02): "gear sets that really define how you play, like Diablo". Approved plan: one rare legendary
set per necromancer discipline (necromancer first), five pieces (head, chest, hands, legs, feet — the existing armor parts).
2 pieces = a nudge, 4 pieces = changes a mechanic, 5 pieces = defines the build. Other families get theirs later.

| Set id | Name | Discipline | 2 pieces | 4 pieces | 5 pieces |
|---|---|---|---|---|---|
| `legion_unburied` | Legion of the Unburied | Gravecaller | Thralls hit +15% harder | **Thralls burst on death** (`thrallDeathBurst` 0.6 of their max HP) | **Legion Champion**: +2 thrall cap (`thrallCap`), every 5th thrall is a Champion (`championEvery` 5), Marrow Spear rallies the legion (`spearRally` 0.75) |
| `colossus_mantle` | Colossus Mantle | Ossuary | Thralls have +25% health | **Bone Ward reflects** 40% of what it blocks (`wardReflect` 0.4) | **Colossus**: 25% less damage taken with 3+ thralls (`colossusGuard` 0.25), Litany barrier shatters for 3x its size (`litanyShatter` 3) |
| `requiem_wraiths` | Requiem of Wraiths | Mourner | +30% essence regeneration | **Wisps**: consuming a corpse summons a healing wisp for 8 s (`corpseWisp` 8) | **Requiem**: Soul Harvest fills 2x faster (`soulHarvestRateMult` 2), empowering a rite makes every wraith/wisp nova (`wraithNova` 0.8) |
| `plague_choir` | Plague Choir | Rotweaver | Miasma is +15% wider | **Contagion**: deaths in Miasma spread Withered (`miasmaSpreadsWithered` 1) | **Chain Plague**: at 10 Withered stacks an enemy bursts into a new Miasma (`witheredBurstAt` 10) |

Contract (commit on `dm/legendary-base`): the mechanics are `DisciplineMods` fields in `src/content/disciplines.ts`, all numeric
with 0 = off (`soulHarvestRateMult` is a multiplier, 1 = normal), and `SetAddKey` / `SetMultKey` in `src/content/setBonuses.ts`
accept them, so a set bonus folds them in through the existing `applySetMods` / `withSetBonuses` path. Data/drops/UI and the
sim mechanics are built separately against this contract. Migration number reserved: **025** (024 is relic runes).
