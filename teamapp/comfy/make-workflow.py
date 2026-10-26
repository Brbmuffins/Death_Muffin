#!/usr/bin/env python3
"""make-workflow.py <ComfyUI url> [out.json]: writes the team app's model workflow (teamapp/comfy/image-to-model.json) from ComfyUI's own
"Pixal3D & TRELLIS.2: Image to Model" template, read from a running ComfyUI together with its node definitions (teamapp/README.md "The model job").

The template is in the editor's format; ComfyUI's /prompt takes the API format: node id -> {class_type, inputs}, an input either a value or
[source node id, output index]. Only the nodes the saved model needs are kept, and the preview nodes on the way (they pass their input
through) are bridged, so the run does no preview work and needs no preview passthrough (older ComfyUI versions have none). `slots` names
the inputs the app fills in for each run; each is checked against the node definitions here, so a changed template fails now, not on a PC.
"""
import json, sys, urllib.request

TEMPLATE = '3d_pixal3d_trellis2_image_to_model'
PASS_THROUGH = {'PreviewImage', 'MaskPreview'}
UI_ONLY = {'control_after_generate', 'upload', 'fixed'}   # editor widgets that are not node inputs


def get(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def main():
    base = sys.argv[1].rstrip('/')
    out = sys.argv[2] if len(sys.argv) > 2 else 'image-to-model.json'
    tpl, info, stats = get(f'{base}/templates/{TEMPLATE}.json'), get(f'{base}/object_info'), get(f'{base}/system_stats')
    nodes = {n['id']: n for n in tpl['nodes']}
    links = {l[0]: (l[1], l[2]) for l in tpl['links']}

    def source(link_id):   # (node, output) feeding a link, through any preview node
        node, slot = links[link_id]
        while nodes[node]['type'] in PASS_THROUGH:
            node, slot = links[next(i['link'] for i in nodes[node]['inputs'] if i.get('link') is not None)]
        return node, slot

    save = [n for n in tpl['nodes'] if n['type'] == 'Save3DAdvanced']
    if len(save) != 1:
        sys.exit(f'expected one Save3DAdvanced node, found {len(save)}')
    prompt, todo = {}, [save[0]['id']]
    while todo:
        nid = todo.pop()
        if str(nid) in prompt:
            continue
        n = nodes[nid]
        d = info.get(n['type'])
        if d is None:
            sys.exit(f'node {nid}: {n["type"]} is not a node this ComfyUI knows')
        spec = {**d['input'].get('required', {}), **d['input'].get('optional', {})}
        inputs = {k: v for k, v in (n.get('widgets_values_named') or {}).items()
                  if k not in UI_ONLY and (k in spec or k.split('.')[0] in spec)}
        for i in n.get('inputs', []):
            if i.get('link') is None:
                continue
            src, slot = source(i['link'])
            inputs[i['name']] = [str(src), slot]
            todo.append(src)
        missing = [k for k in d['input'].get('required', {}) if k not in inputs]
        if missing:
            sys.exit(f'node {nid} ({n["type"]}) lacks required inputs {missing}')
        prompt[str(nid)] = {'class_type': n['type'], 'inputs': inputs, '_meta': {'title': n.get('title') or n['type']}}

    def one(cls, inp, where=None):   # the single node of a class (or the one whose input feeds `where`) and its input, checked
        found = [k for k, v in prompt.items() if v['class_type'] == cls and (where is None or where(k, v))]
        if len(found) != 1:
            sys.exit(f'expected one {cls} node for slot {inp}, found {found}')
        if inp not in prompt[found[0]]['inputs'] or isinstance(prompt[found[0]]['inputs'][inp], list):
            sys.exit(f'{cls} {found[0]} has no plain input {inp}')
        return [found[0], inp]

    def feeds(cls, inp):
        return lambda k, v: any(p['class_type'] == cls and p['inputs'].get(inp, [None])[0] == k for p in prompt.values())

    slots = {
        'image': [one('LoadImage', 'image')],
        'trellis2': [one('PrimitiveBoolean', 'value', feeds('ComfySwitchNode', 'switch'))],
        'faces': [one('DecimateMesh', 'target_face_count')],
        'texture': [one('PrimitiveInt', 'value', feeds('BakeTextureFromVoxel', 'texture_size')), one('BakeNormalMapFromMesh', 'resolution')],
        'seed': sorted([k, 'seed'] for k, v in prompt.items() if v['class_type'] == 'KSampler'),
        'prefix': [one('Save3DAdvanced', 'filename_prefix')],
    }
    seeds = {k: prompt[k]['inputs']['seed'] for k, _ in slots['seed']}
    doc = {
        'about': f'ComfyUI {stats["system"]["comfyui_version"]}, template {TEMPLATE} (templates {stats["system"].get("installed_templates_version")}); '
                 'made by teamapp/comfy/make-workflow.py. A seed slot adds the run\'s seed to the value the template has.',
        'save': slots['prefix'][0][0],
        'slots': slots,
        'seedBase': seeds,
        'prompt': prompt,
    }
    with open(out, 'w') as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write('\n')
    print(f'{out}: {len(prompt)} nodes, save node {doc["save"]}, seeds {seeds}')


if __name__ == '__main__':
    main()
