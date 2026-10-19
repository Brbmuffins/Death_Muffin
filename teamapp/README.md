# Death Muffin Team (the team app)

A small Windows app for the three team PCs (War, Muffins and Helix; DECISIONS B54 and B55). It sits in the tray and runs the jobs that need a
real graphics card, which the server does not have. Its jobs: **screenshots of a Discord-agent proposal on Low and Ultra** (`shots`; also of a *before* and an *after* build, side by side),
**short videos of a change** (`clip`; one game run for each variant the team can choose between, such as three speeds of a spell), and **the game's own benchmark of each new client release**
(`bench`), run on a PC that is left alone, and **the release checks of each new client** (`release`: install, quit while loading, screens at four window sizes, stutter, bench and soak, one job and one report). It is not the players' launcher: it is installed only on those PCs, updates itself, and a bug in it never reaches players.

The server keeps everything with keys or passwords and everything that changes the live game. The app only downloads builds our server made and
uploads results; the server checks each result before it uses it.

## Who can use it

Only the accounts on the server's team list (a table the server's team routes read; rows are added by hand). Anyone else who signs in gets
"This account is not on the team." and the app stops. Hiding the app is not the protection: the server's team routes refuse every other account.

## What it promises

- **It asks first.** A job comes with a small box ("Screenshots of a change, about 1 minute"; "Short videos of a change, about 3 minutes" for a clip job: Run now / Not now / Pause 2 hours). With no answer
  it runs by itself after 5 minutes (mode Ask).
- **It never gets in the way.** It waits (no box, no run) while a full-screen app is running (a game, a film, a presentation; Windows hides
  questions then), while Death Muffin is open (a party's host runs the whole party's fight) or while a laptop is on battery, until that ends or
  you say yes. The box is shown without taking the focus, stays on top of other windows like a notification (never over a game: a job waits while one runs),
  comes with a tray balloon, has no taskbar button and its buttons do not ask for the keyboard. Every change in what the app decides about an offer, and every
  box shown, is written to `app.log` (why it shows, waits or runs).
  The app never sends keys or mouse clicks. **Silent:** the game runs with `--audio-driver Dummy` (Godot still mixes, so the CPU cost stays real, but nothing is heard).
  **A screenshot job's game window is never seen:** it is started at its normal size (Godot does not draw a minimized window) with `--position` 1700 px left of the virtual screen
  (every monitor together), outside every monitor. As a fallback the window is also marked "no activate" and sent to the bottom of the window stack, and if it did become the active
  window the window you were using gets the focus back; Windows itself does not let a background program take the foreground. A benchmark's window stays on screen (the PC is idle
  by then, and a desktop compositor may treat an off-screen window differently).
- **Low priority.** The app and the game a screenshot or clip job starts run below normal priority. A benchmark's game runs at **normal** priority (a lower one would skew the numbers), and
  the box says so.
- **It stops for you.** If you start Death Muffin while a screenshot or clip job runs, the job's game is closed and the job is reported as
  "stopped: the game started". Closing the app does the same ("stopped: the team app was closed"). A benchmark treats it as a touch of the PC: the run is thrown away and the
  benchmark waits for the PC to be quiet again ("The benchmark job" below).
- **Its own folder, offline.** The game it starts runs with `APPDATA` and `LOCALAPPDATA` pointed into the job's folder (screenshots and clips also with `--dev-offline`; a benchmark with
  `--bench-dir`, which makes it a trial that sends nothing), so it never touches your game, settings or account. **Every run of the game has its own empty pair** (`jobs\<id>\run-<n>\appdata` and
  `localappdata`: each screenshot preset on each build, each clip variant, each benchmark setup and each retry), so one run never starts from another's offline save, settings or log.
- **Only our builds.** It downloads only from the game's own server (`/death-muffin/team-files/`, https, the same host), checks every file's
  SHA-256, refuses file names or addresses that could leave the job's folder, and passes the game only the options it checks (it sets `--shot-plan`,
  `--shots`, `--preset` and `--dev-offline` itself for screenshots, `--clip-plan`, `--clips`, `--tune`, `--preset` and `--dev-offline` for clips, `--benchmark` and the `--bench-*` options for a benchmark). It uploads only the pictures
  the game made, as `<preset>_<shot>.png` (`<build>_<preset>_<shot>.png` with two builds), the clips it recorded, as `<variant>_<clip>.mjpeg`, and sends a benchmark's runs only from the files the game wrote in the setup's own folder.
- **A job that is refused stays no job.** If the server will not accept a finished job (`done` answered with an error), the app tells it the job failed, with the server's own reason, so a job never stays "running" on the server
  (this PC's heartbeat would keep it alive for ever).
- **A pause stays a pause.** Pause 2 hours declines jobs for 2 hours (the server is told). Run now ends it.

## Modes (tray menu, Mode)

| Mode | What an offer does |
|---|---|
| **Ask** (default) | The box asks; it runs by itself after 5 minutes without an answer, unless something above is in the way. |
| **Run without asking** | No box; it runs under the same exceptions (for War's spare PC, if he sets it). |
| **Only on a yes** | The box asks and waits for a yes, however long. |

The server stores each PC's mode, so the Discord agent can see which PCs may take a job.

**AFK mode** (mode Ask only). When a box's 5 minutes run out with nobody answering and the job runs by itself, the app takes it that you are away and switches AFK mode on. A small notice stays in the
screen corner ("AFK mode on: jobs run right away", what runs and what is queued, an **End AFK mode** button and a **Hide** button; it stays on top of everything while it is up, never takes the focus and has no
taskbar button; Hide puts the notice away and AFK mode stays on, until the tray's **Show AFK notice** or the next AFK mode shows it again), the tray status says AFK mode and
the tray menu gets **End AFK mode** while it is on. While it is on, every new offer (screenshots or a benchmark) runs straight away, with no box and no 5-minute wait. The waits stay: Death Muffin or a
full-screen app running, the battery and a pause hold a job back, and a benchmark still waits for a quiet PC. It ends when you press the button or the menu item, by itself when you start Death Muffin or a
full-screen app comes up (you are back; while a job runs only Death Muffin counts, because a job's own window can read as full screen on a small screen), and when you pause, change the mode or sign out.
The next offer then shows the box with its 5 minutes again. Run without asking and Only on a yes never enter it, a yes (Run now) is not AFK, and it is not saved: a restart starts with it off.
The decisions are `TeamLogic.Decide` (which takes the flag), `EntersAfk` and `AfkEndReason`.

## The tray menu

The status line (what it is doing), **Run now** (ask the server for a job and run it, even when something above would wait: it is a yes),
**Pause 2 hours** / **Resume**, **End AFK mode** (only while AFK mode is on), **Show AFK notice** (only after Hide), **Mode**, **Sign in** / **Sign out** (not while a job runs), **Start with Windows** (this user only), **Open the app's folder**,
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

1. The app keeps a heartbeat in flight (its id, name, version, graphics card, mode, and whether Death Muffin runs, a full-screen app runs, the
   PC is on battery, a job is running or it is paused). It is a **long poll**: it asks the server to hold it up to 25 seconds (`wait` 25, an HTTP limit of 40 s) while there is nothing to say, so a new job or a cancel
   reaches the PC in about a second, and the next heartbeat is sent at once after the answer. The reply carries the oldest waiting job, if any. Heartbeats go on while a job runs: that
   keeps the job alive on the server (a job whose PC is silent for 3 minutes goes back to the queue). The reply may also list `cancel`: the jobs this PC is running that the server has cancelled.
   When the job the app is running is listed, it kills the game, drops the job without calling fail (the server knows) and the tray says "The job was cancelled." Pauses between heartbeats, `TeamLogic.HeartbeatPause`:
   none after an answer with news (an offer the PC had not seen, a cancel of the job it runs) or after a held answer; at least 5 seconds between two heartbeats when an answer had nothing new and came
   back at once (a server that does not hold requests, an offer waiting for a yes, a cancel list the PC already knows), so the server is never asked in a tight loop; after a failed heartbeat 5 s, then 15 s, then 30 s every time, starting over after an answer.
   Signed out (or the app stopped), the loop only looks once a second whether the PC has signed in again. A sign-in, a mode change and a finished job send one heartbeat at once that asks for an answer at once (`wait` 0).
2. The offer is decided by `TeamLogic.Decide` (`teamapp/windows/TeamLogic.cs`): ask, run, wait or decline, from the mode, your answer, how long the box
   has been up, and the exceptions above. The 5 minutes count from when the box is shown, so a wait never uses them up.
3. **Not now** declines the job for this PC (the job stays queued for the others, and the server skips it for this PC) and the app does not ask about it again for
   30 minutes either. **Pause** declines it once with
   the reason `paused`. A job whose kind this version cannot run is declined once and the status asks for a newer app.
4. A yes (or the 5 minutes, or auto mode) claims the job. If another PC got it first, the app lets it go. A benchmark is accepted and claimed later (see "The benchmark job").
5. The payload is checked (`JobPlan.cs`, by the job's kind). `shots`: the files (`DeathMuffinDebug.exe` with `DeathMuffinDebug.pck` beside it, `DeathMuffin.assets.pck` and the core library),
   the shot plan, the presets (low, medium, high, ultra) and the game options; or, instead of `files`, a `builds` list of a `before` and an `after` build, each with its own files. `clip`: see "The clip job" below.
   `bench`: see "The benchmark job" below. Anything not allowed fails the job with a readable reason.
6. The files are downloaded into the job's folder with a SHA-256 check, resuming a half download. Files with a `cacheKey` (the art pack, about 500 MB, and the
   Godot debug build, about 90 MB) are kept in `cache\<cacheKey>\` and reused by later jobs without a download; the job's game folder gets a hard link
   to them (a copy when Windows refuses).
7. For each preset it starts `DeathMuffinDebug.exe --windowed --resolution 1600x900 --audio-driver Dummy --position <X,Y> -- --dev-offline <options> --shot-plan=<plan.json>
   --shots=<job>/out/<preset> --preset=<preset>`, one preset after the other, at most 10 minutes each, each with its own empty APPDATA and LOCALAPPDATA.
8. It uploads every picture as `<preset>_<shot>.png` (at most 40, each at most 20 MB), then reports **done** with the file names, the log and the timings.
   Any failure (a download that does not match, the game stopping with an error or making no pictures, the 10 minutes, a refused upload) reports **fail** with
   a readable sentence and the end of the log. What it keeps of the game's output and of Godot's own log leaves out Godot's exit report (a debug build's list of what it never freed:
   "... were leaked at exit", "... were never freed", "Leaked instance dependency", "ObjectDB instances were leaked", "resources still in use", each with the "at:" line under it) and nothing else:
   every other ERROR and WARNING stays, so the lines that say why it failed are not pushed out of the log tail the server keeps.
9. The last 3 job folders and the 4 most recently used cache folders are kept; older ones are deleted.

Steps 1 to 3 and 6 are the same for a `clip` job (its files are a screenshots job's; 5, 7 and 8 are what "The clip job" replaces) and for a `bench` job (the claim (4) comes later for it, and 5, 7 and 8 are what "The benchmark job" replaces).

**Before and after** (`builds`). A screenshots job may carry `builds: [{label: "before", files: [...]}, {label: "after", files: [...]}]` (each label at most once) instead of `files`. Each build is checked like a
job's files (it needs its own `DeathMuffinDebug.exe` and `DeathMuffinDebug.pck`) and gets its own game folder (`game-before\`, `game-after\`). A file both builds list with the same checksum and size is downloaded
once and placed (hard link, else copy) in the second build's folder (the art pack and the Godot build also stay in the cache as for any job; two entries that give one cache name to different files are refused). The app runs every preset on each
build, the before build first, and uploads `<label>_<preset>_<shot>.png` (`before_low_hero.png`, `after_low_hero.png`). A run's pictures are in `out\<build>\<preset>\`. With more pictures than the server takes (40) every
(build, preset) run keeps the same number of its first pictures, so the pairs stay pairs.

**Window sizes** (`resolutions`). A screenshots payload may carry `resolutions`: one to four of `1920x1080`, `2560x1440`, `3840x2160` and `3440x1440` (anything else is refused; none: the one 1600x900 window as ever). The app runs
each preset on each build at each size (`--resolution WxH`, the window outside every monitor by its own width, silent), puts a run's pictures in `out\[<build>\]<preset>\<WxH>\` and uploads `<build>_<preset>_<w>x<h>_<shot>.png`
(`<preset>_<w>x<h>_<shot>.png` with no builds). Over 40 pictures every (build, preset, size) run keeps the same number of its first pictures. A size larger than the monitor may be held to the screen's by Windows: the app notes in the
log when the pictures are not the size asked for.

## The benchmark job (`bench`)

A `bench` job is a benchmark of a **release** build ("Benchmark of the new release, about 6 minutes"; the server no longer queues one by itself: the benchmark is a step of the `release` job a shipper asks for, and a `bench` job made by hand still runs): the game's own benchmark
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
- **Claimed when the PC is quiet.** Once nothing else runs and the PC has been quiet for a whole minute (the app reads it once a second): the total CPU of
  every process averaging under 15% over the minute, and through the minute no full-screen app, Death Muffin not open and the PC not on battery (a reading gap over 5 s, from sleep or a hang, starts
  the minute over), the app claims the benchmark and runs it. The keyboard and mouse do not count (Helix, 2026-10-19: the team member may keep using the PC; what skews the numbers is
  other programs' CPU). If the claim answers that the job is gone (taken, expired, cancelled) it is dropped and the tray shows the server's words; a heartbeat that offers
  nothing, or another benchmark, means the same. A claim that failed for a passing reason is tried again after 30 s.
- **Quiet again before each setup.** The files are downloaded after the claim, and before each setup the runner reads the PC the same way and waits for a quiet minute again. While it waits the status says
  what is in the way. It waits until the job's life ends (the offer's expiry, 3 days), then fails with "The PC never went quiet for long enough: ...".
- **A disturbed run** is thrown away. While the game runs the app keeps reading the PC; the run is disturbed by the other programs (every process but
  the game) using more than 20% of the CPU on average over any 30 s of it (judged once the run is 10 s old), by the player starting Death Muffin (a `DeathMuffin` or `DeathMuffinDebug`
  process that the app did not start, that runs from outside the app's folder and has not ended, seen in 3 readings in a row: a real game stays open; one whose path
  Windows will not give counts as the player's, and the job log names it with its parent process and start time) or by the cable being pulled. The game is closed,
  the setup's `bench-<i>` folder and the run's APPDATA are deleted, the app waits for a quiet minute again and starts the setup over: at most 3 tries a setup, then the job fails with
  "The benchmark on Low was disturbed 3 times (...), so no numbers were sent. Keep other programs and Death Muffin closed while it runs." A full-screen app is not a disturbance during a run (on a small screen the game's own 1600x900 window may count as one).
- **The result.** The last entry of each setup's `pending.json` (the payload the game would send, at most 64 KB; a cancelled one is no result) goes into **done** as `runs`, in setup order, all in one call:
  a setup that fails fails the job and nothing is sent. The server checks each run as it checks one a player sent and marks it as a team-PC run.
- **It asks first, like every job.** A benchmark is offered in the same box (Run now / Not now / Pause 2 hours), under the same modes and the same exceptions (`TeamLogic.Decide`: Ask accepts by itself after 5 minutes
  unless a game, a full-screen app or the battery is in the way, Run without asking, Only on a yes). The quiet wait above starts only after the yes (or the automatic start), and the box says so: "It starts once other programs
  have used little of the processor for a minute, and runs at normal priority. You can keep using the PC; a busy processor restarts it."

## The clip job (`clip`)

"Short videos of a change, about N minutes": the team asks how something moves or looks in motion ("take 3 short videos of the spell at different speeds and ask what he likes best"), the Discord agent writes a clip plan and the
values to compare, and this app records one set of clips for each value. The payload is a screenshots job's `files`, `rev` and `godotVersion`, plus:

- `plan`, the clip plan, passed to the game as `--clip-plan=<file>` (written to `plan.json`): `{"discipline": "reaper", "clips": [{"name": "wraith", "area": "graves", "cast": "haunting_wraith", "at": "pack", "enemies": 6, "seconds": 5, "camera": "follow"}]}`.
  The app checks 1 to 4 clips, each name a safe token (`^[a-z0-9][a-z0-9_-]{0,31}$`, once) and each `seconds` (when given) a number above 0 and at most 8; the game checks the rest.
- `variants`: 1 to 4 of `{label, tune}`. The label is `^[a-z0-9][a-z0-9-]{0,23}$` (once; none, or a variant without a label, is `clip`); `tune` is an object of data overrides (at most 32 KB), written to `tune-<label>.json` and passed as
  `--tune=<file>` (a variant with no tune gets no `--tune`; the game refuses a path or key it does not know with a printed line and exit code 2). No `variants` is one run labelled `clip`.
- `presets`: one graphics preset, `["high"]` when none is given. `args`: game options as for screenshots (the app refuses `--clip-plan`, `--clips`, `--tune`, `--fixed-fps`, `--preset` and the others it sets itself).

**One game run for each variant**, each with its own empty `APPDATA`/`LOCALAPPDATA` and its own `out\<label>\` folder: `DeathMuffinDebug.exe --windowed --resolution 1600x900 --audio-driver Dummy --fixed-fps 30 [--position X,Y] -- --dev-offline <options>
--preset=<preset> --clip-plan=<plan.json> --clips=<out>\<label> [--tune=<tune-label.json>]`, below normal priority, at most 10 minutes a run. `--fixed-fps 30` is the engine's: the game runs 30 frames per game second whatever the
time a frame's readback takes, so the clip's timing is the game's. The window is silent and outside every monitor, as for screenshots. The game writes `<name>.mjpeg` (one JPEG per frame, 960 px wide) and `<name>.json` (fps, frames, size, the frame the rite
was cast at; its contents go into the job's log) for each planned clip. A clip the game did not write, a run that wrote none, exit code 2 ("The game refused the clip plan or the tune for the slow variant"), another exit code, the 10 minutes or the player
starting Death Muffin fails the job with a sentence naming the variant, and nothing is uploaded unless every variant ran.

**Uploads**: after all the runs, every clip as `<label>_<clip>.mjpeg` (sorted within a variant, variants in order) with `Content-Type: video/x-motion-jpeg` (an empty clip, or one over the server's 48 MB, fails the job; each is read into memory and sent on its own),
then `done` with their names. **The server turns each into an mp4** (ffmpeg, under 8 MB for Discord) while it answers `done`: a clip it cannot turn into a video fails the job and the app shows the server's reason ("The clips were uploaded, but the server did
not accept the finished job: ..."). A request of 40 s is a heartbeat, one of 6 minutes a clip upload or a done.

## The release job (`release`)

"Checks of <revision>" (or "Checks of the live build <version>"; the box adds how long): a revision's checks on a real PC BEFORE it goes live, asked for by whoever ships it (the server's `team-check.sh`, B62; the publish's own 14-second pre-release check is one too, "Pre-release check of <version>"). It is one box and one claim; the steps run in this order, each step's result is
uploaded the moment it finishes (so a PC that stops halfway has still reported what it did), a step that fails is a result and does not stop the next one (a picture the server will not take, too big or refused, fails its step and is left out), and at the end `done` says how each step went. The server writes the
results up for whoever asked (the Discord agent's thread, or a session's thread or DM). The payload (`TeamLogic`/`JobPlan.ParseRelease`):

- `builds`: `[{label: "release", files}, {label: "debug", files}]`, the same file entries as any job. The **release** build is `DeathMuffin.exe`, `DeathMuffin.pck`, the core's DLL and `DeathMuffin.assets.pck` (what the launcher installs);
  the **debug** build of the same revision is `DeathMuffinDebug.exe` and `DeathMuffinDebug.pck` (and the art pack and core library, shared with the release build and downloaded once). Each build is fetched into its own folder
  (`game-release\`, `game-debug\`) the first time a step needs it, every file checked by SHA-256, the art pack and the Godot builds kept in `cache\`: a download that fails fails the steps that need that build, not the others.
- `steps`: any subset of `install`, `quit-loading`, `screens`, `stutter`, `bench`, `soak`; the app runs them in that order. `setups` (bench: Low and Medium, Full Party, full when absent), `screens` (`plan`: the standard shots; `resolutions`:
  up to six `WxH`, the four standard ones when absent; `uiScales`: up to three values besides the default UI scale, none when absent; `preset`: `high`), `soak` (`minutes`: 1 to 120, 30 when absent), `args` as for screenshots.

| Step | What it runs | Result file | Passes when |
|---|---|---|---|
| `install` | the RELEASE exe: `DeathMuffin.exe --windowed --resolution 1600x900 --audio-driver Dummy [--position X,Y] -- --boot-check`, below normal priority, 90 s | `install.json`: ok, `bootMs` (the game's `BOOT OK <ms>`), exit code, download seconds, the files | exit 0 and a `BOOT OK <ms>` line; the step's `ms` is the game's boot time |
| `quit-loading` | the same with `--quit-while-loading`, 20 s | `quit-loading.json`: ok, exit code, seconds, `crashReport`, `crashFiles` | exit 0 within 20 s and no `session.lock`, `crash_pending.json` or `core_crash_note.txt` (DmCrashWatch's files) left under the run's APPDATA |
| `screens` | the debug build, one run for each window size at the default UI scale and at each `uiScales` value: `--resolution WxH ... -- --dev-offline --shot-plan=<plan> --shots=<dir> --preset=<preset> [--ui-scale=<v>] --qa-window=WxH` (the size again for the game, which cannot read `--resolution`), below normal priority, off-screen and silent, 10 minutes a run | `<w>x<h>[_s<scale>]_<shot>.png` (a dot in a scale is a dash: `s1-5`) and `screens.json`: each run's size, scale, pictures, exit code and the size the pictures really are | every run exits 0 with pictures of the size asked for |
| `stutter` | the debug build: `-- --dev-offline --stutter --stutter-out=<dir>`, below normal priority, 30 minutes | `stutter.json`: the game's JSON as it wrote it (any other `*.json` in the folder if it did not use that name) | exit 0 and a result that is JSON (at most 1 MB) |
| `bench` | the release build's benchmark setups as the `bench` job runs them (normal priority, a quiet minute first, a disturbed run is thrown out and retried, 3 tries; a game that crashes after it saved its numbers keeps them, and the step fails naming the crash code and Windows' faulting module from the Application log; a run during which the PC's screen was off still counts, and its summary row says for how many seconds: `screenOffS`) | `bench.json`: a summary of each run's numbers and the runs; the runs also go to the server in `done` for the public benchmarks page (source `team`) | every setup gives a run |
| `soak` | the debug build: `-- --dev-offline --soak=<minutes> --soak-out=<dir>`, at **normal** priority after a quiet minute; the PC is read every second but nothing that happens to it throws the run out (a key, the mouse, other programs, the battery are noted); Death Muffin starting stops the whole job; the limit is the minutes plus 15 | `soak.json`: the game's JSON as written; `soak-notes.json` (when something was noted) | exit 0 and a result that is JSON |

The bench and the soak wait up to 4 hours (or the job's life) for the PC to be left alone, then fail their step and the next one runs. Every run of the game has its own empty `APPDATA`/`LOCALAPPDATA`. The flags `--boot-check`,
`--quit-while-loading`, `--stutter`, `--stutter-out`, `--soak`, `--soak-out` and `--ui-scale` are the app's (a payload may not pass them). **What the game is assumed to do** (client side, wave 3): print `BOOT OK <ms>` at its first
screen and quit 0; quit itself while loading; write the stutter and soak JSON into the folder the flag names; take `--ui-scale`; honour `--resolution` as the window size. The app reads the scenarios' JSON as opaque and uploads it. A
release job is not declined for being busy (it is queued for this PC alone); the box says the game starts several times and that the benchmark and the soak want the PC left alone; the tray says "N of M release check step(s) passed".
If the player starts Death Muffin (a game that has stayed open 3 s: one listed for a moment is not the player's), or the app closes, the job fails with the steps it had finished (`fail` carries them) and their result files stay on the server for the report.

## Folders (`%LOCALAPPDATA%\DeathMuffinTeam\`)

| What | Where |
|---|---|
| Settings (signed-in account, protected token, this PC's id, mode, pause) | `settings.json` |
| The app's own log | `app.log` (and `app.old.log`) |
| Files kept across jobs | `cache\<cacheKey>\` |
| One job | `jobs\<id>\` with `game\` (`game-before\` and `game-after\` for a screenshots job with two builds), `run-<n>\appdata\` and `run-<n>\localappdata\` (a fresh pair for each run of the game), `out\<preset>\` (`out\<build>\<preset>\` with two builds) for screenshots, `out\<variant>\` and `tune-<variant>.json` for clips, `out\screens\<w>x<h>[_s<scale>]\`, `out\stutter\` and `out\soak\` for a release job (with `game-release\` and `game-debug\`), `bench-<i>\` (a benchmark setup's `pending.json`), `plan.json`, `job.log` |

## Updating itself

The app reads `https://muffindevelopment.com/death-muffin/teamapp/version.json` (`{version, url, sha256}`, `size` optional) 30 seconds after it starts, then every 15 minutes, right after each job ends and when a job is offered (a newer app installs first and the job is offered again after the restart), never while a job runs. For a newer version it
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
`TeamApi.cs` (the login and the server's team routes behind an injectable transport; how long each kind of request may take), `TeamController.cs` (the heartbeat's long poll, offers, answers, claim, sign-in problems),
`JobRunner.cs` (download, game runs, uploads or benchmark runs, done or fail), `FileFetcher.cs` (checked, resumable downloads), `GameHost.cs` (starting the game and watching for
the player's Death Muffin), `TeamFolders.cs`, `Settings.cs`, `SelfUpdate.cs`, `Json.cs`: none of them touches Windows or WinForms, and `teamapp/tests` runs all of them.
`Platform.cs` (DPAPI, full screen and battery checks, the CPU and keyboard/mouse readings, hard links, the game's window, start with Windows), `TrayContext.cs`, `OfferBox.cs`, `AfkNotice.cs`, `SignInForm.cs`,
`Art.cs` (the launcher's look) and `Program.cs` are the Windows side.

### What only a PC can check

The compile check proves the Windows code compiles; it cannot run it. These are checked by hand on a team PC (and the app is not released to anyone before they are):
DPAPI save and load across a restart; the full-screen check (a game or film full screen hides the box and the run, and a yes still runs); the battery check on a laptop;
that the job's game window does not take the keyboard or the focus (the game is started at its normal size because Godot does not draw a minimized window); hard links into the
job folder; `APPDATA` and `LOCALAPPDATA` reaching Godot; `--preset` honoured by the debug build; the tray icon, balloons and menu; self-update on a real exe swap; and one whole
screenshot job against the server. For the release job: the release exe printing `BOOT OK <ms>` and quitting 0 with `--boot-check`, quitting itself with `--quit-while-loading` and leaving no `session.lock`; the debug build honouring `--stutter`/`--soak`/`--ui-scale`, writing their JSON where the flags say, and a 3840x2160 window off-screen on a 1080p monitor (Windows may hold it to the screen's size: the log and `screens.json` then say the pictures are smaller); a whole 40-minute job against the server and the report in #build-alerts; the soak at normal priority while the PC is touched. For the clip job: `--fixed-fps 30` honoured by the debug build with the window outside every monitor (the clips still recorded, at 30 frames per game second), the clip and tune files the game reads, a 20 to 40 MB upload on a home connection inside the 6 minutes, and the server's mp4 coming back in the thread. The
long poll against the live server through nginx (a held heartbeat ending at once for an offer, the cancel reaching a running game within a second). For the benchmark job: the total CPU reading (`GetSystemTimes`) against Task Manager and the game's share (its process's CPU time); the idle time
(`GetLastInputInfo`) counting a key or the mouse and nothing the app or the game does; the game really running at normal priority (Task Manager, Details) and the job refused when Windows will
not allow it; the game's window not counting as a full-screen app or as input; the release build honouring `--bench-quit`, `--bench-dir` and `--bench-preset` (exit codes 0, 1, 2) and leaving
`pending.json`; a disturbed run on a real PC (a busy program started during it) being discarded and retried; the box's note; and one whole benchmark job against the server, including a screenshot job interleaved with a waiting benchmark (the controller reads the PC on the interface thread once a second). Also on a real PC: `--audio-driver Dummy` really silent (loading screen and game), a screenshot job's window really never seen with `--position` left of every
monitor (and the pictures still taken: Godot and the driver draw a window that is off screen), a cancel in the heartbeat reply stopping a running game; the AFK notice (shown without taking the keyboard or the focus, End AFK mode working from it and from the tray menu).

### Changelog

- **0.4.1** (2026-10-19) - The AFK notice lists what runs (the job and its latest step, or a benchmark waiting for a quiet PC) and the queue this PC would be
  offered (how many, the first three with how long each takes, then "and N more"), from the heartbeat's new `queue` (Helix's ask); an older server sends none and the notice says nothing is queued.
- **0.4.0** (2026-10-19) - The app listens for the PC's screen going to sleep (Windows' display-state notification, a hidden window): a benchmark run says
  in the job log, and the release check's summary in `screenOffS`, how long the screen was off (Helix: are numbers from a dark screen right?).
- **0.3.9** (2026-10-19) - A benchmark game that crashes after it saved its numbers keeps them (the step fails, naming the crash code and the faulting module
  Windows recorded); a crash before that fails the step in plain words ("0xC0000374, heap corruption"). Helix's release build crashed while closing after every benchmark.
- **0.3.8** (2026-10-19) - A picture may be 20 MB (the server's new limit; a busy 3840x2160 picture passed 8 MB), and in a release check a picture the server will not
  take fails its step instead of the whole job (Helix's run stopped there before the stutter, benchmark and soak steps).
- **0.3.7** (2026-10-19) - The update check also runs right after each job ends and when a job is offered, so a new app is in place before the next job (Helix's
  release checks twice ran on the version before, which the 15-minute check had skipped while a job ran).
- **0.3.6** (2026-10-19) - The release checks' screens send the size to the game as `--qa-window=WxH` too (Godot keeps `--resolution` from the game, so the
  game could not take a size past the screen); the player's Death Muffin disturbs a benchmark run only when seen in 3 readings in a row (Helix's benchmark was still
  thrown away on 0.3.4 by a "DeathMuffin.exe" listed for a moment at the end of each run), and the job log names such a process's parent and start time; between steps and in every job a new game counts only once it has stayed open 3 s (the same process stopped the whole release check before its soak).
- **0.3.5** (2026-10-19) - The keyboard and mouse no longer hold a benchmark back or throw a run out (Helix: the PC may be in use); other programs' CPU, the
  battery, a full-screen app before the start and the player's own Death Muffin still do, and the box and the tray say so.
- **0.3.4** (2026-10-19) - The games the app starts are remembered and never counted as the player's, and a game that has already ended is not counted at all:
  a benchmark game closing (Windows no longer gives its path then) threw Helix's release benchmark away as "Death Muffin was started".
- **0.3.3** (2026-10-19) - A run nobody should see (everything but a benchmark) has its window moved outside every monitor within about 10 ms of appearing, kept there, and given no taskbar button (Helix: the Godot splash popped up, then hid).
- **0.3.2** (2026-10-19) - The release checks' screens pass the plan's class to the debug build (`--class=N`; without it no game started and every size ended with code 2), and the job log names the process a benchmark or a job counted as the player's game (name, id, path), to find why the job's own game was taken for the player's.
- **0.3.1** (2026-10-19) - The AFK notice stays on top while AFK mode is on, with a Hide button (AFK mode stays on; the tray's Show AFK notice brings it back; Helix's ask).
- **0.3.0** (2026-10-19) - The `clip` job (short videos of a change: one game run for each variant with its own tune, the engine's `--fixed-fps 30`, the clips uploaded as `<variant>_<clip>.mjpeg` for the server to turn into mp4s) and a `shots` job with a `before` and an `after`
  build (files both share are downloaded once, pictures uploaded as `<build>_<preset>_<shot>.png`), and `resolutions` for screenshots at the four standard window sizes (`<preset>_<w>x<h>_<shot>.png`). The `release` job: the release checks of a new client (install, quit-while-loading, screens, stutter, bench, soak),
  each step's result uploaded as it finishes. A job the server refuses to finish is failed with the server's reason instead of staying running. The offer box does not say a job's duration twice when the server's title already does. The heartbeat is a long poll (`wait` 25, answered at once by an offer or a cancel, the next sent right after; 5, 15, 30 s back-off on failures, at least 5 s between heartbeats
  that bring nothing new), so an offer or a cancel reaches the PC in about a second instead of up to 30. A clip is up to 48 MB and a clip job's `done` waits for the server's videos, so the HTTP limits are per request (40 s for a heartbeat, 6 minutes for a clip or a done).

- **0.2.0** (2026-10-19) - The `bench` job: the game's own benchmark of the release build, offered like any job (and, in AFK mode, accepted at once), then accepted and kept unclaimed (the PC is not busy, screenshot jobs run meanwhile) until the PC is
  quiet (a minute without input and under 15% CPU, nothing full screen, Death Muffin closed, on mains), thrown away and retried (3 tries a setup) when the PC is touched; the runs go to the server in `done`. A benchmark's game runs at normal priority and its box says so.
  Every run of the game gets its own empty `APPDATA` and `LOCALAPPDATA` (a Low run's offline save no longer starts the Ultra run). The game is silent (`--audio-driver Dummy`) and a screenshot job's window is
  started outside every monitor (`--position`). AFK mode: a box that runs out in mode Ask means you are away, and jobs then run without a box until you are back. A job the server cancels is dropped ("The job was cancelled."). Godot's exit report is left out of the logs.
- **0.1.1** (2026-10-19) - The game starts on a real PC (no `--main-pack`: the pack is named after the exe), the graphics card is reported, the update check runs every 15 minutes.
- **0.1.0** (2026-10-19) - First version: the team sign-in with the game's account name and password, the tray menu, heartbeat, the offer box and modes, the `shots` job (Low and Ultra),
  cache for the art pack and the Godot build, self-update. The team sign-in (a 90-day team token, `Authorization: Team`, nothing stored but the token, Sign out tells the server).
