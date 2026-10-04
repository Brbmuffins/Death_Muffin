class_name DmGuidanceHud
extends RefCounted
## The HUD "Next" line logic from WorldScene.tickGuidance: a dismissal holds until the best suggestion changes; turning the line off in Settings
## (or being in the Depths) hides it. Call update() about twice a second (or when the state changed) and feed `text` to DmHud's next box.

var top_id := ""
var dismissed := ""
var current: Variant = null


## Returns the suggestion shown ({text, target, place, ...}) or null. `enabled` = settings.guidance.
func update(state: Dictionary, enabled: bool = true) -> Variant:
	var top: Variant = DmGuidance.next_suggestion(state, "")
	var tid: String = String(top["id"]) if top != null else ""
	if tid != top_id:
		top_id = tid
		dismissed = ""
	current = DmGuidance.next_suggestion(state, dismissed) if enabled and state["area"] != "depths" else null
	return current


func text() -> String:
	return String(current["text"]) if current != null else ""


## The × on the box (DmHud.dismiss_next).
func dismiss() -> void:
	if current != null:
		dismissed = String(current["id"])
		current = null
