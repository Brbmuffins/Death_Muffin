class_name DmNextHudVm
extends RefCounted
## The HUD's view-model (godot/ui/hud/README.md schema) built from the combat core and the game scene's hero (client/code.list "Ported"). Today's builder reads
## nodes (DmEnemy, DmThrallHost, DmCorpseField); this one reads the core's bulk arrays and a few queries, ONCE per HUD refresh (20 Hz), never per creature per frame:
##   - the target frame: one `enemy_info` and one `statuses` read for the one enemy under the cursor;
##   - the minimap's dots: `enemy_ids / enemy_positions / enemy_states`, `thrall_ids / thrall_positions`, `corpse_positions` (flat arrays, one pass each);
##   - the thrall count, places and how many are hurt: `thrall_count / thrall_places` and `thrall_owners / thrall_hp / thrall_states`;
##   - the "no corpse" dimming: one `corpses_in_radius` query around the hero;
##   - cooldowns, essence and the cast state: the hero's caster (`DmRiteCaster`), as today;
##   - the belt, the Kill Chain and the Omen: the game's progression and meta (DmNextBelt.rows, the member's DmKillChain, DmNextMeta.omen), as today.
## The minimap's dots are flat arrays (x, z and a flag per dot) rewritten in place, never a dictionary per creature. The host is the panels' adapter (DmNextUiHost): it keeps what
## the view-model needs besides the game (character, progression, the last targeted enemy, kills per area).

const SLOT_KEYS := ["1", "2", "3", "4", "RMB", "R"]
const STATUS_ICON := {
	"fracture": ["fracture.webp", "Fracture"], "withered": ["withered.webp", "Withered"], "slow": ["void-rot.webp", "Miasma"],
	"ward_slow": ["void-rot.webp", "Ward"], "bleed": ["hemorrhage.webp", "Hemorrhage"], "chill": ["chilled.webp", "Chilled"],
	"silence": ["silenced.webp", "Silenced"], "incensed": ["incensed.webp", "Incensed"], "hex": ["cursed.webp", "Bone Hex"],
	"sanctified": ["sanctified.webp", "Sanctified"],
}
const STACKED := ["fracture", "withered"]   ## statuses whose stack count the frame prints (the core's byte caps at 255; Withered goes past it)

## What a rite needs besides essence, so the bar can say "no corpse" / "no legion" before a press is refused (rite_*.gd validate: no_corpse / no_thralls).
const NEEDS := {"exhume": "corpse", "corpse_explosion": "corpse", "grave_offering": "corpse", "grave_step": "corpse", "carrion_seed": "corpse",
	"rally_dead": "legion", "command_rend": "legion"}
const CORPSE_REACH := 13.0   ## the longest corpse pick of those rites (grave offering 13 m); the nearest corpse inside it makes them usable
const LOW_HP_ENTER := 0.35   ## a thrall under this share of its health is "hurt" (DmThrall.LOW_HP_ENTER: its pip is red)
const DEAD := DmCoreEvents.State.DEAD
const THRALL_DEAD := DmCoreEvents.ThrallState.DEAD

var host: DmNextUiHost
var _corpse_near := true     ## a usable corpse lies within CORPSE_REACH of the hero (refreshed once per build, not per slot)
var _legion_n := 1
var _area_id := "\u0001"
var _area_def: Dictionary = {}
var _rites := {}   ## id -> static rite facts (_rite)
var _slots: Array[Dictionary] = []
var _primary := {"icon": "", "key": "LMB"}
var _map := {}
var _dest := {"x": 0.0, "z": 0.0}   ## the pooled minimap destination dict
var _areas: Array = []
var _doors: Array = []
var _enemy_dots := PackedFloat32Array()    ## minimap dots, rewritten in place at each refresh: enemies x, z, elite (1 / 0) ...
var _thrall_dots := PackedFloat32Array()   ## ... living thralls x, z, yaw
var _allies := PackedFloat32Array()        ## ... allies (none yet)
var _none: Array = []
var _ward_vm := {}
var _omen_vm := {}
var _vm := {}                  ## the view-model, kept and rewritten
var _boss_vm := {}             ## the boss plate's dictionary, rewritten in place
var _boss_dot := {"x": 0.0, "z": 0.0}
var _static_sig: Array = []    ## what the static part of it was built from
var _death_alive := {"show": false, "sub": "The Chapterhouse will call you back…"}
var _death_dead := {"show": true, "sub": "The Chapterhouse will call you back…"}
var _slot_view: Array = []     ## the slots handed to the HUD (rewritten in place)
var _aff_id := 0                ## the target whose elite-affix chips are cached (the core id) ...
var _aff_n := -1                ## ... and how many affixes it bore then (the Shrouded one can be stripped)
var _aff_chips: Array = []
var _aff_blurb := ""


func _init(host_: DmNextUiHost) -> void:
	host = host_


## The view-model of this refresh. One dictionary is kept and rewritten (the HUD reads it and keeps nothing of it); what only changes with the character or the area (level,
## XP, gold, tiers, labels, the thrall cap) is rebuilt when its inputs change, not every 50 ms.
func build() -> Dictionary:
	var g: DmNextGame = host.game
	var b: DmHeroBody = g.local_body()
	if b == null:
		return {}
	var sp := soul_state(b)
	var bag := b.family == "reaper"   # the Reaper's energy orb IS her soul bag
	var souls := int(sp.get("souls", 0))
	var vm := _vm
	_refresh_static(g, b)
	vm["hp"] = b.hp
	vm["max_hp"] = b.max_hp
	vm["essence"] = float(souls) if bag else b.resource
	vm["max_essence"] = float(sp.get("soulsMax", 30.0)) if bag else b.resource_max
	vm["area_progress"] = _area_progress(g.area_id)
	vm["primary"] = _primary_slot(b)
	vm["slots"] = _slot_list(b, float(host.character.get("level", 1)))
	vm["target"] = _target()
	vm["boss"] = _boss(g)
	vm["party"] = _party(g)
	vm["minimap"] = _minimap(g, b)
	vm["death"] = _death_alive if b.alive else _death_dead
	vm["souls"] = souls
	vm["souls_max"] = sp.get("soulsMax", 30 if bag else 50)
	vm["ward"] = _ward(b)
	vm["save"] = host.save_chip()
	vm["brews"] = _brews(g)
	vm["chain"] = _chain(g, b)
	vm["omen"] = _omen(g)
	vm["prompt"] = g.chapterhouse.prompt_text if g.chapterhouse != null else null   # the hub's hover / nearby prompt (the stair's among them)
	vm["depth"] = g.depths.hud_state() if g.depths != null else null   # the Depths readout (depth, kills / quota, stair, chest)
	var core: RefCounted = g.core_host.core
	vm["thralls"] = int(core.thrall_places(b.core_id))
	vm["thrall_hurt"] = _legion_hurt(core, b.core_id)
	return vm


## What changes with the character, its progression or the area, not with the fight: rebuilt when one of them did.
func _refresh_static(g: DmNextGame, b: DmHeroBody) -> void:
	var ch := host.character
	var progress := host.progress
	var sig := [ch.get("level"), ch.get("experience"), ch.get("gold"), progress.get("shards"), progress.get("damageTier"), progress.get("waveTierOwned"), progress.get("waveTierActive"),
		g.area_id, b.family, b.mods.get("thrallCap")]
	if sig == _static_sig:
		return
	_static_sig = sig
	var family := b.family
	var level := float(ch.get("level", 1))
	var bag := family == "reaper"
	var vm := _vm
	vm["resource_label"] = DmResources.label_for(family)
	vm["resource_color"] = DmResources.color_for(family) if family != "necromancer" else ""
	vm["level"] = int(level)
	vm["xp"] = ch.get("experience", 0)
	vm["xp_next"] = DmStats.xp_to_next(level)
	vm["gold"] = int(ch.get("gold", 0))
	vm["shards"] = int(progress.get("shards", 0))
	vm["area_name"] = String(_area(g.area_id).get("name", ""))
	vm["party_world"] = ""
	vm["damage"] = {"tier": progress["damageTier"], "pct": DmUpgrades.damage_bonus_pct(float(progress["damageTier"])), "cost": null if host.prog.damage_cost() == -1 else host.prog.damage_cost()}
	vm["wave"] = {"owned": progress["waveTierOwned"], "active": progress["waveTierActive"], "pct": DmWaveUpgrades.wave_modifiers(float(progress["waveTierActive"]))["speedPct"],
		"cost": null if host.prog.wave_cost() == -1 else host.prog.wave_cost()}
	vm["raises_thralls"] = family == "necromancer"
	vm["soul_bag"] = bag
	vm["thrall_cap"] = int(b.mods.get("thrallCap", 0))


## Soul Harvest numbers ({souls, soulsMax}): the host's hero reads its own state; a joiner's hero is a puppet (empty `p`), so it reads what the
## host's caster last sent it. {} before anything arrived.
static func soul_state(b: DmHeroBody) -> Dictionary:
	if not b.p.is_empty():
		return b.p
	var c := b.get_node_or_null("Rites") as DmRiteCaster
	return c.get_state() if c != null else {}


# ---- hotbar -----------------------------------------------------------------------------------------------------------------------

## What never changes about a rite (the table is static), looked up once: icon path, unlock level, costs, base cooldown.
func _rite(id: String) -> Dictionary:
	var r: Variant = _rites.get(id)
	if r == null:
		var d := DmAbilities.def(id)
		r = {"icon": DmGameHud.art(String(d["icon"]).replace("art/", "")), "unlock": DmAbilities.unlock_level(id), "cd": float(d["cooldownMs"]),
			"essence": d["essenceCost"], "soul": d.get("soulCost", 0), "primary": DmAbilities.is_primary(id)}
		_rites[id] = r
	return r


## The current area's (static) definition, kept while the area stays the same.
func _area(id: String) -> Dictionary:
	if id != _area_id:
		_area_id = id
		_area_def = DmContent.area(id)
	return _area_def


func _primary_slot(b: DmHeroBody) -> Dictionary:
	_primary["icon"] = _rite(host.primary)["icon"]
	_fill(_primary, host.primary, b, float(host.character.get("level", 1)), "LMB")
	return _primary


func _slot_list(b: DmHeroBody, level: float) -> Array:
	_refresh_needs(b)
	var n: int = host.keys.size() + (1 if host.signature != "" else 0)   # keys 1-4 + RMB, then R (the signature)
	while _slots.size() < n:
		_slots.append({"alt": _slots.size() == 4, "swap": false, "rune_icon": "", "empowered": false})
	for i in n:
		var s := _slots[i]
		var id: String = host.keys[i] if i < host.keys.size() else host.signature
		s["icon"] = _rite(id)["icon"]
		_fill(s, id, b, level, SLOT_KEYS[i] if i < SLOT_KEYS.size() else "")
	if _slot_view.size() != n:
		_slot_view.resize(n)
	for i in n:
		_slot_view[i] = _slots[i]
	return _slot_view


## Cost, cooldown sweep, affordable / locked flags of one rite. Cooldown comes from the caster's state (the host's numbers).
func _fill(s: Dictionary, id: String, b: DmHeroBody, level: float, key: String) -> void:
	var d := _rite(id)
	var caster := b.get_node_or_null("Rites") as DmRiteCaster
	var base: float = d["cd"]
	var total := base
	if caster != null and caster.p.has("loadout"):
		total = DmWeaponLine.ability_cooldown_ms(id, base, caster.p["loadout"], d["primary"])
	s["key"] = key
	var souls_rite := b.family == "reaper"
	s["cost"] = d["soul"] if souls_rite else d["essence"]
	s["left_ms"] = caster.cooldown_left(id) if caster != null else 0.0
	s["total_ms"] = total
	var sp := soul_state(b)
	var emp := sp.has("soulsMax") and DmAbilities.empowered(sp, id)   # Soul Harvest: charged souls make this rite free
	s["empowered"] = emp
	s["affordable"] = (int(sp.get("souls", 0)) >= int(s["cost"])) if souls_rite else (emp or b.resource >= float(d["essence"]))
	s["locked"] = DmAbilities.rite_level(level, host.dev_access) < float(d["unlock"])
	s["unlock_level"] = d["unlock"]
	s["needs"] = needs_of(id, _corpse_near, _legion_n)


## Living thralls of the hero under a third of their health (the HUD paints that many pips red): one pass over the core's flat thrall arrays.
static func _legion_hurt(core: RefCounted, owner_id: int) -> int:
	if core.thrall_total() == 0:
		return 0
	var owners: PackedInt32Array = core.thrall_owners()
	var hp: PackedFloat32Array = core.thrall_hp()
	var states: PackedInt32Array = core.thrall_states()
	var n := 0
	for i in owners.size():
		if owners[i] != owner_id or states[i] == THRALL_DEAD:
			continue
		var h := hp[i * 2]
		if h > 0.0 and h < hp[i * 2 + 1] * LOW_HP_ENTER:
			n += 1
	return n


## "corpse" / "legion" when the rite needs one and the world has none, else "". Pure, so a test can drive it.
static func needs_of(id: String, corpse_near: bool, legion_n: int) -> String:
	var need: String = NEEDS.get(id, "")
	if need == "corpse" and corpse_near:
		return ""
	if need == "legion" and legion_n > 0:
		return ""
	return need


## The legion's size and whether a usable corpse lies within reach of the hero: two core queries, once per HUD refresh (the corpse view marks are not touched).
## The area filter is the hero's, as the rites' own corpse picks.
func _refresh_needs(b: DmHeroBody) -> void:
	var core: RefCounted = host.game.core_host.core
	_legion_n = int(core.thrall_count(b.core_id))
	var area: String = host.game.area_of(b.owner_peer)
	_corpse_near = not core.corpses_in_radius(Vector2(b.global_position.x, b.global_position.z), CORPSE_REACH, area).is_empty()


# ---- meta feeds: Bone Ward chip, Kill Chain meter, Omen chip (the DmGameHud shapes) ------------------------------------------------------

## The Ossuary's Bone Ward (wardPerThrall x living thralls, at most 60 %): {pct, thralls, per_thrall} or null.
func _ward(b: DmHeroBody) -> Variant:
	var per := float(b.mods.get("wardPerThrall", 0.0))
	if per <= 0.0:
		return null
	var n := _legion_n
	var pct := DmMath.js_round(minf(0.6, per * n) * 100.0)
	if pct <= 0:
		return null
	_ward_vm["pct"] = pct
	_ward_vm["thralls"] = n
	_ward_vm["per_thrall"] = per
	return _ward_vm


func _chain(g: DmNextGame, b: DmHeroBody) -> Variant:
	if g.meta == null or g.meta.member == null or not g.meta.member.chain.active() or not b.alive:
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
	_omen_vm["visible"] = not bool(_area(g.area_id)["safe"])
	return _omen_vm


# ---- belt (Q heal flask with its cooldown, Z / X brews: DmNextBelt) -------------------------------------------------------------

func _brews(g: DmNextGame) -> Array:
	var belt := g.belt()
	if belt != null and belt.inventory != null:
		return belt.rows()
	return _none


# ---- boss plate -------------------------------------------------------------------------------------------------------------------

## The awake boss of this world (the Gravedigger King): his plate, with the phase marks at 60 % and 30 % of the bar (DmGameHud.boss's shape).
func _boss(g: DmNextGame) -> Variant:
	var b := g.bosses.active_boss() if g.bosses != null else null
	if b == null:
		return null
	var def: Dictionary = DmContent.boss(b.boss_id)
	if _boss_vm.is_empty():
		_boss_vm = {"name": "", "phase": 1, "hp": 0.0, "max_hp": 1.0, "phases": []}
	_boss_vm["name"] = ("Empowered " if b.bstate.empowered else "") + String(def["name"])
	_boss_vm["phase"] = b.phase
	_boss_vm["hp"] = b.hp
	_boss_vm["max_hp"] = b.max_hp
	_boss_vm["phases"] = def["phases"]
	return _boss_vm


# ---- target frame, party, area line ----------------------------------------------------------------------------------------------

## The frame of the enemy under the cursor, else the last one a cast was aimed at (host.target_id): name, hp, elite, affix chips and statuses, from the core.
func _target() -> Variant:
	var id := host.target_id()
	if id == 0:
		return null
	var core: RefCounted = host.game.core_host.core
	var info: Dictionary = core.enemy_info(id)
	if info.is_empty() or int(info["state"]) == DEAD:
		return null
	var def_id := String(info["def"])
	var d: Dictionary = DmContent.enemy(def_id)
	var statuses: Array = []
	var raw: PackedByteArray = core.statuses(id)
	for i in raw.size() / 4:
		var sid := int(raw[i * 4])
		var name: String = DmStatusRules.IDS[sid] if sid < DmStatusRules.IDS.size() else ""
		var m: Variant = STATUS_ICON.get(name)
		if m != null:
			var stacks := int(raw[i * 4 + 1])
			if stacks >= 255 and name in STACKED:
				stacks = int(core.status_stacks(id, name))
			statuses.append({"icon": DmGameHud.art("status/" + m[0]), "label": m[1], "n": stacks})
	var chips := _affix_chips(id, info["affixes"], String(d.get("blurb", "")))
	return {"name": d.get("name", def_id), "elite": bool(info["elite"]), "affixes": chips, "hp": info["hp"], "max_hp": info["max_hp"],
		"statuses": statuses, "blurb": _aff_blurb}


## The elite's chips ([{id, name}], DmGameHud's shape) and the blurb listing every affix, from the core's affix names. Cached per target: rebuilt only when the
## target (or its affix count) changes, so a held target costs nothing per refresh.
func _affix_chips(id: int, list: PackedStringArray, base_blurb: String) -> Array:
	var n := list.size()
	if id == _aff_id and n == _aff_n:
		return _aff_chips
	_aff_id = id
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


## The party list: the session's roster (this peer's hero in a solo run). Levels come from the character; the party chain brings the others'.
func _party(g: DmNextGame) -> Array:
	var out: Array = []
	for r in g.roster():
		var b := r["body"] as DmHeroBody
		if b == null:
			continue
		var d := DmContent.discipline(String(r["discipline"]))
		var lvl := g.party.level_of(b) if g.party != null else (int(host.character.get("level", 1)) if b == g.local_body() else int(b.character.get("level", 1)))
		out.append({"id": int(r["peer_id"]), "name": String(r["name"]), "discipline": "%s · Level %d" % [d.get("name", r["discipline"]), lvl],
			"portrait": DmGameHud.art(String(d.get("portrait", "art/portraits/%s.webp" % r["discipline"])).replace("art/", "")), "hp_frac": b.hp / maxf(b.max_hp, 1.0)})
		if out.size() >= 4:
			break
	return out


func _area_progress(area: String) -> String:
	if area == "depths" and host.shell.depths != null and host.shell.depths.active():
		return host.shell.depths.progress_line()
	var def := _area(area)
	if bool(def.get("safe", false)):
		return "Sanctuary. The dead cannot follow you here."
	return "<b>%d</b> slain here · Level %d dead" % [host.kills_in(area), int(float(def.get("level", 1)))]


# ---- minimap -------------------------------------------------------------------------------------------------------------------

func _minimap(g: DmNextGame, b: DmHeroBody) -> Dictionary:
	if _areas.is_empty():
		for id in DmContent.area_order():
			var a: Dictionary = DmContent.area(id)
			_areas.append({"id": id, "rect": a["rect"], "safe": a["safe"], "unlocked": false, "instance": a.get("instance", false)})
		for d in DmContent.doors():
			_doors.append({"rect": d["rect"], "open": false, "id": d["id"]})
	# The world's seal state is what is unlocked / open (as today's builder's).
	for a in _areas:
		a["unlocked"] = g.world.unlocked.has(a["id"])
	for d in _doors:
		d["open"] = g.chapterhouse.door_open(String(d["id"])) if g.chapterhouse != null else bool(g.world.gates.get(String(d["id"]), {}).get("open", false))
	var core: RefCounted = g.core_host.core
	# the living enemies (the core's table also holds the dying), elites flagged
	var ids: PackedInt32Array = core.enemy_ids()
	var pos: PackedFloat32Array = core.enemy_positions()
	var states: PackedInt32Array = core.enemy_states()
	_enemy_dots.resize(ids.size() * 3)
	var ne := 0
	for i in ids.size():
		if states[i] != DEAD:
			_enemy_dots[ne * 3] = pos[i * 3]
			_enemy_dots[ne * 3 + 1] = pos[i * 3 + 1]
			_enemy_dots[ne * 3 + 2] = 1.0 if host.is_elite(ids[i]) else 0.0
			ne += 1
	_enemy_dots.resize(ne * 3)
	var tpos: PackedFloat32Array = core.thrall_positions()
	var tstates: PackedInt32Array = core.thrall_states()
	_thrall_dots.resize(tpos.size())
	var nt := 0
	for i in tstates.size():
		if tstates[i] != THRALL_DEAD:
			_thrall_dots[nt * 3] = tpos[i * 3]
			_thrall_dots[nt * 3 + 1] = tpos[i * 3 + 1]
			_thrall_dots[nt * 3 + 2] = tpos[i * 3 + 2]
			nt += 1
	_thrall_dots.resize(nt * 3)
	_map["px"] = b.position.x
	_map["pz"] = b.position.z
	_map["facing"] = b.yaw
	_map["areas"] = _areas
	_map["doors"] = _doors
	_map["enemies"] = _enemy_dots
	_map["thralls"] = _thrall_dots
	_map["allies"] = _allies
	_map["corpses"] = core.corpse_positions()   # x, z, facing, scale per corpse, as the core lays them out
	var bb := g.bosses.active_boss() if g.bosses != null else null
	if bb != null:
		_boss_dot["x"] = bb.position.x
		_boss_dot["z"] = bb.position.z
		_map["boss"] = _boss_dot
	else:
		_map["boss"] = null
	_map["waystones"] = _none
	_map["stairs"] = _none
	_map["npcs"] = _none
	_map["ping"] = null
	# the click-to-move goal (a minimap or ground click) while the hero is walking to it
	if b.has_target:
		_dest["x"] = b.move_target.x
		_dest["z"] = b.move_target.z
		_map["destination"] = _dest
	else:
		_map["destination"] = null
	_map["depths"] = g.depths.map_floor() if g.depths != null else null
	return _map
