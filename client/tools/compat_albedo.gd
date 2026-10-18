extends SceneTree
## Prints DmCompatAlbedo.TABLE for every textured, tinted material of the area converter (the floors, the walls and the gate posts of client/data/slice/world.json, and the dark earth beyond the walls).
## Run: godot --headless --path client --script res://tools/compat_albedo.gd   and paste the lines into client/next/look/dm_compat_albedo.gd.

const GATE_POST := ["stone_wall", "#8a8296"]


func _initialize() -> void:
	var world: Dictionary = DmData.world()
	var combos := {}
	for k in world.floors:
		var f: Dictionary = world.floors[k]
		combos[[String(f.tex), Color.hex(int(f.color) * 256 + 255)]] = true
	for w: Dictionary in world.walls:
		combos[[String(w.texture), Color.hex(int(w.color) * 256 + 255)]] = true
	combos[[GATE_POST[0], Color.html(GATE_POST[1])]] = true
	combos[[DmWorldBuilder.OUTSIDE_TEX, Color.html(DmWorldBuilder.OUTSIDE_TINT)]] = true   # the dark earth beyond the walls
	var lines: Array[String] = []
	for c in combos:
		var img := Image.load_from_file(ProjectSettings.globalize_path("res://assets/slice/art/textures/%s.webp" % c[0]))
		var r := DmCompatAlbedo.measure(img, c[1])
		lines.append("\t\"%s\": Vector3(%.3f, %.3f, %.3f)," % [DmCompatAlbedo.key(c[0], c[1]), r.x, r.y, r.z])
	lines.sort()
	print("\n".join(lines))
	quit()
