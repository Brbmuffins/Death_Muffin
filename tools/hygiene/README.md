# Repo hygiene check

`npm run hygiene` (also the first step of the CI `server` job) fails on references that outlived what they point at.
Output is one `file:line: message` per violation; exit 0 prints a one-line OK.

Checks (`check.mjs`, config in `retired.json`):

1. Relative Markdown links in tracked `*.md` (not `godot/tests/**`) resolve.
2. Backticked repo paths in tracked `*.md` (starting `godot/ server/ tools/ launcher/ docs/ .github/ public/ art-manifest/`, a root file, or `tests/` / `next/` meaning `godot/...`) exist. Globs, placeholders, `/abs`, `~/` paths are skipped.
3. Retired terms (`terms` in `retired.json`) do not appear in scanned text files (`*.md *.sh *.cjs *.mjs *.js *.ts *.gd *.yml *.json`, minus `scanExclude`).
4. `res://tests/<suite>/<file>.gd` and `tests/<suite>/<file>.gd` paths named in docs and scripts exist.
5. No tracked file is larger than `maxFileMB` (20) unless listed in `bigFileAllow`.
6. Texture `.import` files under the 3D asset folders (`check.mjs` `tex3d`) use `compress/mode=2`; normal maps also `compress/normal_map=1`. UI art stays lossless. `npm run hygiene -- --fix-textures` rewrites violating `.import` files; then re-import headless.
7. No call inside a GDScript `assert(...)` condition outside `godot/tests/`: release exports strip asserts together with their expression, so the call never runs in a shipped client.

## When you delete something

Add an entry to `terms` in `retired.json`: `id`, `pattern` (JS regex source; optional `flags`), `reason` (what replaced it), `allow` (globs of files that may still mention it). Then run `npm run hygiene` and fix every hit, in docs and comments, in the same change. `DECISIONS.md` may mention retired things historically.

## When a mention is legitimate

- Retired term: add a narrow path glob to that term's `allow` (a file, not a directory tree, where possible). Prefer rewording as `archive/<name>` when you mean the tag; the branch terms ignore that prefix.
- Backticked path that is intentionally absent (gitignored output, "removed" notes, "only if present" guards): add it under `allowPaths` as `"<doc>": ["<path>"]`.
- Large file: add its repo path to `bigFileAllow`.
