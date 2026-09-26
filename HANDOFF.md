# HANDOFF — read this first

Living status document so any agent (or person) can pick the project up at any
point. **Update the "Current state" and "In flight" sections whenever you stop.**
Last updated: 2026-09-26 (necromancer redesign session: codex folded in, balance harness added).

## 60-second orientation

- **What it is:** Crossworlds — browser necromancer ARPG (Vite + TS + Three.js). One connected
  world, continuous waves, corpses → thralls/spells, Damage & Wave Speed upgrades, co-op ≤4,
  the Bell-Sworn Prelate boss. Player-facing guide: `README.md`. Design source: `NECROMANCER_REDESIGN_AUDIT.md`.
- **Hard rules:** never modify the live REST server from this repo (write proposals in
  `server/proposals/`); commits go through the user's GitHub Desktop (stage, don't commit,
  unless the user explicitly asks); keys in `.ai-keys.local` are never printed or committed.
- **Architecture map + verification recipe:** `CLAUDE.md`.
- **Asset generation (Gemini/Tripo):** `ASSET_PIPELINE.md` — costs, specs, resumable tools.
- **Scope:** focus on the game (mechanics, engine, rendering, content). The user already has a
  login page and an about/landing page elsewhere, so don't build or polish site pages. The
  in-repo `LoginScene`/`CharacterSelectScene` only need to keep working.

## Resume in 5 commands

```bash
npm install                       # Node 24 (winget OpenJS.NodeJS.LTS if missing)
npm run typecheck && npm test && npm run test:server
npm run balance                   # headless farming/danger table (BALANCE_MINUTES=3 default)
npm run dev                       # or preview "crossworlds-web" in .claude/launch.json
# open http://localhost:5188/?offline  → register any name/password (local mock), pick a discipline
# QA from the console: __cwDebug.god(); __cwDebug.goto('graves'); __cwDebug.advance(3); __cwDebug.counts()
```
Hidden preview panes throttle rendering — drive time with `__cwDebug.advance(seconds)`;
`__cwShot('name')` saves the current frame to `docs/screenshots/`.

## Current state (all verified in-browser on 2026-09-26)

| Area | Status | Where |
|---|---|---|
| Runtime (one renderer, bloom, QA stepping) | ✅ | `src/app/` |
| Login / discipline select (necro theme, portraits) | ✅ | `src/scenes/LoginScene.ts`, `CharacterSelectScene.ts`, `graphics/NecroBackdrop.ts` |
| World: 5 areas, sealed doors, waystones, recall | ✅ | `content/areas.ts`, `content/layout.ts`, `graphics/WorldView.ts`, `gameplay/nav.ts` |
| Authoritative sim: waves, 6 enemy types, elites, corpses, thralls, zones, boss | ✅ tested | `gameplay/sim/` (+ `__tests__/sim.test.ts`) |
| Necromancer kit (5 rites) + per-spell colour identity | ✅ | `gameplay/AbilitySystem.ts`, `content/abilities.ts` (`SPELL_FX`) |
| Progression: XP/gold → server; tiers/shards/unlocks → localStorage | ✅ (interim) | `gameplay/progression.ts`; server spec `server/proposals/necromancer-progress.md` |
| Loot / Reliquary / Workbench (3 professions) / Rites / Settings | ✅ | `gameplay/loot.ts`, `ui/*Panel.ts` |
| HUD (orbs, slots, upgrades, minimap, target frame, boss bar) | ✅ | `ui/HUD.ts`, `ui/Minimap.ts`, `ui/ui.css` |
| Co-op: instanced worlds, host authority, intents, host migration | ✅ tested live (2 tabs) | `server/realtime/server.js` (+tests), `net/realtime.ts`, `gameplay/sim/snapshot.ts` |
| Audio (procedural WebAudio SFX + ambience + boss drum) | ✅ wired, **not yet ear-tested** | `src/audio/Audio.ts` |
| Art: 4 discipline heroes, base hero, 7 creatures, boss, 16 props, textures, icons, portraits | ✅ | `public/models/`, `public/art/`, records in `art-manifest/` |
| Occlusion cutout, target ring, cursors, attachment auto-calibration | ✅ | `graphics/occlusion.ts`, `ui/cursors.ts`, `graphics/Creature.ts` |
| Production build | ✅ `DEPLOY_BASE=/play/ npx vite build` (mock backend excluded) | `vite.config.ts` |
| Illustrated README / in-game guide | ✅ | `README.md`, `docs/screenshots/` |
| In-game Codex (K), per-character discoveries, onboarding tips (Settings toggle) | ✅ | `ui/CodexPanel.ts`, `content/codex.ts`, `gameplay/codexJournal.ts`, `ui/Onboarding.ts` |
| CI (typecheck, vitest, realtime tests, build on push/PR to master) | ✅ written, first run happens on push | `.github/workflows/ci.yml` |
| Headless balance harness (bot drives the real WorldSim) | ✅ | `gameplay/balance/harness.ts`, `report.ts`, `npm run balance` |

## In flight (check before starting overlapping work)

Three parallel agents were dispatched from commit `c475583`. Their full briefs are in
[`docs/agent-briefs/`](docs/agent-briefs/README.md) and can be handed to a fresh agent unchanged.
They ran as **git worktree agents on the original workstation** (`.claude/worktrees/`, gitignored)
and cannot push; that session has no GitHub credentials. A branch reaches GitHub only when the
user publishes it from GitHub Desktop, or when its work is folded into master's staged changes.

| Brief | Branch | Status |
|---|---|---|
| Combat depth: Corpse Explosion (right-click), elite affixes, Grave Surges, Soul Harvest meter, server intent `detonate` | `cloud/combat-depth` | running, not yet in master |
| Environment: Drowned Nave water, atmosphere particles, puddles, distant silhouettes | `cloud/environment` | running, not yet in master |
| Codex (K), onboarding tips, GitHub Actions CI | `cloud/codex-onboarding` (`5dbf2aa`) | **folded into master's working tree** and QA'd in-browser. The codex toasts are now batched into one per discovery burst. The branch itself doesn't need publishing. |

**Picking this up on another workstation:**
1. `git fetch origin && git branch -r`. For each brief whose work isn't in master (check the
   table above and `git log`), look for `origin/cloud/<name>`.
2. Branch exists: review it, then fold it in. Merge order: environment → combat-depth. Keep the
   floor-gloss fix in `WorldView.ts` (floors use no roughness map; it caused glowing square
   highlights). combat-depth and the codex work both touch `WorldScene.bindInput`,
   `handleEvent`/`update` endings, `HUD.ts` (`.hud-menu`, `HudCallbacks.open`) and the
   `.hud-menu` CSS, so expect small conflicts there.
3. Branch missing: the agent's work never left the original machine. Re-dispatch its brief from
   `docs/agent-briefs/` to a new agent, based on current master rather than `c475583`.
4. After each merge run the full check suite, then in-browser QA (the briefs list what to check).

**Folding a finished local branch into master without committing** (this matches the
stage-don't-commit rule): `git diff --binary c475583 <branch> > x.patch && git apply --3way x.patch`.
Run it from bash; PowerShell pipes rewrite line endings and corrupt the patch. `git merge`
refuses while the index has staged changes.

## Known issues / next steps (priority order)

1. **Ear-test audio** in a visible browser (volumes, ambience crossfades, boss drum loop).
2. **Merge the cloud branches** (above) and QA each feature in-browser.
3. **Server storage for progression** — implement `server/proposals/necromancer-progress.md`
   on the VPS, then switch `Progression` to it (migration steps are in the proposal).
4. **Deploy:** realtime protocol v2 + client must ship together (`server/realtime/DEPLOY.md`,
   `server/web-deploy/`). SSH from the dev machine was denied historically — the user runs the scripts.
5. **Balance pass.** Use `npm run balance`. The first report (2026-09-26, 3 simulated minutes per
   row) found far too little danger: at every area's intended band the bot takes ~0–46 damage/min,
   stays near 100% HP, never dies, and gains 3–8 levels in 3 minutes. Thralls soak aggro and the
   bot kills at range. Wave Speed tiers need to bring real pressure. The Prelate (≈15k HP at
   level 13) still needs a real playtest. Treat the bot as an upper bound on player efficiency.
6. Performance under a full horde on mid hardware (skinned enemies are individual meshes;
   VAT crowd rendering is the next step if >~120 animated enemies are needed).
7. `FUTURE_CONTENT.md` — the long-term backlog (new disciplines, spells, bosses, systems).

## Gotchas that cost time before

- `npm`/`node` may not be on the desktop app's PATH → `.claude/launch.json` calls `node.exe` directly;
  in a PowerShell tool shell prefix `$env:Path = "C:\Program Files\nodejs;$env:Path";` and call
  `node node_modules/typescript/bin/tsc --noEmit`, `node node_modules/vitest/vitest.mjs run`, etc.
- Never `git add -A` while agent worktrees exist unless `.claude/worktrees/` is ignored. It
  stages them as embedded-repo gitlinks, which gives the cloud clone broken submodules.
- Tripo v3 retarget **batch** mode concatenates clips into one — always `animationMode: "single"`.
- Tripo PBR materials are mostly metallic → keep emissive boosts ≤0.15 or models white-out under bloom.
- Some original repo files have CRLF line endings — string-replace patch scripts must normalise.
- After editing `server/realtime/server.js` run `node tools/embed-realtime.mjs` (the deploy script embeds it).
- Don't toggle light `visible` at runtime (changes shader light counts → recompiles/hitches).
- sharp holds file handles on Windows — read into a Buffer before overwriting in place.
