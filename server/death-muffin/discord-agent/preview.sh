#!/usr/bin/env bash
# Playable preview of a proposal: preview.sh <jobid>   (run by the RUNNER from the job's worktree, never by the AI).
# 1. Build the branch's OFFLINE EDITION (own in-browser store + token key, no live server involved) with base <previewUrl path>/<jobid>/
#    inside the same sandbox as check.sh (no network, home read-only, worktree writable, scratch tmpfs over node_modules/.vite).
#    The service worker / PWA manifest step is skipped on purpose, so a preview can never register a worker that touches /play/ or /offline/.
# 2. Outside the sandbox: put a "PREVIEW" banner into index.html, then rsync to <previewRoot>/<jobid>/ (--delete, hardlinking unchanged
#    files from the live offline edition to save disk). Refuses any jobid that is not 6 hex chars; never writes outside <previewRoot>/<jobid>.
# Env: DM_PREVIEW_ROOT (default /var/www/death-muffin/preview), DM_PREVIEW_BASE (url path, default /death-muffin/preview),
#      DM_PREVIEW_LINKDEST (default /var/www/death-muffin/offline), DM_PREVIEW_TITLE (banner text).
set -euo pipefail
JOB=${1:-}
[[ "$JOB" =~ ^[0-9a-f]{6}$ ]] || { echo "bad job id"; exit 2; }
ROOT=${DM_PREVIEW_ROOT:-/var/www/death-muffin/preview}
BASEPATH=${DM_PREVIEW_BASE:-/death-muffin/preview}; BASEPATH=${BASEPATH%/}
LINK=${DM_PREVIEW_LINKDEST:-/var/www/death-muffin/offline}
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || { echo "preview root $ROOT is missing"; exit 2; }
TOP=$(git rev-parse --show-toplevel)
NM=$(readlink -f "$TOP/node_modules")
OUT="$TOP/.dm-preview"
export TOP NM JOB BASEPATH
rm -rf "$OUT"
timeout 900 unshare -rnm bash -c '
  set -euo pipefail
  ip link set lo up
  ro() { [ -e "$1" ] && mount --bind "$1" "$1" && mount -o remount,bind,ro "$1" || true; }
  ro /home/ubuntu
  mount --bind "$TOP" "$TOP" && mount -o remount,bind,rw "$TOP"
  mkdir -p "$NM/.vite" 2>/dev/null || true
  mount -t tmpfs tmpfs "$NM/.vite"
  export HOME=$(mktemp -d /tmp/dmprev.XXXXXX)
  cd "$TOP"
  VITE_OFFLINE_BUILD=1 DEPLOY_BASE="$BASEPATH/$JOB/" VITE_WS_BASE= npx vite build --outDir .dm-preview --emptyOutDir > "$HOME/build.log" 2>&1 || { tail -15 "$HOME/build.log"; exit 1; }
' || { echo "preview build failed"; exit 1; }
[ -f "$OUT/index.html" ] || { echo "build produced no index.html"; exit 1; }
# banner (title is HTML-escaped; inserted at publish time, not in game source)
DM_OUT="$OUT/index.html" node - <<'JS'
const fs = require('fs'); const f = process.env.DM_OUT;
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const t = esc((process.env.DM_PREVIEW_TITLE || 'this change').slice(0, 120));
const bar = `<div style="position:fixed;left:50%;bottom:6px;transform:translateX(-50%);z-index:2147483647;background:#4c1d95;color:#fff;font:12px/1.4 system-ui,sans-serif;padding:4px 12px;border-radius:12px;opacity:.92;pointer-events:none;max-width:90vw;text-align:center">PREVIEW of ${t} · offline sandbox, nothing here saves to your real character</div>`;
// Previews have no service worker on purpose, so the offline edition's "Download for offline play" panel would only show an error.
const hide = '<style>.dm-offline-install{display:none!important}</style>';
let h = fs.readFileSync(f, 'utf8'); h = h.replace('</head>', () => hide + '</head>'); h = h.includes('</body>') ? h.replace('</body>', () => bar + '</body>') : h + bar; fs.writeFileSync(f, h);
JS
DEST="$ROOT/$JOB"
[ ! -L "$DEST" ] || { echo "refusing symlinked destination"; exit 2; }
mkdir -p "$DEST"
LD=(); [ -d "$LINK" ] && LD=(--link-dest="$LINK")
rsync -a --delete --chmod=D755,F644 "${LD[@]}" "$OUT/" "$DEST/"
echo "RESULT: ok $JOB"
