"""fbx_to_glb.py - convert a Tripo FBX retarget to GLB so the validators/renderers can read it.
blender -b --python fbx_to_glb.py -- in.fbx out.glb"""
import bpy
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import script_args, reset_scene

src, dst = script_args()[:2]
reset_scene()
bpy.ops.import_scene.fbx(filepath=src)
for a in bpy.data.actions:
    print('ACTION', a.name, a.frame_range[:], len(a.fcurves))
bpy.ops.export_scene.gltf(filepath=dst, export_format='GLB', export_animations=True, export_apply=False)
