class_name DmGuidanceHud
extends RefCounted
## The HUD "Next" line logic from WorldScene.tickGuidance: a dismissal holds until the best suggestion changes; turning the line off in Settings
## (or being in the Depths) hides it. Call update() about twice a second (or when the state changed) and feed `text` to DmHud's next box.

var top_id := ""
var dismissed := ""
var current: Variant = null
var _last_state: Dictionary = {}
var _last_enabled := true
var _last_dismissed := ""
var _has_last := false


## Returns the suggestion shown ({text, target, place, ...}) or null. `enabled` = settings.guidance.
func update(state: Dictionary, enabled: bool = true) -> Variant:
	# Recomputed only on change: the same state, setting and dismissal give the same suggestion (the rules are pure), and most 0.5 s ticks see no change.
	if _has_last and enabled == _last_enabled and dismissed == _last_dismissed and state == _last_state:
		return current
	var top: Variant = DmGuidance.next_suggestion(state, "")
	var tid: String = String(top["id"]) if top != null else ""
	if tid != top_id:
		top_id = tid
		dismissed = ""
	current = DmGuidance.next_suggestion(state, dismissed) if enabled and state["area"] != "depths" else null
	_last_state = state.duplicate(true)
	_last_enabled = enabled
	_last_dismissed = dismissed
	_has_last = true
	return current


func text() -> String:
	return String(current["text"]) if current != null else ""


## The × on the box (DmHud.dismiss_next).
func dismiss() -> void:
	if current != null:
		dismissed = String(current["id"])
		current = null
