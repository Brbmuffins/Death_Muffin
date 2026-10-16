class_name DmUiArt
extends RefCounted
## One place that turns the web's relative art paths ("art/items/staff_oak.webp", "art/abilities/necro-spear.webp", "art/portraits/gravecaller.webp") into
## textures. Roots, first hit wins: res://assets/ui_art/ (tools/godot/sync-ui-art.sh: items, abilities, omens, portraits, status, skills, ui), then the game
## core's res://assets/game/ and the slice assets. Items follow the web: `ITEMS[id].icon ?? art/items/<id>.webp` (InventoryPanel.itemIcon).

const ROOTS := ["res://assets/ui_art/", "res://assets/game/", "res://assets/", "res://assets/slice/"]

static var _cache: Dictionary = {}


## "res://..." of the first root holding `rel`, or "".
static func path(rel: String) -> String:
	if rel == "":
		return ""
	if rel.begins_with("res://"):
		return rel if ResourceLoader.exists(rel) else ""
	for r in ROOTS:
		var full: String = r + rel
		if ResourceLoader.exists(full):
			return full
	return ""


static func texture(rel: String) -> Texture2D:
	if _cache.has(rel):
		return _cache[rel]
	var p := path(rel)
	var t: Texture2D = load(p) as Texture2D if p != "" else null
	_cache[rel] = t
	return t


## The web's item icon path for an item id (meta.icon or art/items/<id>.webp).
static func item_rel(item_id: String) -> String:
	var meta := DmContent.item(item_id)
	var ic: Variant = meta.get("icon")
	return String(ic) if ic != null and String(ic) != "" else "art/items/%s.webp" % item_id


static func item_path(item_id: String) -> String:
	return path(item_rel(item_id))


static func item(item_id: String) -> Texture2D:
	return texture(item_rel(item_id))


static func reset() -> void:
	_cache = {}
