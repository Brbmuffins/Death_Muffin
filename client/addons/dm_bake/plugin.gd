@tool
extends EditorPlugin
## The lighting bake, driven from the command line (README.md): Godot bakes a LightmapGI only from the editor's "Bake Lightmaps" button
## (LightmapGI has no bake() a script can call in 4.7.2), so this plugin presses it. Inert unless the editor starts with
## `-- --dm-bake=res://areas/graves.tscn[,...]`; then it opens each scene, gives its LightmapGI a fresh, empty data file next to the scene
## (without one the button opens a save dialog; an empty one also makes a failed bake visible, since a failed bake leaves the data untouched),
## bakes, saves the scene, writes `--dm-bake-result=<file>` (JSON, one row per scene) and quits the editor (exit 1 when any scene failed).

const TRIES := 3
const BUTTON := "Bake Lightmaps"   ## LightmapGIEditorPlugin's toolbar button (matched in English and in the editor's language)


func _enter_tree() -> void:
	var scenes := PackedStringArray()
	var result := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dm-bake="):
			scenes = a.trim_prefix("--dm-bake=").split(",", false)
		elif a.begins_with("--dm-bake-result="):
			result = a.trim_prefix("--dm-bake-result=")
	if not scenes.is_empty():
		_run.call_deferred(scenes, result)


func _run(scenes: PackedStringArray, result: String) -> void:
	var rows: Array = []
	await _frames(30)
	while EditorInterface.get_resource_filesystem().is_scanning():
		await _frames(1)
	await _stand_in_images(scenes)
	for scene in scenes:
		rows.append(await _bake(scene))
	# A second pass over the scenes that failed: the first scene of a fresh editor has failed in two ways on Helix's PC (2026-10-16: no 3D toolbar
	# yet, then "did not open" in time) while every later one baked; by the second pass the editor is warm.
	for i in rows.size():
		if not rows[i]["ok"]:
			await _frames(60)
			var again: Dictionary = await _bake(String(rows[i]["scene"]))
			again["first_error"] = rows[i]["error"]
			rows[i] = again
	var ok := rows.all(func(r: Dictionary) -> bool: return r["ok"])
	if result != "":
		var f := FileAccess.open(result, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify({"ok": ok, "godot": Engine.get_version_info()["string"], "gpu": RenderingServer.get_video_adapter_name(), "scenes": rows}, " "))
			f.close()
	print("DM_BAKE ", "OK" if ok else "FAILED", " ", JSON.stringify(rows))
	get_tree().quit.call_deferred(0 if ok else 1)


func _bake(scene: String) -> Dictionary:
	var row := {"scene": scene, "ok": false, "ms": 0, "data": "", "error": ""}
	if not ResourceLoader.exists(scene):
		row["error"] = "no such scene"
		return row
	EditorInterface.open_scene_from_path(scene)
	var root: Node = null
	for i in 600:   # up to about 10 s: a fresh editor opens its first scene late
		await _frames(1)
		root = EditorInterface.get_edited_scene_root()
		if root != null and root.scene_file_path == scene:
			break
		if i == 300:
			EditorInterface.open_scene_from_path(scene)
	if root == null or root.scene_file_path != scene:
		row["error"] = "scene did not open"
		return row
	var found := root.find_children("*", "LightmapGI", true, false)
	if found.is_empty():
		row["error"] = "the scene has no LightmapGI"
		return row
	var lm := found[0] as LightmapGI
	var path := scene.get_basename() + ".lmbake"
	var data := LightmapGIData.new()
	var err := ResourceSaver.save(data, path)
	if err != OK:
		row["error"] = "cannot write %s (%s)" % [path, error_string(err)]
		return row
	data.take_over_path(path)
	lm.light_data = data
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(lm)
	EditorInterface.set_main_screen_editor("3D")   # the button lives on the 3D view's toolbar; an editor that opens on another view hides it
	EditorInterface.edit_node(lm)
	# Up to about 5 s: on a fresh editor the 3D view and its toolbar come up some frames after the first scene opens (2026-10-16: the first of eleven
	# scenes found no button, the next ten did).
	var btn: Button = null
	for i in 300:
		await _frames(1)
		btn = _button(EditorInterface.get_base_control())
		if btn != null and btn.is_visible_in_tree():
			break
	if btn == null or not btn.is_visible_in_tree():
		row["error"] = "no visible '%s' button in the editor" % BUTTON
		return row
	# Up to three tries: the editor once canceled a bake through its progress window (2026-10-16, one scene of eleven, fine on the run before), so a
	# bake that produced nothing settles, gets a fresh data file and is pressed again.
	var t0 := Time.get_ticks_msec()
	for attempt in TRIES:
		if attempt > 0:
			await _frames(60)
			data = LightmapGIData.new()
			ResourceSaver.save(data, path)
			data.take_over_path(path)
			lm.light_data = data
		row["tries"] = attempt + 1
		btn.pressed.emit()   # bakes synchronously, with the editor's progress window
		# The lightmap's textures arrive once the editor has imported the new images, some frames later: wait up to about 10 s before calling the
		# try a failure (2026-10-16: a 10-frame look missed them, every scene was baked twice and the second bake could not overwrite the images).
		for i in 600:
			await _frames(1)
			data = lm.light_data
			if data != null and not data.get_lightmap_textures().is_empty():
				break
		if data != null and not data.get_lightmap_textures().is_empty():
			break
	row["ms"] = Time.get_ticks_msec() - t0
	if data == null or data.get_lightmap_textures().is_empty():
		row["error"] = "the bake produced no lightmap in %d tries (meshes need UV2 and static global illumination; the editor showed why)" % TRIES
		return row
	row["data"] = data.resource_path
	row["textures"] = data.get_lightmap_textures().size()
	if EditorInterface.save_scene() != OK:
		row["error"] = "the scene could not be saved"
		return row
	await _frames(30)   # let the editor's progress window close before the next scene's bake opens one
	row["ok"] = true
	return row


func _button(n: Node) -> Button:
	if n is Button and ((n as Button).text == BUTTON or (n as Button).text == TranslationServer.get_or_add_domain("godot.editor").translate(BUTTON)):
		return n
	for c in n.get_children():
		var b := _button(c)
		if b:
			return b
	return null


## Godot 4.7.2's bake writes each lightmap image, imports it and loads it back (LightmapGI::_save_and_reimport_atlas_textures); an image the editor
## has never seen does not load back, so the first bake of every scene failed with a "Failed creating lightmap images" warning window and the second
## worked (2026-10-17, Helix's PC: twelve scenes, two tries and a warning each). So every scene without an image gets a 4x4 stand-in `<scene>.exr` with
## the import settings the bake writes, registered and imported by the editor before any bake: the first bake then overwrites a known image.
func _stand_in_images(scenes: PackedStringArray) -> void:
	var made := PackedStringArray()
	for scene in scenes:
		var exr := scene.get_basename() + ".exr"
		if FileAccess.file_exists(exr):
			continue
		if Image.create_empty(4, 4, false, Image.FORMAT_RGBAH).save_exr(exr, false) != OK:
			continue
		var cfg := ConfigFile.new()
		cfg.set_value("remap", "importer", "2d_array_texture")
		cfg.set_value("remap", "type", "CompressedTexture2DArray")
		cfg.set_value("params", "compress/mode", 2)
		cfg.set_value("params", "compress/channel_pack", 1)
		cfg.set_value("params", "mipmaps/generate", false)
		cfg.set_value("params", "slices/horizontal", 1)
		cfg.set_value("params", "slices/vertical", 1)
		cfg.save(exr + ".import")
		made.append(exr)
	if made.is_empty():
		return
	# Up to about 30 s for the editor to find and import them (a scan runs on its own thread and may start a few frames late).
	var fs := EditorInterface.get_resource_filesystem()
	fs.scan()
	var until := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < until:
		await _frames(1)
		if not fs.is_scanning() and Array(made).all(func(exr: String) -> bool: return fs.get_file_type(exr) != "" and ResourceLoader.exists(exr)):
			break


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
