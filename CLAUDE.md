# Death Muffin — development context

**Current state (owner decision 2026-10-09): Death Muffin is ONE project, the Godot
rebuild.** The active client is in `godot/` on branch **`godot-next`** (entry
`DmNextGame` in `godot/next/`; `DmMain.USE_NEXT := true` is the default, `-- --old`
forces the legacy `DmGame`). Branch from and ship from `godot-next`; `godot-port` is
merged into it and is not a line to work on. The TypeScript / Three.js web client in
`src/` (branch `master`) is **frozen legacy reference**: use it as the spec for
behaviour and numbers, but make no fixes or features there. The backend
`server/death-muffin/` is still live and shared by every client. Start with
`godot/REBUILD.md` (decisions, status), `godot/PARITY.md` (what is built vs the web
game) and `godot/README.md` (running, exporting, data pipeline). The rest of this
file describes the web game and its ground rules; keys, art pipeline and discipline
indices still apply.

Death Muffin is a dark-fantasy
action RPG with nine classes — one connected world (Chapterhouse → Hollow Graves →
Marrow Ossuary → Drowned Nave → Bell Sanctum → Plague Cloister → Cinder Pyre → Mourning Fen, the last three level-scaled), continuous waves, corpses as a
resource, Damage / Wave Speed upgrades and boss fights. The original shared
Crossworlds REST API is outside this repository: propose changes for it in
`server/proposals/`. Death Muffin has its own versioned backend in
`server/death-muffin/`; read `docs/DEATH-MUFFIN-HANDOFF.md` before touching its
deployment or database.

## Read before working

**Start with `HANDOFF.md`** — current state, active work and dated history.
Use [the documentation map](docs/README.md) to find the right source for
player behavior, deployment and plans. Update the handoff when you stop.

| Doc | When |
|---|---|
| `NECROMANCER_REDESIGN_AUDIT.md` | the design direction this build implements |
| `PHASE_REPORTS.md` | what's built and QA'd — **check before rebuilding anything** |
| `ASSET_PIPELINE.md` | Gemini → Tripo v3 → GLB — **read before any generation** |
| `FUTURE_CONTENT.md` | backlog: future disciplines, spells, enemies, bosses |
| `BALANCE.md` | balance targets per band, current `npm run balance` numbers, open issues |
| `docs/DEATH-MUFFIN-HANDOFF.md` + `server/death-muffin/` | Death Muffin runtime and deploy scripts; `server/realtime/DEPLOY.md` is legacy Crossworlds history |
| `server/proposals/necromancer-progress.md` | server spec for browser-local progress |

## Ground rules

- API keys are in `.ai-keys.local` (gitignored) — tools load them per run; never
  print, commit, or bake them into client code.
- Raw AI outputs go in `art-src/` (gitignored). Only optimized output ships in
  `public/models/`; generation records (prompts, task ids, credits) go in `art-manifest/`.
- Legacy server class indices are 0=Engineer, 1=Guardian, 2=Shadowblade,
  3=Cleric, 4=Arcanist. Client discipline indices are 1=Ossuary,
  2=Gravecaller, 3=Mourner, 4=Rotweaver, 5=Grave Warden, 6=Bell Monk,
  7=Carrion Witch, 8=Hollow Knight, 9=Veilwalker (legacy 0 plays as
  Gravecaller). `src/gameplay/classes.ts`, `server/rules/content/disciplines.ts` and
  Death Muffin's `discipline.cjs` must agree; do not merge the legacy class
  names with the discipline names.
- Loot may only use item ids the live server knows (`server/rules/content/items.ts`;
  a unit test enforces it).
- Realtime = Socket.io on port 5000 locally (`server/realtime/`); the client must
  keep working solo when it's down. After editing `server.js`, run
  `node tools/embed-realtime.mjs` to refresh the deploy script.
- Server `error` strings are player-readable — show them verbatim in UI.
- Spell colours carry meaning (see `SPELL_FX` in `src/content/abilities.ts`);
  don't make new content "just violet".
- **PC-first (owner, 2026-10-03: "tuning the PC version is priority over mobile").** This branch has no phone/tablet layer: no touch
  controls, no `mobile.css`, no phone checks. Do not add touch paths or phone layouts here; PC players with a touchscreen use the mouse path.
  Phones and the offline edition live on the **`mobile` branch**, built by `server/death-muffin/deploy-mobile.sh` at
  `/death-muffin/mobile/` (offline edition at `/death-muffin/offline/`). Master is merged into `mobile` from time to time (see the top of
  `HANDOFF.md`); the play page redirects phones there (add `?pc=1` to stay on the PC build).
- Every new player-facing mechanic ships with its help: a Covenant counsel tip (`src/ui/Onboarding.ts`,
  triggered the first time it matters), its Codex entry (`src/content/codex.ts`), the Settings key list
  if it adds a key, and the README. Re-check existing tips when a mechanic changes.
  Give the tip a kind in `src/ui/counselCadence.ts` (default: calm, waits for a quiet moment; `ASKED` for
  "the player just did it", `DANGER` for fight-time, `HERE` for a place, `GROUPS` for a subject that must not repeat),
  and never point brewing at the Workbench: it lives in the Alchemist's Wing.
- **Windows have a fixed header (owner, Helix, 2026-10-04: the design must be consistent across every window).** The title and close
  button sit in a `.cw-panel-head` that never scrolls; only the body beneath it scrolls. Every window built on `.cw-panel-float` must
  draw a `.cw-panel-head` first, then call `wrapPanelBody(el)` (`src/ui/panelBody.ts`) right after each `innerHTML` redraw (inside
  `preserveScroll` if it uses it). Tabbed windows use `TabbedWindow`, which scrolls `.cw-tabwin-body`. No sticky headers, no
  per-window variants. `src/ui/__tests__/windowHeader.test.ts` fails if a window skips it.
- Commits go through the user's GitHub Desktop flow — stage, don't commit.

## Layout

```
src/app/        GameRuntime (one renderer, bloom, advance() QA stepping), Scope, settings
src/content/    data: disciplines, abilities (+SPELL_FX), enemies, areas, layout, items, upgrades
src/gameplay/   sim/ (WorldSim, BossBrain, snapshot mirror), AbilitySystem, Player, nav,
                progression (server + local), loot/Inventory, characterStats, __tests__/
src/graphics/   Creature (GLB instances), EntityViews, WorldView, Effects (+binbun/ BinbunVFX runtime), LootView,
                Avatars, CameraRig, occlusion, NecroBackdrop, AssetCache, fxTextures
src/net/        REST client (+DEV offline mock), realtime client, contracts
src/scenes/     Login, CharacterSelect (disciplines), WorldScene (the game)
src/ui/         HUD, Minimap, FloatingText, panels, cursors, ui.css; src/theme/ tokens + fonts
tools/          ai/ (gemini.mjs, tripo.mjs), build-characters.mjs, make-seamless.mjs, embed-realtime.mjs
art-manifest/   committed generation jobs/specs/records     art-src/ raw outputs (gitignored)
server/         realtime service (+tests, deploy), web-deploy, proposals/
```

## Verification

1. `npm run typecheck && npm test && npm run test:server`
2. Dev server: `npm run dev` (port 5188). `.claude/launch.json` is the older
   Windows preview setup; on this VPS, `tools/qa/README.md` uses port 5199.
3. `http://localhost:5188/?offline` = DEV-only in-browser mock backend (no live
   server, accounts in localStorage). Add `&coop` + start **death-muffin-realtime**
   to test co-op across two tabs.
4. Drive QA through `window.__cwDebug` (DEV only): `advance(s)` steps the game
   deterministically (hidden preview panes throttle rAF — don't wait on the loop),
   `counts()`, `net()`, `god()`, `goto(area)`, `unlockAll()`, `ring(def,n,r)`,
   `freeze()`, `boss(id?)`, `zoom(z)`, `aimAtNearest()`, `cast(slot)`, `vfx(id)`, `vfxGallery(page)`. Screenshots work
   after an `advance()`.
5. Live-server QA uses accounts in `TEST_ACCOUNTS.local.md` (gitignored) — the
   Vite proxy forwards REST calls to the VPS.
