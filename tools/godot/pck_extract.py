"""Extract the asset entries of a Godot 4 .pck (format 3+) into a folder; print the kept paths, sorted. Used by assets-pack.sh.
   python3 pck_extract.py <in.pck> <out dir>"""
import os, struct, sys

KEEP = ('assets/', '.godot/imported/', '.godot/exported/', '.godot/shader_cache/')

def entries(f):
    if f.read(4) != b'GDPC':
        sys.exit('not a Godot pack')
    ver = struct.unpack('<I', f.read(4))[0]
    if ver < 3:
        sys.exit('pack format %d is too old' % ver)
    f.read(12)                                   # engine major, minor, patch
    flags, base, diroff = struct.unpack('<IQQ', f.read(20))
    if flags & 1:
        sys.exit('encrypted packs are not supported')
    f.seek(diroff)
    for _ in range(struct.unpack('<I', f.read(4))[0]):
        n = struct.unpack('<I', f.read(4))[0]
        path = f.read(n).rstrip(b'\0').decode()
        off, size = struct.unpack('<QQ', f.read(16))
        f.read(20)                               # md5 + flags
        yield path[6:] if path.startswith('res://') else path, base + off, size

src, dest = sys.argv[1], sys.argv[2]
kept = []
with open(src, 'rb') as f:
    for path, off, size in list(entries(f)):
        if not path.startswith(KEEP):
            continue
        out = os.path.join(dest, path)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        f.seek(off)
        with open(out, 'wb') as o:
            left = size
            while left:
                chunk = f.read(min(left, 1 << 20)); o.write(chunk); left -= len(chunk)
        kept.append(path)
print('\n'.join(sorted(kept)))
