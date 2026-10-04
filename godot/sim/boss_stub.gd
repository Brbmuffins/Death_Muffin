class_name DmBossStub
extends DmBossController
## Placeholder boss controller used until the bosses track lands res://sim/bosses/boss_factory.gd. It implements the shared BossBrain
## machinery (awaken, damage + Fracture + Withered, phases at 60% / 30%, defeat, wipe reset, stagger clock) and NONE of the attacks:
## no telegraphs, no adds, no movement. Good enough for the sim's own tests (a boss that can be summoned, hit and killed).

var _stagger_t: float = 0.0
var _last_hit_by: String = ""


func awaken(by: String, empowered: bool = false) -> void:
	if state.active:
		return
	var def: Dictionary = DmContent.boss(id)
	var s := state
	var party := maxf(1.0, float(sim.players.size()))
	s.active = true
	s.empowered = empowered
	s.level = sim.area_level(String(def["area"]))
	if empowered:
		s.level = DmMath.js_round_f(s.level + float(DmContent.get_export("gameplay_goldSinkRules", "EMPOWER")["levelsFlat"]) + s.level * float(DmContent.get_export("gameplay_goldSinkRules", "EMPOWER")["levelsShare"]))
	var emp_hp := float(DmContent.get_export("gameplay_goldSinkRules", "EMPOWER")["hpMult"]) if empowered else 1.0
	s.maxHp = float(def["baseHp"]) * DmEnemyStats.hp_scale(s.level) * emp_hp * (1.0 + 0.8 * (party - 1.0)) * float(DmContent.difficulty(sim.difficulty)["enemyHpMult"])
	s.hp = s.maxHp
	s.phase = 1
	s.state = "idle"
	s.stateT = 0.0
	s.x = float(def["arena"]["x"])
	s.z = float(def["arena"]["z"])
	s.facing = 0.0
	s.flash = 0.0
	s.fracture = 0.0
	s.fractureT = 0.0
	s.withered = 0.0
	s.witheredT = 0.0
	s.witheredDps = 0.0
	_stagger_t = 0.0
	_last_hit_by = by
	var ev := {"t": "boss", "kind": "awaken", "x": s.x, "z": s.z, "phase": 1, "boss": id}
	if empowered:
		ev["empowered"] = true
	sim.emit(ev)


func damage(amount: float, by: String, fracture: float) -> void:
	var s := state
	if not s.active or s.hp <= 0.0:
		return
	var F: Dictionary = DmCombatData.const_table("FRACTURE")
	s.hp -= amount * (1.0 + float(F["perStack"]) * s.fracture)
	s.flash = 1.0
	_last_hit_by = by
	if fracture != 0.0:
		s.fracture = minf(float(F["maxStacks"]), s.fracture + fracture)
		s.fractureT = float(F["durationMs"]) / 1000.0


func stagger(seconds: float) -> void:
	if not state.active or state.hp <= 0.0:
		return
	_stagger_t = maxf(_stagger_t, seconds)
	state.flash = 1.0


func update(dt: float) -> void:
	var s := state
	if not s.active:
		return
	s.flash = maxf(0.0, s.flash - dt * 4.0)
	if s.fractureT > 0.0:
		s.fractureT -= dt
		if s.fractureT <= 0.0:
			s.fracture = 0.0
	if s.witheredT > 0.0 and s.withered > 0.0:
		s.witheredT -= dt
		if s.state != "sunk":
			s.hp -= s.withered * s.witheredDps * dt
		if s.witheredT <= 0.0:
			s.withered = 0.0
	if s.hp <= 0.0:
		s.active = false
		s.state = "dead"
		var ev := {"t": "boss", "kind": "defeated", "x": s.x, "z": s.z, "phase": s.phase, "killer": _last_hit_by, "boss": id}
		if s.empowered:
			ev["empowered"] = true
		sim.emit(ev)
		return
	var ratio := s.hp / s.maxHp
	if s.phase == 1 and ratio <= 0.6:
		_set_phase(2)
	elif s.phase == 2 and ratio <= 0.3:
		_set_phase(3)
	var area := String(DmContent.boss(id)["area"])
	var any := false
	for p in sim.players.values():
		if p.alive and p.area == area:
			any = true
			break
	if not any:
		s.active = false
		s.state = "idle"
		sim.emit({"t": "boss", "kind": "defeated", "x": s.x, "z": s.z, "phase": s.phase, "killer": "", "boss": id})
		return
	var d := dt
	if _stagger_t > 0.0:
		var paused := minf(d, _stagger_t)
		_stagger_t -= paused
		d -= paused
		if d <= 0.0:
			return
	s.stateT += d


func _set_phase(p: int) -> void:
	state.phase = p
	sim.emit({"t": "boss", "kind": "phase", "x": state.x, "z": state.z, "phase": p, "boss": id})
