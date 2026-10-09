class_name DmQaUiShots
extends RefCounted
## UI shot plan for the QA driver (`-- --offline --world-demo --qa --shot-plan=/abs/plan.json --shots=/abs/dir`). Loaded by main/qa_driver.gd only when
## --shot-plan is given, so normal play never touches it. Opens real windows of the real DmGameUi on the offline demo hero (with a
## representative bag), optionally shows an item tooltip, and saves one PNG per shot. No network. Used by the Discord agent's shot-godot.sh.
##
## Plan: {"bag": "demo"|"keep", "give": ["item id", ...] (extra items, one each), "shots": [{"name", "open": "bag" | ["bag", ...], "hover": <bag slot 0-47> | "item:<item id>" | "worn:<equip slot>" | "belt:<tool>",
##        "area": "<area id>", "wait_ms": 300, "clip": "window"}]}. At most MAX_SHOTS shots. "open" lists are applied in order (the game keeps one window
## open at a time, so the last one stays). "clip": "window" crops to the open window (plus the tooltip when one is shown); default is the whole screen.
## Window ids (WINDOWS): bag/reliquary/inventory, character/gear/sheet, pets/cosmetics, legion, grimoire/spellbook, vault, forge, salvage, shelf,
## codex, atlas, ascension, map, class, settings, professions, garden, labor, contracts.

const MAX_SHOTS := 4
const MAX_WAIT_MS := 5000
const WINDOWS := {
	"bag": "inventory", "reliquary": "inventory", "inventory": "inventory", "character": "sheet", "gear": "sheet", "sheet": "sheet",
	"pets": "cosmetics", "cosmetics": "cosmetics", "legion": "legion", "grimoire": "grimoire", "spellbook": "grimoire", "vault": "vault",
	"forge": "forge", "salvage": "salvage", "shelf": "shelf", "codex": "codex", "atlas": "atlas", "ascension": "ascension", "map": "map",
	"class": "class", "settings": "settings", "professions": "professions", "garden": "garden", "labor": "labor", "contracts": "contracts",
}
## The demo bag: every rarity, a set piece, affixed gear, stacks and consumables (ids the content does not know are skipped).
const DEMO_BAG := [
	["staff_bone", 1, 0, []], ["scythe_iron", 1, 14, [{"id": "p_str", "v": 2}]], ["staff_gold", 1, 22, [{"id": "p_thrall_dmg", "v": 5}, {"id": "s_ward", "v": 3}]],
	["staff_moon", 1, 31, [{"id": "p_essence_regen", "v": 4}, {"id": "s_thrall_hp", "v": 6}]], ["set_gravecaller_head", 1, 20, []],
	["leg_legion_unburied_chest", 1, 40, [{"id": "p_thrall_dmg", "v": 9}, {"id": "s_miasma", "v": 7}]], ["helm_gold", 1, 12, [{"id": "s_vit", "v": 2}]],
	["tonic_graveluck", 3, 0, []], ["meal_crypt_eel", 5, 0, []], ["bone_meal", 12, 0, []], ["ore_iron", 40, 0, []], ["reagent_grave_dust", 6, 0, []],
	["rune_volley", 1, 0, []], ["rune_splinter", 1, 0, []],
]


## Parses and validates plan text. Returns {"ok": bool, "error": String, "bag": String, "shots": Array[Dictionary]} with normalised shots
## ({name, open: Array[String] of canonical window ids, hover: Variant (int|String|null), area: String, wait_ms: int, clip: String}).
static func parse(text: String) -> Dictionary:
	var out := {"ok": false, "error": "", "bag": "demo", "give": [], "shots": []}
	var js := JSON.new()
	var raw: Variant = js.data if js.parse(text) == OK else null
	if not (raw is Dictionary):
		out["error"] = "plan must be a JSON object"
		return out
	var list: Variant = raw.get("shots")
	if not (list is Array) or (list as Array).is_empty():
		out["error"] = "plan needs a non-empty \"shots\" array"
		return out
	out["bag"] = "keep" if String(raw.get("bag", "demo")) == "keep" else "demo"
	for g in (raw.get("give", []) if raw.get("give", []) is Array else []):
		if (out["give"] as Array).size() < 20 and String(g) != "":
			(out["give"] as Array).append(String(g))
	var i := 0
	for s in list:
		if i >= MAX_SHOTS:
			break
		if not (s is Dictionary):
			out["error"] = "shot %d is not an object" % (i + 1)
			return out
		var wins: Array[String] = []
		var want: Variant = s.get("open", [])
		for w in (want if want is Array else [want]):
			if String(w) == "":
				continue
			if not WINDOWS.has(String(w).to_lower()):
				out["error"] = "shot %d: unknown window \"%s\" (known: %s)" % [i + 1, w, ", ".join(WINDOWS.keys())]
				return out
			wins.append(WINDOWS[String(w).to_lower()])
		var hover: Variant = s.get("hover")
		if hover is float or hover is int:
			if int(hover) < 0 or int(hover) >= DmReliquaryPanel.BAG_SIZE:
				out["error"] = "shot %d: hover slot out of range" % (i + 1)
				return out
			hover = int(hover)
		elif hover is String and (hover.begins_with("worn:") or hover.begins_with("belt:") or hover.begins_with("item:")):
			pass
		elif hover != null:
			out["error"] = "shot %d: hover must be a bag slot number, \"item:<id>\", \"worn:<slot>\" or \"belt:<tool>\"" % (i + 1)
			return out
		var nm := String(s.get("name", "shot-%d" % (i + 1))).to_lower()
		var rx := RegEx.create_from_string("[^a-z0-9-]+")
		nm = rx.sub(nm, "-", true).substr(0, 40)
		(out["shots"] as Array).append({"name": nm if nm != "" else "shot-%d" % (i + 1), "open": wins, "hover": hover, "area": String(s.get("area", "")),
			"wait_ms": clampi(int(s.get("wait_ms", 300)), 0, MAX_WAIT_MS), "clip": "window" if String(s.get("clip", "")) == "window" else ""})
		i += 1
	out["ok"] = true
	return out


## Runs the plan on a live game, then quits the tree. `root` is any node in the tree (the QA autoload).
static func run(root: Node, game: DmGame, plan_path: String, out_dir: String) -> void:
	var tree := root.get_tree()
	var plan := parse(FileAccess.get_file_as_string(plan_path))
	if not plan["ok"]:
		print("QA-SHOTS plan error: ", plan["error"])
		tree.quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	var ui: DmGameUi = game.ui
	await tree.create_timer(1.0).timeout   # the loading screen's fade-out
	if plan["bag"] == "demo":
		for e in DEMO_BAG:
			if DmLootData.item(e[0]).is_empty():
				print("QA-SHOTS demo item missing: ", e[0])
				continue
			var drop := {"item_id": e[0], "quantity": e[1]}
			if int(e[2]) > 0:
				drop["instance"] = {"id": 900000 + game.inventory.slots.size(), "ilvl": e[2], "affixes": e[3]}
			game.inventory.add(drop)
	for id in plan["give"]:   # plan-level "give": extra item ids (one each) so a new item can be shown
		if DmLootData.item(id).is_empty():
			print("QA-SHOTS give: unknown item ", id)
		else:
			game.inventory.add({"item_id": id, "quantity": 1})
	await game.inventory.commit()   # flush to the offline backend now, or an area change reloads the bag without the seeded items
	game.p["hp"] = game.player.max_hp()
	var bad := 0
	for s in plan["shots"]:
		var t0 := Time.get_ticks_msec()
		ui.close_panels()
		if s["area"] != "":
			_go_area(game, s["area"])
		for _i in 3:
			await tree.process_frame
		for w in s["open"]:
			ui.toggle_panel(w)
		await tree.create_timer(maxf(0.15, float(s["wait_ms"]) / 1000.0)).timeout
		var tip_rect := Rect2()
		if s["hover"] != null:
			tip_rect = await _hover(root, ui, s["hover"])
		await tree.process_frame
		await tree.process_frame
		var img := root.get_viewport().get_texture().get_image()
		var rect := Rect2(Vector2.ZERO, Vector2(img.get_size()))
		if s["clip"] == "window" and not s["open"].is_empty():
			var win := ui.window_for(s["open"][s["open"].size() - 1])
			if win != null and win.visible:
				var k := Vector2(img.get_size()) / root.get_viewport().get_visible_rect().size
				var r := win.get_global_rect()
				if tip_rect.size != Vector2.ZERO:
					r = r.merge(tip_rect)
				r = r.grow(10.0)
				r = Rect2(r.position * k, r.size * k).intersection(rect)
				if r.size.x > 8 and r.size.y > 8:
					rect = r
		if rect.size != Vector2(img.get_size()):
			img = img.get_region(Rect2i(rect))
		var file := "%s/%s.png" % [out_dir, s["name"]]
		if img.save_png(file) == OK:
			print("QA-SHOTS shot %s %dms" % [file, Time.get_ticks_msec() - t0])
		else:
			bad += 1
			print("QA-SHOTS shot FAILED ", file)
	DmTip.of(root).hide_now()
	DmTip.of(root).test_mouse = null
	tree.quit(1 if bad > 0 else 0)


## Stand at the area's waystone (or first interactable) like a waystone trip would.
static func _go_area(game: DmGame, area: String) -> void:
	var def: Dictionary = DmContent.area(area)
	if def.is_empty():
		print("QA-SHOTS unknown area ", area)
		return
	for it in def["interactables"]:
		if it["kind"] == "waystone":
			game.actions.teleport_to(float(it["x"]), float(it["z"]) + 1.6)
			return
	if not (def["interactables"] as Array).is_empty():
		game.actions.teleport_to(float(def["interactables"][0]["x"]), float(def["interactables"][0]["z"]) + 1.6)


## Shows the item card for one cell of the open Reliquary; returns the card's rect (global), or an empty Rect2 when nothing could be shown.
static func _hover(root: Node, ui: DmGameUi, which: Variant) -> Rect2:
	var panel: DmReliquaryPanel = ui.inv.panel
	var slot: DmItemSlot = null
	if which is int:
		slot = panel._slots[which]
	elif String(which).begins_with("item:"):
		for sl in panel._slots:
			if sl.is_filled() and String(sl.data.get("item_id", "")) == String(which).substr(5):
				slot = sl
				break
	elif String(which).begins_with("worn:"):
		slot = panel._doll_slots.get(String(which).substr(5))
	else:
		slot = panel._belt_slots.get(String(which).substr(5))
	if slot == null or not slot.is_visible_in_tree() or not slot.is_filled():
		print("QA-SHOTS hover target empty or hidden: ", which)
		return Rect2()
	var tip := DmTip.of(root)
	if not tip.is_inside_tree():   # the tip layer is added deferred on first use
		await root.get_tree().process_frame
		await root.get_tree().process_frame
	tip.test_mouse = slot.get_global_rect().get_center()
	slot.show_tip()
	for _i in 3:
		await root.get_tree().process_frame
	return tip.content.get_global_rect() if tip.content != null else Rect2()
