extends SceneTree
## Bakes creature models for crowd drawing. Run through tools/bake_crowd.sh, or:
##   godot --headless --path client --script res://tools/bake_crowd.gd -- robber hound
## Names are enemy ids (godot/data/content/enemies.json) or model slugs. Output: res://crowd/baked/<model slug>/ (not committed).
## Options: --out=res://crowd/baked  --assets=<folder holding slice/>  --max-triangles=5000

const CrowdBakerScript := preload("res://crowd/crowd_baker.gd")


func _initialize() -> void:
	await process_frame   # the scene tree is live from the first frame; animation players need it
	var names: Array[String] = []
	var out := "res://crowd/baked"
	var opts := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--assets="):
			opts["assets_dir"] = a.substr(9)
		elif a.begins_with("--max-triangles="):
			opts["max_triangles"] = int(a.substr(16))
		else:
			names.append(a)
	if names.is_empty():
		printerr("usage: bake_crowd.gd -- <enemy id or model slug>... [--out=res://crowd/baked] [--assets=dir] [--max-triangles=5000]")
		quit(2)
		return
	var failed := false
	for n in names:
		var slug: String = CrowdBakerScript.model_for(n)
		var r: Dictionary = CrowdBakerScript.bake(root, slug, out.path_join(slug), opts)
		if not r.ok:
			printerr("FAIL bake_crowd %s" % r.error)
			failed = true
			continue
		var clips := []
		for c in r.clips:
			clips.append("%s %d@%.1f (%.0f mm%s)" % [c.name, c.frames, c.fps, c.error * 1000.0, ", loop seam %.0f mm" % (c.seam * 1000.0) if c.seam > 0.01 else ""])
		print("%s: %d triangles (%s), %d vertices -> %d animation ids, %d frames, textures %s (%.1f MB), %.0f s\n  clips (frames@per second, worst interpolation error): %s%s" % [
			slug, r.source_triangles, ",".join(Array(r.triangles).map(func(t: int) -> String: return str(t))), r.vertices, r.anim_vertices, r.frames,
			str(r.texture), float(r.pos_bytes + r.nrm_bytes) / 1048576.0, r.seconds, ", ".join(clips),
			"\n  OVER BUDGET: no level of detail within the triangle budget" if r.over_budget else ""])
	quit(1 if failed else 0)
