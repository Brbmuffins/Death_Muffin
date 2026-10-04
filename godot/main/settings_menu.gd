class_name DmSettingsMenu
extends CanvasLayer
## Esc opens/closes the ui-kit Settings panel in game. Its volume sliders drive AudioDirector.apply_settings; values persist to
## user://settings.cfg and load on start. Audio keys/defaults are the web's (app/settings.ts): volume 0.6, combatVolume 1,
## ambienceVolume 1, musicVolume 0.85, interfaceVolume 1 (the panel's vol_* keys map 1:1). Other panel values persist under [panel].

const WEB_KEYS := {"vol_master": "volume", "vol_combat": "combatVolume", "vol_amb": "ambienceVolume", "vol_music": "musicVolume", "vol_ui": "interfaceVolume"}
const WEB_DEFAULTS := {"volume": 0.6, "combatVolume": 1.0, "ambienceVolume": 1.0, "musicVolume": 0.85, "interfaceVolume": 1.0}

var cfg_path := "user://settings.cfg"
var panel: DmSettingsPanel
var ad: Node
var _holder: Control

func setup(director: Node = null, path: String = "") -> void:
	layer = 20
	ad = director if director != null else get_node_or_null("/root/AudioDirector")
	if path != "":
		cfg_path = path
	_holder = Control.new()
	_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_holder)
	panel = DmSettingsPanel.new()
	panel.has_party = false
	panel.has_bug_report = false
	panel.has_change_class = false
	panel.has_keybinds = false
	panel.has_dev = false
	panel.has_reset_tips = false
	_load()
	panel.build()
	_holder.add_child(panel)
	panel.changed.connect(_on_changed)
	panel.action.connect(_on_action)
	panel.opened.connect(DmAudioHooks.panel_open)
	panel.closed.connect(DmAudioHooks.panel_close)
	_apply()

func is_open() -> bool:
	return panel.visible

func toggle() -> void:
	if panel.visible:
		panel.close()
	else:
		panel.open()

func _unhandled_key_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.physical_keycode == KEY_ESCAPE:
		toggle()
		get_viewport().set_input_as_handled()

func audio_dict() -> Dictionary:
	var d := {}
	for k in WEB_KEYS:
		d[WEB_KEYS[k]] = float(panel.values[k])
	return d

func _apply() -> void:
	if ad != null:
		ad.apply_settings(audio_dict())

func _on_changed(key: String, _v: Variant) -> void:
	if WEB_KEYS.has(key):
		_apply()
	else:
		DmAudioHooks.click()
	_save()

func _on_action(name: String) -> void:
	DmAudioHooks.click()
	if name == "leave":
		get_tree().quit()   # the slice has no character select to return to

func _load() -> void:
	for k in WEB_KEYS:
		panel.values[k] = WEB_DEFAULTS[WEB_KEYS[k]]
	var c := ConfigFile.new()
	if c.load(cfg_path) != OK:
		return
	for k in WEB_KEYS:
		panel.values[k] = clampf(float(c.get_value("settings", WEB_KEYS[k], WEB_DEFAULTS[WEB_KEYS[k]])), 0.0, 1.0)
	for k in panel.values:
		if not WEB_KEYS.has(k) and c.has_section_key("panel", k):
			panel.values[k] = c.get_value("panel", k)

func _save() -> void:
	var c := ConfigFile.new()
	for k in WEB_KEYS:
		c.set_value("settings", WEB_KEYS[k], float(panel.values[k]))
	for k in panel.values:
		if not WEB_KEYS.has(k):
			c.set_value("panel", k, panel.values[k])
	c.save(cfg_path)
