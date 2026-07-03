# Web client deploy → https://playcrossworlds.com/play/

Two files, one command. Serves the game at `/play/` (your existing root site and
the Unity download page stay untouched).

## Run it on the VPS

1. Upload both files to the same folder on the box (SFTP / PuTTY `pscp`):
   - `deploy-web.sh`
   - `crossworlds-web-play.tar.gz`
2. `sudo bash deploy-web.sh`
3. Open `https://playcrossworlds.com/play/`
4. Undo: `sudo bash deploy-web.sh --rollback`

## What it wires up

- Static SPA at `/var/www/rod/play/` (old build backed up on redeploy).
- `location /play/` serves it; `location /authapi/` reverse-proxies the auth API
  to `127.0.0.1:3000` so the HTTPS page reaches it same-origin (no CORS, no mixed
  content). The nginx edit is backed up and auto-restored if `nginx -t` fails.
- For live 4-player co-op, also run `../realtime/deploy-realtime.sh` (adds the
  `/rt/socket.io` wss proxy). Without it the game still runs solo.

## Rebuilding this bundle (only if you change the client)

```
DEPLOY_BASE=/play/ VITE_API_BASE=/authapi \
  VITE_WS_BASE=https://playcrossworlds.com VITE_WS_PATH=/rt/socket.io \
  npm run build
tar -czf server/web-deploy/crossworlds-web-play.tar.gz -C dist .
```
