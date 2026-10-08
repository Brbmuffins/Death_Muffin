extends Node
## AudioDirector: the Godot port of src/audio/Audio.ts (AudioEngine). Register as an autoload named "AudioDirector"
## (project.godot: AudioDirector="*res://audio/audio_director.gd"). Public API is documented in godot/audio/README.md.
##
## Buses (created at runtime, no bus layout file): Master <- Combat, Enemies, Thralls, Ui, Ambience, Music. Every sound plays on a
## pooled AudioStreamPlayer routed through a per-voice pan bus into its category bus. All maths (caps, thinning, repeats,
## ducking, distance) is DmAudioMixer; music decisions are DmMusicState; this node only runs them.

signal sfx_played(sfx_name: String)

const BUS_NAMES := {"combat": "Combat", "enemies": "Enemies", "thralls": "Thralls", "ui": "Ui", "ambience": "Ambience"}
const MUSIC_BUS := "Music"
const MAX_VOICES := 48
const BED_GAIN := 0.55
## Minimum gap (s) for ids the recorded map does not define (the map's cooldownMs wins when it does).
const MIN_GAP := {
	"needleHit": 0.04, "boneHit": 0.05, "emberBurst": 0.07, "emberCrackle": 0.05, "chainTier": 0.3, "chainBreak": 0.5, "emberThrow": 0.15,
	"slagSlam": 0.2, "enemyDeath": 0.06, "coin": 0.05, "hurt": 0.12, "step": 0.2, "wail": 0.08, "tollSmall": 0.25, "wave": 0.8, "flail": 0.12,
	"palm": 0.12, "crow": 0.35, "distantBell": 3.0, "graveCreak": 3.0, "waterDrip": 0.5, "panelOpen": 0.08, "panelClose": 0.08, "equip": 0.15,
	"lootRare": 0.4, "lootEpic": 0.8, "reel": 0.3, "craft": 0.2, "crowCaw": 4.0, "windGust": 6.0, "crowdMoan": 6.0, "bogBubble": 0.6, "dustFall": 1.5,
}

## Co-op: set while handling a remote player's events (their sounds are quieter, near-only and capped to 4 per 0.5 s).
var partner := false
var settings: Dictionary = DmAudioMixer.normalize_settings({})
## Set >= 0 to drive the clock by hand (tests); otherwise engine time is used.
var time_override := -1.0
var rng := RandomNumberGenerator.new()
var bank := DmSampleBank.new()
var music: DmMusicDirector

var _listener := Vector2.ZERO
var _limiter := DmAudioMixer.VoiceLimiter.new()
var _repeats := DmAudioMixer.WindowCounter.new()
var _thin := DmAudioMixer.WindowCounter.new()
var _partner_win := DmAudioMixer.WindowCounter.new()
var _id_limiter := DmAudioMixer.IdLimiter.new()
var _activity := DmAudioMixer.CombatActivity.new()
var _last: Dictionary = {}
var _duck_state := {"depth": 0.0, "until": 0.0}
var _ducks: Dictionary = {}  # bus id -> {depth, hold, release, t}
var _voices: Array = []  # {player, pan_bus, end, fade_at, base_v, active}
var _scheduled: Array = []  # delayed layer starts
var _loops: Dictionary = {}
var _loop_next_id := 1
var _played := 0
var _sample_hits := 0
var _duck_count := 0
var _drops := {"far": 0, "repeat": 0, "thin": 0, "bus": 0, "global": 0, "gap": 0, "id": 0, "partner": 0}
var _forced_combat := false
var _last_pick_rng := 0.0

var _want_area := ""
var _area_trail: Array[String] = []
var _bed: Dictionary = {}  # {area, layers:[{player,gain}], gain, target, tau, kind}
var _old_beds: Array = []
var _bed_duck := 1.0
var _bed_duck_target := 1.0
var _bed_tick := 0.0
var _last_duck_apply := -1.0
var _accent_timer := -1.0
var _accent_retry := false
var _boss_bed: AudioStreamPlayer
var _boss_bed_gain := 0.0
var _boss_bed_target := 0.0
var _lp_buses: Dictionary = {}
var _footsteps := DmFootstepTracker.new()
var _ready_done := false


func _ready() -> void:
	setup()


## Build buses, music and start loading samples. Called from _ready (idempotent).
func setup() -> void:
	if _ready_done:
		return
	_ready_done = true
	rng.randomize()
	_ensure_buses()
	# The voice players + their pan buses up front: each new bus re-lays the whole AudioServer layout (1-3 ms), which otherwise
	# landed on the first big fights as voices were created on demand.
	while _voices.size() < MAX_VOICES:
		_new_voice()
	music = DmMusicDirector.new()
	music.name = "Music"
	music.bus_name = MUSIC_BUS
	music.set_process(false)
	add_child(music)
	bank.queue_legacy()
	# Pack order: hits and hurt first, then the area the player stands in, then the rest, all off the critical path.
	bank.queue_pack("core")
	for p in DmAudioPacks.GLOBAL_PACKS:
		if p != "core":
			bank.queue_pack(p)
	apply_settings(settings)


func _ensure_buses() -> void:
	for id in DmAudioMixer.BUS_IDS:
		_make_bus(BUS_NAMES[id], "Master", true)
	_make_bus(MUSIC_BUS, "Master", false)
	var m := 0
	# Master: gentle compressor then a brick-wall limiter, as the web chain (buses -> compressor -> master -> limiter).
	if AudioServer.get_bus_effect_count(m) == 0:
		var comp := AudioEffectCompressor.new()
		comp.threshold = -18.0
		comp.ratio = 3.0
		comp.attack_us = 6000.0
		comp.release_ms = 250.0
		AudioServer.add_bus_effect(m, comp)
		var lim: AudioEffect
		if ClassDB.class_exists("AudioEffectHardLimiter"):
			lim = ClassDB.instantiate("AudioEffectHardLimiter")
			lim.set("ceiling_db", -3.0)
			lim.set("release", 0.12)
		else:
			lim = AudioEffectLimiter.new()
			(lim as AudioEffectLimiter).ceiling_db = -3.0
		AudioServer.add_bus_effect(m, lim)


func _make_bus(bus_name: String, send: String, reverb: bool) -> int:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		return idx
	AudioServer.add_bus()
	idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, send)
	if reverb:
		# stands in for the web's per-voice reverb send (wet 0.3 into a 2.8 s impulse at gain 0.32)
		var r := AudioEffectReverb.new()
		r.room_size = 0.75
		r.damping = 0.55
		r.wet = 0.1
		r.dry = 1.0
		AudioServer.add_bus_effect(idx, r)
	return idx


# --- clock / rng -----------------------------------------------------------------

func _now() -> float:
	return time_override if time_override >= 0.0 else float(Time.get_ticks_msec()) / 1000.0


func seed_rng(s: int) -> void:
	rng.seed = s


# --- settings ----------------------------------------------------------------------

## Apply slider settings: web keys (volume, combatVolume, ambienceVolume, musicVolume, interfaceVolume) or the settings panel's
## vol_master / vol_combat / vol_amb / vol_music / vol_ui. Call on startup and whenever a slider changes.
func apply_settings(s: Dictionary) -> void:
	settings = DmAudioMixer.normalize_settings(s)
	if not _ready_done:
		return
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(DmAudioMixer.master_gain(settings), 0.0001)))
	_apply_bus_levels()
	music.set_volume_slider(settings["musicVolume"])


func _apply_bus_levels() -> void:
	for id in DmAudioMixer.BUS_IDS:
		var g := DmAudioMixer.bus_gain(id, settings)
		var duck := 1.0
		if _ducks.has(id):
			var d: Dictionary = _ducks[id]
			duck = DmAudioMixer.duck_factor(d["depth"], d["hold"], d["release"], d["t"])
		# Set only when the level actually moved: AudioServer takes the mixer lock for every set, and these levels sit still almost
		# all the time (they were rewritten every frame, ~6 locked sets a frame against the audio thread).
		var bus := AudioServer.get_bus_index(BUS_NAMES[id])
		var db := linear_to_db(maxf(g * duck, 0.0001))
		if absf(AudioServer.get_bus_volume_db(bus) - db) >= 0.005:
			AudioServer.set_bus_volume_db(bus, db)


# --- listener -------------------------------------------------------------------------

## The listener's ground position (the hero): world x and z.
func set_listener(x: float, z: float) -> void:
	_listener = Vector2(x, z)


func set_listener_pos(p: Vector3) -> void:
	_listener = Vector2(p.x, p.z)


static func _xz(pos: Variant) -> Variant:
	if pos is Vector3:
		return Vector2(pos.x, pos.z)
	if pos is Vector2:
		return pos
	return null


# --- sfx ---------------------------------------------------------------------------------

## Play a sound by Sfx id. `pos` is a Vector3 (x,z used) / Vector2 (x,z) or null for head-relative (UI, stingers).
## `intensity` scales volume (max 1.5). Returns true when a clip actually started.
func play_sfx(sfx_name: String, pos: Variant = null, intensity: float = 1.0) -> bool:
	if not _ready_done or _voice_count() > MAX_VOICES:
		return false
	var now := _now()
	var prof := DmAudioMixer.profile_of(sfx_name)
	var def := DmAudioMap.defn(sfx_name)
	var p: Variant = _xz(pos)
	if not def.is_empty() and not bool(def["spatial"]):
		p = null
	var gap: float = float(def["cooldownMs"]) / 1000.0 if not def.is_empty() else float(MIN_GAP.get(sfx_name, 0.0))
	if gap > 0.0 and now - float(_last.get(sfx_name, -1.0)) < gap:
		_drops["gap"] += 1
		return false
	var distance := 0.0
	if p != null:
		distance = (p as Vector2).distance_to(_listener)
		if DmAudioMixer.culled(distance, prof["bus"], int(prof["priority"])):
			_drops["far"] += 1
			return false
	var pg := 1.0
	if partner:
		if not DmAudioMixer.partner_audible(distance) or _partner_win.count("p", now, 0.5) >= 4:
			_drops["partner"] += 1
			return false
		pg = DmAudioMixer.partner_gain("step" if sfx_name.begins_with("step") else "spell")
		_partner_win.add("p", now)
	var repeats := _repeats.count(sfx_name, now, DmAudioMixer.REPEAT_WINDOW)
	if DmAudioMixer.repeat_dropped(repeats, int(prof["priority"])):
		_drops["repeat"] += 1
		return false
	var thin_key := ("thin:" + str(prof["bus"])) if prof.has("thin") else ""
	if prof.has("thin") and _thin.count(thin_key, now, prof["thin"]["window"]) >= int(prof["thin"]["max"]):
		_drops["thin"] += 1
		return false
	if not def.is_empty() and not _id_limiter.request(sfx_name, now, minf(float(prof["dur"]), DmAudioPacks.cap_seconds(sfx_name)), int(def["maxVoices"]), 0.0):
		_drops["id"] += 1
		return false
	if _limiter.request(prof["bus"], int(prof["priority"]), now, float(prof["dur"])) != "":
		return false  # counted by the limiter
	_last[sfx_name] = now
	_repeats.add(sfx_name, now)
	if thin_key != "":
		_thin.add(thin_key, now)
	_played += 1
	var weight := DmAudioMixer.activity_weight(prof["bus"], int(prof["priority"]))
	if weight > 0.0:
		_activity.bump(now, weight)
		if now - _last_duck_apply > 0.1:
			_last_duck_apply = now
			_apply_bed_duck(now)
	if prof.has("duck") and not partner:
		_duck(prof["duck"], now)
	var ctx := {"bus": prof["bus"], "gain": DmAudioMixer.repeat_gain(repeats), "pos": p}
	var share := _recorded(sfx_name, def, ctx, intensity, pg)
	if sfx_name == "bossAwaken":
		_set_boss_bed(true)
	elif sfx_name == "bossDefeat":
		_set_boss_bed(false)
	if share < 1.0:
		sfx_played.emit(sfx_name)
	return share < 1.0


## Rite beds made of re-triggered one-shots: plays `sfx_name` every loopMs for `ms` milliseconds. `follow` (optional) is a Callable
## returning a Vector3/Vector2 to track or null to stop. Returns a handle for stop_loop().
func loop_sfx(sfx_name: String, ms: float, pos: Variant = null, follow: Callable = Callable()) -> int:
	var every := float(DmAudioMap.defn(sfx_name).get("loopMs", 1500.0)) / 1000.0
	var id := _loop_next_id
	_loop_next_id += 1
	var l := {"name": sfx_name, "every": every, "end": _now() + ms / 1000.0, "next": _now() + every, "pos": pos, "follow": follow}
	_loops[id] = l
	_loop_tick(id)
	return id


func stop_loop(handle: int) -> void:
	_loops.erase(handle)


func _loop_tick(id: int) -> void:
	var l: Dictionary = _loops[id]
	var at: Variant = l["pos"]
	if (l["follow"] as Callable).is_valid():
		at = (l["follow"] as Callable).call()
		if at == null:
			_loops.erase(id)
			return
	play_sfx(l["name"], at)


## A footstep for a surface id (`stepStone` / `stepDirt` / `stepGrass` / `stepWater`) at the player's feet.
func footstep(step_id: String, pos: Variant, gain: float = 1.0) -> void:
	play_sfx(step_id, pos, gain)


## Per-frame hero footsteps: feed the walk loop's phase (0..1, or -1 without one), position, the area id, whether the hero wades
## and whether the clip is a run. Plays the surface step when a foot lands. Call hero_stopped() when the hero stops moving.
func hero_footfall(phase: float, x: float, z: float, area_id: String, wet: bool = false, running: bool = false) -> void:
	if _footsteps.step(phase, x, z):
		var surface := "water" if wet else DmAudioMap.area_surface(area_id)
		footstep(DmAudioMap.step_sound(surface), Vector2(x, z), DmAudioMap.area_step_gain(area_id) * (1.25 if running else 1.0))


func hero_stopped() -> void:
	_footsteps.reset()


## The sound of one gathering work cycle (DmGatherSfx), positional.
func gather(skill: String, kind: String = "", pos: Variant = null) -> void:
	play_sfx(DmGatherSfx.gather_sfx(skill, kind), pos)


## The loot sound for the rarities picked up this frame (e.g. ["common","epic"] -> lootEpic).
func play_loot(rarities: Array) -> void:
	play_sfx(DmAudioMixer.loot_sfx(rarities))


# --- voices ---------------------------------------------------------------------------------

func _voice_count() -> int:
	var n := 0
	for v in _voices:
		if v["active"]:
			n += 1
	return n


## An idle voice, preferring one already sending to `send` (re-routing a voice is a set_bus_send, which re-lays every bus).
func _acquire_voice(send: StringName = &"") -> Dictionary:
	var any: Dictionary = {}
	for v in _voices:
		if not v["active"]:
			if send == &"" or v.get("send", &"") == send:
				return v
			if any.is_empty():
				any = v
	if not any.is_empty():
		return any
	if _voices.size() >= MAX_VOICES * 2:
		return {}
	return _new_voice()


func _new_voice() -> Dictionary:
	var p := AudioStreamPlayer.new()
	add_child(p)
	var bus_name := "DmPan%d" % _voices.size()
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.add_bus_effect(idx, AudioEffectPanner.new())
	p.bus = bus_name
	var v := {"player": p, "pan_bus": bus_name, "end": 0.0, "fade_at": INF, "base_v": 1.0, "active": false}
	_voices.append(v)
	return v


func _start_clip(stream: AudioStream, vol: float, rate: float, jitter: float, ctx: Dictionary, delay: float, cap_s: float) -> void:
	if delay > 0.0:
		_scheduled.append({"at": _now() + delay, "stream": stream, "vol": vol, "rate": rate, "jitter": jitter, "ctx": ctx, "cap": cap_s})
		return
	_play_clip(stream, vol, rate, jitter, ctx, cap_s)


func _play_clip(stream: AudioStream, vol: float, rate: float, jitter: float, ctx: Dictionary, cap_s: float) -> void:
	var send: StringName = BUS_NAMES[ctx["bus"]]
	var v := _acquire_voice(send)
	if v.is_empty():
		return
	var r := rate * (1.0 + (rng.randf() * 2.0 - 1.0) * jitter)
	var g: float = vol * float(ctx["gain"]) * float(ctx.get("trim", 1.0))
	var pan := 0.0
	var p: Variant = ctx["pos"]
	if p != null:
		var d: Vector2 = (p as Vector2) - _listener
		g *= DmAudioMixer.distance_gain(d.length(), ctx["bus"])
		pan = DmAudioMixer.pan_for(d.x)
	# set_bus_send re-lays the whole bus layout (every player re-resolves its bus): only when this voice's send really changes.
	var bus_idx: int = v.get("bus_idx", -1)
	if bus_idx < 0 or AudioServer.get_bus_name(bus_idx) != v["pan_bus"]:
		bus_idx = AudioServer.get_bus_index(v["pan_bus"])
		v["bus_idx"] = bus_idx
	if AudioServer.get_bus_send(bus_idx) != send:
		AudioServer.set_bus_send(bus_idx, send)
	v["send"] = send
	(AudioServer.get_bus_effect(bus_idx, 0) as AudioEffectPanner).pan = pan
	var pl: AudioStreamPlayer = v["player"]
	pl.stream = stream
	pl.pitch_scale = maxf(r, 0.05)
	pl.volume_db = linear_to_db(maxf(g, 0.0001))
	pl.play()
	var len_s := stream.get_length() / maxf(r, 0.05)
	var now := _now()
	v["active"] = true
	v["base_v"] = g
	v["fade_at"] = INF
	if len_s > cap_s + 0.05:
		# The file is long for this id (a clip shared with a boss moment): fade it out at the id's own cap.
		v["fade_at"] = now + cap_s - 0.12
		len_s = cap_s
	v["end"] = now + len_s + 0.02
	_sample_hits += 1


## Play the recorded layer of a sound. Returns the share of a synthesised sound still wanted underneath (the web's synth is not
## ported, so callers only use 0 = the clip is the sound, 1 = nothing played).
func _recorded(sfx_name: String, def: Dictionary, ctx: Dictionary, intensity: float, pg: float) -> float:
	var inten := minf(1.5, intensity)
	if def.is_empty() or DmSampleBank.is_kept(sfx_name):
		return _legacy(sfx_name, ctx, inten, pg, 1.0)
	var hit := bank.pick(sfx_name, rng.randf())
	if hit.is_empty():
		return _legacy(sfx_name, ctx, inten, pg, 1.0)
	var vol: float = float(def["volume"]) * (0.88 + rng.randf() * 0.12) * inten * pg
	var cap := DmAudioPacks.cap_seconds(sfx_name)
	var rate := float(def.get("rate", 1.0))
	_start_clip(hit["stream"], vol, rate, float(def["pitchJitter"]), ctx, 0.0, cap)
	if def.has("layer"):
		var ls := bank.pick_layer(sfx_name, rng.randf())
		if ls != null:
			_start_clip(ls, float(def["layer"]["volume"]) * inten * pg, rate, float(def["pitchJitter"]), ctx, float(def["layer"]["delayMs"]) / 1000.0, cap)
	if not DmSampleBank.is_partial(sfx_name):
		return 0.0
	var l := bank.pick_legacy(sfx_name, rng.randf())
	if not l.is_empty():
		var spec: Dictionary = l["spec"]
		_start_clip(l["stream"], float(spec["gain"]) * 0.8 * pg * inten, float(spec.get("rate", 1.0)), float(spec.get("jitter", 0.06)), ctx, 0.0, 4.0)
	return 0.0


func _legacy(sfx_name: String, ctx: Dictionary, inten: float, pg: float, none_value: float) -> float:
	var l := bank.pick_legacy(sfx_name, rng.randf())
	if l.is_empty():
		return none_value
	var spec: Dictionary = l["spec"]
	_start_clip(l["stream"], float(spec["gain"]) * (0.88 + rng.randf() * 0.12) * inten * pg, float(spec.get("rate", 1.0)), float(spec.get("jitter", 0.06)), ctx, 0.0, 4.0)
	return 0.0


# --- ducking / combat -------------------------------------------------------------------------

func _duck(d: Dictionary, now: float) -> void:
	if now < float(_duck_state["until"]) and float(d["depth"]) < float(_duck_state["depth"]):
		return
	_duck_state = {"depth": d["depth"], "until": now + float(d["hold"])}
	_duck_count += 1
	_ducks["thralls"] = {"depth": d["depth"], "hold": d["hold"], "release": d["release"], "t": 0.0}
	_ducks["enemies"] = {"depth": d.get("voice", d["depth"]), "hold": d["hold"], "release": d["release"], "t": 0.0}
	if d.has("ambience") and float(d["ambience"]) > 0.0:
		_ducks["ambience"] = {"depth": d["ambience"], "hold": d["hold"], "release": d["release"], "t": 0.0}
	music.duck_for_cue(minf(0.65, float(d.get("ambience", d["depth"]))), d["hold"], d["release"])


## Force the "a fight is on" state (ducks the beds and music as a heavy fight would). Off by default: the web derives combat
## activity purely from the sounds played, which this port keeps; this is an optional override for scripted moments.
func set_combat(active: bool) -> void:
	_forced_combat = active


func combat_level() -> float:
	var l := _activity.level(_now())
	return maxf(l, 1.0) if _forced_combat else l


func _apply_bed_duck(now: float) -> void:
	var lvl := combat_level()
	_bed_duck_target = DmAudioMixer.bed_duck_gain(lvl)
	music.set_combat_level(lvl)


# --- ambience, area, music --------------------------------------------------------------------

## Enter an area: crossfades the zone bed, switches music, schedules sparse accents and (re)loads the area's packs.
func set_area(area_id: String, force: bool = false) -> void:
	_want_area = area_id
	music.set_area(area_id)
	if not force:
		_sync_area_packs(area_id)
	if not _bed.is_empty() and _bed["area"] == area_id and not force:
		return
	if not _bed.is_empty():
		_bed["target"] = 0.0
		_bed["tau"] = 0.8
		_bed["dispose_in"] = 4.0
		_old_beds.append(_bed)
	_bed = _build_bed(area_id)
	_accent_timer = DmAudioAmbience.accent_gap(area_id, rng.randf()) * 0.5
	_accent_retry = false


func current_area() -> String:
	return _want_area


## Leave the world (title / death screen): fades beds, stops accents and the boss score.
func stop_area() -> void:
	_want_area = ""
	music.set_area("")
	_accent_timer = -1.0
	if not _bed.is_empty():
		_bed["target"] = 0.0
		_bed["tau"] = 0.5
		_bed["dispose_in"] = 3.0
		_old_beds.append(_bed)
	_bed = {}
	_set_boss_bed(false)


## Boss score follows the local area's active boss (including rejoin snapshots).
func set_boss_music(active: bool) -> void:
	music.set_boss(active)


func music_cue() -> String:
	return music.current_cue()


func _build_bed(area_id: String) -> Dictionary:
	var bed: Dictionary = DmAudioAmbience.ZONE_BEDS[area_id]
	var recorded := DmAudioAmbience.bed_ready(area_id, func(f: String) -> bool: return bank.has(f))
	var layers: Array = []
	if recorded:
		for l in bed["loops"]:
			var s := bank.stream(l["file"])
			if s is AudioStreamOggVorbis:
				(s as AudioStreamOggVorbis).loop = true
			var p := AudioStreamPlayer.new()
			p.stream = s
			p.pitch_scale = float(l["rate"])
			p.bus = _lp_bus(int(l["lp"]))
			add_child(p)
			p.volume_db = -80.0
			p.play(rng.randf() * s.get_length())  # random start so two layers of one file never phase together
			layers.append({"player": p, "gain": float(l["gain"]) * DmAudioAmbience.LOOP_TRIM})
	for d in bed["drones"]:
		var dr := DmAudioSynth.drone(float(d[0]))
		var p := AudioStreamPlayer.new()
		p.stream = dr["stream"]
		p.bus = BUS_NAMES["ambience"]
		add_child(p)
		p.volume_db = -80.0
		p.play()
		layers.append({"player": p, "gain": float(d[1]) * float(dr["peak"])})
	return {"area": area_id, "layers": layers, "gain": 0.0, "target": 1.0, "tau": 1.2, "dispose_in": -1.0, "kind": "loops" if recorded else "synth"}


## Bus for a layer's low-pass (0 = none): a tiny bus per cutoff, sending into Ambience.
func _lp_bus(hz: int) -> String:
	if hz <= 0:
		return BUS_NAMES["ambience"]
	var bus_name := "DmBedLP%d" % hz
	if not _lp_buses.has(hz):
		var idx := AudioServer.get_bus_index(bus_name)
		if idx < 0:
			AudioServer.add_bus()
			idx = AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, BUS_NAMES["ambience"])
			var f := AudioEffectLowPassFilter.new()
			f.cutoff_hz = float(hz)
			AudioServer.add_bus_effect(idx, f)
		_lp_buses[hz] = true
	return bus_name


## A slow war-drum pulse under boss fights (bossAwaken starts it; bossDefeat / stop_area end it).
func _set_boss_bed(on: bool) -> void:
	if on:
		if _boss_bed != null:
			_boss_bed_target = 1.0
			return
		_boss_bed = AudioStreamPlayer.new()
		_boss_bed.stream = DmAudioSynth.boss_drum()
		_boss_bed.bus = BUS_NAMES["ambience"]
		_boss_bed.volume_db = -80.0
		add_child(_boss_bed)
		_boss_bed.play()
		_boss_bed_target = 1.0
		_boss_bed_gain = 1.0
		_boss_bed.volume_db = linear_to_db(BED_GAIN)
	else:
		_boss_bed_target = 0.0


func boss_bed_active() -> bool:
	return _boss_bed != null and _boss_bed_target > 0.0


func _sync_area_packs(area_id: String) -> void:
	if _area_trail.is_empty() or _area_trail[0] != area_id:
		var t: Array[String] = [area_id]
		for a in _area_trail:
			if a != area_id:
				t.append(a)
		_area_trail = t.slice(0, 2)
	var keep := {}
	for a in _area_trail:
		for p in DmAudioPacks.area_packs(a):
			keep[p] = true
	for pack in bank.loaded_packs():
		if (pack.begins_with("foot_") or pack.begins_with("fam_") or pack == "boss") and not keep.has(pack):
			bank.release_pack(pack)
	for p in DmAudioPacks.area_packs(area_id):
		bank.queue_pack(p)


# --- frame --------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	advance(delta)


## Advance everything by `delta` seconds (called by _process; tests call it directly with time_override set).
func advance(delta: float) -> void:
	if not _ready_done:
		return
	var now := _now()
	var queued_before := bank.pending()
	bank.pump(6)
	# the recorded beds arrived after a synthesised-less start: rebuild the current area once its loops are ready
	if _want_area != "" and not _bed.is_empty() and _bed["kind"] != "loops" and DmAudioAmbience.bed_ready(_want_area, func(f: String) -> bool: return bank.has(f)):
		set_area(_want_area, true)
	elif queued_before > 0 and _want_area != "" and _bed.is_empty():
		set_area(_want_area, true)
	# delayed layer starts
	for i in range(_scheduled.size() - 1, -1, -1):
		var s: Dictionary = _scheduled[i]
		if now >= float(s["at"]):
			_scheduled.remove_at(i)
			_play_clip(s["stream"], s["vol"], s["rate"], s["jitter"], s["ctx"], s["cap"])
	# voice life: tail fades and release
	for v in _voices:
		if not v["active"]:
			continue
		if now >= float(v["end"]):
			(v["player"] as AudioStreamPlayer).stop()
			v["active"] = false
		elif now >= float(v["fade_at"]):
			var k := clampf(1.0 - (now - float(v["fade_at"])) / 0.12, 0.0, 1.0)
			(v["player"] as AudioStreamPlayer).volume_db = linear_to_db(maxf(float(v["base_v"]) * k, 0.0001))
	# rite loops
	for id in _loops.keys():
		var l: Dictionary = _loops[id]
		if now >= float(l["end"]):
			_loops.erase(id)
		elif now >= float(l["next"]):
			l["next"] = float(l["next"]) + float(l["every"])
			_loop_tick(id)
	# ducks
	for bus in _ducks.keys():
		var d: Dictionary = _ducks[bus]
		d["t"] = float(d["t"]) + delta
		if float(d["t"]) > float(d["hold"]) + 8.0 * float(d["release"]):
			_ducks.erase(bus)
	_apply_bus_levels()
	# bed duck follows the combat level every 0.4 s
	_bed_tick += delta
	if _bed_tick >= 0.4:
		_bed_tick = 0.0
		_apply_bed_duck(now)
	_bed_duck += (_bed_duck_target - _bed_duck) * (1.0 - exp(-delta / 0.35))
	_update_bed(_bed, delta)
	for i in range(_old_beds.size() - 1, -1, -1):
		var ob: Dictionary = _old_beds[i]
		_update_bed(ob, delta)
		ob["dispose_in"] = float(ob["dispose_in"]) - delta
		if ob["dispose_in"] < 0.0:
			for l in ob["layers"]:
				(l["player"] as AudioStreamPlayer).queue_free()
			_old_beds.remove_at(i)
	if _boss_bed != null:
		_boss_bed_gain += (_boss_bed_target - _boss_bed_gain) * (1.0 - exp(-delta / 1.0))
		_boss_bed.volume_db = linear_to_db(maxf(_boss_bed_gain * BED_GAIN, 0.0001))
		if _boss_bed_target <= 0.0 and _boss_bed_gain < 0.002:
			_boss_bed.queue_free()
			_boss_bed = null
	# sparse ambience details; wait out fights
	if _accent_timer >= 0.0 and _want_area != "":
		_accent_timer -= delta
		if _accent_timer < 0.0:
			_accent_fire()
	music.advance(delta)


func _update_bed(bed: Dictionary, delta: float) -> void:
	if bed.is_empty():
		return
	bed["gain"] = float(bed["gain"]) + (float(bed["target"]) - float(bed["gain"])) * (1.0 - exp(-delta / float(bed["tau"])))
	for l in bed["layers"]:
		var v: float = float(l["gain"]) * BED_GAIN * _bed_duck * float(bed["gain"])
		var pl := l["player"] as AudioStreamPlayer
		var db := linear_to_db(maxf(v, 0.0001))
		if absf(pl.volume_db - db) >= 0.005:   # (a settled bed was rewritten every frame)
			pl.volume_db = db


func _accent_fire() -> void:
	if _accent_retry:
		_accent_retry = false
		_accent_timer = DmAudioAmbience.accent_gap(_want_area, rng.randf()) * 0.5
		return
	if not DmAudioMixer.accents_allowed(combat_level()):
		_accent_retry = true
		_accent_timer = 4.0
		return
	var dist := 7.0 + rng.randf() * 9.0
	var ang := rng.randf() * TAU
	play_sfx(DmAudioAmbience.pick_accent(_want_area, rng.randf()), _listener + Vector2(cos(ang), sin(ang)) * dist)
	_accent_timer = DmAudioAmbience.accent_gap(_want_area, rng.randf())


# --- diagnostics --------------------------------------------------------------------------------

## Dev/QA snapshot: voices per bus, drops, loaded samples, music state.
func stats() -> Dictionary:
	var now := _now()
	var active := {}
	for id in DmAudioMixer.BUS_IDS:
		active[id] = _limiter.active(id, now)
	var dropped: int = _limiter.dropped
	for k in ["far", "repeat", "thin", "gap", "id", "partner"]:
		dropped += _drops[k]
	return {
		"played": _played, "samples_loaded": bank.loaded(), "samples_pending": bank.pending(), "samples_failed": bank.failed,
		"packs": bank.loaded_packs(), "sample_plays": _sample_hits, "active": active, "peak_voices": _limiter.peak.duplicate(),
		"dropped": dropped, "dropped_by_reason": _drops.duplicate(), "dropped_by_bus": _limiter.dropped_by_bus.duplicate(),
		"ducks": _duck_count, "nodes": _voice_count(), "combat_level": combat_level(), "bed_duck": _bed_duck,
		"area": _bed.get("area", ""), "bed_kind": _bed.get("kind", "none"), "music_cue": music.current_cue(), "music_status": music.status(),
	}


func reset_stats() -> void:
	_played = 0
	_sample_hits = 0
	_duck_count = 0
	_limiter = DmAudioMixer.VoiceLimiter.new()
	_id_limiter.reset()
	for k in _drops:
		_drops[k] = 0
