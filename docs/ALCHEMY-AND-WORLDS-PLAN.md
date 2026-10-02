# Alchemy expansion, necro weapons + new worlds — plan

Drafted 2026-09-30 for the owner. Status: **proposed, not built**. Scope the owner picked: alchemy items 2–5
(buff system, throwables, discovery + quality, sources) and "a couple new worlds / levels", with the goals
*depth, playability, grind, flat performance*. Thrall draughts were left out for now.

## 0. What the live data says (read first)

- Live DB, 2026-09-30: 3 characters, the top one a **level-65 Gravecaller**. Professions barely used:
  woodcutting 11, mining 2, gravedigging 1, **gardening and alchemy 0**.
- Alchemy is gated behind Grave Gardening (herbs only come from real-time plots). That chain is
  why nobody has brewed anything. **Alchemy needs a way in that doesn't start with farming.**
- The highest zone is the Cinder Pyre (scaled, min 30). A level-65 main has **nothing built for its band**:
  the scaled zones keep XP flowing but nothing drops that is better than Pyre loot.
- Bug found while planning: `AbilitySystem.ts:169` hardcodes the damage buff to `1.15`, and
  `WorldScene.ts:2575/3096` read the ward/speed value from one fixed flask. **The Moonlight Elixir gives +15%, not the +25%
  its tooltip promises.** Phase A fixes it.

---

## Part 1 — Alchemy

### A. Brew engine (the foundation; everything else sits on it)

Replace the three hardcoded buffs (`buffUntil.{speed,damage,ward}`) with one effect table.

- `src/content/brews.ts`: `BREWS: Record<itemId, { slot: 'elixir' | 'tonic', effects: { kind, value }[], seconds, label, icon, color }>`.
- **Two slots, one brew each**: *Elixirs* are combat effects, *Tonics* are utility. A new elixir replaces the old one
  (float text: "Moonlit replaces Forge-tempered"). Healing flasks stay separate on **Q** with their 1.5 s cooldown.
  Two slots keep stacking bounded, so balance stays sane.
- Effect kinds (each read at one place in code):

  | kind | where it applies | slot |
  |---|---|---|
  | `damage` | `AbilitySystem.sp` (replaces the 1.15) | elixir |
  | `ward` | `onHurt` ward sum (replaces the fixed flask value) | elixir |
  | `lifesteal` | on player damage dealt → heal % | elixir |
  | `haste` | cooldown recovery rate | elixir |
  | `resist_fire` | `onHurt` when `from` is `ember`/`burn` | elixir |
  | `resist_rot` | rot/plague hits (Cloister, Plague Saint) | elixir |
  | `speed` | `moveMult` | tonic |
  | `essence` | essence regen | tonic |
  | `wisdom` | kill XP % | tonic |
  | `fortune` | item drop chance % (`rollKill`) | tonic |

- **HUD brew tray**: two chips beside the Bone Ward chip (icon, label, countdown ring, tooltip with the exact
  numbers). This makes a potion's effect *visible* (the necro-focus rule: easy to find and understand).
- **Belt keys**: two quick slots on free keys (proposed **Z** = elixir, **X** = tonic; bound in the Inventory
  panel with right-click → "Put on belt"). Settings key list + Codex + onboarding tip on the first brew.
- Existing flasks keep their ids and become table rows; server `stat_bonus` rows unchanged.

### B. Throwables — "concoctions"

A third belt slot, **F** = throw at the cursor. Shared 8 s cooldown so they add to rites, not replace them.
Reuses the Plague Doctor's landing ring (the `flask` event) and the existing status matrix, so VFX cost is low.

| Concoction | Effect | Colour (SPELL_FX language) | Lvl |
|---|---|---|---|
| Blight Bottle | rot pool, Withered stacks for 5 s | chartreuse/olive | 10 |
| Shrapnel Jar | bone burst + Hemorrhage bleed | ivory/amber | 25 |
| Rime Vial | Chill in a radius (−30% move/attack) | cold blue | 40 |
| Censer Bomb | holy fire: ×2 vs wraiths/spirits, lingers 4 s | ember/crimson | 55 |
| Dead Man's Draught | raises every corpse in the radius as a temporary thrall for 8 s | jade/teal | 80 |

Balance target: one throw ≈ one mid rite, measured with `npm run balance` (new `throw` intent in the harness).

### C. Discovery + quality

- **Experiment** tab at the Workbench: put 2–3 ingredients in the alembic. A hidden recipe is **learned**
  permanently (server table `alchemy_known`, migration 013) and appears in a new Codex section *Alembic Notes*.
  A wrong mix makes **Muddy Sludge**. It sells, and it works as garden fertiliser (−10% grow time), so a failed
  experiment is never a dead end.
- Roughly half the new recipes are discovery-only; the Codex shows "???" slots with a one-line hint
  ("Something from the fire, something that grows in rot").
- **Quality**: the server rolls on craft. *Fine* (+25% duration, 20% base chance, +1% per level over the
  requirement) and *Perfect* (+50%, only above level 90). Stored as **separate item ids** (`elixir_moonlight_fine`) so the stack
  inventory and client-rolled loot need no item-instance rework. Only elixirs, tonics and concoctions get
  quality tiers, not heals, to cap the id explosion (~30 ids).
- This gives the skill a real 72→99 tail: Perfect brews and the last discoveries.

### D. Sources, so alchemy is reachable and feeds the grind

- **Mob reagents** (new drops, weight ~6–10 in their areas). This is the way in that doesn't need gardening:

  | Reagent | Drops from | Used in |
  |---|---|---|
  | Grave Dust | Graves/Warren commons | starter brews, Blight Bottle |
  | Wraith Ectoplasm | wraiths, Mourner-type spirits | Rime Vial, haste elixir |
  | Plague Bile | Cloister | resist_rot elixir |
  | Cinder Ash | Pyre | resist_fire elixir, Censer Bomb |
  | Boss ichors (one per boss) | area bosses, guaranteed | top-tier / Perfect-only recipes |

- **Zone-only herbs**: Rot-cap (Cloister) and Ash-bloom (Pyre) as gather nodes in their zones; their seeds drop
  there too and can then be grown in the Acre. The new Fen (Part 2) brings two more.
- A **starter brew** at level 1 from Grave Dust + Mourning Moss, and a tip at the first reagent drop that
  points to the Workbench.
- The contracts board already picks up alchemy output (`candidatesFor`); add reagents to the pool.
- Rule (GRIND-LOOP §4): every new item is usable, sellable or salvageable. Add them to the
  "no dead-end materials" test.

---

## Part 2 — New worlds

Three zones, recommended in this order. Each follows the Pyre template: a `content/areas.ts` entry, a door,
a roster of ≤4 new enemies plus reused ones, one boss on `BossBrain`, and loot that feeds alchemy.

### W1. The Mourning Fen — level-scaled, min 45

- **Where**: west of the Drowned Nave (free space x −60…−20, z −100…−58), door off the Nave's west wall,
  unlock 800 Pyre kills.
- **Feel**: a drowned graveyard marsh, cold-blue/teal (Mourner colours), heavy fog, wisps. **Bog water slows**
  (reuse the Nave water + wading code); dry hummocks are safe ground, so positioning matters.
- **Roster**: Bog Hag (caster, curses thralls: −30% thrall damage, a necro counter-play), Mire Leech swarm
  (reuse the Ossuary Swarm behaviour), Wisp (flyer, reuses the flyer tech; lures you into deep water), Drowned
  Sexton (elite brute, drags players), plus reused wraiths.
- **Boss**: *The Mire Mother*. She sinks and resurfaces under a random hummock; phase 2 floods the arena
  (hummocks shrink); phase 3 she raises drowned thralls from *your* corpses.
- **Loot**: Fen herbs (Bog Myrtle, Drowned Lotus) + seeds, Wraith Ectoplasm, the next gem tier, level-45+ armour.
- **Art**: 4 enemies + boss via Tripo ≈ 900 credits (balance ~6,330), 4 herb/reagent icons via Gemini.

### W2. The Catacomb Depths — endless descent (best grind per unit of effort)

> **Built 2 Oct 2026 on `dm/depths` (not deployed, no migration).** Deviations from the text below: enemy level is `max(12, hero) + depth` (a level-20 floor is a wall for the Warren's first visitors; see `content/depths.ts`); the Chronicle already had a best-value JSON, so the best depth is `peak.depth` there (no column, no table, no leaderboard rewrite beyond one column on the public page); floors are a seeded 3x3 grid with up to two chambers filled in; the Depths are solo for now. Details: HANDOFF.md "Catacomb Depths", BALANCE.md, README.

- **Where**: a stair in the Catacomb Warren. It's an *instance*, not a map region: floors are assembled from
  the Warren's chamber kit (walls, `Nav.addSightBlocker`) with a seeded layout.
- **Loop**: each floor = clear N kills → the stair opens. **Depth d** = enemy level `max(20, player) + d`, plus one
  new affix every 5 floors (from the existing elite-affix pool). Rewards scale per depth; a chest every 5.
  Dying ends the run; best depth goes on the **Chronicle** leaderboard (the table already exists).
- **Why it grinds**: "one more floor", a number that goes up, a leaderboard between friends. It reuses the whole
  enemy roster, so **no new art** is needed.
- **Performance**: small rooms and a hard cap of ~24 alive keep it the cheapest zone on the GPU.

### W3. The Hollow Court — endgame capital, min 60

- **Where**: south of the Bell Sanctum (z < −136). It opens after the Mire Mother *and* the Cinder Regent.
- **Feel**: the Covenant's ruined basilica, violet ritual magic, gold leaf over bone.
- **Roster**: Lich Acolyte (from FUTURE_CONTENT: raises **your dead thralls** against you), Court Inquisitor
  (silence), Gilded Knight (shield wall), Bone Choir (reused wraith behaviour).
- **Boss**: *The Hollow Bishop*, a mirror necromancer who commands a thrall legion. It's the capstone
  for the necro line.
- **Loot**: Moon ore/ingots, the top armour tier, boss ichor for Perfect-only brews.
- **Art** ≈ 1,000 credits.

### Performance guardrails (all zones)

- Enemy cap ≤ 30 (Pyre 28), wave size ≤ 10; reuse instanced props; new enemies reuse existing rigs/clips
  where possible; **no new per-frame systems** (bog slow reuses wading).
- Each zone ships with a perf entry measured with `tools/qa/flyers-rites-smoke.cjs` against the Graves roster
  baseline (198 calls / 280k tris / 0.99 ms); a regression beyond +10% blocks the deploy.
- Brew engine: effects are read where damage/move already compute, O(1) per hit, with no timers per effect.

---

## Part 3 — Necromancer first: weapons, animation, gear

The owner (2026-09-30): *the necromancer is the staple of this game and should be the most polished.* Today:

- Necros have **one weapon item** (`staff_oak`, +5 int). The other weapon kinds are generic (sword/bow).
- Every weapon is a **code-built primitive** (`graphics/gearProps.ts`: boxes and cylinders, tier-tinted). The only
  real necro weapon mesh, `props/gear_bone_staff.glb`, belongs to thralls.
- Each necro hero has **one `cast` and one `attack` clip** shared by every spell and weapon (clips.json:
  cast, attack, idle, walk, run, dig, hurt, hurt2, death, death2).

### N0. Visual + feel audit (do first, it's cheap)

A screenshot/clip matrix per discipline (Gravecaller, Ossuary, Mourner, Rotweaver) × weapon kind ×
{idle, run, cast, attack, hurt, death}, plus both armor collections and capes. Check: grip alignment
(`Creature.attach` follow), weapon tip = spell origin, clipping with capes/armor, root travel, slide during
casts, readability at game zoom. Every defect → a fix list; nothing ships on "looks fine in code".

### N1. Necro weapon line — each kind *plays* differently

A weapon changes the **LMB primary (Bone Needle)** and one passive, so a weapon swap is a build choice,
not just a stat stick. Five tiers per kind (bone → iron → gold → hell → moon), from drops, bosses and Smithing/Carpentry.

| Kind | Hands | Primary change | Passive | Suits |
|---|---|---|---|---|
| **Staff** | 2H | Needle +25% range, pierces 1 | +10% spell damage | Ossuary, all-rounder |
| **Scythe** | 2H | LMB becomes a close reaping arc (hits 3) | kills in the arc give +1 soul | Gravecaller (fights beside thralls) |
| **Wand** + off-hand | 1H | Needle cadence +30%, −15% damage | — | pairs with an off-hand |
| **Ritual Sickle** + off-hand | 1H | Needle applies 1 Withered stack | Exhume refunds 20% essence | Rotweaver |
| Off-hand **Skull Focus** | OH | — | +1 thrall cap at gold+ | Gravecaller |
| Off-hand **Grimoire** | OH | — | −10% rite cooldowns | any |
| Off-hand **Mourning Bell** | OH | — | wraith hits heal allies +2% | Mourner |

~35 items (4 main-hand kinds × 5 tiers + 3 off-hands × 5 tiers). Items/recipes via one generated migration
(the armor-sets pattern: `tools/generate-*.mjs` → SQL + icons, server rows carry stats).

**Models**: replace the primitives with 7 Tripo static meshes (one per kind, ~50 credits each ≈ 350), tinted per
tier by the existing `gearTier` material logic, so one mesh covers five tiers. Each keeps `userData.tip` for the spell origin.

### N2. Combat animation pass

- New clips per necro hero, retargeted onto the existing rigs (10 credits/clip): **staff slam** (2H cast),
  **scythe sweep**, **one-hand flick** (wand/sickle), **channel** (Litany/Dirge), **summon** (Exhume/raise). 4
  heroes × 5 ≈ 200 credits. Measure hip height before trusting a preset (the `hurt` = lying-clip lesson);
  run `stripRootTravel` on every new clip.
- A clip-selection table `(weaponKind, abilityId) → clip`, so a scythe Gravecaller swings and a wand
  Mourner flicks. Default falls back to today's `cast`/`attack`.
- Replace the retired `hurt` usage with `hurt2` or a short flinch; check both death clips.

### N3. Feel polish

Cast wind-ups that match the clip's release frame (projectile leaves the weapon tip on the frame the arm extends),
a weapon trail on scythe/sickle arcs (reuse the Binbun trail), hit-stop on scythe multi-hits, per-weapon cast sounds.

---

## Build order (recommended; necro first)

| # | Phase | Size | Server work |
|---|---|---|---|
| 1 | **N0. Necro visual/feel audit** + fix list | S | none |
| 2 | **A. Brew engine** + Moonlight fix + HUD tray + belt | M | none (client) |
| 3 | **N1 + N2. Necro weapons + animation pass** | L | generated items migration |
| 4 | **D-lite**: reagent drops + starter brew + 6–8 new brews | S–M | migration (items/recipes) |
| 5 | **B. Concoctions** + **N3 feel polish** | M | items/recipes |
| 6 | **W1. Mourning Fen** + Mire Mother + Fen herbs | L | items/recipes; realtime BOSS_IDS |
| 7 | **C. Discovery + quality** | M | `alchemy_known` table + craft-roll change in `/api/craft` |
| 8 | **W2. Catacomb Depths** | M–L | Chronicle depth column |
| 9 | **W3. Hollow Court** + Hollow Bishop | L | as W1 |

Tripo budget: necro weapons ~350 + clips ~200 + Fen ~900 + Court ~1,000 ≈ **2,450** of ~6,330.

Each phase ships on its own: tests, QA smoke, perf block, a deploy from a clean HEAD checkout, a rollback snapshot.

## Open questions for the owner

1. Belt keys Z / X / F OK?
2. Should quality tiers exist (more ids, more chase), or should discovery alone be the tail?
3. Depths before the Fen? It's cheaper and has no art cost, but the Fen feeds alchemy.
4. Hollow Court boss is a mirror necromancer. Keep it, or do you have a different endgame villain in mind?
