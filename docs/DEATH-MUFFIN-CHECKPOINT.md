# Death Muffin — complete version 1.0.0

User-approved smooth-combat baseline, 2026-09-27. Git tag: `death-muffin-v1.0.0`. Gameplay commit: `fca634d057105e995e17e44d7363812b6cb08458`; the tag adds this checkpoint documentation without changing gameplay.

Live: https://muffindevelopment.com/death-muffin/. This is the reference version to preserve while planning new spells. It includes the supplied login/site design, isolated accounts/progress/co-op, leaderboard, accepted click movement/aiming, stable animations, quick spell flow, stationary auto combat and free class switching with preserved progress.

Verified before checkpoint: 122 client tests, TypeScript, both server suites and production build. Public browser checks passed login/existing character, signup/world rendering/co-op, Auto toggle, class switching, progress, leaderboard and redirects. The user approved the feel of this version.

## Private complete backup

Backup root: `/home/ubuntu/death-muffin/backups/`. Find the completed directory beginning `death-muffin-v1.0.0-`; its `MANIFEST.json`, `SHA256SUMS` and `RESTORE.md` identify exact commit, timestamp and contents. The backup directory is private (0700); files are private (0600), since API configuration and the database contain credentials and account data. Never publish these archives or upload them to GitHub.

Includes:

- `source.tar.gz`: tracked source/assets at the checkpoint commit, dependency lockfiles and handoff docs.
- `repository.bundle`: Git history and annotated checkpoint tag.
- `live-site.tar.gz`: exact served login/site/leaderboard and compiled game, including assets.
- `runtime.tar.gz`: deployed API/realtime source, private `.env` and dependency lockfiles, private deployment scripts and supplied-site source. Dependencies can be recreated with `npm ci`.
- `hosting.tar.gz`: both Death Muffin service units and relevant nginx configuration snapshots.
- `database.sql.gz`: consistent single-transaction snapshot of all 34 Death Muffin InnoDB tables, including account/progress/inventory/catalog data, with triggers/routines/events if present.
- SHA-256 integrity manifest and restoration instructions.

Backups remain on this VPS. The Git tag/source history is also on GitHub; the private database/runtime archives are not an off-VPS disaster-recovery copy.

## Restore boundaries

Default rollback is code-only: restore the served game and backend version while retaining current player progress. A database restore explicitly rewinds accounts and progress to the snapshot time; back up current data first and use the private restoration recipe. Stop only Death Muffin services when restoring its API/database. Preserve the shared nginx hosts' unrelated routes. This checkpoint does not back up unrelated games, Workbench data, system-wide packages or shared TLS private keys; new-host recovery must provision MySQL/nginx/Node and HTTPS separately.

Read [the live VPS handoff](DEATH-MUFFIN-HANDOFF.md) for exact paths, service boundaries and deployment commands. New spell work belongs after this tag; do not move or overwrite the version tag.
