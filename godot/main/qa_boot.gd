extends Node
## Autoload `Qa`: a stub. The QA driver (main/qa_driver.gd) references most of the game, and compiling it cost every process ~5 s at start
## (every test suite paid it); so it is loaded only when the game is started with `-- --qa` or `-- --shot-plan=<plan.json>`, as a child named Driver.

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--qa" or a.begins_with("--shot-plan="):
			var d: Node = load("res://main/qa_driver.gd").new()
			d.name = "Driver"
			add_child(d)
			return
