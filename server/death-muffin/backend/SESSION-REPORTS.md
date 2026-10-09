# Host-reported party sessions

Godot rebuild decision D1: the host's game is authoritative for the *session*; the backend stays authoritative for anything of value.
This is the backend API a host uses to report what its 1-4 members killed. Code: `party-sessions.cjs`; tables: `migrations/041-party-sessions.sql`;
tests: `party-sessions.test.cjs` (fake DB `party-sessions-fake-db.cjs`). The routes answer 503 (`unavailable`) until migration 041 is applied.

## Principle

A host's report earns each member exactly what that member could have reported alone. Each member's part of a batch is handed to
`kills.handleReport` (the existing kill ledger) with the member's own character, level, unlocked grounds, Ascension rank and refilling buckets.
No rule is duplicated. `AUTHORITY_KILLS=off|audit|enforce` applies unchanged (off: sessions run, nothing is credited).

## Lifecycle

1. Host `POST /api/sessions {characterId}` (own JWT, own character) -> `sessionId` (128-bit random; the invite the lobby hands out). The host's
   previous open sessions end; the character leaves any other session. The host is member #1.
2. Each member `POST /api/sessions/:id/join {characterId}` with ITS OWN JWT and a character its account owns. Max 4 active members (D2).
   A member that left (or was removed by the host) cannot rejoin that session. A character is in one session at a time (newest attach wins).
3. Members `POST /api/sessions/:id/heartbeat {characterId, kills?}` every ~10-30 s ("I was there"; min spacing 5 s, extra calls answer `throttled`).
   `kills` = the member's own cumulative count of kills it saw.
4. Host `POST /api/sessions/:id/report {batch, members: [{characterId, groups, bosses}]}` during play. `groups`/`bosses` have the kill-report
   shape of `/api/kills/report` (area, def, level, elite, tier, diff, rank, xpMult, goldMult, shardMult, n).
5. Host `POST /api/sessions/:id/end {batch?, members?, summary?}` (an optional final batch, judged like any other). Idempotent.
6. `POST /api/sessions/:id/leave {characterId}`: the member itself, or the host removing one. The host leaves by ending.
7. `GET /api/sessions/:id` (host or member): status, roster, per-member reported/accepted counters, limits.

All replies are `{success, data}` or `{success:false, code, error}`. Codes: `bad_request` 400, `not_owner`/`not_host`/`not_member` 403,
`no_session` 404, `session_ended`/`left`/`full` 409, `rate_limited`/`session_full` 429, `unavailable` 503 (tables missing / DB error).
A session whose host has been silent for 10 min counts as ended.

## Who gets credit (same rules as the game)

The game pays personal rewards to every living player within `KILL_REWARD_RANGE` of a kill, each at their own multipliers; the chain bonus only
to the killer (`dm_game_rewards.gd on_kill`). The host applies that proximity rule and sends each member the kills THAT member earned, with
that member's own multipliers. The backend cannot see positions; it bounds the result with the ledger caps below. A co-op guest earns at the
host world's Ascension rank: the ledger's existing `COOP_RANK_ALLOWANCE` covers that. Depths floors/chests are solo-only and always dropped from host reports.
Credits land in the member's kill ledger; the member's own `save-progress` / necro saves claim them, exactly as today.

## Anti-cheat

- Membership: only characters attached by their owner's JWT, still `active`, and heartbeated within 120 s (the host counts as present while it
  calls). Others are refused per member (`not_member`, `left`, `stale_heartbeat`); the rest of the batch still goes through. The outsider's ledger is never touched.
- Caps per member, from the ledger: refilling kill/boss buckets (rate), ground unlocks, enemy level plausibility, per-kind mix, elite share,
  XP/gold/shard multiplier caps. Findings go to `progress_audit` against the member.
- Idempotency: `batch` must strictly increase per session; a repeat/older number is acknowledged as `duplicate` and ignored. The number is claimed
  under the session lock before crediting (a crash loses a batch rather than crediting it twice). The ledger sequence per member is server-assigned.
- Bounds: <= 4 members, distinct ids, <= 80 groups and 12 bosses per member (else the whole report is a 400).
- Limits: 30 reports/min per session, 90/min per host account, 12 session opens/hour, 30 joins/min per account, 20000 batches per session
  (in-memory sliding windows plus an express-rate-limit in front). A rate-limited batch is not consumed; the host resends it.
- Ended sessions and left members are refused. At end, a member whose accepted kills exceed twice what its own heartbeats said it saw (+25) is
  audited as `session_kill_mismatch` (audit only, nothing clawed back).
- Loot is not rolled by this API: each member keeps rolling its own drops through `POST /api/loot/roll-gear` (server RNG, existing guards).

## Deployment checklist (not done)

1. Apply `migrations/041-party-sessions.sql` (additive; check no other branch took 041 first).
2. Copy `party-sessions.cjs` + `server.js` to the live backend, restart (routes answer 503 until the tables exist).
3. `AUTHORITY_KILLS` must be `audit` or `enforce` for credits to be recorded.
