class_name DmProfessionsPanel
extends DmPanelB
## The Skills tab of the Acre ledger (src/ui/ProfessionsPanel.ts): a grid with each skill's level, XP bar, XP to go, what the next level
## opens, the active gathering tool, and the AFK node picker. Numbers come from DmGathering (nodes, tools, xp curve), never from here.
##
## Data in:  set_skills({skill_id: {level, xp, next?}})  (the "shown" values; `next` defaults to DmGathering.xp_to_next(level))
##           set_gate_levels({skill_id: level})           (level the node list is gated by; defaults to the level; the cap under dev access)
##           set_tools(held_item_ids: Array, belt_item_ids: Array)   (bag + belt ids: the tool line; leave unset to hide it)
##           set_afk(status {active, text, allowed}|{} = no AFK section, message)   set_busy(bool)
##           nav buttons shown when the matching `show_*` flag is true (the web shows them only when the scene wires a callback).
## Signals:  start_afk_requested(node_id)  -> the world's gather loop: DmApi.begin_afk_gather(character_id, node_type) then DmApi.gather(...)
##           pause_afk_requested           -> the gather loop's pause (no network)
##           contracts_pressed / garden_pressed / labor_pressed / cosmetics_pressed -> open those panels (or select the Acre ledger tab)

signal start_afk_requested(node_id: String)
signal pause_afk_requested
signal contracts_pressed
signal garden_pressed
signal labor_pressed
signal cosmetics_pressed

const BLURB := {
	"woodcutting": "Chop trees in the Sexton’s Acre. The Sawpit turns logs into planks, staves and bows.",
	"mining": "Mine ore seams and geodes. The Bone Kiln smelts ore into ingots and gear.",
	"fishing": "Fish the drifting spots on black water. The Cooking Fire renders fish into fillets and flasks.",
	"gravedigging": "Dig pauper’s graves, mounds and tombs for bones, grave goods and a little gold.",
	"gardening": "Plant seeds and saplings in the Mourning Beds and Coffin Patches (Garden, U). They grow while you are away.",
	"alchemy": "Brew herbs and bone meal into flasks and elixirs in the Alchemist's Wing, through the Chapterhouse's east door.",
	"salvaging": "Break spare gear down at the Bone Grinder in the Sexton’s Acre for ingots, planks and reagents. Higher levels add a chance of an extra material.",
}
const HINT := "Choose a node and Start AFK in the Sexton’s Acre. Keep the game open; your hero repeats, changes nodes and waits for respawns until the bag fills. Skills can stay open. Moving, casting or other panels pause work."

var skills: Dictionary = {}
var gate_levels: Dictionary = {}
var held_items: Array = []
var belt_items: Array = []
var has_tools := false
var afk: Dictionary = {}
var message := ""
var busy := false
var show_contracts := false
var show_garden := false
var show_labor := false
var show_cosmetics := false
var node_choice: Dictionary = {}
## What is drawn per skill: {id, name, level, pct, xp_text, unlock, tool, blurb, nodes: Array[String] (picker rows), start_enabled}.
var cards: Array[Dictionary] = []
var afk_label: Label
var pause_button: Button
var start_buttons: Dictionary = {}
var node_pickers: Dictionary = {}


func _init() -> void:
	super._init()
	title = "Skills"
	panel_width = 860


func _inputs() -> Variant:
	# The bag only reaches the cards as each skill's tool line: looting something that is no tool redraws nothing.
	var tools: Array = []
	for id: String in DmGathering.SKILL_IDS:
		tools.append(tool_line(id))
	return [skills, gate_levels, tools, has_tools, afk, message, busy, show_contracts, show_garden, show_labor, show_cosmetics, node_choice, head_note, error_text]


func set_skills(s: Dictionary) -> void:
	skills = s
	head_note = "Total level <b>%d</b>" % total_level()
	rebuild()


func set_gate_levels(g: Dictionary) -> void:
	gate_levels = g
	rebuild()


func set_tools(held: Array, belt: Array) -> void:
	held_items = held
	belt_items = belt
	has_tools = true
	rebuild()


func set_afk(status: Dictionary, msg: String = "") -> void:
	afk = status
	message = msg
	rebuild()


func set_busy(v: bool) -> void:
	busy = v
	rebuild()


func total_level() -> int:
	var n := 0
	for id: String in DmGathering.SKILL_IDS:
		n += int(skills.get(id, {}).get("level", 1))
	return n


func status_text() -> String:
	if afk.is_empty():
		return ""
	var t: String
	if busy:
		t = "Starting…"
	elif afk.get("active", false):
		t = "AFK · %s" % afk.get("text", "")
	else:
		t = message if message != "" else String(afk.get("text", ""))
	if not afk.get("allowed", true):
		t += " · Visit the Sexton’s Acre to start."
	return t


## The tool line of one gathering skill ("" when the scene gave no inventory, or the skill has no tool).
func tool_line(id: String) -> String:
	if not DmGathering.TOOL_KIND.has(id) or not has_tools:
		return ""
	var tier := DmGathering.tool_tier_for(id, held_items)
	if tier == 0:
		return "No tool: forge one at the Bone Kiln for +5% or more."
	var where := "on belt" if DmGathering.tool_tier_for(id, belt_items) == tier else "in bag"
	return "Tool: %s · +%d%% success · %s" % [DmPb.item_name(DmGathering.tool_item_id(id, tier)), tier * 5, where]


func _is_gather(id: String) -> bool:
	return DmGathering.GATHER_SKILLS.has(id)


func _unlock_text(id: String, lvl: int, capped: bool) -> String:
	if capped:
		return "Mastered."
	if _is_gather(id):
		for n: Dictionary in DmGathering.nodes_for_skill(id):
			if int(n["level"]) > lvl:
				return "Level %d: %s" % [int(n["level"]), n["name"]]
	match id:
		"gardening": return "Plant in the ledger’s Garden tab (U)."
		"alchemy": return "Brew at the Great Cauldron in the Alchemist's Wing."
		"salvaging": return "Grind gear at the Bone Grinder in the Acre."
	return "Every node is open to you."


func _build() -> void:
	cards.clear()
	start_buttons.clear()
	node_pickers.clear()
	afk_label = null
	pause_button = null
	_head_note_row()
	if show_contracts or show_garden or show_labor or show_cosmetics:
		var acts := HFlowContainer.new()
		acts.add_theme_constant_override("h_separation", 10)
		for spec: Array in [[show_cosmetics, "Capes", cosmetics_pressed, "Capes and pets (N)"], [show_labor, "Laborers", labor_pressed, "Grave Laborers (H)"], [show_garden, "Garden", garden_pressed, "Grave Gardening (U)"], [show_contracts, "Contracts", contracts_pressed, "Daily delivery orders (O)"]]:
			if spec[0]:
				var b := DmPb.button(spec[1], false, false, spec[3])
				b.custom_minimum_size = Vector2(0, 40)
				var sig: Signal = spec[2]
				b.pressed.connect(func() -> void: sig.emit())
				acts.add_child(b)
		add_child(DmPb.margin(acts, 0, 0, 0, 10))
	add_child(DmPb.section_title("AFK gathering"))
	add_child(DmPb.hint(HINT, 14, DmUi.TEXT_FAINT))
	if not afk.is_empty():
		var row_card := DmPb.card(self, DmUi.BORDER, Color(0, 0, 0, 0), Vector2(14, 12))
		var row := DmPb.hbox(16)
		afk_label = DmPb.text(status_text(), 14, DmUi.TEXT_MUTED, "body", true)
		afk_label.name = "AfkStatus"
		row.add_child(afk_label)
		pause_button = DmPb.button("Pause AFK", false, not afk.get("active", false) or busy)
		pause_button.custom_minimum_size = Vector2(0, 40)
		pause_button.pressed.connect(func() -> void:
			message = "AFK paused"
			pause_afk_requested.emit())
		row.add_child(pause_button)
		row_card.add_child(row)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(grid)
	for id: String in DmGathering.SKILL_IDS:
		_skill_card(grid, id)


func _skill_card(grid: GridContainer, id: String) -> void:
	var meta: Dictionary = DmGatherData.get_data()["skills"][id]
	var col := Color(String(meta["color"]))
	var s: Dictionary = skills.get(id, {"level": 1, "xp": 0})
	var lvl := int(s["level"])
	var xp := int(s["xp"])
	var nxt := int(s.get("next", DmGathering.xp_to_next(lvl)))
	var capped := lvl >= DmGathering.LEVEL_CAP
	var pct := 100 if capped else mini(100, DmMath.js_round(float(xp) / float(nxt) * 100.0))
	var card := DmPb.card(grid, DmUi.BORDER, col, Vector2(16, 14), Color(0.039, 0.035, 0.055, 0.55))
	(card.get_meta("panel") as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_constant_override("separation", 0)
	var head := HBoxContainer.new()
	var nm := DmPb.text(String(meta["name"]), 17, DmUi.BONE_100, "body_bold")
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(nm)
	var lv := DmPb.text(str(lvl), 20, col, "body_bold")
	head.add_child(lv)
	head.add_child(DmPb.text("/%d" % DmGathering.LEVEL_CAP, 12, Color("8c8478")))
	card.add_child(head)
	card.add_child(DmPb.margin(DmPb.text(String(meta["rite"]), 14, DmUi.BONE_300, "body_italic"), 0, 0, 0, 9))
	var bar := DmPbBar.new(6.0)
	bar.fill = col
	bar.pct = float(pct)
	card.add_child(bar)
	var xp_text := "Level cap" if capped else "%s / %s XP · %s to go" % [DmPb.num(xp), DmPb.num(nxt), DmPb.num(nxt - xp)]
	card.add_child(DmPb.margin(DmPb.text(xp_text, 14, DmUi.BONE_300), 0, 6))
	var unlock := _unlock_text(id, lvl, capped)
	card.add_child(DmPb.margin(DmPb.text(unlock, 14, DmUi.BONE_100, "body", true), 0, 8))
	var tl := tool_line(id)
	if tl != "":
		card.add_child(DmPb.margin(DmPb.text(tl, 14, DmUi.BONE_100, "body", true), 0, 8))
	card.add_child(DmPb.margin(DmPb.text(String(BLURB[id]), 14, DmUi.BONE_300, "body", true), 0, 8))
	var info := {"id": id, "name": meta["name"], "level": lvl, "pct": pct, "xp_text": xp_text, "unlock": unlock, "tool": tl, "blurb": BLURB[id], "nodes": [], "start_enabled": false}
	if not afk.is_empty() and _is_gather(id):
		var gate := int(gate_levels.get(id, lvl))
		var choices: Array = DmGathering.nodes_for_skill(id).filter(func(n: Dictionary) -> bool: return int(n["level"]) <= gate)
		if choices.size() > 0:
			var sel := String(node_choice.get(id, choices[0]["id"]))
			var row := DmPb.hbox(8)
			var ob := OptionButton.new()
			ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ob.clip_text = true
			ob.disabled = busy
			ob.tooltip_text = "%s gathering node" % meta["name"]
			for i in choices.size():
				var n: Dictionary = choices[i]
				ob.add_item("%s · level %d" % [n["name"], int(n["level"])])
				ob.set_item_metadata(i, n["id"])
				info["nodes"].append(ob.get_item_text(i))
				if n["id"] == sel:
					ob.select(i)
			ob.item_selected.connect(func(i: int) -> void: node_choice[id] = String(ob.get_item_metadata(i)))
			row.add_child(ob)
			node_pickers[id] = ob
			var st := DmPb.button("Start AFK", false, busy or not afk.get("allowed", true))
			st.custom_minimum_size = Vector2(0, 40)
			st.pressed.connect(func() -> void:
				var nid := String(ob.get_item_metadata(ob.selected))
				node_choice[id] = nid
				start_afk_requested.emit(nid))
			row.add_child(st)
			start_buttons[id] = st
			card.add_child(DmPb.margin(row, 0, 10))
			info["start_enabled"] = not st.disabled
	cards.append(info)
