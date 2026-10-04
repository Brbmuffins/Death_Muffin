class_name DmAcreLedger
extends DmTabbedWindow
## The merged "Acre ledger" window (WorldScene.ts acreWin): Skills (P), Garden (U), Laborers (H), Contracts (O) as tabs of one window.
## It only hosts the four panels; connect to their own signals (`skills`, `garden`, `labor`, `contracts`) for the actions and read their headers
## for the DmApi calls. Opening a tab is the web's `open(tabId)`; the NEW pips are set_new("garden"|"labor"|"contracts", on).

var skills: DmProfessionsPanel
var garden: DmGardenPanel
var labor: DmLaborPanel
var contracts: DmContractsPanel


func _init() -> void:
	super._init()
	title = "Acre ledger"
	panel_width = 860
	skills = DmProfessionsPanel.new()
	garden = DmGardenPanel.new()
	labor = DmLaborPanel.new()
	contracts = DmContractsPanel.new()
	add_tab("skills", "Skills", skills, "P")
	add_tab("garden", "Garden", garden, "U")
	add_tab("labor", "Laborers", labor, "H")
	add_tab("contracts", "Contracts", contracts, "O")


## Open on a tab (the first by default); a tab already showing stays as it is.
func open_tab(id: String = "") -> void:
	if id != "":
		select_tab(id)
	open()


## The kit's tab group only un-presses the old tab on a click; a programmatic select must do it too.
func select_tab(id: String) -> void:
	super.select_tab(id)
	for k: String in _tabs:
		(_tabs[k]["btn"] as Button).set_pressed_no_signal(k == id)
