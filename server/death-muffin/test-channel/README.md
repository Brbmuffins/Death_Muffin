# Test build channel

The launcher's Test build channel (DECISIONS B38): builds for the team, installed by the launcher's hidden Test build switch next to
the normal game, never seen by players. Served at `https://muffindevelopment.com/death-muffin/client-test/` (`/var/www/death-muffin/client-test/`,
same manifest format as the live `client/`).

- `publish-test-channel.sh <rev>`: publishes the rebuilt client (`client/`, DECISIONS B41) through `publish-godot-client.sh` with
  `PROJECT=client`, the test folder and URL, its own work folder (`~/death-muffin/deploy-test/`, so the live asset-pack cache is never touched),
  no announcement, and `prepare-rebuild.sh`. The rebuild talks to the test backend by its own config (`client/net/dm_config.gd`, client/README.md
  "The test server"). Today's game on Forward+ was the first test build (ROADMAP Gate A, passed 2026-10-16); the channel carries the rebuild since.
- `prepare-rebuild.sh`: the PREPARE step: in the publish's scratch worktree, builds the combat core (Windows for the export, Linux for the
  headless import and bake), syncs the licensed flipbook sheets, imports and bakes the crowd's models (`client/assets/crowd/baked`, not in git).
- The channel is always open online (`online.enabled` true in its manifest): only the team's accounts exist on the test backend.
- Co-op on the test build needs a test lobby and relay; they come with the test build phase (ROADMAP).
- `publish-bake-kit.sh <rev> [scene ...]`: the lighting bake kit for the team's bake helper, served at
  `https://muffindevelopment.com/death-muffin/bake-kit/` (`/var/www/death-muffin/bake-kit/`, the 2 newest kits and `latest.json`). How the bake
  works and comes back: [client/addons/dm_bake/README.md](../../../client/addons/dm_bake/README.md).
