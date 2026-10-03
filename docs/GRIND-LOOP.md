# The grind loop: rewards at every timescale

The owner's direction (2026-09-29): *"it's really important that there is a continuous dopamine hit to make me
continue to play."* Every feature should feed a reward that lands **every few seconds, every few minutes, every hour
and every day**. When a timescale goes quiet, players stop. This doc lists what each timescale has today, where it
leaks, and the backlog that fixes it, ordered by payoff for effort.

## 1. What exists today

| Timescale | Rewards that land now |
|---|---|
| Seconds | Hit numbers and crits, kill bursts, corpses to spend, loot beams, soul-harvest charge, thralls rising, enemy flinches (hit-react clips) |
| Minutes | Character levels, rare drops, shards from elites, procession banners, Grave Surge chests, skill levels, tool upgrades, cooked meals |
| Hours | Area unlocks, Grimoire rites (levels 2–14), area bosses (first-kill trophy + rare), the Prelate, Damage / Wave Speed tiers |
| Long-term | Ascension ranks and boons, 99 in the skills, gear tiers |

## 2. Where it leaks (fix these first)

1. **XP plateaus above level ~15.** Kill XP scales with *area* level (max 13), but levels cost `level × 100`.
   A level-49 character needs about 1,200 Graves kills per level.
   → **Fixed:** the Plague Cloister is level-scaled (min 20), so XP per kill keeps pace with any level.
2. **Dead items clutter the bag.** Measured on 2026-09-29, these drop but have no use:
   - `seed_mourning_moss`: waits for Grave Gardening (G5);
   - `gem_grave_garnet`, `gem_bone_opal`, `gem_void_sapphire`;
   - `reliquary_fragment`, `covenant_seal`.

   **Selling** exists (bag → Sell / Sell all). **Uses added 2026-10-03**: the Sexton's Contracts ask for the gems, the Fragment and the Seal (relic orders) and for Tin and Bronze Ingots, no migration (`docs/polish/loot.md` item 14; `trade-goods.test.ts` pins that nothing droppable is sell-only). Seeds all have plots already. Recipes, rune sockets and boss keys (§3 #3, #7) remain open.
3. **Crafted duds.** Swiftness, Forge-Tempered and Void Resist flasks did nothing. They are **fixed** (timed buffs).
   `kit_iron_warden` (`resist_blast`) is still inert.
4. **Gold has few sinks** (Damage / Wave Speed tiers only), so it piles up once those are bought.
5. **No "one more run" hook between bosses**: nothing pulls you back tomorrow.

## 3. Backlog, in order

| # | Feature | Why it hooks | Effort | Notes |
|---|---|---|---|---|
| 1 | ~~**Plague Cloister** (level-scaled zone)~~ | XP never plateaus; a new place to explore | L | **Shipped 2026-09-29**, with the Plague Saint |
| 2 | ~~**Loot upgrade chase**~~ | Every drop *might* be better; the core ARPG slot machine | L | **Built 2026-10-02 (branch `dm/affixes`, migration 020)**: server-rolled item level and 0-3 affixes per gear drop (`loot_instances`), necromancer levers, readable tooltips, Vault/Salvage/offline carry the roll. Ranges tuned 2 and 3 Oct (BALANCE.md "Affix tuning": a good drop is a 5-9% upgrade, affixes never outclass a completed set). See HANDOFF. The legacy `item_instance` table was Crossworlds', so the new one is `loot_instances` |
| 3 | **Salvage** gear → materials, and **gems into sockets** (runes brief: `build-depth-aspects-runes.md`) | Gives gems, fragments and duplicate gear a purpose | M | Migration 005 plus a Reliquary panel |
| 4 | **Daily Sexton's Contracts** ("kill 200 in the Nave", "cook 20 meals") → shards and seals | A reason to log in daily | M | Icon `sexton_contract.png` exists (unused) |
| 5 | ~~**Omens**~~ | Novelty, and a reason to replay old zones | M | **Shipped 2026-09-30** (`content/omens.ts`): Blood Moon, Drowned Week and The Tolling rotate each UTC week; effects on elites, wave size, rewards and the sky. The `daily_rite` icon is still unused |
| 6 | **Grave Gardening (G5)**: seeds → herbs → alchemy flasks; tree patches | Offline progress to come back to | M | Roadmap §5; herb and seed icons exist |
| 7 | **Covenant Seals / Reliquary Fragments** as boss keys: summon an *empowered* boss (+HP, guaranteed epic) | Turns rare mats into a chase | S | Reuse the BossBrain level knob |
| 8 | ~~**Kill streak / combo meter**~~ | Moment-to-moment juice | S | **Shipped 2026-09-30** as the Kill Chain (`gameplay/killChain.ts`): 4 s window, five tiers, +5–25% XP and gold, HUD readout, rising chime |
| 9 | ~~**Milestone toasts**~~ | Frequent small wins | S | **Shipped 2026-09-30** (`gameplay/milestones.ts`): kill-count, per-area and best-chain purses, paid once per character in this browser. Permanent bonuses were left out: they need server-side storage |
| 10 | Gold sinks: ~~thrall gear upgrades~~, cosmetic Chapterhouse decorations | Keeps gold meaningful | M | **Thrall gear built 2026-10-02 (branch `dm/thrall-gear`, no migration)**: the Legion kit (two slots, spare weapon and armour become thrall bonuses) and **Reinforce**, 12 gold tiers (120 gold, x1.65 each, about 75k in all) that reset on Ascension. The thrall bow and bone staff models are now used. Chapterhouse decorations remain |

## 4. Rules of thumb for new features

- Every new item must be **usable, sellable or salvageable** on day one; add a test like `processing.test.ts`'s
  "no gathered material is a dead end".
- Every new system should add at least one reward at a timescale that is currently thin.
- Keep performance flat. Measure with `tools/qa/flyers-rites-smoke.cjs` (its perf block).
- Gear is now rolled by the server (item level and affixes, `loot.cjs`); *which* item drops, gold and XP are still client-rolled and the
  server only validates ids and stacks (a friends-game trust model). Don't build anything competitive on top of that without moving
  drops server-side first.
