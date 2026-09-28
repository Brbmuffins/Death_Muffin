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

### Open issues
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
