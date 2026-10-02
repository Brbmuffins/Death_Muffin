# Proposal — Relic runes (spell modifiers)

**Status: SUPERSEDED (2026-10-02).** Relic runes were built in this repo against the Death Muffin backend (branch `dm/runes`): migration
`024-relic-runes.sql`, `backend/runes.cjs`, `src/content/runes.ts`. Differences from this proposal: **no `character_rune_sockets` table and no
`GET /api/runes`**: a socketed rune is a reserved inventory row (slots 130-134, `equipped_slot = 'rune_<rite>'`), moved by `POST /api/inventory/rune`;
rune ids equal their icon files (`rune_splinter`, not `rune_needle_splinter`); the behaviours were retuned (see HANDOFF.md "Relic runes"). Kept below
for history.

**Original status:** proposal only. The web client ships no rune content until the
server knows the item ids (`src/content/items.ts` is test-enforced against what the live server has).
**Design source:** `FUTURE_CONTENT.md` → Release 0.2 → "Spell modifiers (Relic runes)".

## Why

Runes are the build-depth layer. They change *how* a rite behaves instead of adding numbers
(Bone Needle that pierces, Exhume that raises three weaker thralls, and so on). They are items:
they drop, stack in the Reliquary, can be sold, and get socketed into one of the necromancer's
rites. That needs:

1. a new `item_type` value, `'rune'`,
2. ten seeded item rows,
3. somewhere to store which rune sits in which rite (one socket per rite).

## 1. Item type (additive)

Extend the items `item_type` enum with `'rune'`. No existing value changes. If the column is a
MySQL `ENUM`:

```sql
ALTER TABLE items MODIFY item_type
  ENUM('weapon','armor_head','armor_chest','armor_legs','ring','trinket','material','rune') NOT NULL;
```
(Keep the real current value list and just append `'rune'`; the client's `ItemType` union in
`src/net/types.ts` gets `'rune'` in the same release.)

## 2. Seed rows

One rune per behaviour in FUTURE_CONTENT. `stat_bonus` stays `NULL`: a rune's effect is defined by
its id on the client and host, not by stats. Column names follow the inventory join the client
already reads (`item_id, name, rarity, item_type, stat_bonus, icon_id, sell_value`); adjust them to
the real items table.

```sql
INSERT INTO items (item_id, name, item_type, rarity, stat_bonus, icon_id, sell_value) VALUES
  ('rune_needle_splinter', 'Rune of Splinters',   'rune', 'uncommon', NULL, 'rune_needle_splinter', 25),
  ('rune_needle_marrowtap','Rune of Marrow-Tap',  'rune', 'uncommon', NULL, 'rune_needle_marrowtap', 25),
  ('rune_needle_volley',   'Rune of the Volley',  'rune', 'rare',     NULL, 'rune_needle_volley',   60),
  ('rune_spear_ring',      'Ossuary Ring Rune',   'rune', 'rare',     NULL, 'rune_spear_ring',      60),
  ('rune_spear_impale',    'Rune of Impaling',    'rune', 'uncommon', NULL, 'rune_spear_impale',    25),
  ('rune_exhume_massgrave','Mass Grave Rune',     'rune', 'rare',     NULL, 'rune_exhume_massgrave',60),
  ('rune_exhume_colossus', 'Bone Colossus Rune',  'rune', 'epic',     NULL, 'rune_exhume_colossus', 150),
  ('rune_miasma_creeping', 'Creeping Rot Rune',   'rune', 'uncommon', NULL, 'rune_miasma_creeping', 25),
  ('rune_miasma_contagion','Contagion Rune',      'rune', 'rare',     NULL, 'rune_miasma_contagion',60),
  ('rune_litany_choir',    'Hollow Choir Rune',   'rune', 'rare',     NULL, 'rune_litany_choir',    60),
  ('rune_litany_requiem',  'Requiem Rune',        'rune', 'epic',     NULL, 'rune_litany_requiem',  150);
```

Runes stack like materials (quantity > 1 in one inventory row). Existing add-item / sell / delete
routes work unchanged once the ids exist.

## 3. Sockets (new table + two routes)

One socket per rite. Socketing moves one rune out of the stack. A rune is never destroyed:
unsocketing (or socketing a different rune) returns it to the Reliquary.

```sql
CREATE TABLE IF NOT EXISTS character_rune_sockets (
  character_id INT UNSIGNED NOT NULL,
  ability_id   VARCHAR(32)  NOT NULL,   -- 'bone_needle' | 'marrow_spear' | 'exhume' | 'miasma' | 'black_litany'
  item_id      VARCHAR(64)  NOT NULL,
  updated_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (character_id, ability_id),
  CONSTRAINT fk_rune_socket_character FOREIGN KEY (character_id) REFERENCES characters(id) ON DELETE CASCADE
);
```

### `GET /api/runes/:characterId`
JWT required; the character must belong to the caller.
`{ success: true, data: { sockets: { "bone_needle": "rune_needle_volley", … } } }` (empty object when none).

### `POST /api/runes/socket`
`{ characterId, abilityId, itemId | null }`, in one transaction:
- validate `abilityId` against the five rites and that `itemId` is a `'rune'` whose id prefix matches
  the rite (`rune_needle_*` → `bone_needle`, `rune_spear_*` → `marrow_spear`, `rune_exhume_*` →
  `exhume`, `rune_miasma_*` → `miasma`, `rune_litany_*` → `black_litany`);
- if the socket already holds a rune, add it back to the inventory (stack or first free slot);
- if `itemId` is set, remove one from the caller's inventory (404 `"You don't have that rune"` if
  absent), then upsert the socket; `null` just clears it.
- Return `{ success: true, data: { sockets, inventory } }` so the client adopts both at once.

Player-readable errors (the client shows them verbatim): `"You don't have that rune"`,
`"That rune doesn't fit this rite"`, `"Reliquary is full"`.

## 4. Where runes drop (client, after the ids exist)

- Elites: 4% per elite kill, from the area's rune pool (graves → uncommon only; ossuary+ → rare;
  sanctum → epic possible).
- Grave Surge offering: 25% chance to replace the guaranteed item with a rune.
- The Prelate: one guaranteed rune (epic 20%).

These go in `src/gameplay/loot.ts`. The item-id test keeps loot on ids the server knows.

## 5. Behaviour and authority (client + realtime; no REST involvement)

The caster's client reads its sockets and shapes the intents it sends. The host's `WorldSim` stays
authoritative and clamps each intent, exactly as it does today. The realtime server's
`validIntent` gains only clamps: `hit.ids` max length (volley/pierce), and the `exhume` count for
Mass Grave. Colossus becomes a new `ThrallKind`.

| Rune | Rite | Behaviour | Intent change |
|---|---|---|---|
| Splinters | Bone Needle | pierces to one more enemy behind the target | `hit.ids` up to 2 |
| Marrow-Tap | Bone Needle | +50% essence refund, −25% damage | none (client) |
| Volley | Bone Needle | 3 needles in a 30° cone, cooldown ×1.8 | `hit.ids` up to 3 |
| Ossuary Ring | Marrow Spear | spikes erupt in a ring (r 3.5) around the caster instead of a line | new target shape, same `hit` |
| Impaling | Marrow Spear | roots the first enemy hit for 1.2 s | `hit.root?: number` (host clamps ≤ 1.5 s) |
| Mass Grave | Exhume | raise from up to 3 corpses at once, each at 60% HP/damage | `exhume.count ≤ 3` |
| Bone Colossus | Exhume | consume 5 corpses in radius → one giant thrall (counts as 2 legion slots) | `exhume.kind: 'colossus'` |
| Creeping Rot | Miasma | the circle drifts 1 m/s toward the nearest enemy | `miasma.creep: true` |
| Contagion | Miasma | Withered enemies that die spread their stacks to the nearest enemy | `miasma.contagion: true` |
| Hollow Choir | Black Litany | doesn't sacrifice thralls; burst ×0.6 | `litany.spareThralls: true` |
| Requiem | Black Litany | detonates 2 s later at double radius | `litany.delayMs ≤ 2000`, `r ≤ 2 × max` |

Colour identity follows the existing spell (runes tint, they don't recolour; see `SPELL_FX`).

## Client migration (once deployed)

1. `ItemType` gains `'rune'`; the Reliquary gets a rune tab and each rite on the Rites panel gets a socket.
2. `Progression`/`WorldScene` load `GET /api/runes/:id` at world start; on a 404 (older server) the
   socket UI is hidden and no rune ids enter loot tables.
3. Realtime protocol bumps with the new clamps (deploy client + realtime together, as for v2).
