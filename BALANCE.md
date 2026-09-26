# Crossworlds — Balance targets & current numbers

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

## Co-op session dashboard (planned)

Easy/Medium/Hard is the first slice of this. The remaining knobs (Wave Speed tier, enemy HP/damage multipliers, density, elite chance, surge
frequency, arrival-wave size, roster weights) should become a **host-side session dashboard for
co-op rooms**. See `FUTURE_CONTENT.md` → "Co-op session dashboard".
