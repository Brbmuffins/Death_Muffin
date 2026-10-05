class_name DmHudTips
extends RefCounted
## The data behind the HUD spell card (HUD.refreshTooltip): which rite sits in a slot, the live slot state, the rune socketed in it, then
## DmSpellTooltip.build + the card extras. Wired as DmHud.spell_card by DmGameUi.

var ui: Node


func _init(ui_: Node) -> void:
	ui = ui_


## The ability id in a HUD slot: -1 = the LMB primary, 0..4 = the Grimoire keys (5 = RMB), 5 = the discipline's signature.
func ability_at(idx: int) -> String:
	if idx == -1:
		return String(ui.rites.primary)
	var sig := String(ui.kit()["signatures"].get(String(ui.build()["discipline"]["id"]), ""))
	var hot: Array = ui.rites.hotbar(sig)
	return String(hot[idx]) if idx >= 0 and idx < hot.size() and hot[idx] != null else ""


func slot_state(idx: int) -> Dictionary:
	var vm: Dictionary = ui.hud.vm
	var s: Dictionary = {}
	if idx == -1:
		s = vm.get("primary", {})
	else:
		var sl: Array = vm.get("slots", [])
		if idx >= 0 and idx < sl.size():
			s = sl[idx]
	return s


static func slot_key(idx: int) -> String:
	return "LMB" if idx == -1 else (String(DmContent.get_export("abilities", "SLOT_KEYS")[idx]) if idx < 5 else "")


func card(idx: int) -> Dictionary:
	var id := ability_at(idx)
	if id == "":
		return {}
	var s := slot_state(idx)
	var state := {}
	if idx != -1:
		state = {"empowered": bool(s.get("empowered", false)), "locked": bool(s.get("locked", false)), "affordable": s.get("affordable", true), "left": float(s.get("left_ms", 0.0))}
	if slot_key(idx) != "":
		state["key"] = slot_key(idx)
	state["auto"] = bool(ui.game.character.get("auto_combat_allowed", false))
	var disc: Dictionary = ui.build()["discipline"]
	var d := DmSpellTooltip.build(id, disc, state)
	var rune_id := String(DmRunes.sockets_of(ui.game.slots).get(id, ""))
	var rune: Dictionary = {}
	if rune_id != "" and not DmContent.rune(rune_id).is_empty():
		var r := DmContent.rune(rune_id)
		var ip := DmUiInventory.icon_of_row({"item_id": rune_id})
		rune = {"icon": load(ip) if ip != "" else null, "name": r["name"], "lines": " ".join(r["lines"]), "cost": String(r["cost"]) if r.get("cost") != null else ""}
	d["rune"] = rune
	d["status_kind"] = "locked" if d["locked"] else ("empowered" if d["empowered"] else "")
	d["footer"] = "%sCodex (K) · Esc closes this card" % ("Click the swap arrows below this slot or press L · " if idx < 5 else "")
	# the web's refresh key: a Grimoire swap puts a different rite in the same slot, and the numbers it shows move with the slot state
	d["key"] = "%d|%s|%s|%s|%s|%s|%d" % [idx, id, rune_id, bool(state.get("empowered", false)), bool(state.get("locked", false)), str(state.get("affordable", "")), int(ceil(float(state.get("left", 0.0)) / 1000.0))]
	return d
