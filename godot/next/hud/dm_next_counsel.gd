class_name DmNextCounsel
extends RefCounted
## Counsel facts for the slice : "busy" flags that hold tips back
## during a fight, and the state-based ctx the UI polls every 400 ms (DmCounselEvents.tick_calls). Reads the slice's nodes; allocates only on the poll.

const BOSS_IDS := ["gravedigger", "abbess", "congregation", "saint", "regent", "mire"]
const BUSY_MS := 4000.0

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
	var near := 0
	for e in host.shell.director.enemies.values():
		var en := e as DmEnemy
		if en != null and is_instance_valid(en) and en.sm != null and en.sm.id() != DmEnemyState.Id.DEAD \
				and Vector2(en.position.x - b.position.x, en.position.z - b.position.z).length() < 9.0:
			near += 1
			if near >= 3:
				last_combat_ms = t
				return


func tick_ctx() -> Dictionary:
	var g: DmNextGame = host.shell
	var b := g.local_body()
	if b == null or not b.alive:
		return {}
	_scan_combat(b)
	var bp := Vector2(b.position.x, b.position.z)
	var corpses_near := 0
	var pack := false
	for c in g.corpses.corpses.values():
		if Vector2(c.x, c.z).distance_to(bp) > 7.0:
			continue
		corpses_near += 1
		if not pack:
			var n := 0
			for e in g.director.enemies.values():
				var en := e as DmEnemy
				if en != null and is_instance_valid(en) and en.sm != null and en.sm.id() != DmEnemyState.Id.DEAD and Vector2(en.position.x - c.x, en.position.z - c.z).length() < 3.0:
					n += 1
			pack = n >= 3
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
	var th := b.get_node_or_null("Thralls") as DmThrallHost
	return {
		"wave_affordable": wave_cost != -1 and float(host.character.get("gold", 0)) >= float(wave_cost), "thralls_mine": th.count() if th != null else 0,
		"corpses_near": corpses_near, "pack_on_corpse": pack, "family": b.family, "level": host.character["level"], "total_kills": loc["totalKills"],
		"has_tool": has_tool, "has_belt_item": has_belt, "shards": loc["shards"], "boss_near": _boss_near(bp), "has_seal": host.inventory.count(DmGoldSink.COVENANT_SEAL) > 0,
		"area": g.area_id, "cheapest_unlock": _cheapest_unlock(loc), "boss_kills": loc["bossKills"], "ascension": loc["ascension"], "ashes": loc["ashes"],
		"gate_near": _gate_near(bp),
	}


func _boss_near(bp: Vector2) -> Array:
	var out: Array = []
	for id in BOSS_IDS:
		var def: Dictionary = DmContent.boss(id)
		if host.shell.area_id != String(def["area"]):
			continue
		for it in DmContent.area(String(def["area"]))["interactables"]:
			if it["id"] == def["summonId"] and Vector2(float(it["x"]), float(it["z"])).distance_to(bp) < 12.0:
				out.append(id)
	return out


func _gate_near(bp: Vector2) -> bool:
	var ch := host.shell.chapterhouse
	for d in DmContent.doors():
		if ch != null and ch.door_open(String(d["id"])):
			continue
		var r: Dictionary = d["rect"]
		if Vector2(maxf(maxf(float(r["x0"]) - bp.x, 0.0), bp.x - float(r["x1"])), maxf(maxf(float(r["z0"]) - bp.y, 0.0), bp.y - float(r["z1"]))).length() < 6.0:
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
