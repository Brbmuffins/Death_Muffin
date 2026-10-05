class_name DmGameRewards
extends RefCounted
## Kill / boss / surge rewards and the economy of a fight, ported from WorldScene.ts: onKill, collected, dropItems (+ the LootRoller),
## gainXp, Kill Chain tiers, milestones, seal unlocks, boss first-kill trophies, soul harvest, loot pickup.

const KILL_REWARD_RANGE := 38.0
const MILESTONE_KEY := "dm_milestones_"
const CHAIN_BEST_KEY := "dm_chain_best_"

var g
var chain = DmKillChain.new()
var chain_told = false
var gold_pool = {"amount": 0, "kills": 0}
var bag_full_at = -1e9
var bag_full_noticed = false
var empower_pending = ""
var empower_summon_id = 0
var _alive = true


func _init(game) -> void:
	g = game


func boss_reward_eligible(alive: bool, distance: float) -> bool:
	return alive and distance < KILL_REWARD_RANGE


func boss_wave_tier() -> float:
	return g.sim.waveTier


func world_difficulty() -> String:
	return g.sim.difficulty


func world_ascension() -> float:
	return g.sim.ascension


func world_levels() -> float:
	return float(g.sim.vowFx["levels"])


func owned_ids() -> Dictionary:
	var d = {}
	for s in g.inventory.slots:
		d[s["item_id"]] = true
	return d


# ---- loot pickup ---------------------------------------------------------------------------------------------------------------

## DmLootView.try_take: put a drop in the bag; false when full.
func try_take(d: Dictionary) -> bool:
	if not g.inventory.add(d):
		# Asked every frame while standing on the drop: say it once in a while.
		if g.now_ms - bag_full_at > 8000.0:
			bag_full_at = g.now_ms
			g.float_text(g.player.x, 2.4, g.player.z, "Reliquary full", "info")
		bag_full_notice()
		return false
	return true


func bag_full_notice() -> void:
	if bag_full_noticed:
		return
	bag_full_noticed = true
	g.toast("Your Reliquary is full. Sell spare gear (Sell all junk) or, back in the Chapterhouse or the Acre, store materials in the Vault (V). What you cannot carry stays on the ground for a minute.", "err")


func tick_loot(dt: float) -> void:
	if g.lootview == null:
		return
	var got = {"gold": 0, "shards": 0, "items": []}
	for ev in g.lootview.tick(dt, Vector3(g.player.x, 0, g.player.z)):
		match ev["kind"]:
			"gold": got["gold"] += int(ev["amount"])
			"shard": got["shards"] += int(ev["amount"])
			"item": got["items"].append(ev["item"])
	# Room again (a free bag slot): the next time something does not fit, say so once more.
	if bag_full_noticed:
		var used = 0
		for s in g.inventory.slots:
			if int(s["slot_index"]) < DmLoot.bag_size():
				used += 1
		if used < DmLoot.bag_size():
			bag_full_noticed = false
	if got["gold"] > 0:
		g.play_sfx("coin")
		g.prog.add_gold(got["gold"])
		g.float_text(g.player.x, 2.1, g.player.z, "+%dg" % got["gold"], "gold")
	if got["shards"] > 0:
		g.play_sfx("shard")
		g.prog.add_shards(got["shards"])
		g.float_text(g.player.x, 2.3, g.player.z, "+%d soul shard%s" % [got["shards"], "s" if got["shards"] > 1 else ""], "shard")
	if not (got["items"] as Array).is_empty():
		collected(got["items"])


## Items just went into the bag (walked over, or auto-looted by the Settings loot rules): sound, toasts and first-time counsel.
func collected(items: Array) -> void:
	var rarities: Array = []
	for item in items:
		rarities.append(String(DmContent.item(item["item_id"]).get("rarity", "common")))
	if g.visual:
		g.audio.play_loot(rarities)
	var gear = false
	var legendary: Array = []
	var armor = false
	var reagent = false
	var affixed = false
	for item in items:
		var m = DmContent.item(item["item_id"])
		if DmAffixRules.is_affix_gear(String(m.get("type", ""))):
			gear = true
		if m.get("rarity") == "legendary":
			legendary.append(item)
		if DmContent.armor_sets().has(item["item_id"]) or _is_armor_piece(item["item_id"]):
			armor = true
		if DmContent.reagents().has(item["item_id"]):
			reagent = true
		if item.get("instance") != null and not (item["instance"]["affixes"] as Array).is_empty():
			affixed = true
	g.emit_game_event("collected", {"gear": gear, "legendary": not legendary.is_empty(), "armor": armor and legendary.is_empty(), "reagent": reagent, "affixed": affixed})
	for item in legendary:
		g.toast("Legendary: %s" % DmContent.item(item["item_id"])["name"], "good")
		g.float_text(g.player.x, 2.6, g.player.z, "LEGENDARY", "big")
	for item in items:
		var meta = DmContent.item(item["item_id"])
		var nm = String(meta["name"])
		if item.get("instance") != null:
			nm = DmAffixRules.affixed_name(nm, item["instance"]["affixes"])
		g.emit_game_event("loot", {"name": nm, "qty": int(item["quantity"]), "rarity": String(meta.get("rarity", "common"))})


func _is_armor_piece(id: String) -> bool:
	return DmContent.item(id).get("type", "").begins_with("armor_") and (DmContent.armor_sets().size() > 0) and _armor_by_id().has(id)


var _armor_ids: Dictionary = {}
func _armor_by_id() -> Dictionary:
	if _armor_ids.is_empty():
		for set_id in DmContent.armor_sets():
			var s: Variant = DmContent.armor_sets()[set_id]
			if s is Dictionary and s.has("pieces"):
				for pc in s["pieces"]:
					_armor_ids[pc["id"] if pc is Dictionary else pc] = true
		_armor_ids["_"] = true
	return _armor_ids


# ---- drops ---------------------------------------------------------------------------------------------------------------------

## Put drops on the ground. Gear first gets its item level and affixes from the server (LootRoller): the piece appears a moment later,
## rolled. Anything the server cannot roll lands as plain gear. Materials never wait.
func drop_items(x: float, z: float, items: Array, level: float, source: String) -> void:
	var gear: Array = []
	for d in items:
		if DmAffixes.can_roll(d["item_id"]):
			gear.append(d)
	for item in items:
		if not gear.has(item) and g.lootview != null:
			g.lootview.item(Vector3(x, 0, z), item)
	if gear.is_empty():
		return
	_attach_and_land(x, z, gear, level, source)


func _attach_and_land(x: float, z: float, gear: Array, level: float, source: String) -> void:
	for batch in DmLootRoll.batches(gear):
		var r: DmResult = await g.api.roll_loot(g.hero_id, DmLootRoll.request(batch, level, source))
		if r.ok and r.data is Array:
			DmLootRoll.apply(batch, r.data)
	if not _alive or g.lootview == null:
		return
	# Settings -> Loot, per rarity: leave it on the ground, auto-loot it into the bag, or take its gold.
	var rules: Dictionary = g.settings_store.loot_rules()
	var keep = Callable()
	if rules.values().has("gold"):
		keep = DmItemText.keeps_for_you(stat_context())
	var gold = 0
	var auto: Array = []
	for item in gear:
		var slots: Variant = DmLoot.add_to_slots([], item)
		var slot: Variant = (slots as Array)[0] if slots != null and not (slots as Array).is_empty() else null
		var action = "ground"
		if slot != null:
			if item.get("instance") != null:
				slot["inst"] = item["instance"]
			action = DmLootFilter.loot_action(slot, rules, keep)
		if action == "gold":
			gold += int(slot["sell_value"]) * int(item["quantity"])
		elif action == "auto" and g.inventory.add(item):
			auto.append(item)
		else:
			g.lootview.item(Vector3(x, 0, z), item)
	if not auto.is_empty():
		collected(auto)
	if gold > 0:
		g.prog.add_gold(gold)
		g.float_text(x, 2.1, z, "+%dg" % gold, "gold")


## Who the gear text is for (DmGearStats / DmItemText context).
func stat_context() -> Variant:
	return {"character": g.character, "slots": g.inventory.slots, "discipline": g.discipline, "damageTier": g.prog.local["damageTier"], "legion": g.build.get("legion", {})}


# ---- kills ---------------------------------------------------------------------------------------------------------------------

func on_kill(ev: Dictionary) -> void:
	# A boss's skull niche is part of the fight, not a kill: no souls, loot, XP or area progress.
	if DmContent.enemy(String(ev["def"])).get("inert", false) == true:
		return
	var player: DmPlayer = g.player
	# Soul Harvest: the caster already banked this kill's souls (DmSimCaster.handle_event); DmGame announces a filled meter.
	# Personal rewards for kills in (or right next to) your area.
	if not boss_reward_eligible(player.alive, DmSimMath.hypot(float(ev["x"]) - player.x, float(ev["z"]) - player.z)):
		return
	# The Depths drop from the hunting ground whose gear matches the floor's depth.
	var loot_area: String = String(ev["area"])
	if g.depths != null:
		var la: Variant = g.depths.loot_area(String(ev["area"]))
		if la != null:
			loot_area = String(la)
	var owned = owned_ids
	var reward = DmLoot.roll_kill(String(ev["def"]), loot_area, float(ev["level"]), bool(ev["elite"]), boss_wave_tier(), Callable(), world_difficulty(), 1.0 + DmPlayerRules.brew_value(g.p, "fortune", g.now_ms), Callable(), Callable(), String(g.discipline["id"]), owned)
	# The chain: your own kills in unsafe ground, each within the window of the last.
	var chain_mult = 1.0
	var area_def: Dictionary = DmContent.area(String(ev["area"]))
	if ev.get("killer") == g.self_id and not area_def["safe"]:
		var up: Variant = chain.hit(g.now_ms)
		chain_mult = chain.mult()
		if up != null:
			on_chain_tier(String(up["name"]), float(up["bonus"]), float(ev["x"]), float(ev["z"]))
	# The week's Omen pays a little extra on every kill, and doubles or more the shards elites drop.
	var combat_area: bool = not area_def["safe"]
	var asc = DmAscension.ascension_reward_mult(world_ascension()) * chain_mult * (float(g.omen["rewardMult"]) if combat_area else 1.0)
	if int(reward["shards"]) > 0 and combat_area:
		reward["shards"] = int(ceil(float(reward["shards"]) * float(g.omen["shardMult"])))
	reward["gold"] = DmMath.js_round(float(reward["gold"]) * asc)
	# Tonic of wisdom: a share more experience from every kill.
	var wisdom = DmPlayerRules.brew_value(g.p, "wisdom", g.now_ms)
	reward["xp"] = DmMath.js_round(float(reward["xp"]) * asc * (1.0 + wisdom))
	# Gold pools over a few kills into one bigger pile; elites always pay out.
	gold_pool["amount"] += int(reward["gold"]) + int(reward["materialGold"])
	gold_pool["kills"] += 1
	if bool(ev["elite"]) or int(gold_pool["kills"]) >= int(DmLoot.KILL_LOOT["goldEveryKills"]):
		if g.lootview != null:
			g.lootview.gold(Vector3(float(ev["x"]), 0, float(ev["z"])), int(gold_pool["amount"]))
		gold_pool["amount"] = 0
		gold_pool["kills"] = 0
	if int(reward["shards"]) > 0 and g.lootview != null:
		g.lootview.shard(Vector3(float(ev["x"]), 0, float(ev["z"])), int(reward["shards"]))
	# Ordinary kills drop half as often (KILL_LOOT), so their gear rolls at elite quality.
	drop_items(float(ev["x"]), float(ev["z"]), reward["items"], float(ev["level"]), "elite")
	# Server authority step 2: report the kill BEFORE the XP is added (a level-up saves at once).
	if combat_area:
		g.psync.report_kill({
			"area": ev["area"], "def": ev["def"], "level": ev["level"], "elite": ev["elite"], "tier": boss_wave_tier(), "diff": world_difficulty(), "rank": world_ascension(),
			"xpMult": asc * (1.0 + wisdom) * DmEnemyStats.new_blood_xp_mult(String(g.discipline["family"]), float(g.character["level"])), "goldMult": asc,
			"shardMult": float(g.omen["shardMult"]),
		})
	gain_xp(float(reward["xp"]), float(ev["x"]), float(ev["z"]))
	if String(ev["area"]) == "depths":
		if g.depths != null:
			g.depths.record_kill()
	else:
		g.prog.record_kill(String(ev["area"]), boss_wave_tier())
	check_unlocks()
	check_milestones()


func on_chain_tier(nm: String, bonus: float, _x: float, _z: float) -> void:
	var tiers: Array = DmProgContent.get_data()["chain"]["tiers"]
	var idx = 0
	for i in tiers.size():
		if tiers[i]["name"] == nm:
			idx = i
			break
	var p: DmPlayer = g.player
	g.play_sfx("chainTier", p.x, p.z, 1.0)
	g.float_text(p.x, 3.0, p.z, "%s  +%d%%" % [nm.to_upper(), DmMath.js_round(bonus * 100.0)], "big")
	var cols = [0xe6d3a0, 0xf0b25a, 0xf08a3a, 0xee5a2a, 0xff3a3a]
	var col: int = cols[maxi(0, idx)]
	if g.visual:
		g.vfx.emit({"x": p.x, "y": 1.0, "z": p.z, "count": 20 + idx * 8, "color": col, "spread": 0.5, "speed": 3.0 + idx * 0.6, "up": 2.4, "life": 0.8, "size": 0.16, "gravity": 3.0})
		g.vfx.decal({"tex": "ring", "color": col, "x": p.x, "z": p.z, "r": 2.0 + idx * 0.5, "duration": 0.5, "opacity": 0.9, "growFrom": 0.3})
	if idx >= 2 and g.camera != null:
		g.camera.shake(0.08 + idx * 0.02)
	if not chain_told:
		chain_told = true
		g.tip("chain", 400)
		g.emit_game_event("chain_started")


func on_souls_charged() -> void:
	g.emit_game_event("souls_charged")
	var p: DmPlayer = g.player
	g.float_text(p.x, 2.6, p.z, "Soul Harvest", "info")
	g.toast("Soul Harvest — your next Marrow Spear, Miasma or Black Litany is free and 50% larger", "good")
	g.play_sfx("shard")
	if g.visual:
		var jade: int = int(DmContent.spell_fx()["souls"]["jade"])
		g.vfx.emit({"x": p.x, "y": 0.3, "z": p.z, "count": 50, "color": jade, "spread": 1.2, "speed": 1.4, "up": 3.0, "life": 1.0, "size": 0.3, "inward": true})
		g.vfx.light_flash(Vector3(p.x, 1.5, p.z), Color.hex(jade * 256 + 255), 30.0, 0.6)


func gain_xp(xp_in: float, x: float, z: float) -> void:
	var xp = DmMath.js_round(xp_in * DmEnemyStats.new_blood_xp_mult(String(g.discipline["family"]), float(g.character["level"])))
	var gained = g.prog.add_xp(float(xp))
	if randf() < 0.35:
		g.float_text(x, 2.0, z, "+%d xp" % xp, "xp")
	if gained > 0:
		var p: DmPlayer = g.player
		g.chronicle.max_("peak.level", float(g.character["level"]))
		g.refresh_stats()
		g.p["hp"] = float(g.p["stats"]["maxHp"])
		g.p["resource"]["value"] = g.p["resource"]["max"]
		g.banner("Level %d" % int(g.character["level"]), "The dead answer you more readily", 2600)
		var lvl = float(g.character["level"])
		var learned: Array = []
		for id in g.kit["primaries"] + g.kit["grimoire"]:
			if DmAbilities.unlock_level(id) > lvl - gained and DmAbilities.unlock_level(id) <= lvl and not learned.has(id):
				learned.append(id)
		if not learned.is_empty():
			var names: Array = []
			for id in learned.slice(0, 3):
				names.append(DmAbilities.def(id)["name"])
			var nm = ", ".join(names)
			if learned.size() > 3:
				nm = "%s and %d more" % [nm, learned.size() - 3]
			g.game_event.emit("toast", {"text": "%s %s your Grimoire. Click here, press L or use the Grimoire button to place it." % [nm, "join" if learned.size() > 1 else "joins"], "kind": "good", "action": "grimoire"})
		var bc: Dictionary = g.counsel_bag_ctx()
		g.emit_game_event("level_up", {"level": int(lvl), "grimoire_unlocked": g.grimoire_unlocked(), "family": g.discipline["family"], "learned_rites": bc["learned_rites"], "rune_count": bc["rune_count"]})
		g.play_sfx("levelUp")
		g.character_changed.emit()
		if g.visual:
			g.vfx.emit({"x": p.x, "y": 0.2, "z": p.z, "count": 90, "color": 0xf1d9a8, "spread": 0.8, "speed": 0.8, "up": 5.0, "life": 1.5, "size": 0.35})
			g.vfx.decal({"tex": "sigil", "color": 0xe2c98f, "x": p.x, "z": p.z, "r": 2.4, "duration": 1.8, "opacity": 1.0, "growFrom": 0.2, "spin": 1.2})
			g.vfx.light_flash(Vector3(p.x, 2.0, p.z), Color.hex(0xf1d9a8ff), 50.0, 1.0)
			g.vfx.play("levelup_pillar", Vector3(p.x, 0, p.z))


## The saved truth, not the dev overlay: dev access must not stop an earned seal from being banked.
func check_unlocks() -> void:
	for id in DmContent.area_order():
		var u: Variant = DmContent.area(id).get("unlock")
		if u == null or g.prog.really_unlocked(id):
			continue
		if g.prog.kills(String(u["area"])) >= g.prog.unlock_kills(float(u["kills"])) and g.prog.unlock(id):
			g.nav.set_unlocked(g.open_areas())
			g._sync_doors()
			var door: Variant = null
			for d in DmContent.doors():
				if d["b"] == id:
					door = d
					break
			g.banner("A seal breaks", "%s lies open%s" % [DmContent.area(id)["name"], (" · " + door_direction(door)) if door != null else ""], 4800)
			if door != null:
				g.play_sfx("gate", (float(door["rect"]["x0"]) + float(door["rect"]["x1"])) / 2.0, (float(door["rect"]["z0"]) + float(door["rect"]["z1"])) / 2.0)
			if g.camera != null:
				g.camera.shake(0.3)
			g.psync.flush()
			g.progress_changed.emit()


## Which way a door lies from the hall it leaves (doorDirection in WorldScene.ts).
func door_direction(door: Dictionary) -> String:
	var a: Dictionary = DmContent.area(String(door["a"]))["rect"]
	var b: Dictionary = DmContent.area(String(door["b"]))["rect"]
	var dx = (float(b["x0"]) + float(b["x1"])) / 2.0 - (float(a["x0"]) + float(a["x1"])) / 2.0
	var dz = (float(b["z0"]) + float(b["z1"])) / 2.0 - (float(a["z0"]) + float(a["z1"])) / 2.0
	if absf(dx) > absf(dz):
		return "east" if dx > 0.0 else "west"
	return "south" if dz > 0.0 else "north"


## Pays any newly reached milestone once per character (claims live on this machine).
## The claims + stored best chain are read from the store once per hero (this runs on every kill) and kept in step with what it writes.
var _ms_hero: Variant = null
var _ms_claimed: Array = []
var _ms_best := 0

func check_milestones() -> void:
	var store: DmCounselStore = g.store
	if _ms_hero != g.hero_id:
		_ms_hero = g.hero_id
		_ms_claimed = []
		_ms_best = 0
		var raw = store.get_item(MILESTONE_KEY + str(g.hero_id))
		if raw != "":
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is Array:
				_ms_claimed = parsed
		var raw_best = store.get_item(CHAIN_BEST_KEY + str(g.hero_id))
		if raw_best != "":
			_ms_best = int(raw_best)
	var claimed: Array = _ms_claimed
	var best_chain = maxi(_ms_best, chain.best)
	var hit = DmMilestones.newly_reached({"totalKills": g.prog.local["totalKills"], "areaKills": g.prog.local["areaKills"], "bestChain": best_chain}, claimed)
	if best_chain > _ms_best:
		_ms_best = best_chain
		store.set_item(CHAIN_BEST_KEY + str(g.hero_id), str(best_chain))
	if hit.is_empty():
		return
	for m in hit:
		claimed.append(m["id"])
		if g.lootview != null:
			g.lootview.gold(Vector3(g.player.x, 0, g.player.z), int(m["gold"]))
		g.toast("Milestone: %s. %s (+%d gold)" % [m["title"], m["text"], int(m["gold"])], "good")
		g.play_sfx("skillUp")
	store.set_item(MILESTONE_KEY + str(g.hero_id), JSON.stringify(claimed))


var seen_wave_tier := -1.0
var night_k := 0.0
var _moon_base := -1.0
var _hemi_base := -1.0


## Wave-milestone banners and the Nightfall light dimming (WorldScene.tickMilestones). Intensity only: never toggle light visibility.
func tick_milestones(dt: float) -> void:
	var tier: float = boss_wave_tier()
	if tier != seen_wave_tier:
		if seen_wave_tier >= 0.0:
			for m in DmContent.get_export("upgrades", "WAVE_MILESTONES"):
				if tier >= float(m["tier"]) and seen_wave_tier < float(m["tier"]):
					g.banner(String(m["name"]), String(m["blurb"]), 3200)
				elif tier < float(m["tier"]) and seen_wave_tier >= float(m["tier"]):
					g.toast("%s fades" % m["name"])
		seen_wave_tier = tier
	var target := 1.0 if DmUpgrades.milestone_active("nightfall", tier) else 0.0
	night_k += (target - night_k) * minf(1.0, dt * 0.8)
	if g.builder == null:
		return
	if _moon_base < 0.0:
		_moon_base = g.builder.moon.light_energy
		_hemi_base = g.builder.env.ambient_light_energy
	var acre: bool = g.area_id == "acre" or g.area_id == "alchemist_wing"
	var night := 0.0 if acre else night_k
	var orchard: bool = g.area_id == "acre"
	g.builder.moon.light_energy = _moon_base * ((3.4 if orchard else (2.65 if acre else 2.4)) / 2.4) * (1.0 - 0.6 * night)
	g.builder.env.ambient_light_energy = _hemi_base * ((2.0 if orchard else (1.12 if acre else 0.95)) / 0.95) * (1.0 - 0.3 * night)


## First kill of an area boss by this character? Recorded in the local store (the web's browser trophy record).
func claim_trophy(id: String) -> bool:
	var store: DmCounselStore = g.store
	var key = DmGuidance.boss_trophy_key(float(g.hero_id))
	var got: Array = DmGuidance.parse_trophies(store.get_item(key) if store.has_item(key) else null)
	if got.has(id):
		return false
	got.append(id)
	store.set_item(key, JSON.stringify(got))
	return true


# ---- surges / bosses -----------------------------------------------------------------------------------------------------------

func on_surge_cleared(ev: Dictionary) -> void:
	var near: bool = g.area_id == String(ev["area"]) or DmSimMath.hypot(float(ev["x"]) - g.player.x, float(ev["z"]) - g.player.z) < 38.0
	if not g.player.alive or not near:
		return
	g.banner("Surge Quelled", "The crypt yields its offering", 3200)
	g.play_sfx("levelUp")
	# Personal reward: a guaranteed item from the area's table plus bonus gold.
	var level = float(DmContent.area(String(ev["area"]))["level"]) + world_levels()
	var diff: Dictionary = DmContent.difficulty(world_difficulty())
	var gold = DmMath.js_round((24.0 + 10.0 * level) * float(DmWaveUpgrades.wave_modifiers(boss_wave_tier())["rewardMult"]) * float(diff["rewardMult"]))
	drop_items(float(ev["x"]), float(ev["z"]), [DmLoot.roll_surge_item(String(ev["area"]), Callable(), String(g.discipline["id"]))], level, "surge")
	if g.lootview != null:
		g.lootview.gold(Vector3(float(ev["x"]), 0, float(ev["z"])), gold)
	if g.visual:
		var glow: int = int(DmContent.spell_fx()["surge"]["glow"])
		g.vfx.emit({"x": ev["x"], "y": 0.4, "z": ev["z"], "count": 70, "color": glow, "spread": 1.0, "speed": 1.2, "up": 4.0, "life": 1.4, "size": 0.34})
		g.vfx.light_flash(Vector3(float(ev["x"]), 2.0, float(ev["z"])), Color.hex(glow * 256 + 255), 70.0, 1.2)


## A boss died: rewards follow the normal-kill rule (a living hero within 38 m of the boss is paid).
func on_boss_defeated(ev: Dictionary) -> void:
	var def: Dictionary = DmContent.boss(String(ev.get("boss", "prelate")))
	if ev.get("killer") == null or not boss_reward_eligible(g.player.alive, DmSimMath.hypot(float(ev["x"]) - g.player.x, float(ev["z"]) - g.player.z)):
		return
	g.chronicle.add("boss." + String(def["id"]))
	if def["id"] == "prelate":
		g.psync.reporter.boss({"boss": def["id"], "tier": boss_wave_tier(), "diff": world_difficulty(), "first": false})
		g.prog.record_prelate_kill()
		if g.prog.can_ascend():
			g.emit_game_event("can_ascend")
	var reward = DmLoot.roll_boss(boss_wave_tier(), Callable(), world_difficulty(), String(def["area"]), float(def["shards"]), String(def["id"]), String(g.discipline["id"]), owned_ids)
	# First kill per character: two more shards and a guaranteed rare-or-better.
	var first_kill: Variant = null
	var first_trophy = false
	if def["id"] != "prelate" and claim_trophy(String(def["id"])):
		first_trophy = true
		reward["shards"] = int(reward["shards"]) + 2
		first_kill = DmLoot.roll_first_kill_item(String(def["area"]), Callable(), String(g.discipline["id"]))
		g.toast("First kill: %s. A trophy for the Codex, two more shards and a rare relic." % def["name"], "good")
	# Relic rune: the Prelate and every first kill always leave one, repeats 35%.
	var rune: Variant = DmLoot.roll_boss_rune(String(def["id"]), first_trophy)
	if rune != null:
		reward["items"].append(rune)
	if def["id"] != "prelate":
		var rep = {"boss": def["id"], "tier": boss_wave_tier(), "diff": world_difficulty(), "first": first_trophy}
		if ev.get("empowered", false) and empower_pending == String(def["id"]) and empower_summon_id != 0:
			rep["summon"] = empower_summon_id
		g.psync.reporter.boss(rep)
	if g.lootview != null:
		g.lootview.gold(Vector3(float(ev["x"]), 0, float(ev["z"])), int(reward["gold"]) + int(reward["materialGold"]))
		g.lootview.shard(Vector3(float(ev["x"]), 0, float(ev["z"])), int(reward["shards"]))
	var boss_level = float(DmContent.area(String(def["area"]))["level"]) + world_levels()
	drop_items(float(ev["x"]), float(ev["z"]), reward["items"], boss_level, "boss")
	if first_kill != null:
		drop_items(float(ev["x"]), float(ev["z"]), [first_kill], boss_level, "first_kill")
	if ev.get("empowered", false) and empower_pending == String(def["id"]):
		claim_empowered(String(def["id"]), float(ev["x"]), float(ev["z"]), boss_level)
	gain_xp(float(reward["xp"]), float(ev["x"]), float(ev["z"]))
	if g.visual:
		g.vfx.light_flash(Vector3(float(ev["x"]), 3.0, float(ev["z"])), Color.hex(0xc6a4ffff), 100.0, 2.0)
	if g.camera != null:
		g.camera.shake(0.7)


## The kill of an Empowered boss this hero called: one server-rolled prize, dropped at the corpse like any loot.
func claim_empowered(id: String, x: float, z: float, level: float) -> void:
	empower_pending = ""
	await g.psync.flush_reports()
	var r: DmResult = await g.api.boss_key_claim(g.hero_id, id, String(g.discipline["id"]), int(level))
	if not _alive:
		return
	if not r.ok:
		g.toast(r.error if r.error != "" else "The Seal's prize could not be rolled.", "err")
		return
	var prize: Dictionary = r.data
	if g.lootview != null:
		g.lootview.item(Vector3(x, 0, z), {"item_id": prize["item_id"], "quantity": 1, "instance": {"id": prize["instance_id"], "ilvl": prize["ilvl"], "affixes": prize["affixes"]}})
	var nm: String = String(DmContent.item(prize["item_id"])["name"])
	g.toast("The Seal's prize: %s, a legendary" % nm if prize.get("legendary", false) else "The Seal's prize: %s" % nm, "good")


func dispose() -> void:
	_alive = false
