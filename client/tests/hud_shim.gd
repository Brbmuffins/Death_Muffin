class_name HudShim
extends RefCounted
## The HUD as the HUD test and the draw-call measurement (tools/hud_measure.gd) drive it: today's DmGameUi on the adapter (DmNextUiHost, DECISIONS B46). `refresh` builds and
## applies the view-model now (DmGameUi does it every 50 ms by itself), with `feeds` merged over it (pieces whose systems are not in the scene: HudFeeds); the rest reaches the
## adapter and the panel host.

var g: DmNextGame
var feeds: Dictionary = {}
var refreshes := 0
var refresh_us := 0                 ## microseconds spent in this shim's refreshes (build and apply)
var hud: DmHud:
	get: return g.ui.hud
var vm: DmNextHudVm:
	get: return g.ui_host.vm
var keys: Array:
	get: return g.ui_host.keys
var signature: String:
	get: return g.ui_host.signature
var game: DmNextGame:
	get: return g
var floats: DmFloatBudget:
	get: return g.ui_host.floats
	set(v): g.ui_host.floats = v
var damage_numbers: bool:
	get: return bool(g.ui_host.settings["damage_numbers"])
	set(v): g.ui_host.settings_store.values["damage_numbers"] = v
var visible: bool:
	get: return g.ui.visible
	set(v): g.ui.visible = v
var process_mode: Node.ProcessMode:
	get: return g.ui.process_mode
	set(v): g.ui.process_mode = v
var _target_until: float:
	get: return g.ui_host._target_until
	set(v): g.ui_host._target_until = v


func _init(g_: DmNextGame) -> void:
	g = g_


func refresh() -> void:
	var t0 := Time.get_ticks_usec()
	var v: Dictionary = g.ui.merged_vm()
	if not feeds.is_empty():
		v.merge(feeds, true)
	g.ui._vm = v
	g.ui._hud_at = Time.get_ticks_msec()
	g.ui.hud.apply(v)
	refreshes += 1
	refresh_us += Time.get_ticks_usec() - t0


func last_vm() -> Dictionary:
	return g.ui._vm


func is_elite(id: int) -> bool:
	return g.ui_host.is_elite(id)


func float_text(pos: Vector3, text: String, kind: String = "info", color: Variant = null, now_ms: float = -1.0) -> void:
	g.ui_host.float_text(pos, text, kind, color, now_ms)


func _on_hotbar(slot: int, aim: Vector3, enemy_id: int) -> void:
	g.ui_host._on_hotbar(slot, aim, enemy_id)
