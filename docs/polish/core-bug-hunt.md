# Core bug hunt (branch `dm/bughunt-core`, 3 Oct 2026)

Scope: the core game on `dm/release-batch2` (combat loop, sim, bosses, co-op relay and reconnect, progression and saves, resource
lifetimes). No new content, no design changes, no deploy. Every fix below has a failing test first (vitest or `node:test`) except where
marked "no test". One commit per bug. Nothing needs a migration.

How it was hunted: read `WorldSim`, `BossBrain`, `snapshot`, `Player`, `AbilitySystem`, `NewBloodSystem`, `autoCombat`, `Gathering`,
`progression`, `loot` (Inventory), `realtime`, `reconnect`, `server/realtime/server.js`, `DepthsController` and the co-op parts of
`WorldScene`; then a seeded fuzz over the sim (random legal intents through the relay's own `validIntent`, every boss, wipes, deaths,
host migration) and two Playwright tours of the real client (all 13 areas twice, all 7 bosses, kill/raise/expire loops, renderer
memory counters). The tours found no console errors and no leak (geometries flat; textures plateau as new enemy kinds are first
drawn, see suspicion 12).

## Fixed

| # | Bug | Sev | Where | Fix commit |
|---|-----|-----|-------|------------|
| 1 | A guest reconnecting (or the socket id replacing the provisional one) **crumbled the whole legion**: `retagSelf` called `removePlayer(old)`, which kills every thrall the old id owns, and only then looked for thralls to retag. Zones, walls, brands, seeds, legend mods and kill credit also stayed on the dead id. | High | `WorldScene.ts:2423` (`retagSelf`), new `WorldSim.retagPlayer` | `88ed47e` |
| 2 | After a dropped link the host's sim kept the partners' bodies **alive forever** (`onCoopDisconnect` / `joinWorld` cleared the avatars, never the sim bodies; no `player:leave` ever arrives): areas stayed open, boss HP scaled for ghosts, their thralls persisted. | Med | `WorldScene.ts:2409`, `:2334` | `88ed47e` |
| 3 | **Host migration degraded the world.** `WorldMirror.seed` rebuilt every thrall at damage 6, swing 1.0, reach 1.3 (archers and bone mages became melee) all on formation slot 0 / `bornAt` 0 (whole legion stacked on one seat, "oldest crumbles first" arbitrary), and every enemy at level 1, damage 8, radius 0.5 (kills then paid XP/gold/gear as level 1). Thrall rows now carry damage + swing speed, enemy rows their level; damage and size are re-derived from level, elite rank and the world dials. Old clients ignore the extra fields. | High | `sim/snapshot.ts:264` (`seed`), `WorldSim.adoptEnemy`, `net/contracts.ts` | `a24a24e` |
| 4 | A guest could **corrupt or crash the host sim** through the relay: `recallThralls` (and `miasma`/`litany`/`exhume`) without x/z passed `validIntent`, the host wrote NaN thrall positions and `separate()` spread NaN to every body they touched; an `exhume` with an unknown `kind` made `raiseFrom` throw on `THRALL_BASE[kind]` mid-frame. Relay now requires a point and whitelists the kind; the sim ignores/falls back too. | High | `server/realtime/server.js:186,240`, `WorldSim.ts:383,622` | `e9b7f3f`, `5be9723` |
| 5 | Abandoning an area mid-surge (`crumbleVacant`) set `surge = null` without `endSurge`: `surgeIn` stayed expired, so the **next fight anywhere opened a surge at once**, and clients kept the crypt mark. Same bare reset in `clearArea` (Ascension). Both now emit `surgeFailed` and restart the clock. | Med | `WorldSim.ts:1783`, `:3341` | `6cc3ffb`, `a24a24e` |
| 6 | Withered rot (zone stacks) **killed a Barrow Ghoul that is underground**: `damageEnemy` refuses burrowed bodies but `tickStatuses` applied DOT directly. | Med | `WorldSim.ts:2749` | `8062b1d` |
| 7 | Withered rot **damaged the Mire Mother while she is sunk** (`damage()` refuses her, the DOT in `BossBrain.update` did not). | Med | `BossBrain.ts:201` | `7d2e72e` |
| 8 | A join that was dropped (service restart mid-join) or never answered **left `RealtimeClient.connect` pending forever**; the Reconnector's attempt never finished, so no retry followed until a reload. Now rejects (retryably) on disconnect or after 8 s. | Med | `net/realtime.ts:82` | `797ca8f` |
| 9 | A **level-up during an in-flight save** was only saved 45 s later (`flush()` returned early and the urgent request was dropped). It now runs the moment the first save lands. | Low | `progression.ts:552` | `c495386` |
| 10 | `revive()` kept **Veil form** (a Veilwalker killed by toxic/burn rose still immune and draining), plus roots, Bulwark, Oath, Between Worlds and the cast lock from the previous life. | Low | `Player.ts:304` | `da5c232` |
| 11 | Choir of One, Harvest crows and Murder of Crows **resumed after the respawn** for the rest of their window (`update` returned early while dead but never ended them). | Low | `NewBloodSystem.ts:235` | `dbfe9d3` |
| 12 | `dotAccum` (damage-number accumulator) leaked an entry for every enemy that left without dying (vacated hall, wiped Depths floor, boss adds). Tiny, unbounded. Pruned every 5 s. | Low | `WorldSim.ts:2029` | `c28df81` |
| 13 | The 4 s / 6 s delayed garden and labor checks were raw `setTimeout`s: a class change right after login let them fire into the **unmounted scene** (toast on the dead HUD, `laborers.apply` on disposed views). Now in the scene Scope and re-checked after the await. **No test** (scene lifecycle). | Low | `WorldScene.ts:783,785,1352,1386` | `16e44ab` |

Also added: `src/gameplay/__tests__/sim-fuzz.test.ts` (seeded fuzz, about 2 s; catches NaN, hp over max, orphan thralls, runaway
counts, throws, across every boss and a host migration), `bughunt-core.test.ts`, `bughunt-save.test.ts`, `bughunt-newblood.test.ts`,
`net/realtime-join.test.ts`, and two `node:test` cases in `server/realtime/server.test.js`.

Deploy notes: #4 changes `server/realtime/server.js`, so the realtime service needs the usual restart with the next release; #3 extends
snapshot rows (additive, older clients keep working). No DB change, no migration.

## Suspicions (not fixed: unconfirmed, or design calls)

1. **Boss rewards go to every client that sees `defeated`**, in any area, dead or alive (`WorldScene.ts:4355`): loot, XP, shards, first-kill
   trophy, and `recordPrelateKill()` (local Ascension credit; the server clamps it by `summonsPending`, so the Altar can show "ready" and then
   refuse). `onKill` requires `alive` and within 38 m; bosses do not. Likely an oversight; a one-line `player.alive && player.area === def.area`
   gate would match `onKill`. Left alone because personal-loot-for-the-whole-party might be intended.
2. **Event batches are sent every frame** (`WorldScene.update` -> `sendEvents`), the relay allows 60 per second per socket. A host on a
   144 Hz monitor in a sustained fight could trip `eventsRate` and drop reliable events (`death`, `exhumed`, `hurt`). Measured in a 6-thrall,
   wave-tier-4 fight: only about 6 batches/s, so low risk today. Coalescing to 20 Hz would also cut socket traffic.
3. The relay rejects a whole `hit` intent with more than 64 ids; `GLOBAL_ENEMY_CAP` is 72 and a few rites (Rot Lance, Spear) do not cap their
   id list at 64 (most `inCircle`/Frost/Mantle paths do). Needs 65+ bodies in one rite: very unlikely.
4. **Necro progress adopt race** (`progression.ts`): `remote()` replies and `flushNecro()` run independently; a reply computed before an
   in-flight kill save lands is merged without those kills, so `areaKills` and a just-opened seal can roll back for a moment until the save's own
   reply is adopted (door closes, then reopens). Self-heals; worth a serial queue if anyone sees flicker.
5. `Progression.flush`, `Chronicle.flush` and `GatherLoop.flush` return early when a request is already in flight, so a `pagehide`/dispose
   keepalive flush can skip the newest gains if it lands mid-save.
6. Boss Withered DOT has no owner (`BossState` carries none), so a kill by rot credits the last direct hitter (`killer`) instead of the stacker.
7. Host migration: the new host's mirror is the interest-filtered snapshot (64 m around the guest), so far enemies are not carried over; thrall
   `echoUntil` is lost (Veilwalker echo wraiths become permanent after a migration).
8. `BossBrain.stagger` shifts pending attacks later, but the clients' telegraph rings keep their original timers: after a stagger the ring
   finishes before the blow resolves (the cue is early, not wrong).
9. Client-resolved rites (needle, scythe, spear) draw a damage number on a sunk Mire Mother or a burrowed ghoul the host will refuse (cosmetic).
10. Corpse Vigil's regeneration window and an in-flight Veil Step are not cancelled by death (a few seconds of heal after the respawn).
11. `__cwDebug.unlockAll()` is undone by the next server sync in `?offline` (`adopt` replaces `local.unlocked` with the mock server's record), so
    long QA tours need to call it again after a sync. Harness only, not a game bug.
12. Renderer `info.memory.textures` climbs by roughly 10 per new enemy kind for the first few waves (`warmModel` / `prewarmCreature` uploads) and then
    plateaus (152 to 185 over four ring/raise/kill/expire cycles, flat after); geometries flat. Not a leak, recorded so nobody re-chases it.


**Resolved 3 Oct 2026 (owner: "same rule as normal kills for boss rewards"):** boss loot, XP, shards, rune, trophy, Chronicle and Prelate/Ascension credit now need a living hero within 38 m (`gameplay/killCredit.ts`, shared with normal kills); the defeat banner and sound still play for everyone who sees it.
