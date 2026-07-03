#!/usr/bin/env bash
# =============================================================================
# Crossworlds web client — deploy to https://playcrossworlds.com/play/
# Run on the VPS from the folder that also holds crossworlds-web-play.tar.gz:
#   sudo bash deploy-web.sh
# Roll back:
#   sudo bash deploy-web.sh --rollback
#
# What it does:
#   - Extracts the static build to /var/www/rod/play/  (existing /play backed up)
#   - Adds two location blocks to the existing 443 vhost (backed up first;
#     auto-restored if `nginx -t` fails):
#       /play/      -> serves the SPA
#       /authapi/   -> reverse-proxies the auth API to 127.0.0.1:3000 (so the
#                      HTTPS page can reach it same-origin: no CORS, no mixed
#                      content). The auth server is NOT modified or restarted.
#   - Does NOT touch the root site, the Unity download page, rod-auth, the
#     dashboard, the database, or frozen ports.
# =============================================================================
set -euo pipefail

WEBROOT=/var/www/rod
PLAYDIR="$WEBROOT/play"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="$SCRIPT_DIR/crossworlds-web-play.tar.gz"

if [[ "${1:-}" == "--rollback" ]]; then
  echo "[rollback] removing $PLAYDIR ..."
  rm -rf "$PLAYDIR"
  echo "[rollback] restore the nginx vhost from its .bak.* file to drop the /play + /authapi blocks:"
  echo "   ls -t /etc/nginx/**/*.bak.* 2>/dev/null | head"
  echo "   then: nginx -t && systemctl reload nginx"
  exit 0
fi

if [[ "$(id -u)" != "0" ]]; then echo "Run with sudo."; exit 1; fi
if [[ ! -f "$TARBALL" ]]; then echo "Missing $TARBALL next to this script."; exit 1; fi

echo "== 1/3  Publishing static build to $PLAYDIR =="
if [[ -d "$PLAYDIR" ]]; then
  BK="$PLAYDIR.bak.$(date +%s)"; mv "$PLAYDIR" "$BK"; echo "  backed up old build -> $BK"
fi
mkdir -p "$PLAYDIR"
tar -xzf "$TARBALL" -C "$PLAYDIR"
chown -R www-data:www-data "$PLAYDIR" 2>/dev/null || true
echo "  extracted $(find "$PLAYDIR" -type f | wc -l) files"

echo "== 2/3  Nginx (/play static + /authapi proxy) =="
VHOST="$(grep -rlE 'server_name[^;]*playcrossworlds' /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null \
  | xargs -r grep -lE 'listen[[:space:]].*443' 2>/dev/null | sort -u | head -1 || true)"

read -r -d '' BLOCK <<'CWEOF_NGINX' || true
    location /play/ {
        root /var/www/rod;
        try_files $uri $uri/ /play/index.html;
    }
    location /authapi/ {
        proxy_pass http://127.0.0.1:3000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
CWEOF_NGINX

if [[ -z "$VHOST" ]]; then
  echo "  [skip] Could not find the 443 vhost. Add this inside its server{ } block, then: nginx -t && systemctl reload nginx"
  echo "-----"; printf '%s\n' "$BLOCK"; echo "-----"
elif grep -q 'location /play/' "$VHOST"; then
  echo "  [ok] /play block already present — static files updated, nginx unchanged."
else
  BAK="$VHOST.bak.$(date +%s)"; cp "$VHOST" "$BAK"; echo "  backed up $VHOST -> $BAK"
  awk -v ins="$BLOCK" '{print} /listen[[:space:]].*443/ && !done {print ""; print ins; done=1}' "$VHOST" > "$VHOST.tmp"
  mv "$VHOST.tmp" "$VHOST"
  if nginx -t; then
    systemctl reload nginx; echo "  [ok] nginx reloaded."
  else
    cp "$BAK" "$VHOST"; echo "  [FAIL] nginx -t rejected the edit — restored from backup. Site untouched."; exit 1
  fi
fi

echo "== 3/3  Verify =="
echo "  Open:  https://playcrossworlds.com/play/"
echo "  API :  curl -s https://playcrossworlds.com/authapi/api/health   # {\"status\":\"ok\",...}"
echo "  (For live co-op, also run deploy-realtime.sh so /rt/socket.io is proxied.)"
echo "== DONE =="
