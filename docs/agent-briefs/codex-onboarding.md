# Brief — Codex, onboarding, CI → branch `cloud/codex-onboarding`

Read `CLAUDE.md`, `HANDOFF.md`, then `src/content/*.ts`, `src/ui/HUD.ts`,
`src/ui/MiscPanels.ts`, `src/ui/ForgePanel.ts`, `src/ui/ui.css`, `src/theme/tokens.css`, and the
panel/event parts of `src/scenes/WorldScene.ts` (togglePanel, bindInput, closePanels,
handleEvent 'spawn'/'death'/boss).

1. **In-game Codex** — `src/ui/CodexPanel.ts` (`.cw-plate .cw-panel-float` styling, tab pattern
   like ForgePanel). Tabs: *Rites* (5 spells: icon, cost/cooldown, description, a "use it well" tip,
   SPELL_FX colour swatch), *Disciplines* (portrait `art/portraits/<id>.webp`, epithet, passive),
   *The Dead* (every enemy incl. Risen + the Bell-Sworn Prelate: behaviour, corpse type, counter-play),
   *The Diocese* (each area: level, unlock condition, dangers), *Covenant Lore* (3–4 short
   paragraphs on the Ossuary Covenant, restrained dark-fantasy tone). Enemy/area entries start
   sealed and unlock on first encounter; persist per character in localStorage
   (`cw_codex_v1_<characterId>`, try/catch). All text in `src/content/codex.ts`.
2. Wiring (keep minimal): Codex button in the HUD `.hud-menu` row (closed-book SVG in
   `src/ui/icons.ts`), hotkey **K**, `togglePanel('codex')`, discovery hooks in
   WorldScene.handleEvent ('spawn' → enemy, area entry → area, boss awaken → Prelate), toast
   "Codex updated: <name>".
3. **Onboarding tips** — `src/ui/Onboarding.ts`: once-per-character contextual tips (movement/attack
   on first load; "Press 2 to Exhume" when a corpse first appears nearby; Wave Speed when first
   affordable; "Kill the Crypt Deacon first" on first nearby deacon; sealed-door explanation near a
   locked gate). Small reliquary card above the hotbar, never blocks input, click/8 s to dismiss;
   `tips: boolean` in `src/app/settings.ts` with a Settings toggle.
4. **CI** — `.github/workflows/ci.yml`: push/PR to master, Node 24, `npm ci`, typecheck, vitest,
   `npm ci` in server/realtime then `node --test server/realtime/server.test.js`, `npm run build`,
   npm cache.
5. Tests: `src/content/__tests__/codex.test.ts` (every enemy/area/ability has an entry; discovery
   persistence).

Another agent concurrently edits WorldScene bindInput/handleEvent, WorldSim, AbilitySystem and
adds a soul meter to HUD.ts — keep WorldScene/HUD edits small and local. Do NOT edit
`src/graphics/WorldView.ts`, `src/content/layout.ts`, `src/gameplay/sim/**`, README.md. Theme
tokens only, no emoji. Verify `npm ci && npx tsc --noEmit && npx vitest run && npm run build`.
Commit on `cloud/codex-onboarding` and push; no PR, no merge. Report: branch, commit, files,
results, in-browser QA needed.
