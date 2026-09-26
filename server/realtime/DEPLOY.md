# Phase 3 VPS Deploy — rod-realtime

Status: **one-shot script ready.** This machine can't SSH to the VPS
(`Permission denied (publickey,password)`), so run it yourself on the box.

## 2026-09-26 — protocol v2 (necromancer world)

The service now speaks the **world** protocol the redesigned client needs; the
old `room:join` / `arena:event` protocol is gone (the old Hub/Arena/Boss
client scenes were removed at the same time, so deploy client + service together).

| Event | Direction | Rules |
|---|---|---|
| `world:join {instance?, characterId, classIndex, x, z, facing}` → ack | client → server | No `instance` = matched into any public world with space (≤4), else a new one. An invite code joins/creates a private world. One socket per account per world. |
| `player:move {x, z, facing, moving, hpFrac}` | client → room | ≤30/s, bounds-checked (|x|,|z| ≤ 400) |
| `world:snapshot` | **host only** → room | ≤15/s, ≤96 KB; latest kept for host migration + late joiners |
| `world:events [..]` | **host only** → room | ≤60/s, ≤64 KB, ≤400 events |
| `world:intent {t: hit\|miasma\|exhume\|litany\|summonBoss\|recallThralls}` | client → **host only** | validated + clamped, stamped with the real sender id, ≤40/s |
| `room:host {hostId, snapshot}` | server → room | on host leave; the new host seeds its sim |
| `chat:send` / `chat:message` | as before | ≤3/s |

Tests: `node --test server/realtime/server.test.js`. After editing `server.js`,
run `node tools/embed-realtime.mjs` so `deploy-realtime.sh` embeds the new copy
(it checks the heredoc markers; the embedded file is byte-identical).

Local dev: `server/realtime/.env` from `.env.example` (DEV_TRUST_TOKENS=1 also
accepts the client's offline dev tokens), then start **crossworlds-realtime**
from `.claude/launch.json` and open `http://localhost:5188/?offline&coop` in
two tabs with different offline accounts.

## Easiest path — the self-contained script

`deploy-realtime.sh` embeds server.js + package.json + the systemd unit + the
nginx block (all byte-verified) and does the whole deploy with safety guards.

1. Get it onto the VPS — upload `server/realtime/deploy-realtime.sh` (SFTP/PuTTY
   `pscp`), or paste its contents into a new file via `nano deploy-realtime.sh`.
2. Run it:  `sudo bash deploy-realtime.sh`
3. It self-verifies (loopback health, socket.io handshake) and prints next steps.
4. Undo anytime:  `sudo bash deploy-realtime.sh --rollback`

The nginx edit is backed up first and **auto-restored if `nginx -t` fails**, so a
bad edit can't leave the live site broken. The service half touches only new
files. The manual command reference below does the same steps by hand.

---


## Routing decision: Nginx reverse proxy (wss), NOT a raw public port

The web client is served over HTTPS. A browser on an HTTPS page **cannot** open a
plain `ws://…:5000` socket — it's blocked as mixed content. So the realtime
service binds **loopback only** (`127.0.0.1:5000`, no new public firewall port)
and the existing Nginx reverse-proxies it over the site's existing SSL:

    Browser  ──wss://playcrossworlds.com/rt/socket.io/──▶  Nginx :443  ──▶  127.0.0.1:5000

Frozen ports (3000/4000/7777/3001) are untouched; 5000 is loopback-internal only.

## What lands on the server

| Local file | VPS destination | Existing file? |
|---|---|---|
| `server/realtime/server.js` | `/opt/rod-realtime/server.js` | new |
| `server/realtime/package.json` | `/opt/rod-realtime/package.json` | new |
| `server/realtime/rod-realtime.service` | `/etc/systemd/system/rod-realtime.service` | new |
| `server/realtime/nginx-realtime.conf` (one `location` block) | pasted into the existing 443 vhost | **EDIT — back up first** |

**Not** deployed: `.env` (local dev only). Production config is in the systemd
unit; JWT secret is read in place from `/opt/rod-auth/.env` via `ENV_FILE`.

The only existing file touched is the Nginx vhost. Everything else is new.

## Deploy commands (run only after SSH works)

```bash
# 1) service files (new dir, new files — nothing overwritten)
ssh ubuntu@playcrossworlds.com "mkdir -p /opt/rod-realtime"
scp server/realtime/server.js server/realtime/package.json ubuntu@playcrossworlds.com:/opt/rod-realtime/
ssh ubuntu@playcrossworlds.com "cd /opt/rod-realtime && npm install --omit=dev"
scp server/realtime/rod-realtime.service ubuntu@playcrossworlds.com:/tmp/
ssh ubuntu@playcrossworlds.com "sudo mv /tmp/rod-realtime.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now rod-realtime"

# 2) Nginx: BACK UP the vhost, then add the location block and reload
#    (find the vhost with:  ls -la /etc/nginx/sites-enabled/ )
ssh ubuntu@playcrossworlds.com "sudo cp /etc/nginx/sites-available/<vhost> /etc/nginx/sites-available/<vhost>.bak.\$(date +%s)"
#    -> hand-insert the location block from nginx-realtime.conf into the 443 server{} block
ssh ubuntu@playcrossworlds.com "sudo nginx -t && sudo systemctl reload nginx"
```

## Verify (in order, immediately after)

```bash
ssh ubuntu@playcrossworlds.com "sudo systemctl status rod-realtime --no-pager"
ssh ubuntu@playcrossworlds.com "sudo journalctl -u rod-realtime -n 20 --no-pager"
ssh ubuntu@playcrossworlds.com "curl -s http://127.0.0.1:5000/health"   # {"status":"ok",...}
curl -s https://playcrossworlds.com/rt/socket.io/?EIO=4&transport=polling  # socket.io handshake, not 404
curl -s http://playcrossworlds.com:3000/api/health                          # auth server still healthy
```

## Client production build

```bash
VITE_WS_BASE=https://playcrossworlds.com VITE_WS_PATH=/rt/socket.io npm run build
```
(These are already the defaults baked into `rod-realtime.service` and
`nginx-realtime.conf`; keep the three values in sync if you change the path.)

## Rollback

```bash
# service
ssh ubuntu@playcrossworlds.com "sudo systemctl disable --now rod-realtime && sudo rm /etc/systemd/system/rod-realtime.service && sudo systemctl daemon-reload && sudo rm -rf /opt/rod-realtime"
# nginx (restore the backup you made)
ssh ubuntu@playcrossworlds.com "sudo cp /etc/nginx/sites-available/<vhost>.bak.<ts> /etc/nginx/sites-available/<vhost> && sudo nginx -t && sudo systemctl reload nginx"
```

## Unblock SSH (what I need from you)

Any one of:
- Add this machine's public key to `~ubuntu/.ssh/authorized_keys` on the VPS, **or**
- Tell me the key file to use and confirm it's authorized (I'll use `ssh -i`), **or**
- Run the deploy yourself from a shell that already has access (copy-paste the blocks above).

I can't do interactive password SSH from this non-interactive session.
