#!/usr/bin/env bash
# Bug-report agent, near real time (death-muffin-bug-agent.timer, every 2 minutes; exits at once when nothing is new). Reads the 'new' player reports, lets a sandboxed headless Claude
# fix what it can in the Godot client (git branch main, project dir godot/) on a fresh branch, writes each report's verdict back for the player, and tells the owner on Discord.
#
#   run-bug-agent.sh            normal run (one branch per run that found reports)
#   run-bug-agent.sh --dry-run  list the pending reports and stop
#
# Safety: the agent runs in --restricted mode (file tools confined to its worktree, user settings ignored, no MCP), with
# --permission-mode dontAsk and an allowlist (read/edit files, `agit` = a few filtered git verbs, `check.sh` = the Godot test suites with no
# network and a read-only filesystem). Both live in ~/death-muffin/bug-agent, outside the worktree, so the agent cannot rewrite them. It never deploys, never pushes, and never sees the database: this script hands it the reports and applies its
# validated verdicts. The owner reviews `bugfix/reports-<date>-<time>`, merges it to main and ships it with publish-godot-client.sh.
set -euo pipefail

REPO=/home/ubuntu/vps-handoffs/DeathMuffin/game
RUNTIME=/home/ubuntu/death-muffin
STATE="$RUNTIME/bug-agent"
DATE=$(date -u +%Y%m%d-%H%M)   # one run = one branch; runs every 2 minutes, so the minute keeps names unique
BRANCH="bugfix/reports-$DATE"
WT=/home/ubuntu/vps-handoffs/DeathMuffin/wt/bug-agent-$DATE
LOG="$STATE/runs/$(date -u +%Y%m%d).log"   # one log per day; quiet ticks (no new report) write nothing
SUMMARY="$STATE/runs/$DATE.md"
mkdir -p "$STATE/runs"
# One run at a time: a report that arrives during a run is picked up by the next tick.
exec 8>"$STATE/run.lock"
flock -n 8 || exit 0

# The CLI is installed beside the runtime so the job does not depend on any checkout's working tree.
CLI="$STATE/reports-cli.cjs"
REPORTS=$(node "$CLI" list)
if [ "${1:-}" = "--dry-run" ]; then printf '%s\n' "$REPORTS"; exit 0; fi   # read-only: no attempt counted
# A report a run could not settle stays 'new'; after 3 attempts it is set aside (attempts.json) and the owner is told once, so a
# stubborn report cannot make every 2-minute tick start a new agent run.
ATTEMPTS="$STATE/attempts.json"
REPORTS=$(REPORTS="$REPORTS" node -e '
  const fs = require("fs"); const f = process.argv[1];
  let a = {}; try { a = JSON.parse(fs.readFileSync(f, "utf8")); } catch {}
  const rows = JSON.parse(process.env.REPORTS);
  const keep = rows.filter((r) => (a[r.id] || 0) < 3);
  const parked = rows.filter((r) => (a[r.id] || 0) >= 3 && !a["told_" + r.id]);
  for (const r of keep) a[r.id] = (a[r.id] || 0) + 1;
  for (const r of parked) a["told_" + r.id] = 1;
  fs.writeFileSync(f, JSON.stringify(a));
  if (parked.length) fs.writeFileSync(f + ".parked", parked.map((r) => "#" + r.id).join(", "));
  process.stdout.write(JSON.stringify(keep));
' "$ATTEMPTS")

COUNT=$(printf '%s' "$REPORTS" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).length))')
IDS=$(printf '%s' "$REPORTS" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).map(r=>r.id).join(",")))')
if [ "$COUNT" = 0 ]; then
  if [ -s "$ATTEMPTS.parked" ] && [ -r "$RUNTIME/private/discord-deathmuffin-webhook.url" ]; then
    python3 - "$RUNTIME/private/discord-deathmuffin-webhook.url" "$(cat "$ATTEMPTS.parked")" <<'PY' || true
import json, sys, urllib.request
url, ids = open(sys.argv[1]).read().strip(), sys.argv[2]
embed = {"title": "Bug reports set aside", "description": f"The bug agent tried {ids} three times without settling them; they wait for a person (reports-cli.cjs show <id>).", "color": 0xB45309}
urllib.request.urlopen(urllib.request.Request(url, data=json.dumps({"username": "Death Muffin", "embeds": [embed], "allowed_mentions": {"parse": []}}).encode(), headers={"Content-Type": "application/json", "User-Agent": "death-muffin-bug-agent"}), timeout=10)
PY
  fi
  rm -f "$ATTEMPTS.parked"
  exit 0
fi
exec > >(tee -a "$LOG") 2>&1
echo "== $(date -u +%FT%TZ) bug agent run"
echo "pending reports: $COUNT ($IDS)"
[ -s "$ATTEMPTS.parked" ] && echo "set aside after 3 attempts: $(cat "$ATTEMPTS.parked")"
rm -f "$ATTEMPTS.parked"

if git -C "$REPO" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null || [ -e "$WT" ]; then
  echo "branch $BRANCH or $WT already exists — stopping"; exit 1
fi
git -C "$REPO" fetch -q origin
git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" origin/main
# node_modules is only for tools/godot/gen-fixtures.sh (the golden fixtures are generated from the frozen TS game).
ln -s "$REPO/node_modules" "$WT/node_modules"
BASE=$(git -C "$WT" rev-parse HEAD)

PROMPT_FILE="$STATE/runs/$DATE.prompt.md"
REPORTS="$REPORTS" BRANCH="$BRANCH" STATE="$STATE" node -e '
  const fs = require("fs");
  // Keep the closing tag out of player text so a report cannot end the <reports> block early.
  const reports = process.env.REPORTS.replace(/<\/?reports>/gi, "[reports]");
  process.stdout.write(fs.readFileSync(process.argv[1], "utf8").replace("__BRANCH__", process.env.BRANCH).replaceAll("__STATE__", process.env.STATE).replace("__REPORTS__", () => reports));
' "$STATE/PROMPT.md" > "$PROMPT_FILE"

echo "== agent (worktree $WT)"
set +e
(
  cd "$WT"
  # check.sh runs a few minutes (full ~9 min) (hard limit 50): the Bash tool must block that long, never background it (2026-10-08 hang lesson).
  export CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 BASH_DEFAULT_TIMEOUT_MS=3300000 BASH_MAX_TIMEOUT_MS=3300000
  timeout 3h claude -p \
    --restricted --strict-mcp-config --no-session-persistence \
    --model opus \
    --permission-mode dontAsk \
    --tools "Read,Edit,Write,Glob,Grep,Bash" \
    --allowedTools "Read" "Edit" "Write" "Glob" "Grep" "Bash($STATE/agit *)" "Bash($STATE/check.sh)" \
    --disallowedTools "WebFetch" "WebSearch" \
    < "$PROMPT_FILE"
)
AGENT_RC=$?
set -e
echo "agent exit: $AGENT_RC"

VERDICTS="$WT/.bug-agent-verdicts.json"
cp "$VERDICTS" "$STATE/runs/$DATE.verdicts.json" 2>/dev/null || true
git -C "$WT" rm -q --cached --ignore-unmatch .bug-agent-verdicts.json >/dev/null

COMMITS=$(git -C "$WT" rev-list --count "$BASE..HEAD")
CHECKS="not run (no commits)"
if [ "$COMMITS" -gt 0 ]; then
  if (cd "$WT" && "$STATE/check.sh" >/dev/null 2>&1); then CHECKS="pass"; else CHECKS="FAIL"; fi
fi

# Verdicts reach players only when the branch is green; on a red branch, "fixed" is downgraded to "triaged".
if [ -f "$VERDICTS" ]; then
  if [ "$CHECKS" = "FAIL" ]; then
    node -e 'const f=process.argv[1],fs=require("fs");const v=JSON.parse(fs.readFileSync(f,"utf8"));for(const x of v)if(x&&x.status==="fixed"){x.status="triaged";x.note="Thanks! We found the cause and are working on a fix.";}fs.writeFileSync(f,JSON.stringify(v));' "$VERDICTS" || true
  fi
  BUG_AGENT_IDS="$IDS" node "$CLI" apply "$VERDICTS" || echo "verdicts not applied"
else
  echo "no verdicts file; reports stay 'new' for the next run (at most 3 attempts)"
fi

{
  echo "# Bug agent — $DATE"
  echo
  echo "- Reports: $COUNT ($IDS)"
  echo "- Branch: \`$BRANCH\` — $COMMITS commit(s) on origin/main $(git -C "$WT" rev-parse --short "$BASE"), checks: $CHECKS"
  echo "- Review: \`git -C $REPO log --stat origin/main..$BRANCH\`"
  echo
  [ -f "$VERDICTS" ] && node -e '
    const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    for (const x of Array.isArray(v) ? v : []) console.log(`- #${x.id} **${x.status}**${x.fixRef ? ` (${x.fixRef})` : ""}: ${String(x.ownerNote || x.note || "").replace(/\s+/g, " ").slice(0, 300)}`);
  ' "$VERDICTS" || true
} > "$SUMMARY"
cat "$SUMMARY"

if [ "$COMMITS" = 0 ]; then
  git -C "$REPO" worktree remove --force "$WT"
  git -C "$REPO" branch -q -D "$BRANCH"
  echo "no fixes; worktree and branch removed"
fi

HOOK_FILE="$RUNTIME/private/discord-deathmuffin-webhook.url"
[ -r "$HOOK_FILE" ] || HOOK_FILE="$RUNTIME/private/discord-github-webhook.url"
if [ -r "$HOOK_FILE" ]; then
  python3 - "$SUMMARY" "$HOOK_FILE" <<'PY' && echo "Discord: summary sent" || echo "Discord: summary failed"
import json, sys, urllib.request
body, url = open(sys.argv[1]).read(), open(sys.argv[2]).read().strip()
embed = {"title": "Death Muffin bug reports — triage (fixes await review)", "description": body[:3900], "color": 0xB45309}
req = urllib.request.Request(url, data=json.dumps({"username": "Death Muffin", "embeds": [embed], "allowed_mentions": {"parse": []}}).encode(),
                             headers={"Content-Type": "application/json", "User-Agent": "death-muffin-bug-agent"})
urllib.request.urlopen(req, timeout=10)
PY
fi
exit 0
