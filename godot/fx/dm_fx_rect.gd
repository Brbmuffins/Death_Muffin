class_name DmFxRect
extends ColorRect
## Replacement for transition_rect.gd (TransitionKit). Exported properties not known to ColorRect are kept in `params`.

var params: Dictionary = {}


static var _native_props: Dictionary = {}


static func _native() -> Dictionary:
	if _native_props.is_empty():
		for p in ClassDB.class_get_property_list("ColorRect"):
			_native_props[String(p["name"])] = true
	return _native_props


func _set(prop: StringName, value: Variant) -> bool:
	if _native().has(String(prop)) or String(prop).begins_with("metadata/") or prop == &"script":
		return false
	params[String(prop)] = value
	return true


func _get(prop: StringName) -> Variant:
	return params.get(String(prop), null)
