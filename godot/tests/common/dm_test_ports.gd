class_name DmTestPorts
extends RefCounted
## A UDP port on 127.0.0.1 nothing is bound to right now (ENet probe), from 40000-49999. Several worktrees and agents run the
## multiplayer suites at once, so suites must never use fixed ports (they stole each other's) — and never production 5190/5191.

static func free_port(avoid: int = 0) -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in 200:
		var port := rng.randi_range(40000, 49999)
		if port == avoid:
			continue
		var probe := ENetMultiplayerPeer.new()
		if probe.create_server(port, 1) == OK:
			probe.close()
			return port
	return 0
