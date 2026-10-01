# Death Muffin — development context

Browser client for Death Muffin (Vite + TypeScript + Three.js): a dark-fantasy
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
  Gravecaller). `src/gameplay/classes.ts`, `src/content/disciplines.ts` and
  Death Muffin's `discipline.cjs` must agree; do not merge the legacy class
  names with the discipline names.
- Loot may only use item ids the live server knows (`src/content/items.ts`;
  a unit test enforces it).
- Realtime = Socket.io on port 5000 locally (`server/realtime/`); the client must
  keep working solo when it's down. After editing `server.js`, run
  `node tools/embed-realtime.mjs` to refresh the deploy script.
- Server `error` strings are player-readable — show them verbatim in UI.
- Spell colours carry meaning (see `SPELL_FX` in `src/content/abilities.ts`);
  don't make new content "just violet".
- Desktop web game first; narrow viewport only needs sanity checks.
- Every new player-facing mechanic ships with its help: a Covenant counsel tip (`src/ui/Onboarding.ts`,
  triggered the first time it matters), its Codex entry (`src/content/codex.ts`), the Settings key list
  if it adds a key, and the README. Re-check existing tips when a mechanic changes.
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
