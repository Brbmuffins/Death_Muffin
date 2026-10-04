class_name DmGrimoireWindow
extends DmPaTabbedWindow
## The merged Grimoire window (WorldScene grimWin): tabs "Grimoire · L" (DmGrimoireView) and "Legion · Y" (DmLegionView; hidden for non-necromancers).

var grimoire := DmGrimoireView.new()
var legion := DmLegionView.new()


func _init() -> void:
	super._init()
	title = "Grimoire"
	panel_width = 760
	add_tab("grimoire", "Grimoire", grimoire, "L")
	add_tab("legion", "Legion", legion, "Y")


## Necromancers only get the Legion tab.
func set_family(family: String) -> void:
	set_tab_hidden("legion", family != "necromancer")


func open_tab(id: String) -> void:
	select_tab(id)
	open()
