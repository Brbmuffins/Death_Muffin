class_name DmHudFloats
extends Control
## Floating combat text and words (`.cw-num`, DmFloatingNumber's looks and timings) with a fixed pool: a number is a row of data and two canvas items made once
## (its outline and its fill), not a node, and nothing is created per hit. Today's DmFloatingNumber.spawn made a Label with three tweens for every number and freed it a
## second later. Each number pops (0.7 to 1.2 to 1.0 times its size), drifts 46 px up and fades, exactly as the tweens did.
##
## The text is drawn into its two items once, when the number is added; a frame only moves them (a transform per item, an alpha in the fade). The items of one kind (one font
## size) share a z layer, outlines under fills, so all the numbers of a kind are two draw calls however many are alive: a Full Party fight draws about eight.
##
##   floats.add(screen_pos, "123", "crit")      # kinds: DmFloatingNumber.STYLE (hit crit dot thrall hurt gold shard xp info big skill heal ward)
## The caps of how many combat numbers may live at once are DmFloatBudget's (DmNextUiHost counts them before the float reaches the HUD).

const CAP := 48                                ## the pool: more than the 22 combat numbers + the 4 a crit may add + the words the hero's cast feedback shows
const OUTLINE := 3                             ## `outline_size`; the old label also drew a 1 px shadow under it, which the outline covers
const OUTLINE_COLOR := Color(0, 0, 0, 0.85)
const RISE := 46.0
const KINDS: Array[String] = ["hit", "crit", "dot", "thrall", "hurt", "gold", "shard", "xp", "info", "big", "skill", "heal", "ward"]

var alive := 0                                 ## numbers on screen (tests)
var _fonts: Array[Font] = []
var _sizes := PackedInt32Array()
var _lifes := PackedFloat32Array()
var _colors := PackedColorArray()
var _out := PackedInt32Array()                 ## the live numbers' entries, oldest first
var _free := PackedInt32Array()                ## entries not in use
var _fill_rid: Array[RID] = []                 ## per entry
var _out_rid: Array[RID] = []
var _pos := PackedVector2Array()
var _kind := PackedInt32Array()
var _born := PackedFloat32Array()
var _life := PackedFloat32Array()
var _shown := PackedVector3Array()             ## the pose last given to the items (scale, rise, alpha): only changes are sent
var _time := 0.0
var _line := TextLine.new()                    ## shapes the text once, for both items


func _init() -> void:
	z_index = DmHudKit.Z_FLOATS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for k in KINDS:
		var st: Dictionary = DmFloatingNumber.STYLE[k]
		_fonts.append(DmUi.font(String(st.get("font", "numeric"))))
		_sizes.append(int(st["size"]))
		_lifes.append(float(st["life"]))
		_colors.append(st["color"])
	_pos.resize(CAP)
	_kind.resize(CAP)
	_born.resize(CAP)
	_life.resize(CAP)
	_shown.resize(CAP)
	set_process(false)


func _ready() -> void:
	# two canvas items per entry, children of this control's item: made once, hidden until used
	var parent := get_canvas_item()
	for i in CAP:
		var o := RenderingServer.canvas_item_create()
		var f := RenderingServer.canvas_item_create()
		for rid in [o, f]:
			RenderingServer.canvas_item_set_parent(rid, parent)
			RenderingServer.canvas_item_set_visible(rid, false)
		_out_rid.append(o)
		_fill_rid.append(f)
		_free.append(CAP - 1 - i)


func _exit_tree() -> void:
	for rid in _out_rid:
		RenderingServer.free_rid(rid)
	for rid in _fill_rid:
		RenderingServer.free_rid(rid)
	_out_rid.clear()
	_fill_rid.clear()
	_free.clear()
	_out.clear()
	alive = 0


## A number or word whose centre starts at `screen_pos`. When the pool is full the oldest is dropped. `color` with alpha 0 means the kind's own.
func add(screen_pos: Vector2, text: String, kind: String = "hit", color: Color = Color(0, 0, 0, 0)) -> void:
	if _free.is_empty():
		if _fill_rid.is_empty():
			return   # not in the tree yet
		_release(0)
	var k := KINDS.find(kind)
	if k < 0:
		k = 0
	var e := _free[_free.size() - 1]
	_free.resize(_free.size() - 1)
	_out.append(e)
	alive = _out.size()
	_pos[e] = screen_pos
	_kind[e] = k
	_born[e] = _time
	_life[e] = _lifes[k]
	_shown[e] = Vector3(-1.0, -1.0, -1.0)
	var col := color if color.a > 0.0 else _colors[k]
	_line.clear()
	_line.add_string(text, _fonts[k], _sizes[k])
	var half := _line.get_size() * 0.5
	# outlines of a kind under the fills of that kind: z layers 2k and 2k + 1 of the floats' layer
	RenderingServer.canvas_item_set_z_index(_out_rid[e], 2 * k)
	RenderingServer.canvas_item_set_z_index(_fill_rid[e], 2 * k + 1)
	RenderingServer.canvas_item_clear(_out_rid[e])
	RenderingServer.canvas_item_clear(_fill_rid[e])
	_line.draw_outline(_out_rid[e], -half, OUTLINE, OUTLINE_COLOR)
	_line.draw(_fill_rid[e], -half, col)
	RenderingServer.canvas_item_set_visible(_out_rid[e], true)
	RenderingServer.canvas_item_set_visible(_fill_rid[e], true)
	_place(e, 0.0)
	set_process(true)


## Removes the live number at position `i` of the order, freeing its entry.
func _release(i: int) -> void:
	var e := _out[i]
	RenderingServer.canvas_item_set_visible(_out_rid[e], false)
	RenderingServer.canvas_item_set_visible(_fill_rid[e], false)
	RenderingServer.canvas_item_clear(_out_rid[e])
	RenderingServer.canvas_item_clear(_fill_rid[e])
	_out.remove_at(i)
	_free.append(e)
	alive = _out.size()


func _process(delta: float) -> void:
	_time += delta
	var i := 0
	while i < _out.size():
		var e := _out[i]
		var t := _time - _born[e]
		if t >= _life[e]:
			_release(i)
		else:
			_place(e, t)
			i += 1
	if _out.is_empty():
		set_process(false)


## For the draw-call model (tests/hud_cost.gd): what the live numbers amount to, an outline run and a fill run for each kind in use.
func model_keys() -> Array:
	var kinds := {}
	for e in _out:
		kinds[_kind[e]] = true
	var ks := kinds.keys()
	ks.sort()
	var out: Array = []
	for k in ks:
		out.append("gout:%d" % k)
		out.append("glyph:%d" % k)
	return out


## Where a number is at age `t` of a life `life`: scale, the rise in px and the alpha (the three tweens of the old label).
static func pose(t: float, life: float) -> Vector3:
	var s := 1.0
	if t < life * 0.12:
		s = 0.7 + 0.5 * (t / (life * 0.12))
	elif t < life * 0.52:
		s = 1.2 - 0.2 * ((t - life * 0.12) / (life * 0.4))
	var a := 1.0
	if t > life * 0.65:
		a = clampf(1.0 - (t - life * 0.65) / (life * 0.35), 0.0, 1.0)
	return Vector3(s, RISE * clampf(t / life, 0.0, 1.0), a)


## Gives the two items of entry `e` the pose of age `t`; a transform or alpha that did not change is not sent again.
func _place(e: int, t: float) -> void:
	var p := pose(t, _life[e])
	var last := _shown[e]
	if p.x != last.x or p.y != last.y:
		var xf := Transform2D(Vector2(p.x, 0.0), Vector2(0.0, p.x), _pos[e] + Vector2(0.0, -p.y))
		RenderingServer.canvas_item_set_transform(_out_rid[e], xf)
		RenderingServer.canvas_item_set_transform(_fill_rid[e], xf)
	if p.z != last.z:
		var c := Color(1, 1, 1, p.z)
		RenderingServer.canvas_item_set_modulate(_out_rid[e], c)
		RenderingServer.canvas_item_set_modulate(_fill_rid[e], c)
	_shown[e] = p
