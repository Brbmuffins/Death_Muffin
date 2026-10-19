# Death Muffin Team (the team app)

A small Windows app for the three team PCs (War, Muffins and Helix; DECISIONS B54 and B55). It sits in the tray and runs the jobs that need a
real graphics card, which the server does not have. The first job is **screenshots of a Discord-agent proposal on Low and Ultra** (`shots`); the second is
**the game's own benchmark of each new client release** (`bench`), run on a PC that is left alone. It is not the
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
  The app never sends keys or mouse clicks. **Silent:** the game runs with `--audio-driver Dummy` (Godot still mixes, so the CPU cost stays real, but nothing is heard).
  **A screenshot job's game window is never seen:** it is started at its normal size (Godot does not draw a minimized window) with `--position` 1700 px left of the virtual screen
  (every monitor together), outside every monitor. As a fallback the window is also marked "no activate" and sent to the bottom of the window stack, and if it did become the active
  window the window you were using gets the focus back; Windows itself does not let a background program take the foreground. A benchmark's window stays on screen (the PC is idle
  by then, and a desktop compositor may treat an off-screen window differently).
- **Low priority.** The app and the game a screenshot job starts run below normal priority. A benchmark's game runs at **normal** priority (a lower one would skew the numbers), and
  the box says so.
- **It stops for you.** If you start Death Muffin while a screenshot job runs, the job's game is closed and the job is reported as
  "stopped: the game started". Closing the app does the same ("stopped: the team app was closed"). A benchmark treats it as a touch of the PC: the run is thrown away and the
  benchmark waits for the PC to be quiet again ("The benchmark job" below).
- **Its own folder, offline.** The game it starts runs with `APPDATA` and `LOCALAPPDATA` pointed into the job's folder (screenshots also with `--dev-offline`; a benchmark with
  `--bench-dir`, which makes it a trial that sends nothing), so it never touches your game, settings or account. **Every run of the game has its own empty pair** (`jobs\<id>\run-<n>\appdata` and
  `localappdata`: each screenshot preset, each benchmark setup and each retry), so one run never starts from another's offline save, settings or log.
- **Only our builds.** It downloads only from the game's own server (`/death-muffin/team-files/`, https, the same host), checks every file's
  SHA-256, refuses file names or addresses that could leave the job's folder, and passes the game only the options it checks (it sets `--shot-plan`,
  `--shots`, `--preset` and `--dev-offline` itself for screenshots, `--benchmark` and the `--bench-*` options for a benchmark). It uploads only the pictures the game made, as `<preset>_<shot>.png`,
  and sends a benchmark's runs only from the files the game wrote in the setup's own folder.
- **A pause stays a pause.** Pause 2 hours declines jobs for 2 hours (the server is told). Run now ends it.

## Modes (tray menu, Mode)

| Mode | What an offer does |
|---|---|
| **Ask** (default) | The box asks; it runs by itself after 5 minutes without an answer, unless something above is in the way. |
| **Run without asking** | No box; it runs under the same exceptions (for War's spare PC, if he sets it). |
| **Only on a yes** | The box asks and waits for a yes, however long. |

The server stores each PC's mode, so the Discord agent can see which PCs may take a job.

**AFK mode** (mode Ask only). When a box's 5 minutes run out with nobody answering and the job runs by itself, the app takes it that you are away and switches AFK mode on. A small notice stays in the
screen corner ("AFK mode on: jobs run right away" and an **End AFK mode** button; like the offer box it never takes the focus, is not topmost and has no taskbar button), the tray status says AFK mode and
the tray menu gets **End AFK mode** while it is on. While it is on, every new offer (screenshots or a benchmark) runs straight away, with no box and no 5-minute wait. The waits stay: Death Muffin or a
full-screen app running, the battery and a pause hold a job back, and a benchmark still waits for a quiet PC. It ends when you press the button or the menu item, by itself when you start Death Muffin or a
full-screen app comes up (you are back; while a job runs only Death Muffin counts, because a job's own window can read as full screen on a small screen), and when you pause, change the mode or sign out.
The next offer then shows the box with its 5 minutes again. Run without asking and Only on a yes never enter it, a yes (Run now) is not AFK, and it is not saved: a restart starts with it off.
The decisions are `TeamLogic.Decide` (which takes the flag), `EntersAfk` and `AfkEndReason`.

## The tray menu

The status line (what it is doing), **Run now** (ask the server for a job and run it, even when something above would wait: it is a yes),
**Pause 2 hours** / **Resume**, **End AFK mode** (only while AFK mode is on), **Mode**, **Sign in** / **Sign out** (not while a job runs), **Start with Windows** (this user only), **Open the app's folder**,
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
   keeps the job alive on the server (a job whose PC is silent for 3 minutes goes back to the queue). The reply may also list `cancel`: the jobs this PC is running that the server has cancelled.
   When the job the app is running is listed, it kills the game, drops the job without calling fail (the server knows) and the tray says "The job was cancelled."
2. The offer is decided by `TeamLogic.Decide` (`teamapp/windows/TeamLogic.cs`): ask, run, wait or decline, from the mode, your answer, how long the box
   has been up, and the exceptions above. The 5 minutes count from when the box is shown, so a wait never uses them up.
3. **Not now** declines the job for this PC (the job stays queued for the others, and the server skips it for this PC) and the app does not ask about it again for
   30 minutes either. **Pause** declines it once with
   the reason `paused`. A job whose kind this version cannot run is declined once and the status asks for a newer app.
4. A yes (or the 5 minutes, or auto mode) claims the job. If another PC got it first, the app lets it go. A benchmark is accepted and claimed later (see "The benchmark job").
5. The payload is checked (`JobPlan.cs`, by the job's kind). `shots`: the files (`DeathMuffinDebug.exe` with `DeathMuffinDebug.pck` beside it, `DeathMuffin.assets.pck` and the core library),
   the shot plan, the presets (low, medium, high, ultra) and the game options. `bench`: see "The benchmark job" below. Anything not allowed fails the job with a readable reason.
6. The files are downloaded into the job's folder with a SHA-256 check, resuming a half download. Files with a `cacheKey` (the art pack, about 500 MB, and the
   Godot debug build, about 90 MB) are kept in `cache\<cacheKey>\` and reused by later jobs without a download; the job's game folder gets a hard link
   to them (a copy when Windows refuses).
7. For each preset it starts `DeathMuffinDebug.exe --windowed --resolution 1600x900 --audio-driver Dummy --position <X,Y> -- --dev-offline <options> --shot-plan=<plan.json>
   --shots=<job>/out/<preset> --preset=<preset>`, one preset after the other, at most 10 minutes each, each with its own empty APPDATA and LOCALAPPDATA.
8. It uploads every picture as `<preset>_<shot>.png` (at most 40, each at most 8 MB), then reports **done** with the file names, the log and the timings.
   Any failure (a download that does not match, the game stopping with an error or making no pictures, the 10 minutes, a refused upload) reports **fail** with
   a readable sentence and the end of the log. What it keeps of the game's output and of Godot's own log leaves out Godot's exit report (a debug build's list of what it never freed:
   "... were leaked at exit", "... were never freed", "Leaked instance dependency", "ObjectDB instances were leaked", "resources still in use", each with the "at:" line under it) and nothing else:
   every other ERROR and WARNING stays, so the lines that say why it failed are not pushed out of the log tail the server keeps.
9. The last 3 job folders and the 4 most recently used cache folders are kept; older ones are deleted.

Steps 1 to 3 and 6 are the same for a `bench` job; the claim (4) comes later for it, and 5, 7 and 8 are what "The benchmark job" replaces.

## The benchmark job (`bench`)

After each client release the server offers every team PC a benchmark of the **release** build ("Benchmark of the new release, about 6 minutes"): the game's own benchmark
([client/README.md "The benchmark"](../client/README.md)) on one to six setups, each a graphics preset, a room, a class, a fight size and a length. The runs land on the public benchmarks page
under the member's account, marked as team-PC runs. The numbers only mean something if the PC was left alone, so the app is strict:

- **The payload.** The files are `DeathMuffin.exe` (the release build, never the debug one) with `DeathMuffin.pck` beside it, `DeathMuffin.assets.pck` and
  `libdmcore.windows.template_release.x86_64.dll`; `setups` are 1 to 6 objects with a preset (low, medium, high, ultra), a room (a lower-case word), a class (1 to 20), a size
  (light, standard, heavy, full_party) and a length (quick or full: the lengths the game knows; any other word is refused, because the game would run its full length without saying so). `args` may
  add game options the app does not set itself.
- **The command**, once per setup: `DeathMuffin.exe --windowed --resolution 1600x900 --audio-driver Dummy -- --benchmark --bench-room=<room> --bench-class=<n> --bench-size=<size> --bench-length=<length> --bench-preset=<preset>
  --bench-dir=<job>\bench-<i> --bench-quit`, at normal priority, at most 15 minutes. With `--bench-dir` the game sends nothing: it leaves the run in `bench-<i>\pending.json` and quits by itself (exit code 0
  when a run was recorded, 1 when it was cancelled or failed, 2 for a setup it refuses).
- **Accepted, not claimed.** After a yes (or the automatic start) the benchmark is kept in the app as accepted and waiting, and **not claimed**: it stays queued on the server (targeted at this PC, so
  nobody else can take it). The PC is not busy meanwhile: heartbeats go on and a screenshot job offered now is handled as usual. One job runs at a time, so the waiting benchmark pauses while a
  screenshot job runs (the PC is not read then) and its quiet minute starts over after it; the server offers screenshot jobs ahead of benchmarks, so a waiting benchmark never hides a newer
  screenshot job. The tray says "Benchmark waiting for the PC to be left alone". A benchmark offered while a job runs is not declined as busy (a decline would end it for this PC). A pause holds it back,
  signing out forgets it, and it is kept only in memory (after a restart the server offers it again and the box asks again).
- **Claimed when the PC is quiet.** Once nothing else runs and the PC has been quiet for a whole minute (the app reads it once a second): no key or mouse for 60 s (`GetLastInputInfo`), the total CPU of
  every process averaging under 15% over the minute, and through the minute no full-screen app, Death Muffin not open and the PC not on battery (a reading gap over 5 s, from sleep or a hang, starts
  the minute over), the app claims the benchmark and runs it. If the claim answers that the job is gone (taken, expired, cancelled) it is dropped and the tray shows the server's words; a heartbeat that offers
  nothing, or another benchmark, means the same. A claim that failed for a passing reason is tried again after 30 s.
- **Quiet again before each setup.** The files are downloaded after the claim, and before each setup the runner reads the PC the same way and waits for a quiet minute again. While it waits the status says
  what is in the way. It waits until the job's life ends (the offer's expiry, 3 days), then fails with "The PC never went quiet for long enough: ...".
- **A disturbed run** is thrown away. While the game runs the app keeps reading the PC; the run is disturbed by a key or the mouse after it started, by the other programs (every process but
  the game) using more than 20% of the CPU on average over any 30 s of it (judged once the run is 10 s old), by the player starting Death Muffin or by the cable being pulled. The game is closed,
  the setup's `bench-<i>` folder and the run's APPDATA are deleted, the app waits for a quiet minute again and starts the setup over: at most 3 tries a setup, then the job fails with
  "The benchmark on Low was disturbed 3 times (...), so no numbers were sent. Leave the PC alone while it runs." A full-screen app is not a disturbance during a run (on a small screen the game's own 1600x900 window may count as one).
- **The result.** The last entry of each setup's `pending.json` (the payload the game would send, at most 64 KB; a cancelled one is no result) goes into **done** as `runs`, in setup order, all in one call:
  a setup that fails fails the job and nothing is sent. The server checks each run as it checks one a player sent and marks it as a team-PC run.
- **It asks first, like every job.** A benchmark is offered in the same box (Run now / Not now / Pause 2 hours), under the same modes and the same exceptions (`TeamLogic.Decide`: Ask accepts by itself after 5 minutes
  unless a game, a full-screen app or the battery is in the way, Run without asking, Only on a yes). The quiet wait above starts only after the yes (or the automatic start), and the box says so: "It starts once the PC has
  been left alone for a minute, and runs at normal priority. Touching the mouse or keyboard restarts it."

## Folders (`%LOCALAPPDATA%\DeathMuffinTeam\`)

| What | Where |
|---|---|
| Settings (signed-in account, protected token, this PC's id, mode, pause) | `settings.json` |
| The app's own log | `app.log` (and `app.old.log`) |
| Files kept across jobs | `cache\<cacheKey>\` |
| One job | `jobs\<id>\` with `game\`, `run-<n>\appdata\` and `run-<n>\localappdata\` (a fresh pair for each run of the game), `out\<preset>\` (screenshots) or `bench-<i>\` (a benchmark setup's `pending.json`), `plan.json`, `job.log` |

## Updating itself

The app reads `https://muffindevelopment.com/death-muffin/teamapp/version.json` (`{version, url, sha256}`, `size` optional) 30 seconds after it starts and then every 15 minutes. For a newer version it
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

`TeamLogic.cs` (modes, the offer decision, texts, token expiry, version compare, hashing), `Quiet.cs` (when a PC is quiet enough for a benchmark and when a run was disturbed: pure rules over readings of the PC),
`JobPlan.cs` (payload checks for each kind, command lines, upload names, reading a benchmark's result),
`TeamApi.cs` (the login and the server's team routes behind an injectable transport), `TeamController.cs` (heartbeat, offers, answers, claim, sign-in problems),
`JobRunner.cs` (download, game runs, uploads or benchmark runs, done or fail), `FileFetcher.cs` (checked, resumable downloads), `GameHost.cs` (starting the game and watching for
the player's Death Muffin), `TeamFolders.cs`, `Settings.cs`, `SelfUpdate.cs`, `Json.cs`: none of them touches Windows or WinForms, and `teamapp/tests` runs all of them.
`Platform.cs` (DPAPI, full screen and battery checks, the CPU and keyboard/mouse readings, hard links, the game's window, start with Windows), `TrayContext.cs`, `OfferBox.cs`, `AfkNotice.cs`, `SignInForm.cs`,
`Art.cs` (the launcher's look) and `Program.cs` are the Windows side.

### What only a PC can check

The compile check proves the Windows code compiles; it cannot run it. These are checked by hand on a team PC (and the app is not released to anyone before they are):
DPAPI save and load across a restart; the full-screen check (a game or film full screen hides the box and the run, and a yes still runs); the battery check on a laptop;
that the job's game window does not take the keyboard or the focus (the game is started at its normal size because Godot does not draw a minimized window); hard links into the
job folder; `APPDATA` and `LOCALAPPDATA` reaching Godot; `--preset` honoured by the debug build; the tray icon, balloons and menu; self-update on a real exe swap; and one whole
screenshot job against the server. For the benchmark job: the total CPU reading (`GetSystemTimes`) against Task Manager and the game's share (its process's CPU time); the idle time
(`GetLastInputInfo`) counting a key or the mouse and nothing the app or the game does; the game really running at normal priority (Task Manager, Details) and the job refused when Windows will
not allow it; the game's window not counting as a full-screen app or as input; the release build honouring `--bench-quit`, `--bench-dir` and `--bench-preset` (exit codes 0, 1, 2) and leaving
`pending.json`; a disturbed run on a real PC (touch the mouse) being discarded and retried; the box's note; and one whole benchmark job against the server, including a screenshot job interleaved with a waiting benchmark (the controller reads the PC on the interface thread once a second). Also on a real PC: `--audio-driver Dummy` really silent (loading screen and game), a screenshot job's window really never seen with `--position` left of every
monitor (and the pictures still taken: Godot and the driver draw a window that is off screen), a cancel in the heartbeat reply stopping a running game; the AFK notice (shown without taking the keyboard or the focus, End AFK mode working from it and from the tray menu).

### Changelog

- **0.2.0** (2026-10-19) - The `bench` job: the game's own benchmark of the release build, offered like any job (and, in AFK mode, accepted at once), then accepted and kept unclaimed (the PC is not busy, screenshot jobs run meanwhile) until the PC is
  quiet (a minute without input and under 15% CPU, nothing full screen, Death Muffin closed, on mains), thrown away and retried (3 tries a setup) when the PC is touched; the runs go to the server in `done`. A benchmark's game runs at normal priority and its box says so.
  Every run of the game gets its own empty `APPDATA` and `LOCALAPPDATA` (a Low run's offline save no longer starts the Ultra run). The game is silent (`--audio-driver Dummy`) and a screenshot job's window is
  started outside every monitor (`--position`). AFK mode: a box that runs out in mode Ask means you are away, and jobs then run without a box until you are back. A job the server cancels is dropped ("The job was cancelled."). Godot's exit report is left out of the logs.
- **0.1.1** (2026-10-19) - The game starts on a real PC (no `--main-pack`: the pack is named after the exe), the graphics card is reported, the update check runs every 15 minutes.
- **0.1.0** (2026-10-19) - First version: the team sign-in with the game's account name and password, the tray menu, heartbeat, the offer box and modes, the `shots` job (Low and Ultra),
  cache for the art pack and the Godot build, self-update. The team sign-in (a 90-day team token, `Authorization: Team`, nothing stored but the token, Sign out tells the server).
