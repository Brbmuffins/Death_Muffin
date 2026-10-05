extends SceneTree
## Data registry tests. Run: godot --headless --path godot --script res://tests/data/run.gd
## Checks: every dataset loads, nothing under data/ is unregistered, no duplicated dataset, the loaders still return the values the
## pre-registry loaders did (snapshots + digests of the merged views), and no production code reads res://data/ outside DmDb.

# md5 of JSON.stringify(sort_keys) of the files that were merged away (loot/content.json, progression/content.json after int
# normalisation, combat/progression.json before its duplicated keys were dropped), recorded before they were deleted.
const GOLD_LOOT := "c0fa66ac6ce30536741c89133da45cc3"
const GOLD_PROG := "ef52eaf07b78f1318163e29622fa56a1"
const GOLD_COMBAT_PROG := "92bc273531f1cb361132f3bad0dfb1bf"

var passed := 0
var failed := 0


func ok(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


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
	ok(FileAccess.file_exists("res://tests/panels_a/sheet_sample.json"), "sheet_sample moved to tests/panels_a")
	var cp: Dictionary = DmDb.raw("combat/progression")
	for k in ["vows", "boons", "ascension", "chain", "wave_milestones", "stat_effects", "damage_upgrade"]:
		ok(not cp.has(k), "combat/progression.json must not re-carry content/ fact: " + k)

	# --- merged views equal the files they replaced ---
	ok(JSON.stringify(DmDb.loot_view(), "", true).md5_text() == GOLD_LOOT, "loot view digest")
	ok(JSON.stringify(DmProgUtil.ints(DmDb.progression_view()), "", true).md5_text() == GOLD_PROG, "progression view digest")
	ok(JSON.stringify(DmDb.combat("progression"), "", true).md5_text() == GOLD_COMBAT_PROG, "combat/progression composed digest")

	# --- wrappers delegate and keep their values (snapshots from the pre-registry loaders) ---
	ok(DmLootData.content() == DmDb.loot_view(), "DmLootData reads the registry")
	ok(DmLootData.bag_size() == 48, "bag size")
	var it := DmLootData.item("log_oak")
	ok(it["name"] == "Oak Log" and it["rarity"] == "common" and int(it["sell"]) == 1 and int(it["stack"]) == 250 and it["offlineStats"] == null and it.size() == 6, "loot item")
	var rat := DmLootData.enemy("rat")
	ok(int(rat["gold"][0]) == 0 and int(rat["gold"][1]) == 1 and int(rat["xp"]) == 1, "loot enemy")
	ok(is_equal_approx(DmLootData.difficulty_reward_mult("hard"), 1.3), "difficulty reward")
	ok(DmLootData.content()["armor"].size() == 110 and DmLootData.content()["necroWeapons"].size() == 35, "armor/necro counts")
	ok(is_equal_approx(float(DmLootData.area("graves")["itemChance"]), 0.062089552238805974), "area itemChance")
	ok(DmProgContent.vows()["elder_dead"]["maxRank"] == 20 and typeof(DmProgContent.vows()["elder_dead"]["maxRank"]) == TYPE_INT, "prog vow int")
	ok(DmProgContent.boon_order().size() == 15 and DmProgContent.vow_order().size() == 11, "prog orders")
	ok(DmProgContent.upgrades()["damage"]["costBase"] == 40 and is_equal_approx(DmProgContent.upgrades()["legion"]["costGrowth"], 1.65), "upgrade costs")
	ok(DmProgContent.get_data()["milestones"].size() == 51 and DmProgContent.get_data()["milestones"][50]["id"] == "chain.100", "milestones")
	ok(DmProgContent.areas()["ossuary"]["unlock"] == {"area": "graves", "kills": 300}, "area unlock")
	ok(DmProgContent.is_always_open("graves") and not DmProgContent.is_always_open("ossuary"), "always open")
	ok(DmProgContent.get_data()["startAreas"] == ["chapterhouse", "graves"], "start areas")
	ok(DmContent.items().size() == 304 and int(DmContent.item("log_oak")["sell"]) == 1, "content items")
	ok(DmContent.file_names().size() > 60, "content file names")
	ok(DmContent.get_export("areas", "AREA_ORDER").size() == 13, "content export")
	ok(DmContent.file("items") == DmDb.content("items"), "DmContent delegates")
	ok(DmCombatData.abilities()["abilities"].size() == 60, "combat abilities")
	var prog: Dictionary = DmCombatData.load_json("progression")
	ok(prog["vows"]["elder_dead"]["maxRank"] == 20 and prog["chain"]["windowMs"] == 4000 and prog["boon_order"].size() == 15, "combat progression composed")
	ok(prog["kit"]["base"] == 120 and prog["new_blood"]["damage_mult"] == 1.5, "combat progression residual")
	ok(DmGatherData.get_data()["nodes"].size() == 30, "gathering nodes")
	ok(DmCounselData.order().size() == 120, "counsel tips")
	ok(DmData.world()["areas"].size() == 13, "slice world")
	ok(DmPaData.atlas()["item_order"].size() == 304, "panels_a atlas")
	ok(DmWfxData.get_data().has("windows") and DmWfxData.get_data()["windows"].size() == 4, "world fx")
	var sw1: Dictionary = DmDb.sim_world()
	var sw2: Dictionary = DmDb.sim_world()
	ok(sw1["obstacles"].size() == 568 and not is_same(sw1, sw2), "sim world fresh each call")
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
	quit(1 if failed > 0 else 0)
