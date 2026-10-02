"""
skinview.py - render a rig as coloured skin weights (each vertex coloured by its strongest vertex group) plus bone lines:
  blender -b --python skinview.py -- <rig_or_anim.glb> <out_prefix> [--frame N] [--views side,front,top] [--size 900]
Writes <out_prefix>_<view>.png. With an animated GLB and --frame the pose at that frame is shown (skinning check).
Cycles on the CPU with an emission shader; no GPU or display needed. Used to read what a Tripo rig really skins.
"""
import colorsys
import math
import os
import sys
import zlib

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402


def main():
    a = common.script_args()
    glb, prefix = a[0], a[1]
    opt = lambda k, d: a[a.index(k) + 1] if k in a else d  # noqa: E731
    frame = int(opt('--frame', 0))
    views = opt('--views', 'side,front,top').split(',')
    size = int(opt('--size', 900))
    common.reset_scene()
    arm, meshes = common.import_glb(glb)
    sc = bpy.context.scene
    sc.frame_set(frame)
    bpy.context.view_layer.update()
    mesh = [m for m in meshes if m.vertex_groups][0]
    for m in meshes:
        if m is not mesh:
            m.hide_render = True
    gname = {g.index: g.name for g in mesh.vertex_groups}
    dg = bpy.context.evaluated_depsgraph_get()
    ev = mesh.evaluated_get(dg)
    me = bpy.data.meshes.new_from_object(ev)
    obj = bpy.data.objects.new('view', me)
    obj.matrix_world = mesh.matrix_world.copy()
    sc.collection.objects.link(obj)
    mesh.hide_render = True
    col = me.color_attributes.new('c', 'FLOAT_COLOR', 'POINT')
    legend = {}
    for v in mesh.data.vertices:
        if v.groups:
            g = max(v.groups, key=lambda g: g.weight)
            n = gname[g.group]
            h = (zlib.crc32(n.encode()) % 997) / 997.0
            legend[n] = h
            c = colorsys.hsv_to_rgb(h, 0.85, 0.35 + 0.65 * g.weight)
        else:
            c = (0.3, 0.3, 0.3)
        col.data[v.index].color = (*c, 1)
    mat = bpy.data.materials.new('m')
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    vc = nt.nodes.new('ShaderNodeVertexColor')
    vc.layer_name = 'c'
    em = nt.nodes.new('ShaderNodeEmission')
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    nt.links.new(vc.outputs[0], em.inputs[0])
    nt.links.new(em.outputs[0], out.inputs[0])
    me.materials.clear()
    me.materials.append(mat)
    # bones as thin white tubes (posed)
    bmat = bpy.data.materials.new('b')
    bmat.use_nodes = True
    bmat.node_tree.nodes.clear()
    e2 = bmat.node_tree.nodes.new('ShaderNodeEmission')
    e2.inputs[0].default_value = (1, 1, 1, 1)
    o2 = bmat.node_tree.nodes.new('ShaderNodeOutputMaterial')
    bmat.node_tree.links.new(e2.outputs[0], o2.inputs[0])
    for pb in arm.pose.bones:
        h = arm.matrix_world @ pb.head
        t = arm.matrix_world @ pb.tail
        cu = bpy.data.curves.new('c', 'CURVE')
        cu.dimensions = '3D'
        cu.bevel_depth = 0.0025
        sp = cu.splines.new('POLY')
        sp.points.add(1)
        sp.points[0].co = (*h, 1)
        sp.points[1].co = (*t, 1)
        co = bpy.data.objects.new('bone', cu)
        co.data.materials.append(bmat)
        sc.collection.objects.link(co)
    pts = [obj.matrix_world @ v.co for v in me.vertices]
    lo = Vector((min(p[i] for p in pts) for i in range(3)))
    hi = Vector((max(p[i] for p in pts) for i in range(3)))
    ctr = (lo + hi) / 2
    ext = max(hi - lo) * 1.15
    sc.render.engine = 'CYCLES'
    sc.cycles.samples = 6
    sc.cycles.use_denoising = False
    sc.render.resolution_x = sc.render.resolution_y = size
    sc.render.film_transparent = False
    sc.world = bpy.data.worlds.new('w')
    sc.world.color = (0.08, 0.07, 0.1)
    sc.view_settings.view_transform = 'Standard'
    cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam'))
    cam.data.type = 'ORTHO'
    cam.data.ortho_scale = ext
    sc.collection.objects.link(cam)
    sc.camera = cam
    dirs = {'side': (Vector((1, 0, 0)), 'Y_FWD'), 'front': (Vector((0, 1, 0)), ''), 'top': (Vector((0, 0, 1)), '')}
    for v in views:
        d = dirs[v][0]
        cam.location = ctr + d * 5
        up = Vector((0, 0, 1)) if v != 'top' else Vector((0, 1, 0))
        cam.rotation_euler = (-d).to_track_quat('-Z', 'Y').to_euler()
        # make 'up' correct
        q = (-d).to_track_quat('-Z', 'Y')
        if v == 'top':
            q = (Vector((0, 0, -1))).to_track_quat('-Z', 'Y')
        cam.rotation_euler = q.to_euler()
        sc.render.filepath = f'{prefix}_{v}.png'
        bpy.ops.render.render(write_still=True)
    print('LEGEND', {k: round(h, 3) for k, h in legend.items()})


main()
