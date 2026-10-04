# Death Muffin — Roadmap

*Updated 3 October 2026. The player guide is [README.md](README.md); build status and history are in [HANDOFF.md](HANDOFF.md).*

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
    S6[2 Oct: armor set bonuses · tool belt]:::done
    S7[2 Oct: necro balance pass]:::done
    S8[2 Oct: guide NPCs + Next line]:::done
    S9[2 Oct: Alchemist's Wing · affixes · audio 2]:::done
    S10[2 Oct: necro spell feel · animation pass]:::done
    S11[2 Oct: Wing dressed · Sexton's spade]:::done
    S12[2 Oct: animation 2 — hitstop · knockback · settle]:::done
    S13[2 Oct: Blender pipeline — new rat + cinderhound gaits]:::done
    S14[2 Oct: first-hour polish]:::done
    S15[2 Oct: Blender round 2 — hound · gargoyle wings]:::done
    S16[2 Oct: gear tuning]:::done
    S17[2 Oct: balance re-audit · boss tuning]:::done
    S18[2 Oct: zone + encounter polish]:::done
    S19[2 Oct: server authority step 1 — report mode]:::done
    S20[2 Oct: readability round 3]:::done
    S21[2 Oct: thrall gear — the Legion]:::done
    S22[2 Oct: QA suite reliability · run-all]:::done
    S23[2 Oct: relic runes · Bone Colossus]:::done
    S25[2 Oct: Catacomb Depths]:::done
    S24[2 Oct: legendary armor sets]:::done
    S26[2 Oct: performance round 1<br/>culling · slim assets · streaming]:::done
    S27[3 Oct: performance pass<br/>warm-up · co-op net · effects · thralls]:::done
    S28[3 Oct: necro loadout presets<br/>rites · runes · weapons · hotkeys]:::done
  end

  subgraph NOW["🔨 Now"]
    R3[Phones round 3<br/>Back to Menu · AFK survives menus · tap tooltips]:::now
    R4[Performance: last items<br/>render budgets · static corpses]:::now
  end

  subgraph POLISH["✨ Next — polish"]
    P0[✨ Polish pass<br/>finish and tune what exists<br/>before any new content]:::next
  end

  subgraph LATER["🌒 Later — new content"]
    L2[New zones<br/>Hollow Court]:::later
    L5[Server authority step 2<br/>enforce + server-side rewards]:::later
    L6[Loadout presets for all classes<br/>New Blood skills + gear sets]:::later
    L4[AI companions — parked]:::later
  end

  SHIPPED --> NOW --> POLISH --> LATER
```

## ✅ Owner decisions

- **Gear should make you strong** (2 Oct 2026). Base item stats stay as they are, even though a good kit makes high Wave Speed much safer. No compensating nerfs: bosses and Wave Speed are not retuned to cancel out gear.

## 📒 Progress log

Newest first. Each entry is a live release (`release.txt` on the site shows the deployed commit).

| Date | Shipped | Notes |
|---|---|---|
| 4 Oct 2026 | Loot no longer comes looking for you: walk over an item to take it (gold and shards still pull in from a few steps), and anything left behind expires (2-3 min, epic/legendary 10 min). Counsel cards now light up the part of the screen they explain (belt, minimap, Menu buttons), and Settings → Show tips again walks through the minimap, belt, Atlas, Grimoire and Codex one card at a time | Playtest feedback (Helix): items "finding" the hero after making bag room; the alchemy belt hard to find. `TIP_ANCHOR` in ui/Onboarding.ts. |
| 3 Oct 2026 | **Report a bug.** Settings → Report a bug: a short form (kind of problem + description; area, level, discipline, release and recent client errors attached) and a *Your reports* list with each report's status. A daily agent (09:00 UTC) triages new reports and fixes what it can confirm on a `bugfix/reports-<date>` branch for review; it never deploys | migration 029, server/death-muffin/bug-agent/README.md |
| 3 Oct 2026 | **Legendaries drop more often.** 15% per boss kill from the Bone Abbess onward (was 7%), and the Gravedigger King can now drop one (3%). README has a new **Getting better gear** guide: arrows, materials by ground, sets, crafting, legendaries (sources and chances), runes, gold sinks | docs/LEGENDARY-SETS.md, README |
| 3 Oct 2026 | **New Blood kit polish** (branch `claude/newblood-kit-polish`, not deployed). Chain Pull, Hook Pull, Butcher, Echo and Crossing verified end to end and now cast by the balance bot; Knell text matches its three independent beats; small per-class cooldown/power/cost tuning puts the five within ~20% of each other at Graves and Nave. | No new content. See BALANCE.md "New Blood kit polish". |
| 3 Oct 2026 | **Core bug hunt + boss reward rule.** 13 fixes: a reconnect no longer crumbles your legion, host migration keeps thrall/enemy stats, malformed co-op intents can no longer corrupt the host, surges end cleanly on area change/Ascension, DoTs no longer hit burrowed ghouls or the sunk Mire Mother, reconnect retries after a lost join. Boss rewards now follow the normal-kill rule (alive, within 38 m) | docs/polish/core-bug-hunt.md |
| 3 Oct 2026 | **New Blood catch-up.** The five classes without a legion hit 1.5x harder and earn extra experience while young (2x at level 1, normal by level 15): at Graves they now level about as fast as a necromancer; at Nave the XP gap closes from ~6x to ~2x | BALANCE.md "New Blood catch-up" |
| 3 Oct 2026 | **Scythe reaches bosses from farther.** The reaping arc reaches 4 m against a boss (3 m otherwise), so a reaper can stand at the edge of rings and cones; scythe boss wipes in the bot 12 -> 5, damage taken -24% | BALANCE.md "Scythe boss reach" |
| 3 Oct 2026 | Necro pressure pass: re-measured the three P3 balance findings (Ossuary at max Wave Speed, Coliseum/Sanctum arrival spike, tier 6-8 pay) on master with 8 seeds; all three were already closed by the 2 Oct necro pass, so no numbers changed. Not deployed. | Branch `claude/necro-pressure-balance`; table in `BALANCE.md` "Necro pressure pass". Human playtest of tiers 6-8 still open. |
| 3 Oct 2026 | **Boss balance harness tells the truth about weapons.** `npm run balance:boss` now plays the staff, scythe, wand and sickle styles, the Litany barrier and the Fen's wading, hands and hummocks through the real game code. No game number changed. The scythe is the slowest style on every boss and wipes a careful Mourner at the Prelate (7/8, progress kit); the other styles are unchanged or slightly faster. Every style with a kit still kills the Congregation to the Regent in about 70-110 s against the 150-210 s target (the standing gear decision) | Branch `claude/boss-bot-coverage`, not merged or deployed. Write-up: BALANCE.md "Boss bot coverage". |
| 3 Oct 2026 | **First-hour owner decisions.** Every seal count reads *Ossuary seal: 0/300 kills* / *Warren seal: 0/150 kills* from one formatter (Next line, area text, the Prior); the hotbar hides SWAP until a second rite is learned, then shows a small swap icon (the Grimoire tip explains it once); the discipline picker badges Gravecaller *Recommended for your first run*. Not deployed yet. | Branch `claude/firsthour-owner-decisions`; closes polish items 11 and 15. |
| 3 Oct 2026 | **Trade goods get Workbench recipes.** Tin Augment, Garnet Ring, Bronze Warden Kit (6 Bronze Ingots + 2 Oak Planks) and Opal Flask, existing items only, none worth more at the vendor than it eats (a test pins it). Offline mock and live server share one content file. **Apply migration `028-trade-goods-recipes.sql`** before deploying. Not deployed yet. | Branch `claude/trade-goods-recipes`; `server/proposals/trade-goods-recipes.md`. |
| 3 Oct 2026 | **Trade goods have uses.** The three gems, Reliquary Fragment, Covenant Seal and Tin/Bronze Ingots were sell-only; the Sexton's Contracts now order them (about one hard order in five is a relic order, 2x sell price; ingots as ordinary smelted-good orders). No migration. A test fails if any dropped or crafted material has no use. Not deployed yet. | Branch `claude/trade-goods-uses`; `docs/polish/loot.md` item 14; Workbench recipes for them are on branch `claude/trade-goods-recipes` and need **migration 028-trade-goods-recipes.sql** (`server/proposals/trade-goods-recipes.md`). |
| 3 Oct 2026 | **New Blood leveling audit (harness and docs only).** The New Blood bot now gates rites by level, counts reach edge to edge, casts the full kit and sidesteps telegraphs; the bot-caused part of the "4–8× slower" gap is gone (now 3–6×); the real remainder and tuning options are in BALANCE.md. No game numbers changed. Not deployed. | Branch `claude/newblood-leveling-audit`; tests in `balance-newblood.test.ts`. |
| 3 Oct 2026 | **Combat owner decisions.** Bone Needle runes (Marrow-Tap, Splinters) now work under a scythe, once per swing; buying a Damage or Reinforce tier strengthens the thralls you already have standing; Easy auto (dev accounts) steps out of boss telegraphs, hymn cones and hostile pools. Not deployed yet. | Branch `claude/combat-owner-decisions`. The realtime relay needs its whitelist change (`refreshThralls`) deployed first or together; no migration. `npm run balance` and `balance:boss` unchanged; numbers in BALANCE.md. |
| 3 Oct 2026 | PC first: the phone and tablet layer moves to its own `mobile` branch and build at `/death-muffin/mobile/` (touch-only devices are redirected there; `?pc=1` opts out); this build carries no touch code. Not deployed yet. | Branch `dm/pc-only`; deploy `mobile` first. |
| 3 Oct 2026 | **Missing icons fixed.** The Grand Healing Flask and Moonlight Elixir icons and the Prelate portrait no longer 404; the server now logs requests it refuses | Quick fix, `2021523`. |
| 3 Oct 2026 | **No more first-fight hitches.** A warm-up render runs behind the login load screen, so creatures' first appearance no longer compiles shaders mid-fight. Root cause: shaders were compiled for the screen, but High quality draws through the bloom target, so every first draw recompiled | `14e12ef`. 16 of 16 probed spawns needed no new shaders or textures. |
| 3 Oct 2026 | **Thralls and controls feel snappier.** 15 thralls cost about 20% less CPU, distant creatures animate less often, the HUD redraws at 20 Hz and corpses stop animating once they land. Feel: only struck enemies freeze on a hit (not you), your movement blends in 0.16 s, a new **Max** frame-rate option (desktop default until you choose), and resolution changes more calmly with an **Auto resolution** toggle in Settings | `0fccb70`. Matrix updates per frame 942 → 211 in the thrall-legion test. |
| 3 Oct 2026 | **Spell effects cost far less.** Dead particles are no longer drawn, flashes, orbits and beams are batched, ground decals are round; a partner's spells use half the particles and Low uses 75% | `be8a674`. Overdraw in a busy fight 6.5 → 1.6 screens. Write-up: docs/VFX-BUDGET.md. |
| 3 Oct 2026 | Hotfix: creature shaders stay alive between waves (spawn lag); stack limits now match the server, which ended a bag-save failure loop; potions stack to 99 | `2a25770`, migration 027. |
| 3 Oct 2026 | Behind the scenes: a **perf beacon**: each player's game reports frame timing every 15 s to the co-op relay, so live lag can be diagnosed | `0427054`. No gameplay change. |
| 3 Oct 2026 | **Lighter co-op network.** The relay compresses updates and sends each guest only what is within 64 m | `ecb125d`. Guest traffic −70% (335 → 99 KB/s in a big two-area fight); drop counters on the relay. |
| 3 Oct 2026 | **Affix tuning (less loot power, same value).** New rolls only: stat affixes flatten above item level 25, Gravebound / Miasma / Withered / ward trimmed at high levels, essence regeneration lifted. A rolled 7-piece kit adds 9-12% power (was 10-14%, p90 17-22% to 13-19%); a good drop is a 5-9% upgrade; levers within 2x of each other to ilvl 47 (was 2.9x); affixes stay under every completed set. Stored items stay legal (validation accepts the previous ranges), no migration | Branch `claude/affix-tuning`, BALANCE.md "Affix tuning". Not deployed; ships with the regenerated `affix-rules.cjs`. |
| 2 Oct 2026 | **Areas stream in.** Only areas within 45 m are drawn and they build on demand; one load screen at login and none on doors or teleports; prop shadows only within 32 m | `b27d9c6`. |
| 2 Oct 2026 | **Smoother big waves.** Creature bodies for a wave are built over several frames, and loot icons, effect textures and Depths rosters load while idle; loot icons share materials | `31f6b5a`. |
| 2 Oct 2026 | **Lighter download, phone layout only on phones.** Models 82 → 62 MB, art 22 → 7 MB (PNG → WebP), texture memory roughly halved; heroes, NPCs and gear untouched. The phone/tablet layout now applies only on touch devices, so a small desktop window keeps the desktop HUD | `1c6499a`. |
| 2 Oct 2026 | **Belt slots always visible.** Q Heal, Z Elixir and X Tonic show at the left edge with how-to-fill hints; augments can now be equipped | `49f0edb`, migration 026. |
| 2 Oct 2026 | **Co-op reconnects itself, new releases refresh themselves.** After a drop the game retries and returns you to the same world; when a release goes live it saves, waits for boss fights to end, then reloads. Creature shaders and textures are prepared before first draw, and each area's roster preloads | `bea8d35`. |
| 2 Oct 2026 | **Less lag, less loot clutter, partner levels.** Performance: world props are culled in 12 m cells instead of whole-area batches (about half the triangles on screen and in the shadow pass), ground decals share one instanced draw per texture (a fight's ~140 rings/glows in 4 draws), a gold pile is one mesh instead of nine coins, and resolution now drops automatically while a machine can't hold its frame cap (and climbs back when it can). Loot: ordinary kills drop items half as often, but their gear rolls at elite quality and material stacks are doubled; gold keeps its total but lands as one pile every 4 kills (every elite still pays out). Elites, bosses, runes, reagents and legendaries unchanged. Co-op: partners' frames show their level, and it follows level-ups | Fixed fight (`fixed-fight-perf.cjs`), High/Low: nave 773k→438k / 388k→250k tris, calls 277→188 / 240→120; graves 717k→478k / 378k→227k; ossuary, pyre and fen ~330–340k High, ~165–180k Low. Production builds skip the synchronous shader-log checks. |
| 2 Oct 2026 | Legendary sets powered up: every set's numbers raised and each got a lever where it was weakest (Legion: +25% thrall damage, bigger bursts, a Champion every 4th thrall, +100% rally, +10% thrall attack speed; Colossus: +35% thrall health and +15% thrall damage, 60% reflect, 30% guard; Requiem: +10% health, corpses heal 2%, 10 s wisps, 120% novas, +15% thrall attack speed; Plague Choir: +25% Miasma, +8% health, bursts at 8 stacks) | Harness: damage taken with a full set ×0.96 → ×0.86; clear speed ×1.4–1.5 at push/max for Gravecaller/Rotweaver (spawn-limited at the intended band). |
| 2 Oct 2026 | The **Catacomb Depths**: an endless descent from a glowing stair in the Warren's west chamber. Slay each floor's quota and the stair down opens; enemies get one level deeper per floor, elites gain an extra affix every 5 floors, and a chest (sometimes holding a Relic rune) waits on every 5th. Your deepest floor goes to the Chronicle and the public leaderboard | Solo for now (the stair says so in a party). Floor pacing and rewards are a first guess and need a playtest. |
| 2 Oct 2026 | **Legendary armor sets**: four five-piece chase sets, one per necromancer discipline (Legion of the Unburied, Colossus Mantle, Requiem of Wraiths, Plague Choir). 2 pieces nudge, 4 change a mechanic (thralls burst on death, the Bone Ward reflects, corpses summon healing wisps, Miasma spreads Withered), 5 define the build (Champion thralls + Marrow Spear rally, Colossus guard + Litany shatter, Soul Harvest ×2 + wraith novas, Withered bursts into new Miasma). Area bosses from the Marrow Ossuary on drop them (~7%, ~70% your own discipline's set), elites in the scaled zones very rarely (0.3%). Amber rarity, a set-coloured glow at 4+ pieces, a Codex section and a first-drop counsel tip | Migration 025. Harness: full set ≈ ×1.13 clear speed on average (up to ×1.5 at push/max bands), modest at the intended band; drop rates and the Mourner's extra risk need a playtest. Rune spears (Ossuary Ring, Impale) also rally. Co-op: the host sim runs burst/Champion/rally/plague mechanics for guests. Perf: +0.4 ms frame update with 3 wisps. |
| 2 Oct 2026 | Relic runes: eleven necromancer runes drop from elites, Surge offerings and bosses; socket one into each rite in the Grimoire (L) to change how it behaves (Splinters, Volley, Ossuary Ring, Impaling, Mass Grave, Creeping Rot, Contagion, Hollow Choir, Requiem…). The **Bone Colossus** rune turns Exhume into one giant thrall made from up to five corpses | Migration 024. Runes add variety, not power (−2% to +10% kills/min in the harness); the Colossus's tanking and the drop rates need a playtest. |
| 2 Oct 2026 | Relic runes (branch `dm/runes`, not deployed, migration 024): eleven socketable spell modifiers, one socket per necromancer rite (Bone Needle, Marrow Spear, Exhume, Miasma Circle, Black Litany), set in the Grimoire (L); runes drop from elites, Grave Surges and bosses, stack, rest in the Vault and grind to reagents; the Bone Colossus rune raises one giant thrall (the `bone_colossus` model) from up to five corpses | Real-database probe (`tools/qa/runes-db-probe.cjs`), balance table in BALANCE.md, `tools/qa/runes-smoke.cjs`. |
| 2 Oct 2026 | Phones, round 2: clear menu icons with labels, and on phones one **☰ Menu** with big tiles for every panel (plus Recall home); counsel cards and prompts in touch wording; Workbench/Cauldron **Craft ×N / ×5 / Max** and bag **Sell all** with confirm; no page zoom on double tap; **Connection lost / Back online** alerts and the save warning shown on phones | Smokes: mobile-nav, craft-n, connection, afk-move, mobile-shots (4 sizes, no overlaps), first-hour (desktop). Craft batches loop the existing single-craft API (one transaction per item). |
| 2 Oct 2026 | Phones and tablets, battery saver: a **Frame rate** setting (60 or 30 fps, default 60; the game no longer runs at 120 fps on fast screens), phones and tablets start on Graphics Low + 30 fps until the player picks their own (older saved High is treated as the old default), and the 3D view redraws only ~6 times a second while a full-screen panel covers it (the game keeps running) | Settings shows a one-line battery hint. Frame-pacing logic is unit tested. Saved choices are never overridden. |
| 2 Oct 2026 | Phones and tablets: a compact HUD for phone portrait and landscape (two-row dock, orbs with readings inside, upgrades behind a button, full-screen panels) and a tablet fit; touch play (tap a rite to cast at your target or the nearest enemy, hold for the spell card, drag to walk, pinch to zoom, flask and brew buttons); a **‹ Back** button on panels opened from another panel, and the phone's Back gesture steps back through panels; panels no longer jump to the top while AFK gathering | `tools/qa/mobile-shots.cjs` (no HUD overlaps at 390×844, 844×390, 820×1180, 1180×820) and `tools/qa/mobile-nav-smoke.cjs`. Counsel tips still name keys (WASD, Esc). |
| 2 Oct 2026 | Behind the scenes: the automated test suite is reliable again (35 of 36 checks pass first time, the last passes on retry) and one command now runs the whole suite, retries flaky checks once and writes a pass/fail report | `node tools/qa/run-all.mjs`; see tools/qa/README.md. No gameplay change. |
| 2 Oct 2026 | Fix: six early gear items (including the starting Oak Staff, the copper/iron/gold helms, the iron chestplate and the oak bow) gave no stats on the live server because of mislabeled stat keys; they now give their designed stats | Migration 023. |
| 2 Oct 2026 | Thrall gear: the Legion panel (Y) gives your thralls a spare weapon and armour piece whose stats and necro affixes become thrall damage, health and attack speed; 12-tier Reinforce gold sink (resets on Ascension); archers and bone mages carry their bow and staff; ▲/▼ verdicts for legion candidates. Also fixes a live tool-belt bug (swapping tools would have failed on the real database) | Real-database probes for the kit and the belt (tools/qa/thrall-kit-db-probe.cjs). |
| 2 Oct 2026 | Readability round 3: your thralls carry a jade rim light (allies' fainter) so they never blend with pale enemies; the Sexton's Acre shows its ground on arrival; Fen corpse rings read on water; the Nave is calmer (fewer glows and specks) and every zone's floor glows batch into one draw call | Before/after in docs/screenshots/readability-3/. |
| 2 Oct 2026 | Server authority step 1 (report mode): progress saves, bag saves, item adds, gear rolls and offline loads are checked against ceilings derived from the game's own best honest rates (×3 headroom); suspicious saves are logged to `progress_audit` and nothing is changed until `AUTHORITY_MODE=enforce` | Migration 021. How to read the audit and switch modes: docs/SERVER-AUTHORITY.md. |
| 2 Oct 2026 | Zone and encounter polish: boss cone and line telegraphs outlined and bright (Gravedigger sweep, Flood Hymn, Abbess, Plague Saint), faint rings on fresh corpses so they never vanish on dark ground, the Fen wisp pulse no longer camouflaged, three prop overlaps fixed, the Ossuary brighter | Full tour and per-zone numbers in docs/ZONE-POLISH-AUDIT.md. |
| 2 Oct 2026 | Balance re-audit: no drift in farming after the day's changes (max Wave Speed still out-earns intended at ~2 deaths per 3 min; Ossuary level with the others); the boss bot can now reach the Mire Mother; Gravedigger King, Bone Abbess and Mire Mother were too easy and got more health (the Mire Mother also hits harder) | Boss tables in BALANCE.md ("Polish round 2"). If base item stats stay as they are, the later bosses should get about +35% health (part of the owner decision). |
| 2 Oct 2026 | Gear tuning: the balance bot now wears realistic gear kits; stat affixes no longer dominate (INT was mandatory), the six necromancer affixes are worth taking, each necromancer's own armor set is its best set, and the ▲/▼ score agrees with real results on 33 of 35 big swaps | Tables in BALANCE.md ("Gear pass"). One open decision for the owner below. |
| 2 Oct 2026 | Blender round 2: the bone hound's walk no longer stretches its body (new leg and tail bones, procedural idle/walk/run, slip 0.85 → 0.06); cinderhound hind legs flex properly and the shoulder poke is gone; the skull rat's tail no longer drags; the belfry gargoyle has real bones in both wings and flaps from clips instead of a shader | CC0 talk gesture tested on the guide NPCs and kept out (reads as waiting, not talking). |
| 2 Oct 2026 | First-hour polish: one counsel card at a time, calm tips wait out fights, fight lessons match what is happening (cards on screen 95% → 59% of the first 160 s), one clear route from the Acre, HUD collisions fixed, the camera keeps a speaking NPC in view, no stale "Workbench" brewing directions | Audit in docs/FIRST-HOUR-AUDIT.md; README "Your first hour" rewritten. |
| 2 Oct 2026 | Blender animation pipeline (headless Blender 4.5 LTS, `node tools/blender.mjs`): procedural gaits, rig fixes, loop/drift cleanup, IK foot-lock, CC0 retargeting. First results: skull rat and cinderhound got new idle/walk/run (the cinderhound's forelegs had no bones; added) — foot slip 1.04 → 0.08 and 1.53 → 0.09 | 0 Tripo credits. Quaternius CC0 library tested on the Gravecaller; not swapped in (not clearly better). |
| 2 Oct 2026 | Animation 2: hitstop on heavy hits (visual only, rationed), eased knockback, corpses settle into the ground (and no longer freeze mid-fall), real run clips for the grave robber and censer bearer, corrected hound strides | 20 Tripo credits. Skull rat and cinderhound gaits go to the Blender pipeline. |
| 2 Oct 2026 | The Alchemist's Wing dressed: ~65 props (benches, shelves, herbs, rugs, candle pools), warm stone floor and walls instead of purple; the Sexton carries his spade | 0 Tripo credits (existing props and procedural textures). |
| 2 Oct 2026 | Necro spell feel: all 22 necromancer rites gained capped bone, grave-dirt, soul-light, rot-spore, skull and spectral-hand motifs (thinner for thralls, off on Low); animation pass: enemies, thralls, bosses and NPCs no longer face 90° sideways, measured stride speeds cut foot sliding (slip ~1.4 → ~0.3), weapon/tool grips no longer sink into bodies, additive hit flinch, smoothed turning, softer crowd overlap | Spell before/after sheets in docs/screenshots/spell-feel/; animation evidence in docs/screenshots/anim-pass/. |
| 2 Oct 2026 | The Alchemist's Wing (east door of the Chapterhouse): the Great Cauldron and Alembic brew everything, a daily "brew of the day" bonus, the Reagent Shelf collection, and the Apothecary at her counter; item level + affixes rolled on the server (6 necromancer affixes, names like "Gravebound … of the Legion", counted by the upgrade arrows, sheet, Vault, salvage); audio pass 2 (ambience beds for every zone that duck in fights, gathering and station sounds, the remaining necro rites) | Migration 020 (loot_instances). Probed end to end against a scratch database. |
| 2 Oct 2026 | Guide NPCs: the Prior (Chapterhouse), the Sexton (Acre) and the Apothecary talk in voice and give context-aware advice (click or E); an optional "Next" line under the minimap with a minimap ping suggests one step at a time (seal progress, affordable bosses, ready laborers, full bag, Ascension); toggles in Settings | Codex "People" tab; README "Finding your way". |
| 2 Oct 2026 | Art (not yet placed in game): 12 Alchemist's Wing props and three guide NPCs (the Prior, the Sexton, the Apothecary) with idle, walk and talk clips | 1,025 Tripo credits; contact sheets in docs/screenshots/alchemist-wing/. |
| 2 Oct 2026 | Necro balance pass: max Wave Speed now pays (kills 0.54× → 1.18×, gold 1.34× → 2.50×, XP 0.61× → 1.84× of the intended band; deaths 7.8 → 2.1 per 3 min); Ossuary 10.1 → 2.2 deaths at max; Coliseum and Sanctum smoothed (≤1 death at the intended band everywhere); Wave Speed ramps in over 30 s; an empty area clears after 8 s | Measured with 8 seeds × 36 rows; details in BALANCE.md. Needs a human playtest at tiers 6–8. |
| 2 Oct 2026 | Tool belt: four belt slots under the paper doll (hatchet, pickaxe, rod, spade) that count for gathering and take no bag space; a one-time "belt your best tools" offer; Skills shows the active tool | No migration (reserved slots 110–113). |
| 2 Oct 2026 | Armor set bonuses at 2/4/5 pieces for all 18 sets (necro sets drive thralls, ward, essence, Miasma, Withered); upgrade arrows and verdicts count set bonuses ("completes your 4-piece" / "breaks your 2-piece"); Set bonuses on the Character sheet and a Codex Armor sets tab | Table in docs/ARMOR-SETS.md. |
| 2 Oct 2026 | Visible Grave Laborers: assigned thralls work their node in the Sexton's Acre (chop, mine, dig, fish) with the right tool, a ready badge, hover details and click-to-open (H) | Uses the dig/chop clips retargeted onto the four thrall rigs. |
| 2 Oct 2026 | 48-slot bag; Ossuary Vault (V, 120 shared slots); Bone Grinder salvage + Salvaging skill; item locks; Sell all junk; gear stat effects, ▲/▼ upgrade arrows, verdict line, Character sheet (J) with "What you're looking for"; combat audio (CC0 samples, capped mixer, Combat/Ambience/Interface sliders); strike timing; old starter gear no longer stacks | Migrations 017 (vault) and 018 (gear unstackable). Thrall dig/chop clips built for the laborers (90 Tripo credits). |
| 1 Oct 2026 | Necro weapons, brewing and reagents, Mourning Fen, five swappable rite slots, Offline Edition with complete save sync, Leave the world at the top of Settings | Codex cleanup; `deploy-release.sh` became the only deploy path. |

**Owner approvals in force:** deploy when all checks pass; push after a secret scan; up to 1,500 Tripo credits without asking (spent so far against it: 1,045 — Wing props and guide NPCs 1,025; robber/censer run clips 20); keep following this roadmap.

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

### P0 · Polish pass (next priority, before new content)
*Owner, 3 Oct 2026: "I'm afraid we are adding more than what gets polished."* Finish the performance items still open (render budgets: resolution cap, shadow cadence and lights; static corpses), then walk the game as a new player and tune what exists: rough edges, readability, feel and balance. Hollow Court and other new content wait in Later until this is done.

### P1 · Necro spell feel
Every necromancer rite should look and sound necromantic: bone, grave dirt, soul-light and rot rather than generic magic. Keep each spell's meaning colour (`SPELL_FX`) but add necro motifs (bone shards, spectral hands, skull wisps, ground sigils), keep effects readable in a crowd, and cap particle counts so a full legion never turns into noise.

### P2 · Visible Grave Laborers
Assigned laborers appear as thralls at their node in the Sexton's Acre and work it: chopping, mining, digging, fishing, picking herbs, with the matching tool. Thrall models have no work clips yet; retargeting chop, dig and mine onto the four thrall rigs costs about 120 Tripo credits.

### P3 · Zone and encounter polish
Driven by measurements, not guesses: the necromancer balance run across all nine hunting grounds, the clip audit, and the loot audit (what fills the bag). Results and the resulting fixes are listed here as they land.

**Necromancer balance run (2 Oct 2026, 4 disciplines × 9 hunting grounds × 4 seeds, 3 min each).** The first three findings below were fixed on `dm/balance-pass` the same day (see `BALANCE.md`, "Necro pass"): max Wave Speed 7.8 → 2.1 deaths per 3 min and 1.18× the intended kill rate; Ossuary level with the others; every intended-band row at ≤ 1 death. Awaiting a human playtest of tiers 6-8. Findings as measured:
- At the intended pressure the necromancers are healthy almost everywhere (0–1.8 deaths per 3 min).
- **Max Wave Speed is a trap.** 5–11 deaths per 3 min, first death after 5–20 s, and kills per minute *fall* to a third or less of the intended band (Nave Gravecaller 109 → 16/min). The top tiers should pay more for good play, not less. Fix: retune the tier 6–8 pressure curve and surge sizes so a careful player out-earns the intended band.
- **Ossuary, the defensive discipline, dies most under pressure** (8–11.5 deaths at max). Its shieldbearers soak until they die, then the caster is exposed. Candidates: Bone Ward per living thrall, or a thrall HP floor.
- **Coliseum and Sanctum spike at arrival level**; Mourner dies even at the intended band there (1.8–2.5 deaths). Check their elite rate and greeting waves.
- **Bag pressure (tool belt built on `dm/tool-belt`, not deployed):** gathering tools (24 kinds) do not stack and the best one you carry counts, so tools held 4+ bag slots. The four-slot tool belt (inventory slots 110-113) frees them.


### X1 · The Alchemist's Wing
**Status (2 Oct 2026, branch `dm/alchemy-wing`):** room, stations, Reagent Shelf, brew of the day, help and smoke built; the Apothecary NPC and the herb-order quests are not (anchor `WING_APOTHECARY_SPOT` in `areas.ts`).

A dedicated room off the Chapterhouse: cauldrons and alembics as brewing stations, reagent shelves showing what you have found, a drying rack for herbs, and an NPC apothecary who hands out brewing orders. Art goes through the existing Gemini → Tripo pipeline (`ASSET_PIPELINE.md`; about 6,300 Tripo credits left). Brewing moves from the Workbench tab into the room, and the room becomes the home of higher-tier recipes (discovery, quality, concoctions from `docs/ALCHEMY-AND-WORLDS-PLAN.md`).

### X2 · Combat feel and animation pass (P5)
*Steps 1-5 are built on `dm/anim-pass`, step 6 and part of 7 on `dm/anim-2` (2 Oct 2026, see HANDOFF). Left: a real run for the quadrupeds (skull rat, cinderhound).* Keep the art style; make motion smoother. Practical steps, in the order that pays most:

0. **Found 1 Oct 2026: attacks are out of sync.** Enemy wind-ups last 0.38–1.3 s, but the attack clip is played at a fixed 1.6× speed (`EntityViews.ts`), so its impact frame shows about 1.3 s in (main clip) or about 0.3 s in (the random second variant). Damage therefore lands before or after the visible swing, and the clip is cut when the enemy walks again. Fix (code only): bake each clip's measured impact time (`tools/measure-clips.mjs`) into a table, scale each swing so its impact lands at the end of the wind-up, and let the follow-through finish before blending to walk. Quadruped rigs (bone hound, skull rat, cinderhound) need the tool taught their bone names.
1. **Measure first.** `tools/clip-sheet.mjs` and `tools/measure-clips.mjs` produce a contact sheet and numbers for every clip. Rank the worst clipping and sliding.
2. **Weapon and prop clipping:** per-weapon grip offsets, hide the off-hand during two-handed clips, and fit per-model attach points.
3. **Foot sliding:** scale walk and run clip speed to actual movement speed.
4. **Blends:** longer locomotion crossfades (0.18 s → about 0.3 s) while attacks stay snappy, and a short additive flinch instead of swapping to a full hurt clip.
5. **Crowds:** stronger separation and steering so packs do not stack, plus formation slots for thralls around the caster.
6. **Impact:** a two- or three-frame hitstop on heavy hits, eased knockback, and a death "settle" into the ground.
7. **Replace the worst Tripo clips** with retargeted library clips where measurements say they are beyond fixing.

### X2b · Blender animation pipeline (built 2 Oct 2026 on branch `dm/blender`, not deployed)
Built: `tools/blender.mjs` (procedural gaits, rigfix, cleanup, retarget), skull rat + cinderhound gaits rebuilt, CC0 retarget proof; see `docs/BLENDER-PIPELINE.md`. Still open: the gargoyle wing, bone_hound gait recipe, shipping retargeted gestures (talk, spell-ready idle), quadruped retarget. Original brief:
Headless Blender on the server, driven by scripts: retarget CC0 animation libraries (e.g. Quaternius) onto the Tripo rigs instead of paying for Tripo presets, clean loop seams and root drift, IK foot-locking so feet truly plant, procedural clips (talk gestures, work loops) and rig fixes (the gargoyle's one-boned wing). Verified with `tools/measure-clips.mjs` and rendered frame strips. Hand-keyed signature animation stays a human animator's job; the pipeline makes it easy to drop such clips in.

### X3 · Loot item level and affixes
**Built 2 Oct 2026 on branch `dm/affixes` (not deployed; needs migration 020).** Gear rolls an item level and up to three affixes on the server, so each drop is a real upgrade decision; necromancer levers (thrall damage and health, essence regeneration, Miasma, Withered, ward) plug into the stat pipeline that armor sets use. Ranges were tuned against the harness on 2 and 3 Oct (BALANCE.md "Affix tuning"). Next for it: crafting or re-rolling (gold sink) and affix-aware set drops. See `docs/GRIND-LOOP.md` §3 #2.

### X4 · Open audits
- Four-discipline visual audit (`tools/qa/necro-audit.cjs`, run one discipline at a time).
- Audio has never been checked by ear.
- New Blood classes level 4–8× slower than necromancers in bot runs; check with a human before retuning. **Audited 3 Oct 2026** (BALANCE.md "New Blood leveling audit"): about a third of the gap was the bot (unlocked-rite gating, reach, unused rites, no dodging; fixed, gap now 3–6×). The rest is real: necromancer thralls tank and deal 20–35% of kills, a New Blood hero dies 4–5 times per 3 min, and its single-target kit does less damage. **Open, owner decision:** damage ×1.5 / HP +50% / early-level XP catch-up options with measured effects are in BALANCE.md; a human should first check that a level-1 Warden, Monk or Knight survives the Graves.

---

## 🌒 Later

### L1 · AI companions (parked)
*Parked on 1 October 2026. The cost study below is kept for when this comes back: event-driven decisions on Claude Haiku 4.5, bots online only while a player is in the world, and a hard daily spend cap come to about $10–20 a month for three bots.*

Two or three bot players you can log in and play with. Recommended design:

- **Body:** a lightweight Node "player" that speaks the same realtime protocol as a browser (move, cast intents, chat), with no rendering. It reuses the existing Easy auto-combat brain (`src/gameplay/autoCombat.ts`) for moment-to-moment fighting. It is cheap enough to run several on the VPS.
- **Mind:** an LLM (Claude Haiku) decides every 10–30 seconds: follow you, hold a chokepoint, gather, return to town, and talks in chat with a persona. It never controls frame-by-frame input.
- **Accounts:** each bot is a real account and character with its own progress, flagged as a bot. Bots only join worlds you invite them to.
- **Decisions needed:** how strong bots should be, whether they loot or level, and the API budget.

### L6 · Loadout presets for all classes (New Blood disciplines)
Necromancer loadout presets are built (`dm/loadouts`, 3 Oct 2026, migration 037): rites + runes + worn weapon/off-hand saved under a name, six per character, optional unbound-by-default hotkeys. Later: the same for the New Blood disciplines (Grave Warden, Bell Monk, Carrion Witch, Hollow Knight, Veilwalker): their skills (rites) plus gear sets (weapon, off-hand, armor pieces). Needs a per-family preset shape (no runes outside the necromancer; armor slots become part of a set), the gear half of `applyLoadout` generalised beyond the two hands, and the section shown for every family. Not started.

### Performance (from the Blender audit)
The targets (the finish line) are in [docs/PERF-BUDGET.md](docs/PERF-BUDGET.md); check with `node tools/qa/perf-budget.cjs`. Measured in [docs/BLENDER-AUDIT.md](docs/BLENDER-AUDIT.md). **Done (2–3 Oct):** prop culling, instanced decals, accessor pruning, trimmed clips, WebP art, texture downscale by class, area streaming, spawn budget, warm-up render, effect budget, thrall CPU, co-op relay filtering. **Open:** render budgets (resolution cap, shadow cadence, light count) and static corpse meshes are in progress. **Later:** meshopt compression and simplify, 3D item icons, LODs, KTX2.

### L2–L4
- **New zones:** the Hollow Court (`docs/ALCHEMY-AND-WORLDS-PLAN.md`). The Catacomb Depths (W2) are live (2 Oct, release b4aab17, no migration): a Warren stair, seeded floors of small chambers, a quota-then-stair loop, elites with another affix and a chest every fifth floor, a Chronicle best depth. Open: co-op floors (solo for now), a depth leaderboard view beyond the public page's column, and a human playtest of the pacing.
- **Content with paid art ready:** nothing waiting: the Bone Colossus and the runes are live (2 Oct, migration 024), thrall gear shipped.
- **Server authority:** today the browser is trusted for level, gold and loot (fine among friends). Move rewards to the server before opening to strangers. Step 1 (plausibility guards, report-first, `AUTHORITY_MODE`) is built on `dm/server-authority`, not deployed: [docs/SERVER-AUTHORITY.md](docs/SERVER-AUTHORITY.md). Server-rolled kill rewards (step 2) remain.

---

## 🧹 Housekeeping
- Seven `zz_*` test accounts in the live database (owner to delete).
- Six merged worktrees in `wt/` and about 11 GB of old update zips in `vps-handoffs/DeathMuffin/` (owner to delete).
- Old one-off deploy scripts that build from stale trees (`deploy-afk.sh`, `deploy-update.sh`); `server/death-muffin/deploy-release.sh` replaces them.
