class_name DmNextHud
extends CanvasLayer
## Minimal slice HUD: two DmHudOrb widgets (health, class resource) with their numbers, the area name, and a death veil, fed from the
## local DmHeroBody. The full DmGameUi / DmHud integration (hotbar, panels, minimap) comes later; this keeps the same widgets and theme.

const INTERVAL := 0.1
const ORB_GAP := 150.0

var game: Node
var hp_orb: DmHudOrb
var res_orb: DmHudOrb
var hp_label: Label
var res_label: Label
var area_label: Label
var death_veil: ColorRect
var _t: float = 0.0


func _ready() -> void:
	layer = 5
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	death_veil = ColorRect.new()
	death_veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	death_veil.color = Color(0.25, 0.0, 0.03, 0.45)
	death_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	death_veil.visible = false
	root.add_child(death_veil)
	var fallen := Label.new()
	fallen.text = "The Covenant will carry you back."
	fallen.set_anchors_preset(Control.PRESET_CENTER)
	fallen.grow_horizontal = Control.GROW_DIRECTION_BOTH
	fallen.add_theme_font_size_override("font_size", 26)
	death_veil.add_child(fallen)
	area_label = Label.new()
	area_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	area_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	area_label.position.y = 14.0
	area_label.add_theme_font_size_override("font_size", 22)
	root.add_child(area_label)
	hp_orb = _orb(root, -ORB_GAP)
	res_orb = _orb(root, ORB_GAP)
	hp_orb.use_health_palette()
	res_orb.use_resource_palette()
	hp_label = _label(root, -ORB_GAP)
	res_label = _label(root, ORB_GAP)


func _orb(parent: Control, dx: float) -> DmHudOrb:
	var o := DmHudOrb.new()
	o.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	o.grow_horizontal = Control.GROW_DIRECTION_BOTH
	o.position = Vector2(dx - DmHudOrb.SIZE * 0.5, -DmHudOrb.SIZE - 26.0)
	parent.add_child(o)
	return o


func _label(parent: Control, dx: float) -> Label:
	var l := Label.new()
	l.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	l.grow_horizontal = Control.GROW_DIRECTION_BOTH
	l.position = Vector2(dx - 40.0, -30.0)
	l.custom_minimum_size = Vector2(80.0, 0.0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(l)
	return l


func _process(delta: float) -> void:
	_t -= delta
	if _t > 0.0 or game == null:
		return
	_t = INTERVAL
	refresh()


func refresh() -> void:
	var b: DmHeroBody = game.local_body()
	if b == null:
		return
	hp_orb.fill = b.hp / maxf(b.max_hp, 1.0)
	res_orb.fill = b.resource / maxf(b.resource_max, 1.0)
	if b.family != "necromancer":
		res_orb.set_resource_color(Color.html(DmResources.color_for(b.family)))
	hp_label.text = "%d / %d" % [roundi(b.hp), roundi(b.max_hp)]
	res_label.text = "%d / %d" % [roundi(b.resource), roundi(b.resource_max)]
	area_label.text = String(DmContent.area(game.area_id).get("name", "")).to_upper()
	death_veil.visible = not b.alive
