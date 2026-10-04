#!/usr/bin/env bash
# Open or close online play in the launcher, no launcher update needed. The launcher re-reads the manifest about once a minute.
#
#   set-online.sh on  [message]    unlock the Play Online button
#   set-online.sh off [message]    lock it again; message (default: keep the current one) is shown under the button
#
# Edits only the "online" block of $OUT_DIR/manifest.json, atomically. Run publish-godot-client.sh first if no manifest exists.
set -euo pipefail
MODE="${1:-}"
case "$MODE" in on|off) ;; *) echo "usage: $0 on|off [message]" >&2; exit 2;; esac
OUT_DIR="${OUT_DIR:-/var/www/death-muffin/client}"
F="$OUT_DIR/manifest.json"
[ -f "$F" ] || { echo "no $F: publish a client first" >&2; exit 1; }
python3 - "$F" "$MODE" "${2-__keep__}" <<'PY'
import json, os, sys
path, mode, msg = sys.argv[1:4]
m = json.load(open(path))
o = m.get("online") if isinstance(m.get("online"), dict) else {}
o["enabled"] = (mode == "on")
if msg != "__keep__":
    o["message"] = msg
elif not isinstance(o.get("message"), str) or not o["message"]:
    o["message"] = "Online opens soon"
m["online"] = o
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o644)
os.replace(tmp, path)
print("online: enabled=%s message=%r" % (o["enabled"], o["message"]))
PY
