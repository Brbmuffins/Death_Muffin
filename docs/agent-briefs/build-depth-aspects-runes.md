# Brief: build depth — Rite Aspects (free sidegrades) and Relic Runes (boss-dropped transformations)

Written 2026-09-27 (evening) on the workstation for the **cloud code agent**, paired with
[`area-bosses.md`](area-bosses.md). Ground rules as in [`spell-variety-first-session.md`](spell-variety-first-session.md)
§1. Build **after** the spell-variety brief (it adds the 7 rites and loadout v2 that this extends). Aspects (§2) are
client-only and can ship alone; Runes (§3) need the Death Muffin backend and a deploy.

## 1. Why, and the shape

With 16 rites the Grimoire has **breadth**; what's missing is **depth** — two players with the same four rites play
identically, and nothing in the loot chases a playstyle. Two layers, deliberately different:

| Layer | What it is | How you get it | Where it lives |
|---|---|---|---|
| **Aspects** | Choose one of two *sidegrades* per rite (or none). Numbers-and-shape tweaks, never strictly better. | Free, unlocked by level (rite's unlock level + 3). Swap any time out of combat. | Client loadout (browser storage, like today's Grimoire) |
| **Relic runes** | One *transformation* socketed per rite: changes what the spell does. Stacks with the aspect. | Drops from the area bosses (and rarely elites at high Wave Speed). Items: tradeable later, sellable. | Death Muffin server (items + sockets) |

Rules that keep it sane: an aspect never removes the rite's identity; a rune is always a real behaviour change (not
+x%); aspect × rune combinations must all be valid (tests enumerate them); auto combat reads both.

## 2. Rite Aspects (client-only)

- Data: `content/aspects.ts` → `ASPECTS: Record<AbilityId, [Aspect, Aspect]>` with `{ id, name, text, mods }`, where
  `mods` are typed overrides the rite's code reads (`damageMult`, `cooldownMult`, `radiusMult`, `extraTargets`, flags).
  `AbilitySystem` gets `aspectOf(id)`; each rite reads its mods in one place.
- Unlock: `riteLevel() >= unlockLevel(rite) + 3` (dev access unlocks all). Both aspects unlock together.
- Storage: loadout v3 `{ primary, keys, aspects: Partial<Record<AbilityId, 'a' | 'b'>> }` with a v2 migration.
- UI: each Grimoire rite card gets two aspect toggles (name + one-line text; clicking the active one clears it); the HUD
  spell card shows the active aspect's name under the rite name; the Codex rite entry lists both.
- Host-side changes must use intent fields that already exist (e.g. `radius`, `durationMs`, `dps` are already
  host-clamped); anything else stays client-resolved. The realtime clamps stay the authority.
- Swapping an aspect keeps cooldowns (they belong to the rite) and is blocked while `castUntil` is in the future.

| Rite | Aspect A | Aspect B |
|---|---|---|
| Bone Needle | **Honed** — +30% damage, −2 essence per hit | **Quickened** — repeat 25% faster, −20% damage |
| Bone Fan | **Wide Fan** — 5 slivers over 40°, each 70% damage | **Tight Volley** — 3 slivers over 10°, +25% each; up to 2 may strike the boss |
| Rot Lance | **Long Rot** — its Withered lasts twice as long | **Barbed** — pierces 3 (not 2), no essence |
| Marrow Spear | **Deep Marrow** — Hemorrhage +40% | **Swift Spear** — cooldown −30%, damage −20% |
| Exhume | **Hasty Grave** — thralls rise 50% faster, −10% thrall HP | **Stubborn Dead** — +25% thrall HP, +4 essence cost |
| Miasma Circle | **Lingering** — lasts 9 s (not 6) | **Choking** — radius −25%, slow 60% (not 40%) |
| Black Litany | **Measured Rite** — −15 essence, −25% power | **Full Rite** — +30% radius |
| Wailing Skull | **Howling** — +1 leap | **Screaming** — first bite +50%; kills no longer earn leaps |
| Grave Step | **Long Step** — range 16 m | **Red Harvest** — burst radius +50% |
| Grave Frost | **Deep Chill** — Chill lasts 5 s | **Brittle** — shatter +100% (not +50%) |
| Bone Mantle | **Bulwark** — barrier cap +15% of max HP | **Whirl** — shards tick every 0.35 s |
| Grave Offering | **Feast** — +50% essence, no heal | **Mend** — heal 8%, half the essence |
| Ivory Cleave | **Reaping** — 180° arc, −15% damage | **Cleft** — 2 Fracture stacks |
| Veil Step | **Far Veil** — 8 m | **Slipstream** — cooldown −3 s |
| Rally the Dead | **War Cry** — +20% more damage, −2 s duration | **Second Wind** — heals 40% (not 20%) |
| Carrion Seed | **Twin Seeds** — 2 live seeds, −20% damage each | **Blight** — the burst leaves a 3 s rot pool (the existing friendly `rot` zone) |

(Signatures and Corpse Explosion stay aspect-free in v1.) Help: a counsel tip the first time an aspect unlocks
("Your rites have learned a second voice — open the Grimoire (L)"), a Codex section, README.

## 3. Relic runes (Death Muffin backend + client)

`server/proposals/relic-runes.md` was written for the old shared server. The live game now runs on the **Death Muffin
backend in this repo** (`server/death-muffin/backend/`, owner-authorised), which has its own `items` table — follow
that proposal's shape, adapted as below.

### 3.1 Items

Item ids **must match the existing icon files** (inventory loads `art/items/<id>.png` by id):

| id (icon exists) | Rite | Transformation | Rarity |
|---|---|---|---|
| `rune_splinter` | Bone Needle | a hit splits the needle toward the nearest other enemy for 50% | uncommon |
| `rune_marrow_tap` | Bone Needle | +4 essence per hit, −30% damage | uncommon |
| `rune_volley` | Bone Needle | every 4th cast fires 3 needles at 3 targets | rare |
| `rune_ossuary_ring` | Marrow Spear | spikes erupt in a ring (r 3) at the cursor instead of a line | rare |
| `rune_impale` | Marrow Spear | roots the first enemy hit for 1.5 s (boss: 0.3 s) | uncommon |
| `rune_mass_grave` | Exhume | raises up to 3 nearby corpses at once, each at 60% HP | rare |
| `rune_bone_colossus` | Exhume | consumes 5 corpses → one giant thrall (3 cap slots, 3.5× HP, 2× damage) | epic |
| `rune_creeping_rot` | Miasma Circle | the circle drifts toward the nearest enemy (1.5 m/s) | uncommon |
| `rune_contagion` | Miasma Circle | a Withered enemy that dies passes its stacks to 2 neighbours | rare |
| `rune_hollow_choir` | Black Litany | no thrall sacrifice; −40% power | rare |
| `rune_requiem` | Black Litany | the burst lands 2 s later at double radius | epic |

- Migration `server/death-muffin/backend/migrations/003-runes.sql`: insert the 11 rows (`item_type 'rune'`, stackable,
  `icon_id` = id, sell values 25 / 60 / 150 by rarity). **Check the real `item_type` column type first** (ENUM →
  append `'rune'`; VARCHAR → nothing), exactly as `002-gathering.sql` did for materials. Idempotent (`ON DUPLICATE KEY`).
- Client: `ItemType` += `'rune'`; add the 11 to `items.ts` (the id test then allows them); Reliquary shows runes in
  their own tab/filter; sell works as for materials.

### 3.2 Sockets

- Table `character_rune_sockets (character_id, ability_id, item_id, updated_at, PK(character_id, ability_id))`
  in the same migration.
- `GET /api/runes/:characterId` and `POST /api/runes/socket { characterId, abilityId, itemId | null }` in one
  transaction, as the proposal specifies: ownership check, rune must fit the rite (table above), an occupied socket
  returns its rune to the bag first, errors are player-readable (`"You don't have that rune"`, `"That rune doesn't fit
  this rite"`, `"Reliquary is full"`). Return `{ sockets, inventory }`. Tests beside `gathering.test.cjs`.
- Offline mock backend (`src/net/mockBackend.ts`) implements both routes so `?offline` QA works.
- Co-op: the rune changes the caster's own intents (spear ring, mass exhume…). Where the host must know (Mass Grave,
  Bone Colossus, Requiem, Contagion, Creeping Rot), add a validated optional field to the existing intent (`exhume.count`
  ≤ 3, `exhume.colossus`, `litany.delayMs` ≤ 2000, `miasma.drift`, `miasma.contagion`) and the realtime clamps + tests;
  old hosts ignore the fields (the spell then behaves as base — acceptable).

### 3.3 UI & help

- Grimoire rite card: a rune socket (empty-socket frame + the rune icon) under the aspect toggles; click → a picker of
  runes in the bag that fit. Rites without a rune family show no socket.
- HUD spell card: rune line under the aspect line. Codex: a **Relic Runes** section listing all 11 (unowned ones
  sealed with "Drops from: <boss>"). Counsel tip on the first rune drop. README.

### 3.4 Where runes drop (ties to the area bosses)

| Boss | Pool |
|---|---|
| Gravedigger King | `rune_splinter`, `rune_marrow_tap`, `rune_mass_grave` |
| Bone Abbess | `rune_ossuary_ring`, `rune_impale`, `rune_bone_colossus`, `rune_volley` |
| Drowned Congregation | `rune_creeping_rot`, `rune_contagion`, `rune_hollow_choir` |
| Bell-Sworn Prelate | `rune_requiem` + any of the above |

First kill of each boss guarantees one from its pool; repeats roll 35%. Elites at Wave Speed tier ≥ 6: 0.5% for any
uncommon rune. Loot uses the normal item pickup path (server-validated ids).

## 4. Art

Rune icons: `public/art/items/rune_*.png` (11, existing). Rite icons exist. The socket frame can be CSS; if the
workstation should paint one, add a line to §5 and leave CSS in place meanwhile.

## 5. Open art requests (the workstation fills these)

- [ ] (optional) `public/art/ui/rune-socket.png` empty-socket frame.

## 6. Tests & docs

Aspect × rune validity matrix, loadout v3 migration, aspect unlock by level (and dev access), every rune's behaviour
(host-side fields clamped), socket route transactions (bag full, wrong rite, missing rune), mock parity, balance harness
runs with a few aspect/rune builds (report in `BALANCE.md`). Docs: README, Codex, `FUTURE_CONTENT.md` (runes ✅),
`server/proposals/relic-runes.md` (mark superseded by the Death Muffin implementation), `server/death-muffin/` deploy
notes (migration 003 + restart), `HANDOFF.md`, `PHASE_REPORTS.md`, this brief's row in `docs/agent-briefs/README.md`.
