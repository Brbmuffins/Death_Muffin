class_name DmCounselEvents
extends RefCounted
## Every Covenant-counsel trigger of the web game, as a named event. DmCounsel.notify(event_id, ctx) resolves an event to the same show(tip, delay, opts)
## calls the web call site makes (archive/legacy-web:src/scenes/WorldScene.ts and DepthsController.ts); `src` is the web file:line of each call. Conditions that
## the web checks at the call site (family == necromancer, hp < 50%...) are evaluated here from plain numbers in `ctx`, so the integrator only reports facts.
## tests/onboarding checks this table against every onboarding.show()/host.tip() call found in the web source (fixtures/callsites.json), both ways.
##
## `src` may list several web lines (comma separated). Each entry: event id -> Array of calls {tip: String | tip_fn: Callable(ctx)->String ("" = none), delay (ms), kind ("" = tip's own), bump, when: Callable(ctx)->bool, src}.

static var _table: Dictionary = {}


static func _c(tip: Variant, src: String, delay: float = 0.0, kind: String = "", bump: bool = false, when: Callable = Callable()) -> Dictionary:
	var d := {"delay": delay, "kind": kind, "bump": bump, "src": src}
	if tip is Callable:
		d["tip_fn"] = tip
	else:
		d["tip"] = tip
	if when.is_valid():
		d["when"] = when
	return d


static func table() -> Dictionary:
	if not _table.is_empty():
		return _table
	var ws := "WorldScene.ts:"
	var dc := "DepthsController.ts:"
	var necro := func(x: Dictionary) -> bool: return String(x.get("family", "")) == "necromancer"
	var rite_tip := func(x: Dictionary) -> String: return String(DmCounselData.data().get("rite_tips", {}).get(String(x.get("ability", "")), ""))
	var first_sight := func(x: Dictionary) -> String: return String(DmCounselData.data().get("first_sight_tips", {}).get(String(x.get("def", "")), ""))
	var in_fight_area := func(x: Dictionary) -> bool: return bool(x.get("near", true)) and not bool(x.get("area_safe", false))
	var loadout_ready := func(x: Dictionary) -> bool:
		return String(x.get("family", "")) == "necromancer" and (int(x.get("learned_rites", 0)) >= 6 or int(x.get("rune_count", 0)) >= 2)
	var sig_level: int = int(DmCounselData.c("SIGNATURE_LEVEL"))
	var t := {}
	# --- Grimoire / rites ---
	t["rite_primary_set"] = [_c(rite_tip, ws + "552")]                      # ctx {ability}: LMB socket changed (first time each level-gated rite is placed)
	t["rite_key_set"] = [_c(rite_tip, ws + "602")]                          # ctx {ability}: a rite placed on a key
	t["grimoire_opened"] = [                                                # ctx {family, owns_rune: bool (bag or socketed)}
		_c("grimoire", ws + "571," + ws + "1828", 0, "asked"),
		_c("runeHunt", ws + "577", 2500, "asked", false, func(x: Dictionary) -> bool: return String(x.get("family", "")) == "necromancer" and not bool(x.get("owns_rune", false))),
	]
	t["rune_socketed"] = [_c("runeSocketed", ws + "1047", 1200)]
	t["necro_weapon_changed"] = [_c("necroWeapon", ws + "1085", 0, "", false,  # ctx {main, was_main}: worn weapon line changed (not a staff)
		func(x: Dictionary) -> bool: return String(x.get("main", "")) != String(x.get("was_main", "")) and String(x.get("main", "")) != "" and String(x.get("main", "")) != "staff")]
	t["set_bonus_gained"] = [_c("setBonus", ws + "1097")]
	t["loadout_check"] = [_c("loadouts", ws + "1036", 0, "", false, loadout_ready)]   # ctx {family, learned_rites, rune_count}
	# --- world entry, levels ---
	t["world_entered"] = [                                                  # ctx {family, level, grimoire_unlocked}
		_c("welcome", ws + "881", 900),
		_c("knight_rage", ws + "883", 2600, "", false, func(x: Dictionary) -> bool: return String(x.get("family", "")) == "knight"),
		_c("warden_oil", ws + "884", 2600, "", false, func(x: Dictionary) -> bool: return String(x.get("family", "")) == "warden"),
		_c("monk_beat", ws + "885", 2600, "", false, func(x: Dictionary) -> bool: return String(x.get("family", "")) == "monk"),
		_c("witch_offal", ws + "886", 2600, "", false, func(x: Dictionary) -> bool: return String(x.get("family", "")) == "witch"),
		_c("veil_forms", ws + "887", 2600, "", false, func(x: Dictionary) -> bool: return String(x.get("family", "")) == "veil"),
		_c("reaper_souls", ws + "888", 2600, "", false, func(x: Dictionary) -> bool: return String(x.get("family", "")) == "reaper"),
		_c("signature", ws + "888", 4000, "", false, func(x: Dictionary) -> bool: return int(x.get("level", 1)) >= sig_level),
		_c("grimoire", ws + "889", 4500, "", false, func(x: Dictionary) -> bool: return bool(x.get("grimoire_unlocked", false))),
	]
	t["level_up"] = [                                                       # ctx {level, grimoire_unlocked, family, learned_rites, rune_count}
		_c("signature", ws + "4427", 3000, "", false, func(x: Dictionary) -> bool: return int(x.get("level", 1)) >= sig_level),
		_c("grimoire", ws + "4437", 3200, "", false, func(x: Dictionary) -> bool: return bool(x.get("grimoire_unlocked", false))),
		_c("loadouts", ws + "1036", 0, "", false, loadout_ready),
	]
	# --- bag / gear / panels ---
	t["bag_changed"] = [                                                    # ctx {slots_used, bag_size, family, kit_candidates: bool, owns_rune: bool, learned_rites, rune_count}
		_c("bag_filling", ws + "938", 0, "", false, func(x: Dictionary) -> bool: return int(x.get("slots_used", 0)) >= ceili(float(x.get("bag_size", DmCounselData.c("BAG_SIZE"))) * 0.8)),
		_c("legion", ws + "940", 0, "", false, func(x: Dictionary) -> bool: return String(x.get("family", "")) == "necromancer" and bool(x.get("kit_candidates", false))),
		_c("rune", ws + "942", 0, "", false, func(x: Dictionary) -> bool: return String(x.get("family", "")) == "necromancer" and bool(x.get("owns_rune", false))),
		_c("loadouts", ws + "1036", 0, "", false, loadout_ready),
	]
	t["gear_equipped"] = [_c("gearEquip", ws + "1235")]
	t["tool_belted"] = [_c("toolBelt", ws + "1237", 0, "", true)]
	t["stat_sheet_opened"] = [_c("statSheet", ws + "1238")]
	t["reforge_done"] = [_c("reforge", ws + "1284", 0, "asked")]
	t["vault_opened"] = [_c("vault", ws + "1306")]
	t["salvage_opened"] = [_c("salvage", ws + "1307")]
	t["salvaged"] = [_c("salvage", ws + "1686")]
	t["class_panel_opened"] = [_c("change_class", ws + "1330")]
	t["bag_full"] = [_c("bag_full", ws + "782")]                            # gathering stopped: bagFull
	t["collected"] = [                                                      # ctx {gear, legendary, armor, reagent, affixed: bool} (any item in the pickup matches)
		_c("relic", ws + "4165"),
		_c("atlas", ws + "4168", 2500, "", false, func(x: Dictionary) -> bool: return bool(x.get("gear", false))),
		_c("legendary", ws + "4172", 600, "", false, func(x: Dictionary) -> bool: return bool(x.get("legendary", false))),
		_c("armor", ws + "4173", 0, "", false, func(x: Dictionary) -> bool: return not bool(x.get("legendary", false)) and bool(x.get("armor", false))),
		_c("reagent", ws + "4174", 0, "", true, func(x: Dictionary) -> bool: return bool(x.get("reagent", false))),
		_c("affix", ws + "4175", 1800, "", false, func(x: Dictionary) -> bool: return bool(x.get("affixed", false))),
	]
	# --- professions / places ---
	t["laborers_seen"] = [_c("laborers_working", ws + "670", 1500)]
	t["gather_started"] = [_c("gather", ws + "2087"), _c("rich_node", ws + "2088", 0, "", false, func(x: Dictionary) -> bool: return bool(x.get("rich", false)))]   # ctx {rich}
	t["skill_up"] = [_c("skill_up", ws + "3236")]
	t["station_opened"] = [_c("station", ws + "2477")]
	t["cauldron_opened"] = [_c("wing", ws + "2484")]
	t["reagent_shelf_opened"] = [_c("wing", ws + "2490")]
	t["lectern_used"] = [_c("codex", ws + "2508", 0, "asked")]
	t["meal_eaten"] = [_c("meal", ws + "2249")]
	t["brew_drunk"] = [_c("brew", ws + "2263")]
	t["npc_first_sight"] = [_c("people", ws + "1609", 45000)]
	t["minimap_travel"] = [_c("minimap", ws + "2063")]
	t["area_first_entered"] = [                                             # ctx {area}: the first time the hero enters it this session (WorldScene announcedAreas)
		_c("cloister", ws + "5557", 4500, "", false, func(x: Dictionary) -> bool: return x.get("area", "") == "cloister"),
		_c("pyre", ws + "5558", 4500, "", false, func(x: Dictionary) -> bool: return x.get("area", "") == "pyre"),
		_c("fen", ws + "5559", 4500, "", false, func(x: Dictionary) -> bool: return x.get("area", "") == "fen"),
		_c("warren", ws + "5560", 4500, "", false, func(x: Dictionary) -> bool: return x.get("area", "") == "warren"),
		_c("wing", ws + "5561", 4500, "calm", false, func(x: Dictionary) -> bool: return x.get("area", "") == "alchemist_wing"),
		_c("coliseum", ws + "5562", 4500, "", false, func(x: Dictionary) -> bool: return x.get("area", "") == "coliseum"),
		_c("acre", ws + "5580", 4500, "", false, func(x: Dictionary) -> bool: return x.get("area", "") == "acre"),
	]
	t["omen_told"] = [_c("omen", ws + "5578", 150000)]
	# --- fight ---
	t["auto_combat_cast"] = [_c("auto_combat", ws + "2202")]
	t["essence_short"] = [_c("essence", ws + "2216")]
	t["enemy_spawned"] = [                                                  # ctx {def, elite, near: within 40 m (default true), area_safe}
		_c("deacon", ws + "3682", 0, "", false, func(x: Dictionary) -> bool: return in_fight_area.call(x) and String(x.get("def", "")) == "deacon"),
		_c(first_sight, ws + "3684", 600, "", false, in_fight_area),
		_c("elite", ws + "3685", 0, "", false, func(x: Dictionary) -> bool: return in_fight_area.call(x) and bool(x.get("elite", false))),
		_c("move", ws + "3687", 0, "", false, in_fight_area),
	]
	t["corpse_near"] = [_c("exhume", ws + "3692", 0, "", false, func(x: Dictionary) -> bool: return not bool(x.get("area_safe", false)) and float(x.get("dist", 99.0)) < 12.0)]   # ctx {area_safe, dist}
	t["sanctify_near"] = [_c("sanctify", ws + "3616", 0, "", false, func(x: Dictionary) -> bool: return float(x.get("dist", 99.0)) < 18.0)]   # ctx {dist}
	t["surge_opened"] = [_c("surge", ws + "4074", 1200)]                    # only when the surge is in the hero's own area
	t["chain_started"] = [_c("chain", ws + "4224", 400)]
	t["souls_charged"] = [_c("souls", ws + "4407")]
	t["hurt_check"] = [_c("hurt", ws + "4497", 0, "", false, func(x: Dictionary) -> bool: return float(x.get("hp", 1.0)) < float(x.get("max_hp", 1.0)) * 0.5)]   # ctx {hp, max_hp}
	t["can_ascend"] = [_c("ascend", ws + "5101", 5000)]
	# --- Depths ---
	t["depths_solo"] = [_c("depths_solo", dc + "224", 600, "asked")]
	t["depths_floor"] = [_c("depths_floor", dc + "245", 1800, "asked")]
	t["depths_affix"] = [_c("depths_affix", dc + "304", 2500, "asked", false, func(x: Dictionary) -> bool: return int(x.get("extras", 0)) > 0)]   # ctx {extras}
	t["depths_chest"] = [_c("depths_chest", dc + "367", 1500, "asked")]
	t["depths_stair_near"] = [_c("depths", dc + "422")]
	# --- Settings -> Show tips again (after DmCounsel.reset) ---
	t["show_tips_again"] = [                                                # ctx {atlas_revealed, spells_revealed}
		_c("minimap", ws + "1320", 0, "calm"),
		_c("belt", ws + "1321", 0, "calm"),
		_c("atlas", ws + "1322", 0, "calm", false, func(x: Dictionary) -> bool: return bool(x.get("atlas_revealed", false))),
		_c("grimoire", ws + "1323", 0, "calm", false, func(x: Dictionary) -> bool: return bool(x.get("spells_revealed", false))),
		_c("codex", ws + "1324", 0, "calm"),
	]
	_table = t
	return _table


static func _resolve(c: Dictionary, ctx: Dictionary) -> Dictionary:
	if c.has("when") and not bool((c["when"] as Callable).call(ctx)):
		return {}
	var tip := String(c["tip"]) if c.has("tip") else String((c["tip_fn"] as Callable).call(ctx))
	if tip == "":
		return {}
	var opts: Variant = null
	if c["kind"] != "":
		opts = {"kind": c["kind"]}
	elif c["bump"]:
		opts = true
	return {"tip": tip, "delay": float(c["delay"]), "opts": opts, "kind": c["kind"], "bump": c["bump"], "src": c["src"]}


## The show() calls an event makes, in the web's order.
static func calls(event_id: String, ctx: Dictionary = {}) -> Array:
	var out: Array = []
	var specs: Array = table().get(event_id, [])
	if specs.is_empty():
		push_warning("unknown counsel event: %s" % event_id)
	for c in specs:
		var r := _resolve(c, ctx)
		if not r.is_empty():
			out.append(r)
	return out


## WorldScene.tickOnboarding (re-checked every 400 ms): the state-driven triggers, in the web's order. ctx (plain facts):
## wave_affordable (waveCost != null && gold >= cost), thralls_mine, corpses_near (within 7 m), pack_on_corpse, family, level, total_kills,
## has_tool, has_belt_item, shards, boss_near: Array of boss ids whose summon object is within 12 m ("gravedigger","abbess","congregation","saint","regent","mire"),
## has_seal, area, cheapest_unlock (cost of the cheapest locked vow/boon; INF if none), boss_kills, ascension, ashes, gate_near (a closed door within 6 m).
static func tick_calls(ctx: Dictionary) -> Array:
	var ws := "WorldScene.ts:"
	var out: Array = []
	var add := func(tip: String, src: String, bump: bool = false) -> void:
		out.append({"tip": tip, "delay": 0.0, "opts": true if bump else null, "kind": "", "bump": bump, "src": ws + src})
	var necro := String(ctx.get("family", "")) == "necromancer"
	var kills := int(ctx.get("total_kills", 0))
	if bool(ctx.get("wave_affordable", false)):
		add.call("wave", "3761")
	if int(ctx.get("thralls_mine", 0)) >= 1:
		add.call("thrall", "3764")
	if necro and int(ctx.get("thralls_mine", 0)) + int(ctx.get("corpses_near", 0)) >= 4 and int(ctx.get("level", 1)) >= 2:
		add.call("litany", "3776")
	if necro and bool(ctx.get("pack_on_corpse", false)) and kills >= 15:
		add.call("burst", "3777")
	if kills >= 40:
		add.call("codex", "3778")
	if bool(ctx.get("has_tool", false)):
		add.call("tool", "3779")
	if bool(ctx.get("has_belt_item", false)):
		add.call("belt", "3781")
	if int(ctx.get("shards", 0)) >= int(DmCounselData.c("BOSS_SUMMON_SHARDS")):
		add.call("prelate", "3782")
	for id in ctx.get("boss_near", []):
		add.call("boss_%s" % id, "3787")
		if bool(ctx.get("has_seal", false)):
			add.call("boss_seal", "3788")
	if String(ctx.get("area", "")) == "chapterhouse":
		var cheapest := float(ctx.get("cheapest_unlock", INF))
		if cheapest != INF and int(ctx.get("shards", 0)) >= cheapest + float(DmCounselData.c("BOSS_SUMMON_SHARDS")) and kills >= 200:
			add.call("altar_unlocks", "3794")
		if int(ctx.get("boss_kills", 0)) >= 1 or kills >= 400:
			add.call("vows", "3795")
	if int(ctx.get("ascension", 0)) > 0 and int(ctx.get("ashes", 0)) > 0 and String(ctx.get("area", "")) == "chapterhouse":
		add.call("boons", "3797")
	if bool(ctx.get("gate_near", false)):
		add.call("gate", "3804")
	return out
