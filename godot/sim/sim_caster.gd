class_name DmSimCaster
extends RefCounted
## The world-dependent half of one player's casting: a headless port of src/gameplay/AbilitySystem.ts (+ NewBloodSystem.ts) with every
## visual stripped. cast() checks and spends through DmAbilities (rules/combat), aims (targets, corpses, cones, lines), flies the projectiles,
## and turns every blow into the same Intents the web client sends (hit / miasma / exhume / litany / detonate / signature) into a DmWorldSim;
## handle_event() applies what the host's answers do to the caster (essence refunds, barrier, heals, wisps, souls). The scene supplies the
## player's position (p["x"], p["z"], p["area"], p["facing"]), the cursor (aim) and, optionally, hand/tip positions and dash rules.
##
## `p` is a DmPlayerRules.new_state() dictionary with, in addition: "loadout" (DmWeaponLine.resolve), "runes" {rite: rune_id}, "area" (String, "" = none),
## "cooldowns" {id: until_ms}. Time is in milliseconds (scene clock), like the TS; update(now, dt) takes dt in seconds.
## Randomness (needle jitter and crit) comes from `random` (default: randf); tests inject a constant to replay the TS bit for bit.

var sim: DmWorldSim
var p: Dictionary
var self_id: String = ""
## Equipped discipline: its id, family and DisciplineMods (DmCharacterBuild.discipline_for(...)["mods"]).
var discipline_id: String = ""
var family: String = "necromancer"
var mods: Dictionary = {}
## DEV: every rite unlocked.
var dev: bool = false
## Ground cursor {x, z} or null (murder_of_crows follows it).
var aim: Variant = null
var random: Callable = Callable()
## Where intents go. Default: sim.apply(intent) (solo / host). A co-op guest sets it to the relay.
var send_fn: Callable = Callable()
## () -> [x, y, z] of the staff tip (default: over the caster's head).
var tip_fn: Callable = Callable()
## (tx, tz) -> [x, z]: the furthest valid dash point (default: veil_target on sim.nav).
var dash_fn: Callable = Callable()
## Damage numbers the scene should float: [{x, z, amount, kind}]; drained by the caller (clear_popups()).
var popups: Array = []
var shakes: Array = []
var notes: Array = []
## Every intent sent (tests / debugging); cleared by clear_log().
var sent: Array = []
var record_sent: bool = false

var _now: float = 0.0
var _needle_casts: int = 0
var _colossus_cast: bool = false
var _reaped: Dictionary = {}
var _wisps: Array = []
var _timed: Array = []
var _projectiles: Array = []
var _dashing: Variant = null
var _vigil_until: float = 0.0
var _last_vigil_at: float = 0.0
var _mantle_until: float = 0.0
var _next_shard_at: float = 0.0
# NewBloodSystem state
var _choir_until: float = 0.0
var _next_choir_beat: float = 0.0
var _crows_until: float = 0.0
var _next_crow_peck: float = 0.0
var _murder_until: float = 0.0
var _next_murder_tick: float = 0.0


func _init(p_sim: DmWorldSim, p_state: Dictionary, p_self_id: String, p_discipline_id: String = "", p_family: String = "necromancer", p_mods: Dictionary = {}) -> void:
	DmSimData.ensure()
	sim = p_sim
	p = p_state
	self_id = p_self_id
	discipline_id = p_discipline_id
	family = p_family
	mods = p_mods


func clear_popups() -> void:
	popups = []


func clear_log() -> void:
	sent = []


func _rand() -> float:
	return float(random.call()) if random.is_valid() else randf()


static func _h(a: float, b: float) -> float:
	return DmSimMath.hypot(a, b)


func _send(intent: Dictionary) -> void:
	if record_sent:
		sent.append(intent)
	if send_fn.is_valid():
		send_fn.call(intent)
	else:
		sim.apply(intent)


func _number(x: float, z: float, amount: float, kind: String) -> void:
	popups.append({"x": x, "z": z, "amount": amount, "kind": kind})


func _boss() -> DmBossState:
	return sim.boss.state


func _essence() -> float:
	return float(p["resource"]["value"])


func _set_essence(v: float) -> void:
	p["resource"]["value"] = v


func _max_essence() -> float:
	return float(p["stats"]["maxEssence"])


func _px() -> float:
	return float(p["x"])


func _pz() -> float:
	return float(p["z"])


func _face(x: float, z: float) -> void:
	p["facing"] = DmFdlibm.atan2_(x - _px(), z - _pz())


func _teleport(x: float, z: float) -> void:
	var r := sim.nav.resolve(x, z, 0.45)
	p["x"] = r[0]
	p["z"] = r[1]
	var a := sim.nav.area_at(r[0], r[1])
	p["area"] = a


func _heal(amount: float) -> void:
	DmPlayerRules.heal(p, amount)


func _area() -> String:
	return String(p.get("area", ""))


## Dead, or underground (a tunnelling or surfacing ghoul): the host refuses every blow, so no rite should draw a number on it.
static func _gone(e: DmSimEnemy) -> bool:
	return e.state == "dead" or e.state == "burrow" or (e.erupting != null and e.state == "windup")


func _tip() -> Array:
	if tip_fn.is_valid():
		return tip_fn.call()
	return [_px(), 1.4, _pz()]


## AbilitySystem.sp
func _sp() -> float:
	return DmAbilities.sp(p, _now)


func rune(rite: String) -> String:
	return DmAbilities.rune(p, rite)


func unlocked(id: String) -> bool:
	return DmAbilities.unlocked(id, float(p["stats"]["level"]), dev)


func empowered(id: String) -> bool:
	return DmAbilities.empowered(p, id)


func ready(id: String, now: float) -> bool:
	return DmAbilities.ready(p, id, float(p["stats"]["level"]), now, dev)


func shortfall(id: String, t: Dictionary) -> float:
	return DmAbilities.shortfall(p, id, t, DmSimConsts.BOSS_RADIUS)


func thrall_count() -> int:
	return sim.owned_thralls(self_id).size()


# --- Projectiles (Effects.projectile / Effects.update) -----------------------------------------------------------------------------------

## A shot in flight: `to_fn` -> [x, y, z] or null (target gone: keeps the last point); `on_arrive(pos)` fires when it lands.
func _projectile(from: Array, to_fn: Callable, speed: float, arc: float, on_arrive: Callable) -> void:
	var first: Variant = to_fn.call()
	var last_to: Array = [first[0], first[1], first[2]] if first != null else [from[0], from[1], from[2]]
	var dx: float = last_to[0] - from[0]
	var dy: float = last_to[1] - from[1]
	var dz: float = last_to[2] - from[2]
	_projectiles.append({"from": [from[0], from[1], from[2]], "to": to_fn, "last_to": last_to, "speed": speed, "arc": arc, "on_arrive": on_arrive,
		"pos": [from[0], from[1], from[2]], "t": 0.0, "dist": maxf(0.1, sqrt(dx * dx + dy * dy + dz * dz))})


func _step_projectiles(dt: float) -> void:
	var i := _projectiles.size() - 1
	while i >= 0:
		var pr: Dictionary = _projectiles[i]
		var target: Variant = pr["to"].call()
		var lt: Array = pr["last_to"]
		if target != null:
			lt[0] = target[0]
			lt[1] = target[1]
			lt[2] = target[2]
		var pos: Array = pr["pos"]
		var vx: float = lt[0] - pos[0]
		var vy: float = lt[1] - pos[1]
		var vz: float = lt[2] - pos[2]
		var d := sqrt(vx * vx + vy * vy + vz * vz)
		var step: float = float(pr["speed"]) * dt
		pr["t"] = float(pr["t"]) + dt
		var arc_progress := minf(1.0, float(pr["t"]) * float(pr["speed"]) / float(pr["dist"]))
		var arrive: bool = (arc_progress >= 1.0) if float(pr["arc"]) != 0.0 else (d <= step)
		if arrive or float(pr["t"]) > 3.0:
			pos[0] = lt[0]
			pos[1] = lt[1]
			pos[2] = lt[2]
			_projectiles.remove_at(i)
			pr["on_arrive"].call([pos[0], pos[1], pos[2]])
			i -= 1
			continue
		if float(pr["arc"]) != 0.0:
			var fr: Array = pr["from"]
			pos[0] = fr[0] + (lt[0] - fr[0]) * arc_progress
			pos[1] = fr[1] + (lt[1] - fr[1]) * arc_progress
			pos[2] = fr[2] + (lt[2] - fr[2]) * arc_progress
			pos[1] = pos[1] + DmFdlibm.sin_(arc_progress * PI) * float(pr["arc"]) * 0.1
		else:
			var k: float = step / maxf(0.001, d)
			pos[0] = pos[0] + vx * k
			pos[1] = pos[1] + vy * k
			pos[2] = pos[2] + vz * k
		i -= 1


# --- Casting -----------------------------------------------------------------------------------------------------------------------------

## Cast a rite at `target` {x, z, enemyId?, boss?}. Returns 'ok' | 'busy' | 'cooldown' | 'essence' | 'range' | 'no_target' | 'no_corpse' | 'dead' | 'locked' | 'no_thralls'.
func cast(id: String, target: Dictionary, now: float) -> String:
	_now = now
	var def: Dictionary = DmSimData.ABILITIES[id]
	if not p["alive"]:
		return "dead"
	if not unlocked(id):
		return "locked"
	if now < float(p["castUntil"]):
		return "busy"
	if DmPlayerRules.on_cooldown(p, id, now):
		return "cooldown"
	var emp := empowered(id)
	if not emp and _essence() < float(def["essenceCost"]):
		return "essence"
	var mult := float(DmCombatData.const_table("SOUL_HARVEST")["areaMult"]) if emp else 1.0
	var result: String
	match id:
		"bone_needle":
			result = _reap(target) if bool(p["loadout"]["reap"]) else _needle(target)
		"marrow_spear":
			result = _spear(target, mult)
		"exhume":
			result = _exhume(target)
		"miasma":
			result = _miasma(target, mult)
		"black_litany":
			result = _litany(mult)
		"corpse_explosion":
			result = _detonate(target)
		"wailing_skull":
			result = _skull(target)
		"grave_step":
			result = _step(target)
		"grave_frost":
			result = _frost(target)
		"bone_mantle":
			result = _mantle()
		"bone_fan":
			result = _fan(target)
		"rot_lance":
			result = _lance(target)
		"grave_offering":
			result = _offering(target)
		"ivory_cleave":
			result = _cleave(target)
		"veil_step":
			result = _veil(target)
		"rally_dead":
			result = _rally(target)
		"carrion_seed":
			result = _seed(target)
		"soul_siphon":
			result = _siphon(target, now)
		"bone_prison":
			result = _prison(target)
		"grave_hands":
			result = _hands(target, now)
		"bone_storm":
			result = _storm(target, now)
		"hollow_cut":
			result = _hollow_cut(target)
		"shield_bash":
			result = _shield_bash(target)
		"grave_slam":
			result = _grave_slam(target)
		"bulwark":
			result = _bulwark(now)
		"corpse_vigil":
			result = _corpse_vigil(target)
		"grave_brand":
			result = _grave_brand(target)
		"oath_unbroken":
			result = _oath_unbroken(now)
		"ossuary_wall", "command_rend", "dirge", "plague_bloom":
			result = _signature(id, target)
		_:
			var r: Variant = _nb_cast(id, target, now)
			result = r if r != null else "no_target"
	if result == "ok":
		p["castUntil"] = now + DmWeaponLine.ability_lock_ms(id, float(DmAbilities.cast_flow(id)["lockMs"]), p["loadout"])
		p["rootedUntil"] = maxf(float(p["rootedUntil"]), float(p["castUntil"]))
		if emp:
			DmPlayerRules.spend_souls(p)
			_wraith_nova()
		else:
			_set_essence(_essence() - float(def["essenceCost"]))
		var lo: Dictionary = p["loadout"]
		if id == "exhume" and not emp and float(lo["exhumeRefund"]) > 0.0:
			_set_essence(minf(_max_essence(), _essence() + float(def["essenceCost"]) * float(lo["exhumeRefund"])))
		var rune_cool: float = float(DmSimData.RUNE_TUNING["colossus"]["cooldownMult"]) if (id == "exhume" and _colossus_cast) else 1.0
		p["cooldowns"][id] = now + (DmWeaponLine.ability_cooldown_ms(id, float(def["cooldownMs"]), lo, DmAbilities.is_primary(id)) * rune_cool) / (1.0 + DmPlayerRules.brew_value(p, "haste", now))
	return result


# --- Bone Needle / scythe / spear ---------------------------------------------------------------------------------------------------------

func _foe_dict(e: DmSimEnemy) -> Dictionary:
	return {"id": e.id, "x": e.x, "z": e.z, "radius": e.radius}


func _live_foes() -> Array:
	var out: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if not _gone(e):
			out.append(e)
	return out


func _needle(t: Dictionary) -> String:
	if not t.has("enemyId") and not t.get("boss", false):
		return "no_target"
	if shortfall("bone_needle", t) > 0.0:
		return "range"
	_face(t["x"], t["z"])
	var from := _tip()
	var lo: Dictionary = p["loadout"]
	var rn := rune("bone_needle")
	var RT: Dictionary = DmSimData.RUNE_TUNING
	var volley := false
	if rn == "rune_volley":
		_needle_casts += 1
		volley = _needle_casts % int(RT["volley"]["every"]) == 0
	var rune_mult := 1.0
	if rn == "rune_marrow_tap":
		rune_mult = float(RT["marrowTap"]["damageMult"])
	elif volley:
		rune_mult = float(RT["volley"]["damageFrac"])
	var dmg := _sp() * float(DmSimData.ABILITIES["bone_needle"]["power"]) * float(lo["needleDamageMult"]) * rune_mult * (0.9 + _rand() * 0.2)
	var essence := float(DmCombatData.const_table("NEEDLE_ESSENCE")) + (float(RT["marrowTap"]["essenceBonus"]) if rn == "rune_marrow_tap" else 0.0)
	if not volley:
		_launch_needle(t, from, dmg, essence, rn == "rune_splinter")
		return "ok"
	var aims: Array = [t]
	if not t.get("boss", false) and t.has("enemyId"):
		var live := _live_foes()
		var first: DmSimEnemy = null
		for e: DmSimEnemy in live:
			if e.id == int(t["enemyId"]):
				first = e
				break
		if first != null:
			var foes: Array = []
			for e: DmSimEnemy in live:
				foes.append(_foe_dict(e))
			var vt := DmRunes.volley_targets({"x": _px(), "z": _pz()}, _foe_dict(first), foes)
			for k in range(1, vt.size()):
				aims.append({"x": vt[k]["x"], "z": vt[k]["z"], "enemyId": vt[k]["id"]})
	while aims.size() < int(RT["volley"]["needles"]):
		aims.append(t)
	for i in aims.size():
		var spread := [from[0] + (i - 1) * 0.12, from[1], from[2]]
		_launch_needle(aims[i], spread, dmg, essence / float(RT["volley"]["needles"]), false, i * 0.05)
	return "ok"


func _boss_to() -> Variant:
	var b := _boss()
	return [b.x, 2.2, b.z] if b.active else null


func _to_enemy(enemy_id: int, y: float) -> Variant:
	var e: DmSimEnemy = sim.enemies.get(enemy_id)
	return [e.x, y, e.z] if e != null else null


func _to_point(end: Array) -> Variant:
	return end


## One needle in flight: damage on arrival, essence back, and (Splinters) a shard to the nearest other enemy.
func _launch_needle(t: Dictionary, from: Array, dmg: float, essence: float, splinters: bool, delay_s: float = 0.0) -> void:
	var lo: Dictionary = p["loadout"]
	var withered: Dictionary = {}
	if float(lo["needleWithered"]) > 0.0:
		withered = {"withered": lo["needleWithered"], "witheredCap": DmLegend.effective_withered_cap(mods)}
	var crit := _rand() < 0.08
	var ctx := {"boss": bool(t.get("boss", false)), "enemy_id": int(t["enemyId"]) if t.has("enemyId") else -1, "dmg": dmg, "essence": essence, "crit": crit, "splinters": splinters, "withered": withered}
	if delay_s > 0.0:
		_timed.append({"until": _now + delay_s * 1000.0 + 50.0, "next": _now + delay_s * 1000.0, "every": 1e9,
			"tick": Callable(self, "_timed_fire_needle").bind(from, ctx), "end": Callable()})
	else:
		_fire_needle(from, ctx)


func _timed_fire_needle(_now_ms: float, from: Array, ctx: Dictionary) -> Variant:
	_fire_needle(from, ctx)
	return true


func _fire_needle(from: Array, ctx: Dictionary) -> void:
	var to_fn: Callable = Callable(self, "_boss_to") if ctx["boss"] else Callable(self, "_to_enemy").bind(ctx["enemy_id"], 1.0)
	_projectile(from, to_fn, 26.0, 0.0, Callable(self, "_needle_arrive").bind(ctx))


func _needle_arrive(pos: Array, ctx: Dictionary) -> void:
	if not p["alive"]:
		return
	var lo: Dictionary = p["loadout"]
	var dmg: float = ctx["dmg"]
	var amount := dmg * 1.8 if ctx["crit"] else dmg
	if ctx["boss"]:
		if not _boss().active:
			return
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": amount, "boss": true})
	else:
		var enemy_id: int = ctx["enemy_id"]
		if not sim.enemies.has(enemy_id):
			return
		var h := {"t": "hit", "by": self_id, "ids": [enemy_id], "dmg": amount}
		h.merge(ctx["withered"])
		_send(h)
		if float(lo["needlePierce"]) > 0.0:
			_pierce_beyond(enemy_id, pos, dmg * float(DmSimData.NECRO_WEAPON_TUNING["staff"]["pierceDamageMult"]), int(lo["needlePierce"]), ctx["withered"])
		if ctx["splinters"]:
			_splinter(enemy_id, pos, dmg)
	_set_essence(minf(_max_essence(), _essence() + float(ctx["essence"])))
	_number(pos[0], pos[2], amount, "crit" if ctx["crit"] else "hit")


## Splinters rune: a shard of the needle flies to the nearest other enemy for half the damage.
func _splinter(first_id: int, at: Array, dmg: float, skip: Dictionary = {}) -> void:
	var first: DmSimEnemy = sim.enemies.get(first_id)
	var pool: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if not _gone(e) and not skip.has(e.id):
			pool.append(_foe_dict(e))
	var fd: Dictionary = _foe_dict(first) if first != null else {"id": first_id, "x": at[0], "z": at[2]}
	var tg: Variant = DmRunes.splinter_target(fd, pool)
	if tg == null:
		return
	var amount := dmg * float(DmSimData.RUNE_TUNING["splinter"]["damageFrac"])
	_send({"t": "hit", "by": self_id, "ids": [tg["id"]], "dmg": amount})
	_number(tg["x"], tg["z"], amount, "hit")


## Staff needle: it carries on through the nearest enemy behind its target, in its lane.
func _pierce_beyond(first_id: int, at: Array, dmg: float, count: int, extra: Dictionary) -> void:
	var pool: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if not _gone(e):
			pool.append(_foe_dict(e))
	var nxt := DmWeaponLine.pierce_targets({"x": _px(), "z": _pz()}, {"x": at[0], "z": at[2], "id": first_id}, pool, count)
	if nxt.is_empty():
		return
	var ids: Array = []
	for e: Dictionary in nxt:
		ids.append(e["id"])
	var h := {"t": "hit", "by": self_id, "ids": ids, "dmg": dmg}
	h.merge(extra)
	_send(h)
	for e: Dictionary in nxt:
		_number(e["x"], e["z"], dmg, "hit")


## Extra souls for a kill the scythe arc delivered (the scene calls this from its death handler).
func reaped_souls(enemy_id: int) -> float:
	if not _reaped.has(enemy_id):
		return 0.0
	var until: float = _reaped[enemy_id]
	_reaped.erase(enemy_id)
	return float(DmSimData.NECRO_WEAPON_TUNING["scythe"]["soulsPerKill"]) if _now <= until else 0.0


func _reap(t: Dictionary) -> String:
	var T: Dictionary = DmSimData.NECRO_WEAPON_TUNING["scythe"]
	if not t.has("enemyId") and not t.get("boss", false):
		return "no_target"
	if shortfall("bone_needle", t) > 0.0:
		return "range"
	var dx: float = t["x"] - _px()
	var dz: float = t["z"] - _pz()
	var l := _h(dx, dz)
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	_face(_px() + dx, _pz() + dz)
	var rn := rune("bone_needle")
	var dmg := _sp() * float(DmSimData.ABILITIES["bone_needle"]["power"]) * float(T["damageMult"]) * (float(DmSimData.RUNE_TUNING["marrowTap"]["damageMult"]) if rn == "rune_marrow_tap" else 1.0) * (0.9 + _rand() * 0.2)
	var pool: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if not _gone(e):
			pool.append(_foe_dict(e))
	var struck := DmWeaponLine.reap_targets({"x": _px(), "z": _pz()}, {"x": t["x"], "z": t["z"]}, pool)
	var b := _boss()
	var hit_boss := b.active and not DmWeaponLine.reap_targets({"x": _px(), "z": _pz()}, {"x": t["x"], "z": t["z"]}, [{"x": b.x, "z": b.z, "radius": DmSimConsts.BOSS_RADIUS}], float(T["bossReach"])).is_empty()
	var now := _now
	if _reaped.size() > 64:
		for id in _reaped.keys():
			if float(_reaped[id]) < now:
				_reaped.erase(id)
	var slots := maxi(0, int(T["maxHits"]) - (1 if hit_boss else 0))
	var hits: Array = struck.slice(0, slots)
	if not hits.is_empty():
		var ids: Array = []
		for e: Dictionary in hits:
			ids.append(e["id"])
		_send({"t": "hit", "by": self_id, "ids": ids, "dmg": dmg})
	if hit_boss:
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})
	for e: Dictionary in hits:
		_reaped[e["id"]] = now + float(T["reapWindowMs"])
		_number(e["x"], e["z"], dmg, "hit")
	if hit_boss:
		_number(b.x, b.z, dmg, "hit")
	var landed := hits.size() + (1 if hit_boss else 0)
	if landed != 0:
		_set_essence(minf(_max_essence(), _essence() + float(T["essencePerHit"]) * landed + (float(DmSimData.RUNE_TUNING["marrowTap"]["essenceBonus"]) if rn == "rune_marrow_tap" else 0.0)))
	if rn == "rune_splinter" and not hits.is_empty():
		var skip: Dictionary = {}
		for e: Dictionary in hits:
			skip[e["id"]] = true
		_splinter(int(hits[0]["id"]), [hits[0]["x"], 0.0, hits[0]["z"]], dmg, skip)
	return "ok"


## `mult` > 1 when Soul Harvest empowers the cast (longer, wider line).
func _spear(t: Dictionary, mult: float = 1.0) -> String:
	var def: Dictionary = DmSimData.ABILITIES["marrow_spear"]
	var rn := rune("marrow_spear")
	var ring := rn == "rune_ossuary_ring"
	var impale := rn == "rune_impale"
	var RT: Dictionary = DmSimData.RUNE_TUNING
	var rng_m := float(def["range"]) * mult
	var radius := float(def["radius"]) * mult
	var centre: Variant = DmRunes.ring_center({"x": _px(), "z": _pz()}, {"x": t["x"], "z": t["z"]}, float(RT["ring"]["maxCastRange"]) * mult) if ring else null
	var dx: float = (centre["x"] if centre != null else t["x"]) - _px()
	var dz: float = (centre["z"] if centre != null else t["z"]) - _pz()
	var len := _h(dx, dz)
	if len == 0.0:
		len = 1.0
	dx /= len
	dz /= len
	_face(_px() + dx, _pz() + dz)
	var origin := {"x": _px(), "z": _pz()}
	var dmg := _sp() * float(def["power"])
	var end: Array
	if centre != null:
		end = [centre["x"], 0.3, centre["z"]]
	else:
		end = [float(origin["x"]) + dx * rng_m, 0.3, float(origin["z"]) + dz * rng_m]
	var ctx := {"origin": origin, "dx": dx, "dz": dz, "rng": rng_m, "radius": radius, "centre": centre, "impale": impale, "dmg": dmg, "end": end, "mult": mult}
	_projectile(_tip(), Callable(self, "_to_point").bind(end), 48.0, 0.0, Callable(self, "_spear_arrive").bind(ctx))
	return "ok"


func _spear_rally() -> bool:
	return float(mods.get("spearRally", 0.0)) > 0.0


func _spear_arrive(_pos: Array, ctx: Dictionary) -> void:
	if not p["alive"]:
		return
	var RT: Dictionary = DmSimData.RUNE_TUNING
	var dmg: float = ctx["dmg"]
	var mult: float = ctx["mult"]
	if ctx["centre"] != null:
		_spear_ring(ctx["centre"], float(RT["ring"]["radius"]) * mult, dmg * float(RT["ring"]["damageMult"]))
		return
	var origin: Dictionary = ctx["origin"]
	var dx: float = ctx["dx"]
	var dz: float = ctx["dz"]
	var rng_m: float = ctx["rng"]
	var half_w: float = float(ctx["radius"]) + 0.2
	if ctx["impale"]:
		_spear_impale(origin, dx, dz, rng_m, half_w, dmg * float(RT["impale"]["damageMult"]))
		return
	var ids: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if _gone(e):
			continue
		var rx := e.x - float(origin["x"])
		var rz := e.z - float(origin["z"])
		var along := rx * dx + rz * dz
		if along > 0.0 and along < rng_m and absf(rx * dz - rz * dx) < half_w + e.radius:
			ids.append(e.id)
			_number(e.x, e.z, dmg, "spear")
	var rally := _spear_rally()
	if not ids.is_empty():
		var h := {"t": "hit", "by": self_id, "ids": ids, "dmg": dmg, "fracture": 1, "bleed": dmg * float(DmSimData.HEMORRHAGE["dpsFrac"])}
		if rally:
			h["spear"] = true
		_send(h)
	var b := _boss()
	if b.active:
		var rx := b.x - float(origin["x"])
		var rz := b.z - float(origin["z"])
		var along := rx * dx + rz * dz
		if along > 0.0 and along < rng_m + DmSimConsts.BOSS_RADIUS and absf(rx * dz - rz * dx) < half_w + DmSimConsts.BOSS_RADIUS:
			var bh := {"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "fracture": 1, "boss": true}
			if ids.is_empty() and rally:
				bh["spear"] = true
			_send(bh)
			_number(b.x, b.z, dmg, "spear")


## Ossuary Ring rune: bone erupts in a ring around `c`, striking everything inside it.
func _spear_ring(c: Dictionary, r: float, dmg: float) -> void:
	var foes: Array = []
	for e: DmSimEnemy in _live_foes():
		foes.append(_foe_dict(e))
	var hit := DmRunes.ring_hits(c, r, foes)
	for e: Dictionary in hit:
		_number(e["x"], e["z"], dmg, "spear")
	var rally := _spear_rally()
	if not hit.is_empty():
		var ids: Array = []
		for e: Dictionary in hit:
			ids.append(e["id"])
		var h := {"t": "hit", "by": self_id, "ids": ids, "dmg": dmg, "fracture": 1, "bleed": dmg * float(DmSimData.HEMORRHAGE["dpsFrac"])}
		if rally:
			h["spear"] = true
		_send(h)
	var b := _boss()
	if b.active and _h(b.x - float(c["x"]), b.z - float(c["z"])) <= r + DmSimConsts.BOSS_RADIUS:
		var bh := {"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "fracture": 1, "boss": true}
		if hit.is_empty() and rally:
			bh["spear"] = true
		_send(bh)
		_number(b.x, b.z, dmg, "spear")


## Impaling rune: the spear stops at the first enemy it meets, skewers it for more and roots it.
func _spear_impale(origin: Dictionary, dx: float, dz: float, rng_m: float, half_w: float, dmg: float) -> void:
	var foes: Array = []
	for e: DmSimEnemy in _live_foes():
		foes.append(_foe_dict(e))
	var hit: Variant = DmRunes.impale_target(origin, dx, dz, rng_m, half_w, foes)
	var b := _boss()
	var boss_along := INF
	if b.active:
		var rx := b.x - float(origin["x"])
		var rz := b.z - float(origin["z"])
		var along := rx * dx + rz * dz
		if along > 0.0 and along < rng_m + DmSimConsts.BOSS_RADIUS and absf(rx * dz - rz * dx) < half_w + DmSimConsts.BOSS_RADIUS:
			boss_along = along
	if hit == null and boss_along == INF:
		return
	var rally := _spear_rally()
	if hit != null and float(hit["along"]) <= boss_along:
		var e: Dictionary = hit["foe"]
		var h := {"t": "hit", "by": self_id, "ids": [e["id"]], "dmg": dmg, "fracture": 1, "bleed": dmg * float(DmSimData.HEMORRHAGE["dpsFrac"]), "root": true, "rootS": DmSimData.RUNE_TUNING["impale"]["rootS"]}
		if rally:
			h["spear"] = true
		_send(h)
		_number(e["x"], e["z"], dmg, "spear")
	else:
		var bh := {"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "fracture": 1, "boss": true}
		if rally:
			bh["spear"] = true
		_send(bh)
		_number(b.x, b.z, dmg, "spear")


# --- Corpse picking, Exhume, Miasma -------------------------------------------------------------------------------------------------------

## Nearest corpse to the cursor (within `pick_radius`, and within `range_m` of the caster), else the nearest one to the player.
func pick_corpse(t: Dictionary, pick_radius: float = -1.0, range_m: float = -1.0) -> DmSimCorpse:
	if pick_radius < 0.0:
		pick_radius = float(DmSimData.ABILITIES["exhume"]["radius"])
	if range_m < 0.0:
		range_m = float(DmSimData.ABILITIES["exhume"]["range"])
	var best: DmSimCorpse = null
	var best_d := pick_radius
	var area := _area()
	for c: DmSimCorpse in sim.corpses.values():
		if not (area == "" or c.area == "" or c.area == area):
			continue
		var d := _h(c.x - float(t["x"]), c.z - float(t["z"]))
		if d < best_d and _h(c.x - _px(), c.z - _pz()) <= range_m:
			best_d = d
			best = c
	if best != null:
		return best
	best_d = 7.0
	for c: DmSimCorpse in sim.corpses.values():
		if not (area == "" or c.area == "" or c.area == area):
			continue
		var d := _h(c.x - _px(), c.z - _pz())
		if d < best_d:
			best_d = d
			best = c
	return best


## Corpses (not echoes) within r of a point, nearest first (stable on ties).
func _corpses_within(px: float, pz: float, r: float) -> Array:
	var out: Array = []
	var i := 0
	for c: DmSimCorpse in sim.corpses.values():
		i += 1
		if c.echoOwner == "" and _h(c.x - px, c.z - pz) <= r:
			out.append({"c": c, "d": _h(c.x - px, c.z - pz), "i": i})
	out.sort_custom(func(a, b): return a["d"] < b["d"] if a["d"] != b["d"] else a["i"] < b["i"])
	var res: Array = []
	for o in out:
		res.append(o["c"])
	return res


func _corpses_in(x: float, z: float, r: float) -> int:
	var n := 0
	for c: DmSimCorpse in sim.corpses.values():
		if c.echoOwner == "" and _h(c.x - x, c.z - z) <= r:
			n += 1
	return n


func _exhume(t: Dictionary) -> String:
	var c := pick_corpse(t)
	if c == null:
		return "no_corpse"
	var rn := rune("exhume")
	var RT: Dictionary = DmSimData.RUNE_TUNING
	var mass := rn == "rune_mass_grave"
	var company: Array = []
	if rn == "rune_bone_colossus":
		company = _corpses_within(c.x, c.z, float(RT["colossus"]["pickRadius"])).slice(0, int(RT["colossus"]["corpses"]))
	var standing := false
	for th: DmSimThrall in sim.thralls.values():
		if th.owner == self_id and th.kind == "colossus" and th.state != "dead":
			standing = true
			break
	var colossus := company.size() >= int(RT["colossus"]["minCorpses"]) and not standing
	_colossus_cast = colossus
	_face(c.x, c.z)
	var intent := {
		"t": "exhume", "by": self_id, "x": c.x, "z": c.z,
		"r": float(RT["colossus"]["pickRadius"]) if colossus else (float(RT["massGrave"]["pickRadius"]) if mass else 0.8),
		"kind": mods["thrallKind"], "cap": mods["thrallCap"], "hp": p["stats"]["thrallHp"], "damage": p["stats"]["thrallDamage"],
		"attackSpeedMult": mods["thrallAttackSpeedMult"],
	}
	if float(p["loadout"]["bellAllyHeal"]) > 0.0:
		intent["allyHeal"] = p["loadout"]["bellAllyHeal"]
	if mass:
		intent["count"] = RT["massGrave"]["count"]
	if colossus:
		intent["colossus"] = true
	_send(intent)
	return "ok"


func _miasma(t: Dictionary, mult: float = 1.0) -> String:
	var def: Dictionary = DmSimData.ABILITIES["miasma"]
	var x: float = t["x"]
	var z: float = t["z"]
	var d := _h(x - _px(), z - _pz())
	if d > float(def["range"]):
		x = _px() + ((x - _px()) / d) * float(def["range"])
		z = _pz() + ((z - _pz()) / d) * float(def["range"])
	_face(x, z)
	var rn := rune("miasma")
	var RT: Dictionary = DmSimData.RUNE_TUNING
	var r := float(def["radius"]) * float(mods["miasmaRadiusMult"]) * mult * (float(RT["creepingRot"]["radiusMult"]) if rn == "rune_creeping_rot" else 1.0)
	var intent := {"t": "miasma", "by": self_id, "x": x, "z": z, "r": r, "dps": _sp() * float(def["power"]), "durationMs": 6000, "witheredCap": DmLegend.effective_withered_cap(mods), "bloom": mods["miasmaBurstsCorpses"]}
	if rn == "rune_creeping_rot":
		intent["creep"] = RT["creepingRot"]["speed"]
	if rn == "rune_contagion":
		intent["contagion"] = true
	_projectile(_tip(), Callable(self, "_to_point").bind([x, 0.2, z]), 18.0, 12.0, Callable(self, "_send_on_arrive").bind(intent))
	return "ok"


## An arrival that just sends its intent (if the caster still lives).
func _send_on_arrive(_pos: Array, intent: Dictionary) -> void:
	if not p["alive"]:
		return
	_send(intent)


# --- Grimoire rites -----------------------------------------------------------------------------------------------------------------------

## Wailing Skull: marks the enemy under (or nearest) the cursor and chains from there.
func _skull(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["wailing_skull"]
	var target: Variant = t if (t.has("enemyId") or t.get("boss", false)) else null
	if target == null:
		var best_d := float(def["radius"])
		for e: DmSimEnemy in sim.enemies.values():
			if e.state == "dead" or e.state == "rising" or e.state == "burrow" or e.hp <= 0.0:
				continue
			var d := _h(e.x - float(t["x"]), e.z - float(t["z"]))
			if d < best_d:
				best_d = d
				target = {"x": e.x, "z": e.z, "enemyId": e.id}
	if target == null:
		return "no_target"
	if shortfall("wailing_skull", target) > 0.0:
		return "range"
	_face(target["x"], target["z"])
	var from := _tip()
	_skull_leap([from[0], from[1], from[2]], target, _sp() * float(def["power"]), 1, int(DmCombatData.const_table("WAILING_SKULL")["hops"]), {})
	return "ok"


## One flight of the skull. `budget` is the leaps left including this one; a leap that kills earns another, never past maxHops in total.
func _skull_leap(from: Array, t: Dictionary, dmg: float, hop: int, budget: int, struck: Dictionary) -> void:
	var W: Dictionary = DmCombatData.const_table("WAILING_SKULL")
	var ctx := {"t": t, "dmg": dmg, "hop": hop, "budget": budget, "struck": struck, "boss": bool(t.get("boss", false)), "enemy_id": int(t["enemyId"]) if t.has("enemyId") else -1}
	var to_fn: Callable = Callable(self, "_boss_to") if ctx["boss"] else Callable(self, "_to_enemy").bind(ctx["enemy_id"], 1.1)
	_projectile(from, to_fn, float(W["speed"]), 0.0, Callable(self, "_skull_arrive").bind(ctx))


func _skull_arrive(pos: Array, ctx: Dictionary) -> void:
	if not p["alive"]:
		return
	var W: Dictionary = DmCombatData.const_table("WAILING_SKULL")
	var dmg: float = ctx["dmg"]
	var struck: Dictionary = ctx["struck"]
	var killed := false
	var landed := false
	if ctx["boss"]:
		if _boss().active:
			_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})
			landed = true
	else:
		var enemy_id: int = ctx["enemy_id"]
		var e: DmSimEnemy = sim.enemies.get(enemy_id)
		if e != null and e.state != "dead" and e.hp > 0.0:
			killed = e.hp <= dmg * (1.0 + float(DmSimData.FRACTURE["perStack"]) * e.fracture)
			_send({"t": "hit", "by": self_id, "ids": [enemy_id], "dmg": dmg})
			landed = true
		struck[enemy_id] = true
	if landed:
		_number(pos[0], pos[2], dmg, "crit" if killed else "hit")
	var left := int(ctx["budget"]) - 1 + (1 if killed else 0)
	if left <= 0 or int(ctx["hop"]) >= int(W["maxHops"]):
		return
	var nxt: Variant = null
	var best_d := float(W["leapRange"])
	for e: DmSimEnemy in sim.enemies.values():
		if e.state == "dead" or e.state == "rising" or e.state == "burrow" or e.hp <= 0.0 or struck.has(e.id):
			continue
		var d := _h(e.x - pos[0], e.z - pos[2])
		if d < best_d:
			best_d = d
			nxt = {"x": e.x, "z": e.z, "enemyId": e.id}
	if nxt == null:
		return
	_skull_leap([pos[0], pos[1], pos[2]], nxt, dmg * float(W["falloff"]), int(ctx["hop"]) + 1, left, struck)


## Grave Step: blood-mist blink onto a corpse in your own area; the corpse stays.
func _step(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["grave_step"]
	var c := pick_corpse(t, float(DmSimData.ABILITIES["exhume"]["radius"]), float(def["range"]))
	var area := _area()
	if c == null or area == "" or c.area != area or _h(c.x - _px(), c.z - _pz()) > float(def["range"]):
		return "no_corpse"
	var ox := _px()
	var oz := _pz()
	_teleport(c.x, c.z)
	_face(_px() + (_px() - ox), _pz() + (_pz() - oz))
	var r := float(DmCombatData.const_table("GRAVE_STEP")["burstRadius"])
	var dmg := _sp() * float(def["power"])
	var ids: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if _gone(e) or _h(e.x - _px(), e.z - _pz()) > r + e.radius:
			continue
		ids.append(e.id)
		if ids.size() <= 12:
			_number(e.x, e.z, dmg, "hit")
		if ids.size() >= 64:
			break
	if not ids.is_empty():
		_send({"t": "hit", "by": self_id, "ids": ids, "dmg": dmg, "bleed": dmg * float(DmSimData.HEMORRHAGE["dpsFrac"])})
	var b := _boss()
	if b.active and _h(b.x - _px(), b.z - _pz()) <= r + DmSimConsts.BOSS_RADIUS:
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})
		_number(b.x, b.z, dmg, "hit")
	return "ok"


## Grave Frost: a cold bolt runs the cone's centre line; the cone resolves when it lands.
func _frost(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["grave_frost"]
	var G: Dictionary = DmSimData.GRAVE_FROST
	var dx: float = t["x"] - _px()
	var dz: float = t["z"] - _pz()
	var l := _h(dx, dz)
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	_face(_px() + dx, _pz() + dz)
	var origin := {"x": _px(), "z": _pz()}
	var ln := float(def["range"])
	var dmg := _sp() * float(def["power"])
	var end := [float(origin["x"]) + dx * ln, 0.9, float(origin["z"]) + dz * ln]
	var ctx := {"origin": origin, "dx": dx, "dz": dz, "len": ln, "dmg": dmg}
	_projectile(_tip(), Callable(self, "_to_point").bind(end), float(G["speed"]), 0.0, Callable(self, "_frost_arrive").bind(ctx))
	return "ok"


func _frost_arrive(_pos: Array, ctx: Dictionary) -> void:
	if not p["alive"]:
		return
	var G: Dictionary = DmSimData.GRAVE_FROST
	var origin: Dictionary = ctx["origin"]
	var dx: float = ctx["dx"]
	var dz: float = ctx["dz"]
	var ln: float = ctx["len"]
	var dmg: float = ctx["dmg"]
	var slope := tan((float(G["halfAngleDeg"]) * PI) / 180.0)
	var chilled: Array = []
	var shattered: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if _gone(e):
			continue
		var rx := e.x - float(origin["x"])
		var rz := e.z - float(origin["z"])
		var along := rx * dx + rz * dz
		if along < -e.radius or along > ln + e.radius:
			continue
		if absf(rx * dz - rz * dx) > slope * maxf(0.0, along) + e.radius:
			continue
		var shatter := e.chillT > 0.0
		if shatter:
			shattered.append(e.id)
		else:
			chilled.append(e.id)
		_number(e.x, e.z, dmg * float(G["shatterMult"]) if shatter else dmg, "crit" if shatter else "hit")
		if chilled.size() + shattered.size() >= 64:
			break
	if not chilled.is_empty():
		_send({"t": "hit", "by": self_id, "ids": chilled, "dmg": dmg, "chill": true})
	if not shattered.is_empty():
		_send({"t": "hit", "by": self_id, "ids": shattered, "dmg": dmg * float(G["shatterMult"]), "chill": true})
	var b := _boss()
	if b.active:
		var rx := b.x - float(origin["x"])
		var rz := b.z - float(origin["z"])
		var along := rx * dx + rz * dz
		if along > -DmSimConsts.BOSS_RADIUS and along < ln + DmSimConsts.BOSS_RADIUS and absf(rx * dz - rz * dx) <= slope * maxf(0.0, along) + DmSimConsts.BOSS_RADIUS:
			_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})
			_number(b.x, b.z, dmg, "hit")


func _tick_timed(now: float) -> void:
	if _timed.is_empty():
		return
	var alive: bool = p["alive"]
	var i := _timed.size() - 1
	while i >= 0:
		var t: Dictionary = _timed[i]
		var done: bool = (not alive) or now >= float(t["until"])
		while not done and now >= float(t["next"]):
			t["next"] = float(t["next"]) + float(t["every"])
			var r: Variant = t["tick"].call(now)
			if r is bool and r == false:
				done = true
		if done:
			var en: Callable = t["end"]
			if en.is_valid():
				en.call()
			_timed.remove_at(i)
		i -= 1


## Clamp a ground aim to the rite's reach.
func _ground_aim(id: String, t: Dictionary) -> Array:
	var rng_m := float(DmSimData.ABILITIES[id]["range"])
	var x: float = t["x"]
	var z: float = t["z"]
	var d := _h(x - _px(), z - _pz())
	if d > rng_m:
		x = _px() + ((x - _px()) / d) * rng_m
		z = _pz() + ((z - _pz()) / d) * rng_m
	return [x, z]


## Enemy ids within r of a point (capped like every client-resolved hit), plus whether the boss is in it.
func _in_circle(x: float, z: float, r: float) -> Dictionary:
	var ids: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if e.state == "dead" or e.state == "rising" or e.state == "burrow" or _h(e.x - x, e.z - z) > r + e.radius:
			continue
		ids.append(e.id)
		if ids.size() >= 64:
			break
	var b := _boss()
	return {"ids": ids, "boss": b.active and b.hp > 0.0 and _h(b.x - x, b.z - z) <= r + DmSimConsts.BOSS_RADIUS}


## Soul Siphon: a tether that follows the target, draining every half second into health and essence.
func _siphon(t: Dictionary, now: float) -> String:
	var def: Dictionary = DmSimData.ABILITIES["soul_siphon"]
	var S: Dictionary = DmCombatData.const_table("SOUL_SIPHON")
	if not t.has("enemyId") and not t.get("boss", false):
		return "no_target"
	if shortfall("soul_siphon", t) > 0.0:
		return "range"
	_face(t["x"], t["z"])
	var is_boss: bool = t.get("boss", false)
	var break_r := float(def["range"]) * float(S["breakMult"]) + (DmSimConsts.BOSS_RADIUS if is_boss else 0.0)
	var dmg := _sp() * float(def["power"])
	var ctx := {"boss": is_boss, "enemy_id": int(t["enemyId"]) if t.has("enemyId") else -1, "break_r": break_r, "dmg": dmg, "ended": false}
	_timed.append({"until": now + float(S["durationS"]) * 1000.0, "next": now + float(S["tickS"]) * 1000.0, "every": float(S["tickS"]) * 1000.0,
		"tick": Callable(self, "_siphon_tick").bind(ctx), "end": Callable(self, "_siphon_end").bind(ctx)})
	return "ok"


func _siphon_target(ctx: Dictionary) -> Variant:
	if ctx["ended"] or not p["alive"]:
		return null
	var q: Variant = null
	if ctx["boss"]:
		var b := _boss()
		if b.active and b.hp > 0.0:
			q = [b.x, 2.2, b.z]
	else:
		var e: DmSimEnemy = sim.enemies.get(int(ctx["enemy_id"]))
		if e != null and e.state != "dead" and e.state != "burrow":
			q = [e.x, 1.1, e.z]
	return q if (q != null and _h(q[0] - _px(), q[2] - _pz()) <= float(ctx["break_r"])) else null


func _siphon_tick(_now_ms: float, ctx: Dictionary) -> Variant:
	var q: Variant = _siphon_target(ctx)
	if q == null:
		return false
	var S: Dictionary = DmCombatData.const_table("SOUL_SIPHON")
	var dmg: float = ctx["dmg"]
	if ctx["boss"]:
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})
	else:
		_send({"t": "hit", "by": self_id, "ids": [int(ctx["enemy_id"])], "dmg": dmg})
	_number(q[0], q[2], dmg, "hit")
	_heal(dmg * float(S["healFrac"]))
	DmPlayerRules.add_resource(p, float(S["essencePerTick"]))
	return true


func _siphon_end(ctx: Dictionary) -> void:
	ctx["ended"] = true


## Bone Prison: a caging ring of spikes; everything inside is rooted and Fractured.
func _prison(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["bone_prison"]
	var P: Dictionary = DmSimData.BONE_PRISON
	var xz := _ground_aim("bone_prison", t)
	_face(xz[0], xz[1])
	var r := float(def["radius"])
	var dmg := _sp() * float(def["power"])
	var ic := _in_circle(xz[0], xz[1], r)
	var ids: Array = ic["ids"]
	if not ids.is_empty():
		_send({"t": "hit", "by": self_id, "ids": ids, "dmg": dmg, "fracture": P["fracture"], "root": true})
		for k in mini(6, ids.size()):
			var e: DmSimEnemy = sim.enemies.get(int(ids[k]))
			if e != null:
				_number(e.x, e.z, dmg, "hit")
	if ic["boss"]:
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true, "fracture": P["fracture"]})
	return "ok"


## Grave Hands: a slowing field of clawing hands; corpses inside at cast time add hands and damage.
func _hands(t: Dictionary, now: float) -> String:
	var def: Dictionary = DmSimData.ABILITIES["grave_hands"]
	var G: Dictionary = DmSimData.GRAVE_HANDS
	var xz := _ground_aim("grave_hands", t)
	_face(xz[0], xz[1])
	var r := float(def["radius"])
	var corpses := mini(int(G["maxCorpses"]), _corpses_in(xz[0], xz[1], r))
	var dmg := _sp() * float(def["power"]) * (1.0 + float(G["perCorpse"]) * corpses)
	var ctx := {"x": xz[0], "z": xz[1], "r": r, "dmg": dmg}
	_timed.append({"until": now + float(G["durationS"]) * 1000.0, "next": now + 60.0, "every": float(G["tickS"]) * 1000.0,
		"tick": Callable(self, "_hands_tick").bind(ctx), "end": Callable()})
	return "ok"


func _hands_tick(_now_ms: float, ctx: Dictionary) -> Variant:
	var ic := _in_circle(ctx["x"], ctx["z"], ctx["r"])
	if not ic["ids"].is_empty():
		_send({"t": "hit", "by": self_id, "ids": ic["ids"], "dmg": ctx["dmg"], "slow": true})
	if ic["boss"]:
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": ctx["dmg"], "boss": true})
	return null


## Bone Storm: a funnel of bone fragments that drifts toward the nearest enemy, shredding what it passes.
func _storm(t: Dictionary, now: float) -> String:
	var def: Dictionary = DmSimData.ABILITIES["bone_storm"]
	var B: Dictionary = DmCombatData.const_table("BONE_STORM")
	var start := _ground_aim("bone_storm", t)
	_face(start[0], start[1])
	var r := float(def["radius"])
	var extra := minf(float(B["maxExtraS"]), _corpses_in(start[0], start[1], r) * float(B["perCorpseS"]))
	var life := float(B["durationS"]) + extra
	var dmg := _sp() * float(def["power"])
	var ctx := {"c": [start[0], start[1]], "r": r, "dmg": dmg, "last": now}
	_timed.append({"until": now + life * 1000.0, "next": now + float(B["tickS"]) * 1000.0, "every": float(B["tickS"]) * 1000.0,
		"tick": Callable(self, "_storm_tick").bind(ctx), "end": Callable()})
	return "ok"


func _storm_tick(t_now: float, ctx: Dictionary) -> Variant:
	var B: Dictionary = DmCombatData.const_table("BONE_STORM")
	var dt := minf(1.0, (t_now - float(ctx["last"])) / 1000.0)
	ctx["last"] = t_now
	var c: Array = ctx["c"]
	var best: DmSimEnemy = null
	var best_d := float(B["seekR"])
	for e: DmSimEnemy in sim.enemies.values():
		if e.state == "dead" or e.state == "rising" or e.state == "burrow":
			continue
		var d := _h(e.x - c[0], e.z - c[1])
		if d < best_d:
			best_d = d
			best = e
	if best != null and best_d > 0.3:
		var step := minf(best_d, float(B["drift"]) * dt)
		c[0] = c[0] + ((best.x - c[0]) / best_d) * step
		c[1] = c[1] + ((best.z - c[1]) / best_d) * step
	var ic := _in_circle(c[0], c[1], ctx["r"])
	if not ic["ids"].is_empty():
		_send({"t": "hit", "by": self_id, "ids": ic["ids"], "dmg": ctx["dmg"]})
	if ic["boss"]:
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": ctx["dmg"], "boss": true})
	return null


## Bone Mantle: ask the host for the corpses; the barrier arrives with its answer.
func _mantle() -> String:
	_send({"t": "signature", "by": self_id, "sig": "mantle", "x": _px(), "z": _pz(), "dx": 0, "dz": 0, "sp": _sp()})
	return "ok"


## The caster's own client handling of a Bone Mantle answer: the barrier and the shard clock (only the caster's).
func on_mantle(ev: Dictionary, mine: bool) -> void:
	if not mine:
		return
	var M: Dictionary = DmSimData.BONE_MANTLE
	if int(ev["corpses"]) > 0:
		on_corpse_consumed()
	if not p["alive"]:
		return
	var now := _now
	var frac := minf(float(M["barrierCap"]), float(M["barrierBase"]) + float(M["barrierPerCorpse"]) * int(ev["corpses"]))
	p["barrier"] = maxf(float(p["barrier"]), float(p["stats"]["maxHp"]) * frac)
	p["barrierHoldUntil"] = now + float(M["durationS"]) * 1000.0
	_mantle_until = now + float(M["durationS"]) * 1000.0
	_next_shard_at = now + float(M["tickS"]) * 1000.0


# --- Legendary set mechanics that resolve on the caster's own client ---------------------------------------------------------------------

func wisp_count() -> int:
	return _wisps.size()


## A corpse of yours was consumed (Exhume, Litany, Offering, Mantle, Corpse Explosion): Requiem 4 summons a healing wisp.
func on_corpse_consumed() -> void:
	var secs := float(mods.get("corpseWisp", 0.0))
	if not (secs > 0.0) or not p["alive"]:
		return
	var now := _now
	var L: Dictionary = DmSimData.LEGEND
	if _wisps.size() >= int(L["wispCap"]):
		# JS reduce keeps `a` when a.until <= b.until: the first of equals wins
		var w: Dictionary = _wisps[0]
		for i in range(1, _wisps.size()):
			var b: Dictionary = _wisps[i]
			w = w if float(w["until"]) <= float(b["until"]) else b
		w["until"] = now + secs * 1000.0
		return
	var n := _wisps.size()
	_wisps.append({"born": now, "until": now + secs * 1000.0, "nextHeal": now + 1000.0, "speed": 2.1 + n * 0.45, "radius": 1.15 + n * 0.28})


func _wisp_at(w: Dictionary, now: float) -> Array:
	var t := maxf(0.0, (now - float(w["born"])) / 1000.0)
	var a := t * float(w["speed"])
	var r := float(w["radius"]) * minf(1.0, 0.25 + t * 3.0)
	return [_px() + DmFdlibm.cos_(a) * r, _pz() + DmFdlibm.sin_(a) * r]


func _tick_wisps(now: float) -> void:
	if _wisps.is_empty():
		return
	var L: Dictionary = DmSimData.LEGEND
	var heal := 0.0
	var i := _wisps.size() - 1
	while i >= 0:
		var w: Dictionary = _wisps[i]
		if not p["alive"] or now >= float(w["until"]):
			_wisps.remove_at(i)
			i -= 1
			continue
		while now >= float(w["nextHeal"]) and float(w["nextHeal"]) < float(w["until"]):
			heal += float(p["stats"]["maxHp"]) * float(L["wispHealFrac"])
			w["nextHeal"] = float(w["nextHeal"]) + 1000.0
		i -= 1
	if heal > 0.0 and p["alive"]:
		_heal(heal)
		if heal >= 1.0:
			notes.append({"text": "+%d" % DmMath.js_round(heal), "kind": "heal"})


## Requiem 5: Soul Harvest empowered a rite, so every wraith (thrall) and wisp of yours releases a nova (capped).
func _wraith_nova() -> void:
	var k := float(mods.get("wraithNova", 0.0))
	if not (k > 0.0) or not p["alive"]:
		return
	var L: Dictionary = DmSimData.LEGEND
	var now := _now
	var src: Array = []
	for w: Dictionary in _wisps:
		src.append(_wisp_at(w, now))
	for th: DmSimThrall in sim.thralls.values():
		if th.owner == self_id and th.kind == "wraith" and th.state != "dead" and th.state != "rising":
			src.append([th.x, th.z])
	if src.is_empty():
		return
	var dmg := _sp() * k
	var struck: Dictionary = {}
	var shown := 0
	for s: Array in src.slice(0, int(L["novaMax"])):
		var ids: Array = []
		for e: DmSimEnemy in sim.enemies.values():
			if e.state == "dead" or e.state == "burrow" or _h(e.x - s[0], e.z - s[1]) > float(L["novaR"]) + e.radius:
				continue
			ids.append(e.id)
			if not struck.has(e.id) and shown < 12:
				struck[e.id] = true
				shown += 1
				_number(e.x, e.z, dmg, "hit")
		if not ids.is_empty():
			_send({"t": "hit", "by": self_id, "ids": ids, "dmg": dmg})
		var b := _boss()
		if b.active and _h(b.x - s[0], b.z - s[1]) <= float(L["novaR"]) + DmSimConsts.BOSS_RADIUS:
			_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})


## Colossus Mantle 5: the Litany barrier broke under damage; it bursts into bone shards around the caster.
func litany_shatter(barrier_size: float) -> void:
	var dmg := DmLegend.shatter_damage(barrier_size, float(mods.get("litanyShatter", 0.0)))
	if dmg <= 0.0 or not p["alive"]:
		return
	var L: Dictionary = DmSimData.LEGEND
	var ids: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if e.state == "dead" or e.state == "burrow" or _h(e.x - _px(), e.z - _pz()) > float(L["shatterR"]) + e.radius:
			continue
		ids.append(e.id)
		if ids.size() <= 12:
			_number(e.x, e.z, dmg, "hit")
	if not ids.is_empty():
		_send({"t": "hit", "by": self_id, "ids": ids, "dmg": dmg})
	var b := _boss()
	if b.active and _h(b.x - _px(), b.z - _pz()) <= float(L["shatterR"]) + DmSimConsts.BOSS_RADIUS:
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})


## Colossus Mantle 4: Bone Ward turned `bone_ward` of a blow; `wardReflect` of that is dealt back at whatever struck it ((x, z) = where the blow came from).
func reflect_ward(raw: float, bone_ward: float, x: float, z: float) -> void:
	var dmg := DmLegend.ward_reflect_damage(raw, bone_ward, float(mods.get("wardReflect", 0.0)))
	if dmg < 1.0:
		return
	var best: DmSimEnemy = null
	var best_d := 0.6
	for e: DmSimEnemy in sim.enemies.values():
		if e.state == "dead" or e.state == "burrow":
			continue
		var d := _h(e.x - x, e.z - z)
		if d <= best_d + e.radius * 0.5 and (best == null or d < best_d):
			best = e
			best_d = d
	var b := _boss()
	if best != null:
		_send({"t": "hit", "by": self_id, "ids": [best.id], "dmg": dmg})
		_number(best.x, best.z, dmg, "hit")
	elif b.active and _h(b.x - x, b.z - z) <= DmSimConsts.BOSS_RADIUS + 0.6:
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})
		_number(b.x, b.z, dmg, "hit")


## Per frame (now in ms, dt in seconds): New Blood timers, timed rites, wisps, the dash glide, Corpse Vigil, the Bone Mantle shards, then
## the projectiles in flight.
func update(now: float, dt: float) -> void:
	_now = now
	_nb_update(now)
	_tick_timed(now)
	_tick_wisps(now)
	if _dashing != null:
		var d: Dictionary = _dashing
		var k := minf(1.0, (now - float(d["start"])) / float(d["dur"]))
		var e := 1.0 - (1.0 - k) * (1.0 - k)
		if p["alive"]:
			_teleport(float(d["fx"]) + (float(d["tx"]) - float(d["fx"])) * e, float(d["fz"]) + (float(d["tz"]) - float(d["fz"])) * e)
		if k >= 1.0:
			_dashing = null
			var on_arrive: Callable = d.get("on_arrive", Callable())
			if on_arrive.is_valid():
				on_arrive.call()
	if now < _vigil_until:
		var vdt := minf(0.25, maxf(0.0, (now - _last_vigil_at) / 1000.0))
		_last_vigil_at = now
		if p["alive"] and vdt > 0.0:
			_heal(float(p["stats"]["maxHp"]) * float(DmCombatData.const_table("CORPSE_VIGIL")["regenFracPerS"]) * vdt)
	else:
		_last_vigil_at = now
	_update_mantle(now)
	_step_projectiles(dt)


func _update_mantle(now: float) -> void:
	if now >= _mantle_until:
		return
	if not p["alive"]:
		_mantle_until = 0.0
		p["barrierHoldUntil"] = 0.0
		return
	if now < _next_shard_at:
		return
	var M: Dictionary = DmSimData.BONE_MANTLE
	_next_shard_at = now + float(M["tickS"]) * 1000.0
	var reach := float(M["orbitRadius"]) + 0.4
	var dmg := _sp() * float(DmSimData.ABILITIES["bone_mantle"]["power"])
	var ids: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if _gone(e) or _h(e.x - _px(), e.z - _pz()) > reach + e.radius:
			continue
		ids.append(e.id)
		if ids.size() <= 6:
			_number(e.x, e.z, dmg, "hit")
		if ids.size() >= 64:
			break
	if not ids.is_empty():
		_send({"t": "hit", "by": self_id, "ids": ids, "dmg": dmg})
	var b := _boss()
	if b.active and _h(b.x - _px(), b.z - _pz()) <= reach + DmSimConsts.BOSS_RADIUS:
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})


# --- Spell variety ------------------------------------------------------------------------------------------------------------------------

## Bone Fan: three slivers, each homing on a distinct enemy in a narrow cone (the boss takes one).
func _fan(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["bone_fan"]
	var BF: Dictionary = DmCombatData.const_table("BONE_FAN")
	if not t.has("enemyId") and not t.get("boss", false):
		return "no_target"
	if shortfall("bone_fan", t) > 0.0:
		return "range"
	_face(t["x"], t["z"])
	var aim_a := DmFdlibm.atan2_(float(t["x"]) - _px(), float(t["z"]) - _pz())
	var cone := (float(BF["coneHalfDeg"]) * PI) / 180.0
	var picks: Array = [{"boss": true, "off": 0.0} if t.get("boss", false) else {"id": int(t["enemyId"]), "off": 0.0}]
	var others: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if e.state == "dead" or e.state == "rising" or e.state == "burrow" or (t.has("enemyId") and e.id == int(t["enemyId"])):
			continue
		var d := _h(e.x - _px(), e.z - _pz())
		if d > float(def["range"]) + 0.4:
			continue
		var off := DmFdlibm.atan2_(e.x - _px(), e.z - _pz()) - aim_a
		while off > PI:
			off -= PI * 2.0
		while off < -PI:
			off += PI * 2.0
		if absf(off) <= cone:
			others.append({"id": e.id, "off": off, "d": d})
	others = DmStableSort.sorted(others, func(a: Dictionary, b: Dictionary) -> bool:
		var ao := absf(a["off"])
		var bo := absf(b["off"])
		return ao < bo if ao != bo else a["d"] < b["d"])
	picks.append_array(others.slice(0, int(BF["slivers"]) - 1))
	var from := _tip()
	var dmg := _sp() * float(def["power"])
	var spread := (float(BF["spreadDeg"]) * PI) / 180.0
	var angles := [0.0, -spread, spread]
	var refund := {"n": 0.0}
	for k in int(BF["slivers"]):
		var pick: Variant = picks[k] if k < picks.size() else null
		var a: float = aim_a + angles[k]
		var miss := [_px() + DmFdlibm.sin_(a) * float(def["range"]), 1.0, _pz() + DmFdlibm.cos_(a) * float(def["range"])]
		var ctx := {"pick": pick, "miss": miss, "dmg": dmg, "refund": refund}
		_projectile(from, Callable(self, "_fan_to").bind(ctx), float(BF["speed"]), 0.0, Callable(self, "_fan_arrive").bind(ctx))
	return "ok"


func _fan_to(ctx: Dictionary) -> Variant:
	var pick: Variant = ctx["pick"]
	if pick != null and pick.get("boss", false):
		var b := _boss()
		return [b.x, 2.2, b.z] if b.active else ctx["miss"]
	var e: DmSimEnemy = sim.enemies.get(int(pick["id"])) if (pick != null and pick.has("id")) else null
	return [e.x, 1.0, e.z] if (e != null and e.state != "dead") else ctx["miss"]


func _fan_arrive(pos: Array, ctx: Dictionary) -> void:
	var pick: Variant = ctx["pick"]
	if not p["alive"] or pick == null:
		return
	var dmg: float = ctx["dmg"]
	if pick.get("boss", false):
		if not _boss().active:
			return
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})
	else:
		var e: DmSimEnemy = sim.enemies.get(int(pick["id"]))
		if e == null or e.state == "dead":
			return
		_send({"t": "hit", "by": self_id, "ids": [int(pick["id"])], "dmg": dmg})
	var BF: Dictionary = DmCombatData.const_table("BONE_FAN")
	var refund: Dictionary = ctx["refund"]
	if float(refund["n"]) < float(BF["essenceCap"]):
		var add := minf(float(BF["essencePerHit"]), float(BF["essenceCap"]) - float(refund["n"]))
		refund["n"] = float(refund["n"]) + add
		_set_essence(minf(_max_essence(), _essence() + add))
	_number(pos[0], pos[2], dmg, "hit")


## Rot Lance: pierces the first two enemies in a narrow lane; the host adds one Withered stack each.
func _lance(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["rot_lance"]
	var RL: Dictionary = DmCombatData.const_table("ROT_LANCE")
	if not t.has("enemyId") and not t.get("boss", false):
		return "no_target"
	if shortfall("rot_lance", t) > 0.0:
		return "range"
	var dx: float = t["x"] - _px()
	var dz: float = t["z"] - _pz()
	var len := _h(dx, dz)
	if len == 0.0:
		len = 1.0
	dx /= len
	dz /= len
	_face(_px() + dx, _pz() + dz)
	var origin := {"x": _px(), "z": _pz()}
	var end := [float(origin["x"]) + dx * float(def["range"]), 1.0, float(origin["z"]) + dz * float(def["range"])]
	var dmg := _sp() * float(def["power"])
	var cap := DmLegend.effective_withered_cap(mods)
	var ctx := {"origin": origin, "dx": dx, "dz": dz, "dmg": dmg, "cap": cap}
	_projectile(_tip(), Callable(self, "_to_point").bind(end), float(RL["speed"]), 0.0, Callable(self, "_lance_arrive").bind(ctx))
	return "ok"


func _lance_arrive(_pos: Array, ctx: Dictionary) -> void:
	if not p["alive"]:
		return
	var def: Dictionary = DmSimData.ABILITIES["rot_lance"]
	var RL: Dictionary = DmCombatData.const_table("ROT_LANCE")
	var origin: Dictionary = ctx["origin"]
	var dx: float = ctx["dx"]
	var dz: float = ctx["dz"]
	var dmg: float = ctx["dmg"]
	var lane: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if _gone(e):
			continue
		var rx := e.x - float(origin["x"])
		var rz := e.z - float(origin["z"])
		var along := rx * dx + rz * dz
		if along > 0.0 and along < float(def["range"]) + e.radius and absf(rx * dz - rz * dx) < float(RL["halfWidth"]) + e.radius:
			lane.append({"along": along, "id": e.id, "x": e.x, "z": e.z})
	var b := _boss()
	if b.active:
		var rx := b.x - float(origin["x"])
		var rz := b.z - float(origin["z"])
		var along := rx * dx + rz * dz
		if along > 0.0 and along < float(def["range"]) + DmSimConsts.BOSS_RADIUS and absf(rx * dz - rz * dx) < float(RL["halfWidth"]) + DmSimConsts.BOSS_RADIUS:
			lane.append({"along": along, "boss": true, "x": b.x, "z": b.z})
	lane = DmStableSort.sorted(lane, func(a: Dictionary, c: Dictionary) -> bool: return a["along"] < c["along"])
	var hits: Array = lane.slice(0, int(RL["pierce"]))
	var ids: Array = []
	var has_boss := false
	for h: Dictionary in hits:
		if h.has("id"):
			ids.append(h["id"])
		if h.get("boss", false):
			has_boss = true
	if not ids.is_empty():
		_send({"t": "hit", "by": self_id, "ids": ids, "dmg": dmg, "withered": RL["withered"], "witheredCap": ctx["cap"]})
	if has_boss:
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})
	if not hits.is_empty():
		_set_essence(minf(_max_essence(), _essence() + float(RL["essence"])))
	for h: Dictionary in hits:
		_number(h["x"], h["z"], dmg, "hit")


## Grave Offering: the host consumes the corpse; essence + health arrive with its answer (on_offering).
func _offering(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["grave_offering"]
	var c := pick_corpse(t, float(def["radius"]), float(def["range"]))
	if c == null or (_area() != "" and c.area != _area()):
		return "no_corpse"
	_face(c.x, c.z)
	_send({"t": "signature", "by": self_id, "sig": "offering", "x": c.x, "z": c.z, "dx": 0, "dz": 0, "sp": _sp()})
	return "ok"


func on_offering(ev: Dictionary, mine: bool) -> void:
	if not ev["ok"]:
		return
	if mine:
		on_corpse_consumed()
	var ctx := {"ev": ev, "mine": mine}
	_projectile([float(ev["x"]), 0.8, float(ev["z"])], Callable(self, "_follow_caster"), 14.0, 0.0, Callable(self, "_offering_arrive").bind(ctx))


func _follow_caster() -> Variant:
	return [_px(), 1.2, _pz()] if p["alive"] else null


func _offering_arrive(_pos: Array, ctx: Dictionary) -> void:
	if not ctx["mine"] or not p["alive"]:
		return
	var G: Dictionary = DmSimData.GRAVE_OFFERING
	var ev: Dictionary = ctx["ev"]
	var essence := (float(G["essence"]) + (float(G["resonantBonus"]) if ev.get("corpseKind") == "resonant" else 0.0)) * (float(G["eliteMult"]) if ev.get("elite", false) else 1.0)
	_set_essence(minf(_max_essence(), _essence() + essence))
	var heal := float(p["stats"]["maxHp"]) * (float(G["healFrac"]) + float(mods.get("corpseHeal", 0.0)))
	p["hp"] = minf(float(p["stats"]["maxHp"]), float(p["hp"]) + heal)


## Ivory Cleave: a 120 degree crescent resolved instantly, Fracturing what it cuts.
func _cleave(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["ivory_cleave"]
	var IC: Dictionary = DmCombatData.const_table("IVORY_CLEAVE")
	var dx: float = t["x"] - _px()
	var dz: float = t["z"] - _pz()
	var l := _h(dx, dz)
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	_face(_px() + dx, _pz() + dz)
	var cos_max := DmFdlibm.cos_((float(IC["halfAngleDeg"]) * PI) / 180.0)
	var dmg := _sp() * float(def["power"])
	var ids: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if _gone(e) or not _in_arc(e.x, e.z, e.radius, float(IC["reach"]), dx, dz, cos_max):
			continue
		ids.append(e.id)
		if ids.size() <= 10:
			_number(e.x, e.z, dmg, "hit")
		if ids.size() >= 64:
			break
	if not ids.is_empty():
		_send({"t": "hit", "by": self_id, "ids": ids, "dmg": dmg, "fracture": IC["fracture"]})
	var b := _boss()
	if b.active and _in_arc(b.x, b.z, DmSimConsts.BOSS_RADIUS, float(IC["reach"]), dx, dz, cos_max):
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "fracture": IC["fracture"], "boss": true})
		_number(b.x, b.z, dmg, "hit")
	return "ok"


func _in_arc(x: float, z: float, r: float, reach: float, dx: float, dz: float, cos_max: float) -> bool:
	var rx := x - _px()
	var rz := z - _pz()
	var d := _h(rx, rz)
	if d > reach + r:
		return false
	return d < r or (rx * dx + rz * dz) / d >= cos_max


## The default dash rule (veilTarget): walk toward the goal in small steps and keep the last point that is walkable and still in the starting hall.
func veil_target(x: float, z: float, tx: float, tz: float) -> Array:
	var area := sim.nav.area_at(x, z)
	var step_m := float(DmCombatData.const_table("VEIL_STEP")["stepM"])
	var n := maxi(1, int(ceilf(_h(tx - x, tz - z) / step_m)))
	var best: Array = [x, z]
	for i in range(1, n + 1):
		var px := x + ((tx - x) * i) / n
		var pz := z + ((tz - z) * i) / n
		if sim.nav.blocked(px, pz, 0.45) or sim.nav.area_at(px, pz) != area:
			break
		best = [px, pz]
	return best


func _dash(tx: float, tz: float) -> Array:
	if dash_fn.is_valid():
		return dash_fn.call(tx, tz)
	return veil_target(_px(), _pz(), tx, tz)


## Veil Step: a short, lerped slip toward the cursor that stops at the last valid point.
func _veil(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["veil_step"]
	var VS: Dictionary = DmCombatData.const_table("VEIL_STEP")
	var dx: float = t["x"] - _px()
	var dz: float = t["z"] - _pz()
	var l := _h(dx, dz)
	if l < 0.3:
		return "no_target"
	var reach := minf(float(def["range"]), l)
	dx /= l
	dz /= l
	var goal := [_px() + dx * reach, _pz() + dz * reach]
	var to := _dash(goal[0], goal[1])
	if _h(to[0] - _px(), to[1] - _pz()) < float(VS["stepM"]):
		return "no_target"
	_face(to[0], to[1])
	_dashing = {"fx": _px(), "fz": _pz(), "tx": to[0], "tz": to[1], "start": _now, "dur": float(VS["durationS"]) * 1000.0}
	return "ok"


## Rally the Dead: the host buffs and retargets the legion.
func _rally(t: Dictionary) -> String:
	if thrall_count() == 0:
		return "no_thralls"
	var RL: Dictionary = DmSimData.RALLY
	var dur := float(RL["durationS"]) + (float(RL["gravecallerBonusS"]) if discipline_id == "gravecaller" else 0.0)
	_send({"t": "signature", "by": self_id, "sig": "rally", "x": t["x"], "z": t["z"], "dx": 0, "dz": 0, "sp": _sp(), "dur": dur})
	return "ok"


## Carrion Seed: plant on the corpse nearest the cursor; the host arms and bursts it.
func _seed(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["carrion_seed"]
	var c := pick_corpse(t, 2.5, float(def["range"]))
	if c == null or (_area() != "" and c.area != _area()):
		return "no_corpse"
	_face(c.x, c.z)
	var CS: Dictionary = DmSimData.CARRION_SEED
	var cap := float(CS["witheredCap"])
	if mods.get("miasmaBurstsCorpses", false):
		cap = maxf(float(CS["witheredCap"]), DmLegend.effective_withered_cap(mods))
	_send({"t": "signature", "by": self_id, "sig": "seed", "x": c.x, "z": c.z, "dx": 0, "dz": 0, "sp": _sp(), "cap": cap})
	return "ok"


# --- Hollow Knight ------------------------------------------------------------------------------------------------------------------------

## Hollow Cut: a short sword arc, client-resolved like Ivory Cleave, paying Rage per body cut.
func _hollow_cut(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["hollow_cut"]
	var HC: Dictionary = DmCombatData.const_table("HOLLOW_CUT")
	var dx: float = t["x"] - _px()
	var dz: float = t["z"] - _pz()
	var l := _h(dx, dz)
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	_face(_px() + dx, _pz() + dz)
	var cos_max := DmFdlibm.cos_((float(HC["halfAngleDeg"]) * PI) / 180.0)
	var dmg := _sp() * float(def["power"])
	var ids: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if _gone(e) or not _in_arc(e.x, e.z, e.radius, float(HC["reach"]), dx, dz, cos_max):
			continue
		ids.append(e.id)
		if ids.size() <= 10:
			_number(e.x, e.z, dmg, "hit")
		if ids.size() >= 64:
			break
	if not ids.is_empty():
		_send({"t": "hit", "by": self_id, "ids": ids, "dmg": dmg})
	var b := _boss()
	if b.active and _in_arc(b.x, b.z, DmSimConsts.BOSS_RADIUS, float(HC["reach"]), dx, dz, cos_max):
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})
		_number(b.x, b.z, dmg, "hit")
		DmPlayerRules.add_resource(p, float(HC["rage"]))
	DmPlayerRules.add_resource(p, float(HC["rage"]) * ids.size())
	return "ok"


## Shield Bash: a short client dash; the host owns the strike and the stun (sig 'bash').
func _shield_bash(t: Dictionary) -> String:
	var SB: Dictionary = DmSimData.SHIELD_BASH
	var dx: float = t["x"] - _px()
	var dz: float = t["z"] - _pz()
	var l := _h(dx, dz)
	if l < 0.3:
		return "no_target"
	dx /= l
	dz /= l
	var goal := [_px() + dx * float(SB["dashM"]), _pz() + dz * float(SB["dashM"])]
	var to := _dash(goal[0], goal[1])
	_face(_px() + dx, _pz() + dz)
	var from := [_px(), _pz()]
	_dashing = {"fx": from[0], "fz": from[1], "tx": to[0], "tz": to[1], "start": _now, "dur": float(SB["durationS"]) * 1000.0}
	_send({"t": "signature", "by": self_id, "sig": "bash", "x": from[0], "z": from[1], "dx": dx, "dz": dz, "sp": _sp()})
	return "ok"


## Grave Slam: a nav-valid leap that resolves its slam on landing.
func _grave_slam(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["grave_slam"]
	var GS: Dictionary = DmCombatData.const_table("GRAVE_SLAM")
	var dx: float = t["x"] - _px()
	var dz: float = t["z"] - _pz()
	var l := _h(dx, dz)
	if l < 0.5:
		return "no_target"
	var reach := minf(float(GS["leapM"]), l)
	dx /= l
	dz /= l
	var goal := [_px() + dx * reach, _pz() + dz * reach]
	var to := _dash(goal[0], goal[1])
	if _h(to[0] - _px(), to[1] - _pz()) < 0.5:
		return "no_target"
	_face(to[0], to[1])
	var from := [_px(), _pz()]
	var dmg := _sp() * float(def["power"])
	_dashing = {"fx": from[0], "fz": from[1], "tx": to[0], "tz": to[1], "start": _now, "dur": float(GS["durationS"]) * 1000.0,
		"on_arrive": Callable(self, "_slam_landing").bind(to, dmg)}
	return "ok"


## The slam itself: everything within GRAVE_SLAM.slamR of where the Knight came down.
func _slam_landing(at: Array, dmg: float) -> void:
	var r := float(DmCombatData.const_table("GRAVE_SLAM")["slamR"])
	var ids: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if _gone(e):
			continue
		if _h(e.x - at[0], e.z - at[1]) > r + e.radius:
			continue
		ids.append(e.id)
		if ids.size() <= 10:
			_number(e.x, e.z, dmg, "hit")
		if ids.size() >= 64:
			break
	if not ids.is_empty():
		_send({"t": "hit", "by": self_id, "ids": ids, "dmg": dmg})
	var b := _boss()
	if b.active and _h(b.x - at[0], b.z - at[1]) <= r + DmSimConsts.BOSS_RADIUS:
		_send({"t": "hit", "by": self_id, "ids": [], "dmg": dmg, "boss": true})
		_number(b.x, b.z, dmg, "hit")


## Bulwark: raise the shield. Mitigation and the perfect-block window live in DmPlayerRules.
func _bulwark(now: float) -> String:
	var B: Dictionary = DmCombatData.const_table("BULWARK")
	p["bulwarkUntil"] = now + float(B["holdS"]) * 1000.0
	p["bulwarkPerfectUntil"] = now + float(B["perfectWindowS"]) * 1000.0
	return "ok"


## Corpse Vigil: the host spends the body (sig 'vigil'); the regen lands in on_vigil.
func _corpse_vigil(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["corpse_vigil"]
	var c := pick_corpse(t, float(def["radius"]), float(def["range"]))
	if c == null or (_area() != "" and c.area != _area()):
		return "no_corpse"
	_face(c.x, c.z)
	_send({"t": "signature", "by": self_id, "sig": "vigil", "x": c.x, "z": c.z, "dx": 0, "dz": 0, "sp": _sp()})
	return "ok"


## Grave Brand: the host spends the body and owns the trap (sig 'brand').
func _grave_brand(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["grave_brand"]
	var c := pick_corpse(t, float(def["radius"]), float(def["range"]))
	if c == null or (_area() != "" and c.area != _area()):
		return "no_corpse"
	_face(c.x, c.z)
	_send({"t": "signature", "by": self_id, "sig": "brand", "x": c.x, "z": c.z, "dx": 0, "dz": 0, "sp": _sp()})
	return "ok"


## Oath Unbroken: the death floor, the damage bonus and the Rage refill are all local.
func _oath_unbroken(now: float) -> String:
	p["unbreakableUntil"] = now + float(DmCombatData.const_table("OATH_UNBROKEN")["durationS"]) * 1000.0
	p["resource"]["value"] = p["resource"]["max"]
	return "ok"


## The host spent a body on Corpse Vigil. Only the caster regenerates.
func on_vigil(ev: Dictionary, mine: bool) -> void:
	if ev.get("ok", true) == false:
		return
	if not mine or not p["alive"]:
		return
	_vigil_until = _now + float(DmCombatData.const_table("CORPSE_VIGIL")["durationS"]) * 1000.0


## Discipline signature rites: aim + spell power to the host.
func _signature(id: String, t: Dictionary) -> String:
	var sig: String = DmCombatData.const_table("SIGNATURE_KIND")[id]
	if DmAbilities.rite_level(float(p["stats"]["level"]), dev) < float(DmCombatData.const_table("SIGNATURE_LEVEL")):
		return "locked"
	if sig == "rend" and thrall_count() == 0:
		return "no_thralls"
	var def: Dictionary = DmSimData.ABILITIES[id]
	var x: float = t["x"]
	var z: float = t["z"]
	var d := _h(x - _px(), z - _pz())
	if float(def["range"]) > 0.0 and d > float(def["range"]):
		x = _px() + ((x - _px()) / d) * float(def["range"])
		z = _pz() + ((z - _pz()) / d) * float(def["range"])
	if sig == "dirge":
		x = _px()
		z = _pz()
	else:
		_face(x, z)
	_send({"t": "signature", "by": self_id, "sig": sig, "x": x, "z": z, "dx": x - _px(), "dz": z - _pz(), "sp": _sp()})
	return "ok"


func _litany(mult: float = 1.0) -> String:
	var def: Dictionary = DmSimData.ABILITIES["black_litany"]
	var rn := rune("black_litany")
	var RT: Dictionary = DmSimData.RUNE_TUNING
	var intent := {
		"t": "litany", "by": self_id, "x": _px(), "z": _pz(),
		"r": float(def["radius"]) * mult * (float(RT["requiem"]["radiusMult"]) if rn == "rune_requiem" else 1.0),
		"spellPower": _sp() * (float(RT["hollowChoir"]["powerMult"]) if rn == "rune_hollow_choir" else 1.0),
		"leaveCorpses": mods["sacrificeLeavesCorpse"],
	}
	if rn == "rune_hollow_choir":
		intent["spare"] = true
	if rn == "rune_requiem":
		intent["delayMs"] = RT["requiem"]["delayMs"]
	_send(intent)
	return "ok"


## Corpse Explosion: name the corpse; the host owns radius and modifiers.
func _detonate(t: Dictionary) -> String:
	var def: Dictionary = DmSimData.ABILITIES["corpse_explosion"]
	var c := pick_corpse(t, float(DmSimData.ABILITIES["exhume"]["radius"]), float(def["range"]))
	if c == null:
		return "no_corpse"
	_face(c.x, c.z)
	_send({"t": "detonate", "by": self_id, "corpseId": c.id, "dmg": _sp() * float(def["power"])})
	return "ok"


func on_detonated(ev: Dictionary, mine: bool) -> void:
	if mine and ev["ok"]:
		on_corpse_consumed()
	if not ev["ok"]:
		return
	if mine and ev.get("targets") != null and DmCombatData.truthy(ev.get("dmg")) and DmCombatData.truthy(ev.get("targets")):
		_number(float(ev["x"]), float(ev["z"]), float(ev["dmg"]), "crit" if ev.get("elite", false) else "hit")


## What the host's litany answer does to the caster: barrier and healing (only the caster's).
func on_litany(ev: Dictionary, mine: bool) -> void:
	if not mine:
		return
	var consumed := int(ev["corpses"]) + int(ev["resonant"]) + int(ev["thralls"])
	if int(ev["corpses"]) + int(ev["resonant"]) > 0:
		on_corpse_consumed()
	var max_hp := float(p["stats"]["maxHp"])
	if DmCombatData.truthy(mods.get("litanyBarrier")):
		var barrier := max_hp * float(mods["litanyBarrier"]) * consumed
		p["barrier"] = float(p["barrier"]) + barrier
		if barrier > 0.0:
			p["barrierPeak"] = maxf(float(p["barrierPeak"]), float(p["barrier"]))
		if barrier >= 1.0:
			notes.append({"text": "+%d barrier" % DmMath.js_round(barrier), "kind": "ward"})
	if DmCombatData.truthy(mods.get("corpseHeal")):
		var healed := max_hp * float(mods["corpseHeal"]) * (int(ev["corpses"]) + int(ev["resonant"])) * 0.5
		_heal(healed)
		if healed >= 1.0:
			notes.append({"text": "+%d" % DmMath.js_round(healed), "kind": "heal"})


# --- New Blood families (NewBloodSystem.ts) ---------------------------------------------------------------------------------------------------

func _nb_power() -> float:
	return DmAbilities.new_blood_power(p, _now)


func _nb_gesture(t: Dictionary) -> void:
	if _h(float(t["x"]) - _px(), float(t["z"]) - _pz()) > 0.1:
		_face(t["x"], t["z"])


func _nb_target(t: Dictionary, reach: float) -> DmSimEnemy:
	var e: DmSimEnemy = null
	if not t.has("enemyId"):
		for v: DmSimEnemy in sim.enemies.values():
			if v.state != "dead" and _h(v.x - float(t["x"]), v.z - float(t["z"])) <= v.radius + 0.8:
				e = v
				break
	else:
		e = sim.enemies.get(int(t["enemyId"]))
	return e if (e != null and e.state != "dead" and _h(e.x - _px(), e.z - _pz()) <= reach + e.radius) else null


func _nb_corpse(t: Dictionary, reach: float, echo: bool = false) -> DmSimCorpse:
	var best: DmSimCorpse = null
	var dist := INF
	var area := _area()
	for c: DmSimCorpse in sim.corpses.values():
		if area != "" and c.area != area:
			continue
		if echo and c.echoOwner != "*" and c.echoOwner != self_id:
			continue
		if not echo and c.echoOwner != "":
			continue
		var d := _h(c.x - float(t["x"]), c.z - float(t["z"]))
		if d <= 1.25 and d < dist and _h(c.x - _px(), c.z - _pz()) <= reach:
			best = c
			dist = d
	return best


func _nb_send_sig(sig: String, x: float, z: float, sp: float, dur: Variant = null) -> void:
	var intent := {"t": "signature", "by": self_id, "sig": sig, "x": x, "z": z, "dx": x - _px(), "dz": z - _pz(), "sp": sp}
	if dur != null:
		intent["dur"] = dur
	_send(intent)


func _nb_host(id: String, sig: String, t: Dictionary, at: Variant = null, power: Variant = null, dur: Variant = null) -> String:
	var a: Dictionary = at if at != null else t
	_nb_send_sig(sig, a["x"], a["z"], float(power) if power != null else _nb_power(), dur)
	_nb_gesture(a)
	return "ok"


func _nb_send_hits(ids: Array, damage: float, extra: Dictionary = {}, boss: bool = false) -> void:
	if not ids.is_empty() or boss:
		var h := {"t": "hit", "by": self_id, "ids": ids, "dmg": damage}
		h.merge(extra)
		if boss:
			h["boss"] = true
		_send(h)


func _nb_arc(t: Dictionary, reach: float, half_angle: float, damage: float) -> int:
	var dx: float = float(t["x"]) - _px()
	var dz: float = float(t["z"]) - _pz()
	var ln := _h(dx, dz)
	if ln == 0.0:
		ln = 1.0
	var ids: Array = []
	var cos_h := DmFdlibm.cos_(half_angle * PI / 180.0)
	for e: DmSimEnemy in sim.enemies.values():
		if e.state == "dead":
			continue
		var ex := e.x - _px()
		var ez := e.z - _pz()
		var d := _h(ex, ez)
		if d > reach + e.radius or (ex * dx + ez * dz) / (maxf(d, 0.01) * ln) < cos_h:
			continue
		ids.append(e.id)
		if ids.size() >= 64:
			break
	_nb_send_hits(ids, damage)
	return ids.size()


## Returns null for abilities owned by the necromancer kit above.
func _nb_cast(id: String, t: Dictionary, now: float) -> Variant:
	var def: Dictionary = DmSimData.ABILITIES[id]
	var reach := float(def["range"])
	match id:
		"flail_swing":
			_nb_gesture(t)
			_nb_arc(t, 3.0, 70.0, _nb_power() * float(def["power"]))
			return "ok"
		"lantern_cone":
			var dx: float = float(t["x"]) - _px()
			var dz: float = float(t["z"]) - _pz()
			var l := _h(dx, dz)
			if l == 0.0:
				l = 1.0
			var ids: Array = []
			var cos_c := DmFdlibm.cos_(PI / 5.0)
			for e: DmSimEnemy in sim.enemies.values():
				if e.state != "dead" and _h(e.x - _px(), e.z - _pz()) <= 7.0 + e.radius \
						and ((e.x - _px()) * dx + (e.z - _pz()) * dz) / (maxf(0.01, _h(e.x - _px(), e.z - _pz())) * l) >= cos_c:
					ids.append(e.id)
			ids = ids.slice(0, 64)
			_nb_send_hits(ids, _nb_power() * float(def["power"]))
			return _nb_host(id, "lantern_cone", t, {"x": _px() + dx / l * 7.0, "z": _pz() + dz / l * 7.0})
		"chain_pull", "hook_pull":
			var e := _nb_target(t, reach)
			if e == null:
				return "no_target"
			return _nb_host(id, id, t, {"x": e.x, "z": e.z})
		"burn_the_dead":
			if _h(float(t["x"]) - _px(), float(t["z"]) - _pz()) > reach:
				return "range"
			var any := false
			for c: DmSimCorpse in sim.corpses.values():
				if c.echoOwner == "" and c.area == _area() and _h(c.x - float(t["x"]), c.z - float(t["z"])) <= 4.0:
					any = true
					break
			if not any:
				return "no_corpse"
			return _nb_host(id, id, t)
		"watchmans_ward", "crow_swarm", "veil_tear":
			if _h(float(t["x"]) - _px(), float(t["z"]) - _pz()) > reach:
				return "range"
			return _nb_host(id, id, t)
		"cremate", "harvest", "sound_the_corpse", "butcher", "lay_to_rest":
			var c := _nb_corpse(t, reach)
			if c == null:
				return "no_corpse"
			return _nb_host(id, id, t, {"x": c.x, "z": c.z})
		"last_light", "toll", "great_toll":
			var spend := 0.0
			if id == "toll" and _essence() >= 25.0:
				spend = 25.0
			elif id == "great_toll":
				spend = _essence()
			DmPlayerRules.add_resource(p, -spend)
			return _nb_host(id, id, t, {"x": _px(), "z": _pz()}, _nb_power() * (1.0 + spend / 100.0), 0.6 if (id == "toll" and spend != 0.0) else null)
		"palm_strike":
			var e := _nb_target(t, reach)
			if e == null and not t.get("boss", false):
				return "no_target"
			var phase := fmod(fmod(now, 1200.0) + 1200.0, 1200.0)
			var beat := phase <= 150.0 or phase >= 1050.0
			var damage := _nb_power() * float(def["power"]) * (1.4 if beat else 1.0)
			_nb_send_hits([e.id] if e != null else [], damage, {}, bool(t.get("boss", false)))
			DmPlayerRules.add_resource(p, 12.0 if beat else 8.0)
			_nb_gesture(t)
			return "ok"
		"resonant_step":
			var dx: float = float(t["x"]) - _px()
			var dz: float = float(t["z"]) - _pz()
			var d := _h(dx, dz)
			if d < 0.3:
				return "no_target"
			dx /= d
			dz /= d
			var to := _dash(_px() + dx * 5.0, _pz() + dz * 5.0)
			if _h(to[0] - _px(), to[1] - _pz()) < 0.3:
				return "no_target"
			_nb_send_sig(id, to[0], to[1], _nb_power())
			_teleport(to[0], to[1])
			_nb_gesture(t)
			return "ok"
		"knell", "hex_charm":
			var e := _nb_target(t, reach)
			if e == null:
				return "no_target"
			return _nb_host(id, id, t, {"x": e.x, "z": e.z})
		"choir_of_one":
			_choir_until = now + 6000.0
			_next_choir_beat = now + 1200.0
			_nb_gesture(t)
			return "ok"
		"hook_throw":
			var e := _nb_target(t, reach)
			if e == null and not t.get("boss", false):
				return "no_target"
			_nb_send_hits([e.id] if e != null else [], _nb_power() * float(def["power"]), {"bleed": _nb_power() * 0.14}, bool(t.get("boss", false)))
			_nb_gesture(t)
			return "ok"
		"murder_of_crows":
			if _h(float(t["x"]) - _px(), float(t["z"]) - _pz()) > reach:
				return "range"
			_murder_until = now + 8000.0
			_next_murder_tick = now
			return _nb_host(id, id, t)
		"spirit_bolt":
			var e := _nb_target(t, reach)
			if e == null and not t.get("boss", false):
				return "no_target"
			_nb_send_hits([e.id] if e != null else [], _nb_power() * float(def["power"]), {}, bool(t.get("boss", false)))
			_nb_gesture(t)
			return "ok"
		"veil_form":
			if not p["veilForm"] and float(p["resource"]["value"]) <= 0.0:
				return "essence"
			p["veilForm"] = not p["veilForm"]
			_nb_gesture(t)
			return "ok"
		"echo", "crossing":
			var c := _nb_corpse(t, reach, true)
			if c == null:
				return "no_corpse"
			return _nb_host(id, id, t, {"x": c.x, "z": c.z})
		"between_worlds":
			p["betweenUntil"] = now + 5000.0
			_nb_gesture(t)
			return "ok"
	return null


func _nb_update(now: float) -> void:
	if not p["alive"]:
		_choir_until = 0.0
		_crows_until = 0.0
		_murder_until = 0.0
		return
	if now < _choir_until and now >= _next_choir_beat:
		_next_choir_beat += 1200.0
		_nb_send_sig("toll", _px(), _pz(), _nb_power() * 0.5)
	if now < _crows_until and now >= _next_crow_peck:
		_next_crow_peck = now + 500.0
		var found: DmSimEnemy = null
		for v: DmSimEnemy in sim.enemies.values():
			if v.state != "dead" and _h(v.x - _px(), v.z - _pz()) <= 3.0:
				found = v
				break
		if found != null:
			_nb_send_hits([found.id], _nb_power() * 0.35)
	if now < _murder_until and now >= _next_murder_tick:
		_next_murder_tick = now + 500.0
		var at_x := _px()
		var at_z := _pz()
		if aim != null:
			at_x = float(aim["x"])
			at_z = float(aim["z"])
		_nb_send_sig("murder_of_crows", at_x, at_z, _nb_power())


func _nb_on_event(ev: Dictionary, mine: bool) -> void:
	if not ev["ok"] or not mine:
		return
	var kind: String = ev["kind"]
	if kind == "burn_the_dead" or kind == "cremate" or kind == "harvest":
		DmPlayerRules.add_resource(p, float(ev["amount"]) if ev.get("amount") != null else 0.0)
	if kind == "harvest":
		_crows_until = _now + 6000.0
		_next_crow_peck = _now
	if kind == "crossing" and ev.get("tx") != null and ev.get("tz") != null:
		_teleport(float(ev["tx"]), float(ev["tz"]))
	if kind == "lay_to_rest":
		_heal(float(p["stats"]["maxHp"]) * 0.06)


# --- The host's answers, as WorldScene.handleEvent routes them to the caster ---------------------------------------------------------------------

## Apply one sim event the way the scene does for the player that owns this caster. Corpse Vigil's answer is deliberately NOT routed: the web
## scene never calls AbilitySystem.onVigil (so the vigil's regeneration never starts there); set `route_vigil` to wire it.
var route_vigil: bool = false


func handle_event(ev: Dictionary) -> void:
	var me := self_id
	match ev["t"]:
		"mantle":
			on_mantle(ev, ev["by"] == me)
		"offering":
			on_offering(ev, ev["by"] == me)
		"newBlood":
			if ev["kind"] == "heal" and ev.get("player") == me and DmCombatData.truthy(ev.get("amount")):
				_heal(float(p["stats"]["maxHp"]) * float(ev["amount"]))
			_nb_on_event(ev, ev["by"] == me)
		"exhumed":
			if ev["by"] == me:
				if not ev["ok"]:
					_set_essence(minf(_max_essence(), _essence() + float(DmSimData.ABILITIES["exhume"]["essenceCost"])))
					p["cooldowns"].erase("exhume")
				else:
					on_corpse_consumed()
					if DmCombatData.truthy(mods.get("corpseHeal")):
						_heal(float(p["stats"]["maxHp"]) * float(mods["corpseHeal"]))
		"litanyResult":
			on_litany(ev, ev["by"] == me)
		"detonated":
			if ev["ok"]:
				on_detonated(ev, ev["by"] == me)
			elif ev["by"] == me:
				_set_essence(minf(_max_essence(), _essence() + float(DmSimData.ABILITIES["corpse_explosion"]["essenceCost"])))
				p["cooldowns"].erase("corpse_explosion")
		"heal":
			if ev["player"] == me and p["alive"]:
				var amount: float = float(p["stats"]["maxHp"]) * float(ev["frac"]) if DmCombatData.truthy(ev.get("frac")) else float(ev["amount"])
				_heal(amount)
		"vigil":
			if route_vigil:
				on_vigil(ev, ev["by"] == me)
		"death":
			if ev["killer"] == me and p["alive"]:
				DmPlayerRules.add_souls(p, 1.0 + reaped_souls(int(ev["id"])))
