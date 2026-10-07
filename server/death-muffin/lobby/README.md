# Death Muffin lobby + relay

Listen-server sessions (decision D3 in `godot/REBUILD.md`): a player hosts from their own PC, this service lists sessions and forwards opaque
game packets host <-> clients over WebSocket, so it works behind any NAT with no port forwarding. Max 4 players per session (D2, host included).
It never parses game data and holds no state beyond the live sessions.

- Port: **5192** (reserved range 5192-5199; 5190 = auth backend, 5191 = realtime). Binds 127.0.0.1; nginx terminates TLS (`nginx-lobby.conf`).
- Env: `DM_LOBBY_JWT_SECRET` (the auth backend's `JWT_SECRET`) or `ENV_FILE` pointing at the backend `.env` (only `JWT_SECRET` is read, never logged);
  `DM_LOBBY_PORT` (5192), `DM_LOBBY_HOST` (127.0.0.1), `DM_LOBBY_IDLE_MS` (900000), `DM_LOBBY_QUIET=1`.
- Run: `npm ci --omit=dev && node src/index.js`. Tests: `npm install && npm test`. Health: `GET /health`. Files `deathmuffin-lobby.service` and
  `nginx-lobby.conf` are for later deployment and are not installed by anything here.

## Auth
First frame on every socket must be `{"t":"auth","token":"<JWT>"}` within 5 s (the token never goes in the URL). Verified like the backend: HS256,
`jsonwebtoken.verify`, requires integer `accountId`, uses `username`. If the token carries an auth-server `sid`, the newer login of an account replaces the
older (same rule as `server/realtime`); without `sid` a new connection for the same account replaces the old one. The DB-backed session check is
not repeated here (no DB access), so a revoked-but-unexpired token still works until it expires (24 h).
**Staff-only online (D10, optional):** with `DM_LOBBY_MANIFEST` set (path of the client `manifest.json`, e.g. `/var/www/death-muffin/client/manifest.json`; optional
`DM_LOBBY_BACKEND`, default `http://127.0.0.1:5190`), each auth follows the manifest's `online` block (`src/gate.js`): `enabled:true` admits everyone; `enabled:false, staff:true`
admits only accounts for which the backend's `GET /api/me` (Bearer token forwarded, 3 s timeout) says `staff:true`; anything else, an unreadable manifest or a backend that does
not answer refuses (error `locked`, close 4403, message from the manifest). The manifest is re-read at most every 2 s, so `set-online.sh` takes effect without a restart; sockets
already connected are not re-checked. Unset = no gate (the old behaviour).
Failure closes with 4401; replaced = 4402; locked (staff-only mode) = 4403; rate limit = 4429; oversize text = 1009.

## Text frames (JSON control)
Client -> server: `list`, `create {name(1-32), area, private?, code?}`, `join {id, code?}`, `leave`, host only: `set_open {open}`, `kick {id}`.
Server -> client: `ready {accountId, username, maxPlayers}`, `sessions {sessions:[{id,name,host,area,players,max,private,open}]}` (public + open only),
`created {session, peerId:1, code?}` (private sessions get a 6-digit code unless one was supplied), `joined {session, peerId}`, `left`, `session_updated`,
host gets `peer_joined {id,name,accountId}` / `peer_left {id, reason: left|disconnected|kicked}`, everyone else gets
`session_closed {reason: host_left|idle|kicked|shutdown}` (the socket stays open, back in the lobby), `error {code,msg,req}`.
Error codes: `bad_request in_session not_in_session not_found bad_code full closed not_host busy rate_limit auth`.
Peer ids: host = 1, clients 2, 3, ... assigned in join order and never reused within a session. One session per connection.

## Binary frames (game packets), 11-byte header + payload
```
off size  field
0   u8    kind = 1
1   u8    transfer mode (Godot TransferMode: 0 unreliable, 1 unreliable ordered, 2 reliable); carried, not interpreted
2   u8    channel; carried, not interpreted
3   u32le source peer id   (the relay OVERWRITES it with the sender's true id: no spoofing)
7   u32le target peer id   (0 = every client; host may address any client; clients may only address 1 (or 0), anything else is dropped)
11  ...   payload (opaque, <= 65536 bytes)
```
Delivery is host <-> client only; client-to-client traffic is the host's job (Godot's SceneMultiplayer server relay).

## Lifecycle and limits
Host disconnect/leave closes the session for everyone (`host_left`); a client disconnect is announced to the host (`peer_left`); sessions with no traffic
or control messages for 15 min expire (`idle`). Per connection token buckets: 600 msg/s (burst 1200) and 1 MiB/s (burst 2 MiB), exceeding closes with
4429; max 64 KiB packet, 2 KiB text; a recipient with > 4 MiB queued is dropped as a slow consumer; ws ping every 20 s, dead sockets terminated; max 200 sessions.
