> **Reference only. Source: Majid Manzarpour, `threejs-game-skills` (MIT, see `LICENSE-threejs-game-skills.txt`), trimmed for Death Muffin.**
> Our rules override anything below: spend is approval-gated and recorded in `art-manifest/`; stage explicit paths (never `git add -A`, the tree is shared);
> `SPELL_FX` colours carry meaning; phones and tablets are supported; Three.js here is 0.166.1 (the source targets r184, check API before pasting);
> there is no generation, credential probe, scaffold or auto-spend step in this project. Dark art is intentional: do not chase his brightness numbers.
> Our numbers live in `docs/PERF-BUDGET.md`; the budget table below is his starting point, not our contract.

# Bot Playtest

Automated playtests drive the game through scripted real input and measure whether it actually plays: objective progression, player responsiveness, softlock windows, and error-free runtime. A game that renders beautifully but cannot be progressed by a scripted sweep is not release-ready. Use this for release-ready gameplay claims and difficulty/fairness verification; the canvas inspector proves the game renders, the bot proves it plays.

## Prerequisites

Ours: `window.__cwDebug` (`advance`, `counts`, `teleport`, `cast`, ...) instead of his diagnostics/test-hook globals; `tools/qa/bot-playtest-smoke.cjs` is our implementation. Gameplay randomness is not fully seeded, so treat results as samples.

## Setup

Run `node tools/qa/bot-playtest-smoke.cjs` (see `tools/qa/README.md`). In his scheme, adapt the input script to the game's controls and level layout: an endless runner bot holds forward and switches lanes on a cadence; an arena game sweeps the play space; a tower defense bot clicks a build pad and starts waves. Game-specific hooks (e.g. `forceWave()`) can set up later states, but separately exercise actual player controls so hooks cannot hide broken input.

## Metrics And What They Mean

- `framesAdvanced` — the loop survived the whole run; a stall here is a crash or frozen loop.
- `distanceTravelled` — input responsiveness; near-zero under held keys means broken input mapping.
- `scoreAfter - scoreBefore` and `stepOfFirstScore` — objective progression and how quickly a naive player finds it. If a scripted sweep never scores, the objective is unreachable, unreadable, or broken.
- `softlockWindows` — sampling windows where frames advanced but held input produced neither motion nor progress. Repeated windows indicate stuck-on-geometry, dead input states, or unrecovered fail states.
- Time-to-first-fail (games with fail states) — add a scripted "reckless" run that seeks hazards and assert the fail state triggers and the retry path restores play; a game that cannot be failed has no pressure, and a fail state that cannot be retried is a release blocker.
- Console/page errors — must be empty for the full run.

## Headless WebGL Caveats

- On this VPS Chromium renders on SwiftShader (CPU): frame time and FPS are fiction (we say so in `docs/BLENDER-AUDIT.md`). Compare draw calls, triangles and texture MB only, and step the sim with `__cwDebug.advance`.
- Run WebGL suites one at a time (`run-all.mjs` does). Parallel contexts contend for the GPU, so game time drifts from wall time and timed phases and baselines flake.
- Headless FPS on a real GPU is a desktop signal, not a phone. Validate mobile performance on real hardware.

## Difficulty And Fairness Signals

For games with fail states, run the bot at two skill levels (e.g. reaction delay 0ms vs 300ms between script steps) and compare survival time and score. If the delayed bot survives as long as the fast one, difficulty pressure is decorative; if even the fast script cannot survive the first threat, the opening is unfair. Report both runs when difficulty tuning is in scope.

## Reporting

Include in the QA evidence: the JSON report attachment (steps, frames, score progression, distance, softlock windows, errors), the seed used, and pass/fail per assertion. Report the bot playtest decision like the visual harness decision: added / extended / skipped with reason.
