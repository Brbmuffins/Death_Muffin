class_name DmCharacterWindow
extends DmPaTabbedWindow
## The merged Character window (WorldScene charWin): tabs "Stats · J" (DmSheetView) and "Capes & Pets · N" (DmCosmeticsView, with a NEW pip until used).
## `sheet` and `cosmetics` are the content views; wire their signals/data directly. open_tab("stats" | "pets") opens at a tab (J / N keys).

var sheet := DmSheetView.new()
var cosmetics := DmCosmeticsView.new()


func _init() -> void:
	super._init()
	title = "Character"
	panel_width = 640
	add_tab("stats", "Stats", sheet, "J")
	add_tab("pets", "Capes & Pets", cosmetics, "N")


func open_tab(id: String) -> void:
	select_tab(id)
	open()
