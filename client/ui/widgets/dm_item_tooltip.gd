class_name DmItemTooltip
extends PanelContainer
## `.cw-tooltip`: the hover card for an item. DmItemSlot returns one from _make_custom_tooltip(); any other widget can too:
##   func _make_custom_tooltip(_t): return DmItemTooltip.make(item_dict)
## Width: shrink to content between 170 and 280 px like the CSS.


static func make(item: Dictionary) -> DmItemTooltip:
	var t := DmItemTooltip.new()
	t.theme = DmUi.theme()
	t.theme_type_variation = "DmTooltipCard"
	var card := DmItemCard.new()
	card.tip_mode = true
	card.set_item(item)
	t.add_child(card)
	# estimate a natural width from the widest header line, clamped to the CSS min/max
	var w := 170.0
	var f := DmUi.font("body_bold")
	w = maxf(w, f.get_string_size(String(item.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 26.0)
	var ft := DmUi.font("body")
	var ty := DmItemCard.capitalize_words("%s %s %s" % [DmUi.rarity_mark(String(item.get("rarity", "common"))), item.get("rarity", ""), item.get("type_label", "")])
	w = maxf(w, ft.get_string_size(ty, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 26.0)
	if item.get("lore", "") != "" or item.get("stats", []).size() > 0:
		w = maxf(w, 230.0)
	t.custom_minimum_size.x = clampf(w, 170.0, 280.0)
	return t
