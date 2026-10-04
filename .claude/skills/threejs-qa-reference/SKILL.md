---
name: threejs-qa-reference
description: "Reference notes for Death Muffin QA: bot playtest design (softlock windows, two reaction delays), visual regression and motion-evidence practice, release traps. Use when writing or reviewing a tools/qa smoke, a screenshot baseline, a bot or playtest check, a mobile check, or a release checklist."
---

# Three.js QA reference (Death Muffin)

Notes adapted from Majid Manzarpour's MIT-licensed `threejs-game-skills` (`threejs-qa-release`). License and attribution: `LICENSE-threejs-game-skills.txt`. **Reference reading only**: his canvas inspector, scaffold templates and director/evidence-manifest files are not part of this project and are not used.

## Our rules win

- Our harness is `tools/qa/` (README there): `run-all.mjs`, `lib/qa-common.cjs`, `window.__cwDebug.advance` stepping. Dev servers only on the ports the README names; never `pkill -f`, kill by PID.
- SwiftShader is a CPU rasteriser: FPS and frame time are fiction, compare calls/triangles/texture MB.
- Pixel metrics are compared with per-zone baselines (`tools/qa/lib/pixel-metrics.cjs`, `tools/qa/baselines/pixel-metrics.json`); his absolute thresholds assume bright arcade art.
- Phones are supported: `mobile-shots.cjs` and `mobile-nav-smoke.cjs`.
- No live server, DB, production site or paid API in QA unless the owner says so. Stage explicit paths only.

## Files

| File | Read when |
| --- | --- |
| `references/playtest-bot.md` | `tools/qa/bot-playtest-smoke.cjs`: softlock windows, error-free runs, difficulty at two reaction delays |
| `references/visual-test-harness.md` | baselines, determinism order (freeze, seed, stabilise), motion evidence for animation changes |
| `references/release-checks.md` | mobile checks, production-build checks, and the traps that reach players |
