# Death Muffin Windows launcher

A small native launcher for Death Muffin. Windows Forms (.NET Framework 4.8, already part of Windows 10/11): no installer, no
separate runtime. Since 0.6.0 it launches and updates the **Godot client** (`DeathMuffin.exe` + `DeathMuffin.pck`) instead of
hosting the web game in WebView2.

## For players

1. Download `DeathMuffinLauncher-win-x64.zip` from the
   [latest release](https://github.com/Brbmuffins/Death_Muffin/releases/latest/download/DeathMuffinLauncher-win-x64.zip)
   and unzip it anywhere (keep the files together).
2. Run `DeathMuffinLauncher.exe`.
3. **Updating the launcher is manual for now:** download the new zip and replace the old folder. The *game* updates from inside
   the launcher (below). Your saves are not in that folder.

### What the launcher does

- **One button that changes with the state** (bottom left). Death Muffin is online-only, so there is a single play path:
  **DOWNLOAD GAME** (nothing installed yet: saves the game to this PC, size shown) ->
  **PLAY** (installed: starts the game) ->
  **UPDATE GAME** (a newer build is on the server; a small "Play the installed version instead" link keeps you playing) ->
  **DOWNLOADING 42%** (progress bar, button disabled) -> **RETRY DOWNLOAD** if it stopped, **GAME RUNNING** while it is open.
  It never opens a web page: everything comes from the launcher.
- **Downloads are checked and safe.** The server's `manifest.json` lists every file with its SHA-256. The launcher downloads into
  `%LOCALAPPDATA%\DeathMuffin\client\.staging-<version>`, checks the size and SHA-256 of every file, retries each file up to 4
  times, resumes partial files (HTTP Range) after a dropped connection or a launcher restart, reuses files that did not change
  from the installed build, and only then swaps the folder in with one rename. A failed or cancelled update never touches the
  installed build, which keeps working (also with no internet). The previous build is kept for one generation, older ones are removed.
- **PLAY is never blocked by the online lock.** The game itself checks access at sign-in and shows its own message, so the launcher
  only adds a note under the button. It reads `online.enabled` / `online.staff` / `online.message` from `manifest.json`
  (re-checked about once a minute, no launcher update needed). Online counts as open only for a literal `enabled: true`; in every other
  case (false, staff-only mode, unreadable manifest) the note shows the manifest message ("Online opens soon" if blank). With no
  internet the note is "No internet connection: the game needs it to sign in." and PLAY stays enabled if the game is installed.
- **Game arguments.** The launcher starts `DeathMuffin.exe -- --online`. The game starts online with no arguments and ignores
  `--online` / `--offline`; the flag is passed only to be explicit. The launcher never passes `--offline` or the developer-only
  `--dev-offline`. Everything after `--` is for the game (`OS.get_cmdline_user_args()` in Godot).
- **World Dispatch** shows the newest release's patch notes (`play/release-notes.json`) in a scrollable box, with an **All patch
  notes** link that opens an in-launcher window (`play/patch-notes.json`). Releases without notes fall back to the commit subjects.
- **One game at a time.** While the game is open the button reads GAME RUNNING and the status panel says so.
- **No internet:** the update check says so; **PLAY** still works if the game is installed (the game shows its own sign-in error),
  otherwise one download while online is needed first. The launcher re-checks once a minute and when Windows reports a network change.
- **Use high-performance GPU** (default on) is in Client Settings. It writes Windows' per-app graphics preference for the installed
  `DeathMuffin.exe` (`HKCU\Software\Microsoft\DirectX\UserGpuPreferences`, `GpuPreference=2`) just before each launch, and removes it when
  unticked. It is the same switch as Windows Settings > System > Display > Graphics.
- The launcher checks GitHub for a newer launcher and shows a link (the only browser launch, since an exe cannot replace itself).

### Where things live

| What | Where |
|---|---|
| Installed game builds | `%LOCALAPPDATA%\DeathMuffin\client\<version>\` (+ `current.json` naming the active one) |
| Launcher settings (GPU toggle) | `%LOCALAPPDATA%\DeathMuffin\launcher-settings.json` |

Delete the `client` folder to force a clean re-download. The old web-offline save (`LauncherProfile`, from launcher 0.5.x) is no longer used
and can be deleted.

## Server side (client files and the online lock)

Published by [`server/death-muffin/publish-godot-client.sh`](../../server/death-muffin/publish-godot-client.sh) `<git-rev>` to
`/var/www/death-muffin/client/`, served at `https://muffindevelopment.com/death-muffin/client/`:

```json
{
  "version": "20261004.153012-ab12cd3",
  "built_at": "2026-10-04T15:30:12Z",
  "rev": "ab12cd3ef456",
  "files": [
    { "path": "DeathMuffin.exe", "size": 109268480, "sha256": "...", "url": "https://muffindevelopment.com/death-muffin/client/20261004.153012-ab12cd3/DeathMuffin.exe" },
    { "path": "DeathMuffin.pck", "size": 165013164, "sha256": "...", "url": "..." }
  ],
  "online": { "enabled": false, "message": "Online opens soon" }
}
```

`version` sorts by its dotted number (a newer build is always `UPDATE`; the launcher never downgrades). `url` must be on the same
host as the manifest. Each build lives in its own `<version>/` folder and `manifest.json` is written last, atomically, so players
mid-download are never served mixed files. Republishing keeps the current `online` block. Devs open or close online sign-in with
[`set-online.sh`](../../server/death-muffin/set-online.sh) `on|off ["message"]` (only the `online` block changes). Only a literal
JSON `true` counts as open.

The launcher does not gate PLAY on `online`: the game enforces it at sign-in (`online.enabled: true` opens it to everyone).

## Build (developers)

Needs the .NET SDK (8 or newer) and NuGet access for the reference assemblies. The project targets .NET Framework 4.8 and
uses `Microsoft.NETFramework.ReferenceAssemblies`, so it also compiles on Linux/macOS (it only runs on Windows). There are no
native dependencies any more (WebView2 was removed in 0.6.0).

```powershell
dotnet build launcher/windows/DeathMuffinLauncher.csproj -c Release
dotnet run --project launcher/tests        # logic tests (manifest, versions, hashes, button states, online note, installer)
```

Output: `launcher/windows/bin/Release/net48/DeathMuffinLauncher.exe`. The version is `<Version>` in the csproj. Without an SDK,
`launcher/tests/run-local.sh` runs the same tests with a .NET 8 runtime and a Roslyn `csc.dll`.

The [Windows launcher workflow](../../.github/workflows/launcher-windows.yml) builds on `windows-latest` for pushes touching
`launcher/**` (and manual runs), uploads `DeathMuffinLauncher-win-x64.zip` as an artifact and, from `main` or a manual
run, attaches it to a GitHub Release tagged `launcher-v<version>`. Releases are built from `main`. Bump `<Version>` (currently 0.7.0) for each new launcher release.

Code map: `ClientLogic.cs` (manifest parsing, version compare, hashing, online note, button state machine; no UI),
`ClientInstaller.cs` (download/verify/resume/swap and the install folder), `Updates.cs` (server requests), `LauncherForm.cs`
(UI, launching the game), `PatchNotesWindow.cs`, `Art.cs`.

## Window

Launcher source is this folder only. The window uses the game's key art (`Resources/keyart.jpg`, embedded) inside a painted indigo
frame, with a command bar, a World Dispatch panel and a status column.

### Changelog

- **0.7.0** - One play path: online. A single Download / Play / Update button; the separate Play Online button, the offline edition wording and the online/offline one-session prompt are gone. Always launches with `-- --online`. An unopened online (or no internet) only adds a note under PLAY.
- **0.6.0** - Launches the Godot client. One Download / Update / Play offline button (SHA-256 verified, resumable, atomic swap into `%LOCALAPPDATA%\DeathMuffin\client\<version>`), Play Online built but locked by `online.enabled` in the server manifest, GPU preference via Windows per-app setting. Removed WebView2, the web game windows, the precache and the web offline edition.
- **0.5.1** - Online and offline made explicit: three always-visible buttons (Play online, Download offline, Play offline), saved offline download state and build, one-session rule with a confirm, no-internet state, in-launcher patch notes, launcher self-update check; the download is started by the offline page's `?download=1` instead of clicking its button.
- **0.5.0** - MMO-style frame, command bar, World Dispatch panel.
