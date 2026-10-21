# Test lobby and relay (2-player co-op of test builds)

A test build's co-op (DECISIONS B38, B40, B53; [client/next/party/CORE-NETWORK.md](../../../../client/next/party/CORE-NETWORK.md)) needs a lobby and a UDP relay of its own, next to the live ones and
next to the test backend ([../README.md](../README.md)): a test build never talks to the live API, lobby or relay, and the live ones never see its sessions. The game since launch day uses the live ones and never reaches these
(client/net/README.md).

| What | Where |
|---|---|
| Test lobby | `death-muffin-lobby-test` (unit here), 127.0.0.1:5195, the live lobby's code in `~/death-muffin/lobby-test/` |
| Test relay | `death-muffin-relay-test` (unit here), UDP 5196 (public), the live relay's code in `~/death-muffin/relay-test/` |
| Public lobby address | `wss://muffindevelopment.com/death-muffin/test-lobby/` (nginx location, `nginx-test-lobby.conf`); the game's `DmConfig.TEST_PATHS` lists it among the addresses it never reaches |
| Who may enter | accounts of the test backend only: the lobby verifies tokens with the test backend's `JWT_SECRET` (`ENV_FILE=~/death-muffin/backend-test/.env`), the relay's tickets are signed with it |
| Friends, invites, asks | the lobby reads friend lists from the test backend (`DM_LOBBY_BACKEND=http://127.0.0.1:5194`): the copies of the team's accounts and their friendships |

Ports 5195 and 5196 come from the range reserved for this project (5195-5199, `../../README.md`); nothing else uses them (`ss -ltnup`, 2026-10-16). Same code as live, no change to the live lobby or
relay: the lobby is `server/death-muffin/lobby` and the relay `server/death-muffin/relay` with the client's `client/net/relay/dm_udp_relay.gd`.
The game takes a relay the lobby offers only on port 5193 (or on the same machine) and refuses 5196 (`DmConfig.allows_relay`); a test build needs a config of its own.

## Files

- `death-muffin-lobby-test.service`, `death-muffin-relay-test.service`: the two units.
- `nginx-test-lobby.conf`: the location for the lobby (a WebSocket upgrade, like the live one's).
- `setup.sh`: one time: the folders under `~/death-muffin`, the units (enabled, **not started**) and the code. Needs the test backend first. Starts nothing, touches no nginx and no firewall.
- `sync.sh [rev] [--no-restart]`: puts the lobby's and the relay's code of a committed revision (default `origin/main`) on the test copies, `npm ci` when the lockfile changed, restarts both
  and checks `/health`. A restart ends the parties running on the test lobby.

## Install (done 2026-10-16 with Helix's OK; the steps, for a reinstall on another server)

1. `bash server/death-muffin/test-server/coop/setup.sh` (creates the folders, installs and enables the two units without starting them).
2. The relay's public address, which is the server's own and so is not in git: copy the live drop-in's address and give it the test port.
   `sudo mkdir -p /etc/systemd/system/death-muffin-lobby-test.service.d` and write `relay.conf` there:
   ```
   [Service]
   Environment=DM_RELAY_UDP=<the address in /etc/systemd/system/deathmuffin-lobby.service.d/relay.conf>:5196
   ```
   then `sudo systemctl daemon-reload`. Without it the lobby offers no relay and every session stays on the lobby's WebSocket (it works, with the TCP stalls the UDP lane exists to avoid).
3. The firewall: `sudo ufw allow 5196/udp comment 'Death Muffin TEST UDP co-op relay (death-muffin-relay-test)'`.
4. nginx: add `nginx-test-lobby.conf` to the `muffindevelopment` server block (next to `/death-muffin/lobby/`), mirror it in `../../nginx-locations.conf`, then `sudo nginx -t && sudo systemctl reload nginx`.
5. `sudo systemctl start death-muffin-relay-test death-muffin-lobby-test`, then:
   - `curl -s http://127.0.0.1:5195/health` answers `{"ok":true,...}` and `journalctl -u death-muffin-relay-test` shows `listening on udp *:5196`;
   - a test build hosts and joins a party (client/next/party/CORE-NETWORK.md: the trial commands) with two of the team's accounts.
6. Both units are in the service list of `server/death-muffin/ops/drift-report.sh`, so a down test lobby or relay is flagged (reinstall the ops jobs with `ops/install.sh` after changing it); an Uptime Kuma monitor is optional and, like every staging and test monitor, never linked to the live Discord notification.

To undo it: `sudo systemctl disable --now death-muffin-lobby-test death-muffin-relay-test`, remove the two units, the drop-in, the nginx block and the firewall rule.

## Trying it without installing anything

`bash client/tools/coop_local.sh` runs this same lobby and relay from the checkout on loopback ports with a throwaway key and prints the commands for a host and a guest (client/README.md).
`client/tests/coop.gd` does the same inside the test: a lobby and a relay started and stopped by the suite, two games, no network beyond this machine.

## Limits (unchanged from the live ones)

The relay allows 600 packets/s and 1 MiB/s per connection; the lobby 600 messages/s and 1 MiB/s, 200 sessions, 4 players a session. One guest in the Full Party fight costs the host's connection
about 28 KB/s and 82 packets/s (`client/tests/coop.gd` prints it); the host sends each guest its own copy, so three guests would cost about 85 KB/s and 250 packets/s, inside both limits.
