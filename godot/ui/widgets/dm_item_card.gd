class_name DmItemCard
extends VBoxContainer
## The text layout of an item (`.cw-tooltip` / `.cw-bag-detail .info`), after src/ui/gearText.ts + InventoryPanel.showTooltip:
##   name (rarity colour, bold) / "<mark> rarity type" / "Item level N · M affixes" / verdict / stat lines / set / brew / lore / "Worth Ng".
## Reads the same Dictionary DmItemSlot takes. Real numbers come from the rules tracks; this only lays them out.
## Keys: name, rarity, quantity, type_label, ilvl, affix_count, verdict {kind: up|down|same, text}, stats: Array[String|Dictionary{text, fx, necro}],
##       set_line, brew_line, lore, sell_value, compare: Array[{text, kind: up|down}].

## Detail strip: name and type share one line (gear-stats.css `.gs-head .name, .type { display: inline-block }`).
var inline_head := false
## Hover-card order (InventoryPanel.showTooltip): the "Against what you wear" block comes BEFORE the brew lines, headed by compare_head.
var tip_mode := false


## CSS `text-transform: capitalize`: the first letter of every space-separated word.
static func capitalize_words(t: String) -> String:
	var out: PackedStringArray = []
	for w in t.split(" "):
		out.append(w.substr(0, 1).to_upper() + w.substr(1) if w != "" else w)
	return " ".join(out)


func _init() -> void:
	add_theme_constant_override("separation", 2)
	theme = DmUi.theme()


func set_item(d: Dictionary, show_lore: bool = true, show_sell: bool = true) -> void:
	for c in get_children():
		c.queue_free()
	if d.is_empty():
		return
	var rarity: String = d.get("rarity", "common")
	var rc := DmUi.rarity_color(rarity)
	var qty: int = int(d.get("quantity", 1))
	var nm := DmUi.label(String(d.get("name", "")) + (" ×%d" % qty if qty > 1 else ""), "DmItemName")
	nm.add_theme_color_override("font_color", rc)
	var ty := String(d.get("type_label", ""))
	var tline := capitalize_words("%s %s %s" % [DmUi.rarity_mark(rarity), rarity, ty])
	var tl := DmUi.label(tline.strip_edges(), "DmItemType")
	if inline_head:
		var hf := HFlowContainer.new()
		hf.add_theme_constant_override("h_separation", 10)
		hf.add_theme_constant_override("v_separation", 0)
		hf.add_child(nm)
		hf.add_child(tl)
		add_child(hf)
	else:
		add_child(nm)
		add_child(tl)
	if d.has("ilvl"):
		var n: int = int(d.get("affix_count", 0))
		var rt := RichTextLabel.new()
		rt.bbcode_enabled = true
		rt.fit_content = true
		rt.scroll_active = false
		rt.theme_type_variation = "DmRichTip"
		rt.add_theme_font_size_override("normal_font_size", 13)
		rt.add_theme_font_size_override("bold_font_size", 13)
		rt.add_theme_color_override("default_color", DmUi.TEXT_MUTED)
		rt.text = "Item level [b][color=#%s]%d[/color][/b] · %s" % [DmUi.BONE_100.to_html(false), int(d["ilvl"]), ("%d %s" % [n, "affix" if n == 1 else "affixes"]) if n else "no affixes"]
		add_child(rt)
	var v: Dictionary = d.get("verdict", {})
	if not v.is_empty() and v.get("kind", "") != "":
		var kind: String = v["kind"]
		var arrow: String = {"up": "▲", "down": "▼", "same": "="}.get(kind, "")
		var vl := DmUi.label("%s %s" % [arrow, v.get("text", "")], "DmVerdictUp" if kind != "down" else "DmVerdictDown")
		if kind == "same":
			vl.add_theme_color_override("font_color", DmUi.TEXT_MUTED)
		vl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(vl)
	for s in d.get("stats", []):
		var txt := ""
		var fx := ""
		var necro := false
		if s is Dictionary:
			txt = s.get("text", "")
			fx = s.get("fx", "")
			necro = s.get("necro", false)
		else:
			txt = String(s)
		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 8)
		row.add_theme_constant_override("v_separation", 0)
		var sl := DmUi.label(("† " if necro else "") + txt, "DmStat")
		sl.add_theme_font_override("font", DmUi.font("body_bold"))
		if necro:
			sl.add_theme_color_override("font_color", DmUi.SPELL_300)
		row.add_child(sl)
		if fx != "":
			var fl := DmUi.label(fx, "DmFaint")
			fl.add_theme_font_size_override("font_size", 12)
			fl.add_theme_color_override("font_color", DmUi.BONE_300)
			row.add_child(fl)
		add_child(row)
	if d.get("set_line", "") != "":
		add_child(DmUi.label(String(d["set_line"]), "DmStat"))
	if tip_mode:
		_add_compare(d)
		_add_brew(d)
	else:
		_add_brew(d)
		_add_compare(d)
	if show_lore and d.get("lore", "") != "":
		var lore := DmUi.label(String(d["lore"]), "DmLore", true)
		add_child(lore)
	if show_sell and d.has("sell_value"):
		var sl2 := DmUi.label("Worth %s" % DmUi.gold(int(d["sell_value"])), "DmGold")
		add_child(sl2)


func _add_brew(d: Dictionary) -> void:
	if d.get("brew_line", "") != "":
		var bl := DmUi.label(String(d["brew_line"]), "DmFaint", true)
		bl.add_theme_font_size_override("font_size", 12)
		bl.add_theme_color_override("font_color", DmUi.BREW)
		add_child(bl)


func _add_compare(d: Dictionary) -> void:
	var cmp: Array = d.get("compare", [])
	if cmp.size() > 0:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)
		box.add_child(DmUi.hrule())
		var hd := DmUi.label(String(d.get("compare_head", "Against what you wear")), "DmFaint")
		hd.add_theme_font_size_override("font_size", 12)
		box.add_child(hd)
		var chips := HFlowContainer.new()
		chips.add_theme_constant_override("h_separation", 10)
		for c in cmp:
			var cl := DmUi.label(String(c.get("text", "")), "DmNumeric")
			cl.add_theme_font_size_override("font_size", 12)
			cl.add_theme_color_override("font_color", DmUi.OK if c.get("kind", "up") == "up" else DmUi.DOWN_SOFT)
			chips.add_child(cl)
		box.add_child(chips)
		add_child(box)
