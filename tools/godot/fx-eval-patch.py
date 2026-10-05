#!/usr/bin/env python3
"""Eval-only fix for a vendor defect: some Binbun scenes/materials embed a CompressedTexture2D sub-resource whose load_path points at
the author's machine-specific .godot/imported cache file. Rewrites them (in the private extracted copy only) into ext_resources of the
source png. Usage: fx-eval-patch.py /home/ubuntu/death-muffin/private/binbun"""
import os, re, sys
root = sys.argv[1]
pngs = {}
for dp, _, fs in os.walk(root):
    for f in fs:
        if f.endswith('.png'):
            pngs.setdefault(f, []).append(os.path.join(dp, f))
n = 0
for dp, _, fs in os.walk(root):
    for f in fs:
        if not f.endswith(('.tscn', '.tres')):
            continue
        p = os.path.join(dp, f)
        s = open(p, encoding='utf-8', errors='replace').read()
        pat = re.compile(r'\[sub_resource type="CompressedTexture2D" id="([^"]+)"\]\nload_path = "res://\.godot/imported/([^"]+?\.png)-[0-9a-f]+(?:\.s3tc|\.etc2)?\.ctex"\n\n?')
        if not pat.search(s):
            continue
        pack = p[len(root):].lstrip('/').split('/')[0]
        adds = []
        def rep(m):
            sid, name = m.group(1), m.group(2)
            cands = [c for c in pngs.get(name, []) if c[len(root):].lstrip('/').split('/')[0] == pack]
            if not cands:
                return m.group(0)
            res = 'res://' + os.path.relpath(cands[0], os.path.join(root, pack))
            adds.append((sid, res))
            return ''
        s2 = pat.sub(rep, s)
        for sid, res in adds:
            s2 = re.sub(r'SubResource\("%s"\)' % re.escape(sid), 'ExtResource("fixed_%s")' % sid, s2)
        hdr_end = s2.index('\n') + 1
        ins = ''.join('[ext_resource type="Texture2D" path="%s" id="fixed_%s"]\n' % (res, sid) for sid, res in adds)
        # ext_resources must precede sub_resources: insert right after the header line
        s2 = s2[:hdr_end] + ('\n' if not s2[hdr_end:].startswith('[ext_resource') else '') + ins + s2[hdr_end:]
        open(p, 'w').write(s2)
        n += 1
print('patched', n)
