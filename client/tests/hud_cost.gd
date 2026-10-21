class_name HudCost
extends RefCounted
## A model of how the canvas renderer turns a tree of controls into draw calls, to guard the HUD's budget in a headless test (client/ui/hud/PERFORMANCE.md).
## It is a MODEL, not a measurement: the counter is read from a rendered run (tools/hud_measure.gd). Its rules are the ones that run measured (Forward+ on lavapipe,
## Godot 4.7.2, 2026-10-16, the "micro" cases), and tests/hud.gd checks that the model reproduces those measured numbers for the same trees before it is asked about the HUD:
##   - items draw in order of z (their own plus their parents', unless z_as_relative is off), then tree order; a child with show_behind_parent draws before its parent;
##   - consecutive commands that share a texture and kind are ONE draw call: rectangles and icons of one texture ("quad"), nine-patches of one texture ("nine"), the glyphs of
##     one font and size ("glyph", and the outline's atlas "gout"), batched lines;
##   - these are one draw call EACH: a StyleBoxFlat panel, a mesh or MultiMesh or polygon or circle ("poly"), a RichTextLabel; an item with its own material never batches;
##   - a texture, font or size that differs from the last command's starts a new draw call; so does a command of another kind;
##   - clip_contents makes the item's commands a draw of their own; clip_children draws the subtree separately and adds 2.
## Engine-drawn controls (Label, Button, PanelContainer, TextureRect, ...) follow from their properties; the HUD's own widgets say what they draw through DmHudKit's
## helpers while `DmHudKit.recording` is on (their `_draw` runs again, with the log on) and DmHudFloats says how many kinds it has alive.

const UNIQUE := ["poly", "flat", "rtl"]

static var _n := 0


## {draws: int, by_z: {z: draws}, unknown: [class names of script-drawn controls that logged nothing], items: int} for the visible controls under `root`.
static func estimate(root: Node) -> Dictionary:
	var st := {"extra": 0, "unknown": [], "order": 0}
	var items: Array = []
	_collect(root, 0, items, st)
	var counted := _count(items)
	return {"draws": int(counted["draws"]) + int(st["extra"]), "by_z": counted["by_z"], "unknown": st["unknown"], "items": items.size()}


static func _collect(n: Node, zbase: int, items: Array, st: Dictionary) -> void:
	if not (n is CanvasItem):
		for c in n.get_children():
			_collect(c, zbase, items, st)
		return
	var ci := n as CanvasItem
	if not ci.visible:
		return
	var z := (zbase + ci.z_index) if ci.z_as_relative else ci.z_index
	if ci.clip_children != CanvasItem.CLIP_CHILDREN_DISABLED:
		var inner: Array = []
		var ist := {"extra": 0, "unknown": st["unknown"], "order": 0}
		_collect_in(ci, z, inner, ist)
		st["extra"] = int(st["extra"]) + int(_count(inner)["draws"]) + 2 + int(ist["extra"])
		_push(items, z, st, ["barrier"])
		return
	_collect_in(ci, z, items, st)


static func _collect_in(ci: CanvasItem, z: int, items: Array, st: Dictionary) -> void:
	var kids := ci.get_children()
	for c in kids:
		if c is CanvasItem and (c as CanvasItem).show_behind_parent:
			_collect(c, z, items, st)
	_push(items, z, st, _own(ci, st))
	for c in kids:
		if not (c is CanvasItem and (c as CanvasItem).show_behind_parent):
			_collect(c, z, items, st)


static func _push(items: Array, z: int, st: Dictionary, keys: Array) -> void:
	if keys.is_empty():
		return
	st["order"] = int(st["order"]) + 1
	items.append([z, int(st["order"]), keys])


## Draws in order of z then tree order; consecutive equal keys merge, unique ones never do, a barrier only breaks.
static func _count(items: Array) -> Dictionary:
	var sorted := items.duplicate()
	sorted.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var draws := 0
	var by_z := {}
	var prev := ""
	for e in sorted:
		for key: String in e[2]:
			if key == "barrier":
				prev = ""
				continue
			var kind := key.get_slice(":", 0)
			if kind in UNIQUE or key != prev:
				draws += 1
				by_z[e[0]] = int(by_z.get(e[0], 0)) + 1
			prev = key
	return {"draws": draws, "by_z": by_z}


## The commands a control draws, in order: what the engine draws for its type, then what its script drew (the log).
static func _own(ci: CanvasItem, st: Dictionary) -> Array:
	var keys: Array = []
	if ci is Label:
		keys.append_array(_label(ci as Label))
	elif ci is RichTextLabel:
		if (ci as RichTextLabel).get_parsed_text() != "":
			keys.append(_unique("rtl"))
	elif ci is Button:
		var b := ci as Button
		keys.append_array(_style(b.get_theme_stylebox("disabled" if b.disabled else "normal")))
		if b.text != "":
			keys.append("glyph:" + _font_key(b.get_theme_font("font"), b.get_theme_font_size("font_size")))
	elif ci is LineEdit:
		var le := ci as LineEdit
		keys.append_array(_style(le.get_theme_stylebox("normal")))
		if le.text != "" or le.placeholder_text != "":
			keys.append("glyph:" + _font_key(le.get_theme_font("font"), le.get_theme_font_size("font_size")))
	elif ci is PanelContainer:
		keys.append_array(_style((ci as Control).get_theme_stylebox("panel")))
	elif ci is TextureRect:
		var t := (ci as TextureRect).texture
		if t != null:
			keys.append("quad:" + _tex_key(t))
	elif ci is ColorRect:
		keys.append("quad:default")
	elif ci is NinePatchRect:
		var t2 := (ci as NinePatchRect).texture
		if t2 != null:
			keys.append("nine:" + _tex_key(t2))
	if ci.has_method("model_keys"):
		keys.append_array(ci.call("model_keys"))
	var logged: Array = DmHudKit.log.get(ci.get_instance_id(), [])
	keys.append_array(logged)
	if logged.is_empty() and ci.get_script() != null and (ci.get_script() as Script).has_method("_draw") and not ci.has_method("model_keys"):
		(st["unknown"] as Array).append(ci.get_class() + ":" + String((ci.get_script() as Script).get_global_name()))
	if ci.material != null:
		var mat := ci.material.get_instance_id()
		for i in keys.size():
			keys[i] = "mat%d!%s" % [mat, keys[i]]
	if ci is Control and (ci as Control).clip_contents and not keys.is_empty():
		keys.push_front("barrier")
		keys.append("barrier")
	return keys


static func _label(l: Label) -> Array:
	var out: Array = []
	if l.text == "":
		return out
	var fk := _font_key(l.get_theme_font("font"), l.get_theme_font_size("font_size"))
	var os := l.get_theme_constant("outline_size")
	var outlined := os > 0 and l.get_theme_color("font_outline_color").a > 0.0
	var shadow := l.get_theme_color("font_shadow_color").a > 0.0 and (l.get_theme_constant("shadow_offset_x") != 0 or l.get_theme_constant("shadow_offset_y") != 0)
	if shadow:
		# the shadow is the text again, offset: its glyphs share the text's atlas (a shadow outline is only drawn under an outlined text: the rendered run counted 1 draw for 20 shadowed labels)
		if outlined and l.get_theme_constant("shadow_outline_size") > 0:
			out.append("gout:" + fk + ":s")
		out.append("glyph:" + fk)
	if outlined:
		out.append("gout:%s:%d" % [fk, os])
	out.append("glyph:" + fk)
	return out


static func _style(sb: StyleBox) -> Array:
	if sb is StyleBoxTexture:
		return ["nine:" + _tex_key((sb as StyleBoxTexture).texture)]
	if sb is StyleBoxFlat:
		return [_unique("flat")]
	return []


static func _font_key(f: Font, size: int) -> String:
	var rids := f.get_rids()
	return "%d:%d" % [rids[0].get_id() if not rids.is_empty() else 0, size]


static func _tex_key(t: Texture2D) -> String:
	if t is AtlasTexture and (t as AtlasTexture).atlas != null:
		return _tex_key((t as AtlasTexture).atlas)
	return str(t.get_rid().get_id()) if t != null else "none"


static func _unique(kind: String) -> String:
	_n += 1
	return "%s:%d" % [kind, _n]
