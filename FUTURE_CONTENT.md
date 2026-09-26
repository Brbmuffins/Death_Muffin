# Crossworlds — Future Content Backlog

Design backlog for disciplines, spells and combat systems beyond the current
necromancer slice. Everything here is **not built yet** — it's the menu for
future releases. Keep entries concrete enough to spec from; move items into
`PHASE_REPORTS.md` when they ship.

Current shipped kit (for reference): Bone Needle · Marrow Spear · Exhume ·
Miasma Circle · Black Litany, four disciplines (Ossuary, Gravecaller, Mourner,
Rotweaver), five enemy archetypes + Risen, the Bell-Sworn Prelate.

Spell-colour language (keep it when adding content): **ivory/amber** = bone,
**ember + dried crimson** = marrow/blood, **jade/teal** = spirit & your risen
dead, **chartreuse/olive** = rot & poison, **violet** = signature ritual magic,
**bronze** = enemy bell/sound attacks, **cold blue** = wraiths/Mourner.

---

## Release 0.2 — "Deeper Rites" (depth for the current four disciplines)

### Per-discipline signature spells (one new active each, unlocked at level 10)
| Discipline | Spell | Targeting | Idea |
|---|---|---|---|
| Ossuary | **Ossuary Wall** | line | Raise a wall of fused bone that blocks enemies and projectiles for 6s; thralls behind it take 30% less damage. |
| Gravecaller | **Command: Rend** | self | All thralls dash to your cursor target and cleave; costs thrall HP instead of essence. |
| Mourner | **Dirge** | channel | Channelled bell-song: allies heal, enemies in a cone are Silenced (casters can't cast). Mourner gets a bell weapon slot. |
| Rotweaver | **Plague Bloom** | ground | Plant a rot flower that pulses Withered and spreads to the nearest corpse, chaining through the corpse field. |

### Spell modifiers ("Relic runes") — the build-depth layer
Socketable runes that change a spell's behaviour instead of its numbers:
- Bone Needle: *Splinter* (pierces once), *Marrow Tap* (+essence, −damage), *Volley* (3 needles in a cone, longer cooldown).
- Marrow Spear: *Ossuary Ring* (spikes erupt in a circle instead of a line), *Impale* (roots the first enemy hit).
- Exhume: *Mass Grave* (raise from up to 3 corpses at once, each weaker), *Bone Colossus* (consume 5 corpses → one giant thrall).
- Miasma: *Creeping Rot* (the circle drifts toward the nearest enemy), *Contagion* (withered enemies that die spread stacks).
- Black Litany: *Hollow Choir* (no thrall sacrifice; smaller burst), *Requiem* (delayed 2s, double radius).
Server-side these can be regular items with a new `item_type: 'rune'` (needs a server enum addition — see `server/proposals/`).

### Thrall variety
- Skeleton archer (from Bellbound corpses), bone mage (from Deacon corpses — casts slow curses), plague bearer (from Carrion Sacs — explodes on death).
- Thrall gear: give thralls the copper/iron gear you'd otherwise salvage (weapon/armour slots on the thrall bar).

### Resource & feel
- ✅ *shipped (combat depth pack, see PHASE_REPORTS)* — **Corpse Explosion** as a universal action on a key (5): the classic necromancer button; toxic/resonant corpses get special explosions.
- ✅ *shipped (combat depth pack)* — **Soul Harvest** passive meter: kills fill a skull meter; when full, the next spell is empowered (free + 50% area).
- Controller support (twin-stick: left stick move, right stick aim, face buttons 1–4).

---

## Release 0.3 — "New Blood" (additional classes beyond necromancy)

The server keeps 5 class indices; index 0 (legacy Engineer) is unused. New
classes should either reuse index 0 or wait for a server `class_index` range
extension. Each keeps the corpse economy relevant so co-op parties interlock.

| Class | Fantasy | Resource | Corpse interaction | Signature combat |
|---|---|---|---|---|
| **Grave Warden** (idx 0 candidate) | Iron-clad cemetery guard, lantern and flail | Oil (lantern fuel) | Burns corpses to deny Deacons and create fire zones | Lantern cone that reveals/stuns wraiths; flail chain-pull |
| **Bell Monk** | Ex-penitent who turned the bell on the dead | Resonance (builds per hit) | Resonant corpses supercharge bell tolls | Rhythm combat: hits on the toll beat deal bonus damage |
| **Carrion Witch** | Ritual butcher, crows and hooks | Offal | Harvests corpses for crow swarms and hex charms | Hook-pull + crow swarm DoT, curses that spread on death |
| **Hollow Knight** | Undead knight still loyal to the Covenant | Rage from damage taken | Stands on corpses to regenerate | Shield bash, grave-slam leap, block/parry window |
| **Veilwalker** | Spirit-medium stepping between life and death | Veil (toggles form) | Walks through the Veil to see "echo corpses" others can't | Phase-shift: invulnerable in Veil but only deals spirit damage |

Party synergy target: every class *produces* or *consumes* corpses so a
4-player party negotiates the corpse field (the core fantasy scales to co-op).

---

## Release 0.4 — "The Deep Diocese" (combat systems & encounters)

### New enemy archetypes
| Enemy | Role | Tell | Corpse |
|---|---|---|---|
| **Choir Wraith** | flying caster, ignores terrain | pale blue song-lines before a scream | none (dissipates) — denies corpse farming |
| **Bone Golem** (elite-only) | walking wall of fused skeletons | ground cracks radiate before a slam | "Colossal" corpse = 3 Exhumes |
| **Lich Acolyte** | mirror-necromancer | raises *your* thralls against you if they die near it | normal |
| **Ossuary Swarm** | 20 tiny skull-rats | chittering; flows around obstacles | none |
| **Censer Bearer** | aura buffer | smoke cloud grants nearby enemies armour | resonant |

### Encounter systems
- ✅ *shipped (combat depth pack; surges open at area breaches, not the mausoleum props yet)* — **Grave Surges** (map events): a mausoleum cracks open and pours out a timed wave with a chest reward — optional risk bursts inside the farming loop.
- ✅ *shipped (combat depth pack; Shrouded = half damage outside miasma)* — **Elite affixes**: Bell-Tolled (periodic stun ring), Hungering (eats corpses to heal), Shrouded (only visible in miasma), Vengeful (explodes into Risen).
- ✅ *shipped 2026-09-26 (Elite Vanguard every other wave; Nightfall shrouds half the commons)* — **Wave Speed milestones** (the three diamonds): at each milestone, waves gain an affix (e.g. tier 3: elites +1, tier 6: surges more frequent, tier 8: "Nightfall" — the moon darkens and all enemies gain Shrouded).
- **Co-op session dashboard** (requested 2026-09-26): a host-side panel for co-op rooms that
  controls the session's tuning — active Wave Speed tier, enemy HP / damage multipliers, density
  (cap, wave size, interval), elite chance, Grave Surge frequency, arrival-wave size, per-area
  roster weights, and friendly-fire-style toggles later. Host-authoritative: the host's `WorldSim`
  applies it, guests see the values read-only, and realtime relays a clamped + tested `tuning`
  field (update `server/realtime/server.js` validation, then `node tools/embed-realtime.mjs`).
  Defaults come from `content/areas.ts`, `content/enemies.ts` and `waveModifiers`; presets can be
  previewed with `npm run balance` (see `BALANCE.md`). Rewards must scale with, or be capped by, the
  chosen difficulty so an easy preset can't be farmed for Wave-Speed-level loot.
- **Status matrix expansion**: Chill (from Mourner), Hemorrhage (marrow), Sanctified (enemy priests) — the icons already exist in `public/art/status/`.

### More bosses (one per area, each with a summoning key)
| Area | Boss | Mechanic |
|---|---|---|
| Hollow Graves | **The Gravedigger King** | Buries players (root) and digs up elites mid-fight |
| Marrow Ossuary | **The Bone Abbess** | Rebuilds herself from the walls; destroy skull-niches to stop regeneration |
| Drowned Nave | **The Drowned Congregation** | Water rises each phase; kneeling pews become cover |
| Bell Sanctum | **Bell-Sworn Prelate** | ✅ shipped |

---

## Release 0.5+ — "World & Endgame"

- **New areas** beyond the Sanctum: Plague Cloister (rot biome), Bell Tower (vertical climb arena), Catacomb Depths (procedural endless descent with depth tiers).
- **Nightmare tiers**: after the Prelate, the world can be re-rolled at a higher level band (server-side level cap raise needed).
- **Seasons**: rotating world modifiers (e.g. "Blood Moon": double corpses, double Deacons).
- **Guild chapterhouses**: a shared hub instance per guild with a communal reliquary (server work).
- **PvP ossuary duels**: only after loot/progression become server-authoritative (audit Phase 4).

---

## Technical prerequisites (track before building the above)

- Server columns for upgrade tiers / shards / area kills (spec: `server/proposals/necromancer-progress.md`).
- New item types (`rune`, thrall gear) require server `item_type` enum additions.
- Server-authoritative reward grants before any tradeable economy (audit Phase 4).
- VAT (vertex-animation-texture) crowd rendering if hordes exceed ~120 animated enemies.
