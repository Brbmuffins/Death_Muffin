#!/usr/bin/env bash
# Death Muffin weekly drift report. READ-ONLY: compares the VPS with origin/main and prints what differs.
# Exit 0 = clean, 3 = drift found.   drift-report.sh [--discord] [--always] [--json]
# Env: REPO (checkout, default /home/ubuntu/vps-handoffs/DeathMuffin/game), DM_HOME (~/death-muffin), WWW (/var/www/death-muffin)
set -u
REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
DM="${DM_HOME:-/home/ubuntu/death-muffin}"
WWW="${WWW:-/var/www/death-muffin}"
WEBHOOK_FILE="${WEBHOOK_FILE:-$DM/private/discord-deathmuffin-webhook.url}"
REV=origin/main
DISCORD=0; ALWAYS=0; JSON=0
for a in "$@"; do case "$a" in
  --discord) DISCORD=1;; --always) ALWAYS=1;; --json) JSON=1;;
  -h|--help) sed -n '2,4p' "$0"; exit 0;;
  *) echo "unknown option $a" >&2; exit 2;; esac; done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REC="$TMP/rec.tsv"; : > "$REC"
SEC=""
section() { SEC="$1"; printf '%s\tsec\t\n' "$1" >> "$REC"; }
drift() { printf '%s\tdrift\t%s\n' "$SEC" "$1" >> "$REC"; }
note()  { printf '%s\tnote\t%s\n' "$SEC" "$1" >> "$REC"; }
info()  { printf '%s\tinfo\t%s\n' "$SEC" "$1" >> "$REC"; }
g() { git -C "$REPO" "$@"; }

git -C "$REPO" fetch -q 2>/dev/null || info "git fetch failed; comparing with the last fetched origin/main"
now=$(date +%s)

# Strip // and /* */ comments (string aware) and blank lines.
cat > "$TMP/strip.py" <<'PY'
import sys
s = sys.stdin.read(); out = []; i = 0; n = len(s); q = None
while i < n:
    c = s[i]
    if q:
        out.append(c)
        if c == '\\' and i + 1 < n: out.append(s[i+1]); i += 1
        elif c == q: q = None
    elif c in '\'"`': q = c; out.append(c)
    elif s.startswith('//', i):
        while i < n and s[i] != '\n': i += 1
        continue
    elif s.startswith('/*', i):
        j = s.find('*/', i + 2); i = n if j < 0 else j + 2
        continue
    else: out.append(c)
    i += 1
sys.stdout.write('\n'.join(l.rstrip() for l in ''.join(out).split('\n') if l.strip()) + '\n')
PY
# compare_code <repo path> <live file> <label>: real drift vs comment-only drift
COMMENT_ONLY=0; NCMP=0
compare_code() {
  local rp="$1" lf="$2" label="$3"; NCMP=$((NCMP+1))
  if ! g cat-file -e "$REV:$rp" 2>/dev/null; then drift "$label: not in origin/main ($rp)"; return; fi
  if [ ! -f "$lf" ]; then drift "$label: missing live ($lf)"; return; fi
  g show "$REV:$rp" > "$TMP/a"
  cmp -s "$TMP/a" "$lf" && return
  python3 "$TMP/strip.py" < "$TMP/a" > "$TMP/a.s"; python3 "$TMP/strip.py" < "$lf" > "$TMP/b.s"
  if cmp -s "$TMP/a.s" "$TMP/b.s"; then COMMENT_ONLY=$((COMMENT_ONLY+1)); else drift "$label: live code differs from origin/main"; fi
}
# compare_exact <repo path> <installed file> <label>
compare_exact() {
  local rp="$1" lf="$2" label="$3"; NCMP=$((NCMP+1))
  if [ ! -f "$lf" ]; then drift "$label: missing ($lf)"; return; fi
  g show "$REV:$rp" 2>/dev/null | cmp -s - "$lf" || drift "$label: differs from origin/main"
}

# 1. Agents
section "1. Installed agent copies"
SRC=server/death-muffin/discord-agent
LIST="$(g ls-tree -r --name-only "$REV" -- "$SRC/runner" | sed "s#^$SRC/##")
ship.sh rollback.sh sandbox-lib.sh check.sh check-godot.sh regen.sh shot.sh shoot.cjs shot-godot.sh label-shot.py art-run.sh build-art.sh preview.sh preview-godot.sh agit wait-for-ship.sh PROMPT.md PROMPT-godot.md config.example.json death-muffin-discord-agent.service"
for f in $(echo $LIST); do compare_exact "$SRC/$f" "$DM/discord-agent/$f" "discord-agent/$f"; done
for f in common gemini tripo; do compare_exact "tools/ai/$f.mjs" "$DM/discord-agent/art-tools/tools/ai/$f.mjs" "discord-agent/art-tools/tools/ai/$f.mjs"; done
BSRC=server/death-muffin/bug-agent
for f in run-bug-agent.sh reports-cli.cjs PROMPT.md; do compare_exact "$BSRC/$f" "$DM/bug-agent/$f" "bug-agent/$f"; done
compare_exact "$SRC/check-godot.sh" "$DM/bug-agent/check.sh" "bug-agent/check.sh (= discord-agent/check-godot.sh)"
for f in sandbox-lib.sh agit; do compare_exact "$SRC/$f" "$DM/bug-agent/$f" "bug-agent/$f (= discord-agent/$f)"; done
compare_exact "$SRC/death-muffin-discord-agent.service" /etc/systemd/system/death-muffin-discord-agent.service "systemd death-muffin-discord-agent.service"
compare_exact server/death-muffin/ops/git-pre-push.sh "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push" "git pre-push hook"
for u in death-muffin-bug-agent.service death-muffin-bug-agent.timer; do compare_exact "$BSRC/$u" "/etc/systemd/system/$u" "systemd $u"; done

info "$NCMP file(s)/unit(s) compared"; NCMP=0
# 2. Backend + lobby
section "2. Live backend and lobby vs origin/main"
B=server/death-muffin/backend
compare_code "$B/server.js" "$DM/backend/server.js" "backend/server.js"
for rp in $(g ls-tree --name-only "$REV" -- "$B/" | grep -E '\.cjs$' | grep -v '\.test\.cjs$'); do
  compare_code "$rp" "$DM/backend/$(basename "$rp")" "backend/$(basename "$rp")"; done
for rp in $(g ls-tree --name-only "$REV" -- "$B/gathering/" | grep -E '\.cjs$' | grep -v '\.test\.cjs$'); do
  compare_code "$rp" "$DM/backend/gathering/$(basename "$rp")" "backend/gathering/$(basename "$rp")"; done
for f in necro-rules.cjs necro-progress-routes.cjs mysql-store.cjs; do
  compare_code "server/vps-handoff/necro-progress/$f" "$DM/backend/necro-progress/$f" "backend/necro-progress/$f"; done
for rp in $(g ls-tree --name-only "$REV" -- server/death-muffin/lobby/src/ | grep -E '\.js$'); do
  compare_code "$rp" "$DM/lobby/src/$(basename "$rp")" "lobby/src/$(basename "$rp")"; done
info "$NCMP file(s) compared"
[ "$COMMENT_ONLY" -gt 0 ] && note "$COMMENT_ONLY file(s) differ only in comments/blank lines (normal after doc edits)"

# 3. Client
section "3. Live client"
MAN="$WWW/client/manifest.json"
if [ ! -f "$MAN" ]; then drift "manifest.json missing ($MAN)"; else
  CREV="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("rev",""))' "$MAN" 2>/dev/null)"
  if [ -z "$CREV" ]; then drift "manifest.json has no rev"
  elif ! g cat-file -e "$CREV^{commit}" 2>/dev/null; then drift "published rev $CREV is not a known commit"
  else
    # Only files that go into the exported client count (export_presets.cfg excludes tests/, shots/, build/; docs don't ship).
    N="$(g rev-list --count "$CREV..$REV" -- godot/ ':(exclude)godot/tests/**' ':(exclude)godot/*.md' ':(exclude)godot/**/*.md' ':(exclude)godot/shots/**' ':(exclude)godot/build/**')"
    info "published rev $CREV"
    [ "$N" -gt 0 ] && drift "$N commit(s) changing the shipped client (godot/, not tests or docs) merged after the published rev $CREV, not published"
  fi
fi

# 4. Git leftovers
section "4. Git leftovers"
age_days() { echo $(( (now - $1) / 86400 )); }
while read -r _ ref; do b="${ref#refs/heads/}"; [ "$b" = main ] && continue
  d="$(g log -1 --format=%ct "origin/$b" 2>/dev/null || echo "$now")"; a=$(age_days "$d")
  case "$b" in
    discord/*) info "agent job (remote): $b, ${a}d old"; [ "$a" -gt 7 ] && drift "agent job older than 7 days: origin/$b (${a}d)";;
    bugfix/reports-*) [ "$a" -gt 3 ] && drift "unreviewed bug-fix branch: origin/$b (${a}d)" || info "bug-fix branch: origin/$b (${a}d)";;
    *) drift "remote branch other than main: $b";;
  esac
done < <(g ls-remote --heads origin)
while read -r b; do [ "$b" = main ] && continue
  d="$(g log -1 --format=%ct "$b")"; a=$(age_days "$d")
  case "$b" in
    discord/*) info "agent job (local): $b, ${a}d old"; [ "$a" -gt 7 ] && drift "agent job older than 7 days: local $b (${a}d)";;
    bugfix/reports-*) [ "$a" -gt 3 ] && drift "unreviewed bug-fix branch: local $b (${a}d)" || info "bug-fix branch: local $b (${a}d)";;
    *) drift "local branch other than main: $b";;
  esac
done < <(g for-each-ref --format='%(refname:short)' refs/heads)
MAINWT="$(g rev-parse --show-toplevel)"
wt=""; br=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) wt="${line#worktree }"; br="";;
    "branch "*) br="${line#branch refs/heads/}";;
    "") ;;
  esac
  if [ -n "$wt" ] && { [ -z "$line" ] || [ "${line%% *}" = branch ] || [ "${line%% *}" = detached ]; }; then
    if [ "$wt" != "$MAINWT" ]; then
      case "$br" in
        discord/*) a=$(age_days "$(g log -1 --format=%ct "$br")"); info "agent job worktree: $wt ($br, ${a}d)"; [ "$a" -gt 7 ] && drift "agent job worktree older than 7 days: $wt (${a}d)";;
        *) drift "extra worktree: $wt (${br:-detached})";;
      esac
    fi; wt=""
  fi
done < <(g worktree list --porcelain; echo)
for d in "$(dirname "$REPO")"/wt/*/; do [ -d "$d" ] || continue
  case "$(g worktree list --porcelain)" in *"worktree ${d%/}"*) ;; *) drift "directory in wt/ that is not a registered worktree: ${d%/}";; esac; done

# 5. Uncommitted
section "5. Main checkout"
ST="$(g status --porcelain)"
if [ -n "$ST" ]; then drift "uncommitted changes in $REPO ($(echo "$ST" | wc -l) path(s)): $(echo "$ST" | head -3 | tr '\n' ';')"; fi

# 6. Docroot
section "6. Public docroot $WWW"
EXP=" client play preview $(g ls-tree --name-only "$REV" -- server/death-muffin/site/ | sed 's#.*/##' | tr '\n' ' ')"
for e in "$WWW"/* "$WWW"/.[!.]*; do [ -e "$e" ] || continue; n="$(basename "$e")"
  case "$EXP" in *" $n "*) ;; *) drift "unexpected top-level entry: $n";; esac; done
if [ -d "$WWW/play" ]; then for e in "$WWW/play"/* "$WWW/play"/.[!.]*; do [ -e "$e" ] || continue; n="$(basename "$e")"
  case "$n" in index.html|patch-notes.json|release-notes.json) ;; *) drift "unexpected file in play/: $n";; esac; done; fi
while IFS= read -r f; do drift "secret-ish file in docroot: ${f#$WWW/}"; done < <(find "$WWW" \( -iname '*.env' -o -iname '.env*' -o -iname '*.sql' -o -iname '*.zip' -o -iname '*.bak' -o \( -iname '*.txt' \( -iname '*key*' -o -iname '*token*' \) \) \) 2>/dev/null)

# 7. Services
section "7. Services"
for s in death-muffin-auth deathmuffin-lobby death-muffin-discord-agent; do
  st="$(systemctl is-active $s 2>&1)"; [ "$st" = active ] || drift "$s is $st"; done
st="$(systemctl is-enabled death-muffin-bug-agent.timer 2>&1)"; [ "$st" = enabled ] || drift "death-muffin-bug-agent.timer is $st"
H="$(curl -fsS -m 5 http://127.0.0.1:5190/health 2>&1)" || drift "auth /health failed: ${H:0:100}"
[ -n "${H:-}" ] && info "auth /health: ${H:0:100}"

# 8. Disk
section "8. Disk"
U="$(df --output=pcent / | tail -1 | tr -dc 0-9)"
[ "$U" -gt 85 ] && drift "/ is ${U}% full" || info "/ usage ${U}%"
info "wt/ size: $(du -sh "$(dirname "$REPO")/wt" 2>/dev/null | cut -f1)"
info "deploy/ size: $(du -sh "$DM/deploy" 2>/dev/null | cut -f1)"
DKB=$(du -sk "$DM/deploy" 2>/dev/null | cut -f1)
if [ "${DKB:-0}" -gt $((2 * 1024 * 1024)) ]; then
  # deploy-release.sh removes its candidate export after a good deploy; anything else here is a leftover (owner deletes, this script never does)
  BREAK=$(cd "$DM/deploy" && ls -1 | sed -E 's/-[0-9a-f]{7,}.*//; s/[0-9]{8}T[0-9]{6}Z.*//; s/\.(png|log|json|cjs|sh)$/ (file)/' | sort | uniq -c | sort -rn | head -6 | awk '{c=$1; $1=""; printf "%s%s x%s", (NR>1?", ":""), substr($0,2), c}')
  drift "deploy/ holds $(du -sh "$DM/deploy" | cut -f1) (over 2 GB): $BREAK"
fi
OLD=$(find "$DM/deploy" -maxdepth 1 -name 'backup-pre-release-*' -mtime +30 2>/dev/null | wc -l)
[ "$OLD" -gt 0 ] && note "$OLD backup-pre-release-* folder(s) in deploy/ older than 30 days; consider pruning (this script never prunes)"

# 9. DB backups
section "9. DB backups"
BD="$DM/backups/db"   # backup-db.sh writes daily/ (weekly/, monthly/ are hard links)
if [ ! -d "$BD" ]; then drift "no DB backup directory ($BD)"; else
  NEW="$(find "$BD/daily" -maxdepth 1 -type f -name "*.sql.gz" -printf '%T@ %p\n' | sort -n | tail -1)"
  if [ -z "$NEW" ]; then drift "DB backup directory is empty"; else
    ts="${NEW%% *}"; ts="${ts%.*}"; h=$(( (now - ts) / 3600 ))
    [ "$h" -gt 36 ] && drift "newest DB backup is ${h}h old ($(basename "${NEW#* }"))" || info "newest DB backup ${h}h old ($(basename "${NEW#* }"))"
  fi
fi

# Report
NDRIFT="$(grep -c $'\tdrift\t' "$REC")"
python3 - "$REC" "$JSON" "$NDRIFT" <<'PY' > "$TMP/report.txt"
import sys, json
allrows = [l.rstrip('\n').split('\t', 2) for l in open(sys.argv[1])]
secs = [s for s, k, t in allrows if k == 'sec']; rows = [r for r in allrows if r[1] != 'sec']
n = int(sys.argv[3])
if sys.argv[2] == '1':
    print(json.dumps({"drift_count": n, "clean": n == 0,
        "items": [{"section": s, "kind": k, "text": t} for s, k, t in rows]}, indent=1)); sys.exit()
print("Death Muffin drift report  %s  (vs origin/main)" % __import__('time').strftime('%Y-%m-%d %H:%M UTC', __import__('time').gmtime()))
for s in secs:
    print("\n== %s" % s)
    mine = [(k, t) for ss, k, t in rows if ss == s]
    if not any(k == 'drift' for k, _ in mine): print("  OK")
    for k, t in mine: print("  %s %s" % ({'drift': 'DRIFT', 'note': 'note ', 'info': '     '}[k], t))
print("\n%s" % ("CLEAN" if n == 0 else "%d thing(s) need attention" % n))
PY
cat "$TMP/report.txt"

if [ "$DISCORD" = 1 ] && { [ "$NDRIFT" -gt 0 ] || [ "$ALWAYS" = 1 ]; }; then
  if [ ! -r "$WEBHOOK_FILE" ]; then echo "discord: webhook file not readable" >&2; else
    grep -P '\tdrift\t' "$REC" | cut -f1,3 | python3 -c '
import sys, json
n = int(sys.argv[1]); lines = [l.rstrip("\n").split("\t", 1) for l in sys.stdin]
desc = "\n".join("- %s" % (t,) for _, t in lines) or "All clean."
if len(desc) > 3800: desc = desc[:3780] + "\n- ...truncated"
title = "Death Muffin weekly check: %d things need attention" % n if n else "Death Muffin weekly check: all clean"
print(json.dumps({"embeds": [{"title": title, "description": desc, "color": 15158332 if n else 3066993}], "allowed_mentions": {"parse": []}}))
' "$NDRIFT" > "$TMP/payload.json"
    curl -fsS -m 15 -o /dev/null -H 'Content-Type: application/json' -d @"$TMP/payload.json" "$(tr -d '\r\n' < "$WEBHOOK_FILE")" >/dev/null 2>&1 \
      && echo "discord: posted" || echo "discord: post failed" >&2
  fi
fi
[ "$NDRIFT" -gt 0 ] && exit 3
exit 0
