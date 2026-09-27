# Brief G4: skills UI, stations and help → branch `cloud/professions-g4`

Depends on G0 (API + rules) and G1 (node data in the scene). Read `CLAUDE.md` (the help rule: every new
mechanic ships with a counsel tip, a Codex entry, Settings keys and the README), `HANDOFF.md`,
**`docs/PROFESSIONS-ROADMAP.md`** §3, §7, §11, then `src/ui/ProfessionsPanel.ts`, `ForgePanel.ts`,
`GrimoirePanel.ts` (the newest panel; reuse its patterns), `CodexPanel.ts`, `Onboarding.ts`, `HUD.ts`,
`src/content/codex.ts`, `src/ui/ui.css`.

1. **Skills panel** (grow the Rite Niches, `P`): a RuneScape-style grid of every gathering and processing
   skill with level, XP bar, XP to next level, **total level**, and what unlocks at the next level (nodes,
   recipes, seeds). Live-updates from the gather reply.
2. **Node tooltip / hover card** (name, level requirement, XP per action, the "Requires …" state) and a
   level-up banner and sound per skill.
3. **Station panels** for the Bone Kiln (smelt + bone meal), Sawpit (carpentry) and cooking fire, reusing the
   `ForgePanel` recipe list filtered by `recipe_type`/station. Server errors are shown verbatim.
4. **Help**: counsel tips for the Acre on first entry, the first node, a full bag, the first level-up per
   skill, the first seed planted, and the first grown tree. A Codex **Professions** tab (skills, node tables
   generated from `gatheringRules.ts` so the numbers can't drift, and where to find each node). Settings key
   list entries. A README "Professions" section with a screenshot.

Do NOT edit sim, backend or layout files. Keep checks green. Commit on `cloud/professions-g4`; no PR.
Report: files, screenshots, the tips added, and test results.
