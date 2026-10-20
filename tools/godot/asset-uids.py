"""Write <project>/main/asset_uids.json: the uid of every res://assets file, read from the imported project's .godot/uid_cache.bin.
   python3 tools/godot/asset-uids.py <project dir>
The game's art ships in its own pack (DeathMuffin.assets.pck, assets-pack.sh), which carries no uid cache, and the main pack's cache lists only
the main pack's files: so every uid reference inside the art (a model's textures, an effect material's shader) fell back to its path with a
WARNING at load. DmPacks registers these ids after it loads the art pack. Run after the import and before the main export
(publish-godot-client.sh, discord-agent/preview-godot.sh); the file is generated, never committed (.gitignore). The art pack itself does not
change, so the launcher keeps reusing it. Ids are written as decimal strings (JSON numbers would lose 64-bit precision)."""
import json, os, struct, sys

proj = sys.argv[1]
src = os.path.join(proj, '.godot', 'uid_cache.bin')
with open(src, 'rb') as f:
    data = f.read()
count = struct.unpack_from('<I', data, 0)[0]
pos = 4
ids = {}
for _ in range(count):
    uid, n = struct.unpack_from('<qI', data, pos)
    pos += 12
    path = data[pos:pos + n].rstrip(b'\0').decode()
    pos += n
    if path.startswith('res://assets/') and uid > 0:
        ids[path] = str(uid)
if not ids:
    sys.exit('asset-uids: no res://assets entries in %s (is the project imported?)' % src)
out = os.path.join(proj, 'main', 'asset_uids.json')
with open(out, 'w') as f:
    json.dump(dict(sorted(ids.items())), f, separators=(',', ':'))
print('asset uids: %d written to %s' % (len(ids), os.path.relpath(out, proj)))
