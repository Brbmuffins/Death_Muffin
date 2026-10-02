# Server authority, step 1: plausibility guards

Status: built on `dm/server-authority`, **not deployed**. Default mode is `report`, which never changes a save.

Until now the browser has been trusted with level, XP, gold and its bag (fine among friends). This step does not move any reward
onto the server and does not change how honest play feels. It adds guards that ask one question on every save: *could this
character have earned that much in the real time that passed?* A "no" is logged (report) or held back with a readable message (enforce).

## Switching modes

Set `AUTHORITY_MODE` in the backend env (`/home/ubuntu/death-muffin/backend/.env`) and restart the API:

| value | effect |
|---|---|
| unset, `report`, or anything else | **report** (default). Every guard runs and writes `progress_audit` rows plus an `[AUTHORITY]` log line. Saves and replies are exactly as before. |
| `enforce` (exact, case-insensitive) | Guards clamp or refuse what is not believable and the reply carries `authority.message` (the client shows it as a toast). |

The value is read on every request, but the service only reads `.env` at start, so a restart is needed to switch.

**Suggested rollout:** apply migration 021, deploy with `report`, play for a few days (friends will exercise it), then read
`progress_audit` (queries below). If honest saves show up there, adjust the constants in `src/gameplay/authorityRules.ts`
(`npm run build:server-rules`) before enforcing. Only then set `AUTHORITY_MODE=enforce`.

```sql
-- what has been flagged, newest first
SELECT a.created_at, ac.username, a.character_id, a.kind, a.mode, a.action, a.detail
  FROM progress_audit a JOIN accounts ac ON ac.id = a.account_id ORDER BY a.id DESC LIMIT 50;
-- who trips it most
SELECT account_id, character_id, kind, COUNT(*) n FROM progress_audit GROUP BY 1, 2, 3 ORDER BY n DESC LIMIT 20;
```

Server log: `journalctl -u <api unit> | grep '\[AUTHORITY\]'`.

## What is guarded

| Route | Guard | Report mode | Enforce mode |
|---|---|---|---|
| `POST /api/character/save-progress` | **XP / level**: lifetime XP (`50·L·(L-1) + xp`) may rise only by the character's allowance; level cannot jump beyond what that XP buys | log `xp_rate` | level/XP clamped to the allowance, message |
| | **Gold**: a rise may not exceed the gold allowance plus sale credit | log `gold_rate` | gold clamped |
| | **Stale save**: lifetime XP never decreases | log `xp_stale` | the newer level/XP is kept |
| | **Stats**: base stats can only be echoed (nothing in the game raises them) | log `stat_raise` | stats kept |
| `POST /api/inventory/save` | per item: more of an item than the bag held is "introduced"; only items that come off the ground may be, at the ground's pace | log `item_intro` | extra units trimmed (highest slot first), message; the reply carries the real bag |
| `POST /api/inventory/add-item` | same per-item allowance | log | refused (400, readable) |
| `POST /api/loot/roll-gear` | the item must exist in a drop table (area loot, mob reagent, boss ichor) | log `roll_gear` | "That drop could not be rolled." |
| `POST /api/offline/load` | the offline save is compared with the online one | log `offline_load` | 409 `implausible: true` until the request carries `confirmImplausible: true`; the client asks the player and re-sends |
| `POST /api/offline/sync-stats` | same, with only level/XP to judge | log | same 409 |

Notes:

- **Fail open.** If the tables are missing (migration not applied) or a guard query fails, the save goes through unchecked and one
  `[AUTHORITY] ... unavailable` line is logged. Verified by the probe with the tables renamed away.
- **Staff exempt.** Accounts the server already treats as staff (`role` admin/gm or `gm_enabled`) skip every guard (dev access:
  `__cwDebug.god()`, debug leveling). Add nothing to the audit for them.
- **Report mode is byte-for-byte the old behaviour** for the saved rows and for the HTTP reply (no extra field). Only the audit rows,
  the `character_authority` bookkeeping and log lines are new. The probe asserts this step by step.
- An enforce-mode clamp never loses honest progress permanently: the client keeps resending its absolute level, XP and gold, so what
  was held back arrives as the allowance refills. A held-back item is simply not in the bag the reply returns (the client adopts the
  server's rows after every bag save).

## The mechanism: allowances that refill with time

Per character, `character_authority` stores two buckets (XP, gold) and a bucket time. On each `save-progress`:

```
bucket = min(cap, bucket + perMin × minutesSinceLastSave)        cap = perMin × 60 min + burst
gain   = newLifetimeXp − storedLifetimeXp                         (gold likewise, increases only)
gain ≤ bucket  → accepted, bucket −= gain
gain >  bucket → flagged; enforce writes stored + bucket instead
```

A bucket (not "rate × time since last save") is what stops a cheat from saving every second to collect a fresh burst each time. A
character the server has not seen yet starts with 2 minutes in the bank. Idle time banks for at most 60 minutes. The same bucket idea
is kept per item (`item_budget` JSON) and for gold credit from sales (`gold_credit`). `character_authority` also keeps
`last_progress_at`, `last_bag_at`, lifetime accepted XP/gold and a flag count.

## Ceilings and how they were derived

All numbers live in `src/gameplay/authorityRules.ts` and are bundled to `gathering/authority-rules.cjs` (`npm run build:server-rules`;
a unit test fails if the bundle is stale).

### XP and gold per real minute

1. **Best honest rate per hunting ground** (`AREA_PEAK`) is measured with the balance harness, which plays the real sim:
   `BALANCE_DIFFICULTY=hard BALANCE_SEEDS=2 BALANCE_BANDS=max BALANCE_KIT=auto npm run balance` over all nine disciplines and all nine
   grounds (2026-10-02). That is Hard difficulty (×1.3 rewards), Wave Speed 8 (the most a player can dial; ×2.05 gold and ×1.55 XP per kill, Nightfall bonus included, plus faster, denser waves), the ascended kit, rank 0, and the best discipline per column. Kill rate, elites, drops and boss-less farming are all in it.
2. **Multipliers the harness does not apply**, at their maximum: kill chain Requiem ×1.25, the weekly Omen ×1.2, a wisdom tonic ×1.25 (XP only).
3. **Ascension.** Rank adds ×(1 + 0.05·rank) and ages every enemy +3 levels per rank; XP per kill scales `1 + 0.25·(level−1)` and gold
   `1 + 0.15·(level−1)`, so the ground's peak is rescaled by the ratio of enemy levels. The rank used is the character's own plus
   **2** (a co-op guest earns at the *host's* rank, which the guest's own record cannot show). Level-scaled grounds (Cloister, Pyre, Fen)
   follow the character's stored level.
4. **Which ground.** The best ground in the character's `character_necro_progress.unlockedAreas` sets the rate (the server already
   keeps that record and validates kills per save). A character with no combat ground unlocked gets no XP rate and a flat
   1,500 gold/min (labour, contracts).
5. **Headroom ×3** over all of the above (party play, a human out-killing the bot, tool noise). Lump sums that do not scale with time
   (boss XP ≈ 1,200; milestone gold, 47 of them, 8,000 at most each) are covered by a flat burst: 5,000 XP, 40,000 gold.

Resulting ceilings (per minute, level 1 / rank 0 unless noted; rank +2 and ×3 headroom already included):

| Best unlocked ground | XP/min | gold/min |
|---|---|---|
| Hollow Graves | 31,185 | 23,231 |
| Marrow Ossuary | 53,080 | 34,859 |
| Drowned Nave | 94,688 | 61,436 |
| Bell Sanctum | 140,405 | 85,917 |
| Plague Cloister (level 20) | 187,357 | 105,153 |
| Cinder Pyre (level 30) | 318,467 | 172,204 |
| Mourning Fen (level 45) | 520,894 | 141,162 |
| none (Acre only) | 0 | 1,500 |

These are deliberately far above normal play (BALANCE.md: the max band already earns about 1.7× the XP and 2.3× the gold of the
*intended* band, the ceiling is 3× the max band plus the unmodelled multipliers, and a person is not a perfect bot). They still bite: a fresh character cannot reach level 255 (3.2M XP) in under ~100 minutes
of top-rate farming, and the first save of an unseen character can claim only 2 minutes (≈ 67k XP, ≈ level 37).
The owner's character (level 135, rank 1, Warren unlocked) has a ceiling of about 67k XP/min against a lifetime of ~905k.

### Items

`GROUND_RATES` is, per item, the most a character could pick up per minute, derived from the same tables the client rolls
(`content/areas.ts` loot weights and `itemChance`, elites ×6 on area loot, `content/reagents.ts` mob and area reagent chances with the
elite ×4, Wave Speed 8's item-chance bonus, a fortune tonic +30%, and each ground's peak kills/min from the harness). Boss ichors
are 0.5/min (a summon costs shards and a 2-3 minute fight). `×3` headroom, banked for 10 minutes, plus a burst of two minutes (min 4).
Examples (per-minute rate / cap): boss ichor 1.5 / 19; moon staff 1.3 / 18; Ascended Ossuary boots 3.1 / 38; reagent Grave Dust 16 / 193;
copper ore 38 / 450; iron helm 86 / 1,028.

An item is one of two classes:

- **ground** (appears in an area loot table, a mob's reagent drops, or is a boss ichor; 179 item ids): may be introduced up to its allowance.
- **server-only** (everything else: planks, ingots, tools, bone meal...): crafting, gathering, salvage, labour, garden and vault
  routes already write these to the database themselves, so a *bag save* never legitimately adds one. Allowance 0.

"Introduced" means a bag save contains more of an item than the bag range it speaks for held in the database at that moment, so
moving, splitting, selling and equipping are never flagged, and a stale 24-slot tab only judges slots 0-23. Items that left the bag
credit the gold bucket by their `items.sell_value` (selling), up to 3M, so a bulk sale never trips the gold guard.

**Gathering.** Checked: `POST /api/gather` rolls loot, XP and gold server-side from the shared rules, clamps actions to the elapsed
time (`checkBudget`), and writes items, gold and skill XP in one transaction; the client names no item or amount. Labor, garden,
contracts (payout computed server-side), salvage, craft and vault do the same. So gathered materials and charms already arrive in the
database before the bag save, which therefore shows no increase. (Gold from contracts and labor is *returned* to the client, which
adds it to its total; that gold is covered by the gold allowance.)

### Offline full sync and sync-stats

The offline edition is a complete browser-only game, so a legitimate offline save can be far ahead of the online one. The server
cannot measure time spent offline, so the check uses the offline save's own `chronicle.life.playSeconds` beyond the online save's (at
least 10 minutes, at most 7 days) at the rate ceiling of the *offline* save's unlocked grounds and rank, for XP and gold, plus the
ground-item pace for items that appear in a drop table (crafted things are not checked, the offline edition crafts too). Only
increases count. `playSeconds` is client-supplied, so this is a tripwire for big jumps, not proof.

Report mode logs it and loads as before. Enforce mode answers 409 with `implausible: true`; the client (`src/offline/install.ts`)
asks the player ("Load it anyway?") and re-sends with `confirmImplausible: true`. The existing backup is unchanged: the online save
and the offline copy are both stored as versions before anything is applied, and a confirmed implausible load is audited with
`action = 'confirm'` so staff can find it and restore the previous version.

## Data

Migration `021-server-authority.sql` (additive, idempotent, FK-cascade on character/account delete):

- `character_authority` (one row per character, created on first save): buckets, `bucket_at`, `gold_credit`, `item_budget`, `last_progress_at`, `last_bag_at`, `xp_accepted`, `gold_accepted`, `flags`.
- `progress_audit` (one row per finding): `kind` (`xp_rate xp_stale gold_rate stat_raise item_intro roll_gear offline_load`), `mode`, `action` (`report clamp refuse confirm`), `detail` JSON.

Rollback: `DROP TABLE progress_audit; DROP TABLE character_authority;` (nothing reads them but the guards, which fail open).

## Tests

- `server/death-muffin/backend/authority.test.cjs`: each guard in both modes with the fake-connection pattern (`authority-fake-db.cjs`, `bag-fake-db.cjs`); in `npm run test:server`.
- `src/gameplay/__tests__/authority-rules.test.ts`: curve arithmetic, ceilings follow progress, every drop-table item is a ground item, the bundle is fresh.
- `tools/qa/authority-db-probe.cjs`: real `server.js` against a scratch MySQL database built from the live schema, once per mode (header explains setup).

## What is still trusted

This is a tripwire, not authority. After step 1 the client still:

- **rolls every kill reward** (XP, gold, drops, shards, boss kills). A cheater who stays under the ceilings (at least 3× what the best measured bot earns at
  the max band in the best unlocked ground) keeps that much unearned progress. Step 2 is to have the server roll rewards from a
  server-validated kill (the host-authoritative sim lives in the browser, so this needs a trusted sim or kill attestations).
- **chooses its ground and rank.** `unlockedAreas`/`ascension` come from `character_necro_progress`, which already caps kills per save
  but is itself fed by client-reported kills (`NECRO_LIMITS.killsPerSave` = 900), so it bounds a cheater only loosely. A guest's rank in a host's world is guessed as own rank + 2.
- **reports time implicitly.** Real time is the server's clock between saves, but a long-idle character can bank 60 minutes of allowance.
- **offline saves** carry their own `playSeconds` and necro state, and a confirmed implausible load goes through. If strangers can
  use the offline edition, the safer policy is to require staff approval or disable `confirmImplausible`.
- **gold after the fact.** Gold can still be spent or sold for what the game says; only gains are bounded. Item `sell_value` credit trusts bag contents the guard already limited.
- **ground items within the allowance**, and gear *instances*: `roll-gear` still trusts the client's `level` and `source` (already clamped to the character's level, `affixRules.clampDropLevel`) and only checks that the item can drop somewhere, not where the player is.
- **crafting inputs** are real server rows, but the first four layers above feed them.
- Races: two simultaneous saves can both read the same allowance (the row is read `FOR UPDATE` but not held across the route's later write on `characters`). The excess is at most one save's gain and is audited.

## Deploy checklist

1. Apply `migrations/021-server-authority.sql` (new tables only). The deploy script copies `authority.cjs` and `gathering/authority-rules.cjs` with the other backend files.
2. Leave `AUTHORITY_MODE` unset (report). Ship the client with the server (it adds the notice toast and the offline confirm prompt; both are inert until `enforce`).
3. Watch `progress_audit` and the `[AUTHORITY]` log. Expect no rows from honest play.
4. To enforce: add `AUTHORITY_MODE=enforce` to the backend `.env`, restart the API. To undo: remove the line, restart.
