#!/usr/bin/env bash
# Death Muffin nightly drift report. READ-ONLY: compares the VPS with origin/main and prints what differs.
# Exit 0 = clean, 3 = drift found.   drift-report.sh [--discord] [--always] [--json]
# Env: REPO (checkout, default /home/ubuntu/vps-handoffs/DeathMuffin/game), DM_HOME (~/death-muffin), WWW (/var/www/death-muffin)
set -u
REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
DM="${DM_HOME:-/home/ubuntu/death-muffin}"
WWW="${WWW:-/var/www/death-muffin}"
WEBHOOK_FILE="${WEBHOOK_FILE:-$DM/private/discord-build-alerts-webhook.url}"   # #build-alerts
GH_TOKEN_FILE="${GH_TOKEN_FILE:-$DM/private/github-api-token}"   # the read-only token tools/check/ci.sh sends to GitHub
GH_API="${GH_API:-https://api.github.com}"
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
section "1. Installed agent and ops copies"
SRC=server/death-muffin/discord-agent
LIST="$(g ls-tree -r --name-only "$REV" -- "$SRC/runner" | sed "s#^$SRC/##")
ship.sh rollback.sh sandbox-lib.sh check-godot.sh regen-godot.sh shot-godot.sh label-shot.py render-model.sh render-model.py art-run.sh build-art.sh sound-run.mjs build-sound.sh sound-build.mjs preview-godot.sh agit wait-for-ship.sh reports-cli.cjs PROMPT-godot.md config.example.json death-muffin-discord-agent.service"
for f in $(echo $LIST); do compare_exact "$SRC/$f" "$DM/discord-agent/$f" "discord-agent/$f"; done
# the agent's guides (install-runner.sh replaces the folder whole): each one in main, and nothing installed that main does not have
GUIDES="$(g ls-tree -r --name-only "$REV" -- "$SRC/guides" | sed "s#^$SRC/##")"
for f in $GUIDES; do compare_exact "$SRC/$f" "$DM/discord-agent/$f" "discord-agent/$f"; done
for lf in "$DM"/discord-agent/guides/*; do [ -e "$lf" ] || continue; case " $(echo $GUIDES) " in *" guides/$(basename "$lf") "*) ;; *) drift "discord-agent/guides/$(basename "$lf"): installed but not in origin/main";; esac; done
compare_exact tools/check/prep.sh "$DM/discord-agent/prep.sh" "discord-agent/prep.sh"
compare_exact tools/check/ci.sh "$DM/discord-agent/ci.sh" "discord-agent/ci.sh"
for f in common gemini tripo; do compare_exact "tools/ai/$f.mjs" "$DM/discord-agent/art-tools/tools/ai/$f.mjs" "discord-agent/art-tools/tools/ai/$f.mjs"; done
compare_exact "$SRC/death-muffin-discord-agent.service" /etc/systemd/system/death-muffin-discord-agent.service "systemd death-muffin-discord-agent.service"
# the ops jobs themselves (this script included: an installed copy left behind once kept reporting a retired agent)
for f in drift-report.sh backup-db.sh launcher-release-notice.sh health-watch.mjs sync-checkout.sh; do compare_exact "server/death-muffin/ops/$f" "$DM/ops/$f" "ops/$f"; done
compare_exact server/death-muffin/team-files-prune.sh "$DM/ops/team-files-prune.sh" "ops/team-files-prune.sh"   # the nightly team-prune job's copy (the script lives beside team-check.sh)
for u in death-muffin-drift-report.service death-muffin-drift-report.timer death-muffin-db-backup.service death-muffin-db-backup.timer death-muffin-launcher-notice.service death-muffin-launcher-notice.timer death-muffin-health-watch.service death-muffin-health-watch.timer death-muffin-team-prune.service death-muffin-team-prune.timer death-muffin-checkout-sync.service death-muffin-checkout-sync.timer; do
  compare_exact "server/death-muffin/ops/$u" "/etc/systemd/system/$u" "systemd $u"; done
compare_exact server/death-muffin/ops/git-pre-push.sh "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push" "git pre-push hook"

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
# the UDP relay (installed by deploy-lobby.sh)
for f in server/death-muffin/relay/project.godot server/death-muffin/relay/relay_main.gd client/net/relay/dm_udp_relay.gd; do
  compare_exact "$f" "$DM/relay/$(basename "$f")" "relay/$(basename "$f")"; done
compare_exact server/death-muffin/relay/deathmuffin-relay.service /etc/systemd/system/deathmuffin-relay.service "systemd deathmuffin-relay.service"
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
    # Only files that go into the exported client count (export_presets.cfg excludes tests/, tools/, dev/, shots/, build/; docs don't ship), and the combat core.
    N="$(g rev-list --count "$CREV..$REV" -- client/ native/src/ ':(exclude)client/tests/**' ':(exclude)client/tools/**' ':(exclude)client/dev/**' ':(exclude)client/*.md' ':(exclude)client/**/*.md' ':(exclude)client/shots/**' ':(exclude)client/build/**')"
    info "published rev $CREV"
    [ "$N" -gt 0 ] && drift "$N commit(s) changing the shipped game (client/ or the combat core, not tests, tools or docs) merged after the published rev $CREV, not published"
  fi
fi

# 4. Git leftovers
section "4. Git leftovers"
age_days() { echo $(( (now - $1) / 86400 )); }
while read -r _ ref; do b="${ref#refs/heads/}"; [ "$b" = main ] && continue
  d="$(g log -1 --format=%ct "origin/$b" 2>/dev/null || echo "$now")"; a=$(age_days "$d")
  case "$b" in
    discord/*) info "agent job (remote): $b, ${a}d old"; [ "$a" -gt 7 ] && drift "agent job older than 7 days: origin/$b (${a}d)";;
    *) drift "remote branch other than main: $b";;
  esac
done < <(g ls-remote --heads origin)
while read -r b; do [ "$b" = main ] && continue
  d="$(g log -1 --format=%ct "$b")"; a=$(age_days "$d")
  case "$b" in
    discord/*) info "agent job (local): $b, ${a}d old"; [ "$a" -gt 7 ] && drift "agent job older than 7 days: local $b (${a}d)";;
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
# check_wt_dirs: a folder in wt/ that git does not list as a worktree. Whole paths are compared, so a leftover wt/discord-abc is not hidden by a
# registered wt/discord-abc-2 (test: drift-leftovers.test.cjs).
check_wt_dirs() {
  local registered d; registered="$(g worktree list --porcelain | sed -n 's/^worktree //p')"
  for d in "$(dirname "$REPO")"/wt/*/; do [ -d "$d" ] || continue
    printf '%s\n' "$registered" | grep -Fxq -- "${d%/}" || drift "directory in wt/ that is not a registered worktree: ${d%/}"; done
}
check_wt_dirs

# 5. Uncommitted
section "5. Main checkout"
ST="$(g status --porcelain)"
if [ -n "$ST" ]; then drift "uncommitted changes in $REPO ($(echo "$ST" | wc -l) path(s)): $(echo "$ST" | head -3 | tr '\n' ';')"; fi
# the nightly checkout sync (sync-checkout.sh, 04:55) fast-forwards it; behind here means that job could not (a branch, local changes, a ship)
BR="$(g branch --show-current)"; BEHIND="$(g rev-list --count HEAD.."$REV" 2>/dev/null || echo '?')"
[ "$BR" = main ] || drift "$REPO is on '${BR:-a detached HEAD}', not main"
[ "$BEHIND" = 0 ] || drift "$REPO is $BEHIND commit(s) behind $REV: its files are not the game's (journalctl -u death-muffin-checkout-sync says why)"

# 6. Docroot
section "6. Public docroot $WWW"
EXP=" bake-kit client client-test launcher play preview team-files teamapp $(g ls-tree --name-only "$REV" -- server/death-muffin/site/ | sed 's#.*/##' | tr '\n' ' ')"
for e in "$WWW"/* "$WWW"/.[!.]*; do [ -e "$e" ] || continue; n="$(basename "$e")"
  case "$EXP" in *" $n "*) ;; *) drift "unexpected top-level entry: $n";; esac; done
if [ -d "$WWW/play" ]; then for e in "$WWW/play"/* "$WWW/play"/.[!.]*; do [ -e "$e" ] || continue; n="$(basename "$e")"
  case "$n" in index.html|patch-notes.json|release-notes.json) ;; *) drift "unexpected file in play/: $n";; esac; done; fi
# the downloads the site serves on purpose are not secret-ish: the team app's zips, the bake kit, the agent's preview builds
while IFS= read -r f; do drift "secret-ish file in docroot: ${f#$WWW/}"; done < <(find "$WWW" -not -path "$WWW/teamapp/DeathMuffinTeam-*.zip" -not -path "$WWW/bake-kit/kit-*.zip" -not -path "$WWW/preview/*/DeathMuffin-Preview-*-win64.zip" \( -iname '*.env' -o -iname '.env*' -o -iname '*.sql' -o -iname '*.zip' -o -iname '*.bak' -o \( -iname '*.txt' \( -iname '*key*' -o -iname '*token*' \) \) \) 2>/dev/null)
TV=$(find "$WWW/teamapp" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null | wc -l)
[ "$TV" -le 2 ] || drift "teamapp/ holds $TV versions (publish-teamapp.sh keeps the newest 2: server/death-muffin/publish-teamapp.sh --prune)"

# 7. Services
section "7. Services"
for s in death-muffin-auth deathmuffin-lobby deathmuffin-relay death-muffin-discord-agent death-muffin-auth-test death-muffin-lobby-test death-muffin-relay-test; do
  st="$(systemctl is-active $s 2>&1)"; [ "$st" = active ] || drift "$s is $st"; done
H="$(curl -fsS -m 5 http://127.0.0.1:5190/health 2>&1)" || drift "auth /health failed: ${H:0:100}"
[ -n "${H:-}" ] && info "auth /health: ${H:0:100}"
if [ -f "$DM/backend-test/.env" ]; then   # the rebuild's test backend (test-server/README.md): up, and on the live server code
  curl -fsS -m 5 http://127.0.0.1:5194/health >/dev/null 2>&1 || drift "test backend :5194 /health failed"
  diff -rq --exclude=.env --exclude='.env.*' "$DM/backend" "$DM/backend-test" >/dev/null 2>&1 || drift "test backend code differs from live (run server/death-muffin/test-server/sync.sh)"
fi

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
# The team PCs' builds and results: cleaned by the nightly team-prune job (team-files-prune.sh) and the backend (results 14 days after a job): growth past these means a clean-up stopped
TFKB=$(du -sk "$WWW/team-files" 2>/dev/null | cut -f1); TRKB=$(du -sk "$DM/team-results" 2>/dev/null | cut -f1)
info "team-files/ size: $(du -sh "$WWW/team-files" 2>/dev/null | cut -f1), team-results/ size: $(du -sh "$DM/team-results" 2>/dev/null | cut -f1)"
[ "${TFKB:-0}" -gt $((10 * 1024 * 1024)) ] && drift "team-files/ holds $(du -sh "$WWW/team-files" | cut -f1) (over 10 GB): is the death-muffin-team-prune timer running?"
[ "${TRKB:-0}" -gt $((5 * 1024 * 1024)) ] && drift "team-results/ holds $(du -sh "$DM/team-results" | cut -f1) (over 5 GB): the backend removes a job's results 14 days after it finished, when a new job is made"
# deploy-release.sh and deploy-lobby.sh keep their newest 5 backups each after a good deploy: more means that pruning stopped
for P in backup-pre-release backup-lobby; do
  NB=$(find "$DM/deploy" -maxdepth 1 -mindepth 1 -type d -name "$P-*" 2>/dev/null | wc -l)
  [ "$NB" -gt 5 ] && note "$NB $P-* folders in deploy/ (the deploys keep 5): is their pruning running?"
done

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

# check_github_token: tools/check/ci.sh (the agent's and the sessions' CI verdict) sends this token; GitHub rate_limit is a free call. Drift when the
# file is missing, GitHub refuses the token (401), or its expiry (header github-authentication-token-expiration) is under 14 days away.
GH_TOKEN_HOWTO="Muffins (brbmuffins, the repo owner) makes a new one on github.com -> Settings -> Developer settings -> Fine-grained tokens (\"Public repositories (read-only)\") and DMs it to Muffin Core."
check_github_token() {
  if [ ! -s "$GH_TOKEN_FILE" ]; then
    drift "the GitHub token file is missing ($GH_TOKEN_FILE), so CI checks run on the 60-calls-an-hour limit and the agent can be left without a verdict. $GH_TOKEN_HOWTO"; return
  fi
  local code hdr="$TMP/gh-token.hdr" exp ts days
  # the token goes in on stdin, never in the command line
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '[:space:]' < "$GH_TOKEN_FILE")" | curl -s -m 15 -K - -o /dev/null -D "$hdr" -w '%{http_code}' -H 'Accept: application/vnd.github+json' "$GH_API/rate_limit" 2>/dev/null || echo 000)
  case "$code" in
    401) drift "GitHub refuses the CI token (expired or revoked): CI checks fall back to 60 calls an hour and can leave the agent without a verdict. $GH_TOKEN_HOWTO"; return;;
    200) ;;
    000) info "GitHub token not checked: could not reach GitHub"; return;;
    *) info "GitHub token not checked: GitHub answered $code"; return;;
  esac
  exp=$(grep -i '^github-authentication-token-expiration:' "$hdr" 2>/dev/null | head -1 | cut -d' ' -f2- | tr -d '\r')
  if [ -z "$exp" ]; then info "GitHub token works (no expiry date)"; return; fi
  ts=$(date -d "$exp" +%s 2>/dev/null) || { info "GitHub token works (expiry date not understood: $exp)"; return; }
  days=$(( (ts - $(date +%s)) / 86400 ))
  if [ "$days" -lt 14 ]; then drift "the GitHub token for CI checks runs out in ${days} day(s) (on $exp); after that CI checks fall back to 60 calls an hour. $GH_TOKEN_HOWTO"
  else info "GitHub token works, expires in ${days} days"; fi
}

# 10. GitHub token
section "10. GitHub token for CI checks"
check_github_token

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
if len(desc) > 3700: desc = desc[:3680] + "\n- ...truncated"
if n: desc += "\n\nDetails: `~/death-muffin/ops/drift-report.sh` on the VPS."
title = "Death Muffin nightly check: %d things need attention" % n if n else "Death Muffin nightly check: all clean"
print(json.dumps({"embeds": [{"title": title, "description": desc, "color": 15158332 if n else 3066993}], "allowed_mentions": {"parse": []}}))
' "$NDRIFT" > "$TMP/payload.json"
    curl -fsS -m 15 -o /dev/null -H 'Content-Type: application/json' -d @"$TMP/payload.json" "$(tr -d '\r\n' < "$WEBHOOK_FILE")" >/dev/null 2>&1 \
      && echo "discord: posted" || echo "discord: post failed" >&2
  fi
fi
[ "$NDRIFT" -gt 0 ] && exit 3
exit 0
