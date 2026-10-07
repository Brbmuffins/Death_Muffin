#!/usr/bin/env bash
# Open or close online play for the launcher, the Godot client and the lobby, no release needed. Clients re-read the manifest about once a minute.
#
#   set-online.sh on    [message]   everyone may play online            (online.enabled=true,  staff=false)
#   set-online.sh staff [message]   staff/GM accounts only (D10)        (online.enabled=false, staff=true)
#   set-online.sh off   [message]   nobody; message is shown as the lock (online.enabled=false, staff=false)
#
# Old launchers/clients that only read `enabled` keep seeing it locked in staff mode. Edits only the "online" block of $OUT_DIR/manifest.json,
# atomically. Run publish-godot-client.sh first if no manifest exists. OUT_DIR overrides the directory (tests use a temp one).
set -euo pipefail
MODE="${1:-}"
case "$MODE" in on|off|staff) ;; *) echo "usage: $0 on|off|staff [message]" >&2; exit 2;; esac
OUT_DIR="${OUT_DIR:-/var/www/death-muffin/client}"
F="$OUT_DIR/manifest.json"
[ -f "$F" ] || { echo "no $F: publish a client first" >&2; exit 1; }
python3 - "$F" "$MODE" "${2-__keep__}" <<'PY'
import json, os, sys
path, mode, msg = sys.argv[1:4]
m = json.load(open(path))
o = m.get("online") if isinstance(m.get("online"), dict) else {}
o["enabled"] = (mode == "on")
o["staff"] = (mode == "staff")
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
print("online: enabled=%s staff=%s message=%r" % (o["enabled"], o["staff"], o["message"]))
PY
