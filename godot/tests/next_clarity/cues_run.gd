extends "res://tests/next_clarity/audit.gd"
## Every one of the 25 rites gives a visible AND an audible cue in the 0.25 s after an accepted cast (never silent, never only on landing).
## godot --headless --path godot --script res://tests/next_clarity/cues_run.gd


func _parts() -> void:
	tail = 0.0
	await _setup()
	var ids: Array = DmRiteRegistry.ids()
	check(ids.size() == 25, "25 rites are registered (%d)" % ids.size())
	for id in ids:
		await audit_rite(id)
		var r: Dictionary = results[id]
		check((r["why"] as Array).is_empty(), "%s casts in the audit scene (refused %s)" % [id, str(r["why"])])
		check(int(r["early"]) >= 3, "%s shows a visible cue at the cast (%d visual calls in 0.25 s)" % [id, int(r["early"])])
		check(not (r["sfx"] as Array).is_empty(), "%s makes a sound at the cast (%s)" % [id, str(r["sfx"])])
