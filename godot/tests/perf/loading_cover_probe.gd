extends SceneTree
var main: Node
var n := 0
var log_: Array = []
func _initialize() -> void:
	main = load("res://main/main.tscn").instantiate()
	root.add_child(main)
	process_frame.connect(_f)
func _cover_up() -> bool:
	for c in root.find_children("*", "CanvasLayer", true, false):
		if (c as CanvasLayer).layer == 90 and c.visible:
			return true
	return false
func _f() -> void:
	n += 1
	var g = main.get("game") if main.get("game") != null else main.get("slice")   # slice = the rebuild (the default since USE_NEXT)
	var ui = main.get("ui")
	var state := "none"
	if g != null and is_instance_valid(g):
		state = "game"
		if ui != null:
			state = "ui"
		if g.get("ready_") == true:
			state += "+ready"
	var cov := _cover_up()
	log_.append([n, state, cov])
	if n % 60 == 0: print("COVER tick ", n, " ", state, " ", cov)
	if state.begins_with("ui") and not cov and n > 20:
		# first uncovered frame after the ui exists = playable
		_report()
func _report() -> void:
	var gap := 0
	var first := -1
	for r in log_:
		if r[1] != "none" and not r[2]:
			gap += 1
			if first < 0:
				first = r[0]
	print("COVER frames=%d uncovered frames from game creation to the first playable frame=%d (first at %d)" % [log_.size(), gap - 1, first])
	var last_state := ""
	for r in log_:
		var k = "%s cover=%s" % [r[1], r[2]]
		if k != last_state:
			print("COVER frame %d: %s" % [r[0], k])
			last_state = k
	quit()
