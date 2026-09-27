# Death Muffin spell variety plan

Status: proposal only, 2026-09-27. No abilities, loadout changes, unlocks or assets in this document have been implemented. Preserve the approved gameplay at `fca634d057105e995e17e44d7363812b6cb08458`, checkpointed as `death-muffin-v1.0.0`. Read [the checkpoint](DEATH-MUFFIN-CHECKPOINT.md) and [VPS handoff](DEATH-MUFFIN-HANDOFF.md) before implementation.

The aim is more ways to enjoy the existing relaxed grinding loop: choose a few spells, watch satisfying combinations clear packs, and take over for positioning or a well-timed ability. Variety should come from different attack shapes and corpse decisions, with the accepted movement, quick gestures and visual UI intact.

## Shipped foundation

The source of truth is `src/content/abilities.ts`, not older backlog headings. Ten active ability IDs already exist:

| Role | Shipped abilities |
| --- | --- |
| Basic generator | Bone Needle |
| Shared numbered slots | Marrow Spear · Exhume · Miasma Circle · Black Litany |
| Corpse finisher | Corpse Explosion |
| Level-10 discipline signatures | Ossuary Wall · Command: Rend · Dirge · Plague Bloom |

Also shipped: Soul Harvest empowerment, Fracture/Withered/Hemorrhage/Chill and other statuses, corpse-dependent thrall types, four discipline heroes, free class changes, short cast recovery, stable in-place hero gestures and stationary auto combat. Relic runes, the new spells below and live grinding/opponent bots remain proposals.

Keep the Claude foundation's persistent world → kills → corpses → minions/spell fuel → loot/upgrades loop. `FUTURE_CONTENT.md` has useful rune and talent ideas; it does not establish that those systems are implemented. The original redesign audit's violet-heavy palette is historical: the current `SPELL_FX` family colours and live site's design take precedence.

## Controls and loadout proposal

Keep click-to-move, stationary mouse aim, primary attack, 1–4, RMB/5 corpse finishing and R/6 signature. Add no mandatory key. A player can continue using the existing kit unchanged.

Add a **Rites loadout** section inside the existing panel style, with one selectable basic and role-compatible swaps for the four existing slots:

| Existing role | First compatible choices |
| --- | --- |
| Primary | Bone Needle / Bone Fan; later Rot Lance |
| 1: direct pack damage | Marrow Spear / Soul Chain; later Ivory Cleave |
| 2: corpse or legion support | Exhume / Grave Offering; later Rally the Dead |
| 3: ground/control | Miasma Circle; later Frost Wake / Carrion Seed |
| 4: burst or survival | Black Litany / Veil Step; later Bone Mantle |
| RMB/5 and R/6 | Keep the existing corpse finisher and discipline signature mappings |

Veil Step occupies slot 4 and replaces the big ritual while equipped. That is a meaningful survival-versus-burst choice, without turning the bar into eight new buttons. These are first-release constraints; arbitrary slot assignment can wait for evidence that players need it.

Changing a loadout is free. Proposed safeguard: preserve remaining spell and slot cooldowns and current cast recovery; a replacement cannot erase the old slot's recovery. Do not refill essence, souls, health or charges. Apply selections atomically and clear any queued action for the replaced slot. This is a requirement for the future loadout system, not an unsolicited change to accepted class-switch behavior.

Give each discipline two optional named presets, such as **Relaxed Farm** and **Boss Control**, built from earned spells. Presets only equip spells and update auto preferences; they must not change difficulty, progression or move the player. Keep the current preset as the default after migration. Selecting a spell should show its actual targeting shape, cost, cooldown, corpse requirements and what it replaces; richer hover information should read the same data.

## Four MVP additions, in order

Numbers below are starting points for playtesting, not approved balance values. None needs a new hero GLB, weapon or animation.

| Priority / spell | Interaction and tradeoff | Shape / visual identity | Existing reuse and performance cost |
| --- | --- | --- | --- |
| **1 — Bone Fan**: alternative basic | Fire three short-range slivers through a narrow fan, generating essence on confirmed hits. Trade Needle's reliable long-range focus for close pack coverage. Start around 8m reach, .50s repeat; cap total essence gain at 6 per cast and prevent threefold reward credit. Auto aims the fan at a nearby pack; it never walks closer. | Three thin ivory/amber lines and small bone impacts; no floor-sized flash. | Existing needle geometry/material and pooled projectiles, short `cast` gesture, `necro-needle.png` as a labelled temporary family icon. Low cost: three projectile mesh draws while alive instead of one; at most three release/impact groups. |
| **2 — Veil Step**: survival choice for slot 4 | Dash up to about 4m toward the cursor along valid walkable space; stop before sealed gates or blockers. Roughly 8s cooldown, no essence cost. Manual only. MVP provides repositioning, not wall phasing, long invulnerability or automatic dodging. | A compact jade departure ring, a short thin spirit streak and arrival sparks. The hero remains visible. | Existing hero `run`/locomotion, ring/glow/spark textures and managed particles. No ceremonial cast. Low rendering cost, medium gameplay work because navigation, collision and co-op position validation must agree. |
| **3 — Grave Offering**: corpse choice for slot 2 | Consume one owned/available nearby corpse for essence and modest healing instead of raising it. Starting point: 16 essence, 4% maximum health, 2s cooldown; no corpse means no spend or cooldown. Explicitly define Mourner's existing corpse-heal interaction and cap healing at maximum HP. Cannot generate souls or loot. | A small jade wisp travels corpse → staff, followed by a restrained pulse. Direction reverses Exhume's caster → corpse tether so the choice reads clearly. | Existing short `dig` gesture, Exhume beam/glow/cracks and `necro-exhume.png` as a labelled temporary icon. Low cost: one tether plus at most 12 motes; no new summon. |
| **4 — Soul Chain**: damage choice for slot 1 | Hit the aimed target, then jump to up to two distinct nearby enemies. Trade Spear's high line damage and Fracture for reliable scattered-pack hits. Start around 22 essence and 2.8s cooldown; successive jumps weaken. Boss receives one hit, not three repeated links. Never bounce into unaggroed distant packs. | A bright jade/teal thread connects distinct targets in a readable sequence; compact pale impact cores. | Existing short `cast`, beams, flashes and procedural spirit audio family. `necro-spear.png` can be a temporary labelled family icon; a dedicated chain icon remains an art gap. Low/medium: at most three links and impacts, one bounded search per jump. |

Build the loadout seam before the first alternate basic, then ship one spell at a time. Veil Step gives a new thing to *do*; Offering gives a new thing to *decide*; Fan and Chain give a new pattern to *watch*. This creates variety without making relaxed play depend on a perfect rotation.

## Six later additions

These proposals deepen the four existing disciplines rather than introducing unrelated classes. Unlock class-flavoured choices through the shared character's earned milestones; changing class should not restart that progression.

| Spell / discipline | Interaction and compatible slot | Shape / colour | Reuse, cost and reason |
| --- | --- | --- | --- |
| **Ivory Cleave — Ossuary** | Slot 1 alternative: short forward bone arc applies Fracture to a close pack. Strong close coverage, weaker reach than Spear. No new physical weapon required. | One shallow ivory/amber crescent on the ground; small bone flecks. | `fx.cone()`/ring fragments, current staff cast, Spear icon as placeholder. Low; one bounded cone query. Gives Ossuary a clear close-range identity. |
| **Rally the Dead — Gravecaller** | Slot 2 alternative: briefly strengthen the existing legion and focus its current target. No teleport, extra minions or new corpse creation; respect thrall cap. Exhume remains the way to rebuild. | Brief jade threads to up to the current legion cap, tiny bone markers on recipients. | Existing thrall models and tethers, Exhume icon as placeholder. Low; bounded buff state and no new AI update loop. Gives legion play an option that does not sacrifice it. |
| **Frost Wake — Mourner** | Slot 3 alternative: a short fan of spirits applies existing Chill. Slows a close pack to buy room; trades Miasma's persistent damage for immediate control. Boss gets bounded slow, never a permanent freeze. | Three thin cold-blue spirit ribbons in a fan, a pale edge and limited mist. | Current `cast`, cone/glow/spark textures; renewal status art may inform a labelled placeholder. Low/medium; one cone query and existing status path. Differentiates Mourner without borrowing enemy bell bronze. |
| **Carrion Seed — Rotweaver** | Slot 3 alternative: plant a seed on one corpse. After a brief visible warning, the next nearby enemy triggers a rot burst; the seed then ends. One seed per caster initially; corpse consumption is atomic. | Small chartreuse bud/sigil at the corpse, olive boundary, quick green burst. | Current `dig`, Miasma/cracks/ring textures and Miasma icon as placeholder. Medium; one bounded timed trigger, not a recursive spreading simulation. Creates a deliberate trap rather than another permanent cloud. |
| **Rot Lance — Rotweaver** | Alternative basic: a narrow long projectile applies a light Withered stack while generating less essence than Needle. Lower upfront damage; the target survives long enough for poison to matter. | Thin chartreuse lance, compact olive droplets; no lingering large smoke. | Pooled projectile, `cast`, Withered art and needle icon as placeholder. Low; one projectile/status application. Provides a distinct poison farming rhythm. |
| **Bone Mantle — Ossuary** | Slot 4 alternative: a brief capped barrier, modestly strengthened by an existing legion. No extra thralls or corpse requirement; shares survival-slot recovery with Veil Step. | A close ivory/amber rim and a few bone segments around the hero; no opaque bubble. | Existing barrier state, ring/spark textures, Ossuary portrait and Spear icon as placeholder. Low; one bounded barrier effect. Smooths Ossuary's documented exposed period after shieldbearers die. |

Initial discipline identity: **Ossuary** holds close ground; **Gravecaller** tends and directs its legion; **Mourner** controls and sustains with spirits; **Rotweaver** creates poison and corpse traps. Shared staples remain available, and class-specific options should be sidegrades rather than obligatory upgrades.

## Art compatibility and outstanding work

These are available source assets, not claims of finished new spell art:

| Existing asset/system | Proposed reuse | Gap before polished release |
| --- | --- | --- |
| `public/models/hero_{ossuary,gravecaller,mourner,rotweaver}/character.glb` | Preserve each discipline's model and proportions; use the current anchored, shortened `cast`/`dig` gestures and locomotion blending. | No new GLBs required for MVP. Only request a new clip if a measured gesture mismatch cannot be solved by timing. |
| `public/art/portraits/{ossuary,gravecaller,mourner,rotweaver}.webp` | Existing discipline heading/preset identity inside the supplied panel style. | No portrait replacements. |
| `public/art/abilities/necro-{needle,spear,exhume,miasma,litany,corpse-explosion}.png` | Spell-family placeholders for early testing; existing six shipped icons stay intact. | New abilities need distinct final icons, particularly dash, chain, offering and buffs. Retinting is not finished dedicated art; use explicit names/role labels while testing. |
| `src/graphics/fxTextures.ts`: glow, ring, disc, sigil, cone, smoke, spark, cracks, lightPool | Assemble short, legible shapes using existing cached textures and pooled Effects primitives. | A curved arc/ribbon can be code geometry or an atlas variant later; no new asset generation in the first pass. |
| `public/art/status/{fracture,withered,hemorrhage,renewal,sanctified}.png` and current inline status fallback | Keep current status meanings; reuse Fracture/Withered/Chill paths when appropriate. | New buff labels/icons need design review. Do not pretend an unrelated status icon has the new meaning. |
| Existing procedural Audio engine | Reuse bone, spirit, rot and impact families with distinct, restrained timing. | Ear-test cadence and overlapping voices; new named audio cues are not yet produced. |

Use `SPELL_FX` colour families: ivory/amber bone, ember/crimson marrow, jade/teal spirit, chartreuse/olive rot, cold blue Mourner, violet major rituals. Bronze remains enemy bell language. Shape and sound must distinguish spells even without colour. Preserve login art, typography, borders, HUD layout, staff attachment, model yaw and fixed click destinations.

## Unlock pacing and sustained variety

Proposed pacing targets must be calibrated in a real new-player session; they are not timers or guarantees:

- Keep the complete shipped kit available as it is. Existing characters lose no spells.
- Offer Bone Fan after one small fight: level 2 **or** 25 recorded kills, whichever comes first. Veil Step follows level 3 **or** 50 kills. Aim for both during the opening few minutes, without a boss or rare drop gate.
- Offer Grave Offering at level 4 **or** 100 kills; Soul Chain at level 5 **or** 150 kills. Target access to all four MVP choices during an initial 10–15 minute session; adjust thresholds if measured sessions miss it.
- At the existing level-10 signature milestone, add the first class option for each discipline. Later options come through ordinary progression or exploring an area, with clear previews; avoid mandatory Hard difficulty or repeated boss kills to obtain the basic build choices.
- Keep unlocked spells across class changes and Ascension. Use a versioned per-character save and server validation; give eligible existing characters unlocks through an idempotent migration. Never infer ownership from browser-only UI state.
- After the active pool is enjoyable, add one of two behavior choices per spell: Fan becomes a wider fan versus a tighter volley; Offering becomes more essence versus more sustain; Chain becomes an extra weak jump versus a stronger first target. Equip one variant, never stack both. Start with earned talent selections; actual socketable rune items remain separate server work.

The goal is an early new toy followed by a meaningful build decision every few sessions. Avoid ten compulsory maintenance buffs, a new resource per spell, daily lockouts, escalating animation length or a spell that is simply an old spell with larger numbers.

## Auto combat safeguards

Extend `src/gameplay/autoCombat.ts`; do not invent a second combat executor. Both automatic and manual actions must pass the same readiness, targeting, cast recovery and Intent → WorldSim validation path.

- Select only equipped spells. Inspect bounded candidates, choose at most one action per decision, and preserve the current essence reserve, panel suspension and manual movement priority.
- Primary attacks may repeat; pack spells need useful coverage. Veil Step stays manual. Signatures remain manual by default, as shipped.
- Offering may run only when essence/health genuinely needs it and a corpse is not needed to restore an equipped Exhume legion. Destructive corpse use is a player-selectable preference; preserve rare/resonant corpse fuel when appropriate.
- Rally must not cast with no legion. Mantle needs real pressure, not a permanently refreshing empty-room effect. Seed triggers are bounded, and Chain does not reach beyond its equipped spell's range.
- No auto chase, navigation change, automatic difficulty/Wave Speed increase or corpse-teleport shortcut. Auto combat remains relaxed stationary assistance; persistent bots are the separate future project in [the roadmap](death-muffin-roadmap.md).

## Three.js and gameplay budgets

Preserve current short cast locks (60–160ms) and .22–.48s hero gestures. New attacks release promptly, resume walking without root drift and let impact feedback coincide with actual confirmed hits. No per-spell RAF, untracked timeout or overlapping full-body ceremony.

Reuse the existing two particle systems, fixed light count, pooled projectiles, instanced spikes and 160 cosmetic-transient ceiling. Extra visuals must degrade gracefully without dropping gameplay callbacks. Proposed per-cast limits: at most three basic projectiles, three Chain links, one Seed, one Mantle ring, and roughly 12–24 small particles for ordinary spells. Limit dash trails to a short pooled effect; do not clone the full skinned hero for afterimages. Avoid a persistent dynamic light per projectile or zone, growing smoke clouds and nested chain explosions.

Performance claims need a home-PC GPU baseline, not headless software-rendering FPS. Compare the same quality, area, camera and enemy density before/after with shaders warmed. Profile worst-case four-player overlapping casts, average/P95 frame time, calls/triangles and resource cleanup after ten minutes. If a proposal misses budget, reduce cosmetic layers before changing damage behavior.

## Delivery phases and next-agent work

1. **Loadout seam:** one basic selection and role-compatible numbered slots; same defaults, free swaps, cooldown safeguards, clear hover/preview data, versioned save proposal and deterministic auto selection for equipped spells. Existing live endpoint/item contracts remain valid. Review new save fields and intents before adding migrations.
2. **MVP spells:** ship Fan, then Veil Step, then Offering, then Chain, with isolated QA and a reversible static build for each. Stay on the approved assets. Publish only completed, tested mechanics; the plan alone changes no gameplay.
3. **Discipline options:** implement Ivory Cleave, Rally, Frost Wake and Seed one at a time. Add Rot Lance and Mantle only after testing resource sustain and defensiveness. Measure Gravecaller's existing pressure weakness and Ossuary's swinginess before using new spells to conceal balance issues.
4. **Build depth:** a small behavior-variant layer and distinct final icons; then optional earned presets, encounter synergies and longer-term runes. Live bots and leaderboard participation stay separately scoped and visibly identified.

Each implemented spell needs content definitions, actor/target validity, authoritative intent/event behavior, bounded VFX/audio, auto eligibility, Onboarding counsel, Codex entry, README guidance and accurate hover information. New persisted fields require rules validation and save/reload coverage; new intents require realtime bounds/rate checks and host-migration compatibility. Continue using known live item IDs unless an explicit server proposal introduces new ones.

Tests should cover shape/target limits, resource and corpse consumption exactly once, failed cast spending nothing, swap/reconnect cooldown behavior, cancellation on death/scene exit, multiplayer ownership and late arrival timing. Extend the existing deterministic farming/boss harness to actually equip and exercise the alternatives before tuning; current historical balance tables do not prove a new spell is balanced. Re-run typecheck, client and server suites, relevant browser scenarios and same-horde rendering checks. Keep the accepted fixed click path, aim-facing, hero anchoring, class/save preservation and original visuals as regression checks.

Recommended first implementation: the small loadout seam plus **Bone Fan**. It proves variety and compatibility at low risk; follow with **Veil Step** to add an engaging manual decision. Do not implement all ten abilities in one pass.
