# Polish hunt (branch `dm/polish-hunt`, 3 Oct 2026)

Scope: debug and polish only, no gameplay change. Driven with the dev server (`?offline`) and headless Chromium (swiftshader) at 1280x720,
1920x1080 (and 1600x900 for the select screen): every panel by hotkey, every hunting ground, four bosses, the Depths, Settings by keyboard.
`npm run typecheck`, `npm test` (1385) and `npm run test:server` (264) pass on the branch head. Nothing deployed.

## Fixes

| Commit | Issue -> fix -> how verified |
|---|---|
| 5b75982 | Atlas headings, README and `docs/LOOT-TABLES.md` still said "tap" and "Atlas in the Menu on a phone" on the PC build -> reworded, `npm run gen:loot` -> grep for tap/phone. |
| 1040964 | Settings/Salvage/Garden checkboxes were the browser's default blue -> `accent-color` violet -> screenshot. |
| 7226de3 | World hotkey handler swallowed arrows, Space and Enter even when a `<select>` or button owned them: ArrowDown never changed Difficulty/Graphics, Enter/Space never pressed a focused button -> `focusOwnsKey` -> Playwright (medium -> hard, Enter and Space click). **Also contains** an unrelated 5-line `readability.css` hunk (committed by mistake in the same commit): the 7-9px captions (belt/equipment slot labels, brew chip label, "Move this card") now follow the 11px readability rule; verified by screenshot. |
| 18ee0ff | Follow-up: `:focus-visible` turns on once a key is pressed, so click Bag + Enter toggled the panel instead of opening chat -> track Tab vs pointer focus -> Playwright (click+Enter focuses chat as before). |
| eb47483 | Class select: the "Recommended" badge covered the NECROMANCER tag on the Gravecaller card at 1280 -> tag drops below -> screenshot. |
| f73dd03 | `classes.html` gave wrong numbers (Bone Ward 60%/6%, Funeral Rites 6%, Miasma 30%) vs the game (100%/10%, 10%, 40%); about/classes/leaderboard used `styles.css?v=2` while home used v=5 -> corrected, versions aligned -> compared with `disciplines.ts`. |
| a9b382f | 1280x720: right HUD column (two-line zone name + Depths widget with wrapped cue) ran under the Damage/Wave Speed plate and hid the menu's second row; at level 110 "Experience 1,486 / 11,000" wrapped inside the number -> 4px column gap on short windows, 200px Depths widget, nowrap halves -> Playwright rects and screenshots. |
| 23d6074 | "Opening the Vault..." wrapped one word per line in an 8-column grid cell -> spans the grid -> seen in the panel tour. |

## Checked, no bug found

All 13 areas (cast 1-4 + R), Gravedigger/Abbess/Congregation/Prelate, Depths floor 1 to stair open: no page errors, no console errors.
Every hotkey in Settings/README/tips maps to a real key. `ERR_ABORTED` on the 16 `prop_node_*.glb` HEAD probes is a Vite dev artefact (files exist, curl HEAD is 200).

## Not verified / leads (not fixed)

1. **WebGL warnings in headless**: `texSubImage2D: bad image data` / `Texture is immutable` repeat when item icon SVGs (e.g. `art/items/set_gravecaller_legs.svg`, viewBox only, no width/height, so 150x150 intrinsic) are uploaded by `renderer.initTexture` from `LootView.warmTasks`. Could be swiftshader-only; I could not reproduce on a real GPU. If it reproduces there the icon sprites would draw blank. Fix idea: add `width`/`height` to those SVGs or ship webp.
2. Co-op two-tab (`&coop`) was not run.
3. Counsel cards of kind "asked" stay over other panels (by design, z-index 6) and can cover the left tabs of a 700px panel at 1280.

## Suggestions (out of scope)

1. The site's classes page lists only the four necromancer disciplines ("Four ways to spend the dead") while the game has nine.
2. Next-line guidance says "Walk north into the Hollow Graves and fight your first dead" to a level-63 hero standing in the Cinder Pyre when kill counters are zero (QA artefact of `__cwDebug`, but worth a look for characters imported from the offline edition).
3. Mixed "armor"/"armour" spellings across UI, README and codex.
4. `focus-visible` styling on several controls only changes border colour, identical to hover.
