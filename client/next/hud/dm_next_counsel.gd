class_name DmNextCounsel
extends RefCounted
## Counsel facts for the slice : "busy" flags that hold tips back
## during a fight, and the state-based ctx the UI polls every 400 ms (DmCounselEvents.tick_calls). Allocates only on the poll.
## Ported to the combat core (client/code.list "Ported"): today's counsel reads the director's enemy nodes, the corpse field and the hero's thrall host; this one asks the
## core, and only on the poll (every 400 ms, DmGameUi's timer): "three living dead within 9 m" is one radius query, the corpses within 7 m one more and, for each of
## those, the living bodies within 3 m of it; the hero's thralls are `thrall_count`. No node, no per-creature call and no scan of the whole table. The facts are today's:
## a body counts by the distance of its centre, a rising or burrowed one counts, a dead one does not (the core's radius queries measure to the edge, so a candidate is
## confirmed by its centre). One more fact: `altar` is false, the build has no Altar of Ascension (DECISIONS B36), so the counsel does not send the player to one (ported DmCounselEvents.tick_calls).

const BOSS_IDS := ["gravedigger", "abbess", "congregation", "saint", "regent", "mire"]
const BUSY_MS := 4000.0
const FIGHT_R := 9.0       ## a fight is three living dead within 9 m of the hero, or the boss awake
const FIGHT_N := 3
const CORPSE_R := 7.0      ## the corpses near the hero (the Exhume and Litany tips)
const PACK_R := 3.0        ## a pack stands on a corpse: three living dead within 3 m of it (Corpse Explosion's tip)
const PACK_N := 3

var host: DmNextUiHost
var last_combat_ms := -1e9
var last_hurt_ms := -1e9
var _cheapest_key := -1
var _cheapest := INF


func _init(host_: DmNextUiHost) -> void:
	host = host_


func now() -> float:
	return float(Time.get_ticks_msec())


## The hero was hurt (DmGameCombat.on_hurt: lastCombatAt + lastHurtAt).
func hurt() -> void:
	last_combat_ms = now()
	last_hurt_ms = last_combat_ms


func busy() -> Dictionary:
	var t := now()
	var b := host.shell.local_body()
	return {"combat": t - last_combat_ms < BUSY_MS, "hurt": t - last_hurt_ms < BUSY_MS, "dead": b != null and not b.alive}


## A fight is three living dead within 9 m of the hero, or the boss awake (tick_counsel, run at the poll's cadence).
func _scan_combat(b: DmHeroBody) -> void:
	var t := now()
	if host.shell.bosses != null and host.shell.bosses.active_boss() != null:
		last_hurt_ms = t
		last_combat_ms = t
		return
	if _living_near(b.position.x, b.position.z, FIGHT_R, FIGHT_N) >= FIGHT_N:
		last_combat_ms = t


## How many living bodies of the core stand within `r` of a ground point, by the distance of their centres, counting up to `limit` (then it stops asking). The radius query
## measures to the edge, which only ever finds more than the centre test does: fewer candidates than `limit` end it at once, which is nearly every poll outside a fight.
func _living_near(x: float, z: float, r: float, limit: int) -> int:
	var core: RefCounted = host.shell.core_host.core
	var at := Vector2(x, z)
	var cand: PackedInt32Array = core.enemies_in_radius(at, r)
	if cand.size() < limit:
		return 0
	var n := 0
	for id in cand:
		var info: Dictionary = core.enemy_info(id)
		if not info.is_empty() and int(info["state"]) != DmCoreEvents.State.DEAD and (info["pos"] as Vector2).distance_to(at) < r:
			n += 1
			if n >= limit:
				break
	return n


func tick_ctx() -> Dictionary:
	var g: DmNextGame = host.shell
	var b := g.local_body()
	if b == null or not b.alive:
		return {}
	_scan_combat(b)
	var bp := Vector2(b.position.x, b.position.z)
	var core: RefCounted = g.core_host.core
	var corpses_near := 0
	var pack := false
	for cid in core.corpses_in_radius(bp, CORPSE_R):
		corpses_near += 1
		if not pack:
			var c: Dictionary = core.corpse_info(cid)
			pack = not c.is_empty() and _living_near(float(c["x"]), float(c["z"]), PACK_R, PACK_N) >= PACK_N
	var has_tool := false
	var has_belt := false
	var brews: Dictionary = DmContent.brews()
	var flasks: Dictionary = DmContent.healing_flasks()
	for s in host.inventory.slots:
		var id := String(s["item_id"])
		has_tool = has_tool or id.begins_with("tool_")
		has_belt = has_belt or brews.has(id) or flasks.has(id)
	var loc: Dictionary = host.prog.local
	var wave_cost: int = host.prog.wave_cost()
	return {
		"wave_affordable": wave_cost != -1 and float(host.character.get("gold", 0)) >= float(wave_cost), "thralls_mine": g.core_host.thrall_count(b.core_id) if b.core_id != 0 else 0,   # (0 asks for everyone's)
		"corpses_near": corpses_near, "pack_on_corpse": pack, "family": b.family, "level": host.character["level"], "total_kills": loc["totalKills"],
		"has_tool": has_tool, "has_belt_item": has_belt, "shards": loc["shards"], "boss_near": _boss_near(bp), "has_seal": host.inventory.count(DmGoldSink.COVENANT_SEAL) > 0,
		"area": g.area_id, "cheapest_unlock": _cheapest_unlock(loc), "boss_kills": loc["bossKills"], "ascension": loc["ascension"], "ashes": loc["ashes"],
		"gate_near": _gate_near(bp), "altar": false,
	}


## Where each boss's summon object stands in an area (static content, made once per area): [[boss id, Vector2], ...] in the order the poll walks them.
var _boss_sites := {}
var _gate_rects: Array = []   ## the doors, as [id, x0, z0, x1, z1] (static content, made once)


func _boss_near(bp: Vector2) -> Array:
	var area: String = host.shell.area_id
	var sites: Variant = _boss_sites.get(area)
	if sites == null:
		sites = []
		for id in BOSS_IDS:
			var def: Dictionary = DmContent.boss(id)
			if area != String(def["area"]):
				continue
			for it in DmContent.area(String(def["area"]))["interactables"]:
				if it["id"] == def["summonId"]:
					sites.append([id, Vector2(float(it["x"]), float(it["z"]))])
		_boss_sites[area] = sites
	var out: Array = []
	for site in sites:
		if (site[1] as Vector2).distance_to(bp) < 12.0:
			out.append(site[0])
	return out


func _gate_near(bp: Vector2) -> bool:
	if _gate_rects.is_empty():
		for d in DmContent.doors():
			var r: Dictionary = d["rect"]
			_gate_rects.append([String(d["id"]), float(r["x0"]), float(r["z0"]), float(r["x1"]), float(r["z1"])])
	var ch := host.shell.chapterhouse
	for g in _gate_rects:
		if Vector2(maxf(maxf(g[1] - bp.x, 0.0), bp.x - g[3]), maxf(maxf(g[2] - bp.y, 0.0), bp.y - g[4])).length() < 6.0 and not (ch != null and ch.door_open(g[0])):
			return true
	return false


## The cheapest vow / boon still shut; only changes when the unlock set does.
func _cheapest_unlock(loc: Dictionary) -> float:
	var key := hash(loc.get("unlocks"))
	if key == _cheapest_key:
		return _cheapest
	_cheapest_key = key
	_cheapest = INF
	for k in DmProgContent.vow_order():
		var vk := DmAscension.vow_key(String(k))
		if not DmAscension.is_unlocked(loc.get("unlocks"), vk):
			_cheapest = minf(_cheapest, float(DmAscension.unlock_cost(vk)))
	for k in DmProgContent.boon_order():
		var bk := DmAscension.boon_key(String(k))
		if not DmAscension.is_unlocked(loc.get("unlocks"), bk):
			_cheapest = minf(_cheapest, float(DmAscension.unlock_cost(bk)))
	return _cheapest
