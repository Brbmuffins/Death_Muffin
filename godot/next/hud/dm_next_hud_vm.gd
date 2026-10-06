class_name DmNextHudVm
extends RefCounted
## The slice's HUD view-model (godot/ui/hud/README.md schema) built from DmNextGame / DmHeroBody / DmRiteCaster / DmThrallHost / DmStatusSet,
## the counterpart of DmGameHud.build for the old DmGame. Slot and minimap sub-dictionaries are reused between calls (the HUD is applied at
## 20 Hz by DmGameUi; only the enemy/thrall/corpse lists and the top-level dictionary are new each time).

const SLOT_KEYS := ["1", "2", "3", "4", "RMB", "R"]
const STATUS_ICON := {
	"fracture": ["fracture.webp", "Fracture"], "withered": ["withered.webp", "Withered"], "slow": ["void-rot.webp", "Miasma"],
	"ward_slow": ["void-rot.webp", "Ward"], "bleed": ["hemorrhage.webp", "Hemorrhage"], "chill": ["chilled.webp", "Chilled"],
	"silence": ["silenced.webp", "Silenced"], "incensed": ["incensed.webp", "Incensed"], "hex": ["cursed.webp", "Bone Hex"],
	"sanctified": ["sanctified.webp", "Sanctified"],
}

var host: DmNextUiHost
var _slots: Array[Dictionary] = []
var _primary := {"icon": "", "key": "LMB"}
var _map := {}
var _areas: Array = []
var _doors: Array = []
var _area_sig := ""
var _ward_vm := {}
var _omen_vm := {}
var _aff_id := 0                ## the target whose elite-affix chips are cached (instance id) ...
var _aff_n := -1                ## ... and how many affixes it bore then (the Shrouded one can be stripped)
var _aff_chips: Array = []
var _aff_blurb := ""


func _init(host_: DmNextUiHost) -> void:
	host = host_


func build() -> Dictionary:
	var g: DmNextGame = host.shell
	var b: DmHeroBody = g.local_body()
	if b == null:
		return {}
	var family := b.family
	var level := float(host.character.get("level", 1))
	var vm := {
		"hp": b.hp, "max_hp": b.max_hp, "barrier": 0.0,
		"essence": b.resource, "max_essence": b.resource_max,
		"resource_label": DmResources.label_for(family), "resource_color": DmResources.color_for(family) if family != "necromancer" else "",
		"level": int(level), "xp": host.character.get("experience", 0), "xp_next": DmStats.xp_to_next(level),
		"gold": int(host.character.get("gold", 0)), "shards": int(host.progress.get("shards", 0)),
		"area_name": String(DmContent.area(g.area_id).get("name", "")), "area_progress": _area_progress(g.area_id),
		"primary": _primary_slot(b), "slots": _slot_list(b, level),
		"target": _target(g), "boss": _boss(g), "party": _party(g), "minimap": _minimap(g, b),
		"brews": _brews(), "death": {"show": not b.alive, "sub": "The Chapterhouse will call you back…"},
		"damage": {"tier": host.progress["damageTier"], "pct": DmUpgrades.damage_bonus_pct(float(host.progress["damageTier"])), "cost": null if host.prog.damage_cost() == -1 else host.prog.damage_cost()},
		"wave": {"owned": host.progress["waveTierOwned"], "active": host.progress["waveTierActive"], "pct": DmWaveUpgrades.wave_modifiers(float(host.progress["waveTierActive"]))["speedPct"],
			"cost": null if host.prog.wave_cost() == -1 else host.prog.wave_cost()},
		"souls": b.p["souls"] if not b.p.is_empty() else 0, "souls_max": b.p["soulsMax"] if not b.p.is_empty() else 50, "raises_thralls": family == "necromancer",
		"ward": _ward(b), "chain": _chain(g, b), "omen": _omen(g), "save": host.save_chip(),
	}
	vm["prompt"] = g.chapterhouse.prompt_text if g.chapterhouse != null else null
	vm["depth"] = g.depths.hud_state() if g.depths != null else null   # the Depths readout (depth, kills / quota, stair, chest)
	var th := b.get_node_or_null("Thralls") as DmThrallHost
	vm["thralls"] = int(th.places_used()) if th != null else 0
	vm["thrall_cap"] = int(host.build_cache()["discipline"]["mods"]["thrallCap"])
	return vm


## The boss bar (the current game's DmGameHud.boss shape): the awake boss of this peer's world, hp from the body.
func _boss(g: DmNextGame) -> Variant:
	var b := g.bosses.active_boss() if g.bosses != null else null
	if b == null:
		return null
	var def: Dictionary = DmContent.boss(b.boss_id)
	return {"name": ("Empowered " if b.bstate.empowered else "") + String(def["name"]), "phase": b.phase, "hp": b.hp, "max_hp": b.max_hp, "phases": def["phases"]}


# ---- hotbar -----------------------------------------------------------------------------------------------------------------------

func _primary_slot(b: DmHeroBody) -> Dictionary:
	var d := DmAbilities.def(host.primary)
	_primary["icon"] = DmGameHud.art(String(d["icon"]).replace("art/", ""))
	_fill(_primary, host.primary, b, float(host.character.get("level", 1)), "LMB")
	return _primary


func _slot_list(b: DmHeroBody, level: float) -> Array:
	var n: int = host.keys.size() + (1 if host.signature != "" else 0)   # keys 1-4 + RMB, then R (the signature)
	while _slots.size() < n:
		_slots.append({"alt": _slots.size() == 4, "swap": false, "rune_icon": "", "empowered": false})
	for i in n:
		var s := _slots[i]
		var id: String = host.keys[i] if i < host.keys.size() else host.signature
		s["icon"] = DmGameHud.art(String(DmAbilities.def(id)["icon"]).replace("art/", ""))
		_fill(s, id, b, level, SLOT_KEYS[i] if i < SLOT_KEYS.size() else "")
	return _slots.slice(0, n)


## Cost, cooldown sweep, affordable / locked flags of one rite. Cooldown comes from the caster's state (the host's numbers).
func _fill(s: Dictionary, id: String, b: DmHeroBody, level: float, key: String) -> void:
	var d := DmAbilities.def(id)
	var caster := b.get_node_or_null("Rites") as DmRiteCaster
	var base := float(d["cooldownMs"])
	var total := base
	if caster != null and caster.p.has("loadout"):
		total = DmWeaponLine.ability_cooldown_ms(id, base, caster.p["loadout"], DmAbilities.is_primary(id))
	s["key"] = key
	s["cost"] = d["essenceCost"]
	s["left_ms"] = caster.cooldown_left(id) if caster != null else 0.0
	s["total_ms"] = total
	var emp := not b.p.is_empty() and DmAbilities.empowered(b.p, id)   # Soul Harvest: charged souls make this rite free
	s["empowered"] = emp
	s["affordable"] = emp or b.resource >= float(d["essenceCost"])
	s["locked"] = DmAbilities.rite_level(level, host.dev_access) < DmAbilities.unlock_level(id)
	s["unlock_level"] = DmAbilities.unlock_level(id)


# ---- meta feeds: Bone Ward chip, Kill Chain meter, Omen chip (the DmGameHud shapes) ------------------------------------------------------

## The Ossuary's Bone Ward (wardPerThrall x living thralls, at most 60 %): {pct, thralls, per_thrall} or null.
func _ward(b: DmHeroBody) -> Variant:
	var per := float(b.mods.get("wardPerThrall", 0.0))
	var th := b.get_node_or_null("Thralls") as DmThrallHost
	if per <= 0.0 or th == null:
		return null
	var n := th.count()
	var pct := DmMath.js_round(minf(0.6, per * n) * 100.0)
	if pct <= 0:
		return null
	_ward_vm["pct"] = pct
	_ward_vm["thralls"] = n
	_ward_vm["per_thrall"] = per
	return _ward_vm


func _chain(g: DmNextGame, b: DmHeroBody) -> Variant:
	if g.meta == null or not g.meta.member.chain.active() or not b.alive:
		return null
	var c: DmKillChain = g.meta.member.chain
	var t: Variant = c.tier()
	var tiers: Array = DmProgContent.get_data()["chain"]["tiers"]
	return {"count": c.count, "name": t["name"] if t != null else "Chain", "bonus": t["bonus"] if t != null else 0.0, "frac": c.frac(g.rewards.clock_ms()),
		"tier": (tiers.find(t) + 1) if t != null else 0}


func _omen(g: DmNextGame) -> Variant:
	if g.meta == null or g.meta.omen.is_empty():
		return null
	if _omen_vm.get("name") != g.meta.omen["name"]:   # the Omen changes with the week or a test, not per frame
		_omen_vm["name"] = g.meta.omen["name"]
		_omen_vm["icon"] = DmGameHud.art(String(g.meta.omen["icon"]).replace("art/", ""))
		_omen_vm["blurb"] = g.meta.omen["blurb"]
	_omen_vm["visible"] = not bool(DmContent.area(g.area_id)["safe"])
	return _omen_vm


# ---- belt (Q heal flask with its cooldown, Z / X brews: DmNextBelt) -------------------------------------------------------------

func _brews() -> Array:
	if host.shell.progress != null and host.shell.progress.belt.inventory != null:
		return host.shell.progress.belt.rows()
	return []


# ---- target frame, party, area line ----------------------------------------------------------------------------------------------

func _target(g: DmNextGame) -> Variant:
	var e := host.target_enemy()
	if e == null:
		return null
	var d: Dictionary = DmContent.enemy(e.def_id)
	var statuses: Array = []
	var set_ := DmStatusSet.of(e)
	if set_ != null:
		for id in set_.ids():
			var m: Variant = STATUS_ICON.get(String(id))
			if m != null:
				statuses.append({"icon": DmGameHud.art("status/" + m[0]), "label": m[1], "n": set_.stacks(id)})
	var chips := _affix_chips(e, String(d.get("blurb", "")))
	return {"name": d.get("name", e.def_id), "elite": bool(e.get_meta("dm_elite", false)), "affixes": chips, "hp": e.hp, "max_hp": e.max_hp,
		"statuses": statuses, "blurb": _aff_blurb}


## The elite's chips ([{id, name}], DmGameHud's shape) and the blurb listing every affix. Built from the replicated meta `dm_affix_list`,
## cached per target: rebuilt only when the target (or its affix count) changes, so a held target costs nothing per frame.
func _affix_chips(e: DmEnemy, base_blurb: String) -> Array:
	var key := e.get_instance_id()
	var list: PackedStringArray = e.get_meta(&"dm_affix_list") if e.has_meta(&"dm_affix_list") else PackedStringArray()
	var n := list.size()
	if key == _aff_id and n == _aff_n:
		return _aff_chips
	_aff_id = key
	_aff_n = n
	_aff_chips = []
	_aff_blurb = base_blurb
	if n > 0:
		var ed: Dictionary = DmContent.get_export("enemies", "ELITE_AFFIXES")
		var parts: Array = []
		for a in list:
			var ad: Variant = ed.get(a)
			if ad == null:
				continue
			_aff_chips.append({"id": a, "name": ad["name"]})
			parts.append(ad["blurb"])
		if not parts.is_empty():
			_aff_blurb = " ".join(parts)
	return _aff_chips


func _party(g: DmNextGame) -> Array:
	var out: Array = []
	for r in g.roster():
		var b := r["body"] as DmHeroBody
		if b == null:
			continue
		var d := DmContent.discipline(String(r["discipline"]))
		var lvl := int(host.character.get("level", 1)) if b == g.local_body() else int(b.character.get("level", 1))
		out.append({"id": int(r["peer_id"]), "name": String(r["name"]), "discipline": "%s · Level %d" % [d.get("name", r["discipline"]), lvl],
			"portrait": DmGameHud.art("portraits/%s.webp" % r["discipline"]), "hp_frac": b.hp / maxf(b.max_hp, 1.0)})
		if out.size() >= 4:
			break
	return out


func _area_progress(area: String) -> String:
	if area == "chapterhouse":
		return "Walk north to the Hollow Graves · Click an enemy to attack · Keys 1-5 cast your rites"
	if area == "depths" and host.shell.depths != null and host.shell.depths.active():
		return host.shell.depths.progress_line()
	var def := DmContent.area(area)
	if bool(def.get("safe", false)):
		return "Sanctuary. The dead cannot follow you here."
	return "<b>%d</b> slain here · Level %d dead" % [host.kills_in(area), int(float(def.get("level", 1)))]


# ---- minimap -------------------------------------------------------------------------------------------------------------------

## The suggestion ping (WorldScene minimap `ping`): where the Next box's suggestion is, when it is elsewhere or marked pingInPlace. The Next box's
## own suggestion dictionary is read, nothing is allocated.
func _guide_ping(g: DmNextGame) -> Variant:
	var cur: Variant = g.ui.guidance_hud.current if g.ui != null else null
	if cur == null or cur.get("target") == null:
		return null
	var st: Dictionary = host.settings
	if not (bool(st.get("guidance", true)) and bool(st.get("guide_ping", true))):
		return null
	return cur["target"] if (bool(cur.get("pingInPlace", false)) or String(cur.get("place", "")) != g.area_id) else null


func _minimap(g: DmNextGame, b: DmHeroBody) -> Dictionary:
	if _areas.is_empty():
		for id in DmContent.area_order():
			var a: Dictionary = DmContent.area(id)
			_areas.append({"id": id, "rect": a["rect"], "safe": a["safe"], "unlocked": false, "instance": a.get("instance", false)})
		for d in DmContent.doors():
			_doors.append({"rect": d["rect"], "open": false, "id": d["id"]})
	# What the slice actually built is what is unlocked / open (world.builder.area_nodes, door nav regions).
	var builder: DmWorldBuilder = g.world.builder
	if builder != null:
		for a in _areas:
			a["unlocked"] = builder.unlocked.has(a["id"])
		for d in _doors:
			d["open"] = g.chapterhouse.door_open(String(d["id"])) if g.chapterhouse != null else builder.nav_regions.has("door:" + String(d["id"]))
	var enemies: Array = []
	for e in g.director.enemies.values():
		var en := e as DmEnemy
		if en != null and is_instance_valid(en) and en.sm != null and en.sm.id() != DmEnemyState.Id.DEAD:
			enemies.append({"x": en.position.x, "z": en.position.z, "elite": bool(en.get_meta("dm_elite", false))})
	var thralls: Array = []
	var th := b.get_node_or_null("Thralls") as DmThrallHost
	if th != null:
		for t in th.list():
			thralls.append({"x": t.position.x, "z": t.position.z})
	var corpses: Array = []
	for c in g.corpses.corpses.values():
		corpses.append({"x": c.x, "z": c.z})
	_map["px"] = b.position.x
	_map["pz"] = b.position.z
	_map["facing"] = b.yaw
	_map["areas"] = _areas
	_map["doors"] = _doors
	_map["enemies"] = enemies
	_map["thralls"] = thralls
	_map["allies"] = []
	_map["corpses"] = corpses
	var bb := g.bosses.active_boss() if g.bosses != null else null
	_map["boss"] = {"x": bb.position.x, "z": bb.position.z} if bb != null else null
	_map["waystones"] = []
	_map["stairs"] = []
	_map["npcs"] = []
	_map["ping"] = _guide_ping(g)
	_map["destination"] = null
	_map["depths"] = g.depths.map_floor() if g.depths != null else null
	return _map
