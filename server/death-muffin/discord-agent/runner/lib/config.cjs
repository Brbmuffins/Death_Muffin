'use strict';
const fs = require('fs');
const DEFAULTS = {
  channelId: '',
  // In-game bug reports (owner 2026-10-14): each new report gets its own thread here (#in-game-reports) with the game log attached, so the devs see
  // what is reported; the agent only works on one when someone @-mentions it in that thread. Empty = off.
  bugChannelId: '',
  bugPollMin: 2,                // how often the runner looks for new reports
  bugThreadsPerHour: 10,        // flood cap: reports over it wait (still 'new') for the next hour
  archiveReportAfterMin: 2880,  // a report thread nobody picked up is archived after 48 h quiet (owner 2026-10-14)
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
  turnTimeoutMin: 60,
  publishAutoRetryMin: 10,     // godot: after ship.sh's own 3 publish tries fail, the runner retries once more by itself after this long
  publishRetrySleeps: null,    // tests only: PUBLISH_RETRY_SLEEPS for ship.sh (default "30 90")
  maxTurnsPerJob: 40,           // per round (a round = one branch, from the first message to ship/discard)
  maxTurnsPerThread: 120,       // hard cap over all rounds of one thread
  // Full approvers (owner, Helix) playtest and ask in bursts, so they get roomier limits than everyone else.
  rateLimit: { perUserPerHour: 12, perUserNewJobsPerDay: 8, fullApproverPerHour: 60, fullApproverNewJobsPerDay: 30 },
  casualShipsPerDay: 5,         // per LIMITED approver (may approve casual but not sensitive); full approvers and the owner are exempt
  allowMigrations: true,
  numericTolerancePct: 25,
  // Which game the agent works on. web = the three.js game on master (check.sh, preview.sh, shot.sh, PROMPT.md, `tiers`, deploy-release.sh,
  // mobile step). godot = the Godot 4 client (set baseBranch to godot-next too): check-godot.sh, preview-godot.sh (offline .exe
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
  // Team PC pictures and short videos (godot mode): with a team PC online the agent writes a shot plan instead of rendering, and the team PC renders it
  // after the proposal on Low and Ultra, before and after; it also records the agent's clips (teamShots: false = off for both).
  // teamApi: the backend the runner reaches /internal/team on ('' = off); teamResultsDir: where the backend keeps the uploaded pictures and videos; teamBuildCmd and
  // teamLabelCmd (tests) replace preview-godot.sh --team and label-shot.py; teamPollMs: how often a job is checked.
  teamShots: true,
  teamApi: 'http://127.0.0.1:5190',
  teamResultsDir: '/home/ubuntu/death-muffin/team-results',
  // After a PC ship goes live, ship.sh best-effort merges master into this branch and publishes phones + the offline edition (empty = off).
  mobileBranch: 'mobile',
  mobileDeployScript: 'server/death-muffin/deploy-mobile.sh',
  // In-game bug reports (report threads, !report) through the DB helper installed beside the runner (reportsCmd replaces it in tests).
  reportsCli: '/home/ubuntu/death-muffin/discord-agent/reports-cli.cjs',
  githubRepo: 'Brbmuffins/Death_Muffin',
  secretFile: '/home/ubuntu/death-muffin/discord-agent/secret',
  // The agent may WebSearch freely but WebFetch only these documentation hosts (exact host names): a fetch elsewhere could carry data out
  // in its URL. Owner 2026-10-08: Helix asked for the agent to look up documentation online.
  // webAnyHost (owner 2026-10-08, "access to the web for research"): WebFetch on any host instead. The workspace holds no secrets (file tools are
  // scoped to the job's worktree, which is a plain checkout), pages are data never instructions, and nothing ships without a human ✅.
  webAnyHost: false,
  webDocDomains: ['docs.godotengine.org', 'godotengine.org', 'forum.godotengine.org', 'github.com', 'raw.githubusercontent.com',
    'docs.github.com', 'developer.mozilla.org', 'threejs.org', 'nodejs.org', 'www.typescriptlang.org', 'vitest.dev', 'vite.dev'],
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
  // Tier rules for mode 'godot' (replace `tiers`; same semantics): the game is client/ (DECISIONS B49, B57). It carries its own offline backend, saves,
  // login and net code, so those are sensitive here exactly like server/auth are on the web side. First check is sensitive; unmatched paths (the
  // frozen web src/, root files, native/) are sensitive too. gameplay = everything else under client/. A changed project.godot can add autoloads /
  // main scene, so it is sensitive; so are the files the players' 500 MB asset pack is fingerprinted by (tools/godot/assets-fp.sh), whose change
  // sends every player that download again.
  godotTiers: {
    sensitive: [
      'server/**', 'launcher/**', 'tools/**', '.github/**', '**/*.sh', '**/deploy*', 'CLAUDE.md', '.claude/**', '**/.env*', '.gitignore',
      'native/**', 'client/project.godot', 'client/export_presets.cfg', 'client/net/**', 'client/front/**', 'client/session/**', 'client/addons/**',
      'client/main/**', 'client/bin/**', 'client/core/**', 'client/backend/**',
      'client/**/*auth*', 'client/**/*session*', 'client/**/*online*', 'client/**/*save*', 'client/**/*mock_backend*',
      // the same concerns outside those folders: the offline edition, server progress saves, co-op / host authority, plus anything named for login,
      // accounts, tokens, relay/lobby/realtime, and native libraries.
      'client/**/*offline*', 'client/**/*progress_sync*', 'client/**/*coop*', 'client/**/*login*', 'client/**/*account*', 'client/**/*token*',
      'client/**/*credential*', 'client/**/*relay*', 'client/**/*lobby*', 'client/**/*realtime*',
      'client/**/*.gdextension', 'client/**/*.dll', 'client/**/*.so', 'client/**/*.dylib', 'client/**/*.exe', 'client/**/*.pck',
      // progression, unlocks, kills, gold sinks and other economy rules mirror the server's authority (web tiers: src/gameplay/progression*)
      'client/rules/progression/**', 'client/data/progression/**', 'client/**/*progression*', 'client/**/*authority*', 'client/**/*ledger*', 'client/**/*economy*', 'client/**/*spend*',
      'client/**/*kill*', 'client/**/*gold_sink*', 'client/**/*goldSink*', 'client/**/*vault_rules*', 'client/**/*vaultRules*', 'client/**/*labor_rules*', 'client/**/*laborRules*',
      'client/**/*legionRules*', 'client/**/*milestone*', 'client/**/*reward*', 'client/**/*tradeGoods*', 'client/**/*unlock*', 'client/**/*seal*',
      // the tests that guard those systems
      'client/tests/rules-progression/**', 'client/tests/backend/**', 'client/tests/relay/**', 'client/tests/realtime/**', 'client/tests/next_front/**',
      'client/tests/front.gd', 'client/tests/value.gd',
      // the asset pack's fingerprint (tools/godot/assets-fp.sh) beyond client/assets/**, which every asset change already touches
      'client/crowd/**', 'client/tools/bake_crowd*', 'client/game/view_models.json', 'client/game/dm_creature*', 'client/game/dm_gear_props.gd',
      'client/world/dm_models.gd', 'client/world/dm_animator.gd',
    ],
    casual: [
      { glob: 'docs/**', mode: 'any' }, { glob: '*.md', mode: 'any' }, { glob: 'client/**/*.md', mode: 'any' },
      { glob: 'PATCH_NOTES.json', mode: 'any' },
    ],
    gameplay: ['client/**'],
  },
  // Paths the agent may never touch (proposal refused, not even for the owner to approve): secrets, and the agent's own rules/deploy scripts.
  // They are still "sensitive" if the owner removes them from this list and makes the change by hand.
  forbiddenPaths: ['server/death-muffin/discord-agent/**', '**/deploy*.sh', '**/.env*', '.claude/**', 'client/export_presets.cfg'],
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
  c.maxConcurrentJobs = Math.max(1, Math.min(3, Number(c.maxConcurrentJobs) || 1));   // 3 = owner + two requesters at once (2026-10-08)
  const ids = (a) => [...new Set((a || []).map(String).filter((x) => /^\d{15,25}$/.test(x)))];
  c.ownerIds = ids(c.ownerIds);
  c.soundUsers = ids([...c.ownerIds, ...(c.soundUsers || [])]);   // may generate ElevenLabs sounds, no budget (lib/sound.cjs); the owner always may
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
