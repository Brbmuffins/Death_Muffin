> **Reference only. Source: Majid Manzarpour, `threejs-game-skills` (MIT, see `LICENSE-threejs-game-skills.txt`), trimmed for Death Muffin.**
> Our rules override anything below: spend is approval-gated and recorded in `art-manifest/`; stage explicit paths (never `git add -A`, the tree is shared);
> `SPELL_FX` colours carry meaning; phones and tablets are supported; Three.js here is 0.166.1 (the source targets r184, check API before pasting);
> there is no generation, credential probe, scaffold or auto-spend step in this project. Dark art is intentional: do not chase his brightness numbers.
> Our numbers live in `docs/PERF-BUDGET.md`; the budget table below is his starting point, not our contract.

# Release Checks

What to check beyond the QA pass in this skill's `SKILL.md`, and the traps that repeatedly ship broken games.

Apply the full list for a release or a complete game. For a narrow change select the affected behavior and shared risks, and reuse the lead's checks from the same code/asset revision. Mobile checks apply when mobile is a supported target. Changes to animated models need the motion pass in `visual-test-harness.md`.

## Mobile

- Touch controls emit game intents, not just visual press states.
- Pointer release, cancel, and blur cannot leave a control stuck down.
- Safe areas respected; touch targets reachable and separated.
- Page scroll does not steal gameplay input.
- Orientation change and resize preserve canvas and HUD.
- DPR and frame time acceptable on the mobile tier.
- Desktop input still works unless it was intentionally removed.

## Production release

- Production build passes, and the production preview or static server is the thing actually tested.
- Vite `base` and asset URLs match the target host; public assets load under the static-hosting assumption.
- Debug GUI, diagnostics overlays, verbose logging, and test shortcuts are gated or removed from the player-facing build.
- Bundle and large assets reviewed.
- No API keys in client code, checked-in files, built assets, or browser-visible environment.
- Deployment command or static artifact location and browser support assumptions documented.

## Performance evidence

When draw calls, asset counts, shaders, shadows, or post-processing changed: renderer calls, triangles, geometries, textures; FPS or frame time where available; DPR cap and post/shadow settings; physics engine, timestep, body and collider counts, active sensors, CCD bodies when physics changed. Measure during active gameplay, not the idle view, and compare before/after when performance work was the request.

## Traps

These are the failures that actually reach players:

- Dev server tested, production build shipped untested.
- Static host base path breaks every asset.
- Debug UI visible to players.
- Mobile UI passes a screenshot but the controls do not work.
- Canvas is non-blank but the wrong app is running on that port.
- Physics looks right on screen while collision proxies, sensors, or restart cleanup were never exercised.
- Screenshots are title or idle views rather than active play.
- A capture was labeled with a requested state that its hook never applied, or old reports were reused as current-run evidence.
- A premium claim with no scorecard and no renderer diagnostics.
- A generation API key or a temporary provider URL left in client code.
- (Ours) Dev server tested, built `dist` shipped untested: always `npm run build` and smoke the build too.
