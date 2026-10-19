extends "res://tests/relay/run.gd"
## run.gd's whole session again with the UDP relay offered (DECISIONS B31): same assertions (order and delivery survive the switch to UDP)
## plus the clients and the host ending up on the UDP lane.

func _initialize() -> void:
	udp_mode = true
	super._initialize()
