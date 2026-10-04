class_name DmAudioSynth
extends RefCounted
## Procedural loops the web engine builds from oscillators: the zone drones (two detuned sawtooths, low-passed at 3x the pitch)
## and the boss war-drum pulse (src/audio/Audio.ts setBossBed). Generated once into looping AudioStreamWAVs (no asset files).

const DRONE_RATE := 4000
const DRONE_SECONDS := 10  # every drone pitch has one decimal, so f * 10 s is a whole number of cycles: the loop is seamless
const DRUM_RATE := 11025
const DRUM_PERIOD := 1.6  # the web re-triggers the three-beat figure every 1600 ms
## [offset s, start Hz, peak] of the three beats; each is a sine gliding to 38 Hz over a 4 ms attack and 0.45 s decay.
const DRUM_BEATS := [[0.0, 62.0, 0.55], [0.42, 58.0, 0.35], [1.2, 62.0, 0.45]]

static var _cache: Dictionary = {}


## {stream: AudioStreamWAV (looping), peak: float} where `peak` is the sample peak before normalising (use amt * peak as the linear volume).
static func drone(freq_hz: float) -> Dictionary:
	var key := "drone%.1f" % freq_hz
	if _cache.has(key):
		return _cache[key]
	var n := DRONE_RATE * DRONE_SECONDS
	# the web detunes -3 and +4 cents; snapped to 0.1 Hz so both fit the loop exactly (-4.1 / +4.2 cents at 41 Hz)
	var f1 := roundf(freq_hz * pow(2.0, -3.0 / 1200.0) * 10.0) / 10.0
	var f2 := roundf(freq_hz * pow(2.0, 4.0 / 1200.0) * 10.0) / 10.0
	var fc := freq_hz * 3.0
	var alpha := 1.0 - exp(-TAU * fc / float(DRONE_RATE))
	var data := PackedFloat32Array()
	data.resize(n)
	var y := 0.0
	for pass_i in 2:  # first pass only settles the filter so the loop seam is continuous
		for i in n:
			var t := float(i) / float(DRONE_RATE)
			var s := (2.0 * fposmod(f1 * t, 1.0) - 1.0) + (2.0 * fposmod(f2 * t, 1.0) - 1.0)
			y += (s - y) * alpha
			if pass_i == 1:
				data[i] = y
	var peak := 0.0
	for i in n:
		peak = maxf(peak, absf(data[i]))
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var scale := 0.9 / maxf(peak, 0.0001)
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(data[i] * scale, -1.0, 1.0) * 32767.0))
	var out := {"stream": _wav(bytes, DRONE_RATE, n), "peak": peak / 0.9}
	_cache[key] = out
	return out


## One 1.6 s cycle of the boss drum, looping.
static func boss_drum() -> AudioStreamWAV:
	if _cache.has("drum"):
		return _cache["drum"]["stream"]
	var n := int(DRUM_PERIOD * float(DRUM_RATE))
	var data := PackedFloat32Array()
	data.resize(n)
	for b in DRUM_BEATS:
		var off: float = b[0]
		var f0: float = b[1]
		var peak: float = b[2]
		var attack := 0.004
		var decay := 0.45
		var total := attack + decay
		var phase := 0.0
		var i0 := int(off * float(DRUM_RATE))
		var count := int((total + 0.02) * float(DRUM_RATE))
		for k in count:
			var t := float(k) / float(DRUM_RATE)
			var f := f0 * pow(38.0 / f0, minf(t / total, 1.0))
			phase += TAU * f / float(DRUM_RATE)
			var env := 0.0
			if t < attack:
				env = pow(peak / 0.0001, t / attack) * 0.0001
			elif t < total:
				env = peak * pow(0.0001 / peak, (t - attack) / decay)
			var idx := (i0 + k) % n
			data[idx] += sin(phase) * env
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(data[i], -1.0, 1.0) * 32767.0))
	_cache["drum"] = {"stream": _wav(bytes, DRUM_RATE, n)}
	return _cache["drum"]["stream"]


static func _wav(bytes: PackedByteArray, rate: int, frames: int) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = bytes
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = frames
	return w
