# Sync fixes (branch `claude/sync-fixes`, 3 Oct 2026, not deployed, no migration)

Follow-up to the suspicions in `core-bug-hunt.md`. Each was reproduced with a failing test first, then fixed in its own commit.
Tests: `src/gameplay/__tests__/sync-fixes.test.ts`, `src/net/__tests__/eventCoalescer.test.ts`, `server/realtime/server.test.js`.

| # | Finding | Verdict | Fix commit |
|---|---|---|---|
| 1 | Overlapping necro-progress replies roll back kills, a just-opened seal or a boon | **Confirmed**, two ways: a reply arriving while a kill save is in flight is merged without the in-flight kills; an older reply arriving after a newer one replaces newer state. | `265d701` all necro requests (remote mutations and the kill save) now run through one serial queue, so replies are adopted in the order the server applied them. A keepalive flush bypasses the queue. |
| 2 | The page-close flush skips the newest gains when a save is already in flight | **Confirmed** for `Progression.flush`. | `3055abc` a keepalive flush during an in-flight save sends the current level/XP/gold and pending necro deltas at once. |
| 2b | Same early return in `GatherLoop.flush` | **Confirmed**: cycles queued behind an in-flight batch were never sent on close. | `9683536` keepalive flush posts the queue alongside the in-flight batch. |
| 5 | Inventory save path: `pagehide` called `flush()` without keepalive (the fetch is cut off on unload) and returned early when a save was out | **Confirmed**; last pickups before closing the tab could be lost. | `d31880d` `saveInventory(..., keepalive)`; `flush(true)` sends even mid-save; `WorldScene` pagehide passes it. |
| 3 | Relay drops a whole `hit` with more than 64 ids; enemy cap is 72 | **Confirmed** (a 65-72 body sweep was discarded silently). | `8cabc88` cap raised to 72 (`LIMITS.hitIds`, equal to `GLOBAL_ENEMY_CAP`, pinned by a test). Validation otherwise unchanged: integers only, same byte limit (72 ids ~ 0.5 KB of the 2 KB budget). Deploy script re-embedded. |
| 4 | Event batches sent every frame vs the relay's 60/s | **Confirmed, worse than the hunt measured**: in a 15-thrall fight the sim emits events every frame, 61 batches/s at 60 fps (already over the limit) and 145/s at 144 fps. | `b5ea3da` `EventCoalescer`: send at once unless one went out under 25 ms ago, otherwise batch what queued, in order, chunks of at most 200. Measured after: 31/s at 60 fps, 37/s at 144 fps. Added delay is at most one frame at 60 fps (one 25 ms gap at 144 fps), and zero when events are sparse. |

Not changed: Chronicle's `flush` (no keepalive, skips mid-flight); its counters are cosmetic stats and its interval flush is short, so it was left
alone. Held events are dropped on disconnect or when the host changes (a reconnect resyncs from a snapshot).

Deploy: the realtime service needs the usual restart (`server/realtime/server.js` changed; `deploy-realtime.sh` is regenerated). Client-only
otherwise. Gates run: `npx tsc --noEmit`, `npm test` (1370 passed), `npm run test:server` (256 passed).
