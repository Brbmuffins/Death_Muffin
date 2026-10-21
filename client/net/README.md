# The API rule (DECISIONS B38, B49)

Which server the client talks to (`client/net/`: `DmConfig`, `DmApi`, the offline mock). The front flow: [front/README.md](../front/README.md).

The client plays on the **live server** and **never reaches the test server** (since launch day, 2026-10-18). Where it may talk is set in
**one place**, `net/dm_config.gd`, and enforced twice:
- `DmConfig.API_BASE` is the live API (`https://muffindevelopment.com/death-muffin/api`), `SITE_BASE` the site's root (the launcher's manifest and the patch notes are under it),
  `LOBBY_URL` the live lobby and `RELAY_PORT` the live relay's (5193). A test run and an exported build all read these constants: there is no publish-time swap to miss.
- `DmHttpTransport.send` (the one door to the network) refuses any URL `DmConfig.allows_url` does not accept: under the site's root, never under a test-server path
  (`DmConfig.TEST_PATHS`: the test API, the test channel, the test lobby), nothing with a `/..` that a server would resolve elsewhere. It logs an error and answers like an unreachable server.
  `DmNextGame.start` refuses any api whose base url is not the live API or empty (the local mock). `DmNextParty` connects only to a lobby `DmConfig.allows_lobby_url` accepts (the live
  lobby, or one on this machine for a trial) and keeps a relay the lobby offers only when `DmConfig.allows_relay` does (port 5193, or this machine; never the test relay's 5196).
- A finished benchmark run is sent (`DmApi.post_benchmark`) through the same transport to the live API's benchmark history.
- `client/tests/front.gd` fails if any of it moves: the constants are the live server's, the allow-list refuses the test server's addresses and
  lookalikes, every request the flows made stayed on the live server, and a scan of every shipped file finds no address outside `net/dm_config.gd` and no test-server path anywhere.

Test builds (the launcher's Test build switch) keep the last one published to the test channel before launch day; a new test build needs endpoints of its own first (ROADMAP: the test lane for big changes), never a change to
`net/dm_config.gd`.
