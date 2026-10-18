# UDP co-op relay

`deathmuffin-relay`: co-op packets over ENet (UDP 5193) instead of the lobby WebSocket, so a lost movement packet no longer stalls the
packets behind it (DECISIONS B31). Same star as the lobby relay: a client reaches only its host. The code is
`client/net/relay/dm_udp_relay.gd` (the relay) and `dm_udp_lane.gd` (a member's side, used by `DmRelayPeer`); this folder only runs it as
a headless Godot process: `godot --headless --path <this folder> --script relay_main.gd`.

- **Who may use it:** the lobby hands each member a ticket in `created` / `joined` (`relay: {addr, port, ticket}`, HMAC-SHA256 with the
  shared JWT secret, valid 10 min to attach). The lobby stays the source of truth for membership: kicks and leaves work as before.
- **Fallback:** a member whose lane cannot connect, is refused, or drops keeps (or goes back to) the WebSocket. A client only uses the lane
  once the host is on it too.
- **Deploy:** `deploy-lobby.sh` installs these files and `dm_udp_relay.gd` into `/home/ubuntu/death-muffin/relay` and restarts the unit when
  they changed. The unit file `deathmuffin-relay.service` is installed by hand (`sudo cp` + `systemctl enable --now`), like the lobby's.
- **Turning it on:** the lobby offers the lane only when `DM_RELAY_UDP=<public address>:5193` is set; it lives in a systemd drop-in
  (`/etc/systemd/system/deathmuffin-lobby.service.d/relay.conf`), not in git, because it is the server's own address (players' games
  connect to it directly; the website stays behind Cloudflare). The firewall allows 5193/udp. Unset it to turn the lane off.
- **Log:** `journalctl -u deathmuffin-relay` (attach/detach lines and an hourly stats line).
