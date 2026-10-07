extends "res://tests/next_combat_odds/run.gd"
## Cast-cue audit of the 25 rites: for each one, how many visual primitives (DmRiteFx.stats minus sfx / loop / gesture / shake / float) fire in the cast
## window (the first 0.25 s after the accepted cast) and in the whole 4 s; plus the sounds. A rite with 0 visuals in the cast window gives no cue at the
## moment of the press. Prints a table; `godot --headless --path godot --script res://tests/next_clarity/audit.gd`

const NONVIS := ["sfx", "loop", "gesture", "shake", "float"]


func _vis(s: Dictionary) -> int:
	var n := 0
	for k in s:
		if not NONVIS.has(k):
			n += int(s[k])
	return n


var tail := 3.75          ## seconds watched after the first 0.25 s (the table's total_vis); the suite uses 0
var results := {}         ## rite -> {early, total, sfx, why}


func _parts() -> void:
	await _setup()
	for id in DmRiteRegistry.ids():
		await audit_rite(id)


func _setup() -> void:
	boss_id = "gravedigger"
	character = (await api.load_or_create_character(0)).data
	await new_solo()
	caster = hb.get_node("Rites") as DmRiteCaster
	th = hb.get_node("Thralls") as DmThrallHost
	caster.p["stats"]["level"] = 60.0
	caster.random = func() -> float: return 0.5


func audit_rite(id: String) -> void:
	if true:
		reset()
		hb.teleport(Vector3(0, 0, -16))
		for i in 7:
			var a := float(i) / 7.0 * TAU
			foe(Vector3(cos(a) * 3.5, 0, -16.0 + sin(a) * 3.5))
		var best: DmSimCorpse = null
		for i in 6:
			var a2 := float(i) / 6.0 * TAU + 0.3
			var cp := corpse(Vector3(cos(a2) * 2.2, 0, -16.0 + sin(a2) * 2.2))
			if best == null:
				best = cp
		var spec := {"kind": "warrior", "cap": 6.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0}
		for k in 2:
			th._spawn(DmThralls.raise_stats(spec, {"kind": "normal", "enemy": "risen", "elite": false}, 1.0, k + 1, 0.0), hb.global_position + Vector3(2 + k, 0, 0), 0.0)
		await until(func() -> bool: return th.list().all(func(t: DmThrall) -> bool: return t.state != DmThrall.S.RISING), 6.0)
		var rec := RecAudio.new()
		caster.fx.audio = rec
		caster.p["castUntil"] = 0.0
		caster.p["cooldowns"].clear()
		caster.p["resource"]["value"] = 900.0
		var why: Array = []
		var rj := func(_r: String, w: String) -> void: why.append(w)
		caster.cast_rejected.connect(rj)
		var before: Dictionary = caster.fx.stats.duplicate()
		var def := DmAbilities.def(id)
		if String(def.get("targeting", "ground")) == "enemy":
			caster.request_cast(id, foes[0].position, eid(foes[0]))
		else:
			caster.request_cast(id, Vector3(best.x, 0, best.z) if best != null else Vector3(3, 0, -16), -1)
		await secs(0.25)
		var early := {}
		for k in caster.fx.stats:
			early[k] = int(caster.fx.stats[k]) - int(before[k])
		await secs(tail)
		var total := {}
		for k in caster.fx.stats:
			total[k] = int(caster.fx.stats[k]) - int(before[k])
		caster.cast_rejected.disconnect(rj)
		results[id] = {"early": _vis(early), "total": _vis(total), "sfx": rec.sfx.duplicate(), "why": why}
		print("RITE %-16s early_vis=%2d total_vis=%3d sfx=%s%s" % [id, _vis(early), _vis(total), str(rec.sfx), ("  REJECTED " + str(why)) if not why.is_empty() else ""])
