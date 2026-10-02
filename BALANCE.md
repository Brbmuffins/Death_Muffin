# Crossworlds — Balance targets & current numbers

## Easy auto combat browser pass (2026-09-28, undeployed)

The owner wants Easy to be an automated, powerful farming mode. Easy auto now engages enemies across the current combat area, dodges nearby windups, uses every equipped New Blood rite and signature when useful, drinks flasks, and recovers 2% max HP/s while under attack. Hollow Knight and Veilwalker auto gain 30% ward between their defensive abilities. Veilwalker phases under pressure instead of draining its meter against every lone enemy. Easy enemies deal 0.3× Medium damage (previously 0.6×); Medium and Hard enemy damage is unchanged. Manual movement, targets, menus, and gathering still take control.

The offline browser drove the **real scene and auto policy**, starting fresh level-1 characters in the Graves with Easy auto on for three minutes (`tools/qa/easy-auto-balance.cjs`, browser random seed 43). These are one-run samples, not a statistical guarantee:

| Class | Kills / 3 min | Deaths | Healing flasks used | End HP |
|---|---:|---:|---:|---:|
| Ossuary necromancer | 291 | 0 | 0 | 190/190 |
| Grave Warden | 138 | 0 | 1 | 101/128 |
| Bell Monk | 122 | 0 | 0 | 111/128 |
| Carrion Witch | 109 | 0 | 0 | 111/128 |
| Hollow Knight | 119 | 0 | 0 | 128/128 |
| Veilwalker | 72 | 0 | 0 | 114/114 |

The Knight row is a repeat after its guard change; the Veilwalker row is a repeat after its ward and phase policy changes. The other rows ran before those class-specific changes. A second final Veilwalker run (seed 44) made 69 kills with zero deaths and zero flasks. One earlier run with the old Veilwalker policy died at 141 seconds. These short, level-1 Graves samples do not establish later-area or long-session survival. The headless Medium numbers below use a different scripted bot, so they should not be compared directly with the Easy browser rows.

## New Blood simulation (2026-09-28)

The report includes discipline indices 5–9. The updated bot uses the real `Player` resource and damage rules, class arcs, Witch crows, Veil form, and available defensive rites. **Graves / intended / 3 minutes / seeds 42–44** produced:

| Class | Kills/min | Mean deaths | Earliest first death |
|---|---:|---:|---:|
| Grave Warden | 27.6 | 6.7 | 13 s |
| Bell Monk | 23.7 | 7.0 | 8 s |
| Carrion Witch | 26.9 | 4.7 | 17 s |
| Hollow Knight | 12.9 | 8.3 | 12 s |
| Veilwalker | 29.1 | 1.7 | 23 s |

The established Ossuary necromancer bot made 96.9 kills/min with no deaths under the same settings. That comparison exposes a large solo farming gap, but the policies differ: the necromancer fights behind thralls, while the new-family bot walks into range and never dodges, drinks flasks, or retreats from packs. Its level-1 melee classes cannot use their later defensive rites. The 3-seed geared Graves and Ossuary runs also showed repeated new-class deaths. These are release risk signals, not calibrated player outcomes; a human combat pass and a bot with movement and defensive timing are needed before tuning damage or enemy health from this table.

The full **medium / 3-minute / seeds 42–44** run on 2026-09-28 covered all four areas and all four bands (`BALANCE_SEEDS=3 npm run balance`). Intended-band results below are **kills per minute / mean deaths**. The four necromancer disciplines made 70.6–126.7 kills/min and averaged 0–1.3 deaths across these areas.

| Class | Graves | Ossuary | Nave | Sanctum |
|---|---:|---:|---:|---:|
| Grave Warden | 27.6 / 6.7 | 35.0 / 6.7 | 25.4 / 8.7 | 21.3 / 8.3 |
| Bell Monk | 23.7 / 7.0 | 25.6 / 8.3 | 19.6 / 10.0 | 14.3 / 9.3 |
| Carrion Witch | 26.9 / 4.7 | 22.1 / 7.3 | 11.2 / 11.3 | 16.0 / 7.7 |
| Hollow Knight | 12.9 / 8.3 | 14.0 / 7.7 | 9.1 / 10.0 | 6.6 / 9.0 |
| Veilwalker | 29.1 / 1.7 | 19.0 / 6.3 | 16.1 / 7.7 | 13.6 / 6.7 |

At geared Wave Speed 3, every new class still averaged at least 5.3 deaths in every area. This bot currently skips Shield Bash, Grave Slam, Resonant Step, Knell, Choir, Chain Pull, Cremate, Hook Pull, Hex Charm, and Echo; it therefore understates several kits' offense and control. It also enters close combat without reacting to telegraphs. The next balance pass should exercise those rites and movement before setting numeric buffs, followed by a human playtest.

## Necro pass (2026-10-02)

Four necromancer disciplines x nine hunting grounds x `intended,geared,push,max`, **8 seeds, 3 sim-minutes**
(`BALANCE_SEEDS=8`; the report now also prints `1st med`, the median seed's first death, because the
min-over-seeds `1st†s` is set by one unlucky seed). "Old" = the code at the start of the pass with only the
harness fix below, so the comparison is like for like.

### What was wrong (measured, not guessed)
1. **A harness bug hid part of the problem.** When an enemy stood exactly on the bot, the back-off step divided
   0 by 0 and the bot's position became NaN for the rest of the run: no kills, no damage, no deaths (seen as
   rows with ~0 kills/min and 0 deaths at max). Fixed in `harness.ts`. The true old max band is *worse*
   than the baseline table in the ROADMAP: mean 7.8 deaths per 3 min (max 12.1).
2. **Past tier ~3 more density is pure danger.** The bot clears about 100 bodies/min and the base wave rate is
   already about that, so at tier 8 (supply 2.9x) the field just sat at the cap (peak 60-72 enemies vs ~40 at
   the intended band). Kills/min do not rise with supply; they fall as deaths climb. Per-enemy HP x1.24,
   damage x1.28 and +6.4% elite chance stacked on top.
3. **Death was a spiral.** After a death the whole mob stayed in the area; the caster walked back in 12 s later
   with no thralls and no corpses into the pile that killed it (lives of 10-20 s, 5-11 deaths).
4. **The second wave landed ~4 s in** at tier 8 (interval 3 s): first deaths at 5-8 s, before a single thrall.
5. XP did not scale with Wave Speed at all, so tier 8 could never out-earn the intended band in XP.

### What changed
| Change | Where | Why |
|---|---|---|
| Density terms (interval, cap, wave size) climb at full rate to tier 3 and at **0.55x** after (`densityTier`) | `upgrades.ts` | tiers 0-3 are unchanged (the healthy rows); past that, extra supply only piles up |
| Per-enemy terms gentler: HP +1.8%/tier (was 3), damage +2.6% (was 3.5), elite +0.4% (was 0.8) | `upgrades.ts` | tier 8: HP x1.14, damage x1.21, elites +3.2% |
| **XP scales with the dial**: +5%/tier, +15% Nightfall (tier 8: x1.55). Gold stays +10%/tier, +25% Nightfall | `upgrades.ts`, `loot.ts` | rewards keep climbing while density levels off: that is the pay for the risk |
| **Ramp**: Wave Speed builds linearly over the first 30 s of a visit (`rampTier`); the arrival wave is a plain greeting; Vanguard/Nightfall appear as the ramp passes their tier | `WorldSim.ts` | first deaths were 5-8 s in, with no legion up yet |
| **Vacant areas crumble**: no living player in an area for 8 s removes its enemies (no loot) and the next arrival gets a fresh greeting wave | `WorldSim.ts` | breaks the death spiral; a death now costs the 12 s respawn plus rebuilding the legion, not the whole run |
| Ossuary: thrall HP x1.6 -> x2.0, Bone Ward 6% -> 10% per thrall (3 thralls: 18% -> 30%) | `disciplines.ts` | the caster is protected for longer after the shieldbearers' first losses |
| Mourner: thrall HP x0.9 -> x1.0, corpse heal 8% -> 10% | `disciplines.ts` | weakest necro in Coliseum/Sanctum at the intended band |
| Coliseum elite chance 16% -> 13% | `areas.ts` | smaller arrival spike; the farm rate and gold are kept |
| `report.ts`: area column widened (the `coliseum` rows ran into the band name and were dropped by greps); `1st med` column | `report.ts` | |
| Guard tests | `__tests__/balance-necro.test.ts` | curve shape, arrival ramp, vacancy, and the target rows |

`necro-rules.cjs` was regenerated (it bundles `areas.ts`; only the Coliseum elite chance changed).

### Results (means over the 4 necromancers x 9 areas, 8 seeds; ratios are to the *intended* band of the same row)
| Band | | kills/min | gold/min | XP/min | deaths / 3 min | median first death |
|---|---|---|---|---|---|---|
| max (tier 8) | old | 0.54x | 1.34x | 0.61x | **7.8** (max row 12.1) | 8-34 s |
| max (tier 8) | **new** | **1.18x** | **2.50x** | **1.84x** | **2.1** (max row 3.4) | 41-161 s |
| push (tier 6) | old | 0.79x | 1.51x | 0.90x | 5.7 | 19-57 s |
| push (tier 6) | new | 1.21x | 2.03x | 1.60x | 1.7 | 47-180 s |
| geared (tier 3) | old | 1.30x | 2.12x | 1.55x | 1.3 | |
| geared (tier 3) | new | 1.41x | 2.13x | 1.80x | 0.4 | |

Per area at max (deaths old -> new): Graves 4.1 -> 0.5, Warren 4.4 -> 1.3, Ossuary 6.1 -> 2.4, Coliseum 10.0 -> 2.8,
Nave 9.7 -> 2.4, Sanctum 9.8 -> 2.5, Cloister 8.9 -> 2.5, Pyre 9.2 -> 2.4, Fen 8.2 -> 2.1.

Target rows (per discipline; kills/min, gold/min, XP/min, deaths, median first death):
| Row | old max | new max | intended (unchanged) |
|---|---|---|---|
| Nave Gravecaller | 30 / 695 / 544 / 9.9 / 7 s | 104 / 2298 / 2772 / 2.5 / 33 s | 107 / 1143 / 1879 |
| Nave Ossuary | 34 / 637 / 512 / 11.8 / 8 s | 150 / 3185 / 3937 / 2.5 / 54 s | 125 / 1384 / 2251 |
| Nave Mourner | 28 / 719 / 566 / 9.6 / 7 s | 111 / 2491 / 3009 / 2.6 / 40 s | 90 / 1018 / 1668 |
| Nave Rotweaver | 45 / 1220 / 940 / 7.4 / 9 s | 100 / 2330 / 2861 / 2.1 / 36 s | 103 / 1147 / 1879 |
| Sanctum Gravecaller | 25 / 1208 / 984 / 9.1 / 21 s | 79 / 3199 / 4209 / 2.8 / 38 s | 80 / 1680 / 2877 |
| Coliseum Ossuary | 47 / 727 / 627 / 12.1 / 12 s | 185 / 2765 / 3614 / 3.4 / 35 s | 178 / 1916 / 3248 |
| Coliseum Mourner | 35 / 802 / 647 / 9.8 / 11 s | 102 / 2207 / 2797 / 2.9 / 25 s | 82 / 1030 / 1717 |

Max by discipline (mean of 9 areas): Ossuary 10.1 -> **2.2** deaths, Gravecaller 7.3 -> 2.2, Mourner 7.2 -> 2.0,
Rotweaver 6.6 -> 2.0. Ossuary is now level with the others rather than the worst; it is still the top earner
(143 kills/min vs ~100) as it was at the intended band (111 vs 87-95).

Intended band (healthy rows): kills/min, gold and XP are within +-10% of the old numbers in every one of the
36 rows (the largest moves are Coliseum Mourner/Rotweaver kills +16%, from fewer spiral deaths). Intended deaths
per 3 min: Coliseum Ossuary 1.9 -> 0.9, Mourner 1.5 -> 1.0, Rotweaver 1.4 -> 0.5; Sanctum Mourner 1.9 -> 0.9,
Gravecaller 1.0 -> 0.3; every row is now at most 1.0.

Bosses: `npm run balance:boss` (3 seeds) is unchanged for Gravecaller and Rotweaver (dodgers win 166-173 s; non-dodgers
wipe). Ossuary (higher thrall HP and Bone Ward) wins 1 in 6-8 non-dodging intended runs with ~2% boss HP left
(was 0/6); Mourner is unchanged.

Other classes (indices 5-9, 4 seeds, Graves/Ossuary/Nave/Sanctum, intended and max): nothing broke. They
benefit from the same wave/ramp/vacancy rules; max-band deaths fall from 8.8-13.5 to 4.8-8.8 and kills/min roughly
double. Their intended-band gold moved -30% to +30% on 4 seeds (noise; the bot still dies 5-8 times per run, see the
New Blood section above), so these rows are not retuned.

### Closed open issues
- Gravecaller weakest under pressure: gone (all four at 2.0-2.2 deaths at max; the spiral was the cause).
- Ossuary discipline swings hardest: now level with the others (see above).
- Nave at max Wave Speed kills arrival-level bots within ~5 s: median first death 40 s, deaths 9.7 -> 2.4.

### Still open
- Death at max is a smaller spiral, not none; the bot has no flasks/dodging, so a human should land lower.
- Ossuary's win rate against a non-dodging Prelate rose from 0 to ~1 in 6-8.
- A human playtest of tier 6-8 (ramp, vacancy greeting waves, XP) is still needed.
- The vacancy rule means leaving an area for 8+ s and coming back triggers a fresh greeting wave (a small, bounded farm).


`npm run balance` drives the real `WorldSim` with a scripted necromancer bot
(`src/gameplay/balance/harness.ts`) and prints one row per area × level band ×
discipline. The bot is **an upper bound on kill efficiency** (perfect targeting,
instant reactions) but **never dodges telegraphs**, so its damage taken from
penitent cones and Bell-Tolled rings is higher than a careful player's.

```bash
npm run balance                                  # 3 simulated minutes per row, seed 42
BALANCE_SEEDS=3 npm run balance                  # average seeds 42..44 (use this for decisions)
BALANCE_AREAS=nave BALANCE_BANDS=push,max npm run balance
```

Columns: `hurt%/m` damage taken per minute as % of max HP · `minHp` lowest HP
reached · `1st†s` seconds to the first death (`-` = survived) · `unlock m`
minutes of kills to open the next area. Deaths model the real respawn: 4 s in
the Chapterhouse plus ~8 s to waystone back.

## Level bands (defined in `report.ts`)

| Band | Who | Level | Damage tiers | Wave Speed |
|---|---|---|---|---|
| intended | just arrived | area level | ≈0.6 × level | 0 |
| geared | settled in | area level + 3 | ≈0.9 × level | 3 |
| push | greedy | area level | ≈0.6 × level | 6 |
| max | reckless | area level | ≈0.6 × level | 8 |

## Targets

| Band | hurt%/m | minHp | Deaths / 3 min | Feel |
|---|---|---|---|---|
| intended | 10–60 | 30–80 | 0 | Pressure you notice; a mistake costs a flask, not a life. (Graves is the tutorial: low end.) |
| geared | 5–40 | ≥ 25 | 0 (≤ 0.5) | Comfortable farming — you're paying for Wave Speed 3 with levels. |
| push | 50–250 | 0 | 0.5–4 | Dangerous: the bot (no dodging) dies occasionally; a dodging player rarely. |
| max | 150+ | 0 | 3+ | Arrival-level power at max Wave Speed should kill a careless player. Owning tier 8 costs ~14k gold, so real players arrive far stronger. |
| pacing | — | — | — | Bot opens the next area in 3–5 min (humans ≈ 5–8). |

## Current numbers (2026-09-26, 3 seeds, after the first balance pass)

Ranges across the four disciplines:

| Area | intended hurt%/m · minHp | geared hurt%/m | push hurt%/m · deaths | max deaths | unlock (bot) |
|---|---|---|---|---|---|
| Hollow Graves | 4–22 · 51–75 | 4–13 | 47–98 · 0.3–1 | 0–6 | 3.1–3.5 min |
| Marrow Ossuary | 8–20 · 48–81 | 10–58 | 88–271 · 1.3–5 | 2.3–11 | 3.4–3.6 min |
| Drowned Nave | 24–54 · 0–61 | 18–39 | 122–317 · 1.3–6.3 | 8–11 | 3.9–5.3 min |
| Bell Sanctum | 5–26 · 0–80 | 2–9 | 173–202 · 2.7–3.3 | 3.3–8.3 | — |

Before this pass (same harness, 1 seed): intended 0–15 hurt%/m everywhere,
unlock in 2.7–3.7 min, and push/max either harmless (Graves, Sanctum) or a
13–27-death spiral (Ossuary, Nave).

### What changed
- Trash is tougher and hits harder (HP ×1.4, damage ×1.25; penitent cone 16 → 18):
  the Bone Needle was killing a Grave Robber in under a second at 11 m, so nothing ever arrived.
- Denser waves: cap/wave size Graves 28/9, Ossuary 32/10, Nave 34/11, Sanctum 26/8 (interval 7.5 → 6.5 s).
  Nave roster shifted slightly from penitents toward robbers and hounds.
- Wave Speed compounds less: interval +12%/tier (was 16), cap +9% (12), wave size +6% (12),
  enemy damage +3.5% (5). Throughput at tier 8 is ≈2.9× base instead of 4.3×.
- The first-visit arrival wave is a fixed 1.3× greeting that ignores the Wave Speed dial (was 1.6× × dial).
- Unlock thresholds 200/280/360 → 300/420/520 kills (unlocks already earned stay unlocked).

### Open issues (2026-09-26; the first three are closed by the 2026-10-02 necro pass above)
- **Gravecaller is the weakest discipline under pressure** (worst push/max rows in every area):
  warriors with 0.85× HP die fast, and five of them don't ward the caster. Candidates: Bone Ward
  per thrall, or a thrall HP floor.
- **Ossuary discipline swings hardest.** Shieldbearers soak everything until they die, then the
  caster is exposed (0 damage at intended, most deaths at max).
- **Nave at max Wave Speed** still kills arrival-level bots within ~5 s of the greeting wave.
  It's acceptable for the reckless band, but it's the harshest spot in the game.
- A human-played session is still needed to calibrate how far below the bot's efficiency real players land.

## The Bell-Sworn Prelate (`npm run balance:boss`)

`src/gameplay/balance/boss.ts` summons the Prelate with a full legion already raised and fights
until it dies, the bot dies (a solo death resets the boss), or 6 minutes pass. Each discipline
runs twice: **dodging** (steps out of toll/slam/rain circles after a 0.35 s reaction) and **not
dodging**. The bot carries 4 major flasks (70%, 1.5 s cooldown) and drinks below 40% HP.

**Targets:** at arrival level, a careful player wins in 2.5–3.5 min with some HP to spare, and one
who ignores telegraphs dies. Geared players finish in about 2 min and can brute-force it with flasks.

**First pass (2026-09-26):** base HP 4200 → 26000 (solo ≈ 95k at level 13). Party scaling is now
+80% per extra player (was +60%), because four players deal ~4× damage while the Prelate splits its
attacks. Bell Rain uses the sim's seeded RNG (it used `Math.random`), so fights are reproducible.

| Band | Dodge | Result (3 seeds × 4 disciplines) | Kill time | Min HP | Flasks |
|---|---|---|---|---|---|
| intended (lvl 13) | yes | 12/12 wins | 154–175 s | 31–39% | 0.3–1.3 |
| intended | no | 0/12 — wipes with the boss at 3–17% | — | 0 | 4 |
| geared (lvl 16) | yes | 12/12 | 110–122 s | 34–56% | 0–0.7 |
| geared | no | 12/12 | 113–124 s | 29–35% | 3.3–4 |

Before: every row won in 16–30 s. Direct hits (Needle and Marrow Spear, with Fracture) do ~75% of the
damage and Withered ~20%. Adds from the processions barely matter (0–10% of damage taken), which
makes them a candidate for a bigger role later. `src/gameplay/__tests__/balance.test.ts` guards the
intended-band rows.

## Wave Speed milestones

At tier 3 **Elite Vanguard** guarantees an elite in every other regular wave. At tier 6 **Restless Crypts**
multiplies the surge interval by 0.6. At tier 8 **Nightfall** shrouds 50% of common spawns and adds
+0.25 reward / +0.2 item chance. The first draft (an elite in *every* wave, *all* commons shrouded)
pushed the push band to 0.5–8.5 deaths and dropped max-band gold below push. With the softened
version, push is 0.5–9 deaths / 3 min (mostly 1–5) and max stays the reckless band (2–13.5 deaths,
first death in 6–38 s).

## Difficulty (Easy / Medium / Hard)

`content/difficulty.ts`. Medium is everything above. Enemies and the Prelate get HP × and damage ×,
kills/surges/Prelate give gold + XP ×, and Hard adds +2% elite chance. It's picked in Settings. The
world keeper's value runs the sim and rides in snapshots (older hosts → medium), and changes apply to
new spawns. Harness: `BALANCE_DIFFICULTY=easy|hard npm run balance` (also `balance:boss`).

| | HP | Damage | Rewards | Farming (intended band) | Prelate (intended, 3 seeds) |
|---|---|---|---|---|---|
| Easy | 0.75 | 0.6 | 0.75 | Graves 1–11 %HP/min, Nave 18–48; no deaths even at push in the Graves | everyone wins in ~2 min, even without dodging |
| Medium | 1 | 1 | 1 | see tables above | dodgers win in ~2.7 min; non-dodgers die |
| Hard | 1.2 | 1.3 | 1.3 | Nave 56–96 %HP/min, occasional deaths; Sanctum 15–77 | dodgers win in ~3.4 min using every flask; non-dodgers die |

## Ascension

`content/ascension.ts`. Each rank adds +3 levels to every enemy, toxic pool and the Prelate, and +5%
gold/XP. `BALANCE_ASCENSION=N` runs both harnesses with the bands anchored on the aged level. At matching
level, Ascension III plays like the base game: Graves 0–21 %HP/min, Nave 22–36; the Prelate falls in
~2.3 min for dodgers and still kills 3 of 4 disciplines who don't dodge. In practice characters arrive
over-levelled for the early areas of a new run (level, gear and gold persist), which is intended: early
seals go fast, and the aged late areas catch up. Ashes per run: 10 for the first Prelate kill,
+5 per extra kill (max 4), +2 per peak Wave Speed tier, +1 per 300 kills (max 15), ×(1 + 0.25·rank).
Boons are per-character only: stats, costs, thrall cap, Soul Harvest, unlock thresholds.

## Co-op session dashboard (planned)

Easy/Medium/Hard is the first slice of this. The remaining knobs (Wave Speed tier, enemy HP/damage multipliers, density, elite chance, surge
frequency, arrival-wave size, roster weights) should become a **host-side session dashboard for
co-op rooms**. See `FUTURE_CONTENT.md` → "Co-op session dashboard".


## Mourning Fen vs Cinder Pyre (2026-09-30, 8 seeds, 3 sim-minutes, same level in both)

The Fen is a level-scaled area (min 45), so it is compared with the Pyre at equal player levels (45 and 65) rather than at the area floors.
`npx vite-node src/gameplay/balance/fenCompare.ts` reproduces it; the bot also wades the bog at the real slow (x0.78), as a hero would.
Target: danger similar to the Pyre, XP/min about 10-15% higher (enough to reward going there).

    kills = kills/min, xp = XP/min, hurt = damage taken as % of max HP per minute, deaths per 3 min
    L45 Gravecaller intended | pyre kills 90 xp 13219 hurt 46 deaths 0.4 | fen kills 81 xp 14854 hurt 74 deaths 0.9 | xp ratio 1.12
    L45 Gravecaller geared   | pyre kills 128 xp 22953 hurt 67 deaths 0.6 | fen kills 105 xp 23529 hurt 109 deaths 1.5 | xp ratio 1.03
    L45 Ossuary     intended | pyre kills 100 xp 14249 hurt 29 deaths 0.3 | fen kills 96 xp 17853 hurt 44 deaths 0.3 | xp ratio 1.25
    L45 Ossuary     geared   | pyre kills 156 xp 27481 hurt 52 deaths 0.8 | fen kills 144 xp 31917 hurt 99 deaths 0.9 | xp ratio 1.16
    L45 Mourner     intended | pyre kills 79 xp 11689 hurt 72 deaths 1.3 | fen kills 83 xp 14575 hurt 57 deaths 0.4 | xp ratio 1.25
    L45 Mourner     geared   | pyre kills 98 xp 17394 hurt 124 deaths 2.5 | fen kills 110 xp 24673 hurt 93 deaths 0.8 | xp ratio 1.42
    L45 Rotweaver   intended | pyre kills 84 xp 12418 hurt 65 deaths 1.0 | fen kills 84 xp 15909 hurt 70 deaths 0.8 | xp ratio 1.28
    L45 Rotweaver   geared   | pyre kills 106 xp 19097 hurt 106 deaths 1.6 | fen kills 107 xp 25747 hurt 63 deaths 0.5 | xp ratio 1.35
    L65 Gravecaller intended | pyre kills 94 xp 20696 hurt 36 deaths 0.4 | fen kills 88 xp 24397 hurt 36 deaths 0.3 | xp ratio 1.18
    L65 Gravecaller geared   | pyre kills 143 xp 35589 hurt 44 deaths 0.3 | fen kills 122 xp 37817 hurt 62 deaths 0.5 | xp ratio 1.06
    L65 Ossuary     intended | pyre kills 100 xp 20959 hurt 13 deaths 0.1 | fen kills 99 xp 24457 hurt 18 deaths 0.0 | xp ratio 1.17
    L65 Ossuary     geared   | pyre kills 165 xp 40539 hurt 26 deaths 0.1 | fen kills 151 xp 44123 hurt 66 deaths 0.8 | xp ratio 1.09
    L65 Mourner     intended | pyre kills 95 xp 20313 hurt 28 deaths 0.1 | fen kills 88 xp 23236 hurt 53 deaths 0.4 | xp ratio 1.14
    L65 Mourner     geared   | pyre kills 134 xp 33104 hurt 48 deaths 0.4 | fen kills 126 xp 39029 hurt 55 deaths 0.6 | xp ratio 1.18
    L65 Rotweaver   intended | pyre kills 95 xp 19529 hurt 32 deaths 0.3 | fen kills 95 xp 25708 hurt 27 deaths 0.0 | xp ratio 1.32
    L65 Rotweaver   geared   | pyre kills 149 xp 36838 hurt 54 deaths 0.4 | fen kills 125 xp 37682 hurt 47 deaths 0.3 | xp ratio 1.02

Level 65 (the live top band): XP/min is +14% on average (range 1.02-1.32, bot noise is large), hurt%/min is at or below the Pyre at `intended`
and 10-40 points above it when `geared` (wave speed 3 fills the bog with leeches), deaths stay at or under 0.8 per 3 minutes. Level 45 runs
hotter on XP (+23%; the Fen's XP is a flat per-kill table, and the bot's kill rate differs most at lower gear); left as is (it is the
entry band). Tuning that got here: leech 4 dmg / 22 hp / 4.2 speed / 5 XP, hag 12 dmg / 24 XP, wisp 9 dmg / 19 XP, sexton 25 dmg / 54 XP, cap 24.
