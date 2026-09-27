# Agent briefs

Self-contained task briefs handed to parallel (cloud) agents. Each one is complete
enough to give to a fresh agent as-is. Status of each brief lives in `HANDOFF.md`
("In flight"). Rules every brief inherits: read `CLAUDE.md` + `HANDOFF.md`, never
edit the live REST server, push to the named branch only (no merge, no PR), and
leave `npx tsc --noEmit && npx vitest run && node --test server/realtime/server.test.js
&& npm run build` green.

| Brief | Branch | Dispatched | Status |
|---|---|---|---|
| [combat-depth.md](combat-depth.md) | `cloud/combat-depth` | 2026-09-26 from `c475583` | ✅ in master (`08c62b0`) |
| [environment.md](environment.md) | `cloud/environment` | 2026-09-26 from `c475583` | ✅ rebuilt on `claude/adoring-knuth-hd1uox` (`5e5e382`) |
| [codex-onboarding.md](codex-onboarding.md) | `cloud/codex-onboarding` | 2026-09-26 from `c475583` | ✅ in master |
| [professions-g0-rules-server.md](professions-g0-rules-server.md) | `cloud/professions-g0` | — | ✅ built on `claude/adoring-knuth-hd1uox` (2026-09-27, `fa43c9c`) |
| [professions-g1-nodes-loop.md](professions-g1-nodes-loop.md) | `cloud/professions-g1` | — | ✅ built on `claude/adoring-knuth-hd1uox` (`fa43c9c`) |
| [professions-g2-sextons-acre.md](professions-g2-sextons-acre.md) | `cloud/professions-g2` | — | ✅ built on `claude/adoring-knuth-hd1uox` (`fa43c9c`) |
| [professions-g3-art.md](professions-g3-art.md) | — (workstation) | 2026-09-27 | ✅ art generated on the workstation; node models live via `NodeViews` (see the brief + `docs/ART-BACKLOG.md`) |
| [professions-g4-ui-help.md](professions-g4-ui-help.md) | `cloud/professions-g4` | — | ✅ built on `claude/adoring-knuth-hd1uox` (`fa43c9c`) |

The professions briefs implement [`docs/PROFESSIONS-ROADMAP.md`](../PROFESSIONS-ROADMAP.md), which has the
design, the owner decisions (§12) and the later phases G5–G7 (gardening, processing, long tail).
**Workload split (2026-09-27).** A cloud agent builds the code briefs G0 → G2 → G1 → G4. The workstation
session (the only one with `.ai-keys.local`) owns everything that calls Gemini or Tripo: G3 art, item icons,
tint variants and the art backlog (`docs/ART-BACKLOG.md`). It stays out of `items.ts`, `layout.ts`,
`WorldSim` and `src/ui/**` while the code agent owns them. If you need new art (herb or tool icons, more
props), leave it as a checklist line in the G3 brief rather than generating stand-in art yourself.

**The Death Muffin backend is in scope for G0** (owner-authorised; see `docs/DEATH-MUFFIN-HANDOFF.md`),
but the original shared Crossworlds server is not.

**Checking on them from another workstation:** `git fetch origin && git branch -r | grep cloud/`.
If a branch exists, review its last commit message/report and follow the merge plan in
`HANDOFF.md`. If a branch is missing, the agent didn't finish (or couldn't push) —
re-dispatch the brief to a new agent, starting from the current `master`.
