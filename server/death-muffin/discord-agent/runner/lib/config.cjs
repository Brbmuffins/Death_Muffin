'use strict';
const fs = require('fs');
const DEFAULTS = {
  channelId: '',
  guildId: '',
  ownerIds: [],                 // the owner: always a requester and approver for every tier; pinged (FYI) when anyone else ships or rolls back
  // Per-project access. Everyone not listed (in requesters or any approver list) is ignored. Ids are Discord user ids (digits only;
  // placeholders such as "HELIX_DISCORD_ID" are dropped on load, so they are inert until filled in).
  // Approver tiers are decided by the diff's FILES (see tiers), never by the model. A user in approvers.sensitive is a full approver:
  // may approve everything, roll back anything, no daily cap, may switch models. A user only in approvers.casual is limited.
  projects: { deathmuffin: { requesters: [], approvers: { casual: [], gameplay: [], sensitive: [] } } },
  names: {},                    // id -> display name used in proposals ("Helix")
  threadReplyRequiresMention: false,
  defaultModel: 'sonnet',
  allowedModels: ['sonnet', 'opus', 'haiku'],
  maxConcurrentJobs: 1,
  turnTimeoutMin: 45,
  maxTurnsPerJob: 40,           // per round (a round = one branch, from the first message to ship/discard)
  maxTurnsPerThread: 120,       // hard cap over all rounds of one thread
  // Full approvers (owner, Helix) playtest and ask in bursts, so they get roomier limits than everyone else.
  rateLimit: { perUserPerHour: 12, perUserNewJobsPerDay: 8, fullApproverPerHour: 60, fullApproverNewJobsPerDay: 30 },
  casualShipsPerDay: 5,         // per LIMITED approver (may approve casual but not sensitive); full approvers and the owner are exempt
  allowMigrations: true,
  numericTolerancePct: 25,
  // Which game the agent works on. web = the three.js game on master (check.sh, preview.sh, shot.sh, PROMPT.md, `tiers`, deploy-release.sh,
  // mobile step). godot = the Godot 4 client (set baseBranch to godot-port too): check-godot.sh, preview-godot.sh (offline .exe
  // zip), PROMPT-godot.md, `godotTiers`, publish-godot-client.sh, no screenshots, no mobile step. baseBranch is where worktrees are cut from and
  // where ships merge and push; it is passed to git as a ref, so it is validated in loadConfig.
  baseBranch: 'master',
  mode: 'web',
  runnerPort: 4321,
  repo: '/home/ubuntu/vps-handoffs/DeathMuffin/game',
  worktreeRoot: '/home/ubuntu/vps-handoffs/DeathMuffin/wt',
  stateDir: '/home/ubuntu/death-muffin/discord-agent/state',
  toolsDir: '/home/ubuntu/death-muffin/discord-agent',
  deployDir: '/home/ubuntu/death-muffin/deploy',
  deployScript: 'server/death-muffin/deploy-release.sh',
  clientManifest: '/var/www/death-muffin/client/manifest.json',   // godot mode: the live client's manifest; ship.sh reads `rev` from it to write ROLLBACK.sh before publishing
  // Playable preview of each proposal (offline edition build, see preview.sh). previewCmd (tests) replaces preview.sh.
  previewRoot: '/var/www/death-muffin/preview',
  previewUrl: 'https://muffindevelopment.com/death-muffin/preview/',
  // After a PC ship goes live, ship.sh best-effort merges master into this branch and publishes phones + the offline edition (empty = off).
  mobileBranch: 'mobile',
  mobileDeployScript: 'server/death-muffin/deploy-mobile.sh',
  githubRepo: 'Brbmuffins/Death_Muffin',
  secretFile: '/home/ubuntu/death-muffin/discord-agent/secret',
  // Tier rules are deterministic path rules, never the model's opinion. First match wins inside a tier; a diff is as strict as its strictest file.
  // sensitive > gameplay > casual. Files matching no rule: under src/ = gameplay, anything else = sensitive.
  tiers: {
    sensitive: [
      'server/**', '**/migrations/**', '.github/**', 'package.json', 'package-lock.json', '**/package.json', '**/package-lock.json',
      '**/*.sh', '**/deploy*', 'CLAUDE.md', '.claude/**', '**/.env*', 'vite.config.*', 'vitest.config.*', 'tsconfig*.json', 'launcher/**', 'tools/**',
      'src/net/**', 'src/gameplay/progression*', 'src/**/auth*', 'src/**/session*', 'src/**/authority*', '.gitignore',
    ],
    casual: [
      { glob: '**/*.css', mode: 'any' },
      { glob: 'docs/**', mode: 'any' }, { glob: '*.md', mode: 'any' }, { glob: 'PATCH_NOTES.json', mode: 'any' },
      { glob: 'src/content/codex.ts', mode: 'text', keys: '*' },
      { glob: 'src/ui/Onboarding.ts', mode: 'text', keys: '*' },
      { glob: 'src/content/items.ts', mode: 'text', keys: ['name', 'desc', 'description', 'flavor', 'flavour', 'lore'] },
      { glob: 'src/content/abilities.ts', mode: 'text', keys: ['name', 'desc', 'description', 'tooltip'] },
      { glob: 'src/content/enemies.ts', mode: 'text', keys: ['name', 'desc', 'description'] },
      { glob: 'src/content/disciplines.ts', mode: 'text', keys: ['name', 'desc', 'description', 'tagline'] },
      { glob: 'src/content/areas.ts', mode: 'text', keys: ['name', 'desc', 'description'] },
      { glob: 'src/content/audioMap.ts', mode: 'any' }, { glob: 'src/audio/map*.ts', mode: 'any' },
      { glob: 'src/content/enemies.ts', mode: 'numeric' }, { glob: 'src/content/abilities.ts', mode: 'numeric' },
      { glob: 'src/content/upgrades.ts', mode: 'numeric' }, { glob: 'src/content/items.ts', mode: 'numeric' },
    ],
    gameplay: ['src/**'],
  },
  // Tier rules for mode 'godot' (replace `tiers`; same semantics). The Godot client carries its own offline backend, saves, login and net code,
  // so those are sensitive here exactly like server/auth are on the web side. First check is sensitive; unmatched paths (the frozen web src/, root
  // files) are sensitive too. gameplay = everything else under godot/. A changed project.godot can add autoloads / main scene, so it is sensitive.
  godotTiers: {
    sensitive: [
      'server/**', 'launcher/**', 'tools/**', '.github/**', '**/*.sh', '**/deploy*', 'CLAUDE.md', '.claude/**', '**/.env*', '.gitignore',
      'godot/project.godot', 'godot/export_presets.cfg', 'godot/net/**', 'godot/front/**', 'godot/backend/**', 'godot/addons/**',
      'godot/**/*auth*', 'godot/**/*session*', 'godot/**/*online*', 'godot/**/*save*', 'godot/**/*mock_backend*',
      // where the real tree keeps the same concerns outside those folders (checked against origin/godot-port 2026-10-07): the offline edition
      // (game/dm_offline.gd), server progress saves (game/dm_progress_sync.gd), co-op / host authority (game/dm_game_coop.gd), the boot script
      // that picks offline/online (main/main.gd), plus anything named for login, accounts, tokens, relay/lobby/realtime, and native code.
      'godot/**/*offline*', 'godot/**/*progress_sync*', 'godot/**/*coop*', 'godot/**/*login*', 'godot/**/*account*', 'godot/**/*token*',
      'godot/**/*credential*', 'godot/**/*relay*', 'godot/**/*lobby*', 'godot/**/*realtime*', 'godot/main/main.gd',
      'godot/**/*.gdextension', 'godot/**/*.dll', 'godot/**/*.so', 'godot/**/*.dylib', 'godot/**/*.exe', 'godot/**/*.pck',
      // progression, unlocks, kills, gold sinks and other economy rules mirror the server's authority (web tiers: src/gameplay/progression*); checked
      // against origin/godot-port 2026-10-07 (rules/progression/, data/progression, gameplay_{kill*,goldSink,vault,labor,legion,milestones}Rules json, game/dm_game_rewards.gd ...)
      'godot/rules/progression/**', 'godot/data/progression/**', 'godot/**/*progression*', 'godot/**/*authority*', 'godot/**/*ledger*', 'godot/**/*economy*', 'godot/**/*spend*',
      'godot/**/*kill*', 'godot/**/*gold_sink*', 'godot/**/*goldSink*', 'godot/**/*vault_rules*', 'godot/**/*vaultRules*', 'godot/**/*labor_rules*', 'godot/**/*laborRules*',
      'godot/**/*legionRules*', 'godot/**/*milestone*', 'godot/**/*reward*', 'godot/**/*tradeGoods*', 'godot/**/*unlock*', 'godot/**/*seal*',
      'godot/tests/rules-progression/**',
      'godot/tests/net/**', 'godot/tests/relay/**', 'godot/tests/offline/**', 'godot/tests/realtime/**', 'godot/tests/online_local/**', 'godot/tests/front/**',
    ],
    casual: [
      { glob: 'docs/**', mode: 'any' }, { glob: '*.md', mode: 'any' }, { glob: 'godot/**/*.md', mode: 'any' }, { glob: 'PATCH_NOTES.json', mode: 'any' },
    ],
    gameplay: ['godot/**'],
  },
  // Paths the agent may never touch (proposal refused, not even for the owner to approve): secrets, and the agent's own rules/deploy scripts.
  // They are still "sensitive" if the owner removes them from this list and makes the change by hand.
  forbiddenPaths: ['server/death-muffin/discord-agent/**', 'server/death-muffin/bug-agent/**', '**/deploy*.sh', '**/.env*', '.claude/**', 'godot/export_presets.cfg'],
};
function merge(a, b) {
  if (Array.isArray(a) || typeof a !== 'object' || a === null) return b === undefined ? a : b;
  const out = { ...a };
  for (const k of Object.keys(b || {})) out[k] = k in a ? merge(a[k], b[k]) : b[k];
  return out;
}
function loadConfig(file) {
  let user = {};
  if (file && fs.existsSync(file)) user = JSON.parse(fs.readFileSync(file, 'utf8'));
  const c = merge(DEFAULTS, user);
  c.maxConcurrentJobs = Math.max(1, Math.min(2, Number(c.maxConcurrentJobs) || 1));
  const ids = (a) => [...new Set((a || []).map(String).filter((x) => /^\d{15,25}$/.test(x)))];
  c.ownerIds = ids(c.ownerIds);
  const pr = (c.projects && c.projects.deathmuffin) || {};
  const ap = pr.approvers || {};
  c.project = { requesters: ids([...c.ownerIds, ...(pr.requesters || [])]), approvers: {} };
  for (const t of ['casual', 'gameplay', 'sensitive']) c.project.approvers[t] = ids([...c.ownerIds, ...(ap[t] || [])]);
  // baseBranch becomes `origin/<baseBranch>` and a push refspec in git calls and shell scripts: allow only plain ref characters, and refuse the
  // shapes git would read as an option or a revision range (leading '-', '..', '//', a trailing '/' or '.lock').
  c.baseBranch = String(c.baseBranch);
  if (!/^[A-Za-z0-9._\/-]+$/.test(c.baseBranch) || /^-|\.\.|\/\/|\/$|\.lock$/.test(c.baseBranch)) throw new Error(`Invalid baseBranch: ${JSON.stringify(c.baseBranch)}`);
  if (!['web', 'godot'].includes(c.mode)) throw new Error(`Invalid mode: ${JSON.stringify(c.mode)}; must be 'web' or 'godot'`);
  // Everything downstream (classifier, ship gate) reads cfg.tiers, so the mode picks the rule set here once.
  if (c.mode === 'godot') c.tiers = c.godotTiers;
  return c;
}
module.exports = { loadConfig, DEFAULTS };
