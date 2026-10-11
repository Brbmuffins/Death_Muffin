extends "res://tests/next_clarity/audit.gd"
## Combat-readability polish of the rebuild, one process (next/feel/README.md):
##   1. clarity_part: the floating-number budget, the action bar's "no corpse / no legion" state, the low-health thrall ring, the red legion pips
##   2. cues: every one of the 31 rites gives a visible AND an audible cue in the 0.25 s after an accepted cast (never silent, never only on landing).
## godot --headless --path godot --script res://tests/next_clarity/run.gd   (audit.gd is the table tool: same file, tail 3.75 s)


func _parts() -> void:
	var keep := root.get_children()
	var part = load("res://tests/next_clarity/clarity_part.gd").new()
	part.bind(self)
	await part._initialize()
	passed += part.passed
	failed += part.failed
	print("  [clarity_part] %d passed, %d failed" % [part.passed, part.failed])
	for c in root.get_children():
		if not keep.has(c):
			root.remove_child(c)
			c.free()
	await process_frame
	log_.errors.clear()   # the clarity part ran stand-alone (no engine-error log) before the merge; the log check below covers the cues part only
	await _cues()


func _cues() -> void:
	tail = 0.0
	await _setup()
	var ids: Array = DmRiteRegistry.ids()
	check(ids.size() == 31, "31 rites are registered (%d)" % ids.size())
	for id in ids:
		await audit_rite(id)
		var r: Dictionary = results[id]
		check((r["why"] as Array).is_empty(), "%s casts in the audit scene (refused %s)" % [id, str(r["why"])])
		check(int(r["early"]) >= 3, "%s shows a visible cue at the cast (%d visual calls in 0.25 s)" % [id, int(r["early"])])
		check(not (r["sfx"] as Array).is_empty(), "%s makes a sound at the cast (%s)" % [id, str(r["sfx"])])
