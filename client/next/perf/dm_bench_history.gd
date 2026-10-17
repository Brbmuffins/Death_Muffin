class_name DmBenchHistory
extends RefCounted
## The benchmark's run history. Local (`history_file`): every finished run's setup, PC and numbers, for the results screen's "vs last run" column
## (the previous run of the same setup on the same GPU). Server: every finished run is queued in `pending_file` and sent with the player's login
## (DmApi.post_benchmark -> the benchmark history of the TEST server); `flush` retries what is left the next time a logged-in online session has an api (the results screen,
## character select). Runs that ran at the refresh rate (V-Sync forced on) or were cancelled are sent too, flagged by the server and left out of its trends.
## Ported to the rebuilt client (client/code.list "Ported"): both files live in `DmBenchmark.dir`, so a test keeps its own, and a script run (every test is one) never sends through a real transport.

const KEEP := 200               ## local runs kept (oldest dropped)
const PENDING_KEEP := 50
## Lower-is-better rows of DmBenchmark.ROWS (the rest are higher-is-better or neutral counts; see `better`).
const LOWER_BETTER := ["avg_ms", "median_ms", "p95_ms", "p99_ms", "worst_ms", "hitches", "draw_calls", "objects", "primitives", "render_cpu_ms", "render_gpu_ms", "process_ms", "physics_ms"]
const HIGHER_BETTER := ["avg_fps"]

static var _flushing := false


## The local history of finished runs.
static func history_file() -> String:
	return DmBenchmark.dir.path_join("history.json")


## The runs waiting to be sent.
static func pending_file() -> String:
	return DmBenchmark.dir.path_join("pending.json")


## The entry stored locally and sent to the server for a finished run (`r` = DmBenchmark.run()'s results, `report` = its text).
static func payload(r: Dictionary, report: String) -> Dictionary:
	var m: Dictionary = r["meta"]
	var s: Dictionary = r.get("setup", DmBenchmark.STANDARD)
	var ph: Dictionary = (r["phases"] as Array)[0] if not (r["phases"] as Array).is_empty() else {}
	var metrics := {}
	for k in ph:
		if ph[k] is float or ph[k] is int:
			metrics[k] = float(ph[k])
	var bd: Dictionary = r.get("breakdown", {})
	return {
		"clientRunId": "%d%06d" % [Time.get_unix_time_from_system(), randi() % 1000000],
		"ranAt": Time.get_datetime_string_from_system(false, false),
		"version": str(m.get("version", "")), "godot": str(m.get("godot", "")), "gpu": str(m.get("gpu", "")), "cpu": str(m.get("cpu", "")),
		"cores": int(m.get("cores", 0)), "os": str(m.get("os", "")), "renderer": str(m.get("renderer", "")), "resolution": str(m.get("resolution", "")),
		"refreshHz": float(m.get("refresh_hz", 0.0)), "preset": str(m.get("preset", "")),
		"room": str(s["room"]), "discipline": int(s["discipline"]), "size": str(s["size"]), "length": str(s["length"]),
		"standard": DmBenchmark.is_standard(s), "vsyncCapped": DmBenchmark.capped_warning(r) != "", "cancelled": bool(r.get("cancelled", false)),
		"metrics": metrics, "breakdown": bd, "report": report,
	}


## Saves `p` (a `payload`) to the local history and queues it for the server.
static func record(p: Dictionary) -> void:
	var all := _read(history_file())
	var local := p.duplicate()
	local.erase("report")      # (the text reports are saved one file each; the history keeps the numbers)
	local.erase("breakdown")
	all.append(local)
	_write(history_file(), all.slice(maxi(0, all.size() - KEEP)))
	var q := _read(pending_file())
	q.append(p)
	_write(pending_file(), q.slice(maxi(0, q.size() - PENDING_KEEP)))


## The latest earlier local run of the same setup on the same GPU and preset, or {} (`p` itself is skipped by its clientRunId).
static func previous(p: Dictionary) -> Dictionary:
	var all := _read(history_file())
	for i in range(all.size() - 1, -1, -1):
		var e: Dictionary = all[i]
		if e.get("clientRunId") == p["clientRunId"] or bool(e.get("cancelled", false)):
			continue
		var same := int(e.get("discipline", 0)) == int(p["discipline"])   # (a number read back from JSON is a float)
		for k in ["room", "size", "length", "gpu", "preset"]:
			same = same and str(e.get(k, "")) == str(p[k])
		if same:
			return e
	return {}


## Change of `key` from `prev` to `now` as a fraction (0.1 = +10%), or NAN when there is nothing to compare.
static func change(now: Dictionary, prev: Dictionary, key: String) -> float:
	if prev.is_empty() or not now.has(key) or not (prev.get("metrics", {}) as Dictionary).has(key):
		return NAN
	var b := float(prev["metrics"][key])
	if absf(b) < 0.0001:
		return NAN
	return (float(now[key]) - b) / absf(b)


## +1 when a change of `frac` in `key` is an improvement, -1 when it is worse, 0 for neutral rows (counts that only describe the fight).
static func better(key: String, frac: float) -> int:
	if is_nan(frac) or absf(frac) < 0.02:
		return 0
	if key in HIGHER_BETTER:
		return 1 if frac > 0.0 else -1
	if key in LOWER_BETTER:
		return 1 if frac < 0.0 else -1
	return 0


## Sends the queued runs (oldest first) with `api` (an online, logged-in DmApi). A run the server accepted, or refused as invalid (400 / 413 /
## 422, or `success: false`), leaves the queue; anything else (no network, 401 / 409 login trouble, 429, 5xx) stops and keeps the rest for next
## time. Returns how many were accepted.
static func flush(api: DmApi) -> int:
	if api == null or api.get_token().is_empty() or _flushing or over_the_network_from_a_script(api):
		return 0
	_flushing = true
	var sent := 0
	var q := _read(pending_file())
	while not q.is_empty():
		var r := await api.post_benchmark(q[0])
		var gone := r.ok or r.status in [200, 400, 413, 422]   # accepted, or refused as invalid (sending it again would not help)
		if not gone:
			break
		if r.ok:
			sent += 1
		q.pop_front()
		_write(pending_file(), q)
	_flushing = false
	return sent


## True when `api` would carry the run over the network (a DmHttpTransport) from a script run: every test is one (`godot --script`), and no test sends a benchmark run anywhere but
## a mock, the test server included. A real launch is not a script run.
static func over_the_network_from_a_script(api: DmApi) -> bool:
	return "--script" in OS.get_cmdline_args() and api.transport.is_valid() and api.transport.get_object() is DmHttpTransport


static func pending_count() -> int:
	return _read(pending_file()).size()


static func _read(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Array else []


static func _write(path: String, rows: Array) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(rows))
