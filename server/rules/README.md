# Shared game rules (server-side source of truth)

TypeScript rule modules (`gameplay/*Rules.ts`) and the content they read (`content/`, `types.ts`). They are not run
directly: `npm run build:server-rules` bundles each rule entry into the CommonJS files the live backend requires
(`server/death-muffin/backend/gathering/*-rules.cjs`, `server/vps-handoff/necro-progress/necro-rules.cjs`), and the
`tools/build-*-sql.mjs` / `tools/generate-necro-weapons.mjs` generators write the content migrations from `content/`.

The Godot client has its own GDScript port of these rules (`godot/rules/`); a change here that players should see
needs the matching change there.

- Change a rule or content table here, then `npm run build:server-rules` (and the matching SQL generator) and commit
  both; `node tools/build-server-rules.mjs --check` / the `--check` generators fail when a committed copy is stale.
- Tests: `npm run test:rules` (unit) and `npm run test:server` (backend, includes the freshness checks).

Moved out of the retired web client's `src/` on 2026-10-09 (Phase 3 of the baseline reset); bundles were byte-identical
apart from their path comments.
