#!/usr/bin/env bash
# GitHub CI's verdict on a revision, for sessions, the Discord agent and ship scripts (tools/check/README.md "CI is the gate"):
#   tools/check/ci.sh status <rev>               prints "<passed|failed|pending|none> <run url or ->" and exits 0
#   tools/check/ci.sh wait <rev> [<minutes>]     waits (default 60 minutes): exit 0 passed, 1 failed or cancelled, 2 no run or out of time
#   tools/check/ci.sh failed <rev>               the game suites CI reported failing, one per line (from the run's annotations)
# A verdict belongs to a tree, not a commit: a CI run of any commit with exactly the same files counts (a fast-forward, a re-push, a merge
# that changed nothing), so a revision CI already passed is never waited for again. Only the "CI" workflow counts. Every caller on this
# machine shares one copy of the recent runs ($DM_CI_CACHE, default /home/ubuntu/death-muffin/ci-status), refreshed with a conditional request
# (an unchanged answer does not count against GitHub's limit) at most once a minute without a token (60 calls an hour for the whole machine)
# and every 15 s with one in $DM_GITHUB_TOKEN_FILE (default /home/ubuntu/death-muffin/private/github-api-token; read-only access is enough).
# A token GitHub refuses (401: expired or revoked) is not a dead end: the call is repeated without it, `token-bad` in the cache folder records
# the time, one note an hour says so on stderr, and for that hour the token is not sent (the no-token pace applies); then it is tried again.
set -euo pipefail
REPO_SLUG="${DM_GITHUB_REPO:-Brbmuffins/Death_Muffin}"
API="${DM_GITHUB_API:-https://api.github.com}/repos/$REPO_SLUG"
CACHE="${DM_CI_CACHE:-/home/ubuntu/death-muffin/ci-status}"
TOKEN_FILE="${DM_GITHUB_TOKEN_FILE:-/home/ubuntu/death-muffin/private/github-api-token}"
CMD="${1:-}"; REV="${2:-}"
[ -n "$CMD" ] && [ -n "$REV" ] || { sed -n '2,5p' "$0" >&2; exit 2; }
SHA=$(git rev-parse --verify "$REV^{commit}") || exit 2
TREE=$(git rev-parse "$SHA^{tree}")
mkdir -p "$CACHE"
BAD="$CACHE/token-bad"
# auth: the token header, unless the token file is missing or GitHub refused the token less than an hour ago (the marker's age).
set_auth() {
  auth=()
  [ -s "$TOKEN_FILE" ] || return 0
  if [ -f "$BAD" ] && [ $(( $(date +%s) - $(stat -c %Y "$BAD") )) -lt 3600 ]; then return 0; fi
  auth=(-H "Authorization: Bearer $(tr -d '[:space:]' < "$TOKEN_FILE")")
}
# A 401 to a call that carried the token, so remember it (once an hour at most, so the marker's age is the hour) and say so; the caller repeats without it.
token_refused() {
  date -u +%FT%TZ > "$BAD"
  echo "ci.sh: GitHub refused the API token in $TOKEN_FILE (expired or revoked?); checking without it, 60 calls an hour" >&2
  set_auth
}
# A token GitHub accepted clears an old marker.
token_ok() { [ ${#auth[@]} -eq 0 ] || [ ! -f "$BAD" ] || rm -f "$BAD"; }
# gh_get <outfile> <url> [curl options]: the body into the file, the status code on stdout; the token is sent when there is a good one and a refused
# token falls back to no token. Called in the main shell (not a $(...)), so the fallback holds for the rest of the run.
gh_get() {
  local out="$1" url="$2" code; shift 2
  set_auth
  code=$(curl -s -m 30 -o "$out" -w '%{http_code}' "${auth[@]}" "$@" "$url" || echo 000)
  if [ "$code" = 401 ] && [ ${#auth[@]} -gt 0 ]; then
    token_refused
    code=$(curl -s -m 30 -o "$out" -w '%{http_code}' "$@" "$url" || echo 000)
  elif [ "$code" != 401 ] && [ "$code" != 000 ]; then token_ok; fi
  echo "$code"
}

# The recent runs, shared: one refresh at a time, at most every 60 s without a token (GitHub's 60 calls an hour), every 15 s with one.
refresh() {
  set_auth
  local EVERY=60; [ ${#auth[@]} -eq 0 ] || EVERY=15; EVERY="${DM_CI_EVERY:-$EVERY}"   # (DM_CI_EVERY, DM_CI_POLL: tests)
  exec 8>"$CACHE/.lock"; flock -w 60 8 || return 0
  if [ -s "$CACHE/runs.json" ] && [ $(( $(date +%s) - $(stat -c %Y "$CACHE/runs.json") )) -lt "$EVERY" ]; then flock -u 8; return 0; fi
  # GitHub's limit used up: no request until it resets (asking again would not help), and say so once a minute at most
  local until; until=$(cat "$CACHE/limited" 2>/dev/null || echo 0)
  if [ "$(date +%s)" -lt "$until" ]; then
    [ -n "$(find "$CACHE/limited" -mmin -1 2>/dev/null)" ] || { echo "ci.sh: GitHub's API limit is used up until $(date -u -d "@$until" +%H:%M) UTC (60 calls an hour without a token, see tools/check/README.md); the answer can be up to that old" >&2; touch "$CACHE/limited"; }
    flock -u 8; return 0
  fi
  local hdr=(); [ ! -s "$CACHE/etag" ] || [ ! -s "$CACHE/runs.json" ] || hdr=(-H "If-None-Match: $(cat "$CACHE/etag")")
  local code reset
  code=$(curl -s -m 30 -o "$CACHE/.new" -D "$CACHE/.hdr" -w '%{http_code}' "${auth[@]}" "${hdr[@]}" -H 'Accept: application/vnd.github+json' "$API/actions/runs?per_page=60" || echo 000)
  if [ "$code" = 401 ] && [ ${#auth[@]} -gt 0 ]; then
    token_refused
    code=$(curl -s -m 30 -o "$CACHE/.new" -D "$CACHE/.hdr" -w '%{http_code}' "${hdr[@]}" -H 'Accept: application/vnd.github+json' "$API/actions/runs?per_page=60" || echo 000)
  elif [ "$code" != 401 ] && [ "$code" != 000 ]; then token_ok; fi
  if [ "$code" = 200 ]; then
    mv "$CACHE/.new" "$CACHE/runs.json"; grep -i '^etag:' "$CACHE/.hdr" | cut -d' ' -f2- | tr -d '\r' > "$CACHE/etag" || true
  elif [ "$code" = 304 ]; then touch "$CACHE/runs.json"
  elif [ "$code" = 403 ] || [ "$code" = 429 ]; then
    reset=$(grep -i '^x-ratelimit-reset:' "$CACHE/.hdr" | tr -dc '0-9')
    if [ -n "$reset" ]; then echo "$reset" > "$CACHE/limited"; echo "ci.sh: GitHub's API limit is used up until $(date -u -d "@$reset" +%H:%M) UTC; the answer can be up to that old" >&2; fi
  fi
  rm -f "$CACHE/.new" "$CACHE/.hdr"; flock -u 8
}
# A revision older than the recent runs is looked up by itself (one call).
lookup_sha() { gh_get "$CACHE/.one-$$" "$API/actions/runs?head_sha=$SHA&per_page=20" -H 'Accept: application/vnd.github+json' >/dev/null; }
verdict() {
  refresh
  local f="$CACHE/runs.json" out
  [ -s "$f" ] || { echo "none -"; return; }
  # The runs of the same tree: fetch is not needed for a commit we have; one we do not have cannot be compared (left out).
  out=$(python3 - "$f" "$TREE" "$SHA" <<'PY'
import json, subprocess, sys
runs = [r for r in json.load(open(sys.argv[1])).get("workflow_runs", []) if r.get("name") == "CI"]
tree = sys.argv[2]
def tree_of(sha):
    p = subprocess.run(["git", "rev-parse", "--verify", "-q", sha + "^{tree}"], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else ""
same = [r for r in runs if tree_of(r["head_sha"]) == tree]
if not same: print("none -"); sys.exit()
own = any(r["head_sha"] == sys.argv[3] for r in same)
ok = [r for r in same if r["status"] == "completed" and r["conclusion"] == "success"]
if ok: print("passed", ok[0]["html_url"]); sys.exit()
live = [r for r in same if r["status"] != "completed"]
if live: print("pending", live[0]["html_url"]); sys.exit()
bad = [r for r in same if r["conclusion"] not in ("cancelled", "skipped")]
print(("failed " + bad[0]["html_url"]) if bad else ("cancelled " + same[0]["html_url"]), "" if own else "(another commit with these files)")
PY
)
  if [ "${out%% *}" = none ]; then
    lookup_sha
    out=$(python3 -c '
import json, sys
runs = [r for r in json.load(open(sys.argv[1])).get("workflow_runs", []) if r.get("name") == "CI"]
ok = [r for r in runs if r["status"] == "completed" and r["conclusion"] == "success"]
live = [r for r in runs if r["status"] != "completed"]
bad = [r for r in runs if r["status"] == "completed" and r["conclusion"] not in ("cancelled", "skipped", "success")]
print(("passed " + ok[0]["html_url"]) if ok else ("pending " + live[0]["html_url"]) if live else ("failed " + bad[0]["html_url"]) if bad else ("cancelled " + runs[0]["html_url"]) if runs else "none -")
' "$CACHE/.one-$$" 2>/dev/null || echo "none -")
    rm -f "$CACHE/.one-$$"
  fi
  echo "$out"
}

case "$CMD" in
  status) verdict ;;
  wait)
    MIN="${3:-60}"; START=$(date +%s); END=$(( START + MIN * 60 )); seen_none=0
    while :; do
      v=$(verdict); s="${v%% *}"
      case "$s" in
        passed) echo "$v"; exit 0 ;;
        failed|cancelled)
          # from another commit with these files while this one's own run can still appear (a re-push to retry a flake): give it 5 minutes
          if [[ "$v" == *"(another commit with these files)"* ]] && [ $(( $(date +%s) - START )) -lt "${DM_CI_OWN_WAIT:-300}" ]; then :; else echo "$v"; exit 1; fi ;;
        none) seen_none=$((seen_none + 1)) ;;
      esac
      # a run appears a few seconds after a push; ten minutes without one means none is coming
      if [ "$s" = none ] && [ "$seen_none" -ge "${DM_CI_NONE_TRIES:-30}" ]; then echo "none - (no CI run for this revision)"; exit 2; fi
      [ "$(date +%s)" -lt "$END" ] || { echo "$v (out of time after $MIN minutes)"; exit 2; }
      sleep "${DM_CI_POLL:-20}"
    done ;;
  failed)
    # Each failing game suite is an error annotation titled "client suite <name> failed" (tools/rebuild/run-client-tests.sh prints it).
    gh_get "$CACHE/.checks-$$" "$API/commits/$SHA/check-runs?per_page=100" -H 'Accept: application/vnd.github+json' >/dev/null
    python3 -c '
import json, re, sys, subprocess
api = sys.argv[1]; auth = sys.argv[2:]
seen = []
for c in json.load(sys.stdin).get("check_runs", []):
    if c.get("conclusion") != "failure": continue
    url = api + "/check-runs/" + str(c["id"]) + "/annotations?per_page=100"
    out = subprocess.run(["curl", "-s", "-m", "30", *auth, url], capture_output=True, text=True).stdout
    for a in json.loads(out or "[]"):
        m = re.match(r"^client suite (\S+) failed$", a.get("title") or "")
        if m and m.group(1) not in seen: seen.append(m.group(1))
print("\n".join(seen))
' "$API" "${auth[@]}" < "$CACHE/.checks-$$"; rm -f "$CACHE/.checks-$$" ;;
  *) echo "ci.sh: unknown command $CMD (status, wait, failed)" >&2; exit 2 ;;
esac
