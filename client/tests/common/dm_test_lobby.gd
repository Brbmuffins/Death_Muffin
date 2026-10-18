class_name DmTestLobby
extends RefCounted
## Test helper: a LOCAL lobby + relay service (server/death-muffin/lobby, node) on a random free port with a test JWT secret, never the live one.
##   var lobby := DmTestLobby.start()        # null when node / npm install are missing (the suite then prints a skip line)
##   lobby.url  /  lobby.token(7, "name")  /  lobby.stop()
## The service is a child process of the test: stop() (or the test's quit) kills it.

const SECRET := "party-test-secret-not-a-real-one"

var url := ""
var port := 0
var pid := 0


## Env for the service: pass the same secret to the child game processes through `token()`.
static func start(env: Dictionary = {}) -> DmTestLobby:
	var dir := ProjectSettings.globalize_path("res://").path_join("../server/death-muffin/lobby").simplify_path()
	var out := []
	if OS.execute("node", ["-v"], out) != OK or not FileAccess.file_exists(dir.path_join("node_modules/ws/package.json")):
		return null
	var l := DmTestLobby.new()
	l.port = DmTestPorts.free_tcp_port()
	if l.port == 0:
		return null
	OS.set_environment("DM_LOBBY_JWT_SECRET", SECRET)
	OS.set_environment("DM_LOBBY_PORT", str(l.port))
	OS.set_environment("DM_LOBBY_HOST", "127.0.0.1")
	OS.set_environment("DM_LOBBY_QUIET", "1")
	for k in env:
		OS.set_environment(String(k), String(env[k]))
	l.pid = OS.create_process("node", [dir.path_join("src/index.js")])
	l.url = "ws://127.0.0.1:%d" % l.port
	return l


func token(account_id: int, username: String) -> String:
	return RelayTestJwt.mint(SECRET, account_id, username)


## Wait until the service answers a TCP connect (it takes ~200 ms to start).
func wait_ready(tree: SceneTree, timeout_s: float = 10.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_s * 1000.0:
		var c := StreamPeerTCP.new()
		if c.connect_to_host("127.0.0.1", port) == OK:
			for i in 20:
				c.poll()
				if c.get_status() != StreamPeerTCP.STATUS_CONNECTING:
					break
				await tree.create_timer(0.02).timeout
			var up := c.get_status() == StreamPeerTCP.STATUS_CONNECTED
			c.disconnect_from_host()
			if up:
				return true
		await tree.create_timer(0.1).timeout
	return false


func stop() -> void:
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
	pid = 0
