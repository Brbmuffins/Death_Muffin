class_name DmPrelateBrain
extends "res://sim/bosses/boss_brain.gd"
## The Bell-Sworn Prelate: Toll (ring), Slam, Bell Rain (P2+), Procession (adds on phase change). Port of PrelateBrain.

var _toll_cd := 4.0
var _slam_cd := 2.0
var _rain_cd := 6.0
## Prelate Echoes III: when the chasing volley is aimed (0 = none pending).
var _chase_at := 0.0


func _init(world_: RefCounted) -> void:
	super(world_, "prelate")


func _tick(_dt: float, players: Array) -> void:
	if _chase_at != 0.0 and world.now() >= _chase_at:
		_chase_at = 0.0
		if not players.is_empty():
			var t: Array = []
			for p in players:
				t.append([p["x"], p["z"]])
			_telegraph("rain", state["x"], state["z"], 2.3, 1100.0, {"targets": t, "side": true})


func _on_awaken() -> void:
	state["z"] = _az() - 4.0
	_toll_cd = 3.5
	_slam_cd = 2.0
	_rain_cd = 7.0
	_chase_at = 0.0


func _circle_damage(kind: String) -> float:
	return 24.0 if kind == "toll" else (20.0 if kind == "slam" else 18.0)


func _on_phase(p: int) -> void:
	# Procession: penitents file in from the side aisles.
	var spawns := [[-11.0, -110.0], [11.0, -110.0], [-11.0, -123.0], [11.0, -123.0]]
	# Prelate Echoes II: the procession is longer and its first two walkers are elite.
	var echoes: int = world.echoes()
	var count := (4 if p == 2 else 6) + (2 if echoes >= 2 else 0)
	for i in count:
		var sp: Array = spawns[i % spawns.size()]
		_spawn_add("penitent" if i % 2 == 1 else "risen", sp[0] + (1.5 if i > 3 else 0.0), sp[1], echoes >= 2 and i < 2)
	emit_boss("summon", state["x"], state["z"], {"phase": p, "targets": spawns})


func _think(dt: float, players: Array) -> void:
	var s := state
	var ph: int = s["phase"]
	var fast := 0.62 if ph == 3 else (0.82 if ph == 2 else 1.0)
	_toll_cd -= dt
	_slam_cd -= dt
	_rain_cd -= dt
	var nn := _nearest(players)
	var nearest: Dictionary = nn["nearest"]
	var nd: float = nn["nd"]
	var busy := _busy()
	if not busy:
		if _toll_cd <= 0.0:
			_toll_cd = 9.0 * fast
			var ms := 1500.0 * (0.8 if ph == 3 else 1.0)
			_telegraph("toll", s["x"], s["z"], 6.5, ms)
			# Prelate Echoes I, the second bell: a smaller toll answers on whoever stands farthest from the first, a moment later.
			if world.echoes() >= 1 and not players.is_empty():
				var far: Dictionary = players[0]
				for b in players:
					if Geom.hyp(b["x"] - float(s["x"]), b["z"] - float(s["z"])) > Geom.hyp(far["x"] - float(s["x"]), far["z"] - float(s["z"])):
						far = b
				_telegraph("toll", far["x"], far["z"], 3.6, 1300.0, {"side": true}, ms + 600.0)
		elif _rain_cd <= 0.0 and ph >= 2:
			_rain_cd = 8.0 * fast
			var targets: Array = []
			for p in players:
				targets.append([p["x"], p["z"]])
			var extra := 4 if ph == 3 else 2
			for i in extra:
				var a: float = world.rand() * PI * 2.0
				var r: float = 3.0 + world.rand() * (_ar() - 4.0)
				targets.append([_ax() + cos(a) * r, _az() + sin(a) * r])
			_telegraph("rain", s["x"], s["z"], 2.3, 1400.0, {"targets": targets})
			# Prelate Echoes III, chasing rain: a second volley is aimed at wherever each player has run to a moment later (see _tick).
			if world.echoes() >= 3:
				_chase_at = world.now() + 1.6
		elif _slam_cd <= 0.0 and nd < 4.5:
			_slam_cd = 3.2 * fast
			var dir_x: float = (nearest["x"] - float(s["x"])) / (nd if nd != 0.0 else 1.0)
			var dir_z: float = (nearest["z"] - float(s["z"])) / (nd if nd != 0.0 else 1.0)
			_telegraph("slam", float(s["x"]) + dir_x * 2.6, float(s["z"]) + dir_z * 2.6, 2.6, 900.0 * (0.8 if ph == 3 else 1.0))
	var speed := (2.6 if ph == 3 else (2.0 if ph == 2 else 1.6)) * (0.25 if busy else 1.0)
	# `busy` from before this tick's attack choice, exactly as the single-boss build did.
	_chase(nearest, nd, speed, dt, 2.0, 3.0, 1 if busy else 0)
