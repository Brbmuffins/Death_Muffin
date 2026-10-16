class_name DmMusicDirector
extends Node
## Port of the MusicDirector in archive/legacy-web:src/audio/music.ts. Streams one cue at a time and crossfades on area or boss changes; each cue
## hands over to a fresh copy of itself just before it ends so it loops without a gap. The decisions live in DmMusicState (pure,
## tested); this node runs the commands with AudioStreamPlayers on the "Music" bus. Cues: res://assets/audio/music/<cue>.mp3.

var state := DmMusicState.new()
var bus_name := "Music"
var _slots: Dictionary = {}  # slot -> {player, cue, gain, target, dispose_in}
var _streams: Dictionary = {}
var _combat_gain := 1.0
var _combat_target := 1.0
var _combat_level := 0.0
var _cue_duck: Array = []  # {depth, hold, release, t}
var _slider_gain := 0.0
var _slider_target := 0.0


func current_cue() -> String:
	return state.current_cue


func status() -> Dictionary:
	return {"desired": state.desired, "pending": state.pending_cue, "current": state.current_cue, "error": state.last_error}


func set_volume_slider(value: float) -> void:
	_slider_target = DmAudioMixer.slider_gain(value) * DmAudioMixer.MUSIC_TRIM
	_run(state.set_volume(value))


func set_area(area_id: String) -> void:
	_run(state.set_area(area_id))


func set_boss(active: bool) -> void:
	_run(state.set_boss(active))


func set_combat_level(level: float) -> void:
	_combat_level = level
	_combat_target = DmAudioMixer.music_combat_gain(level, state.boss)


func duck_for_cue(depth: float, hold: float, release: float) -> void:
	_cue_duck = [{"depth": depth, "hold": hold, "release": release, "t": 0.0}]


func _run(cmds: Array) -> void:
	for c in cmds:
		match c["op"]:
			"start":
				_start_slot(c["slot"], c["cue"])
			"dispose":
				_dispose(c["slot"])
			"retire":
				if _slots.has(c["slot"]):
					_slots[c["slot"]]["target"] = 0.0
					_slots[c["slot"]]["dispose_in"] = DmMusicState.FADE_SECONDS + 0.3
			"loop":
				if _slots.has(c["slot"]):
					var p: AudioStreamPlayer = _slots[c["slot"]]["player"]
					var s := p.stream.duplicate() as AudioStream
					if s is AudioStreamMP3:
						(s as AudioStreamMP3).loop = true
					var pos := p.get_playback_position()
					p.stream = s
					p.play(pos)


func _cue_stream(cue: String) -> AudioStream:
	if not _streams.has(cue):
		var path := DmSampleBank.MUSIC_DIR + cue + ".mp3"
		_streams[cue] = ResourceLoader.load(path) as AudioStream if ResourceLoader.exists(path) else null
	return _streams[cue]


func _start_slot(slot: int, cue: String) -> void:
	var s := _cue_stream(cue)
	if s == null:
		_run(state.start_failed(slot, "missing music file: " + cue))
		return
	var p := AudioStreamPlayer.new()
	p.stream = s
	p.bus = bus_name
	p.volume_db = -80.0
	add_child(p)
	p.play()
	_slots[slot] = {"player": p, "cue": cue, "gain": 0.0, "target": 1.0, "dispose_in": -1.0}
	_run(state.started(slot))


func _dispose(slot: int) -> void:
	if _slots.has(slot):
		var p: AudioStreamPlayer = _slots[slot]["player"]
		p.stop()
		p.queue_free()
		_slots.erase(slot)
	state.disposed(slot)


## Per-frame: crossfades, hand-over checks, ducks and the Music bus level.
func _process(delta: float) -> void:
	advance(delta)


func advance(delta: float) -> void:
	var tau := DmMusicState.FADE_SECONDS / 3.0
	var k := 1.0 - exp(-delta / tau)
	for slot in _slots.keys():
		var e: Dictionary = _slots[slot]
		e["gain"] = float(e["gain"]) + (float(e["target"]) - float(e["gain"])) * k
		(e["player"] as AudioStreamPlayer).volume_db = linear_to_db(maxf(float(e["gain"]), 0.0001))
		if float(e["dispose_in"]) >= 0.0:
			e["dispose_in"] = float(e["dispose_in"]) - delta
			if float(e["dispose_in"]) < 0.0:
				_dispose(slot)
	if state.current_slot != 0 and _slots.has(state.current_slot):
		var p: AudioStreamPlayer = _slots[state.current_slot]["player"]
		var length := p.stream.get_length()
		var left := length - p.get_playback_position() if p.playing else 0.0
		_run(state.handover_check(state.current_slot, left))
	_combat_gain += (_combat_target - _combat_gain) * (1.0 - exp(-delta / 0.3))
	_slider_gain += (_slider_target - _slider_gain) * (1.0 - exp(-delta / 0.08))
	var duck := 1.0
	if _cue_duck.size() > 0:
		var d: Dictionary = _cue_duck[0]
		d["t"] = float(d["t"]) + delta
		duck = DmAudioMixer.duck_factor(float(d["depth"]), float(d["hold"]), float(d["release"]), float(d["t"]))
		if float(d["t"]) > float(d["hold"]) + 6.0 * float(d["release"]):
			_cue_duck.clear()
	var idx := AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(_slider_gain * _combat_gain * duck, 0.0001)))
