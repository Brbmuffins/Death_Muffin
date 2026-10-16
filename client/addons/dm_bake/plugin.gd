@tool
extends EditorPlugin
## The lighting bake, driven from the command line (README.md): Godot bakes a LightmapGI only from the editor's "Bake Lightmaps" button
## (LightmapGI has no bake() a script can call in 4.7.2), so this plugin presses it. Inert unless the editor starts with
## `-- --dm-bake=res://areas/graves.tscn[,...]`; then it opens each scene, gives its LightmapGI a fresh, empty data file next to the scene
## (without one the button opens a save dialog; an empty one also makes a failed bake visible, since a failed bake leaves the data untouched),
## bakes, saves the scene, writes `--dm-bake-result=<file>` (JSON, one row per scene) and quits the editor (exit 1 when any scene failed).

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
	for scene in scenes:
		rows.append(await _bake(scene))
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
	await _frames(10)
	var root := EditorInterface.get_edited_scene_root()
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
	var t0 := Time.get_ticks_msec()
	btn.pressed.emit()   # bakes synchronously, with the editor's progress window
	row["ms"] = Time.get_ticks_msec() - t0
	await _frames(5)
	data = lm.light_data
	if data == null or data.get_lightmap_textures().is_empty():
		row["error"] = "the bake produced no lightmap (meshes need UV2 and static global illumination; the editor showed why)"
		return row
	row["data"] = data.resource_path
	row["textures"] = data.get_lightmap_textures().size()
	if EditorInterface.save_scene() != OK:
		row["error"] = "the scene could not be saved"
		return row
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


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
