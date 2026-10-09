#!/usr/bin/env bash
# Tell players a new revision of main is live. Called by publish-godot-client.sh (every client release, manual or a Discord ship) and by
# deploy-release.sh (backend), always AFTER the release is live. Never fails the caller: every step reports and carries on.
#
#   announce-release.sh <rev>
#
# 1. release-notes.json (launcher news panel) and patch-notes.json (launcher "All patch notes", the site's patch-notes page, the in-game
#    notes) in $PUBLIC/play/. The title and items are the top PATCH_NOTES.json entry when that file changed since the last announced
#    release, otherwise the commit subjects since then.
# 2. A "Death Muffin update is live" notice in #deathmuffin (webhook URL outside the repo).
# 3. Player bug reports fixed in the range (commits "Bug report #<id>: ...") are marked 'released' (the reporter sees "Fixed — live now"),
#    with their own notice.
# The last announced revision is the `sha` in the live release-notes.json. A revision that is not newer than it (a rollback, or the
# same revision published twice) announces nothing.
# QUIET=1 (deploy-release.sh: backend deploys): when PATCH_NOTES.json did not change, keep the live notes' title and items (commit
# subjects of a backend fix are not player news) and post no release notice; bug reports are still released and announced.
# Test overrides: REPO PUBLIC RUNTIME HOOK_FILE REPORTS_CLI, DRY_RUN=1 (write the JSON to $PUBLIC/play without sudo, no Discord, no DB).
set -uo pipefail

REV="${1:-}"
[ -n "$REV" ] || { echo "usage: $0 <git-rev>" >&2; exit 2; }
REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
PUBLIC="${PUBLIC:-/var/www/death-muffin}"
RUNTIME="${RUNTIME:-/home/ubuntu/death-muffin}"
g() { git -C "$REPO" "$@"; }

SHA=$(g rev-parse -q --verify "$REV^{commit}") || { echo "release notes: unknown revision $REV" >&2; exit 0; }
SHORT=${SHA:0:12}
NOTES="$PUBLIC/play/release-notes.json"
PREV=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sha",""))' "$NOTES" 2>/dev/null || true)
PREV_FULL=""
[ -n "$PREV" ] && PREV_FULL=$(g rev-parse -q --verify "$PREV^{commit}" 2>/dev/null || true)
if [ -n "$PREV_FULL" ]; then
  [ "$PREV_FULL" = "$SHA" ] && { echo "release notes: $SHORT already announced"; exit 0; }
  g merge-base --is-ancestor "$PREV_FULL" "$SHA" || { echo "release notes: $SHORT is not newer than the announced ${PREV_FULL:0:12} (rollback?): nothing announced"; exit 0; }
  RANGE=("$PREV_FULL..$SHA")
  FRESH=0; g diff --quiet "$PREV_FULL" "$SHA" -- PATCH_NOTES.json || FRESH=1
else
  RANGE=(-n 12 "$SHA")
  FRESH=1
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
g show "$SHA:PATCH_NOTES.json" >"$TMP/PATCH_NOTES.json" 2>/dev/null || echo '[]' >"$TMP/PATCH_NOTES.json"
g log --no-merges --format='%s' "${RANGE[@]}" | grep -vE '^(Merge |WIP)' | head -12 >"$TMP/commits.txt"

# ---- 1. notes JSON ----
CARRY=0; [ -n "${QUIET:-}" ] && [ "$FRESH" = 0 ] && CARRY=1
python3 - "$SHA" "$FRESH" "$TMP" "$CARRY" "$NOTES" <<'PY' || { echo "release notes: could not build the notes" >&2; exit 0; }
import json, os, sys, datetime
sha, fresh, tmp, carry, live = sys.argv[1][:12], sys.argv[2] == "1", sys.argv[3], sys.argv[4] == "1", sys.argv[5]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
commits = [l.strip()[:150] for l in open(os.path.join(tmp, "commits.txt")) if l.strip()]
try:
    history = [e for e in json.load(open(os.path.join(tmp, "PATCH_NOTES.json"))) if e.get("items")]
except Exception:
    history = []
top = history[0] if (history and fresh) else None
notes = {"sha": sha, "date": now, "title": top["title"] if top else "", "items": top["items"] if top else commits, "commits": commits}
if carry:   # a quiet backend deploy: the player-facing notes stay what the last release said
    try:
        old = json.load(open(live))
        notes.update(title=old.get("title", ""), items=old.get("items", []), date=old.get("date", now))
    except Exception:
        pass
json.dump(notes, open(os.path.join(tmp, "release-notes.json"), "w"))
json.dump({"sha": sha, "date": now, "releases": history[:30]}, open(os.path.join(tmp, "patch-notes.json"), "w"))
PY
if [ -n "${DRY_RUN:-}" ]; then
  mkdir -p "$PUBLIC/play"; cp "$TMP/patch-notes.json" "$TMP/release-notes.json" "$PUBLIC/play/"
else
  sudo install -m 644 -o root -g root "$TMP/patch-notes.json" "$PUBLIC/play/patch-notes.json" \
    && sudo install -m 644 -o root -g root "$TMP/release-notes.json" "$PUBLIC/play/release-notes.json" \
    || { echo "release notes: could not write $PUBLIC/play" >&2; exit 0; }
fi
echo "release notes: $SHORT published ($( [ "$FRESH" = 1 ] && echo "PATCH_NOTES.json" || { [ "$CARRY" = 1 ] && echo "previous notes kept"; } || echo "commit subjects"))"

# ---- 2. Discord notice (the repo is public: the webhook URL lives outside it) ----
HOOK_FILE="${HOOK_FILE:-$RUNTIME/private/discord-deathmuffin-webhook.url}"
post() {   # post <json file> <label>: prints the outcome, never fails
  if [ -n "${DRY_RUN:-}" ]; then echo "Discord: $2 not posted (dry run)"; return 0; fi
  if [ ! -r "$HOOK_FILE" ]; then echo "Discord: $2 not posted (no webhook file)"; return 0; fi
  python3 - "$HOOK_FILE" "$1" <<'PY' && echo "Discord: $2 sent" || echo "Discord: $2 failed"
import sys, urllib.request
url, body = open(sys.argv[1]).read().strip(), open(sys.argv[2], "rb").read()
urllib.request.urlopen(urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "death-muffin-release"}), timeout=10)
PY
}
python3 - "$SHA" "${PREV_FULL:-}" "$TMP" <<'PY'
import json, os, sys
sha, prev, tmp = sys.argv[1], sys.argv[2], sys.argv[3]
n = json.load(open(os.path.join(tmp, "release-notes.json")))
body = "\n".join("• " + str(i)[:200] for i in n["items"]) or "• (no player-facing changes listed)"
if n["title"]:
    body = "**" + n["title"] + "**\n" + body
compare = f"https://github.com/Brbmuffins/Death_Muffin/compare/{prev[:12]}...{sha[:12]}" if prev else f"https://github.com/Brbmuffins/Death_Muffin/commit/{sha[:12]}"
embed = {"title": f"Death Muffin update {sha[:7]} is live", "url": "https://muffindevelopment.com/death-muffin/",
         "description": body[:3700] + f"\n\nThe launcher updates on its own. [What changed]({compare})", "color": 0x7C3AED}
json.dump({"username": "Death Muffin", "embeds": [embed], "allowed_mentions": {"parse": []}}, open(os.path.join(tmp, "notice.json"), "w"))
PY
if [ "$CARRY" = 1 ]; then echo "Discord: no release notice (quiet backend deploy, no new patch notes)"
elif [ -s "$TMP/notice.json" ]; then post "$TMP/notice.json" "release notice"; fi

# ---- 3. bug reports fixed by this release ----
FIXES=$(g log --no-merges --format='%s' "${RANGE[@]}" | grep -E '^Bug report #[0-9]+: ' || true)
[ -n "$FIXES" ] || exit 0
IDS=$(printf '%s\n' "$FIXES" | sed -E 's/^Bug report #([0-9]+):.*/\1/' | sort -un | paste -sd, -)
if [ -n "${DRY_RUN:-}" ]; then echo "bug reports (dry run): would release $IDS"; exit 0; fi
CLI="${REPORTS_CLI:-$TMP/reports-cli.cjs}"
[ -n "${REPORTS_CLI:-}" ] || g show "$SHA:server/death-muffin/bug-agent/reports-cli.cjs" >"$CLI" 2>/dev/null
NEWLY=$(node "$CLI" release "$IDS" 2>/dev/null || echo '[]')
echo "bug reports released: $NEWLY"
[ "$NEWLY" != "[]" ] || exit 0
printf '%s\n' "$FIXES" | python3 - "$SHA" "$NEWLY" "$TMP" <<'PY'
import json, os, sys
sha, newly, tmp = sys.argv[1], {r["id"] for r in json.loads(sys.argv[2])}, sys.argv[3]
lines = []
for l in sys.stdin:
    head, _, text = l.strip().partition(": ")
    rid = int(head.split("#")[1])
    if rid in newly:
        lines.append(f"• **#{rid}** {text[:150]}")
embed = {"title": "\U0001F41E Player-reported bugs fixed — live now", "url": "https://muffindevelopment.com/death-muffin/",
         "description": "\n".join(lines)[:3700] + f"\n\nUpdate {sha[:7]}. Thanks for the reports! Send more from Settings → Report a bug.", "color": 0x16A34A}
json.dump({"username": "Death Muffin", "embeds": [embed], "allowed_mentions": {"parse": []}}, open(os.path.join(tmp, "fixes.json"), "w"))
PY
[ -s "$TMP/fixes.json" ] && post "$TMP/fixes.json" "bug-fix notice"
exit 0
