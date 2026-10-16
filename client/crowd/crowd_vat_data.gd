class_name CrowdVatData
extends Resource
## One creature model baked for crowd drawing (client/crowd/README.md): the textures and meshes the baker (crowd_baker.gd) writes, the clip
## table, and the helpers that build the material and MultiMesh and pack the per-instance data crowd_vat.gdshader reads.

const SHADER_PATH := "res://crowd/crowd_vat.gdshader"
## Clips per model the shader can address (its `vat_clips` array).
const MAX_CLIPS := 16
## Floats per instance in `MultiMesh.buffer` with colors and custom data: 12 transform, 4 color, 4 custom.
const BUFFER_STRIDE := 20

@export var slug := ""
## Where the model's textures live, relative to the assets folder (`res://assets/`, see client/crowd/README.md).
@export var albedo_path := ""
@export var orm_path := ""
@export var height := 1.0
@export var yaw := 0.0
## Animation ids: the columns of the baked textures (UV seams share one).
@export var anim_vertex_count := 0
## Texels per row and rows per frame of both textures.
@export var tex_width := 1
@export var tex_rows := 1
@export var total_frames := 0
@export var clip_names := PackedStringArray()
## Per clip: x first frame, y frame count, z frames per second, w 1 loop / 0 hold the last frame.
@export var clip_table := PackedVector4Array()
## Per clip: seconds of the source clip the frames cover (the clip's full length for a loop).
@export var clip_seconds := PackedFloat32Array()
## Per clip: seconds of the whole source clip (a strike or a hurt is baked only up to its follow-through; `clip_seconds` is what is baked).
@export var clip_source_length := PackedFloat32Array()
## Per clip: the second of the source clip where the blow lands (the model row's `timings`, DmAnimator.strike_timing's `impact`), -1 when unmeasured.
@export var clip_impact := PackedFloat32Array()
## Per clip: the second a death clip has come to rest (DmCreature.landing_time), -1 for the other clips.
@export var clip_landing := PackedFloat32Array()
## Body heights per second of walking and running (the model row's `stride`, DmAnimator.plan_loco); 0 = none measured.
@export var stride_walk := 0.0
@export var stride_run := 0.0
## Role (idle, walk, run, attack, hurt, death, ...) -> the clips that play it, the way DmCreature._resolve picks them.
@export var roles := {}
## Bounds of every baked pose, in creature space (feet at the origin, +Z forward); also the meshes' custom_aabb.
@export var aabb := AABB()
@export var pos_tex: Texture2D
@export var nrm_tex: Texture2D
## Level of detail 0 first. Every level shares the vertex array (and so the animation ids), only the index list shrinks.
@export var meshes: Array[Mesh] = []
@export var lod_triangles := PackedInt32Array()


func clip_index(clip_name: String) -> int:
	return clip_names.find(clip_name)


## Seconds a clip covers (a loop's length, or how long until a one-shot holds its last frame).
func clip_length(clip: int) -> float:
	return clip_seconds[clip]


## What `DmCrowd.add_model` reads (client/crowd/README.md "Driving the crowd"): the clip table and the numbers the views play it with.
func crowd_data() -> Dictionary:
	var loops := PackedInt32Array()
	for c in clip_table:
		loops.append(int(c.w))
	return {"slug": slug, "height": height, "stride_walk": stride_walk, "stride_run": stride_run, "clip_names": clip_names, "clip_seconds": clip_seconds,
		"clip_length": clip_source_length if clip_source_length.size() == clip_names.size() else clip_seconds, "clip_impact": clip_impact, "clip_landing": clip_landing,
		"clip_loop": loops, "roles": roles}


## The material for this model's MultiMeshes. `albedo` is the model's colour texture (res://assets/ + albedo_path in the game).
func make_material(albedo: Texture2D, orm: Texture2D = null) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(SHADER_PATH)
	m.set_shader_parameter("albedo_tex", albedo)
	if orm != null:
		m.set_shader_parameter("orm_tex", orm)
		m.set_shader_parameter("use_orm", true)
	m.set_shader_parameter("vat_pos", pos_tex)
	m.set_shader_parameter("vat_nrm", nrm_tex)
	m.set_shader_parameter("vat_width", tex_width)
	m.set_shader_parameter("vat_rows", tex_rows)
	var table := PackedVector4Array(clip_table)
	table.resize(MAX_CLIPS)
	m.set_shader_parameter("vat_clips", table)
	return m


## A MultiMesh of `count` instances of level of detail `lod`. Fill it with `MultiMesh.buffer` (BUFFER_STRIDE floats per instance) or set_instance_*.
func make_multimesh(count: int, lod: int = 0) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = meshes[lod]
	mm.instance_count = count
	return mm


## INSTANCE_CUSTOM for one instance: `clip` at `time` seconds, optionally blending `blend` (0..1, at most 0.999) of `prev_clip` at `prev_time`.
static func pack_custom(clip: int, time: float, prev_clip: int = 0, prev_time: float = 0.0, blend: float = 0.0) -> Color:
	return Color(float(clip), time, float(prev_clip) + clampf(blend, 0.0, 0.999), prev_time)


## COLOR for one instance: linear tint and hit flash 0..1.
static func pack_color(tint: Color, flash: float) -> Color:
	return Color(tint.r, tint.g, tint.b, flash)
