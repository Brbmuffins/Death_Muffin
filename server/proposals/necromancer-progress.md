# Proposal — server storage for necromancer progression

**Status:** SUPERSEDED (2026-09-26) by the ready-to-install package in
[`server/vps-handoff/necro-progress/`](../vps-handoff/necro-progress) and its brief
[`server/VPS_HANDOFF.md`](../VPS_HANDOFF.md). The package keeps the whole record as one validated JSON
row, adds Ascension/Ashes/boons, and makes the server own prices and gold. It is kept here
for history only; follow the handoff.
**Owner of the change:** the VPS (`/opt/rod-auth`). This repo never edits
server endpoints — this document is the spec to implement there.

## Why

The redesign adds progress the live schema has no column for. Today it lives
in `localStorage` (`cw_progress_v1_<characterId>`, see
`src/gameplay/progression.ts`), which means it is per-browser, lost if site
data is cleared, and trivially editable. Level, XP and gold already persist
via `POST /api/character/save-progress` and are unchanged.

| Field | Type | Meaning |
|---|---|---|
| `damage_tier` | TINYINT UNSIGNED (0–25) | Purchased Damage upgrade tier (+8% spell power each) |
| `wave_tier_owned` | TINYINT UNSIGNED (0–8) | Highest Wave Speed tier purchased |
| `wave_tier_active` | TINYINT UNSIGNED (0–8, ≤ owned) | The player's chosen risk level |
| `soul_shards` | INT UNSIGNED | Elite/boss currency; 5 summon the Prelate |
| `area_kills` | JSON `{ "graves": 123, … }` | Per-area kill counts (drive door unlocks) |
| `unlocked_areas` | JSON `["chapterhouse","graves",…]` | Opened seals |
| `boss_kills` | INT UNSIGNED | Prelate defeats |

## Schema (additive — no existing column changes)

```sql
CREATE TABLE IF NOT EXISTS character_necro_progress (
  character_id      INT UNSIGNED NOT NULL PRIMARY KEY,
  damage_tier       TINYINT UNSIGNED NOT NULL DEFAULT 0,
  wave_tier_owned   TINYINT UNSIGNED NOT NULL DEFAULT 0,
  wave_tier_active  TINYINT UNSIGNED NOT NULL DEFAULT 0,
  soul_shards       INT UNSIGNED NOT NULL DEFAULT 0,
  area_kills        JSON NOT NULL,
  unlocked_areas    JSON NOT NULL,
  boss_kills        INT UNSIGNED NOT NULL DEFAULT 0,
  updated_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_necro_progress_character FOREIGN KEY (character_id) REFERENCES characters(id) ON DELETE CASCADE
);
```
(Adjust the FK target to the real characters table name.)

## Endpoints (new routes only — existing routes untouched)

### `GET /api/necro-progress/:characterId`
JWT required; character must belong to the caller.
`{ success: true, data: { damageTier, waveTierOwned, waveTierActive, soulShards, areaKills, unlockedAreas, bossKills } }`
Missing row → defaults (`unlockedAreas: ["chapterhouse","graves"]`).

### `POST /api/necro-progress/purchase`
`{ characterId, upgrade: "damage" | "wave" }` — the server owns prices and
deducts gold atomically in one transaction, so gold and tiers can't drift:

```
damage cost(t) = round(40 × 1.5^t),   t < 25
wave   cost(t) = round(120 × 1.75^t), t < 8
```
Errors are player-readable (`"Not enough gold (need 96)"`, `"Already at max tier"`).

### `POST /api/necro-progress/save`
`{ characterId, waveTierActive, soulShardsDelta, areaKillsDelta, bossKillsDelta }`
Deltas, not absolutes; the server clamps each delta per call (e.g. ≤ 500
kills, ≤ 20 shards) and derives `unlockedAreas` from its own thresholds:
`ossuary: graves ≥ 300`, `nave: ossuary ≥ 420`, `sanctum: nave ≥ 520` (mirror
`AREAS[*].unlock` in `src/content/areas.ts`; raised in the 2026-09-26 balance pass).

### `POST /api/necro-progress/summon-prelate`
Deducts 5 shards atomically; returns the new balance. The client only sends
`summonBoss` to the realtime host after this succeeds.

## Client migration (once deployed)

1. `Progression` loads from `GET /api/necro-progress` and falls back to
   `localStorage` only when the route 404s (older server).
2. First successful load with a local record: POST the local values once
   (as deltas from zero) so existing players keep their tiers, then delete the
   local key.
3. `buyDamage` / `buyWave` call `purchase` and adopt the server's gold.

## New item types needed by FUTURE_CONTENT.md
- `item_type = 'rune'` (spell modifiers) — fully specified in `relic-runes.md` — and `'thrall_gear'`. These need the
  items enum extended and rows seeded; until then loot tables only reference
  ids the server already knows (`src/content/items.ts`, verified by
  `src/gameplay/__tests__/systems.test.ts`).
