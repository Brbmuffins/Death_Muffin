# Server Operations — Local Repo vs. Production VPS

Two separate machines, two separate change processes. Read this before Claude Code touches anything past `npm run build`.

## The two environments

**1. This repo (`Cross Worlds Web`, on your machine, tracked by GitHub Desktop)**
Everything Claude Code writes by default — `src/`, config files, docs — lives here and only here until you deliberately deploy it. Committing/pushing this repo does **not** touch the VPS. GitHub Desktop is your commit/push tool for this repo; it has no relationship to the server.

**2. The VPS (`playcrossworlds.com`, `15.204.243.36`)**
Runs the live auth server, dashboard, and (soon) the realtime service. Reached only by `ssh ubuntu@playcrossworlds.com`. Nothing gets there unless something is explicitly copied/deployed over SSH. This is production — real accounts, real characters, real gold.

```
/opt/rod-auth/server.js          — auth + game REST API (port 3000)
/opt/rod-auth/.env               — DB creds, JWT secret
/opt/rod-dashboard/server.js     — GM dashboard (port 4000)
/var/www/rod/                    — public static site (Nginx serves this)
/opt/rod-realtime/                — NEW, Phase 3 — doesn't exist yet, Claude Code creates it
```

## What actually gets uploaded, per phase

| Phase | What changes locally | What (if anything) goes to the VPS |
|---|---|---|
| 1–2 | `src/**`, this repo only | Nothing. Pure client work against the *existing* live API. |
| 3 | `src/net/realtime.ts` + new socket client code | **New** `/opt/rod-realtime/` service — new code, new port, new systemd unit. First time this build touches the server. |
| 4–5 | more `src/**` | None, unless a phase turns up a genuine gap in the existing `/api/*` endpoints — if so, only *additive* changes to `/opt/rod-auth/server.js`, never edits to existing routes. |
| 6 | `dist/` (production build output) | `dist/*` → `/var/www/rod/` (or a subpath, your call — e.g. `/var/www/rod/play/` so the old Unity download page can stay up during transition) |

So: for most of this build, nothing touches the VPS at all. The two moments that do are (a) standing up the new realtime service in Phase 3, and (b) deploying the built web client in Phase 6. Everything else is local iteration you push to git whenever you want.

## Safe deploy procedure (what Claude Code should follow, every time)

1. **Diff first.** Show exactly what file(s) will land on the server and what they'll contain — no surprise edits.
2. **Backup before touching an existing file.** `cp /opt/rod-auth/server.js /opt/rod-auth/server.js.bak.$(date +%s)` before any edit to a file that already exists in production.
3. **New code goes in new files/services**, not inline edits, wherever possible — this is why Phase 3's realtime service is its own directory and process, not bolted into `rod-auth`.
4. **Deploy, then verify, in that order:**
   ```
   scp <local file(s)> ubuntu@playcrossworlds.com:<dest>
   ssh ubuntu@playcrossworlds.com "sudo systemctl restart <service>"
   ssh ubuntu@playcrossworlds.com "sudo systemctl status <service>"
   ssh ubuntu@playcrossworlds.com "sudo journalctl -u <service> -n 30 --no-pager"
   curl http://playcrossworlds.com:3000/api/health
   ```
5. **State the rollback** before deploying, not after something breaks — usually "restore the `.bak` file and restart."
6. **Never touch**: `/opt/rod-auth/.env`, the old endpoints, ports 3000/4000/7777/3001 (Phase 3's new service needs its own port — Claude Code should pick one, e.g. 5000, and say so explicitly).

## Prompt to give Claude Code for any server-level step

Use this whenever you're ready for Claude Code to actually deploy something (Phase 3's realtime service, or Phase 6's static build) — don't let it SSH in as a side effect of a normal coding session:

> This step touches the production VPS at playcrossworlds.com, which is separate from this local repo. Before running any `ssh`/`scp` command: (1) show me the exact diff or new file contents, (2) tell me the exact deploy commands you're about to run, (3) confirm you've backed up any existing file you're overwriting, (4) confirm which port/service this uses and that it doesn't collide with 3000, 4000, 7777, or 3001. Wait for my go-ahead before running anything against the server. After deploying, show me the systemctl status and the last 20 log lines as proof it's actually healthy, and tell me the rollback command in case I need it.

For routine local work (everything in Phases 1, 2, 4, 5 except the actual endpoint additions), no server prompt is needed — it's just `npm run dev` / `npm run build` in this repo, committed via GitHub Desktop as normal.

## Reference: SSH/service commands (already in use for the Unity-era server, same box)

```bash
ssh ubuntu@playcrossworlds.com

# services
sudo systemctl status crossworlds-auth crossworlds-dashboard crossworlds
sudo systemctl restart crossworlds-auth

# logs
sudo journalctl -u crossworlds-auth -n 50 --no-pager
tail -f /var/log/crossworlds.log

# db
mysql -u rodgame -p"$(grep DB_PASS /opt/rod-auth/.env | cut -d= -f2)" rod_online

# health check
curl http://localhost:3000/api/health
```
