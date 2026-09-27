# HANDOFF — read this first

Living status document so any agent (or person) can pick the project up at any
point. **Update the "Current state" and "In flight" sections whenever you stop.**
> **VPS update, 2026-09-27:** Death Muffin now runs at https://muffindevelopment.com/death-muffin/. Read [docs/DEATH-MUFFIN-HANDOFF.md](docs/DEATH-MUFFIN-HANDOFF.md) for current deployment, class switching, combat flow, Git access and verification; older cloud-only status below is historical.

Last updated: 2026-09-26 (cloud session: environment, balance + Prelate pass, difficulty, milestones, statuses, thrall variety, signature rites, onboarding, perf, Ascension, VPS storage handoff).

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
(cd server/realtime && npm ci)     # test:server needs the realtime service's deps (dotenv, socket.io)
npm run typecheck && npm test && npm run test:server
npm run balance                   # headless farming/danger table — targets + current numbers in BALANCE.md
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
| Progression: XP/gold → server; tiers/shards/unlocks/Ascension → server when `/api/necro-progress` exists, else localStorage | ✅ client + mock; **server side awaits the VPS** | `gameplay/progression.ts`, `gameplay/necroRules.ts`; VPS brief `server/VPS_HANDOFF.md` |
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
| Combat depth: Corpse Explosion, elite affixes, Grave Surges, Soul Harvest | ✅ in master + QA'd in-browser | `gameplay/sim/WorldSim.ts`, `AbilitySystem.ts`, `HUD.ts` |
| Environment: nave water + puddles, per-area weather, distant silhouettes | ✅ QA'd in-browser (high + low) | `graphics/Water.ts`, `graphics/Atmosphere.ts`, `WorldView.ts`, `content/layout.ts` |
| First balance pass (danger at intended band, tamer Wave Speed) | ✅ harness | `BALANCE.md`, `content/enemies.ts`, `content/areas.ts`, `content/upgrades.ts` |
| Prelate balance (boss harness `npm run balance:boss`, ~95k HP solo) | ✅ harness + guard-rail tests | `gameplay/balance/boss.ts`, `sim/BossBrain.ts` |
| Easy / Medium / Hard difficulty (host-authoritative, in snapshots) | ✅ QA'd | `content/difficulty.ts`, Settings |
| Wave Speed milestones: Elite Vanguard / Restless Crypts / Nightfall | ✅ QA'd | `content/upgrades.ts`, `WorldSim`, HUD dial |
| Grave Surges from mausoleums/sarcophagi | ✅ QA'd | `layout.crypts`, `WorldSim.startSurge` |
| Statuses: Hemorrhage, Chill, Sanctified, Bone Hex, Silenced | ✅ QA'd | `content/statuses.ts`, snapshot flag bits 3/12–15 |
| Thrall variety: archer / bone mage / plague bearer (from the corpse) | ✅ QA'd | `WorldSim.applyExhume`, `EntityViews` |
| Signature rites (lvl 10, key R): Ossuary Wall, Command: Rend, Dirge, Plague Bloom | ✅ QA'd (wall + locked slot in browser; all four sim-tested) | `content/abilities.ts`, `WorldSim.applySignature`, realtime `signature` intent |
| Onboarding: welcome + 12 just-in-time tips, "Show tips again" | ✅ QA'd | `ui/Onboarding.ts` |
| Horde perf: per-area prop batches + shadow LOD (−40% triangles at the cap) | ✅ measured | `WorldView`, `EntityViews.shadowLod`, `__cwDebug.perf()` |
| Relic runes | 📝 server proposal only | `server/proposals/relic-runes.md` |
| **Ascension** (prestige): Altar panel, Ashes, 9 Covenant Boons, +3 levels/rank, snapshot-synced rank | ✅ QA'd (full ascend + boon flow in browser) | `content/ascension.ts`, `progression.ts`, `ui/AscensionPanel.ts` |
| **VPS storage package** (validated `/api/necro-progress/*` routes, MySQL store, schema, shared rules bundle, tests) | ✅ tested with an in-memory store + mock backend; not installed yet | `server/vps-handoff/necro-progress/`, `server/VPS_HANDOFF.md`, `npm run build:server-rules` |

## In flight (check before starting overlapping work)

Nothing is in flight. All three agent briefs in [`docs/agent-briefs/`](docs/agent-briefs/README.md) are done:

| Brief | Where it landed |
|---|---|
| Combat depth (`cloud/combat-depth`) | Folded into master in `08c62b0`; browser-QA'd 2026-09-26. |
| Environment (`cloud/environment`) | The branch never reached GitHub, so it was rebuilt from the brief on the cloud branch `claude/adoring-knuth-hd1uox` (`5e5e382`). |
| Codex + onboarding + CI (`cloud/codex-onboarding`) | Folded into master earlier. |

**Cloud-session branch:** `claude/adoring-knuth-hd1uox` carries the environment work, the balance
pass and these doc updates on top of master `08c62b0`. Cloud sessions commit and push (they have
no GitHub Desktop). Merge it through GitHub, or pull it into GitHub Desktop.

**Folding a finished local branch into master without committing** (this matches the
stage-don't-commit rule): `git diff --binary <base> <branch> > x.patch && git apply --3way x.patch`.
Run it from bash; PowerShell pipes rewrite line endings and corrupt the patch. `git merge`
refuses while the index has staged changes.

## Known issues / next steps (priority order)

**Needs the user (can't be done from a cloud container):**
1. **Ear-test audio** in a visible browser (volumes, ambience crossfades, boss drum loop).
2. **Server storage for progression.** Hand `server/VPS_HANDOFF.md` to a Claude Code session on the
   VPS. It installs `server/vps-handoff/necro-progress/` (additive routes + one new table) after
   recon and backups. The client already switches to it on its own: `Progression.connect()` falls
   back to localStorage on a 404, and on the first successful connect it uploads the browser save once,
   after which the server's copy wins. The web client from this branch has to be deployed too.
3. **Deploy.** Realtime protocol v2 and the client must ship together (`server/realtime/DEPLOY.md`,
   `server/web-deploy/`). The user runs the scripts.
4. **A human playtest of the new balance.** The bot is an upper bound on efficiency and never
   dodges. Report how intended/push feel, and see "Open issues" in `BALANCE.md`.

**Buildable next (code-only):**
5. **Replay depth, continued.** Ascension shipped. Next from `FUTURE_CONTENT.md` → "Replay & endgame
   depth": daily rites (date-seeded objectives paying Ashes), discipline talents (levels 5/15/20), weekly
   omens, Prelate Echoes per rank. Rank/Ashes/boons are already part of the VPS storage package.
   Any new persistent field has to go through `necroRules.ts`, followed by `npm run build:server-rules` and
   a re-install on the VPS.
6. **Co-op session dashboard** (user request). Easy/Medium/Hard is the first slice. The rest (Wave
   Speed, HP/damage, density, elites, surges, arrival wave, roster weights) becomes a host panel
   relaying a validated `tuning` field. Spec: `FUTURE_CONTENT.md` → "Co-op session dashboard".
7. **Art for new content** (needs the Gemini/Tripo keys on the workstation, `ASSET_PIPELINE.md`):
   icons for the four signature rites and Chill/Silenced (currently retinted or inline-SVG
   placeholders), and real bow/staff models for archer and bone-mage thralls.
8. **Discipline balance.** Gravecaller is the weakest under pressure and Ossuary swings the most
   (`BALANCE.md`). Signature rites and thrall variety aren't in the farming bot yet, so add them to
   `harness.ts` before tuning.
9. **Realtime deploy note:** protocol additions this session are `signature` intents, `hit.bleed`,
   and snapshot `difficulty` plus new flag bits. Older clients ignore them, but ship client and
   realtime together (`server/realtime/DEPLOY.md`; `deploy-realtime.sh` is already re-embedded).

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
- `npm run test:server` fails with `Cannot find module 'dotenv'` on a fresh clone. Run
  `cd server/realtime && npm ci` first (CI already does this).
- Headless QA in a cloud container: global Playwright + `--use-angle=swiftshader`. Drive time with
  `__cwDebug.advance()`, and call `unlockAll()` before `goto()` into a locked area (otherwise
  `goto` leaves you at the sealed gate). Seed `localStorage.cw_settings_v1 = {"tips":false}` to hide
  onboarding cards in screenshots.
- `src/gameplay/necroRules.ts` is bundled into `server/vps-handoff/necro-progress/necro-rules.cjs`.
  After editing it (or anything it imports, e.g. `content/upgrades.ts`, `content/ascension.ts`, `content/areas.ts`),
  run `npm run build:server-rules`. The parity test in `necroServer.test.ts` fails if the bundle is stale.
- Water/decal layering: water renders at renderOrder 1, and Effects decals (telegraphs) at 2. Keep
  that order or telegraphs sink under the nave's flood.

