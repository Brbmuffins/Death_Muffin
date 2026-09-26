# Crossworlds

A dark fantasy necromancer action RPG in the browser (Vite + TypeScript + Three.js).
Explore one connected, desecrated realm — graveyard, ossuary, drowned nave, bell
sanctum — farming endless waves, turning corpses into thralls and spell fuel,
upgrading Damage and Wave Speed, and awakening the Bell-Sworn Prelate. Solo or
with up to three friends. No extraction, no run resets.

## Run it

```
npm install
npm run dev            # http://localhost:5188
```

- `http://localhost:5188/?offline` — DEV-only offline mode: an in-browser mock of
  the auth server, so you can play without the live backend.
- Live server: the dev server proxies the REST API to `playcrossworlds.com:3000`
  (override with `VITE_API_PROXY_TARGET`).
- Co-op locally: `cd server/realtime && npm install && cp .env.example .env && node server.js`,
  then `?offline&coop` in two tabs.

## Controls

Click to move / attack · Shift+click to cast in place · **1** Marrow Spear ·
**2** Exhume · **3** Miasma Circle · **4** Black Litany · **Q** healing flask ·
**T** return to the Chapterhouse · **I C P M** Reliquary, Workbench, Rites, Waystones ·
Wheel zoom · Enter chat · Esc settings

## Checks

```
npm run typecheck
npm test               # game-logic unit tests (vitest)
npm run test:server    # realtime service tests (node:test)
npm run build
```

## Docs

`CLAUDE.md` (working context) · `PHASE_REPORTS.md` (what's built) ·
`NECROMANCER_REDESIGN_AUDIT.md` (design direction) · `ASSET_PIPELINE.md`
(Gemini → Tripo → GLB) · `FUTURE_CONTENT.md` (backlog) · `server/` (realtime,
deploy, proposals).
