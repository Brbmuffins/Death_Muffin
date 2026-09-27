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
| [professions-g0-rules-server.md](professions-g0-rules-server.md) | `cloud/professions-g0` | — | 📝 ready (start first; parallel with G2) |
| [professions-g1-nodes-loop.md](professions-g1-nodes-loop.md) | `cloud/professions-g1` | — | 📝 ready (G0 contract; can stub) |
| [professions-g2-sextons-acre.md](professions-g2-sextons-acre.md) | `cloud/professions-g2` | — | 📝 ready (parallel with G0) |
| [professions-g3-art.md](professions-g3-art.md) | `cloud/professions-g3` | — | ⏸ needs the owner's Tripo OK + workstation keys |
| [professions-g4-ui-help.md](professions-g4-ui-help.md) | `cloud/professions-g4` | — | 📝 ready after G0 + G1 |

The professions briefs implement [`docs/PROFESSIONS-ROADMAP.md`](../PROFESSIONS-ROADMAP.md), which has the
design, the owner decisions (§12) and the later phases G5–G7 (gardening, processing, long tail).
**The Death Muffin backend is in scope for G0** (owner-authorised; see `docs/DEATH-MUFFIN-HANDOFF.md`),
but the original shared Crossworlds server is not.

**Checking on them from another workstation:** `git fetch origin && git branch -r | grep cloud/`.
If a branch exists, review its last commit message/report and follow the merge plan in
`HANDOFF.md`. If a branch is missing, the agent didn't finish (or couldn't push) —
re-dispatch the brief to a new agent, starting from the current `master`.
