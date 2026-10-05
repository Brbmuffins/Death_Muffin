class_name DmGameCoop
extends RefCounted
## Co-op (Phase C): the realtime half of WorldScene.ts (connectRealtime, joinWorld, rtHandlers, parties, host migration, remote players).
## The relay's oldest member is the HOST: it simulates and publishes snapshots + events; everyone else is a GUEST and mirrors it
## (DmSimMirror), sending intents instead of applying them. Solo play never depends on this: with the service down, or no `rt`,
## nothing here runs and the game stays the authoritative sim.
##
## A guest keeps `game.sim` pointing at a facade DmWorldSim that is never stepped: its entity dictionaries ARE the mirror's, so every
## reader (views, picking, HUD, event router, depths) works unchanged. `become_authority` swaps in a real sim seeded from the mirror.

const SNAPSHOT_MS := 100.0
const MOVE_SEND_MS := 100.0
const PARTY_ALPHABET := "abcdefghjkmnpqrstuvwxyz23456789"
const SLOT_IDS := ["head", "chest", "legs", "feet", "hands", "main_hand", "off_hand", "ring", "trinket"]

var g
var rt: DmRtClient
var mirror: DmSimMirror = null
var party_code := ""
var paused := false
var reconnector: DmRtReconnector = null
var reconnect_toasted := false
var event_out: DmEventCoalescer
var remotes: Dictionary:
	get: return g.remotes
var _snapshot_count := 0
var _last_snapshot := -1e9
var _last_move := -1e9
var _last_gear := ""
var _enabled := false


func _init(game, client: DmRtClient = null) -> void:
	g = game
	rt = client if client != null else DmRtClient.new()
	event_out = DmEventCoalescer.new(func(batch: Array) -> void: rt.send_events(batch))
	rt.player_joined.connect(_on_player_join)
	rt.player_left.connect(_on_player_leave)
	rt.player_moved.connect(_on_player_move)
	rt.player_gear.connect(_on_player_gear)
	rt.chat_received.connect(func(m: Dictionary) -> void: chat_line("%s: %s" % [m.get("name", "?"), m.get("text", "")]))
	rt.disconnected.connect(_on_disconnect)
	rt.intent_received.connect(_on_intent)
	rt.snapshot_received.connect(func(s: Dictionary) -> void:
		if mirror != null:
			mirror.apply_snapshot(s))
	rt.events_received.connect(_on_events)
	rt.host_changed.connect(func(host_id: String, snapshot: Variant) -> void:
		if host_id == rt.self_id:
			become_authority(snapshot))
	rt.session_replaced.connect(func() -> void: g.api.notify_session_replaced())


func chat_line(text: String) -> void:
	g.emit_game_event("chat", {"text": text})


func connected() -> bool:
	return rt.is_connected_to_world()


## isAuthority(): solo, or the world's host.
func is_authority() -> bool:
	return mirror == null


# ---- joining ---------------------------------------------------------------------------------------------------------------------

## Online editions connect at mount like the web: a saved party (10-minute window) or your own solo world.
func connect_initial() -> void:
	_enabled = true
	var saved := DmRtRejoinStore.load_rejoin()
	var res := await join_world(saved, "first")
	if res.ok:
		return
	var msg := res.error
	if saved != "" and not DmRtClient.is_retryable_error(msg, "first") and not msg.contains("not configured"):
		DmRtRejoinStore.clear_rejoin()
		var res2 := await join_world("", "first")
		if res2.ok:
			return
		first_failed(res2.error)
		return
	first_failed(msg)


## First connect failed: say so once. A service that is merely down keeps being retried quietly.
func first_failed(err: String) -> void:
	if not err.contains("not configured"):
		chat_line(err if err != "" else "Co-op unavailable — playing solo")
	if not DmRtClient.is_retryable_error(err, "first") or not g.is_inside_tree():
		return
	start_reconnector("first")


func start_reconnector(mode: String) -> void:
	if reconnector != null:
		reconnector.stop()
	var r := DmRtReconnector.new(mode, func() -> DmResult:
		return await join_world(party_code if mode == "rejoin" else DmRtRejoinStore.load_rejoin(), mode))
	reconnector = r
	r.gave_up.connect(func(err: String) -> void:
		chat_line(err)
		if mode == "rejoin":
			g.toast("%s — the world continues solo" % err, "err"))
	r.start()


func gear_ids() -> Dictionary:
	var gear := {}
	var worn: Dictionary = DmGear.equipped_by_slot(g.inventory.slots)
	for slot in worn:
		if worn[slot] != null:
			gear[slot] = worn[slot]["item_id"]
	if String(g.my_cosmetics["cape"]) != "":
		gear["cape"] = g.my_cosmetics["cape"]
	if String(g.my_cosmetics["pet"]) != "":
		gear["pet"] = g.my_cosmetics["pet"]
	return gear


## One join attempt: connect, then the setup the first join always did. Returns the DmResult (failure = nothing changed).
func join_world(code: String, mode: String) -> DmResult:
	var req := {"characterId": g.hero_id, "classIndex": int(g.character["class_index"]), "level": int(g.character["level"]),
		"x": g.player.x, "z": g.player.z, "facing": g.player.facing, "gear": gear_ids()}
	if code != "":
		req["instance"] = code
	var res: DmResult = await rt.connect_to_world(g.api.get_token(), req)
	if not res.ok:
		return res
	if not g.is_inside_tree():
		rt.disconnect_from_world()
		return res
	var data: Dictionary = res.data
	var old: String = g.self_id
	g.self_id = rt.self_id
	retag_self(old)
	# A rejoin starts from a clean slate: any avatar left from before the drop is replaced by the server's roster.
	var roster := {}
	for p in data.get("players", []):
		roster[String(p["id"])] = true
	for id in remotes.keys():
		_dispose_remote(id)
		if not roster.has(id):
			g.sim.remove_player(id)
	remotes.clear()
	for p in data.get("players", []):
		if String(p["id"]) != g.self_id:
			add_remote(p)
	if not rt.is_host():
		# Someone else owns the world: drop our local sim, mirror theirs.
		become_guest(data.get("snapshot"))
	party_code = "" if data.get("solo", false) else String(data["instance"])
	if party_code != "":
		DmRtRejoinStore.save_rejoin(party_code)
	else:
		DmRtRejoinStore.clear_rejoin()
	reconnector = null
	var n: int = remotes.size() + 1
	if mode == "rejoin":
		reconnect_toasted = false
		if party_code != "":
			var msg := "Back in party %s (%d player%s)" % [party_code, n, "s" if remotes.size() > 0 else ""]
			chat_line(msg + (" — you keep the world" if rt.is_host() else ""))
			g.toast(msg, "good")
		else:
			g.toast("Back online (playing solo)", "good")
		broadcast_gear(true)
	elif party_code != "":
		chat_line("Joined party %s (%d player%s)%s" % [party_code, n, "s" if remotes.size() > 0 else "", " — you keep the world" if rt.is_host() else ""])
	return res


# ---- sim <-> mirror --------------------------------------------------------------------------------------------------------------

func _swap_sim(s: DmWorldSim) -> void:
	g.sim = s
	if g.abilities != null:
		g.abilities.sim = s


func become_guest(snapshot: Variant) -> void:
	mirror = DmSimMirror.new()
	if snapshot is Dictionary:
		mirror.apply_snapshot(snapshot)
	var f := DmWorldSim.new(g.nav, DmRng.new(1))
	f.set_crypts(g._sim_world["crypts"])
	f.set_cover(g._sim_world["cover"])
	f.set_nodes(g._sim_world["nodes"])
	_swap_sim(f)
	sync_facade()


## The facade's readers see the mirror's world.
func sync_facade() -> void:
	var f: DmWorldSim = g.sim
	f.enemies = mirror.enemies
	f.thralls = mirror.thralls
	f.corpses = mirror.corpses
	f.zones = mirror.zones
	f.waveTier = mirror.waveTier
	f.difficulty = mirror.difficulty
	f.vows = mirror.vows
	f.time = mirror.time
	var bs: Variant = mirror.bossState
	if bs != null:
		if String(bs.id) != "" and f.bosses.has(String(bs.id)):
			f.bossId = String(bs.id)
		f.boss.state = bs
	for id in f.nodes:
		var n: Dictionary = f.nodes[id]
		n["remaining"] = 0.0 if mirror.depleted.has(id) else 1.0


## Our own mirror has every event applied, so it seeds the new sim; the server's stored snapshot is only the fallback.
func become_authority(snapshot: Variant) -> void:
	if mirror == null:
		return
	var s := DmWorldSim.new(g.nav, DmRng.new(int(Time.get_ticks_usec()) & 0x7fffffff))
	s.omen = g.omen
	s.set_crypts(g._sim_world["crypts"])
	s.set_cover(g._sim_world["cover"])
	s.set_nodes(g._sim_world["nodes"])
	s.waveTier = float(g.prog.local["waveTierActive"])
	mirror.seed(s)
	for e in s.enemies.values():
		s.mark_visited(e.area)
	# The new keeper's difficulty runs the world from here on (new spawns).
	s.difficulty = String(g.settings["difficulty"])
	s.vows = DmAscension.world_vows(g.prog.vows())
	s.corpseLifeMult = float(g.prog.boons()["corpseLifeMult"])
	_swap_sim(s)
	mirror = null
	chat_line("You now keep the world (%s)" % String(DmContent.difficulty(s.difficulty)["name"]))


func retag_self(old: String) -> void:
	if g.abilities != null:
		g.abilities.self_id = g.self_id
	if mirror == null and old != g.self_id:
		g.sim.retag_player(old, g.self_id)


## Everyone else leaves our world (their bodies too: nobody left in the sim holds areas open) and we keep it ourselves.
func drop_coop_state() -> void:
	for id in remotes.keys():
		_dispose_remote(id)
		g.sim.remove_player(id)
	remotes.clear()
	become_authority(null)


# ---- per frame -------------------------------------------------------------------------------------------------------------------

## Before the sim step: a guest mirrors (no step).
func guest_update(dt: float) -> void:
	mirror.update(dt)
	sync_facade()


## After a host step: relay events, publish snapshots, send our position.
func host_publish(events: Array, now: float) -> void:
	if not connected():
		event_out.clear()
		return
	var wire: Array = []
	for ev in events:
		wire.append(DmSimSnapshot.wire_event(ev))
	event_out.push(wire, now)
	if now - _last_snapshot >= SNAPSHOT_MS:
		_last_snapshot = now
		_snapshot_count += 1
		rt.send_snapshot(DmSimSnapshot.make(g.sim, _snapshot_count % 20 == 0))


func send_move(now: float) -> void:
	if connected() and now - _last_move >= MOVE_SEND_MS:
		_last_move = now
		rt.send_move({"x": g.player.x, "z": g.player.z, "facing": g.player.facing, "moving": g.player.moving,
			"hpFrac": float(g.p["hp"]) / g.player.max_hp(), "level": int(g.character["level"])})


## Remote bodies ease toward their latest reported position.
func update_remotes(dt: float) -> void:
	var k := minf(1.0, dt * 10.0)
	for id in remotes:
		var r: Dictionary = remotes[id]
		r["x"] += (r["tx"] - r["x"]) * k
		r["z"] += (r["tz"] - r["z"]) * k
		var av: Variant = r.get("avatar")
		if av != null:
			av.update(dt, r["x"], r["z"], r["facing"], r["moving"], 5.4)
		if r.get("pet") != null:
			r["pet"].update(dt, r["x"], r["z"], r["facing"])


# ---- handlers --------------------------------------------------------------------------------------------------------------------

func _on_intent(env: Dictionary) -> void:
	if mirror != null or not is_authority():
		return
	var it: Dictionary = (env["intent"] as Dictionary).duplicate()
	it["by"] = env["from"]   # never trust the claimed caster; the server stamps `from`
	g.sim.apply(it)


func _on_events(batch: Array) -> void:
	if mirror == null:
		return
	mirror.apply_events(batch)
	for ev in batch:
		g.handle_event(ev)


func _on_player_join(p: Dictionary) -> void:
	add_remote(p)
	chat_line("%s entered the world" % p.get("name", "?"))


func _on_player_leave(id: String) -> void:
	var r: Variant = remotes.get(id)
	if r == null:
		return
	chat_line("%s left" % r["info"].get("name", "?"))
	_dispose_remote(id)
	remotes.erase(id)
	if mirror == null:
		g.sim.remove_player(id)


func _on_player_move(u: Dictionary) -> void:
	var r: Variant = remotes.get(String(u["id"]))
	if r == null:
		return
	r["tx"] = float(u["x"])
	r["tz"] = float(u["z"])
	r["facing"] = float(u["facing"])
	r["moving"] = bool(u["moving"])
	r["hpFrac"] = float(u["hpFrac"])
	if u.get("level"):
		r["info"]["level"] = u["level"]
		r["level"] = u["level"]


func _on_player_gear(u: Dictionary) -> void:
	var r: Variant = remotes.get(String(u["id"]))
	if r != null and r.get("avatar") != null:
		r["avatar"].set_equipment(gear_from_ids(u.get("gear")))
		dress_remote(r, u.get("gear"))


## Another player's cape and companion, from the ids they broadcast (checked against the catalogue).
func dress_remote(r: Dictionary, gear: Variant) -> void:
	var cape := ""
	var pet := ""
	if gear is Dictionary:
		for c in DmContent.get_export("cosmetics", "CAPES"):
			if c["id"] == gear.get("cape"):
				cape = c["id"]
		pet = String(gear.get("pet", ""))
	if r.get("avatar") != null:
		r["avatar"].set_cape(cape)
	var def: Variant = g._pet_def(pet)
	var cur: Variant = r.get("pet")
	if (cur.id() if cur != null else "") != (String(def["id"]) if def != null else ""):
		if cur != null:
			cur.dispose()
			r["pet"] = null
		if def != null and g.visual:
			r["pet"] = DmPetView.new(g.world_root, def, r["tx"], r["tz"])


## The link dropped unexpectedly: carry on solo and keep trying to get back to the same world.
func _on_disconnect() -> void:
	drop_coop_state()
	if not g.is_inside_tree():
		return
	if not reconnect_toasted:
		reconnect_toasted = true
		g.toast("Reconnecting to the world… (playing solo meanwhile)", "err")
	start_reconnector("rejoin")


# ---- remote players --------------------------------------------------------------------------------------------------------------

static func gear_from_ids(ids: Variant) -> Dictionary:
	var out := {}
	if ids is Dictionary:
		for slot in ids:
			if slot in SLOT_IDS and ids[slot] is String:
				out[slot] = {"item_id": ids[slot]}
	return out


func add_remote(p: Dictionary) -> void:
	var id := String(p["id"])
	if remotes.has(id) or id == g.self_id:
		return
	var d: Dictionary = DmCharacterBuild.discipline_for(float(p.get("classIndex", 0)))
	var dd: Dictionary = DmContent.discipline(String(d["id"]))
	var av: Variant = null
	if g.visual:
		var cls: Variant = load("res://game/dm_avatar.gd")
		av = cls.new()
		av.settings = g.settings
		av.setup(g.world_root, dd.get("color", 0xa26bff), false, String(dd.get("modelSlug", "necromancer")))
		av.set_equipment(gear_from_ids(p.get("gear")))
	remotes[id] = {"info": p, "avatar": av, "x": float(p["x"]), "z": float(p["z"]), "tx": float(p["x"]), "tz": float(p["z"]), "facing": float(p.get("facing", 0.0)),
		"moving": false, "hpFrac": float(p.get("hpFrac", 1.0)), "level": p.get("level", 1), "family": d["family"], "pet": null}
	if g.visual:
		dress_remote(remotes[id], p.get("gear"))


func _dispose_remote(id: String) -> void:
	var r: Variant = remotes.get(id)
	if r != null and r.get("pet") != null:
		r["pet"].dispose()
	if r != null and r.get("avatar") != null and is_instance_valid(r["avatar"]):
		r["avatar"].queue_free()


## Tell the world what we're wearing (item ids only), when it changes and once after joining.
func broadcast_gear(force: bool = false) -> void:
	var gear := gear_ids()
	var key := JSON.stringify(gear)
	if not force and key == _last_gear:
		return
	_last_gear = key
	if connected():
		rt.send_gear(gear)


# ---- parties ---------------------------------------------------------------------------------------------------------------------

## Make a new party: a short code friends type in (Settings -> Play together, or /party <code>).
func create_party() -> void:
	var code := ""
	for i in 6:
		code += PARTY_ALPHABET[randi() % PARTY_ALPHABET.length()]
	await join_party(code, true)


## Join (or make) the party with this invite code. Leaves the current world first; on failure carries on where we were.
func join_party(raw: String, created: bool = false) -> void:
	var rx := RegEx.create_from_string("[^a-z0-9-]")
	var code := rx.sub(raw.strip_edges().to_lower(), "", true).left(12)
	if code == "":
		g.toast("Enter a party code (letters and numbers).", "err")
		return
	if g.depths != null and g.depths.active():
		g.toast("Finish your descent first: the Depths are a solo run.", "err")
		return
	if code == party_code and connected():
		g.toast("You are already in party %s." % code, "err")
		return
	var before := party_code
	_stop_reconnector()
	rt.disconnect_from_world()
	drop_coop_state()
	party_code = ""
	var res := await join_world(code, "first")
	if res.ok:
		g.toast("Party %s made: tell your friends to join with this code" % code if created else "Joined party %s" % code, "good")
		if created:
			chat_line("Your party code is %s. Friends join it in Settings -> Play together, or by typing /party %s." % [code, code])
		return
	g.toast(res.error if res.error != "" else "Could not join that party", "err")
	# Back to where we were: the old party (if any), else a solo world.
	var res2 := await join_world(before, "first")
	if not res2.ok:
		party_code = before
		first_failed(res2.error)


## Leave the party and play in our own world again.
func leave_party() -> void:
	if party_code == "":
		g.toast("You are not in a party.", "err")
		return
	if g.depths != null and g.depths.active():
		g.toast("Finish your descent first.", "err")
		return
	_stop_reconnector()
	rt.disconnect_from_world()
	drop_coop_state()
	party_code = ""
	DmRtRejoinStore.clear_rejoin()
	chat_line("You left the party and play solo.")
	var res := await join_world("", "first")
	if not res.ok:
		first_failed(res.error)


func _stop_reconnector() -> void:
	if reconnector != null:
		reconnector.stop()
	reconnector = null


## Step out of the party for a solo-only activity (the Depths): leave its world, keep the code, become keeper of our own.
func pause() -> void:
	if party_code == "" or paused:
		return
	paused = true
	_stop_reconnector()
	rt.disconnect_from_world()
	drop_coop_state()
	chat_line("You step out of party %s for the descent; you rejoin when it ends." % party_code)


## The solo activity is over: go back to the party we stepped out of.
func resume() -> void:
	if not paused:
		return
	paused = false
	if not g.is_inside_tree() or party_code == "":
		return
	reconnect_toasted = true   # the rejoin says so itself ("Back in party ...")
	start_reconnector("rejoin")


## `/party [code]`, `/solo`, `/leave`: the chat-line way to the same three actions. True when the line was a command.
func chat_command(text: String) -> bool:
	var m := RegEx.create_from_string("^/(party|solo|leave)(?:\\s+(\\S+))?\\s*$").search(text.strip_edges().to_lower())
	if m == null:
		return false
	var cmd := m.get_string(1)
	var arg := m.get_string(2)
	if cmd != "party":
		leave_party()
	elif arg != "":
		join_party(arg)
	elif party_code != "":
		chat_line("Your party code is %s. Friends join with /party %s. /solo leaves it." % [party_code, party_code])
	else:
		create_party()
	return true


func send_chat(text: String) -> void:
	if chat_command(text):
		return
	if connected():
		rt.send_chat(text)
	else:
		chat_line("(solo) Nobody hears you in the dark.")


func dispose() -> void:
	_stop_reconnector()
	rt.disconnect_from_world()
