extends SceneTree
## usage: godot --headless --path godot --script res://tests/world_fx/imgdiff.gd -- a.png b.png [threshold]
## Prints how many pixels differ by more than `threshold` (sum of RGB, 0..765) and the max difference.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var a := Image.load_from_file(args[0])
	var b := Image.load_from_file(args[1])
	var th := int(args[2]) if args.size() > 2 else 12
	var n := 0
	var mx := 0
	var sx := 0.0
	var sy := 0.0
	for y in a.get_height():
		for x in a.get_width():
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := int(round((absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) * 255.0))
			mx = maxi(mx, d)
			if d > th:
				n += 1
	print("[diff] ", args[0].get_file(), " vs ", args[1].get_file(), " changed=", n, " max=", mx)
	quit()
