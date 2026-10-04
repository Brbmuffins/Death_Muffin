> **Reference only. Source: Majid Manzarpour, `threejs-game-skills` (MIT, see `LICENSE-threejs-game-skills.txt`), trimmed for Death Muffin.**
> Our rules override anything below: spend is approval-gated and recorded in `art-manifest/`; stage explicit paths (never `git add -A`, the tree is shared);
> `SPELL_FX` colours carry meaning; phones and tablets are supported; Three.js here is 0.166.1 (the source targets r184, check API before pasting);
> there is no generation, credential probe, scaffold or auto-spend step in this project. Dark art is intentional: do not chase his brightness numbers.
> Our numbers live in `docs/PERF-BUDGET.md`; the budget table below is his starting point, not our contract.

# Visual Test Harness

Screenshot baselines are worth adding when the visual state is valuable enough to protect and deterministic enough to compare — not for every prototype.

**Add or extend** when the user asked for premium/AAA/showcase/release-ready quality, when HUD or responsive text fit has regressed before, when imported assets must be proven visible in-game, when a signature scene is worth protecting, or when every release needs desktop/mobile active-play evidence. For a narrow fix, protect the affected state; do not re-run unrelated release coverage just because the existing game is premium.

**Defer** for exploratory prototypes, intentionally random scenes that cannot be seeded quickly, and images dominated by particles or noise where masking would hide the actual assertion. If the only question is "is the canvas non-blank", `tools/qa/lib/pixel-metrics.cjs` answers it. Say which way you went and why.

## States worth capturing

Two to five high-value states: `active-play-desktop` (player, objective, threat, reward, HUD all visible), `active-play-mobile` (same under mobile viewport and touch controls), `pause-or-settings` (layout, safe areas, text fit), `fail-or-retry`, and `hero-asset` (imported or generated asset in real lighting at real camera distance).

Title-only screenshots are only useful when title/menu work is the change.

## Determinism contract

Our equivalent of the hook contract is `window.__cwDebug` (see `tools/qa/lib/qa-common.cjs` and `first-hour-lib.cjs`, which also freezes timers and rAF). The shape below is his, for reference:

```ts
window.__THREE_GAME_TEST_HOOKS__ = {
  seed: setGameSeed,
  async setState(name: string) {
    if (!supportedStates.has(name)) throw new Error(`Unknown test state: ${name}`);
    await loadAssetsForState(name);
    await enterGameState(name);
    return { state: name };
  },
  setPausedForScreenshot: setSimulationPaused,
  setReducedMotion: setReducedMotion,
  hideDebugUi: hideDebugUi,
};
```

The example's helpers are project-owned implementations, not placeholders to copy as no-ops. Keep hooks real: a silent no-op hook captures a live animating scene and every rerun diffs.

Before a baseline, follow this order: unpause, seed, apply and await the state, freeze immediately, then stabilize particles and noise, disable camera shake, hitstop and time-dependent post, hide debug overlays, and wait for fonts and rendered frames. These visual hooks must work while paused, without a gameplay tick. Use fixed viewport profiles and mask dynamic UI only where the masked area is not part of the acceptance criteria.

## Playwright

We do not use Playwright Test snapshots; our smokes are plain Node scripts (`tools/qa/*.cjs`) and our baselines are metric JSON (`tools/qa/baselines/pixel-metrics.json`). His guidance, for reference:

Thresholds: low `maxDiffPixelRatio` for stable UI and menu states, slightly higher for WebGL antialiasing and post-processing variation, never so high that a real layout or asset failure slips through.

## Asset visibility

For generated or imported assets, assert the path is loaded or present in diagnostics, screenshot it in active gameplay rather than a showroom, and check scale, orientation, bounds, material readability, and collision proxy. Keys stay out of baseline paths and client code.

## Motion Evidence

For substantial animated gameplay, rig, or clip changes, capture a short unpaused sequence at the real gameplay camera. Cover at least a complete relevant motion cycle, locomotion start/stop and clip crossfades, plus attack/impact/recovery when combat is present. Record Playwright video (`recordVideo` on the context, close the context to finalize it), the runner's video tool, or a timed frame sequence with animation diagnostics. Do not use the paused screenshot hook for this pass.

Inspect for frozen rigs, collapsing or stretching limbs, foot sliding relative to world displacement, root-motion double application, snapping transitions, looping attacks, and hit/contact events that disagree with the visible motion. Note clip names, durations, mixer action changes, and event times alongside observed defects. Test active movement and interruption through real input, not only a forced pose. Rigid-body-only games need checks of their actual physics/motion, not an invented skeleton audit.

Write each run's shots to its own `DM_QA_ARTIFACT_DIR` (`run-all.mjs` does) so old screenshots are never reused as new evidence. File existence alone cannot establish good motion. Keep the detailed visual decision, states covered, commands, paths, thresholds, masks, motion findings, and flake risks in the lead's consolidated evidence artifact.
