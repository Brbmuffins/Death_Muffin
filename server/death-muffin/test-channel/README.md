# Test build channel

The launcher's Test build channel (DECISIONS B38): builds for the team, installed by the launcher's hidden Test build switch next to
the normal game, never seen by players. Served at `https://muffindevelopment.com/death-muffin/client-test/` (`/var/www/death-muffin/client-test/`,
same manifest format as the live `client/`).

- `publish-test-channel.sh <rev>`: runs `publish-godot-client.sh` with the test folder and URL, its own work folder
  (`~/death-muffin/deploy-test/`, so the live asset-pack cache is never touched), no announcement, and a PREPARE step.
- `prepare-live-project.sh`: the PREPARE step for builds of the live project (`godot/`): Forward+, its own user:// folder
  ("Death Muffin (test build)"), the test backend (`/death-muffin/test-api/`, ../test-server/README.md) and this channel's manifest.
  It edits only the publish's scratch worktree. The first test build (ROADMAP Gate A) is today's game built this way.
- The channel is always open online (`online.enabled` true in its manifest): only the team's accounts exist on the test backend.
- Co-op on the test build needs a test lobby and relay; they come with the test build phase (ROADMAP).
- `publish-bake-kit.sh <rev> [scene ...]`: the lighting bake kit for the team's bake helper, served at
  `https://muffindevelopment.com/death-muffin/bake-kit/` (`/var/www/death-muffin/bake-kit/`, the 2 newest kits and `latest.json`). How the bake
  works and comes back: [client/addons/dm_bake/README.md](../../../client/addons/dm_bake/README.md).
