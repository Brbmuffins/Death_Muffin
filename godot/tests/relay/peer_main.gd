extends SceneTree
## Child process for run.gd: one relay participant.
##   godot --headless --path godot --script res://tests/relay/peer_main.gd -- <role> <url> <token> <logfile> [session_id] [label]
## role = host | client. It writes progress lines to <logfile>; run.gd asserts on them.

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var node: Node = load("res://tests/relay/relay_node.gd").new()
	node.name = "Game"
	node.role = a[0]
	node.url = a[1]
	node.token = a[2]
	node.logfile = a[3]
	node.session_id = a[4] if a.size() > 4 else ""
	node.label = a[5] if a.size() > 5 else ""
	root.add_child(node)
