class_name DmNextAutoCombat
extends RefCounted
## Easy auto-combat on the rebuild: the shared decision code (DmAutoCombat.select_action / select_movement, DmAutoDodge, DmBossTelegraphs in game/)
## fed by a small adapter over the combat core's bulk arrays: no node per enemy exists, so the enemies are read from `DmCore.enemy_ids / enemy_positions /
## enemy_states` (one native copy each, in spawn order), the corpses from `corpse_ids / corpse_positions`, and what those arrays do not carry (radius, elite, health, a swing's
## wind-up, a corpse's kind) from small tables kept by the core host's signals (`_facts`, `_corpse_facts`, `_zones`): each is written by an event, never read back from the core per creature.
## Local owner only; its output is the same intents as the keyboard: `DmNextInput.cast_at` (the hotbar seam -> request_cast) and `request_move_dir`.
##
## Rules:
##   gate      settings_store.can_use_auto_combat() (the character's `auto_combat_allowed`) AND settings["auto_combat"] (Easy only, the store enforces it); the rebuilt client has no
##             settings store yet, so the gate is closed unless `gate_probe` says otherwise (the benchmark, tests)
##   yields    to a walk (click / WASD / held key), a click target, a queued cast, an open panel, gathering, a dead hero (and a family other than the
##             necromancers and the Reaper: those rules are not in the rebuild)
##   action    every ACT_MS: one `select_action` (rite rotation, corpse rites, target priority) and one cast; a Healing flask under 42 % hp
##   movement  every MOVE_MS: `select_movement` (leave telegraphs / hostile pools first, close to the primary's range, back off a pack), sent as a
##             direction intent (re-sent every RESEND_MS, one ZERO when it stops); 2 %/s regen for 5 s after a hit (the old game loop's Easy sustain)
## Cost: one compare per physics frame; a decision reuses its enemy / corpse / hazard dictionaries (no per-enemy allocation): every 100 ms the tables are read (0.3 ms for 62 enemies and
## 31 corpses on the VPS) and every 180 ms DmAutoCombat chooses (0.6 ms); a hero that holds his ground reads them only when an action is due.

const ACT_MS := 180.0
const MOVE_MS := 100.0
const RESEND_MS := 150.0
const RANGE_M := 40.0                ## enemies farther than this cannot matter (select_movement stops at 36)
const ENEMY_CAP := 200
const REGEN_MS := 5000.0
const FLASK_FRAC := 0.42
const ZONE_PAD := 0.45               ## DmHostileZone.TARGET_PAD: a hero's radius added to a pool's
const CORPSE_CAP := 256              ## DmAutoCombat inspects at most this many corpses
## The slots of an enemy's record in `_facts` (an Array per enemy, written by the core host's signals; the bulk arrays carry only place and state).
const F_RADIUS := 0
const F_ELITE := 1
const F_MAX_HP := 2
const F_HP := 3
const F_WINDUP_UNTIL := 4            ## ms (clock_ms): the swing in progress is in its wind-up until then
const F_AREA := 5

## The clock the decisions and the wind-ups run on: milliseconds of physics ticks. At real time it is the wall clock (60 ticks a second); run faster than real time
## (`--fixed-fps`, the headless processor test) the fight keeps its cadence, which a wall clock would stretch.
static func clock_ms() -> float:
	return float(Engine.get_physics_frames()) * 1000.0 / float(Engine.physics_ticks_per_second)


var game: Node                                   ## DmNextGame
var input: DmNextInput
var gate_probe := Callable()                     ## () -> bool, tests swap it; default = the settings gate above
var telegraphs := DmBossTelegraphs.new()
var mem: Dictionary = {}                         ## AutoMoveMemory
var aim_active := false                          ## auto has a target: the standing mouse-aim leaves the hero alone
var stats := {"ticks": 0, "actions": 0, "casts": 0, "moves": 0, "yields": 0, "flasks": 0, "fills": 0}   ## (fills: the times the core's tables were read for a decision)
var last_action: Variant = null                  ## the last select_action result (tests)
var hold_position := false                       ## cast but never walk (the in-game benchmark keeps the hero at the room's centre)

var _next_move := 0.0
var _next_act := 0.0
var _last_ms := 0.0
var _resend := 0.0
var _dir_on := false
var _dir := Vector3.ZERO
var _wired := false
var _pool: Array = []                            ## reused enemy dictionaries
var _enemies: Array = []
var _corpse_pool: Array = []                     ## reused corpse dictionaries
var _corpses: Array = []
var _hazards: Array = []
var _facts := {}                                 ## enemy id -> [radius, elite, max hp, hp, wind-up end, area] (see F_*): kept by spawn, damaged, attack and removed
var _corpse_facts := {}                          ## corpse id -> [kind, area]
var _zones := {}                                 ## zone id -> [x, z, radius]: the hostile ground (dust clouds, toxic pools) while it lasts
var _core_wired := false
var _boss := {"active": false, "hp": 0.0, "state": "idle", "x": 0.0, "z": 0.0}
var _ctx := {"player": {}, "enemies": null, "corpses": null, "boss": null, "thrallCount": 0, "thrallCap": 0, "ready": Callable(), "primary": "", "primaryRange": 0.0,
	"selfId": "", "family": "necromancer", "signature": "", "now": 0.0, "nav": null, "hazards": null}
var _slots: Array = ["", "", "", "", "", "", ""]
var _boss_id := 0


func setup(game_: Node, input_: DmNextInput) -> void:
	game = game_
	input = input_


func _wire() -> void:
	var host := game.get("core_host") as DmCoreHost
	if host != null and not _core_wired:
		_core_wired = true
		host.enemy_spawned.connect(_on_spawned)
		host.enemy_damaged.connect(_on_damaged)
		host.enemy_attack.connect(_on_attack)
		host.enemy_removed.connect(_on_removed)
		host.corpse_added.connect(_on_corpse_added)
		host.corpse_gone.connect(_on_corpse_gone)
		host.zone.connect(_on_zone)
		host.zone_gone.connect(_on_zone_gone)
		for id in host.core.enemy_ids():   # bodies that were there before this adapter listened
			var info: Dictionary = host.core.enemy_info(id)
			if not info.is_empty():
				_facts[id] = [float(info["radius"]), bool(info["elite"]), float(info["max_hp"]), float(info["hp"]), 0.0, String(info["area"])]
		for cid in host.core.corpse_ids():
			var ci: Dictionary = host.core.corpse_info(cid)
			if not ci.is_empty():
				_corpse_facts[cid] = [String(ci["kind"]), String(ci["area"])]
	var bh: Variant = game.get("bosses")
	if bh != null and bh.fx != null and _core_wired:
		_wired = true
		bh.fx.played.connect(func(ev: Dictionary) -> void: telegraphs.on_event(ev, clock_ms()))


## The core's spawn event: the radius is not on it, so one query per body asks for it (never per tick).
func _on_spawned(id: int, _def: String, _level: int, elite: bool, area: String, _affixes: int, _x: float, _z: float, max_hp: float) -> void:
	var info: Dictionary = (game.core_host as DmCoreHost).core.enemy_info(id)
	_facts[id] = [float(info["radius"]) if not info.is_empty() else 0.5, elite, max_hp, max_hp, 0.0, area]


func _on_damaged(id: int, _source: int, _amount: float, hp: float) -> void:
	var f: Variant = _facts.get(id)
	if f != null:
		f[F_HP] = hp


func _on_attack(id: int, _blow: int, _aim_x: float, _aim_z: float, windup_s: float) -> void:
	var f: Variant = _facts.get(id)
	if f != null:
		f[F_WINDUP_UNTIL] = clock_ms() + windup_s * 1000.0


func _on_removed(id: int) -> void:
	_facts.erase(id)


func _on_corpse_added(id: int, kind: int, _def: String, _elite: bool, area: String, _x: float, _z: float, _facing: float, _scale: float) -> void:
	_corpse_facts[id] = [DmCoreEvents.CORPSE_KINDS[kind], area]


func _on_corpse_gone(id: int, _reason: String) -> void:
	_corpse_facts.erase(id)


func _on_zone(id: int, _kind: int, _source: int, x: float, z: float, radius: float, _seconds: float) -> void:
	_zones[id] = [x, z, radius]


func _on_zone_gone(id: int) -> void:
	_zones.erase(id)


func allowed() -> bool:
	if gate_probe.is_valid():
		return bool(gate_probe.call())
	var ui: Variant = game.get("ui_host")
	return ui != null and ui.settings_store.can_use_auto_combat() and bool(ui.settings["auto_combat"])


## One physics frame; `now` in ms (clock_ms()).
func tick(now: float) -> void:
	if now < _next_move:
		return
	_next_move = now + MOVE_MS
	stats["ticks"] += 1
	if not _wired:
		_wire()
	var dt := minf((now - _last_ms) / 1000.0, 0.5) if _last_ms > 0.0 else MOVE_MS / 1000.0
	_last_ms = now
	var b: DmHeroBody = game.local_body()
	if b == null or not b.alive or not allowed() or (b.family != "necromancer" and b.family != "reaper") or game.bosses == null:
		_release()
		return
	var c := b.get_node_or_null("Rites") as DmRiteCaster
	var combat := input.combat
	if c == null or b.has_target or combat.target_id != 0 or not combat.queued.is_empty() or not combat._held.is_empty() or input.held_direction() != Vector3.ZERO \
			or (game.ui != null and game.ui.panel_open()) or (game.gather != null and game.gather.loop != null and game.gather.loop.active):
		stats["yields"] += 1
		_release()
		return
	if not b.p.is_empty() and b.clock_ms() - float(b.p["lastHurtAt"]) < REGEN_MS:
		b.heal(b.max_hp * 0.02 * dt)
	var act_due := now >= _next_act
	if hold_position and not act_due:
		return   # a hero that holds his ground has nothing to decide between two actions: the tables are read when one is due
	var p := b.position
	stats["fills"] += 1
	var ctx := _fill(b, c, p, now)
	if act_due:
		_next_act = now + ACT_MS
		_act(b, c, ctx, p, now)
	if not hold_position:
		_move(ctx, dt, now)


## Drop the target and stop the walk this adapter started (the gate closed, or a deliberate input took over).
func _release() -> void:
	aim_active = false
	mem["dir"] = null
	if _dir_on:
		_dir_on = false
		_dir = Vector3.ZERO
		var held := input.held_direction() != Vector3.ZERO
		if not held and game != null and game.session.is_active():
			var b: DmHeroBody = game.local_body()
			if b == null or not b.has_target:
				game.session.request_move_dir(Vector3.ZERO)


## The core's tables as the plain records the decision code reads (reused dictionaries): the enemies and corpses by their bulk arrays, in spawn order.
func _gather(p: Vector3, _area: String) -> void:
	_enemies.clear()
	var host: DmCoreHost = game.core_host
	var core: RefCounted = host.core
	var ids: PackedInt32Array = core.enemy_ids()
	var pos: PackedFloat32Array = core.enemy_positions()   # x, z, yaw per body
	var states: PackedInt32Array = core.enemy_states()
	var n := 0
	var lim := RANGE_M * RANGE_M
	var now := clock_ms()
	for i in ids.size():
		if n >= ENEMY_CAP:
			break
		var sid := states[i]
		if sid == DmCoreEvents.State.DEAD or sid == DmCoreEvents.State.RISING or sid == DmCoreEvents.State.BURROW or sid == DmCoreEvents.State.ERUPT:
			continue   # (a burrowed or erupting body cannot be hurt: DmFoe.hittable)
		var ex := pos[i * 3]
		var ez := pos[i * 3 + 1]
		var dx := ex - p.x
		var dz := ez - p.z
		if dx * dx + dz * dz > lim:
			continue
		var f: Variant = _facts.get(ids[i])
		if f == null or float(f[F_HP]) <= 0.0:
			continue
		if n >= _pool.size():
			_pool.append({"id": 0, "x": 0.0, "z": 0.0, "hp": 0.0, "maxHp": 0.0, "state": "", "radius": 0.5, "elite": false, "area": "", "hexOwner": ""})
		var r: Dictionary = _pool[n]
		n += 1
		r["id"] = ids[i]
		r["x"] = ex
		r["z"] = ez
		r["hp"] = f[F_HP]
		r["maxHp"] = f[F_MAX_HP]
		r["radius"] = f[F_RADIUS]
		r["elite"] = f[F_ELITE]
		r["area"] = f[F_AREA]
		r["state"] = "windup" if (sid == DmCoreEvents.State.ATTACK and now < float(f[F_WINDUP_UNTIL])) else "chase"
		_enemies.append(r)
	_corpses.clear()
	var cids: PackedInt32Array = core.corpse_ids()
	var cpos: PackedFloat32Array = core.corpse_positions()   # x, z, facing, scale per corpse
	var field: DmCoreCorpses = host.corpses
	var cn := 0
	for i in cids.size():
		if cn >= CORPSE_CAP:
			break
		var cdx := cpos[i * 4] - p.x
		var cdz := cpos[i * 4 + 1] - p.z
		if cdx * cdx + cdz * cdz > lim:
			continue
		var cf: Variant = _corpse_facts.get(cids[i])
		if cf == null:
			continue
		if cn >= _corpse_pool.size():
			_corpse_pool.append({"x": 0.0, "z": 0.0, "kind": "normal", "seedOwner": "", "echoOwner": "", "area": ""})
		var c: Dictionary = _corpse_pool[cn]
		cn += 1
		c["x"] = cpos[i * 4]
		c["z"] = cpos[i * 4 + 1]
		c["kind"] = cf[0]
		c["area"] = cf[1]
		c["seedOwner"] = str(field.notes(cids[i]).get("seedOwner", "")) if field.has_notes(cids[i]) else ""
		_corpses.append(c)
	var boss: DmBoss = game.bosses.active_boss()
	_boss_id = 0
	if boss != null and boss.is_hittable() and boss.hp > 0.0:
		_boss["active"] = true
		_boss["hp"] = boss.hp
		_boss["x"] = boss.position.x
		_boss["z"] = boss.position.z
		_boss_id = boss.core_id
	else:
		_boss["active"] = false
	if not _boss["active"]:
		telegraphs.clear()
	_hazards.clear()
	_hazards.append_array(telegraphs.active(clock_ms()))
	for zid in _zones:
		var zn: Array = _zones[zid]
		if Vector2(zn[0] - p.x, zn[1] - p.z).length() < 40.0:
			_hazards.append(DmAutoDodge.pool_hazard({"x": zn[0], "z": zn[1], "r": zn[2]}, ZONE_PAD))


func _fill(b: DmHeroBody, c: DmRiteCaster, p: Vector3, now: float) -> Dictionary:
	for i in 7:
		_slots[i] = String(game.rite_for_slot(i))
	var primary: String = _slots[0]
	var loadout: Dictionary = c.p.get("loadout", DmWeaponLine.no_loadout()) if not c.p.is_empty() else DmWeaponLine.no_loadout()
	var thr := c.thralls()
	var area: String = game.area_of(game.session.get_my_id())
	_gather(p, area)
	var pl: Dictionary = _ctx["player"]
	pl["x"] = p.x
	pl["z"] = p.z
	pl["area"] = area
	pl["essence"] = c.essence()
	pl["maxEssence"] = b.resource_max
	pl["hp"] = b.hp
	pl["maxHp"] = b.max_hp
	pl["souls"] = int(c.p.get("souls", 0)) if not c.p.is_empty() else 0
	_ctx["family"] = b.family
	_ctx["enemies"] = _enemies
	_ctx["corpses"] = _corpses
	_ctx["boss"] = _boss
	_ctx["thrallCount"] = int(thr.places_used()) if thr != null else 0
	_ctx["thrallCap"] = _thrall_cap(b)
	_ctx["ready"] = func(id: String) -> bool: return _slots.has(id) and c.cooldown_left(id) <= 0.0
	_ctx["primary"] = primary
	_ctx["primaryRange"] = DmWeaponLine.ability_range(primary, float(DmAbilities.def(primary)["range"]), loadout) if primary != "" else 0.0
	_ctx["selfId"] = str(c.peer_id)
	_ctx["signature"] = _slots[6]
	_ctx["now"] = now
	_ctx["nav"] = null
	_ctx["hazards"] = _hazards
	return _ctx


func _thrall_cap(b: DmHeroBody) -> int:
	if not b.mods.is_empty():
		return int(b.mods.get("thrallCap", 0))
	return int(game.ui_host.build_cache()["discipline"]["mods"]["thrallCap"]) if game.ui_host != null else 0


func _act(b: DmHeroBody, c: DmRiteCaster, ctx: Dictionary, p: Vector3, now: float) -> void:
	stats["actions"] += 1
	if b.hp < b.max_hp * FLASK_FRAC and game.ui_host != null and game.session.is_host():
		_flask()
	var act: Variant = DmAutoCombat.select_action(ctx)
	last_action = act
	if act == null:
		aim_active = false
		return
	var t: Dictionary = act["target"]
	aim_active = t.has("enemyId") or t.has("boss")
	if t.has("enemyId"):
		mem["targetId"] = t["enemyId"]
	var slot := _slots.find(String(act["id"]))
	if slot < 0:
		return
	var eid := int(t["enemyId"]) if t.has("enemyId") else (_boss_id if t.has("boss") else 0)
	stats["casts"] += 1
	input.cast_at(slot, Vector3(float(t["x"]), 0.0, float(t["z"])), eid, false)
	if game.ui_host != null:
		game.ui_host.game_event.emit("auto_combat_cast", {})   # the counsel's one auto-combat tip


func _flask() -> void:
	var belt: Variant = game.belt()
	if belt == null or belt.inventory == null or belt.prog == null or bool(belt.prog.vow_fx().get("noFlasks", false)):
		return
	var inv: Variant = belt.inventory
	if inv.count("flask_hp_grand") > 0 or inv.count("flask_hp_major") > 0 or inv.count("flask_hp_minor") > 0:
		stats["flasks"] += 1
		belt.drink_flask()


func _move(ctx: Dictionary, dt: float, now: float) -> void:
	var d: Variant = DmAutoCombat.select_movement(ctx, mem, now, dt)
	if d == null:
		mem["dir"] = null
		if _dir_on:
			_dir_on = false
			_dir = Vector3.ZERO
			game.session.request_move_dir(Vector3.ZERO)
		return
	var v := Vector3(float(d["x"]), 0.0, float(d["z"]))
	if not _dir_on or v.distance_squared_to(_dir) > 0.0025 or now >= _resend:
		_resend = now + RESEND_MS
		stats["moves"] += 1
		game.session.request_move_dir(v)
	_dir = v
	_dir_on = true
