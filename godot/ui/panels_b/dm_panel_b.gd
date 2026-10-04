class_name DmPanelB
extends VBoxContainer
## Base of the crafting / gathering / economy panels. A panel is a content column (so the Acre ledger can host it as a tab and tests can
## drive it without a window); `make_window()` wraps it in a DmWindow with the web's fixed header.
##
## Contract (same for every subclass): feed it plain Dictionaries (the shape of the server reply, see each file's header), listen to its
## signals. It never calls the network: each signal's doc comment names the DmApi call (godot/net/dm_api.gd) the integrator makes, then
## feeds the reply back in (and re-reads the bag when the action moves items, under the inventory "exclusive" guard like the web).

signal close_requested

var title := ""
var aka := ""
var panel_width := 680
## The head's right-hand summary (`.cw-skill-total`, e.g. "Grave Gardening 12 · 340 / 500 xp"); shown as the first line of the content.
var head_note := ""
## Shown verbatim in red under the content (`.cw-error`).
var error_text := ""
var window: DmWindow


func _init() -> void:
	theme = DmUi.theme()
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## Wrap in a window (add the returned node to the scene yourself, then `open()` it).
func make_window() -> DmWindow:
	window = DmWindow.new()
	window.title = title
	window.aka = aka
	window.panel_width = panel_width
	window.body.add_child(self)
	window.closed.connect(func() -> void: close_requested.emit())
	return window


func set_error(msg: String) -> void:
	error_text = msg
	rebuild()


func rebuild() -> void:
	DmPb.clear(self)
	_build()


func _build() -> void:
	pass


func _head_note_row() -> void:
	if head_note == "":
		return
	var l := DmPb.rich(head_note, 13, DmUi.BONE_300)
	add_child(l)


func _error_row() -> void:
	var l := DmUi.label(error_text, "DmError", true)
	l.name = "Error"
	l.visible = error_text != ""
	add_child(l)
