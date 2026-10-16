class_name DmDepthsStairPrompt
extends DmWindow
## Port of archive/legacy-web:src/ui/DepthsStairPrompt.ts: the Warren stair's choice once the hero has been below depth 1 (resume at the deepest floor, or start at 1).

signal depth_picked(depth: int)

var resume_button: Button
var fresh_button: Button


func _init() -> void:
	super._init()
	title = "The Stair Down"
	panel_width = 440


func open_deepest(deepest: int) -> void:
	for c in body.get_children():
		c.queue_free()
	body.add_child(DmUi.label("Your deepest descent is depth %d. Where do you go down?" % deepest, "DmHint", true))
	resume_button = Button.new()
	resume_button.text = "Resume at depth %d — pick up where you left off; floors past it beat your record." % deepest
	resume_button.pressed.connect(func() -> void:
		close()
		depth_picked.emit(deepest))
	body.add_child(resume_button)
	fresh_button = Button.new()
	fresh_button.text = "Descend from depth 1 — a fresh run from the first floor."
	fresh_button.pressed.connect(func() -> void:
		close()
		depth_picked.emit(1))
	body.add_child(fresh_button)
	open()
