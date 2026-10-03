# Side-systems bug hunt (3 Oct 2026, branch `claude/sidesystems-bug-hunt`)

Scope: professions, garden, Grave Laborers, brewing/Workbench, Contracts, Vault, salvage/sell, tool belt, AFK ledger, Chronicle, capes/pets.
One bug per commit, test added where plain vitest can reach it. No UI redesign, no new content, no per-frame cost added.

## Fixed

| # | Bug | Sev | Where | Fix commit |
|---|---|---|---|---|
| 1 | Skills panel fully redrawn on every AFK XP tick; a press on Pause/Start AFK straddling a redraw is lost | Med | `ProfessionsPanel.render` via `WorldScene.onSkillsChanged` | e2e27a7 (`ProfessionsPanel.refresh`, `ui/redrawGuard.ts`) |
| 2 | Deliver/harvest/collect/adopt: if the bag re-read failed after the server action, the reply was thrown away (order/plot/laborer stayed "unfilled", gold not credited) | Med | `ContractsPanel.deliver`, `GardenPanel.act`, `LaborPanel.act`, `CosmeticsPanel` | 5faf1ca (`Inventory.exclusiveAction`) |
| 3 | Garden plot never turned "ready" while the panel stayed open (Harvest disabled at "0s left") | High | `GardenPanel.render` used snapshot `p.state` | b0021de (`ui/gardenView.ts`) |
| 4 | Stale bone-meal tick sent `compost:true` after the last meal: plant refused, grow estimate wrong. Dev mock also consumed the seed before refusing | Low | `GardenPanel`, `mockBackend /api/garden/plant` | ef7f5f0 |
| 5 | Replaying a queued sale on a fresh server bag could consume the same item at a reserved slot (belt 110+, worn 100+): gold paid, belted tool gone locally only | Med | `loot.ts applyInventoryMutation` | 5846b09 |
| 6 | Contracts panel kept yesterday's orders after 00:00 UTC; Deliver sends only the slot, so it filled the new day's order | Med | `ContractsPanel` 30 s tick | 987bdbe |
| 7 | Vault bag cells clickable during the opening load; the move overlapped the load and the stale load reply overwrote vault view and bag | Low | `VaultPanel.run` | 6eb7898 |
| 8 | Chronicle `view()` dipped by the in-flight batch during a flush; AFK report's lifetime-finds snapshot could repeat or miss a milestone | Low | `chronicle.ts` | 2c394a4 |

Tests: `ui/__tests__/{redrawGuard,gardenView,contractsView,vaultPanel}.test.ts`, `gameplay/__tests__/inventory-action.test.ts`, `chronicle.test.ts`. #5 and #2 are covered by Inventory-level tests; the panel wiring (#1, #3 render use) is tested through its extracted helpers because the repo has no DOM test environment.

## Unconfirmed / not fixed

- **Forge craft: failed re-read leaves a stale local bag.** If `getInventory` throws after N server crafts, `ForgePanel.doCraft` skips `replace`; a later pickup save would write the stale bag (ingredients back, products gone) if the server accepts it. Needs a "bag is stale, reload before next save" flag on `Inventory`; not done (design change). Same hazard remains for `exclusiveAction` when `bagStale` is true.
- **ForgePanel tab race**: tab A then B quickly, A's reply landing last shows A's recipes under B. No request token. Not fixed (no DOM test).
- **Garden/Labor/Cosmetics redraw on `inventory.onChange`** is unguarded (loot pickup under the pointer can swallow a click / close an open select). The 1 s ticks are guarded. A disabled button under the pointer also freezes the tick-render (Harvest may stay disabled until the pointer moves). Fix would be `controlUnderPointer` plus a deferred redraw.
- **GatherLoop retry** reads `this.afk` again, so AFK cycles re-queued after `stop()` are replayed with `afk=false`; server use of the flag not checked.
- **`endGatherSession`** uses `GatherLoop.flush()`, which returns an already-running flush, so cycles queued after that batch started may miss the report (they are still saved).
- **Dev mock backend only** (`mockBackend.ts`): `/api/contracts/deliver` and `/api/craft` keep their deductions when they refuse for lack of room; contract rewards can exceed the 99 stack cap. The real server runs in transactions; not touched.
- **Inventory.count/consume** include rows at slot 100+ (only matters for item ids that can be worn/belted).
- Startup `window.setTimeout` for garden/labor hints in `WorldScene` (~777-779) is not scope-bound; harmless after dispose.
- Retracted: `addToSlots` unknown-id NaN (suspected, disproved: operator precedence gives Infinity).
