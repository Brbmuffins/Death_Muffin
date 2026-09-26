# Agent briefs

Self-contained task briefs handed to parallel (cloud) agents. Each one is complete
enough to give to a fresh agent as-is. Status of each brief lives in `HANDOFF.md`
("In flight"). Rules every brief inherits: read `CLAUDE.md` + `HANDOFF.md`, never
edit the live REST server, push to the named branch only (no merge, no PR), and
leave `npx tsc --noEmit && npx vitest run && node --test server/realtime/server.test.js
&& npm run build` green.

| Brief | Branch | Dispatched |
|---|---|---|
| [combat-depth.md](combat-depth.md) | `cloud/combat-depth` | 2026-09-26 from `c475583` |
| [environment.md](environment.md) | `cloud/environment` | 2026-09-26 from `c475583` |
| [codex-onboarding.md](codex-onboarding.md) | `cloud/codex-onboarding` | 2026-09-26 from `c475583` |

**Checking on them from another workstation:** `git fetch origin && git branch -r | grep cloud/`.
If a branch exists, review its last commit message/report and follow the merge plan in
`HANDOFF.md`. If a branch is missing, the agent didn't finish (or couldn't push) —
re-dispatch the brief to a new agent, starting from the current `master`.
