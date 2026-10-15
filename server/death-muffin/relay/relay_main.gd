extends SceneTree
## Entry point of `deathmuffin-relay` (README.md): godot --headless --path <this dir> --script relay_main.gd
## Env: DM_RELAY_PORT (5193), DM_RELAY_BIND (*), the shared secret from DM_RELAY_SECRET or JWT_SECRET in ENV_FILE (never printed).

const Relay := preload("dm_udp_relay.gd")

var relay: Node
var _stats_at := 0


func _initialize() -> void:
	OS.low_processor_usage_mode = true
	OS.low_processor_usage_mode_sleep_usec = 1000   # ~1 ms between polls: little CPU, little added latency
	var secret := OS.get_environment("DM_RELAY_SECRET")
	if secret == "" and OS.get_environment("ENV_FILE") != "":
		for line in FileAccess.get_file_as_string(OS.get_environment("ENV_FILE")).split("\n"):
			var l := line.strip_edges()
			if l.begins_with("JWT_SECRET="):
				secret = l.trim_prefix("JWT_SECRET=").trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
	if secret == "":
		printerr("[relay] secret missing: set DM_RELAY_SECRET or ENV_FILE")
		quit(1)
		return
	var port := int(OS.get_environment("DM_RELAY_PORT")) if OS.get_environment("DM_RELAY_PORT").is_valid_int() else 5193
	var bind := OS.get_environment("DM_RELAY_BIND") if OS.get_environment("DM_RELAY_BIND") != "" else "*"
	relay = Relay.new()
	var err: int = relay.listen(port, bind, secret)
	if err != OK:
		printerr("[relay] cannot listen on udp %s:%d (error %d)" % [bind, port, err])
		quit(1)
		return
	root.add_child(relay)
	print("[relay] listening on udp %s:%d" % [bind, port])


func _process(_dt: float) -> bool:
	var now := Time.get_ticks_msec()
	if relay != null and now - _stats_at > 3600000:   # an hourly line in the journal
		_stats_at = now
		print("[relay] %s" % JSON.stringify(relay.stats))
	return false
