extends SceneTree
## Data registry tests. Run: godot --headless --path client --script res://tests/data/run.gd
## Checks: every dataset loads, nothing under data/ is unregistered, no duplicated dataset, the merged views carry every entry of the
## content tables they are made from (so new content never needs a test edit, DECISIONS B59), and no production code reads res://data/ outside DmDb.

var passed := 0
var failed := 0


func ok(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


func _keys(d: Variant) -> Array:
	var k: Array = (d as Dictionary).keys() if d is Dictionary else []
	k.sort()
	return k


## The item fields the loot view keeps (DmDb.loot_view).
const LOOT_ITEM_FIELDS := ["name", "type", "rarity", "sell", "stack", "offlineStats"]


## Equal as the JSON says: numbers by value (the views turn whole numbers into ints), lists and objects entry by entry.
func _same(a: Variant, b: Variant) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return is_equal_approx(float(a), float(b))
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not _same(a[k], b[k]):
				return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	return a == b


func _check_loot_view() -> void:
	var v := DmDb.loot_view()
	var want_top := ["areas", "armor", "bagSlots", "depths", "difficulty", "disciplineFamily", "elite", "enemies", "items", "legendary", "necroWeapons", "reagents", "runes"]
	ok(_keys(v) == want_top, "loot view: its sections %s" % [_keys(v)])
	var items: Dictionary = DmDb.content("items").get("ITEMS", {})
	ok(not items.is_empty() and _keys(v["items"]) == _keys(items), "loot view: one entry per content item")
	var bad := []
	for id in items:
		for f in LOOT_ITEM_FIELDS:
			if v["items"][id].get(f) != items[id].get(f):
				bad.append("%s.%s" % [id, f])
	ok(bad.is_empty(), "loot view: items carry the table's name, type, rarity, sell, stack, offlineStats %s" % [bad.slice(0, 5)])
	var areas: Dictionary = DmDb.content("areas").get("AREAS", {})
	ok(_keys(v["areas"]) == _keys(areas), "loot view: one entry per area")
	bad = []
	for id in areas:
		if v["areas"][id].get("loot") != areas[id].get("loot") or v["areas"][id].get("itemChance") != areas[id].get("itemChance"):
			bad.append(id)
	ok(bad.is_empty(), "loot view: areas carry their loot and item chance %s" % [bad])
	var enemies: Dictionary = DmDb.content("enemies").get("ENEMIES", {})
	ok(_keys(v["enemies"]) == _keys(enemies), "loot view: one entry per enemy")
	bad = []
	for id in enemies:
		if v["enemies"][id] != {"gold": enemies[id].get("gold"), "xp": enemies[id].get("xp")}:
			bad.append(id)
	ok(bad.is_empty(), "loot view: enemies carry their gold and xp %s" % [bad])
	ok(_keys(v["armor"]) == _keys(DmDb.content("armorSets").get("ARMOR_BY_ID", {})), "loot view: one entry per armor piece")
	ok(_keys(v["disciplineFamily"]) == _keys(DmDb.content("disciplines").get("DISCIPLINES", {})), "loot view: one family per discipline")
	var lg := DmDb.content("legendarySets")
	ok(v["legendary"]["setIds"] == lg.get("LEGENDARY_SET_IDS") and not (lg.get("LEGENDARY_SET_IDS", []) as Array).is_empty(), "loot view: the legendary set list")
	bad = []
	for id in lg.get("LEGENDARY_SET_IDS", []):
		if v["legendary"]["setDiscipline"].get(id) != lg["LEGENDARY_SETS"][id].get("disciplineId"):
			bad.append(id)
	ok(bad.is_empty(), "loot view: each legendary set's discipline %s" % [bad])
	var rn := DmDb.content("runes")
	ok(v["runes"]["order"] == rn.get("RUNE_ORDER") and _keys(v["runes"]["rarity"]) == _keys(rn.get("RUNES", {})), "loot view: every rune, in order, with its rarity")
	ok(v["runes"]["pityStep"] == rn.get("RUNE_PITY_STEP") and v["runes"]["pityMaxMult"] == rn.get("RUNE_PITY_MAX_MULT"), "loot view: the rising rune chance")
	ok(v["bagSlots"] == DmDb.content("gameplay_gatheringRules").get("BAG_SLOTS"), "loot view: bag slots from the gathering rules")


func _check_progression_view() -> void:
	var v := DmDb.progression_view()
	var want_top := ["alwaysOpen", "areaOrder", "areas", "ascension", "boonOrder", "boons", "bossIds", "bossSummonShards", "bosses", "chain", "limits", "milestones", "startAreas", "upgrades", "vowOrder", "vows"]
	ok(_keys(v) == want_top, "progression view: its sections %s" % [_keys(v)])
	var areas: Dictionary = DmDb.content("areas").get("AREAS", {})
	ok(_keys(v["areas"]) == _keys(areas) and _keys(v["alwaysOpen"]) == _keys(areas), "progression view: one entry per area")
	ok(v["areaOrder"] == DmDb.content("areas").get("AREA_ORDER"), "progression view: the area order")
	var bosses: Dictionary = DmDb.content("bosses").get("BOSSES", {})
	ok(_keys(v["bosses"]) == _keys(bosses) and v["bossIds"] == DmDb.content("bosses").get("BOSS_IDS"), "progression view: every boss")
	var bad := []
	for id in bosses:
		if v["bosses"][id].get("area") != bosses[id].get("area") or v["bosses"][id].get("shards") != bosses[id].get("shards"):
			bad.append(id)
	ok(bad.is_empty(), "progression view: each boss's area and shards %s" % [bad])
	var ms: Array = DmDb.content("gameplay_milestones").get("MILESTONES", [])
	var ids := []
	for m in v["milestones"]:
		ids.append(m["id"])
	var src_ids := []
	for m in ms:
		src_ids.append(m["id"])
	ok(not ids.is_empty() and ids == src_ids, "progression view: every milestone, in order")
	ok(v["chain"] == DmDb.content("gameplay_killChain").get("CHAIN"), "progression view: the kill chain")


func _check_combat_progression() -> void:
	var c: Dictionary = DmDb.combat("progression")
	var u := DmDb.content("upgrades")
	var a := DmDb.content("ascension")
	var pairs := {"damage_upgrade": u.get("DAMAGE_UPGRADE"), "wave_upgrade": u.get("WAVE_UPGRADE"), "legion_upgrade": u.get("LEGION_UPGRADE"),
		"thrall_refresh_max": u.get("THRALL_REFRESH_MAX"), "wave_milestones": u.get("WAVE_MILESTONES"), "ascension": a.get("ASCENSION"),
		"vows": a.get("VOWS"), "vow_order": a.get("VOW_ORDER"), "boons": a.get("BOONS"), "boon_order": a.get("BOON_ORDER"),
		"stat_effects": DmDb.content("gameplay_characterStats").get("STAT_EFFECTS"), "chain": DmDb.content("gameplay_killChain").get("CHAIN")}
	var bad := []
	for k in pairs:
		if c.get(k) != pairs[k] or pairs[k] == null:
			bad.append(k)
	ok(bad.is_empty(), "combat/progression carries the content tables it composes %s" % [bad])
	var own: Dictionary = DmDb.raw("combat/progression")
	bad = []
	for k in own:
		if c.get(k) != own[k]:
			bad.append(k)
	ok(not own.is_empty() and bad.is_empty(), "combat/progression keeps its own file's keys %s" % [bad])


func _scan(dir: String, rel: String, out: PackedStringArray) -> void:
	for d in DirAccess.get_directories_at(dir):
		_scan(dir + "/" + d, rel + d + "/", out)
	for f in DirAccess.get_files_at(dir):
		out.append(rel + f)


func _scan_gd(dir: String, out: PackedStringArray) -> void:
	for d in DirAccess.get_directories_at(dir):
		if d in [".godot", "tests", "assets", "addons"]:
			continue
		_scan_gd(dir + "/" + d, out)
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir + "/" + f)


func _initialize() -> void:
	# --- every registered dataset loads; nothing under data/ is unregistered ---
	var files: PackedStringArray = DmDb.all_files()
	for rel in files:
		ok(DmDb.exists(rel), "registered file missing: " + rel)
		ok(DmDb.raw(rel) != null, "dataset does not parse: " + rel)
	var on_disk := PackedStringArray()
	_scan("res://data", "", on_disk)
	var registered := PackedStringArray()
	for rel in files:
		registered.append(rel + ".json")
	on_disk = PackedStringArray(Array(on_disk).filter(func(f): return f.ends_with(".json")))
	for f in on_disk:
		ok(f in registered, "file under data/ not owned by DmDb: " + f)
	ok(on_disk.size() == registered.size(), "data/ has %d files, registry %d" % [on_disk.size(), registered.size()])

	# --- no two files carry the same dataset (whole-file digests are unique; known merged files are gone) ---
	var seen := {}
	for rel in files:
		var h := JSON.stringify(DmDb.raw(rel), "", true).md5_text()
		if str(DmDb.raw(rel)).length() > 40:
			ok(not seen.has(h), "duplicate dataset: %s == %s" % [rel, seen.get(h, "")])
		seen[h] = rel
	ok(not DmDb.exists("loot/content"), "loot/content.json must not exist (projection of content/*)")
	ok(not DmDb.exists("progression/content"), "progression/content.json must not exist (projection of content/*)")
	ok(not DmDb.exists("panels_a/sheet_sample"), "sample/mock data belongs under tests/")
	ok(FileAccess.file_exists("res://tests/panel_data/sheet_sample.json"), "sheet_sample moved to tests/panel_data")
	var cp: Dictionary = DmDb.raw("combat/progression")
	for k in ["vows", "boons", "ascension", "chain", "wave_milestones", "stat_effects", "damage_upgrade"]:
		ok(not cp.has(k), "combat/progression.json must not re-carry content/ fact: " + k)

	# --- merged views carry their content tables: every entry, the same values ---
	_check_loot_view()
	_check_progression_view()
	_check_combat_progression()

	# --- wrappers delegate and keep the values of the tables they read ---
	ok(DmLootData.content() == DmDb.loot_view(), "DmLootData reads the registry")
	ok(DmLootData.bag_size() == int(DmDb.content("gameplay_gatheringRules").get("BAG_SLOTS")), "bag size is the gathering rules' BAG_SLOTS")
	var items_src: Dictionary = DmDb.content("items").get("ITEMS", {})
	var bad := []
	for id in items_src:
		var it := DmLootData.item(id)
		if it.size() != LOOT_ITEM_FIELDS.size():
			bad.append(id)
		for f in LOOT_ITEM_FIELDS:
			if it.get(f) != items_src[id].get(f):
				bad.append("%s.%s" % [id, f])
	ok(not items_src.is_empty() and bad.is_empty() and DmLootData.item("no_such_item_x").is_empty(), "loot item: the table's fields for each item, {} for an unknown one %s" % [bad.slice(0, 5)])
	var enemies_src: Dictionary = DmDb.content("enemies").get("ENEMIES", {})
	bad = []
	for id in enemies_src:
		if not _same(DmLootData.enemy(id)["gold"], enemies_src[id].get("gold")) or not _same(DmLootData.enemy(id)["xp"], enemies_src[id].get("xp")):
			bad.append(id)
	ok(not enemies_src.is_empty() and bad.is_empty(), "loot enemy: each enemy's gold and xp %s" % [bad])
	var diffs: Dictionary = DmDb.content("difficulty").get("DIFFICULTIES", {})
	bad = []
	for id in diffs:
		if not is_equal_approx(DmLootData.difficulty_reward_mult(id), float(diffs[id]["rewardMult"])):
			bad.append(id)
	ok(not diffs.is_empty() and bad.is_empty(), "difficulty reward: each difficulty's rewardMult %s" % [bad])
	ok(not DmLootData.content()["armor"].is_empty() and not DmLootData.content()["necroWeapons"].is_empty(), "armor/necro tables are there")
	var areas_src: Dictionary = DmDb.content("areas").get("AREAS", {})
	bad = []
	for id in areas_src:
		if not _same(DmLootData.area(id).get("itemChance"), areas_src[id].get("itemChance")):
			bad.append(id)
	ok(bad.is_empty(), "area itemChance: each area's own %s" % [bad])
	var vows_src: Dictionary = DmDb.content("ascension").get("VOWS", {})
	bad = []
	for id in vows_src:
		if DmProgContent.vows()[id]["maxRank"] != int(vows_src[id]["maxRank"]) or typeof(DmProgContent.vows()[id]["maxRank"]) != TYPE_INT:
			bad.append(id)
	ok(not vows_src.is_empty() and bad.is_empty(), "prog vows: each vow's maxRank, as a whole number %s" % [bad])
	ok(DmProgContent.boon_order().size() == DmProgContent.boons().size() and DmProgContent.vow_order().size() == DmProgContent.vows().size() and not DmProgContent.boon_order().is_empty(), "prog orders list every boon and vow")
	var costs: Dictionary = DmDb.raw("progression/extras")["upgradeCosts"]
	bad = []
	for k in costs:
		var got: Dictionary = DmProgContent.upgrades()[k]
		if got["costBase"] != int(costs[k]["costBase"]) or not is_equal_approx(got["costGrowth"], float(costs[k]["costGrowth"])):
			bad.append(k)
	ok(not costs.is_empty() and bad.is_empty(), "upgrade costs: each upgrade's base and growth from the progression extras %s" % [bad])
	var ms: Array = DmProgContent.get_data()["milestones"]
	var ms_ids := {}
	for m in ms:
		ms_ids[String(m["id"])] = true
	ok(not ms.is_empty() and ms_ids.size() == ms.size(), "milestones: some, each id once")
	bad = []
	for id in areas_src:
		var a: Dictionary = DmProgContent.areas()[id]
		var open: bool = areas_src[id].get("unlock") == null and not bool(areas_src[id].get("instance", false))
		if not _same(a["unlock"], areas_src[id].get("unlock")) or DmProgContent.is_always_open(id) != open:
			bad.append(id)
	ok(not areas_src.is_empty() and bad.is_empty(), "area unlock and always-open: each area's own seal %s" % [bad])
	ok(_same(DmProgContent.get_data()["startAreas"], DmDb.raw("progression/extras")["startAreas"]), "start areas")
	ok(not DmContent.items().is_empty() and DmContent.item(String(items_src.keys()[0])) == items_src[items_src.keys()[0]], "content items")
	var on_disk_content := []
	for f in DirAccess.get_files_at("res://data/content"):
		if f.ends_with(".json") and f != "manifest.json":
			on_disk_content.append(f.trim_suffix(".json"))
	var listed := Array(DmContent.file_names())
	on_disk_content.sort()
	listed.sort()
	ok(not listed.is_empty() and listed == on_disk_content, "content file names: the manifest lists the files of data/content")
	ok(DmContent.get_export("areas", "AREA_ORDER").size() == DmData.world()["order"].size(), "content export: the areas' order lists the world's areas")
	ok(DmContent.file("items") == DmDb.content("items"), "DmContent delegates")
	var combat_abilities: Dictionary = DmCombatData.abilities()["abilities"]   # the combat table and the content table list the same abilities
	var content_abilities: Dictionary = DmContent.file("abilities")["ABILITIES"]
	ok(not combat_abilities.is_empty() and _keys(combat_abilities) == _keys(content_abilities), "combat abilities: the same ids as the content table")
	var prog: Dictionary = DmCombatData.load_json("progression")
	var own_prog: Dictionary = DmDb.raw("combat/progression")
	ok(_same(prog["vows"], vows_src) and _same(prog["chain"], DmDb.content("gameplay_killChain").get("CHAIN")) and prog["boon_order"].size() == DmProgContent.boon_order().size(), "combat progression composed: the content table's vows and chain, one entry per boon")
	ok(not own_prog.is_empty() and _same(prog["kit"], own_prog["kit"]) and _same(prog["new_blood"], own_prog["new_blood"]), "combat progression residual: its own file's kit and new blood")
	ok(DmGatherData.get_data()["nodes"].size() == (DmContent.get_export("gameplay_gatheringRules", "NODES") as Dictionary).size() and not DmGatherData.get_data()["nodes"].is_empty(), "gathering nodes: the data holds the rules' node types")
	ok(DmCounselData.order().size() == DmCounselData.tips().size() and not DmCounselData.order().is_empty(), "counsel tips: the order lists every tip")
	ok(DmData.world()["areas"].size() == DmData.world()["order"].size() and not DmData.world()["order"].is_empty(), "slice world: an entry for each area in the order")
	ok(DmPaData.atlas()["item_order"].size() == DmContent.items().size(), "panels_a atlas lists every item")
	# necromancer gear look props (slice/necro_gear.json): every prop and legendary hero model is registered and imported
	var ng: Dictionary = DmDb.slice("necro_gear")
	var used_models: Array = DmDb.slice("assets_used")["models"]
	var ng_props: Array = []
	for tbl in ["weapon_kind_prop", "mantle_by_set_id", "helm_by_tier", "weapon_by_set_id"]:
		for k in ng[tbl]:
			ng_props.append("models/props/%s.glb" % ng[tbl][k]["prop"])
	for k in ng["legendary_hero_by_set_id"]:
		ng_props.append(ng["legendary_hero_by_set_id"][k]["url"])
	var ng_bad := 0
	for m in ng_props:
		if not used_models.has(m) or not ResourceLoader.exists("res://assets/slice/" + m):
			ng_bad += 1
			print("necro_gear model missing: ", m)
	ok(not ng_props.is_empty() and ng_bad == 0, "necro gear table: %d models listed in assets_used and imported" % ng_props.size())
	var asets: Dictionary = DmContent.get_export("armorSets", "ARMOR_SETS")
	var ascended: Dictionary = DmContent.get_export("armorSets", "ASCENDED_ARMOR_SETS")
	var mantle_bad := []
	for k in ng["mantle_by_set_id"]:
		var base := String(k).trim_suffix("_ascended")
		if not (asets.has(k) or (k != base and ascended.has(base))):
			mantle_bad.append(k)
	ok(not ng["mantle_by_set_id"].is_empty() and mantle_bad.is_empty(), "necro gear table: each mantle id is a class set or an ascended one %s" % [mantle_bad])
	for k in ng["legendary_hero_by_set_id"]:
		ok(DmContent.get_export("armorSets", "ARMOR_BY_ID").has("leg_%s_chest" % k), "necro gear table: legendary set %s exists" % k)
	ok(DmWfxData.get_data().has("windows") and not DmWfxData.get_data()["windows"].is_empty(), "world fx")
	var sw1: Dictionary = DmDb.sim_world()
	var sw2: Dictionary = DmDb.sim_world()
	ok(not sw1["obstacles"].is_empty() and sw1["obstacles"].size() == sw2["obstacles"].size() and not is_same(sw1, sw2), "sim world fresh each call")
	ok(DmDb.content("wing").size() > 0 and DmDb.content_export("reagents", "REAGENT_BREW_LIST").size() > 0, "wing + reagents")
	ok(DmDb.content("disciplines")["PLAYABLE_DISCIPLINES"].size() > 0, "playable disciplines")

	# --- one door: production code never opens res://data/ itself ---
	var gds := PackedStringArray()
	_scan_gd("res://", gds)
	for p in gds:
		if p.ends_with("/rules/core/dm_db.gd"):
			continue
		ok(not FileAccess.get_file_as_string(p).contains("res://data/"), "direct res://data/ access outside DmDb: " + p)

	print("data: %d passed, %d failed" % [passed, failed])
	print("%s data %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)
