# Making a new sound effect or music track (ElevenLabs)

You cannot call ElevenLabs yourself and you never see its key; the runner generates. Use this when someone asks for a NEW sound or track (a spell sound,
a scream, an ambience loop, a piece of music), or explicitly asks for ElevenLabs. Prefer an existing clip only when the asker did not ask for a new one.
You ask by writing two small files, then you stop and say what you asked for:
1. `audio-manifest/eleven/<id>.json`: `{"id": "<id>", "kind": "sfx", "prompt": "...", "duration_seconds": 2.5, "variants": 3}`.
   sfx: `duration_seconds` 0.5 to 30, `variants` 1 to 4 (default 1), optional `"loop": true` (seamless loop, for beds) and `"prompt_influence"` 0 to 1 (default 0.4).
   music: `{"id": "<id>", "kind": "music", "prompt": "...", "duration_seconds": 60}` (10 to 180 s, `variants` 1 or 2, always instrumental).
   Describe the sound itself (source, texture, attack, tail, space), say what must NOT be in it (music, voices, words), and keep game one-shots short (0.5 to 3 s).
   For a sound people will pick from, ask for 2 or 3 variants. `<id>` is lower-case letters, digits and underscores (3 to 40), and not already used in `audio-manifest/eleven/`.
2. `.dm-sound-request.json` (never commit it): `{"id": "<id>", "note": "one plain sentence on what this is for"}`.
Only the people the runner allows can generate; for them it starts right away, with no credit check. End your reply with one line saying what you asked for.
The runner posts the takes in the thread and then tells you the files are ready: run `__TOOLS__/build-sound.sh <id> <take>` (it levels the take to the game's loudness and writes
`client/assets/audio/eleven/<id>.wav`, or `.mp3` for music, and the sound's row in `docs/AUDIO-SOURCES.md`, the licence record), wire it in where the request asked
(`client/audio/README.md`), commit the spec, the asset and `docs/AUDIO-SOURCES.md`, run `__TOOLS__/check-godot.sh --rerun code_load` (commit the `.import` file it writes),
then the usual proposal. `audio-src/` is git-ignored raw output: never commit it. One sound per request.
