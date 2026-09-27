# HANDOFF — read this first

Living status document so any agent (or person) can pick the project up at any
point. **Update the "Current state" and "In flight" sections whenever you stop.**
> **VPS update, 2026-09-27:** Death Muffin now runs at https://muffindevelopment.com/death-muffin/. The live release includes Acre-first spawn, open-game AFK professions and ten-player co-op; source, checks and deployment tooling are committed at the user’s explicit request. Read [docs/DEATH-MUFFIN-HANDOFF.md](docs/DEATH-MUFFIN-HANDOFF.md) for current deployment, class switching, combat flow, Git access and verification; older cloud-only status below is historical.

Last updated: 2026-09-27 evening, workstation (latest: spell-variety / dev-access / Binbun runtime / first-session brief + art for the cloud agent, see "In flight"; before that: BinbunVFX port researched + documented for Codex): **everything combined on `master`** (the professions commit `fa43c9c`
fast-forwarded, plus the workstation's Grimoire, enemy pack, art batches and merge fixes, staged for the owner's
push). The full art inventory is in [`docs/ART-BACKLOG.md`](docs/ART-BACKLOG.md). Before that, the cloud session on `claude/adoring-knuth-hd1uox`: **professions G0 + G1 + G2 + G4 built**
(gathering rules + `/api/gather`, the Sexton's Acre, nodes + loop + Auto, Skills panel, stations, tips, Codex, README).
G3 art has since landed from the workstation. Earlier the same day (Windows workstation session: **Grimoire + four new rites**, **enemy variety pack +
processions**, **professions roadmap + agent briefs**; all staged, not committed. See the 2026-09-27
entries in `PHASE_REPORTS.md`). Before that: 2026-09-26 cloud session (environment, balance + Prelate
pass, difficulty, milestones, statuses, thrall variety, signature rites, onboarding, perf, Ascension,
VPS storage handoff).

## 60-second orientation

- **What it is:** Crossworlds — browser necromancer ARPG (Vite + TS + Three.js). One connected
  world, continuous waves, corpses → thralls/spells, Damage & Wave Speed upgrades, co-op ≤10,
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
| **Grimoire (L)**: 4 static rite slots, player-chosen from 8 rites; new Wailing Skull / Grave Step / Grave Frost / Bone Mantle (lvl 3/5/7/12); Gemini icons + tintable VFX sprites | ✅ tests + browser QA (2026-09-27) | `gameplay/loadout.ts`, `ui/GrimoirePanel.ts`, `AbilitySystem.ts`, `graphics/fxImages.ts`, `public/art/fx/` |
| **Enemy variety**: Censer Bearer (Incensed aura), Choir Wraith (scream ring), Skull-Rat packs, Bone Golem (3 corpses) + themed **processions**; Tripo models | ✅ tests + browser QA (2026-09-27) | `content/enemies.ts` (`WAVE_THEMES`), `WorldSim`, `EntityViews`, `public/models/{censer_bearer,skull_rat,bone_golem}`, `models/props/choir_wraith.glb` |
| **Professions / gathering**: shared rules + Death Muffin `POST /api/gather` (time budget, server rolls) | ✅ tests + live VPS deployment (2026-09-27) | `gameplay/gatheringRules.ts`, `server/death-muffin/backend/gathering/`, `migrations/002-gathering.sql`, `server/death-muffin/GATHERING_DEPLOY.md` |
| The Sexton's Acre (safe zone west of the Chapterhouse, every node tier, pond, stations) + rich nodes in hunting grounds | ✅ QA'd in-browser | `content/areas.ts`, `content/layout.ts` (`nodes`, `ponds`), `graphics/WorldView.ts`, `Atmosphere.ts` |
| Gathering nodes in the sim (shared depletion, `gather` intent, snapshot `depleted`), loop + Auto, stand-in node views | ✅ sim/loop tests + browser QA | `sim/WorldSim.ts`, `gameplay/Gathering.ts`, `gameplay/gatherPlan.ts`, `graphics/NodeViews.ts`, `nav.findPath` |
| Skills panel (P), node hover card, Bone Kiln / Sawpit / Cooking Fire, 6 counsel tips, Codex Professions tab | ✅ QA'd | `ui/ProfessionsPanel.ts`, `ui/ForgePanel.ts` (stations), `ui/HUD.ts` (`nodeTip`), `ui/Onboarding.ts`, `ui/CodexPanel.ts` |
| Node art (Tripo `prop_node_*`), Grave Gardening (G5), new processing recipes (G6), long tail (G7) | 📝 G3 with the owner; G5–G7 not started | `docs/PROFESSIONS-ROADMAP.md` §10, §13 |

## In flight (check before starting overlapping work)

- **Two new mobs (brief ready 2026-09-27 evening):**
  [`docs/agent-briefs/mobs-barrow-ghoul-lich-acolyte.md`](docs/agent-briefs/mobs-barrow-ghoul-lich-acolyte.md).
  - **Barrow Ghoul:** a new Tripo model (145 credits), `public/models/barrow_ghoul/`. It burrows, erupts in a
    telegraphed ring and gives the Hollow Graves its first new mob.
  - **Lich Acolyte:** the existing model. It raises your fallen thralls against you in the Nave and the Sanctum.

  Cloud code work; the art is staged on `master`.
- **Spell variety + dev access + Binbun runtime + first-session readability (brief ready 2026-09-27 evening).**
  The owner couldn't find where to swap rites; the Grimoire exists (L) but is hidden and gated at levels 3–12. They
  asked for:
  - more rites;
  - full access for their `brbmuffins` dev account;
  - the Godot/Binbun VFX, including world effects;
  - interactables (the Altar and similar) that a first-time player can't miss.

  The cloud agent builds from
  [`docs/agent-briefs/spell-variety-first-session.md`](docs/agent-briefs/spell-variety-first-session.md). The
  workstation has staged on `master`:
  - 45 more Binbun conversions (67 total, including seven `world_*` shader kits);
  - five tintable rite sprites (`public/art/fx/`, `gemini-jobs/spells-v5.json`).

  The rite icons already existed. The owner pushes `master` via GitHub Desktop; the agent merges `origin/master`
  into its branch first.

- **BinbunVFX → Three.js port (started 2026-09-27; local conversion complete, runtime pending).** The owner's
  Godot VFX packs (from `F:\`, licence confirmed for this non-profit game) are
  vendored raw in `art-src/vendor/binbun/` (gitignored, workstation only). Read
  [`docs/BINBUN-VFX-PORT.md`](docs/BINBUN-VFX-PORT.md) end to end. The workstation-only step is done:
  `tools/binbun-port.mjs` produced 22 portable effects under `public/fx/binbun/`, so a cloud session no longer
  needs `art-src/` for this selected batch. Next: build `src/graphics/binbun/BinbunFX.ts`, translate/verify the
  committed shaders, add the DEV gallery, and wire the proposed spell/world hooks. Source/selection records:
  `art-manifest/binbun-vfx.json` and `art-manifest/binbun-effects.json`. Rules: additive only (keep today's
  effects), recolour from `SPELL_FX`, never add PointLights (use `Effects.lightFlash`), and keep asset loading
  non-blocking/fail-open so combat can never wait on or fail because of VFX. Do not replace the current visuals
  before gallery + combat-readability + dense-wave perf QA. Stage, don't commit.

**Professions / gathering: G0, G1, G2 and G4 are built** on `claude/adoring-knuth-hd1uox` (one session, one branch,
not the per-brief `cloud/professions-g*` branches). **G3 art has landed** (workstation, 2026-09-27): the node GLBs are
live as `models/props/prop_node_<model>.glb` (trees, stump, seams, geode, rubble, all four grave tiers, Bone Kiln), and
the seam/geode vein colour stays a code-built emissive overlay. Item icons need no `icon` field, because inventory and
loot load `art/items/<id>.png` by name. Art that exists but has no code yet (stations, garden stages, tools, tool-tier
icons, herbs, planks, meals, skills) is listed in [`docs/ART-BACKLOG.md`](docs/ART-BACKLOG.md). **Wire it; don't make stand-ins.** Next are G5 (Grave Gardening: plots, seeds, tree
patches; `seed_mourning_moss` already drops) and G6 (recipes for the new logs, fish, bones → bone meal, gems). Owner
decisions assumed are listed in `server/death-muffin/GATHERING_DEPLOY.md`. Brief status: [`docs/agent-briefs/README.md`](docs/agent-briefs/README.md).

The three older agent briefs in [`docs/agent-briefs/`](docs/agent-briefs/README.md) are done:

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

**From the 2026-09-27 session (needs the user / a deploy):**
- **Commit + push `master` through GitHub Desktop.** Everything is combined and staged on `master`: the professions
  commit (fast-forward) plus all workstation work restored from GitHub Desktop's two branch-switch stashes. Safety refs
  `backup/art-batch-stash` and `backup/art-late-stash` hold those stashes. Delete them (and the two stash entries)
  once the push is confirmed. `cloud/*` and `worktree-agent-*` branches are older work already folded into master, and
  `origin/CrossWorldsWEB` is the July-era README/audit branch, deliberately not merged. This shell can't reach GitHub
  (no stored credentials), so fetch and push from GitHub Desktop. The VPS has its own deploy key.
- **Deploy realtime with the client.** The realtime server gained `signature` sig `mantle` (Bone Mantle) and a
  sanitised `hit.chill` flag (`deploy-realtime.sh` is re-embedded). An older realtime server drops Bone
  Mantle for co-op **guests** (hosts and solo play are fine), and Grave Frost's chill passes through unsanitised.
- `necro-rules.cjs` was regenerated (it embeds `areas.ts`, whose rosters changed). Re-install it if the
  necro-progress package is already on the VPS.
- Ear-test the four new rite sounds (`wail`, `bloodStep`, `frost`, `mantle`) and the look of the new mobs in a visible browser.
- Tripo spent this session (owner-approved; ledger in `docs/ART-BACKLOG.md` §5): the enemy pack (395), 14 node props
  (700), the hero `attack` clip ×5 (50), and the roadmap batch (tools, thrall gear, wraith thrall, 13 more profession
  props, Lich Acolyte, three bosses, five class heroes). `NodeViews` gained `live` models for Blackthorn, Ghostwood,
  crypt collapse and barrow tomb (data only). Node props keep the `prop_` prefix at build time (`tools/build-characters.mjs`).
- **Workload split:** cloud agents build code; the workstation (the only machine with `.ai-keys.local`) does
  Gemini/Tripo work and tracks it in `docs/ART-BACKLOG.md`. Signature-rite icons and the dedicated Corpse Explosion icon are wired (`abilities.ts`; the HUD's
  hue-rotate hack was removed from `ui.css`).
- **Merge fix (PR #4 spell cards × Grimoire):** the cards' listeners are now bound in `HUD.bindSlots()`,
  so they survive the slot rebuild a Grimoire swap does (before this, cards stopped opening after any swap).
  Native `title`s are gone (the cards replace them). `spellTooltip` covers the four new rites, shows the
  rite's actual loadout key and locks by `unlockLevel`.
- `docs/SPELL-VARIETY-PLAN.md` (VPS session, PR #4) was written before the Grimoire shipped. Its loadout
  proposal (role-locked slots), Bone Mantle and Frost Wake overlap what now exists. Reconcile it with
  `GRIMOIRE` before anyone builds from it.

**From the professions build (needs the user / a deploy):**
- **Deploy gathering to Death Muffin:** follow `server/death-muffin/GATHERING_DEPLOY.md` (backup, check the professions
  column type, migration 002, copy `backend/gathering/` + `server.js`, restart the auth service, verify, publish the client).
  `POST /api/professions/award-xp` now answers 410; nothing in the client used it.
- **Realtime:** a new `gather` intent (validated, `successes` clamped to 1–3; `deploy-realtime.sh` re-embedded). An older
  realtime server drops it, so guests' node depletion stays local until it's deployed.
- **Workbench fix, worth deploying soon:** the live `/api/craft` replies with the result, not the bag, and the old client
  kept the pre-craft bag, so the next full-bag save could write spent ingredients back. `ForgePanel` now re-reads the
  inventory and professions after every craft. The offline mock also served `/api/recipes` only with a token, which left
  the Workbench empty offline; fixed.
- **Owner decisions (roadmap §12)** are still open. The code defaults to the live XP rule (`XP_CURVE = 'live'`), optional
  tools, no character XP from gathering, cap 99, and shared depletion with per-player rewards.

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
- **Windows checkout = CRLF working tree** (`core.autocrlf=true`). Git Bash's `grep -c $'\r'` reports 0 even
  on CRLF files, so check with Node. Scripted string edits must match `\r\n`. The rules-bundle parity test
  now compares with line endings normalised.
- The Gemini tool's `post.lumaAlpha` + `post.mask` turn white-on-black art into tintable VFX sprites
  (`ASSET_PIPELINE.md` §1). A rig-less Tripo model builds as a **prop** GLB (`models/props/<id>.glb`), so
  register a static creature (the Choir Wraith) with that URL in `modelPaths.ts`.
- Another session may hold port 5188; `.claude/launch.json` has `crossworlds-web-alt` on 5198.
- A long-running Vite dev server on this Windows drive can **serve stale modules** after edits (the watcher
  misses changes). If behaviour doesn't match the source, `fetch('/src/…')` in the page to confirm, then restart the preview.
