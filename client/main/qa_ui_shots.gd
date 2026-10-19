class_name DmQaUiShots
extends RefCounted
## UI shot plan for the QA driver (`-- --dev-offline --class=2 --qa --shot-plan=/abs/plan.json --shots=/abs/dir`; `--world-demo` = `--dev-offline --class=2`).
## Loaded by main/qa_driver.gd only when --shot-plan is given, so normal play never touches it. Opens real windows of the real DmGameUi of the game scene
## (DmNextGame) on the dev-offline `tester` hero (with a representative bag), optionally shows an item tooltip, and saves one PNG per shot. No network.
## Rendered on the VPS by client/tools/qa_shots.sh (client/README.md "Screenshots for proposals"): the pictures of a Discord agent's proposal.
## A run is cut up in separate calls: `prepare` (the bag, the gear worn,
## the hero healed), `stage` (the area, the windows, the view and pose, the tooltip) and `capture` (the picture and its crop), so tests/qa_shots.gd checks the
## set-up a plan asks for without a renderer, and `clip_rect` is a function of numbers.
##
## Plan: {"bag": "demo"|"keep", "give": ["item id", ...] (extra items, one each), "equip": ["item id", ...] (max 12, worn like a player equipping from the bag),
##        "discipline": "ossuary"|"gravecaller"|"mourner"|"rotweaver"|"reaper" (or 1-4 / 11; read by the launching script, which passes --class=N: client/tools/qa_shots.sh),
##        "shots": [{"name", "open": "bag" | ["bag", ...], "hover": <bag slot 0-47> | "item:<item id>" | "worn:<equip slot>" | "belt:<tool>",
##        "area": "<area id>", "wait_ms": 300, "clip": "window", "view": "hero" | "game", "turn": <degrees>, "anim": "idle" | "run" | "cast", "fight": true}]}.
## At most MAX_SHOTS shots per plan: a plan with more is refused (`QA-SHOTS plan error:`, exit code 2), not trimmed (run several plans for more). "open" lists are applied in order (the game keeps one window
## open at a time, so the last one stays). "clip": "window" crops to the open window (plus the tooltip when one is shown); default is the whole screen.
## "equip": each id is added to the bag (gear gets a real backend roll) and equipped through the backend's equip call, then the bag reloads, so the avatar
## updates exactly as in play (weapon in hand, helm, mantle, set look at 3+ pieces, legendary body swap). Unknown or unequippable ids print `QA-SHOTS equip:` and are skipped.
## "fight": true makes the wait ("wait_ms") a real fight, for a shot of the HUD in combat: FIGHT_FOES of the Graves' robbers (play's health and damage) are made in a fan 6 to 9 m ahead of the hero as the shot's area is entered, and every FIGHT_STEP_S
## the hero casts at the nearest enemy (the primary, now and then the right mouse button's rite) with its resource and health topped up and the pack made up again when it has thinned, as the scripted fight of the driver does; give it "wait_ms" of 3000 or more so the pack has arrived. Without "fight" the waves of a
## dev-offline start are only climbing out 18 m away or more after a few seconds: nothing is on screen, nothing is cast, nothing is hit.
## "view": "hero" closes every window, hides the HUD and frames the hero full body close-up from the front (`turn` degrees: 0 faces the camera, 180 shows the
## back; `anim` poses the hero and freezes it after a short settle); "game" is the normal game camera with the HUD hidden. The camera, HUD and pose are restored after the shot.
## Window ids (WINDOWS): bag/reliquary/inventory, character/gear/sheet, pets/cosmetics, legion, grimoire/spellbook, vault, forge, salvage, shelf,
## codex, atlas, ascension, map, class, settings, professions, garden, labor, contracts, social/friends, party.

const MAX_SHOTS := 6
const MAX_WAIT_MS := 5000
const MAX_EQUIP := 12
const FIGHT_FOES := 8        ## "fight": enemies made round the hero
const FIGHT_STEP_S := 0.4    ## "fight": the hero casts this often
const DEFAULT_TURN := 25.0   ## a hero view without "turn" stands slightly turned (front three-quarter); "turn": 0 faces the camera
const VIEWS := ["", "hero", "game"]
const ANIMS := ["", "idle", "run", "cast"]
## Playable disciplines by name -> class index (data/combat/disciplines.json by_index; client/tools/qa_shots.sh maps the same names to --class=N).
const DISCIPLINES := {"ossuary": 1, "gravecaller": 2, "mourner": 3, "rotweaver": 4, "reaper": 11}
## The hero close-up: replaces the camera config's distance / height / look-at (fov stays); the focus is the hero's position.
const HERO_CAM := {"dist": 4.6, "heightFactor": 0.48, "backFactor": 0.9, "lookAtY": 1.0, "lookAheadZ": 0.0}
const WINDOWS := {
	"bag": "inventory", "reliquary": "inventory", "inventory": "inventory", "character": "sheet", "gear": "sheet", "sheet": "sheet",
	"pets": "cosmetics", "cosmetics": "cosmetics", "legion": "legion", "grimoire": "grimoire", "spellbook": "grimoire", "vault": "vault",
	"forge": "forge", "salvage": "salvage", "shelf": "shelf", "codex": "codex", "atlas": "atlas", "ascension": "ascension", "map": "map",
	"class": "class", "settings": "settings", "professions": "professions", "garden": "garden", "labor": "labor", "contracts": "contracts",
	"social": "friends", "friends": "friends", "party": "party",
}
## The demo bag: every rarity, a set piece, affixed gear (rolled by the backend at the listed item level, so the affixes are random; the listed ones are
## only a fallback shape), stacks and consumables (ids the content does not know are skipped).
const DEMO_BAG := [
	["staff_bone", 1, 0, []], ["scythe_iron", 1, 14, [{"id": "p_str", "v": 2}]], ["staff_gold", 1, 22, [{"id": "p_thrall_dmg", "v": 5}, {"id": "s_ward", "v": 3}]],
	["staff_moon", 1, 31, [{"id": "p_essence_regen", "v": 4}, {"id": "s_thrall_hp", "v": 6}]], ["set_gravecaller_head", 1, 20, []],
	["leg_legion_unburied_chest", 1, 40, [{"id": "p_thrall_dmg", "v": 9}, {"id": "s_miasma", "v": 7}]], ["helm_gold", 1, 12, [{"id": "s_vit", "v": 2}]],
	["tonic_graveluck", 3, 0, []], ["meal_crypt_eel", 5, 0, []], ["bone_meal", 12, 0, []], ["ore_iron", 40, 0, []], ["reagent_grave_dust", 6, 0, []],
	["rune_volley", 1, 0, []], ["rune_splinter", 1, 0, []],
]


## Parses and validates plan text. Returns {ok, error, bag, give, equip, class_index (0 = not set), shots} with normalised shots
## ({name, open: Array[String] of canonical window ids, hover: Variant (int|String|null), area, wait_ms, clip, view, turn (degrees), anim, fight}).
static func parse(text: String) -> Dictionary:
	var out := {"ok": false, "error": "", "bag": "demo", "give": [], "equip": [], "class_index": 0, "shots": []}
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
	for g in (raw.get("equip", []) if raw.get("equip", []) is Array else []):
		if (out["equip"] as Array).size() < MAX_EQUIP and String(g) != "":
			(out["equip"] as Array).append(String(g))
	var disc: Variant = raw.get("discipline")
	if disc != null:
		var ci := class_index_of(disc)
		if ci == 0:
			out["error"] = "unknown discipline \"%s\" (known: %s)" % [disc, ", ".join(DISCIPLINES.keys())]
			return out
		out["class_index"] = ci
	if (list as Array).size() > MAX_SHOTS:
		out["error"] = "plan has %d shots, at most %d are taken (run several plans for more)" % [(list as Array).size(), MAX_SHOTS]
		return out
	var i := 0
	for s in list:
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
		var view := String(s.get("view", "")).to_lower()
		if not VIEWS.has(view):
			out["error"] = "shot %d: view must be \"hero\" or \"game\"" % (i + 1)
			return out
		var anim := String(s.get("anim", "")).to_lower()
		if not ANIMS.has(anim):
			out["error"] = "shot %d: anim must be idle, run or cast" % (i + 1)
			return out
		var fight: Variant = s.get("fight", false)
		var nm := String(s.get("name", "shot-%d" % (i + 1))).to_lower()
		var rx := RegEx.create_from_string("[^a-z0-9-]+")
		nm = rx.sub(nm, "-", true).substr(0, 40)
		(out["shots"] as Array).append({"name": nm if nm != "" else "shot-%d" % (i + 1), "open": wins, "hover": hover, "area": String(s.get("area", "")),
			"wait_ms": clampi(int(s.get("wait_ms", 300)), 0, MAX_WAIT_MS), "clip": "window" if String(s.get("clip", "")) == "window" else "",
			"view": view, "turn": fmod(float(s.get("turn", DEFAULT_TURN)), 360.0), "anim": anim, "fight": fight is bool and fight})
		i += 1
	out["ok"] = true
	return out


## A discipline name ("gravecaller", "hero_gravecaller") or class index (1-4, 11) -> its class index; 0 = not a playable discipline.
static func class_index_of(v: Variant) -> int:
	if v is float or v is int:
		return int(v) if DISCIPLINES.values().has(int(v)) else 0
	return int(DISCIPLINES.get(String(v).to_lower().trim_prefix("hero_"), 0))


## Runs the plan on a live game, then quits the tree. `root` is any node in the tree (the QA driver).
static func run(root: Node, game: DmNextGame, plan_path: String, out_dir: String) -> void:
	var tree := root.get_tree()
	var plan := parse(FileAccess.get_file_as_string(plan_path))
	if not plan["ok"]:
		print("QA-SHOTS plan error: ", plan["error"])
		tree.quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	await tree.create_timer(1.0).timeout   # the loading screen's fade-out
	await prepare(game, plan)
	var bad := 0
	for s in plan["shots"]:
		var t0 := Time.get_ticks_msec()
		var staged := await stage(root, game, s)
		var file := "%s/%s.png" % [out_dir, s["name"]]
		if capture(root, game, s, staged, file):
			print("QA-SHOTS shot %s %dms" % [file, Time.get_ticks_msec() - t0])
		else:
			bad += 1
			print("QA-SHOTS shot FAILED ", file)
	DmTip.of(root).hide_now()
	DmTip.of(root).test_mouse = null
	tree.quit(1 if bad > 0 else 0)


## What the plan needs before its first shot: the bag (the demo items, the plan's "give" items, the "equip" gear), the offline backend seeded with it, the gear worn through the backend's
## equip call (the bag reloads and the hero's look follows), and the hero healed.
static func prepare(game: DmNextGame, plan: Dictionary) -> void:
	var inventory: DmInventory = game.ui_host.inventory
	if plan["bag"] == "demo":
		for e in DEMO_BAG:
			if DmLootData.item(e[0]).is_empty():
				print("QA-SHOTS demo item missing: ", e[0])
				continue
			inventory.add(await _drop(game, e[0], e[1], e[2]))
	for id in plan["give"]:   # plan-level "give": extra item ids (one each) so a new item can be shown
		if DmLootData.item(id).is_empty():
			print("QA-SHOTS give: unknown item ", id)
		else:
			inventory.add({"item_id": id, "quantity": 1})
	var wear: Array = []
	for id in plan["equip"]:   # into the bag first (gear with a real roll); equipped below, once the whole bag is saved
		var def := DmLootData.item(id)
		if def.is_empty():
			print("QA-SHOTS equip: unknown item ", id)
		elif DmGear.equip_slot_of({"item_type": def.get("type", ""), "item_equipment_slot": def.get("equipment_slot")}) == "":
			print("QA-SHOTS equip: %s cannot be equipped (%s)" % [id, def.get("type", "?")])
		elif not inventory.add(await _drop(game, id, 1, 20)):
			print("QA-SHOTS equip: no bag room for ", id)
		else:
			wear.append(id)
	# The bag is the server's (DECISIONS B25): seed the offline backend with what was shown, as a GM would, and show its answer.
	var seed: Array = []
	for s in inventory.all():
		if int(s["slot_index"]) < DmLoot.bag_size():
			seed.append({"slot_index": int(s["slot_index"]), "item_id": s["item_id"], "quantity": int(s["quantity"]), "equipped": int(s.get("equipped", 0)), "instance_id": s.get("instance_id")})
	var seeded: DmResult = await game.api.save_inventory(int(game.character["id"]), seed, DmLoot.bag_size())
	if seeded.ok:
		inventory.replace(seeded.data)
	else:
		print("QA-SHOTS bag seed: ", seeded.error)
	if int(plan["class_index"]) != 0 and int(plan["class_index"]) != int(game.character.get("class_index", 0)):
		print("QA-SHOTS discipline: the game runs class %d, the plan wants %d (client/tools/qa_shots.sh and shot-godot.sh pass --class=N; a direct run needs it too)" % [int(game.character.get("class_index", 0)), int(plan["class_index"])])
	await _wear(game, wear)
	game.local_body().heal(1e6)


## One shot's scene: the windows closed, the hero stood at the plan's area, the windows opened, the view framed (and the hero posed), the tooltip shown, then two frames to draw it.
## Returns what `capture` needs: {saved (what `_view_end` puts back; empty without a view), tip (the tooltip's rect; empty without one)}.
static func stage(root: Node, game: DmNextGame, s: Dictionary) -> Dictionary:
	var tree := root.get_tree()
	var ui: DmGameUi = game.ui
	ui.close_panels()
	if s["area"] != "":
		go_area(game, s["area"])
	for _i in 3:
		await tree.process_frame
	if s["fight"]:
		_fight_begin(game)
	for w in s["open"]:
		ui.toggle_panel(w)
	var saved := {}
	if s["view"] != "":
		saved = _view_begin(game, s)
	await _wait(root, game, s)
	if not s["open"].is_empty() and not ui.is_open(s["open"][s["open"].size() - 1]):   # the last window of the list is the one that stays
		var last: String = s["open"][s["open"].size() - 1]
		print("QA-SHOTS window did not open: %s%s" % [last, " (the Vault opens only in the Chapterhouse: \"area\": \"chapterhouse\")" if last == "vault" else ""])
	if s["view"] == "hero":
		await _pose(game, s)
	var tip_rect := Rect2()
	if s["hover"] != null:
		tip_rect = await _hover(root, ui, s["hover"])
	await tree.process_frame
	await tree.process_frame
	return {"saved": saved, "tip": tip_rect}


## The shot's wait: `wait_ms` of game time (at least 0.15 s); a "fight" shot casts every FIGHT_STEP_S of it.
static func _wait(root: Node, game: DmNextGame, s: Dictionary) -> void:
	var secs := maxf(0.15, float(s["wait_ms"]) / 1000.0)
	if not s["fight"]:
		await root.get_tree().create_timer(secs).timeout
		return
	var t := 0.0
	var n := 0
	while t < secs:
		_fight_step(game, n)
		n += 1
		var step := minf(FIGHT_STEP_S, secs - t)
		await root.get_tree().create_timer(step).timeout
		t += step


## "fight": `count` robbers in a fan 6 to 9 m ahead of the hero (up the screen), at the same places every time (`first`: the place to start from), through the director like the scripted fight's.
static func _fight_spawn(game: DmNextGame, count: int, first: int = 0) -> void:
	var b := game.local_body()
	for k in count:
		var i := (first + k) % FIGHT_FOES
		var a := deg_to_rad(-60.0 + 120.0 * float(i) / float(FIGHT_FOES - 1))
		var r := 6.0 + 1.5 * float(i % 3)
		game.director.spawn("robber", b.position + Vector3(sin(a) * r, 0.0, -cos(a) * r))


static func _fight_begin(game: DmNextGame) -> void:
	_fight_spawn(game, FIGHT_FOES)


## One cast of a "fight" shot: the nearest enemy gets the primary (the right mouse button's rite every fourth step), the hero's resource and health are topped up and the pack made up to FIGHT_FOES again when it has thinned.
static func _fight_step(game: DmNextGame, n: int) -> void:
	var b := game.local_body()
	var best := 0
	var best_d := 99.0
	for id in game.core_host.enemies_in_radius(b.position, 99.0):
		var at := game.core_host.enemy_position(id)
		var d := Vector2(at.x - b.position.x, at.z - b.position.z).length()
		if d < best_d:
			best_d = d
			best = id
	if best != 0:
		var aim := game.core_host.enemy_position(best)
		game.input.cast_at(5 if n % 4 == 3 else 0, Vector3(aim.x, 0.0, aim.z), best, false)
	var caster := b.get_node_or_null("Rites") as DmRiteCaster
	if caster != null:
		caster.p["resource"]["value"] = caster.p["resource"]["max"]
	b.heal(1e6)
	var alive := game.core_host.alive_count()
	if alive < FIGHT_FOES - 2:   # the pack thins out as the hero kills: more climb out, so the picture has a fight in it whenever it is taken
		_fight_spawn(game, FIGHT_FOES - alive, n * 3)


## The staged shot as a PNG at `file`: the viewport's picture, cropped to the open window (and its tooltip) for "clip": "window", then the camera, HUD and pose put back.
## False when there is no picture to take (a run with no renderer, headless) or the file could not be written.
static func capture(root: Node, game: DmNextGame, s: Dictionary, staged: Dictionary, file: String) -> bool:
	var ui: DmGameUi = game.ui
	var img := grab(root)
	if img == null:
		print("QA-SHOTS no picture: this run draws nothing (headless: start it with a renderer, client/tools/qa_shots.sh)")
	else:
		var rect := Rect2(Vector2.ZERO, Vector2(img.get_size()))
		if s["clip"] == "window" and not s["open"].is_empty():
			var win := ui.window_for(s["open"][s["open"].size() - 1])
			if win != null and win.visible:
				rect = clip_rect(rect, root.get_viewport().get_visible_rect().size, win.get_global_rect(), staged["tip"])
		if rect.size != Vector2(img.get_size()):
			img = img.get_region(Rect2i(rect))
	if not (staged["saved"] as Dictionary).is_empty():
		_view_end(game, staged["saved"])
	return img != null and img.save_png(file) == OK


## The viewport's picture as it is drawn; null when this run has no renderer (headless) or nothing is drawn yet.
static func grab(node: Node) -> Image:
	if DisplayServer.get_name() == "headless":
		return null
	var tex := node.get_viewport().get_texture()
	var img := tex.get_image() if tex != null else null
	return img if img != null and not img.is_empty() else null


## The crop of "clip": "window": the window's rect (merged with the tooltip's when one is shown) grown by 10, from the interface's coordinates into the picture's pixels and cut to the
## picture (`full`); the whole picture when what is left is under 8 pixels either way.
static func clip_rect(full: Rect2, ui_size: Vector2, window: Rect2, tip: Rect2) -> Rect2:
	var k := full.size / ui_size
	var r := window
	if tip.size != Vector2.ZERO:
		r = r.merge(tip)
	r = r.grow(10.0)
	r = Rect2(r.position * k, r.size * k).intersection(full)
	return r if r.size.x > 8 and r.size.y > 8 else full


## Stand at the area's waystone (or first interactable) like a waystone trip would.
static func go_area(game: DmNextGame, area: String) -> void:
	var def: Dictionary = DmContent.area(area)
	if def.is_empty():
		print("QA-SHOTS unknown area ", area)
		return
	for it in def["interactables"]:
		if it["kind"] == "waystone":
			game.chapterhouse.teleport_to(float(it["x"]), float(it["z"]) + 1.6)
			return
	if not (def["interactables"] as Array).is_empty():
		game.chapterhouse.teleport_to(float(def["interactables"][0]["x"]), float(def["interactables"][0]["z"]) + 1.6)


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


## A drop dict for the bag: gear (level > 0) with a real roll from the backend, or the bag save would refuse an instance it never minted.
static func _drop(game: DmNextGame, id: String, qty: int, level: int) -> Dictionary:
	var drop := {"item_id": id, "quantity": qty}
	if level > 0 and DmAffixRules.is_affix_gear(String(DmLootData.item(id).get("type", ""))):
		var rr: DmResult = await game.ui_host.api.roll_loot(game.ui_host.hero_id, [{"item_id": id, "level": level, "source": "boss"}])
		if rr.ok and rr.data is Array and not (rr.data as Array).is_empty() and rr.data[0].get("instance_id") != null:
			drop["instance"] = {"id": rr.data[0]["instance_id"], "ilvl": rr.data[0]["ilvl"], "affixes": rr.data[0]["affixes"]}
	return drop


## Equips each id from the saved bag like the Reliquary does (backend equip call, then the bag reloads, which dresses the avatar via DmHeroLook).
static func _wear(game: DmNextGame, ids: Array) -> void:
	var host := game.ui_host
	await host.refresh_inventory()
	for id in ids:
		var row: Dictionary = {}
		for r: Dictionary in host.inventory.slots:
			if String(r.get("item_id", "")) == id and int(r.get("equipped", 0)) == 0 and not DmGear.is_kit_slot(r.get("slot_index")) and DmGear.equip_slot_of(r) != "":
				row = r
				break
		if row.is_empty():
			if not DmGear.equipped_by_slot(host.inventory.slots).values().any(func(w: Dictionary) -> bool: return String(w.get("item_id", "")) == id):
				print("QA-SHOTS equip: %s is not in the bag" % id)
			continue
		var res: DmResult = await host.api.equip_item(host.hero_id, int(row["slot_index"]), 1)
		if not res.ok:
			print("QA-SHOTS equip: %s: %s" % [id, res.error])
			continue
		await host.refresh_inventory()
	for _i in 4:
		await game.get_tree().process_frame


## "view" shots: HUD and windows away; "hero" also frames the hero close-up and turns it. Returns what _view_end puts back.
static func _view_begin(game: DmNextGame, s: Dictionary) -> Dictionary:
	var body := game.local_body()
	var saved := {"hud": game.ui.visible, "cfg": game.camera.cfg, "zoom": game.camera.zoom, "target_zoom": game.camera.target_zoom, "yaw": body.yaw}
	game.ui.visible = false
	if s["view"] == "hero":
		var cfg: Dictionary = game.camera.cfg.duplicate()
		cfg.merge(HERO_CAM, true)
		game.camera.cfg = cfg
		game.camera.zoom = 1.0
		game.camera.target_zoom = 1.0
		body.yaw = deg_to_rad(float(s["turn"]))
		if body.avatar != null:
			body.avatar.c.root.rotation.y = body.yaw
		game.camera.snap(body.position)
	return saved


## The hero view's pose: "run" / "idle" loop, "cast" plays once; frozen after a short settle so the frame is steady.
static func _pose(game: DmNextGame, s: Dictionary) -> void:
	var av: DmAvatar = game.local_body().avatar
	if av == null or s["anim"] == "":
		return
	if s["anim"] == "cast":
		av.play_once("cast", 1.0)
	else:
		av.set_loop(s["anim"])
	await game.get_tree().create_timer(0.4).timeout
	av.c.ap.speed_scale = 0.0


static func _view_end(game: DmNextGame, saved: Dictionary) -> void:
	game.ui.visible = saved["hud"]
	game.camera.cfg = saved["cfg"]
	game.camera.zoom = saved["zoom"]
	game.camera.target_zoom = saved["target_zoom"]
	var body := game.local_body()
	body.yaw = saved["yaw"]
	if body.avatar != null:
		body.avatar.release_gesture()
		body.avatar.set_loop("idle")
		body.avatar.c.ap.speed_scale = 1.0
	game.camera.snap(body.position)
