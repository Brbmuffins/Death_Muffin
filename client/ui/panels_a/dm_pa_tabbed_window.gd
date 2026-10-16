class_name DmPaTabbedWindow
extends DmTabbedWindow
## DmTabbedWindow + one fix: selecting a tab from code (open_tab / select_tab) must un-press the previous tab's button. The kit's select_tab uses
## set_pressed_no_signal on a ButtonGroup member, which leaves the old tab looking pressed (user clicks are fine). Reported to the integrator.


func select_tab(id: String) -> void:
	super.select_tab(id)
	for k in _tabs:
		(_tabs[k]["btn"] as Button).set_pressed_no_signal(k == id)
