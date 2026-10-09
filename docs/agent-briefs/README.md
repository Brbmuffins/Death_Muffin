# Agent briefs

> **OBSOLETE (archived 2026-10-09).** Every brief in this folder was written for web-era cloud agents; all are history. See [../ARCHIVE.md](../ARCHIVE.md).

These are dated design and implementation briefs, originally handed to cloud
contributors. Their branch names and instructions describe that original work,
not the current Git workflow. Read [the documentation map](../README.md),
`../../CLAUDE.md` and `../../HANDOFF.md` before taking up a brief. Check source
and the deployment record before treating a proposal as built or published.

| Brief | Original branch / owner | Dispatched | Status as recorded 2026-09-29 |
|---|---|---|---|
| [combat-depth.md](combat-depth.md) | `cloud/combat-depth` | 2026-09-26 from `c475583` | ✅ in master (`08c62b0`) |
| [environment.md](environment.md) | `cloud/environment` | 2026-09-26 from `c475583` | ✅ rebuilt on `claude/adoring-knuth-hd1uox` (`5e5e382`) |
| [codex-onboarding.md](codex-onboarding.md) | `cloud/codex-onboarding` | 2026-09-26 from `c475583` | ✅ in master |
| [professions-g0-rules-server.md](professions-g0-rules-server.md) | `cloud/professions-g0` | — | ✅ built on `claude/adoring-knuth-hd1uox` (2026-09-27, `fa43c9c`) |
| [professions-g1-nodes-loop.md](professions-g1-nodes-loop.md) | `cloud/professions-g1` | — | ✅ built on `claude/adoring-knuth-hd1uox` (`fa43c9c`) |
| [professions-g2-sextons-acre.md](professions-g2-sextons-acre.md) | `cloud/professions-g2` | — | ✅ built on `claude/adoring-knuth-hd1uox` (`fa43c9c`) |
| [professions-g3-art.md](professions-g3-art.md) | — (workstation) | 2026-09-27 | ✅ art generated on the workstation; node models live via `NodeViews` (see the brief + `docs/ART-BACKLOG.md`) |
| [professions-g4-ui-help.md](professions-g4-ui-help.md) | `cloud/professions-g4` | — | ✅ built on `claude/adoring-knuth-hd1uox` (`fa43c9c`) |
| [spell-variety-first-session.md](spell-variety-first-session.md) | `claude/adoring-knuth-hd1uox` + workstation | 2026-09-27 | ✅ Grimoire, expanded rites and Binbun wiring are in source; later rites/VFX were recorded as published in the 2026-09-28 VPS handoff |
| [mobs-barrow-ghoul-lich-acolyte.md](mobs-barrow-ghoul-lich-acolyte.md) | same historical branch | 2026-09-27 | ✅ Barrow Ghoul and Lich Acolyte are in source and recorded in the 2026-09-28 release |
| [area-bosses.md](area-bosses.md) | originally queued after mobs | 2026-09-27 | 🔨 Gravedigger King, Bone Abbess and Drowned Congregation are unstaged work in the current checkout; no publication recorded |
| [build-depth-aspects-runes.md](build-depth-aspects-runes.md) | same branch, after spell-variety (runes need a Death Muffin deploy) | 2026-09-27 evening | 📝 ready: 32 Rite Aspects (client-only) + 11 Relic Runes (server items + sockets, dropped by area bosses) |
| [world-dressing.md](world-dressing.md) | workstation + layout | 2026-09-27 | ◐ Partly implemented through `layout.ts` room dressing; check source for any remaining props |
| [new-classes.md](new-classes.md) | `claude/new-classes-framework` | 2026-09-27 | ✅ Five New Blood kits are recorded as deployed and publicly checked on 2026-09-28 in the VPS handoff |

The professions briefs implement [the professions roadmap](../PROFESSIONS-ROADMAP.md),
which also records owner decisions (§12). G6 processing is recorded as released;
G5 Grave Gardening and G7 long-tail work remain proposals.
**Historical workload split (2026-09-27).** A cloud agent built the code briefs G0 → G2 → G1 → G4. The workstation
session (the only one with `.ai-keys.local`) owns everything that calls Gemini or Tripo: G3 art, item icons,
tint variants and the art backlog (`docs/ART-BACKLOG.md`). It stays out of `items.ts`, `layout.ts`,
`WorldSim` and `src/ui/**` while the code agent owns them. If you need new art (herb or tool icons, more
props), leave it as a checklist line in the G3 brief rather than generating stand-in art yourself.

**The Death Muffin backend is in scope for G0** (owner-authorised; see `docs/DEATH-MUFFIN-HANDOFF.md`),
but the original shared Crossworlds server is not.

**Current collaboration:** check `git status --short`, both diffs and the top of
`HANDOFF.md` before editing shared files. Historical `cloud/*` branches do not
indicate that a task is still open; verify the feature in source and the dated
deployment handoff. Follow the repository's stage-without-commit rule unless
the user gives a different instruction.
