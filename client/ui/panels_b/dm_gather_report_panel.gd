class_name DmGatherReportPanel
extends DmPanelB
## "The Sexton's Ledger" (archive/legacy-web:src/ui/GatherReportPanel.ts): what an AFK session brought back, shown when work stops.
##
## Data in:  show_report(r)  r = GatherReport {seconds, reason, items:[{itemId, name, qty, rarity}], totalItems, goldValue, gold,
##           skills:[{name, xp, fromLevel, toLevel}], best:{name, qty, rarity}|null, milestones:[String], records:[String]}
## Signals:  open_bag_requested -> open the Reliquary (the panel closes itself first)   close_requested (the footer Close and the header X)
## No network: the report is built client-side by the gather loop (gameplay/gatherReport.ts).

signal open_bag_requested

const WHY := {
	"bagFull": "Your bag filled up. Make room, then start AFK again.",
	"moved": "You took over the controls.",
	"panel": "You opened another panel.",
	"hurt": "Something hurt you.",
	"dead": "You fell.",
	"left": "You left the Sexton’s Acre.",
	"blocked": "The node was spent.",
	"unreachable": "The node could not be reached.",
	"labor": "Your laborers came home with this.",
}

var report: Dictionary = {}
var open_bag_button: Button
var close_button: Button
## What is drawn: {note, finds, worth, xp, best, wins: Array[String], skill_rows: Array[String], item_rows: Array[String]}.
var shown: Dictionary = {}


func _init() -> void:
	super._init()
	title = "The Sexton’s Ledger"
	panel_width = 680


func show_report(r: Dictionary) -> void:
	report = r
	rebuild()
	if window != null:
		window.open()


func why_text(reason: String) -> String:
	return String(WHY.get(reason, "Work stopped."))


func total_xp() -> int:
	var n := 0
	for s: Dictionary in report.get("skills", []):
		n += int(s["xp"])
	return n


func _build() -> void:
	open_bag_button = null
	close_button = null
	shown = {}
	if report.is_empty():
		return
	var r := report
	add_child(DmPb.rich("Worked for <b>%s</b>. %s" % [DmPb.duration_text(int(r["seconds"])), why_text(String(r.get("reason", "")))], 12))
	var big := GridContainer.new()
	big.columns = 3
	big.add_theme_constant_override("h_separation", 8)
	big.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(big)
	var stats := [[DmPb.num(r["totalItems"]), "finds"], ["%sg" % DmPb.num(r["goldValue"]), "worth"], [DmPb.num(total_xp()), "skill xp"]]
	for st: Array in stats:
		var c := DmPb.card(big, DmUi.BORDER, Color(0, 0, 0, 0), Vector2(8, 8))
		(c.get_meta("panel") as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var v := DmPb.text(st[0], 22, DmUi.BONE_100, "numeric")
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		c.add_child(v)
		var k := DmPb.text(DmUi.upper(st[1]), 11, DmUi.TEXT_FAINT)
		k.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		c.add_child(k)
	var wins: Array = r.get("milestones", []) + r.get("records", [])
	var best: Variant = r.get("best")
	var win_texts: Array[String] = []
	shown = {"note": why_text(String(r.get("reason", ""))), "finds": DmPb.num(r["totalItems"]), "worth": "%sg" % DmPb.num(r["goldValue"]), "xp": DmPb.num(total_xp()), "best": "", "wins": win_texts, "skill_rows": [], "item_rows": []}
	if wins.size() > 0 or best != null:
		var wc := DmPb.vbox(4)
		add_child(wc)
		if best != null:
			var b: Dictionary = best
			var rc := DmUi.rarity_color(String(b["rarity"]))
			var line := "%s Best find: %s%s" % [DmUi.rarity_mark(String(b["rarity"])), b["name"], " ×%d" % int(b["qty"]) if int(b["qty"]) > 1 else ""]
			shown["best"] = line
			wc.add_child(DmPb.text(line, 14, rc, "body_bold"))
		for w: String in wins:
			win_texts.append("★ " + w)
			wc.add_child(DmPb.text("★ " + w, 14, DmUi.BONE_100))
	var cols := GridContainer.new()
	cols.columns = 2
	cols.add_theme_constant_override("h_separation", 12)
	cols.add_theme_constant_override("v_separation", 12)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(cols)
	var g1 := DmPb.group(cols, "Skills")
	(g1.get_meta("panel") as Control).size_flags_vertical = Control.SIZE_FILL
	for s: Dictionary in r.get("skills", []):
		var up := int(s["toLevel"]) > int(s["fromLevel"])
		var left := DmPb.hbox(4)
		left.add_child(DmPb.text(String(s["name"]), 13))
		left.add_child(DmPb.text("Lv %d → %d" % [int(s["fromLevel"]), int(s["toLevel"])] if up else "Lv %d" % int(s["toLevel"]), 13, DmUi.OK if up else DmUi.TEXT_MUTED, "body_italic" if up else "body"))
		g1.add_child(DmPb.kv_row(left, "+%s xp" % DmPb.num(s["xp"])))
		shown["skill_rows"].append("%s %s +%s xp" % [s["name"], "Lv %d → %d" % [int(s["fromLevel"]), int(s["toLevel"])] if up else "Lv %d" % int(s["toLevel"]), DmPb.num(s["xp"])])
	var g2 := DmPb.group(cols, "Brought back")
	(g2.get_meta("panel") as Control).size_flags_vertical = Control.SIZE_FILL
	DmPb.item_rows(g2, r.get("items", []))
	for i: Dictionary in r.get("items", []):
		shown["item_rows"].append("%s ×%s" % [i["name"], DmPb.num(i["qty"])])
	var foot := DmPb.hbox(10)
	open_bag_button = DmPb.button("Open Reliquary")
	open_bag_button.custom_minimum_size = Vector2(0, 40)
	open_bag_button.pressed.connect(func() -> void:
		close_requested.emit()
		if window != null:
			window.close()
		open_bag_requested.emit())
	foot.add_child(open_bag_button)
	close_button = DmPb.button("Close")
	close_button.custom_minimum_size = Vector2(0, 40)
	close_button.pressed.connect(func() -> void:
		if window != null:
			window.close()
		else:
			close_requested.emit())
	foot.add_child(close_button)
	add_child(foot)
