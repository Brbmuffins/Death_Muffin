# Death Muffin Windows launcher

A small native launcher for the [Death Muffin](../../README.md) web game. Windows Forms (.NET Framework 4.8, already part
of Windows 10/11) hosts the game in a dedicated window using the Microsoft Edge WebView2 Runtime. No browser tab, no
installer, no separate Java or .NET download.

## For players

1. Download `DeathMuffinLauncher-win-x64.zip` from the
   [latest release](https://github.com/Brbmuffins/Death_Muffin/releases/latest/download/DeathMuffinLauncher-win-x64.zip)
   and unzip it anywhere (keep the files together).
2. Run `DeathMuffinLauncher.exe`.
3. **Updating the launcher is manual for now:** download the new zip and replace the old folder. The *game* updates itself
   (below). Your saves are not in that folder.

### What the launcher does

- **Play Online** in the command bar opens the live game at `https://muffindevelopment.com/death-muffin/play/` in its own window. Log in
  normally; the launcher never sees your password.
- **Update check (Jagex-launcher style).** On start it reads `play/release.txt` (the live build). If that build is newer than
  the one it last prepared, it shows **Update available** with a progress bar while a hidden page
  (`play/precache.html`) downloads the game's files into the launcher's cache. **Play is usable the whole time**; this only
  makes the first load after an update faster. If it fails or you are offline, nothing is lost.
- **World Dispatch** shows the newest release's patch notes (`play/release-notes.json`, written by the deploy script from the hand-written `PATCH_NOTES.json` at the repo root) in a scrollable box, with an **All patch notes** link to the site's patch-notes page. Releases without notes fall back to the commit subjects.
- **Three always-visible buttons.** **PLAY ONLINE** (the live game, needs internet), **DOWNLOAD OFFLINE** (saves the offline edition, about
  105 MB, with progress; afterwards it shows "Downloaded" with the date/build and reads **UPDATE OFFLINE COPY** when a newer offline
  build is live, otherwise **DOWNLOAD AGAIN**, which re-checks the copy) and **PLAY OFFLINE** (disabled until downloaded). The offline
  edition uses the same Death Muffin account and character; progress syncs when you are next online.
- **One session at a time.** Online and offline both sign in to your account and would sign each other out, so opening one while the
  other is open asks "Close the ... game first?" and closes the other. The status panel says which mode is running.
- **No internet:** PLAY ONLINE is disabled with "No internet connection", PLAY OFFLINE is highlighted if downloaded (otherwise one
  download while online is needed first). The launcher re-checks every 20 s and when Windows reports a network change.
- **Everything inside the launcher.** Games open in the launcher's own windows; **All patch notes** opens an in-launcher window; the
  launcher checks GitHub for a newer launcher and shows a link (the only browser launch, since an exe cannot replace itself). The
  browser is used only when WebView2 is missing or will not start, and the status line says so.
- **Use high-performance GPU** (default on) is in Client Settings - see flags below. Changing it takes effect the next time the launcher starts.

### Performance flags

The game window passes these Chromium switches to WebView2 (`CoreWebView2EnvironmentOptions.AdditionalBrowserArguments`):

| Flag | Why |
|---|---|
| `--force_high_performance_gpu` | On laptops with two GPUs (integrated + discrete) Windows may give WebView2 the weak one; this asks Chromium for the high-performance adapter. Only added when the checkbox is on. |
| `--disable-background-timer-throttling` | Chromium slows JS timers in pages it considers hidden; the game's co-op/network timers should keep firing if the window is behind another. |
| `--disable-renderer-backgrounding` | Stops Chromium lowering the renderer process's priority when the window is not focused (keeps the game from stuttering when you alt-tab to chat or a guide). |
| `--disable-backgrounding-occluded-windows` | Same idea for a window that is covered by other windows. |

These are standard Chromium switches. Microsoft documents WebView2 browser flags as unsupported for production (they can
change between Edge versions), so every flag here is harmless if a future runtime ignores it. The persistent profile also
keeps the shader cache and HTTP cache between sessions, which is where most of the "second launch is faster" comes from.
Nothing here changes the game itself: the launcher adds no code to the web bundle.

### WebView2 Runtime (and the browser fallback)

Windows 11 and current Windows 10 already include it. The launcher only reports it missing when WebView2 itself says so *and*
the registry (EdgeUpdate) has no runtime either; any other failure (usually the exe run from inside the zip, so its DLLs are
not next to it) is reported as **launcher files missing - unzip the whole folder**.

Without a working WebView2 the launcher still plays: **Play Online / Download Offline / Play Offline open the game in Chrome, Edge or
Brave as an app window (`--app`), or in the default browser (e.g. Firefox)** if none of those is installed. The same happens
if the game window fails to start WebView2. In that mode there is no update pre-download and the performance flags below do
not apply (the browser uses its own settings). To get the dedicated game window, install the **Evergreen
Standalone/Bootstrapper** from <https://developer.microsoft.com/en-us/microsoft-edge/webview2/> and restart the launcher.

### Where things live

| What | Where |
|---|---|
| WebView2 profile (offline edition save + local player, HTTP/shader cache, cookies) | `%LOCALAPPDATA%\DeathMuffin\LauncherProfile` |
| Launcher settings (GPU toggle, last prepared build, offline downloaded flag/build/date) | `%LOCALAPPDATA%\DeathMuffin\launcher-settings.json` |

Back up `LauncherProfile` before clearing app data or replacing your Windows profile: the offline edition's local save lives
there. Online accounts are stored on the server. Online and offline saves stay separate unless you use the game's
**Sync complete save** while connected. Deleting `launcher-settings.json` makes the next start re-prepare the update.

## Build (developers)

Needs the .NET SDK (8 or newer) and NuGet access for `Microsoft.Web.WebView2`. The project targets .NET Framework 4.8 and
uses `Microsoft.NETFramework.ReferenceAssemblies`, so it also compiles on Linux/macOS (it only runs on Windows).

```powershell
dotnet build launcher/windows/DeathMuffinLauncher.csproj -c Release
```

Output: `launcher/windows/bin/Release/net48/` (`DeathMuffinLauncher.exe`, the two WebView2 managed DLLs and
`runtimes/*/native/WebView2Loader.dll`). The version is `<Version>` in the csproj.

The [Windows launcher workflow](../../.github/workflows/launcher-windows.yml) builds on `windows-latest` for pushes touching
`launcher/**` (and manual runs), uploads `DeathMuffinLauncher-win-x64.zip` as an artifact and, from `master` or a manual
run, attaches it to a GitHub Release tagged `launcher-v<version>`. Bump `<Version>` for each new launcher release.

## How the web side fits

- `npm run build:death-muffin` also runs `tools/build-asset-manifest.mjs`, writing `dist/asset-manifest.json` (sorted file
  list with sizes: hashed bundles plus models/art/audio/fx; deterministic, no timestamps).
- `public/precache.html` is a tiny standalone page (no game code): it fetches the manifest, fetches each file with 4 in
  flight and posts `dm-precache:<done>/<total>` to the launcher, then `dm-precache-done:ok`. It uses the default cache
  mode, so unchanged files are revalidated (the server sends `no-cache` + ETag) and answer 304 instead of re-downloading.
  It does not touch the game's own release auto-refresh.
- `server/death-muffin/deploy-release.sh` publishes `precache.html` and `asset-manifest.json` with the assets, and
  `release-notes.json` (`{ sha, date, title, items, commits }`: the newest `PATCH_NOTES.json` entry, or the commit subjects since the previous live release) and `patch-notes.json` (the notes history, for `site/patch-notes.html`) after `index.html`, next to `release.txt`.
- **Every release: add an entry at the top of `PATCH_NOTES.json`** (`date`, `title`, short player-facing `items`) before running `deploy-release.sh`.
  `index.html`, next to `release.txt`.

Launcher source is this folder only; the old prototype's source was lost, so this is a clean rebuild of its behaviour. The
window uses the game's key art (`Resources/keyart.jpg`, embedded) inside a painted indigo frame. Version 0.5.0 introduces a
command bar with a prominent Play Online action, separate offline actions, and a scrollable World Dispatch panel.

### Changelog

- **0.5.1** - Online and offline made explicit: three always-visible buttons (Play online, Download offline, Play offline), saved offline download state and build, one-session rule with a confirm, no-internet state, in-launcher patch notes, launcher self-update check; the download is started by the offline page's `?download=1` instead of clicking its button.
- **0.5.0** - MMO-style frame, command bar, World Dispatch panel.
