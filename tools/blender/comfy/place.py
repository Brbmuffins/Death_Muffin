# blender -b --python place.py -- <in.glb> <out.glb> <frame.json> : a model moved into its game placement, the frame's 4x4 matrix in Blender's world space
# (z up; align.py or stand.py found it on the detailed model, so the same move fits every version made from it), normals and tangents with it; materials
# and textures kept.
import bpy, sys, json, mathutils
a = sys.argv[sys.argv.index('--') + 1:]
SRC, OUT = a[0], a[1]
X = mathutils.Matrix(json.load(open(a[2]))['matrix'])
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.import_scene.gltf(filepath=SRC)
for o in [o for o in bpy.data.objects if o.type == 'MESH']:
    o.data.transform(o.matrix_world.inverted() @ X @ o.matrix_world)
bpy.ops.object.select_all(action='SELECT')
bpy.ops.export_scene.gltf(filepath=OUT, use_selection=True, export_format='GLB', export_yup=True, export_tangents=True)
print('PLACE', OUT)
