# Repo hygiene check

`npm run hygiene` (also the first step of the CI `server` job) fails on references that outlived what they point at.
Output is one `file:line: message` per violation; exit 0 prints a one-line OK.

Checks (`check.mjs`, config in `retired.json`):

1. Relative Markdown links in tracked `*.md` (not `client/tests/**`) resolve.
2. Backticked repo paths in tracked `*.md` (starting `client/ native/ server/ tools/ launcher/ teamapp/ docs/ .github/ public/ art-manifest/`, a root file, or `tests/` / `next/` meaning `client/...`) exist. Globs, placeholders, `/abs`, `~/` paths are skipped. `DECISIONS.md` records what was true when each decision was made, so its paths may name files that are gone (`historyDocs` in `retired.json`).
3. Retired terms (`terms` in `retired.json`) do not appear in scanned text files (`*.md *.sh *.cjs *.mjs *.js *.ts *.gd *.yml *.json`, minus `scanExclude`).
4. `res://tests/<suite>/<file>.gd` and `tests/<suite>/<file>.gd` paths named in docs and scripts exist under `client/`.
5. No tracked file is larger than `maxFileMB` (20) unless listed in `bigFileAllow`.
6. Texture `.import` files under the 3D asset folders (`check.mjs` `tex3d`, in `client/assets/` and `client/world_fx/assets/`) use `compress/mode=2`; normal maps also `compress/normal_map=1`. UI art stays lossless. `npm run hygiene -- --fix-textures` rewrites violating `.import` files; then re-import headless (`godot --headless --path client --import`).
7. No call inside a GDScript `assert(...)` condition in `client/` outside the test folders: release exports strip asserts together with their expression, so the call never runs in a shipped client.
8. The suite list matches the suite files: every `client/tests/<name>.gd` and `client/tests/<name>/run.gd` is in `SUITES` of `tools/rebuild/run-client-tests.sh` (a suite nobody lists never runs, in CI or anywhere), every `SUITES` name has a file, and every `PACED`, `LANE` and `WAITING` name is in `SUITES`. A file that is a helper or a by-hand rendered smoke, not a suite, is listed with its reason in `notSuites` in `retired.json`.
9. The Discord agent's path rules name real paths: every glob in `tiers` and `forbiddenPaths` of `server/death-muffin/discord-agent/runner/lib/config.cjs` (loaded from the module) has a fixed leading part (the segments before the first wildcard) that is a tracked path, and a glob with no wildcard exists itself; globs with no fixed part (`**/.env*`) are skipped. A renamed folder would otherwise silently stop protecting and drop a change to a lower approval tier: update `config.cjs` in the same change as the rename. A glob that is stale on purpose or waiting for a fix is listed with its reason in `staleGlobs` in `retired.json`.
10. No paid or foreign GitHub machines: every `runs-on` in `.github/workflows/*.yml` is one of the standard GitHub-hosted labels (`freeRunners` in `retired.json`: `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-22.04`, `windows-latest`, `windows-2025`, `windows-2022`), free for this public repo. A larger runner (a custom label) can cost money and `self-hosted` runs on someone's own machine, so both fail, and so does any `${{ }}` expression unless it is `matrix.<key>` with every value written out literally in the same workflow. Adding a label means deciding it is free first.
11. Navigation (`tools/context/navigation.mjs`, called from here; tools/context/README.md "Navigation check"): README.md's "Documentation map" and its links, every old section of the client manual still answered by its anchor in `client/README.md` and its new home (`tools/context/doc-moves.json`), and every Markdown link (fragment included: GitHub's heading slugs and explicit `<a id>` anchors) or quoted section reference (`path.md "Label"`) into those files. Check 1 strips fragments; this one does not, but only for that scope. An old section name of `client/README.md` in a reference fails unless the file is in `kept` there, with its reason.

## When you delete something

Add an entry to `terms` in `retired.json`: `id`, `pattern` (JS regex source; optional `flags`), `reason` (what replaced it), `allow` (globs of files that may still mention it). Then run `npm run hygiene` and fix every hit, in docs and comments, in the same change. `DECISIONS.md` may mention retired things historically.

## When a mention is legitimate

- Retired term: add a narrow path glob to that term's `allow` (a file, not a directory tree, where possible). Prefer rewording as `archive/<name>` when you mean the tag; the branch terms ignore that prefix.
- Backticked path that is intentionally absent (gitignored output, "removed" notes, "only if present" guards): add it under `allowPaths` as `"<doc>": ["<path>"]`, or name it in words without backticks (the docs say "the baked folder" for the generated crowd models).
- Large file: add its repo path to `bigFileAllow`.
