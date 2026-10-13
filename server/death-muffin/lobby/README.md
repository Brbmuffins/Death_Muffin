# Death Muffin lobby + relay

Listen-server sessions (decision D3 in `DECISIONS.md`): a player hosts from their own PC, this service lists sessions and forwards opaque
game packets host <-> clients over WebSocket, so it works behind any NAT with no port forwarding. Max 4 players per session (D2, host included).
It never parses game data and holds no state beyond the live sessions.

- Port: **5192** (reserved range 5192-5199; 5190 = auth backend). Binds 127.0.0.1; nginx terminates TLS (`nginx-lobby.conf`).
- Env: `DM_LOBBY_JWT_SECRET` (the auth backend's `JWT_SECRET`) or `ENV_FILE` pointing at the backend `.env` (only `JWT_SECRET` is read, never logged);
  `DM_LOBBY_PORT` (5192), `DM_LOBBY_HOST` (127.0.0.1), `DM_LOBBY_IDLE_MS` (900000), `DM_LOBBY_QUIET=1`.
- Run: `npm ci --omit=dev && node src/index.js`. Tests: `npm install && npm test`. Health: `GET /health`. `deathmuffin-lobby.service` and `nginx-lobby.conf` are installed by hand (nothing in this repo installs them; the live nginx locations are in `../nginx-locations.conf`); the unit expects the code in `/home/ubuntu/death-muffin/lobby` with `npm ci --omit=dev` run there.

## Auth
First frame on every socket must be `{"t":"auth","token":"<JWT>"}` within 5 s (the token never goes in the URL). Verified like the backend: HS256,
`jsonwebtoken.verify`, requires integer `accountId`, uses `username`. If the token carries an auth-server `sid`, the newer login of an account replaces the
older; without `sid` a new connection for the same account replaces the old one. The DB-backed session check is
not repeated here (no DB access), so a revoked-but-unexpired token still works until it expires (24 h).
**Staff-only online (D10, optional):** with `DM_LOBBY_MANIFEST` set (path of the client `manifest.json`, e.g. `/var/www/death-muffin/client/manifest.json`; optional
`DM_LOBBY_BACKEND`, default `http://127.0.0.1:5190`), each auth follows the manifest's `online` block (`src/gate.js`): `enabled:true` admits everyone; `enabled:false, staff:true`
admits only accounts for which the backend's `GET /api/me` (Bearer token forwarded, 3 s timeout) says `staff:true`; anything else, an unreadable manifest or a backend that does
not answer refuses (error `locked`, close 4403, message from the manifest). The manifest is re-read at most every 2 s, so `set-online.sh` takes effect without a restart; sockets
already connected are not re-checked. Unset = no gate.
Failure closes with 4401; replaced = 4402; locked (staff-only mode) = 4403; rate limit = 4429; oversize text = 1009.

## Text frames (JSON control)
Client -> server: `list`, `create {name(1-32), area, private?, code?}`, `join {id, code?}` or `join {code}` (private sessions are not listed: the code alone finds one; wrong codes are counted per connection, 10 per 10 min, then `rate_limit`), `leave`, host only: `set_open {open}`, `kick {id}`.
Server -> client: `ready {accountId, username, maxPlayers}`, `sessions {sessions:[{id,name,host,area,players,max,private,open}]}` (public + open only),
`created {session, peerId:1, code?}` (private sessions get a 6-digit code unless one was supplied), `joined {session, peerId}`, `left`, `session_updated`,
host gets `peer_joined {id,name,accountId}` / `peer_left {id, reason: left|disconnected|kicked}`, everyone else gets
`session_closed {reason: host_left|idle|kicked|shutdown}` (the socket stays open, back in the lobby), `error {code,msg,req}`.
Error codes: `bad_request in_session not_in_session not_found bad_code full closed not_host busy rate_limit auth` (+ Friends: `not_friend already_in`).
Peer ids: host = 1, clients 2, 3, ... assigned in join order and never reused within a session. One session per connection.

## Friends (DECISIONS B18): presence, invites, asks to join
Friend lists come from the auth backend: `GET /api/friends` with the player's OWN token (the one the socket authenticated with; `src/friends.js`),
at auth and on `friends_changed`, at most 20 reloads per connection per minute. Only with `DM_LOBBY_BACKEND` set (the service sets it); tests use
`DM_LOBBY_FRIENDS_FILE` (`{"<accountId>": [ids]}`); neither = no presence (`ready.presence: false`). A friend is **mutual**: both lists name the
other. Presence goes only to connected mutual friends. A list that cannot be read keeps the last one.
Client -> server: `presence {class, level, area}` (bad values become null; unchanged = not sent on), `friends_changed {accountId}` (we changed a
friendship: both lists reload and the other side gets `friends_changed`), `invite {accountId}` (host only, an online mutual friend: they may join
this session for 5 min, also when it is Closed or not accepting), `ask {accountId}` (an online mutual friend; goes to their session's host, or to
them when solo; one per friend per 30 s; not while in a session), `answer {accountId, accept}` (to an ask in the last 5 min; accepting needs us to
host: the asker gets an invite with `auto: true`), `set_private {private}` (host: Closed = not listed, invite or code only; gets a code if it had none).
Server -> client: `friends {list: [presence]}` (online mutual friends, after each list load), `presence {accountId, p}` (p = null: went offline or
no longer a friend), `friends_changed`, `invited {from, fromId, session, auto}`, `invite_sent {accountId, username}`, `join_request {accountId,
username, via?}` (via = the friend in our party they asked), `ask_sent {accountId, username}`, `ask_declined {username}`.
presence = `{accountId, username, class, level, area, session: {id, private, open, players, max, host, isHost} | null}`, pushed on every change
(presence message, create / join / leave / kick / close, Open / Closed, disconnect). Error codes added: `not_friend already_in`.

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
