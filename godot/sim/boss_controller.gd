class_name DmBossController
extends RefCounted
## The interface between the world sim and one area boss (see godot/sim/BOSS_HOOK.md). The sim owns one controller per boss id
## (sim.bosses[id]) and talks to the awake one through exactly these members. The bosses track subclasses this (or replaces the
## stub via res://sim/bosses/boss_factory.gd) and ports BossBrain.ts behind it.

var sim  # DmWorldSim (untyped: the sim and the controllers reference each other)
var id: String = "prelate"
var state: DmBossState = DmBossState.new()


## Called by sim.bosses construction; `p_sim` is the owning DmWorldSim.
func setup(p_sim, p_id: String) -> void:
	sim = p_sim
	id = p_id
	state.id = p_id


## A summonBoss intent was accepted (no other boss awake). `empowered` = Covenant Seal summon.
func awaken(_by: String, _empowered: bool = false) -> void:
	pass


## A hit landed on the boss (Intent 'hit' with boss=true, thrall blows, litany, detonate, signatures...). fracture = Fracture stacks to add.
func damage(_amount: float, _by: String, _fracture: float) -> void:
	pass


## Shield Bash: pause the boss clock for `seconds`.
func stagger(_seconds: float) -> void:
	pass


## Once per sim.step(dt), after enemies/thralls moved, before corpses (the TS order). The brain mutates `state`, the sim (emit, spawn_enemy, zones...) and players' hurt events.
func update(_dt: float) -> void:
	pass


## Host migration: rebuild what only the old brain knew (niches, pits). Rarely needed in solo.
func resume() -> void:
	pass
