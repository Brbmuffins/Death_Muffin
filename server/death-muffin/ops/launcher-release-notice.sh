#!/usr/bin/env bash
# Posts each new Windows launcher release (GitHub Release tagged launcher-v<version>, built by .github/workflows/launcher-windows.yml) to
# #build-alerts, once. Run every 10 minutes by death-muffin-launcher-notice.timer. Reads the public GitHub API (no token) and the #build-alerts
# webhook file. The first run only records the releases that exist (no backlog posts). The text is that version's changelog line in
# launcher/windows/README.md on origin/main, else the release body. A failed post is retried on the next run (the tag is recorded only after).
set -euo pipefail
REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
RUNTIME="${RUNTIME:-/home/ubuntu/death-muffin}"
HOOK_FILE="${HOOK_FILE:-$RUNTIME/private/discord-build-alerts-webhook.url}"
STATE="${STATE:-$RUNTIME/ops/state/launcher-announced.txt}"
API="${API:-https://api.github.com/repos/Brbmuffins/Death_Muffin/releases?per_page=20}"
mkdir -p "$(dirname "$STATE")"
JSON=$(curl -sSf --max-time 20 -H 'Accept: application/vnd.github+json' "$API")
TAGS=$(printf '%s' "$JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const r of JSON.parse(s))if(/^launcher-v/.test(r.tag_name)&&!r.draft&&!r.prerelease)console.log(r.tag_name)})')
[ -n "$TAGS" ] || exit 0
if [ ! -f "$STATE" ]; then printf '%s\n' "$TAGS" >"$STATE"; echo "seeded $(wc -l <"$STATE") existing launcher releases"; exit 0; fi
git -C "$REPO" fetch -q origin 2>/dev/null || true
README=$(git -C "$REPO" show origin/main:launcher/windows/README.md 2>/dev/null || true)
# oldest first, so several new releases post in order
for TAG in $(printf '%s\n' "$TAGS" | tac); do
  grep -qxF "$TAG" "$STATE" && continue
  [ -s "$HOOK_FILE" ] || { echo "no webhook file $HOOK_FILE" >&2; exit 1; }
  BODY=$(printf '%s' "$JSON" | TAG="$TAG" README="$README" node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const r=JSON.parse(s).find((x)=>x.tag_name===process.env.TAG); const v=r.tag_name.replace(/^launcher-v/,"");
      // the changelog entry: "- **0.8.0** - text" plus its indented continuation lines
      const lines=(process.env.README||"").split("\n"); let note="";
      const i=lines.findIndex((l)=>l.startsWith(`- **${v}** -`));
      if(i>=0){note=lines[i].replace(/^- \*\*[^*]+\*\* - /,"");for(let k=i+1;k<lines.length&&/^\s{2,}\S/.test(lines[k]);k++)note+=" "+lines[k].trim();}
      if(!note)note=(r.body||"").trim();
      const zip=(r.assets||[]).find((a)=>/\.zip$/.test(a.name));
      const content=`🖥️ **Launcher ${v} is out**\n${note.slice(0,1500)}\nDownload: ${zip?zip.browser_download_url:r.html_url}`;
      process.stdout.write(JSON.stringify({username:"Death Muffin Releases",allowed_mentions:{parse:[]},content}));})')
  curl -sSf --max-time 20 -o /dev/null -H 'content-type: application/json' -d "$BODY" "$(cat "$HOOK_FILE")"
  echo "$TAG" >>"$STATE"; echo "announced $TAG"
done
