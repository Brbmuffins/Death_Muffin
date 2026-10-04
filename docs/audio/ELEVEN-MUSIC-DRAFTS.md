# Eleven Music auditions

The workflow makes private audition tracks for five themes: the Chapterhouse, Hollow Graves, Ossuary, Cinder Pyre, and a boss fight. The generated originals stay private. Approved drafts can be prepared as game loops with `prepare-eleven-music.mjs`; see `docs/AUDIO-SOURCES.md` for the shipped asset record.

## Generate one draft

Save the ElevenLabs **secret API key** (starts with `sk_`, not the key ID) at `/home/ubuntu/death-muffin/private/elevenlabs-api-key` with file mode `0600`, or set `ELEVENLABS_API_KEY` in the process environment. Do not put the key in this repository.

```bash
node tools/audio/generate-eleven-music.mjs --list
node tools/audio/generate-eleven-music.mjs chapterhouse --dry-run
node tools/audio/generate-eleven-music.mjs chapterhouse
```

Each live run requests one instrumental cue from `music_v2_5` and saves the MP3 plus its prompt, model, timestamp, and song ID in `/home/ubuntu/death-muffin/private/music-drafts/`. Review the cue for its musical fit, then use `node tools/audio/prepare-eleven-music.mjs <cue>` to encode a loop. The game has a dedicated Music volume control and transition rules.

## Release rights

ElevenLabs' [Music Model-Specific Terms](https://elevenlabs.io/eleven-music-model-specific-terms) currently exclude “Studio Games” from Creator media rights. Their definition includes a monetized game available through more than one platform. Death Muffin's browser and Windows launcher distribution make its monetization status relevant. The owner confirmed on 2026-10-04 that the game is not currently monetized. Recheck rights if that changes. The [Compose Music API](https://elevenlabs.io/docs/api-reference/music/compose) documents the request fields used by the script.
