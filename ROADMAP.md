# Death Muffin — Roadmap

*Updated 2 October 2026. The player guide is [README.md](README.md); build status and history are in [HANDOFF.md](HANDOFF.md).*

The roadmap below runs left to right. **Now** is the next build session, **Next** follows it, and **Later** is waiting for a decision or for the earlier work. Each box links to a section below.

```mermaid
flowchart LR
  classDef done fill:#2d4a2f,stroke:#7fd18b,color:#e8ffe9
  classDef now fill:#4a2d5c,stroke:#c6a4ff,color:#f4ecff
  classDef next fill:#2f3550,stroke:#8fa8ff,color:#eef1ff
  classDef later fill:#3a3a3a,stroke:#9a9a9a,color:#eeeeee

  subgraph SHIPPED["✅ Shipped"]
    S1[1 Oct: weapons, brews, Fen,<br/>five rite slots, Offline Edition]:::done
    S2[2 Oct: 48-slot bag · Vault · Salvage]:::done
    S3[2 Oct: gear you can read<br/>upgrade arrows · sheet J]:::done
    S4[2 Oct: combat audio · strike timing]:::done
    S5[2 Oct: visible Grave Laborers]:::done
    S6[2 Oct: armor set bonuses]:::done
  end

  subgraph NOW["🔨 Now — being built"]
    N2[Necro spell feel]:::now
    N3[Balance pass<br/>Ossuary · Wave Speed · spiky zones]:::now
    N5[Tool belt]:::now
  end

  subgraph POLISH["✨ Next — polish"]
    P5[Animation pass<br/>clipping · sliding · crowds]:::next
    P6[Second polish round<br/>re-run audits]:::next
  end

  subgraph LATER["🌒 Later — new content"]
    L0[Alchemist's Wing]:::later
    L1[Item level + affixes]:::later
    L2[New zones]:::later
    L3[Server authority]:::later
    L4[AI companions — parked]:::later
  end

  SHIPPED --> NOW --> POLISH --> LATER
```

## 📒 Progress log

Newest first. Each entry is a live release (`release.txt` on the site shows the deployed commit).

| Date | Shipped | Notes |
|---|---|---|
| 2 Oct 2026 | Armor set bonuses at 2/4/5 pieces for all 18 sets (necro sets drive thralls, ward, essence, Miasma, Withered); upgrade arrows and verdicts count set bonuses ("completes your 4-piece" / "breaks your 2-piece"); Set bonuses on the Character sheet and a Codex Armor sets tab | Table in docs/ARMOR-SETS.md. |
| 2 Oct 2026 | Visible Grave Laborers: assigned thralls work their node in the Sexton's Acre (chop, mine, dig, fish) with the right tool, a ready badge, hover details and click-to-open (H) | Uses the dig/chop clips retargeted onto the four thrall rigs. |
| 2 Oct 2026 | 48-slot bag; Ossuary Vault (V, 120 shared slots); Bone Grinder salvage + Salvaging skill; item locks; Sell all junk; gear stat effects, ▲/▼ upgrade arrows, verdict line, Character sheet (J) with "What you're looking for"; combat audio (CC0 samples, capped mixer, Combat/Ambience/Interface sliders); strike timing; old starter gear no longer stacks | Migrations 017 (vault) and 018 (gear unstackable). Thrall dig/chop clips built for the laborers (90 Tripo credits). |
| 1 Oct 2026 | Necro weapons, brewing and reagents, Mourning Fen, five swappable rite slots, Offline Edition with complete save sync, Leave the world at the top of Settings | Codex cleanup; `deploy-release.sh` became the only deploy path. |

**Owner approvals in force:** deploy when all checks pass; push after a secret scan; up to 1,500 Tripo credits without asking (spent so far against it: 0); keep following this roadmap.

**Principle (owner, 1 Oct 2026):** polish and improve what exists before adding more. The game should be immersive but not overwhelming. The necromancer is the main class; the other classes are bonus work.

**Legend:** 🟪 Now · 🟦 Next · ⬜ Later · 🟩 shipped

---

## 🔨 Now

### N1 · Inventory relief
*Problem: the bag fills in minutes. It has 24 slots, there is no storage, and selling is one stack at a time.*

| Piece | What it does |
|---|---|
| **Bigger bag** | 24 → 48 slots. The 0–23 slot range is hard-coded in the server's save, add-item, contracts, gathering and offline sync, so it changes in one place first (a shared `BAG_SLOTS`). |
| **The Ossuary Vault** | A stash in the Chapterhouse: 120 slots shared by your characters, with tabs. Deposit-all-materials and stack-merge buttons. |
| **Salvage** | A **Bone Grinder** station in the Acre turns unwanted gear into **Scrap** and **Bone Dust** by rarity. Scrap feeds Smithing and Carpentry upgrades; Bone Dust feeds Alchemy. It becomes a small profession (*Salvaging*) with levels that raise the yield. |
| **Quick clean-up** | Reliquary buttons: *Sell all junk*, *Salvage all below rare*, and a lock icon to protect items from both. |

### N2 · Gear you can read
*Problem: gear shows STR / AGI / INT / VIT but never says what they do for you.*

Today the four stats feed these formulas (`src/gameplay/characterStats.ts`):

| Stat | What it gives |
|---|---|
| **VIT** | +8 max health each |
| **INT** | +1.3 spell power, +2 max essence, +0.1 essence/s each |
| **STR** | +0.4 spell power each |
| **AGI** | +0.2 spell power, +0.3% move speed each |
| *(thralls)* | Thrall health = 45% of yours; thrall damage = 40% of your spell power |

- **Plain-language tooltips:** "+6 VIT → +48 health", with green or red **compared to what you wear**.
- **Character sheet (paper doll):** final health, spell power, essence, speed and thrall strength, each with a breakdown (base, level, gear, upgrades, boons) you can hover.
- **Necro weapon effects** listed beside the stats, as the Codex does now.

### N3 · Armor set bonuses (built on `dm/set-bonuses`, see docs/ARMOR-SETS.md)
The 18 armor sets (90 pieces) are themed but have **no set bonus**. Add 2-, 4- and 5-piece bonuses per set that support its discipline (for example, Ossuary: thralls take less damage; Mourner: wraith healing). Show them in the tooltip with a "3 / 5 worn" tracker.

---

## ✨ Next — polish what exists

### P1 · Necro spell feel
Every necromancer rite should look and sound necromantic: bone, grave dirt, soul-light and rot rather than generic magic. Keep each spell's meaning colour (`SPELL_FX`) but add necro motifs (bone shards, spectral hands, skull wisps, ground sigils), keep effects readable in a crowd, and cap particle counts so a full legion never turns into noise.

### P2 · Visible Grave Laborers
Assigned laborers appear as thralls at their node in the Sexton's Acre and work it: chopping, mining, digging, fishing, picking herbs, with the matching tool. Thrall models have no work clips yet; retargeting chop, dig and mine onto the four thrall rigs costs about 120 Tripo credits.

### P3 · Zone and encounter polish
Driven by measurements, not guesses: the necromancer balance run across all nine hunting grounds, the clip audit, and the loot audit (what fills the bag). Results and the resulting fixes are listed here as they land.

**Necromancer balance run (2 Oct 2026, 4 disciplines × 9 hunting grounds × 4 seeds, 3 min each):**
- At the intended pressure the necromancers are healthy almost everywhere (0–1.8 deaths per 3 min).
- **Max Wave Speed is a trap.** 5–11 deaths per 3 min, first death after 5–20 s, and kills per minute *fall* to a third or less of the intended band (Nave Gravecaller 109 → 16/min). The top tiers should pay more for good play, not less. Fix: retune the tier 6–8 pressure curve and surge sizes so a careful player out-earns the intended band.
- **Ossuary, the defensive discipline, dies most under pressure** (8–11.5 deaths at max). Its shieldbearers soak until they die, then the caster is exposed. Candidates: Bone Ward per living thrall, or a thrall HP floor.
- **Coliseum and Sanctum spike at arrival level**; Mourner dies even at the intended band there (1.8–2.5 deaths). Check their elite rate and greeting waves.
- **Bag pressure:** gathering tools (24 kinds) do not stack and the best one you carry counts, so tools hold 4+ bag slots. A small tool belt would free them.


### X1 · The Alchemist's Wing
A dedicated room off the Chapterhouse: cauldrons and alembics as brewing stations, reagent shelves showing what you have found, a drying rack for herbs, and an NPC apothecary who hands out brewing orders. Art goes through the existing Gemini → Tripo pipeline (`ASSET_PIPELINE.md`; about 6,300 Tripo credits left). Brewing moves from the Workbench tab into the room, and the room becomes the home of higher-tier recipes (discovery, quality, concoctions from `docs/ALCHEMY-AND-WORLDS-PLAN.md`).

### X2 · Combat feel and animation pass (P5)
Keep the art style; make motion smoother. Practical steps, in the order that pays most:

0. **Found 1 Oct 2026: attacks are out of sync.** Enemy wind-ups last 0.38–1.3 s, but the attack clip is played at a fixed 1.6× speed (`EntityViews.ts`), so its impact frame shows about 1.3 s in (main clip) or about 0.3 s in (the random second variant). Damage therefore lands before or after the visible swing, and the clip is cut when the enemy walks again. Fix (code only): bake each clip's measured impact time (`tools/measure-clips.mjs`) into a table, scale each swing so its impact lands at the end of the wind-up, and let the follow-through finish before blending to walk. Quadruped rigs (bone hound, skull rat, cinderhound) need the tool taught their bone names.
1. **Measure first.** `tools/clip-sheet.mjs` and `tools/measure-clips.mjs` produce a contact sheet and numbers for every clip. Rank the worst clipping and sliding.
2. **Weapon and prop clipping:** per-weapon grip offsets, hide the off-hand during two-handed clips, and fit per-model attach points.
3. **Foot sliding:** scale walk and run clip speed to actual movement speed.
4. **Blends:** longer locomotion crossfades (0.18 s → about 0.3 s) while attacks stay snappy, and a short additive flinch instead of swapping to a full hurt clip.
5. **Crowds:** stronger separation and steering so packs do not stack, plus formation slots for thralls around the caster.
6. **Impact:** a two- or three-frame hitstop on heavy hits, eased knockback, and a death "settle" into the ground.
7. **Replace the worst Tripo clips** with retargeted library clips where measurements say they are beyond fixing.

### X3 · Loot item level and affixes
Already the next item in the grind loop (`docs/GRIND-LOOP.md` §3 #2). Items roll an item level and affixes on the server, so each drop is a real upgrade decision. It depends on N2, which makes stats readable.

### X4 · Open audits
- Four-discipline visual audit (`tools/qa/necro-audit.cjs`, run one discipline at a time).
- Audio has never been checked by ear.
- New Blood classes level 4–8× slower than necromancers in bot runs; check with a human before retuning.

---

## 🌒 Later

### L1 · AI companions (parked)
*Parked on 1 October 2026. The cost study below is kept for when this comes back: event-driven decisions on Claude Haiku 4.5, bots online only while a player is in the world, and a hard daily spend cap come to about $10–20 a month for three bots.*

Two or three bot players you can log in and play with. Recommended design:

- **Body:** a lightweight Node "player" that speaks the same realtime protocol as a browser (move, cast intents, chat), with no rendering. It reuses the existing Easy auto-combat brain (`src/gameplay/autoCombat.ts`) for moment-to-moment fighting. It is cheap enough to run several on the VPS.
- **Mind:** an LLM (Claude Haiku) decides every 10–30 seconds: follow you, hold a chokepoint, gather, return to town, and talks in chat with a persona. It never controls frame-by-frame input.
- **Accounts:** each bot is a real account and character with its own progress, flagged as a bot. Bots only join worlds you invite them to.
- **Decisions needed:** how strong bots should be, whether they loot or level, and the API budget.

### L2–L4
- **New zones:** Catacomb Depths and the Hollow Court (`docs/ALCHEMY-AND-WORLDS-PLAN.md`).
- **Content with paid art ready:** the Bone Colossus, runes (needs a migration), thrall gear.
- **Server authority:** today the browser is trusted for level, gold and loot (fine among friends). Move rewards to the server before opening to strangers.

---

## 🧹 Housekeeping
- Seven `zz_*` test accounts in the live database (owner to delete).
- Six merged worktrees in `wt/` and about 11 GB of old update zips in `vps-handoffs/DeathMuffin/` (owner to delete).
- Old one-off deploy scripts that build from stale trees (`deploy-afk.sh`, `deploy-update.sh`); `server/death-muffin/deploy-release.sh` replaces them.
