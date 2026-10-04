class_name DmBossAdapter
extends "res://sim/boss_controller.gd"
## DmBossController (the sim's boss hook, godot/sim/BOSS_HOOK.md) backed by one of the pure brains in this folder. The brains keep
## their BossState as a Dictionary; this class copies it to/from the sim's DmBossState around every call, so the sim sees a normal
## controller with a live `state` and may also write `state` (host migration, tests) before the next call.
## Only loaded when res://sim/boss_controller.gd exists (the sim track), via boss_factory.gd.

const Brains := preload("res://sim/bosses/boss_brains.gd")
const SimWorld := preload("res://sim/bosses/sim_boss_world.gd")

const FIELDS := ["active", "x", "z", "facing", "hp", "maxHp", "phase", "state", "stateT", "flash", "fracture", "fractureT", "withered", "witheredT", "witheredDps", "level", "empowered"]

var brain


func setup(p_sim, p_id: String) -> void:
	super(p_sim, p_id)
	brain = Brains.make(SimWorld.new(p_sim), p_id)
	_pull()


## DmBossState -> brain dict
func _push() -> void:
	for k in FIELDS:
		brain.state[k] = state.get(k)
	brain.state["phase"] = int(state.phase)
	brain.state["fracture"] = int(state.fracture)
	brain.state["withered"] = int(state.withered)


## brain dict -> DmBossState
func _pull() -> void:
	for k in FIELDS:
		if brain.state.has(k):
			state.set(k, brain.state[k])


func awaken(by: String, empowered: bool = false) -> void:
	_push()
	brain.awaken(by, empowered)
	_pull()


func damage(amount: float, by: String, fracture: float) -> void:
	_push()
	brain.damage(amount, by, int(fracture))
	_pull()


func stagger(seconds: float) -> void:
	_push()
	brain.stagger(seconds)
	_pull()


func update(dt: float) -> void:
	if not state.active:
		return
	_push()
	brain.update(dt)
	_pull()


func resume() -> void:
	_push()
	brain.resume()
	_pull()
