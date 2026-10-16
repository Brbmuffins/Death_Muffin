# Test backend (the rebuild's test server)

A second Death Muffin backend for the rebuild's test build (DECISIONS B38): same server code as live, its own database
(`death_muffin_test`, its own MySQL user `dm_test` that cannot see the live database), its own token signing key, so nothing played
on it can touch a live character.

| What | Where |
|---|---|
| Service | `death-muffin-auth-test` (unit file `death-muffin-auth-test.service` here), 127.0.0.1:5194 |
| Code | `~/death-muffin/backend-test/` (a copy of the installed live backend; `.env` is its own, chmod 600, never overwritten) |
| Public API | `https://muffindevelopment.com/death-muffin/test-api/` (nginx location, mirrored in `../nginx-locations.conf`) |
| Accounts | copies of the team's: Brbmuffins, Helix, Bogar, bogar1 |

- `setup.sh`: one time. Creates the database and its user, `.env` (the live one minus database, port and signing key) and the unit.
- `copy-team.sh [username ...]`: refills the test database from live (only reads live): the live schema, every catalog table, the
  team's accounts with their characters and what belongs to them. Logs and history stay out. Replaces whatever was played on the
  test server since the last copy. Run it when the team wants their latest live characters there.
- `coop/`: the test lobby and relay for the rebuild's 2-player co-op (units, nginx location, setup and sync scripts, the install steps that wait for the owner's OK): [coop/README.md](coop/README.md).
- `sync.sh [rev]`: copies the installed live backend's code over, applies pending migrations of `rev` (default `origin/main`) to the
  test database and restarts it. `deploy-release.sh` runs it after every live deploy (best effort), and the drift report flags a test
  backend that is down or on different code.
