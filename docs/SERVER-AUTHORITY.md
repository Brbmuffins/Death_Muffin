# Server authority

Two steps. **Step 1 (plausibility guards)** is deployed in `report` mode. **Step 2 (the kill ledger)** is built on `dm/authority-2`, **not
deployed**, off by default: [jump to Step 2](#step-2-the-kill-ledger). Step 2 builds on step 1 and does not replace it.

## Step 1: plausibility guards

Status: deployed 2026-10-02, mode `report`, which never changes a save.

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
| `POST /api/gold/adjust` (legacy) | crediting gold is staff-only in every mode; spending is open and row-locked | - | - |
| `POST /api/combat/kill`, `/api/loot/roll`, `/api/loot/drop` (legacy) | pay XP, gold or items for a client-chosen enemy id; the browser never calls them | unchanged | 403 for non-staff |
| `POST /api/reforge`, `/api/reforge/quote` (gold sink) | the server prices (never the client) and rolls; gold is taken under the character row lock; ownership of the character and of the piece's instance is checked | - | - |
| `POST /api/boss-key/status\|summon\|refund\|claim` (gold sink) | Seal + gold taken server-side; the prize is rolled server-side, only for a summon the character paid for, once, 10 s to 3 h after it. `status` answers which summons are still bound (the free retry survives a reload). With `AUTHORITY_KILLS` audit/enforce the claim also needs a kill the ledger received (the boss kill report names the summon id): audit logs `boss_key_no_kill` and still pays, enforce refuses | - | - |

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

**The Catacomb Depths** (added 2 Oct 2026, branch `dm/depths`) are a source like any ground. They are not in `unlockedAreas` (an instance is opened by a run, not a seal), so the ceiling counts them for any character whose record has **opened the Warren** (the stair is in its west chamber). Their peak (`AREA_PEAK.depths`, 27,600 XP / 16,000 gold / 72 kills per minute) was measured on held floors of depth 5, 10 and 20 for a level-40 hero, best column of the nine disciplines, then rescaled to enemy level 50 (depth 10 for that hero). Enemies there are `max(12, hero level) + depth`, so the ceiling is rescaled to the enemy level the character could be facing: the deepest floor its **Chronicle** records (`peak.depth`, read by `authority.cjs necroSummary`; the offline snapshot's own chronicle for an offline load) plus a slack of 3 (a chronicle flush is up to 30 s behind the stairs), capped at 120. A character with no record is judged as if on depth 3. The Depths never lower a ceiling another ground sets. Items: kills drop from the Ossuary, Coliseum, Sanctum, Cloister, Pyre and Fen tables by depth, so every id already had an allowance; `GROUND_RATES` now also counts the Depths' kill rate on those tables, a floor-clear drop (65% per floor, at most 3 floors a minute), a chest's drops (at most 0.5 chests a minute) and a chest's rune.

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

## Owner decisions (2026-10-03)

- Staff-account characters (gm_enabled, e.g. Brbmuffins) **stay on the public leaderboard**, unmarked.
- Offline loads that were confirmed as implausible **stay on the leaderboard** (no exclusion; the kill ledger re-bases on an offline load).
- The co-op guest allowance (paid at the guest's own level, 2 ranks of slack) **is enough**; audit mode will still show `kill_invalid` `ground`/`level` rows if real guests get docked.

## What is still trusted

(After step 2 the kill, shard, Prelate, depth, play-time and run items below are bounded by the ledger; see [Step 2](#step-2-the-kill-ledger).) This is a tripwire, not authority. After step 1 the client still:

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

---

# Step 2: the kill ledger

Status: built on `dm/authority-2` (migration **036**), **not deployed**, `AUTHORITY_KILLS` unset = `off` = today's behaviour exactly.

## Why `progress_audit` has 0 rows (checked 2026-10-03, read-only)

Nothing is broken. `AUTHORITY_MODE` is unset (so `report`), the migration is applied and the guards ran, but report mode only writes a row when a
save looks wrong, and nothing has. Also: only one non-staff character has ever saved since the guards shipped (`character_authority` has one row,
character 129, flags 0, accepted 30k XP); the owner's character (#97, level 255) belongs to a `gm_enabled` account, and **staff are exempt, so no row is
written for them at all**. The other 10 accounts have no character. So "0 rows" means "no evidence yet", not "the check is off". Step 2's audit mode
is built to produce evidence even from honest play (below).

## What the browser could still assert after step 1

| Number | Where it came from | Bound after step 1 |
|---|---|---|
| level / XP / gold | `save-progress`, absolute values | the XP/gold bucket: 3x the best bot's rate at the best open ground, 60 minutes banked |
| total kills (leaderboard) | `necro-progress/save`, `areaKills` | **none in time**: 900 per save, only a limiter of 60 necromancer requests a minute: up to 54,000 kills a minute |
| soul shards -> Prelate summons -> boss kills -> Ascension rank (leaderboard's top sort key) | `necro-progress/save`, `shards` 30 per save, `prelateKills` | **none in time**: shards 30 per save, a summon is 5 shards |
| deepest Depths floor | Chronicle `maxes.peak.depth` | +25 floors per request, no time bound, nothing proves a floor was cleared |
| play time | Chronicle `deltas.playSeconds` | none (any number up to 50,000,000 per request) |
| runs | Chronicle `ascend` | none (any ascension number 0-255 archives a run) |
| items | bag save | per-item allowance by time (step 1) |
| drops' item level and affixes | `loot/roll-gear` | server rolls them (already) |

## Design

The browser still plays the sim. What changes: it **reports every kill** (what died, where, at what level, elite or not, plus the multipliers its reward
used) in small numbered batches that ride along with the progress save (one request: the credit is on the ledger before the gain is judged). The server
validates a batch against real time and the game's own tables and turns the valid part into **credits**: kills per ground, XP, gold, soul shards, Prelate
kills, Depths floors. The routes that carry progression can then only pay out of credits.

```
client kill -> KillReporter (groups identical kills, seals numbered batches)
            -> rides on POST /api/character/save-progress {killReports} (or POST /api/kills/report alone)
server      -> kills.cjs handleReport: seq check, time buckets, ground/kind/level/mix/elite checks (gathering/kill-rules.cjs)
            -> character_kill_ledger: credits (kills per ground, XP, gold, shards, prelate), buckets, grandfathered baselines
save-progress   level/XP/gold gain  <- XP / gold credits  (+ a small refilling lump for non-kill income)   [kills.creditPass]
necro save      areaKills, shards, prelateKills <- credits   (express middleware in front of the necro routes)  [kills.necroGuard]
chronicle       playSeconds <- wall clock; peak.depth <- proven floors; runs <- Ascension record               [kills.guardChronicleAdd, mayArchiveRun]
leaderboard     totalKills <= ledger base + validated kills (enforce)
```

**What a kill is worth (`src/gameplay/killRules.ts`, bundled to `gathering/kill-rules.cjs`).** XP is deterministic in the game (`loot.ts rollKill`), so
the server's number is **exact** (a unit test compares it with `rollKill` for every enemy, level, tier and difficulty). Gold and shards are random draws:
the credit is the **best roll the game could have made** (an enemy's top gold, 2 shards per elite), so an honest client is never short and a cheater never
beats the luckiest honest player. The client's own multipliers (Ascension, chain, Omen, tonic, New Blood catch-up) are reported but **capped** at what play can reach
(`multCaps`). Bosses pay `rollBoss`'s own numbers; a Depths floor clear pays `floorBonus` and a chest `chestBonus`.

**What the server checks in a batch, and what it drops (named in `progress_audit`):**

| Check | Rule | Audit kind |
|---|---|---|
| replay | `seq` must exceed the last accepted; an exact repeat (a retry after a lost reply) is a silent no-op, an older one is audited; a `seq` more than 10 minutes in the future is refused | `kill_replay` |
| rate | a kill bucket refills at 1.5x the best honest kills/min of the best ground the character has open (`AREA_PEAK.kills`, so 308/min with only the Graves, 390 with the Nave), banks 30 minutes, starts with 5; reports cannot be chopped to beat it | `kill_rate` |
| ground | combat ground, open for the character (or one seal ahead, so the batch that opens a seal counts); the Depths need the Warren | `kill_invalid` (why `ground`) |
| kind | the enemy must live in that ground: its spawn table, the processions that visit it, their leads, plus raised Risen and Deacon penitents; inert niches never | `kill_invalid` (why `kind`) |
| level | the ground's level aged by Ascension (record rank + the co-op allowance of 2); level-scaled grounds follow the hero's level +15; the Depths follow depth | `kill_invalid` (why `level`) |
| mix | per kind, at most 2x its best honest share (own weights or a procession's, pack sizes counted) + 12 | `kill_mix` |
| elites | at most 2x the ground's best honest elite chance + 6 per batch | `kill_elite` |
| difficulty | a known difficulty; wave tier capped at 8 | `kill_invalid` (why `difficulty`) |
| bosses | known boss, ground open, 1.5/min bucket (10 minutes banked) | `boss_rate`, `boss_invalid` |
| floors | a clear at depth d needs d-1 cleared before (grandfathered from the Chronicle), 6/min bucket, Warren open | `floor_rate`, `floor_invalid` |
| claims vs credit | a save's gain beyond credit + lump; claimed kills/shards/Prelate kills beyond credit | `unbacked_xp`, `unbacked_gold`, `unbacked_kills`, `unbacked_shards`, `unbacked_prelate` |
| Chronicle | play time beyond the clock; peak depth beyond proven floors + 1; runs beyond Ascensions + 1 | `play_rate`, `depth_peak`, `run_count` |

**Lump allowance.** XP that is not a kill (rounding, a race) refills at 300/min up to 3,000. Gold that is not a kill (contracts, labour, milestones, a Grave Surge,
gathering finds) refills at 1,500/min up to 130,000 (the step-1 non-combat rate and burst). Item sales credit gold as in step 1.

**Honest play is not docked (the key test).** `kill-rules.test.ts` plays the real balance bot (Hard, Wave Speed 8, ascended kit; necromancer and a New Blood class; Graves,
Ossuary, Nave, Sanctum, Cloister, Fen at rank 1, and a Depths floor with floor clears and chests), feeds its kills to the ledger in 45-second reports, and asserts
**nothing is dropped** and the credits cover the bot's XP, gold and shards.

## Modes (`AUTHORITY_KILLS`, independent of `AUTHORITY_MODE`)

| value | effect |
|---|---|
| unset / `off` | reports are acknowledged and ignored; no table is touched; every route is byte-for-byte as before |
| `audit` | the ledger is kept, saves are compared with it and **never changed**. Findings go to `progress_audit` with `mode = 'audit'`. Balances move exactly as they would in enforce |
| `enforce` | claims are paid out of credits only: unbacked XP/gold/kills/shards/Prelate kills are clamped, the player gets a readable message (reload hint if the client never reports), unreportable chronicle numbers are bounded. **Also turns on step 1's clamp for save-progress** (otherwise a claim built from the richest allowed kills could exceed step 1's rate ceiling) |

Read on every call (restart needed only because the service reads `.env` at start). Every function **fails open**: a missing table or failed query never costs a save;
staff (`role` admin/gm or `gm_enabled`) are exempt from every clamp. Client side nothing is flag-gated: the browser always reports (cheap, batched with the save), an old
server ignores the extra field.

## Existing leaderboard entries

**Grandfathered.** The ledger row is created at first sight with `kills_base` = the character's necromancer `total_kills` and `depth_proved` = its Chronicle
`peak.depth`, so every existing number stands and only new gains need a ledger behind them. Nothing is recomputed or hidden. If an existing row is inflated, the
owner decides case by case (SQL below); an offline load or a necromancer import **re-bases** the ledger on the new totals so honest offline progress shows.
Staff-account characters stay on the board unmarked (character #97 included): hide or mark them if the board should show only verified numbers.

## What stays trusted after step 2

- **Items.** Drops are still client-rolled and picked up; they stay under step 1's per-item time allowance. Server-rolled drops need a ground-drop protocol (the server
  telling the client what dropped) and overlap `dm/loot-achievable` and `dm/gold-sinks`; the ledger already rolls nothing there. Step 2b.
- **The maximizing cheater** is bounded by step 1's rate ceiling (the stricter of the two applies), not by honest play: ~15x the bot's XP at the Graves. What changes is that kills,
  shards, Prelate kills, Ascension, depth, play time and runs (the leaderboard) are now bounded by time and by each other, not asserted.
- **A forged "kill"** inside the rate and mix limits is credited: there is no trusted sim. The bound is time, not proof.
- **Guests in a stronger host's level-scaled ground** are paid at their own level (the same assumption step 1 makes); audit will show how often that docks a real guest.
- **Offline saves** still carry their own `playSeconds` (step 1's tripwire). After a confirmed load the ledger re-bases on the loaded record.
- **Milestone gold** is claimed per browser (localStorage); the lump allowance bounds it.
- Chronicle counters that are not on the board (`kills`, `gold.earned`, `boss.*`, ...) are still bounds-and-shape only.

## Gold sinks and the kill ledger

`dm/gold-sinks` ties its Empowered-boss prize to this ledger. A boss kill report may carry `summon` (the id of the character's bound `empowered_summons` row); `kills.cjs` stamps `killed_at` on that row when the report is accepted (audit and enforce). `POST /api/boss-key/claim` then: `off` keeps the 10 s minimum fight only; `audit` pays but writes a `boss_key_no_kill` finding when no stamped kill exists; `enforce` refuses with a readable message until one does (staff exempt). The client flushes the kill report before it claims. Needs migrations 035 (adds `killed_at`) and 036.

## Deploy checklist (step 2)

1. Merge, then deploy with `deploy-release.sh <rev> 036-kill-ledger.sql` (new table only, idempotent). Backend and client ship together; **client first matters**: a browser that has not
   reloaded sends no reports (`releaseWatch` prompts a reload).
2. Leave `AUTHORITY_KILLS` unset. Confirm the service is healthy and `POST /api/kills/report` answers `{"mode":"off"}`.
3. Set `AUTHORITY_KILLS=audit` in `/home/ubuntu/death-muffin/backend/.env`, restart the API. Play a few real sessions (and a co-op one with a guest) for several days.
4. Read the audit (queries below). **Healthy audit = no `unbacked_*`, no `kill_invalid`/`kill_mix`/`kill_elite`/`kill_rate` rows from honest players.** Expect `xp_total` at or above `xp_used` per character.
   Anything honest that shows up is a constant to loosen in `src/gameplay/killRules.ts` (`npm run build:server-rules`) before enforcing.
5. Set `AUTHORITY_KILLS=enforce` (and, if you have not, `AUTHORITY_MODE=enforce` for items and the offline confirm), restart. To undo: remove the line, restart; the ledger just stops mattering.
6. Rollback of the schema: `DROP TABLE character_kill_ledger;` (nothing else reads it; the code fails open).

```sql
-- the audit: what the ledger would have done, per kind
SELECT kind, mode, action, COUNT(*) n FROM progress_audit WHERE kind LIKE 'unbacked_%' OR kind LIKE 'kill_%' OR kind LIKE 'boss_%' OR kind LIKE 'floor_%'
  OR kind IN ('play_rate','depth_peak','run_count') GROUP BY 1,2,3 ORDER BY n DESC;
-- is the ledger tracking real play? (xp_total >= xp_used for honest characters; reports > 0)
SELECT l.character_id, a.username, l.reports, l.kills_total, l.rejected_kills, l.xp_total, l.xp_used, l.gold_total, l.gold_used, l.shards_total, l.depth_proved
  FROM character_kill_ledger l JOIN characters c ON c.id = l.character_id JOIN accounts a ON a.id = c.account_id ORDER BY l.updated_at DESC;
-- characters saving XP with no reports at all (old tab, or a script)
SELECT character_id, COUNT(*) n FROM progress_audit WHERE kind = 'unbacked_xp' AND JSON_EXTRACT(detail, '$.reports') = 0 GROUP BY 1;
-- who drops kills, and why
SELECT character_id, JSON_EXTRACT(detail, '$.why') why, SUM(JSON_EXTRACT(detail, '$.kills')) n FROM progress_audit WHERE kind = 'kill_invalid' GROUP BY 1, 2;
```

## Overlaps with parallel branches

- `dm/loot-achievable`: touches drop tables, affix ranges and regenerates `authority-rules.cjs`. Step 2 reads `AREA_PEAK` and `AUTHORITY` from `authorityRules.ts` (kills/min, headroom,
  rank allowance, noncombat gold) but changes nothing in it; item allowances stay step 1's. If it changes `AREA_PEAK.kills` the ledger's rate follows, then re-run `npm run build:server-rules`.
- `dm/gold-sinks`: a server-side reroll or seal-boss purchase that moves gold must go through the same gold balance `save-progress` compares (the ledger reads `characters.gold`
  as stored, so server-side deductions are already in the baseline). A seal boss kill is a normal boss report. No `loot.ts` line was edited here; `rollKill` is only read by a test.
- `src/gameplay/balance/harness.ts` gained an optional `onKill` hook (two lines) for the honest-play test.

## Tests (step 2)

- `server/death-muffin/backend/kills.test.cjs` (in `test:server`): the pure rules, then every piece against `kills-fake-db.cjs` in off/audit/enforce: inflated kills, XP, gold, depth, play time,
  runs, shards and Prelate kills; replayed and future sequence numbers; many small reports; sealed/unknown/safe grounds; wrong enemy; level; mix; elites; bosses; skipped floors;
  co-op guest at the host's rank (and a forged rank); offline load re-base; credits kept on a failed necro save; fail-open with the table gone; staff exempt; the real routes through `server-harness.cjs`.
- `src/gameplay/__tests__/kill-rules.test.ts`: XP exact vs `rollKill`, gold/shards bounded, honest bot play passes whole, the reporter's batching/retry, generated bundle fresh.
- `src/gameplay/__tests__/progression-reports.test.ts`: reports ride the save, survive a failed save with the same `seq`, order before necromancer claims, 404 stops holding.

- Real MySQL check (2026-10-03, scratch database built from the live schema and dropped afterwards): migration 036 applies twice, and `handleReports`, `guardProgress`, `necroGuard` (credits consumed after the save answers),
  `guardChronicleAdd`, `rebase` and the enforce leaderboard SQL all ran against it. `tools/qa/authority-db-probe.cjs` was not extended: re-run it with `AUTHORITY_KILLS` set if you want the full HTTP round trip.
