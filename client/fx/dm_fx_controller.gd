class_name DmFxController
extends Node3D
## Replacement for the vendor scripts of the BinbunVFX pack (vfx_controller.gd, vfx_portal_controller.gd, vfx_smoke / fire / beam
## controller, vfx_loot.gd), which were not vendored. The saved scenes already hold every shader parameter those scripts pushed in
## the editor, so this only (1) keeps their exported properties (unknown ones land in `params`), (2) forwards the animated script
## properties that exist as shader uniforms (open_amount, shrink_amount) to the bound materials, and (3) exposes fade_mult /
## depth_mult (animation-driven multipliers that DmFxBinbun folds into alpha_multiplier / proximity_fade_distance each frame).

var params: Dictionary = {}
var open_amount: float = 1.0:
	set(v):
		open_amount = v
		_forward("open_amount", v)
var shrink_amount: float = 0.5:
	set(v):
		shrink_amount = v
		_forward("shrink_amount", v)
var fade_mult: float = 1.0
var depth_mult: float = 1.0

var _mats: Array = []
var _names: Array = []


static var _native_props: Dictionary = {}


static func _native() -> Dictionary:
	if _native_props.is_empty():
		for p in ClassDB.class_get_property_list("Node3D"):
			_native_props[String(p["name"])] = true
	return _native_props


func _set(prop: StringName, value: Variant) -> bool:
	if _native().has(String(prop)) or String(prop).begins_with("metadata/") or prop == &"script":
		return false
	params[String(prop)] = value
	return true


func _get(prop: StringName) -> Variant:
	if params.has(String(prop)):
		return params[String(prop)]
	return null


## Bound by DmFxBinbun with this instance's own (duplicated) materials and their uniform-name sets.
func bind(mats: Array, names: Array) -> void:
	_mats = mats
	_names = names


func _forward(uniform: String, value: Variant) -> void:
	for i in _mats.size():
		if _names[i].has(uniform):
			(_mats[i] as ShaderMaterial).set_shader_parameter(uniform, value)
