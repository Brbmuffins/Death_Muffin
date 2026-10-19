# Death Muffin Team (the team app)

A small Windows app for the three team PCs (War, Muffins and Helix; DECISIONS B54 and B55). It sits in the tray and runs the jobs that need a
real graphics card, which the server does not have. The first job is **screenshots of a Discord-agent proposal on Low and Ultra**. It is not the
players' launcher: it is installed only on those PCs, updates itself, and a bug in it never reaches players.

The server keeps everything with keys or passwords and everything that changes the live game. The app only downloads builds our server made and
uploads results; the server checks each result before it uses it.

## Who can use it

Only the accounts on the server's team list (a table the server's team routes read; rows are added by hand). Anyone else who signs in gets
"This account is not on the team." and the app stops. Hiding the app is not the protection: the server's team routes refuse every other account.

## What it promises

- **It asks first.** A job comes with a small box ("Screenshots of a change, about 1 minute": Run now / Not now / Pause 2 hours). With no answer
  it runs by itself after 5 minutes (mode Ask).
- **It never gets in the way.** It waits (no box, no run) while a full-screen app is running (a game, a film, a presentation; Windows hides
  questions then), while Death Muffin is open (a party's host runs the whole party's fight) or while a laptop is on battery, until that ends or
  you say yes. The box is shown without taking the focus, is not topmost, has no taskbar button and its buttons do not ask for the keyboard.
  The app never sends keys or mouse clicks. The job's game window is started at its normal size (Godot does not draw a minimized window), marked "no
  activate", sent to the bottom of the window stack, and if it did become the active window the window you were using gets the focus back; Windows itself
  does not let a background program take the foreground.
- **Low priority.** The app and the game it starts run below normal priority.
- **It stops for you.** If you start Death Muffin while a job runs, the job's game is closed and the job is reported as
  "stopped: the game started". Closing the app does the same ("stopped: the team app was closed").
- **Its own folder, offline.** The game it starts runs `--dev-offline` with `APPDATA` and `LOCALAPPDATA` pointed into the job's folder, so it never
  touches your game, settings or account.
- **Only our builds.** It downloads only from the game's own server (`/death-muffin/team-files/`, https, the same host), checks every file's
  SHA-256, refuses file names or addresses that could leave the job's folder, and passes the game only the options it checks (it sets `--shot-plan`,
  `--shots`, `--preset` and `--dev-offline` itself). It uploads only the pictures the game made, as `<preset>_<shot>.png`.
- **A pause stays a pause.** Pause 2 hours declines jobs for 2 hours (the server is told). Run now ends it.

## Modes (tray menu, Mode)

| Mode | What an offer does |
|---|---|
| **Ask** (default) | The box asks; it runs by itself after 5 minutes without an answer, unless something above is in the way. |
| **Run without asking** | No box; it runs under the same exceptions (for War's spare PC, if he sets it). |
| **Only on a yes** | The box asks and waits for a yes, however long. |

The server stores each PC's mode, so the Discord agent can see which PCs may take a job.

## The tray menu

The status line (what it is doing), **Run now** (ask the server for a job and run it, even when something above would wait: it is a yes),
**Pause 2 hours** / **Resume**, **Mode**, **Sign in** / **Sign out** (not while a job runs), **Start with Windows** (this user only), **Open the app's folder**,
**Open the last job's log**, **Quit**. Balloons are for the answer to a click (Run now with nothing waiting), a failed or refused job, being signed out
and a newer version that could not be installed.

## Signing in

The sign-in box takes the Death Muffin account name and password and sends them once to the team's own sign-in on the server (`POST .../team/login` with the name,
password, this PC's id and its name). The server checks the password and that the account is on the team, and answers with a **team token** that lasts 90 days.
That sign-in **never touches the game's session**, so it cannot stop a game you have open from saving, and playing never signs the app out.

- The token is kept in `settings.json` protected with Windows DPAPI for the current user; the file never holds it in plain text. **No password is ever stored.**
- Every team route is called with `Authorization: Team <token>` (not the game's bearer token).
- If the server stops accepting the token (401, `signed_out`: after Sign out here, after 90 days, or if the member is removed), the app shows "Signed out: sign in
  to the team app again." as a balloon and in the status, forgets the token and stops asking the server for jobs until you sign in from the tray menu. It never opens
  the box by itself, except at the very first start.
- **Sign out** (tray menu) tells the server to end the token (`POST .../team/logout`) and then forgets it, even if the server cannot be reached. It is refused while a job runs.

## What a job does

1. Every 30 seconds the app sends a heartbeat (its id, name, version, graphics card, mode, and whether Death Muffin runs, a full-screen app runs, the
   PC is on battery, a job is running or it is paused). The reply carries the oldest waiting job, if any. Heartbeats go on while a job runs: that
   keeps the job alive on the server (a job whose PC is silent for 3 minutes goes back to the queue).
2. The offer is decided by `TeamLogic.Decide` (`teamapp/windows/TeamLogic.cs`): ask, run, wait or decline, from the mode, your answer, how long the box
   has been up, and the exceptions above. The 5 minutes count from when the box is shown, so a wait never uses them up.
3. **Not now** declines the job for this PC (the job stays queued for the others, and the server skips it for this PC) and the app does not ask about it again for
   30 minutes either. **Pause** declines it once with
   the reason `paused`. A job whose kind this version cannot run is declined once and the status asks for a newer app.
4. A yes (or the 5 minutes, or auto mode) claims the job. If another PC got it first, the app lets it go.
5. The payload is checked (`JobPlan.cs`): the files (`DeathMuffin.pck`, `DeathMuffin.assets.pck`, the core library and `DeathMuffinDebug.exe`), the shot plan,
   the presets (low, medium, high, ultra) and the game options. Anything not allowed fails the job with a readable reason.
6. The files are downloaded into the job's folder with a SHA-256 check, resuming a half download. Files with a `cacheKey` (the art pack, about 500 MB, and the
   Godot debug build, about 90 MB) are kept in `cache\<cacheKey>\` and reused by later jobs without a download; the job's game folder gets a hard link
   to them (a copy when Windows refuses).
7. For each preset it starts `DeathMuffinDebug.exe --main-pack DeathMuffin.pck --windowed --resolution 1600x900 -- --dev-offline <options> --shot-plan=<plan.json>
   --shots=<job>/out/<preset> --preset=<preset>`, one preset after the other, at most 10 minutes each.
8. It uploads every picture as `<preset>_<shot>.png` (at most 40, each at most 8 MB), then reports **done** with the file names, the log and the timings.
   Any failure (a download that does not match, the game stopping with an error or making no pictures, the 10 minutes, a refused upload) reports **fail** with
   a readable sentence and the end of the log.
9. The last 3 job folders and the 4 most recently used cache folders are kept; older ones are deleted.

## Folders (`%LOCALAPPDATA%\DeathMuffinTeam\`)

| What | Where |
|---|---|
| Settings (signed-in account, protected token, this PC's id, mode, pause) | `settings.json` |
| The app's own log | `app.log` (and `app.old.log`) |
| Files kept across jobs | `cache\<cacheKey>\` |
| One job | `jobs\<id>\` with `game\`, `appdata\`, `localappdata\`, `out\<preset>\`, `plan.json`, `job.log` |

## Updating itself

The app reads `https://muffindevelopment.com/death-muffin/teamapp/version.json` (`{version, url, sha256}`, `size` optional) every hour. For a newer version it
does what the launcher does ([launcher/windows/SelfUpdate.cs](../launcher/windows/SelfUpdate.cs)): downloads `DeathMuffinTeam.exe.new` next to itself, checks the SHA-256,
renames the running exe to `.old`, moves the new one in, starts it and closes; the new copy removes `.old`. Never while a job runs. A folder it cannot write to,
or three failures, show a balloon and the app keeps running. The workflow artifact is not published anywhere: putting a build in that folder of the site is a
separate, manual step from a committed revision.

**Publishing a version** (on the VPS, from a committed revision; first published 2026-10-19 as 0.1.0): raise `<Version>` in `DeathMuffinTeam.csproj`, then
`git archive <rev> teamapp | tar -x -C <scratch>` and `dotnet build <scratch>/teamapp/windows/DeathMuffinTeam.csproj -c Release` (the .NET 8 SDK at
`/home/ubuntu/porchlite/.dotnet`; it builds the net48 exe on Linux); copy `DeathMuffinTeam.exe` and `.exe.config` to `/var/www/death-muffin/teamapp/<version>/`,
write `DeathMuffinTeam-<version>.zip` (the two files and a README.txt) beside it for first installs, and replace the site's `version.json` in that folder with the new
`{version, url, sha256, size}` last: the installed apps update within the hour.

## Build and test

```
bash teamapp/tests/run-local.sh              # logic tests: .NET 8 runtime + any Roslyn csc.dll (CSC=/path/to/csc.dll); a real local file server and a stand-in game
bash teamapp/tests/compile-check.sh [dir]    # compiles the whole app, UI included, against the .NET Framework 4.8 reference assemblies; keeps the exe in [dir]
dotnet run --project teamapp/tests           # the same logic tests with the SDK (Linux or Windows)
dotnet build teamapp/windows/DeathMuffinTeam.csproj -c Release    # the real build: teamapp/windows/bin/Release/net48/DeathMuffinTeam.exe
```

The [team app workflow](../.github/workflows/teamapp-windows.yml) runs the logic tests on Linux, builds on `windows-latest` and keeps `DeathMuffinTeam-win-x64.zip` as a
workflow artifact for 30 days (pushes touching `teamapp/**`, and manual runs). It makes no release. Bump `<Version>` in `DeathMuffinTeam.csproj` (three
numbers) for each release and add a line below.

### Code map

`TeamLogic.cs` (modes, the offer decision, texts, token expiry, version compare, hashing), `JobPlan.cs` (payload checks, command lines, upload names),
`TeamApi.cs` (the login and the server's team routes behind an injectable transport), `TeamController.cs` (heartbeat, offers, answers, claim, sign-in problems),
`JobRunner.cs` (download, game runs, uploads, done or fail), `FileFetcher.cs` (checked, resumable downloads), `GameHost.cs` (starting the game and watching for
the player's Death Muffin), `TeamFolders.cs`, `Settings.cs`, `SelfUpdate.cs`, `Json.cs`: none of them touches Windows or WinForms, and `teamapp/tests` runs all of them.
`Platform.cs` (DPAPI, full screen and battery checks, hard links, the game's window, start with Windows), `TrayContext.cs`, `OfferBox.cs`, `SignInForm.cs`,
`Art.cs` (the launcher's look) and `Program.cs` are the Windows side.

### What only a PC can check

The compile check proves the Windows code compiles; it cannot run it. These are checked by hand on a team PC (and the app is not released to anyone before they are):
DPAPI save and load across a restart; the full-screen check (a game or film full screen hides the box and the run, and a yes still runs); the battery check on a laptop;
that the job's game window does not take the keyboard or the focus (the game is started at its normal size because Godot does not draw a minimized window); hard links into the
job folder; `APPDATA` and `LOCALAPPDATA` reaching Godot; `--preset` honoured by the debug build; the tray icon, balloons and menu; self-update on a real exe swap; and one whole
screenshot job against the server.

### Changelog

- **0.1.0** (2026-10-19) - First version: the team sign-in with the game's account name and password, the tray menu, heartbeat, the offer box and modes, the `shots` job (Low and Ultra),
  cache for the art pack and the Godot build, self-update. The team sign-in (a 90-day team token, `Authorization: Team`, nothing stored but the token, Sign out tells the server).
