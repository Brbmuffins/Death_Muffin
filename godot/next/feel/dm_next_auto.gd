class_name DmNextAutoCombat
extends RefCounted
## Easy auto-combat on the rebuild: the current client's decision code (DmAutoCombat.select_action / select_movement, DmAutoDodge, DmBossTelegraphs,
## untouched) fed by a small adapter over the nodes world (DmEnemy, DmBoss, DmCorpseField, DmThrallHost, the caster) instead of the old sim.
## Local owner only; its output is the same intents as the keyboard: `DmNextInput.cast_at` (the hotbar seam -> request_cast) and `request_move_dir`.
##
## Rules, as the current client (DmGameInput.tick_combat / auto_movement):
##   gate      settings_store.can_use_auto_combat() (the character's `auto_combat_allowed`) AND settings["auto_combat"] (Easy only, the store enforces it)
##   yields    to a walk (click / WASD / held key), a click target, a queued cast, an open panel, gathering, a dead hero (and a non-necromancer: that
##             family's rules are not in the rebuild)
##   action    every ACT_MS: one `select_action` (rite rotation, corpse rites, target priority) and one cast; a Healing flask under 42 % hp
##   movement  every MOVE_MS: `select_movement` (leave telegraphs / hostile pools first, close to the primary's range, back off a pack), sent as a
##             direction intent (re-sent every RESEND_MS, one ZERO when it stops); 2 %/s regen for 5 s after a hit (the old game loop's Easy sustain)
## Cost: one compare per physics frame; a decision reuses its enemy / hazard dictionaries (no per-enemy allocation), so ~every 100 ms a few hundred us.

const ACT_MS := 180.0
const MOVE_MS := 100.0
const RESEND_MS := 150.0
const RANGE_M := 40.0                ## enemies farther than this cannot matter (select_movement stops at 36)
const ENEMY_CAP := 200
const REGEN_MS := 5000.0
const FLASK_FRAC := 0.42

var game: Node                                   ## DmNextGame
var input: DmNextInput
var gate_probe := Callable()                     ## () -> bool, tests swap it; default = the settings gate above
var telegraphs := DmBossTelegraphs.new()
var mem: Dictionary = {}                         ## AutoMoveMemory
var aim_active := false                          ## auto has a target: the standing mouse-aim leaves the hero alone
var stats := {"ticks": 0, "actions": 0, "casts": 0, "moves": 0, "yields": 0, "flasks": 0}
var last_action: Variant = null                  ## the last select_action result (tests)

var _next_move := 0.0
var _next_act := 0.0
var _last_ms := 0.0
var _resend := 0.0
var _dir_on := false
var _dir := Vector3.ZERO
var _wired := false
var _pool: Array = []                            ## reused enemy dictionaries
var _enemies: Array = []
var _corpses: Array = []
var _hazards: Array = []
var _boss := {"active": false, "hp": 0.0, "state": "idle", "x": 0.0, "z": 0.0}
var _ctx := {"player": {}, "enemies": null, "corpses": null, "boss": null, "thrallCount": 0, "thrallCap": 0, "ready": Callable(), "primary": "", "primaryRange": 0.0,
	"selfId": "", "family": "necromancer", "signature": "", "now": 0.0, "nav": null, "hazards": null}
var _slots: Array = ["", "", "", "", "", "", ""]
var _boss_id := 0


func setup(game_: Node, input_: DmNextInput) -> void:
	game = game_
	input = input_


func _wire() -> void:
	var bh: Variant = game.get("bosses")
	if bh != null and bh.fx != null:
		_wired = true
		bh.fx.played.connect(func(ev: Dictionary) -> void: telegraphs.on_event(ev, float(Time.get_ticks_msec())))


func allowed() -> bool:
	if gate_probe.is_valid():
		return bool(gate_probe.call())
	var ui: Variant = game.get("ui_host")
	return ui != null and ui.settings_store.can_use_auto_combat() and bool(ui.settings["auto_combat"])


## One physics frame; `now` in ms (Time.get_ticks_msec()).
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
	if b == null or not b.alive or not allowed() or b.family != "necromancer" or game.bosses == null:
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
	var p := b.position
	var ctx := _fill(b, c, p, now)
	if now >= _next_act:
		_next_act = now + ACT_MS
		_act(b, c, ctx, p, now)
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


## The nodes world as the plain records the decision code reads (reused dictionaries).
func _gather(p: Vector3, area: String) -> void:
	_enemies.clear()
	var n := 0
	var lim := RANGE_M * RANGE_M
	for e: DmEnemy in game.director.enemies.values():
		if n >= ENEMY_CAP:
			break
		if not is_instance_valid(e) or e.hp <= 0.0 or not e.is_hittable():
			continue
		var sid := e.sm.id()
		if sid == DmEnemyState.Id.DEAD or sid == DmEnemyState.Id.RISING:
			continue
		var ep := e.position
		var dx := ep.x - p.x
		var dz := ep.z - p.z
		if dx * dx + dz * dz > lim:
			continue
		if n >= _pool.size():
			_pool.append({"id": 0, "x": 0.0, "z": 0.0, "hp": 0.0, "maxHp": 0.0, "state": "", "radius": 0.5, "elite": false, "area": "", "hexOwner": ""})
		var r: Dictionary = _pool[n]
		n += 1
		r["id"] = int(e.get_meta(&"dm_id", 0))
		r["x"] = ep.x
		r["z"] = ep.z
		r["hp"] = e.hp
		r["maxHp"] = e.max_hp
		r["radius"] = e.radius
		r["elite"] = e.elite
		r["area"] = e.get_meta(&"dm_area", area)   # an enemy that carries no area is where the hero is (the sim filtered by area, the nodes world is one scene)
		r["state"] = "windup" if (sid == DmEnemyState.Id.ATTACK and (e.sm.current as DmStateAttack).phase == DmStateAttack.Phase.WINDUP) else "chase"
		_enemies.append(r)
	_corpses.clear()
	for cp: DmSimCorpse in game.corpses.corpses.values():
		if cp.echoOwner == "" or cp.echoOwner == null:
			_corpses.append(cp)
	var boss: DmBoss = game.bosses.active_boss()
	_boss_id = 0
	if boss != null and boss.is_hittable() and boss.hp > 0.0:
		_boss["active"] = true
		_boss["hp"] = boss.hp
		_boss["x"] = boss.position.x
		_boss["z"] = boss.position.z
		_boss_id = int(boss.get_meta(&"dm_id", 0))
	else:
		_boss["active"] = false
	if not _boss["active"]:
		telegraphs.clear()
	_hazards.clear()
	_hazards.append_array(telegraphs.active(float(Time.get_ticks_msec())))
	for zn: Node in game.get_tree().get_nodes_in_group(&"dm_hostile_zone"):
		var hz := zn as DmHostileZone
		if hz != null and hz.dps > 0.0 and Vector2(hz.position.x - p.x, hz.position.z - p.z).length() < 40.0:
			_hazards.append(DmAutoDodge.pool_hazard({"x": hz.position.x, "z": hz.position.z, "r": hz.radius}, DmHostileZone.TARGET_PAD))


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


func _flask() -> void:
	var belt: Variant = game.progress.belt if game.progress != null else null
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
