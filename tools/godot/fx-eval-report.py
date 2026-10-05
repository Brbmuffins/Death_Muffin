#!/usr/bin/env python3
"""Merge godot/shots/fx_eval/data/*_{static,perf}.json + logs into effects.json (+ effects.csv) with cost tiers.
usage: tools/godot/fx-eval-report.py"""
import json, glob, os, re, csv
D = os.path.join(os.path.dirname(__file__), '..', '..', 'godot', 'shots', 'fx_eval', 'data')
rows = []
for sf in sorted(glob.glob(D + '/*_static.json')):
    pack = os.path.basename(sf)[:-12]
    st = json.load(open(sf))
    pf = {}
    pp = os.path.join(D, pack + '_perf.json')
    if os.path.exists(pp):
        pf = json.load(open(pp))
    # per-effect stderr errors between @@FX markers
    errs = {}
    for suffix in ('static', 'perf', 'shots'):
        lp = os.path.join(D, f'{pack}_{suffix}.log')
        if not os.path.exists(lp):
            continue
        cur = None
        for line in open(lp, errors='replace'):
            if line.startswith('@@FX '):
                cur = line[5:].strip()
            elif cur and ('ERROR' in line) and 'backtrace' not in line:
                errs.setdefault(cur, set()).add(line.strip()[:140])
    for path, e in st.items():
        r = {'pack': pack, 'name': os.path.basename(path)[:-5], 'path': path.replace('res://assets/', '')}
        r.update({k: e.get(k) for k in ('kind', 'duration', 'amount', 'emitters', 'mesh_count', 'draw_nodes', 'alpha_area_m2', 'trails', 'subemitters', 'tex_samples', 'lights', 'uses_screen', 'uses_depth', 'uses_stencil', 'static_score', 'aabb')})
        r['max_particle_life'] = e.get('max_particle_life')
        p = pf.get(path)
        if p:
            b = p['base']
            for n in ('x1', 'x10'):
                m = p[n]
                r[n + '_ms'] = round(m['ms_mean'] - b['ms_mean'], 1)
                r[n + '_dc'] = m['draw_calls'] - b['draw_calls']
                r[n + '_obj'] = m['objects'] - b['objects']
                r[n + '_prim'] = m['prims'] - b['prims']
        r['errors'] = sorted(errs.get(path, []))
        rows.append(r)
json.dump(rows, open(os.path.join(D, 'effects.json'), 'w'), indent=1)
print(len(rows), 'effects;', sum(1 for r in rows if 'x10_ms' in r), 'with perf')
