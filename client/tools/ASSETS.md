# Assets

How the client takes in art, models and audio. Where generated assets come from and how they are recorded: [ASSET_PIPELINE.md](../../ASSET_PIPELINE.md).

`client/assets/` holds the art, models, audio and effect data the game loads (`audio/`, `fx/`, `slice/` with the models and textures, `ui_art/` with every flat picture the windows and the HUD show, one copy each), and the game owns them: a new or changed asset is committed here with its `.import` file. How an asset gets here (models, sounds, pictures) is ASSET_PIPELINE.md
"Into the game"; the masters of older art and sound stay in `public/`.

- **Import files.** Commit the `*.import` and `*.uid` files Godot writes next to assets and scripts, and the `*.unwrap_cache` files it writes next to models it gives lightmap UV2 (they keep UV2 identical on every machine). A new 3D texture (under `slice/models/`, `slice/art/textures/`, `fx/art/` and the other 3D folders
  listed as `tex3d` in `tools/hygiene/check.mjs`) gets a seed `.import` first (VRAM compressed, mipmaps, normal maps flagged), so even a headless first import is right; `npm run hygiene` checks them. Models import with lightmap UV2 (`importer_defaults` in `project.godot`); a model that never gets a lightmap
  (creatures, the hero) may set `meshes/light_baking=1` in its `.import`.
- Scenes and resources name assets by path, never by uid (no `.tscn` or `.tres` in the project carries a `uid://`), so a new asset's uid raises no "invalid UID" warning.
- **Generated, not committed: the crowd's baked models.** `bash client/tools/bake_crowd.sh` bakes them into the baked folder under `assets/crowd/`, which the root `.gitignore` keeps out of git (client/crowd/README.md).
- **Licensed flipbook sheets** (the sheets folder under `assets/fx/`) are not in git either (`fx/README.md` "Flipbook sheets"). `bash tools/godot/fx-sheets-sync.sh [<checkout>]` copies them from `$FX_SHEETS` (default `~/death-muffin/private/fx-sheets/`) into the checkout and fails when a listed sheet is missing; run it once in a new worktree. The publish's prepare step
  (`server/death-muffin/test-channel/prepare-rebuild.sh`) runs it too, so a publish never ships without them. A build made without the private folder (CI) has no sheets and draws the plain look.
- **The assets pack.** `res://assets` ships as its own pack, `DeathMuffin.assets.pck`, which is reused while its fingerprint is unchanged: the assets, the crowd baker's inputs, the export settings, the Godot version and the pack tools (`tools/godot/assets-fp.sh`; `server/death-muffin/README.md`). The art pack carries no uid
  cache and the main pack's lists only the main pack's files, so the main pack carries the art's uids instead (`main/asset_uids.json`, written at export by
  `tools/godot/asset-uids.py` from the imported project; not in git) and `DmPacks` registers them as it loads the art pack: without them every uid
  reference inside the art (a model's textures, an effect material's shader) fell back to its path with a WARNING at load. The art pack does not change for it.
