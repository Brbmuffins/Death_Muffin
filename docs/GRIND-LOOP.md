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
   → **The Plague Cloister** is level-scaled (min 20) so XP per kill keeps pace with any level. Bosses and Ascension help today.
2. **Dead items clutter the bag.** Measured on 2026-09-29, these drop but have no use:
   - `seed_mourning_moss`: waits for Grave Gardening (G5);
   - `gem_grave_garnet`, `gem_bone_opal`, `gem_void_sapphire`;
   - `reliquary_fragment`, `covenant_seal`.

   **Selling** now exists (bag → Sell / Sell all). Real uses still need designing (§3).
3. **Crafted duds.** Swiftness, Forge-Tempered and Void Resist flasks did nothing. They are **fixed** (timed buffs).
   `kit_iron_warden` (`resist_blast`) is still inert.
4. **Gold has few sinks** (Damage / Wave Speed tiers only), so it piles up once those are bought.
5. **No "one more run" hook between bosses**: nothing pulls you back tomorrow.

## 3. Backlog, in order

| # | Feature | Why it hooks | Effort | Notes |
|---|---|---|---|---|
| 1 | **Plague Cloister** (level-scaled zone) | XP never plateaus; a new place to explore | L | In flight 2026-09-29; see HANDOFF |
| 2 | **Loot upgrade chase**: item level + affix rolls on drops (e.g. "+8% needle damage"), rarity beams already exist | Every drop *might* be better; the core ARPG slot machine | L | Needs server item_instance rows (the table exists) |
| 3 | **Salvage** gear → materials, and **gems into sockets** (runes brief: `build-depth-aspects-runes.md`) | Gives gems, fragments and duplicate gear a purpose | M | Migration 005 plus a Reliquary panel |
| 4 | **Daily Sexton's Contracts** ("kill 200 in the Nave", "cook 20 meals") → shards and seals | A reason to log in daily | M | Icon `sexton_contract.png` exists (unused) |
| 5 | **Omens**: weekly world modifiers (Blood Moon: +elites, Drowned Week: water everywhere, Tolling) | Novelty, and a reason to replay old zones | M | Icons `art/omens/*` exist (unused) |
| 6 | **Grave Gardening (G5)**: seeds → herbs → alchemy flasks; tree patches | Offline progress to come back to | M | Roadmap §5; herb and seed icons exist |
| 7 | **Covenant Seals / Reliquary Fragments** as boss keys: summon an *empowered* boss (+HP, guaranteed epic) | Turns rare mats into a chase | S | Reuse the BossBrain level knob |
| 8 | **Kill streak / combo meter** (nearest-kill chain → temporary XP and gold bonus, audio escalation) | Moment-to-moment juice | S | Client-only; hook onKill |
| 9 | **Milestone toasts**: first 1k kills in an area, 100 elites, and so on, with small permanent bonuses | Frequent small wins | S | Codex journal already stores discoveries |
| 10 | Gold sinks: thrall gear upgrades, cosmetic Chapterhouse decorations | Keeps gold meaningful | M | Thrall gear models exist (unused) |

## 4. Rules of thumb for new features

- Every new item must be **usable, sellable or salvageable** on day one; add a test like `processing.test.ts`'s
  "no gathered material is a dead end".
- Every new system should add at least one reward at a timescale that is currently thin.
- Keep performance flat. Measure with `tools/qa/flyers-rites-smoke.cjs` (its perf block).
- Loot is client-rolled and the server only validates ids and stacks (a friends-game trust model). Don't build
  anything competitive on top of it without moving drops server-side first.
