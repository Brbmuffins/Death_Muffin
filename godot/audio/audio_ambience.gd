class_name DmAudioAmbience
extends RefCounted
## Port of archive/legacy-web:src/audio/ambience.ts: zone ambience data and pure rules (which looping bed layers each area plays, which sparse
## details drift in over it, and the gaps between them). Beds are low and quiet on purpose. lp = 0 means no low-pass.

## Overall trim on the recorded loops (~-3 dB from the first measured level).
const LOOP_TRIM := 0.7
const BED_FILES: Array[String] = ["bed_wind", "bed_hollow", "bed_water", "bed_fire", "bed_murmur", "bed_rain", "bed_flame"]

## loops: recorded layers {file, gain, rate, lp}; wind: synthesised fallback [low-pass Hz, gain]; drones: [Hz, gain].
const ZONE_BEDS := {
	"chapterhouse": {"loops": [{"file": "bed_hollow", "gain": 0.2, "rate": 1.0, "lp": 0}, {"file": "bed_wind", "gain": 0.06, "rate": 0.8, "lp": 500}], "wind": [[300, 0.06]], "drones": [[55, 0.018]]},
	"acre": {"loops": [{"file": "bed_wind", "gain": 0.28, "rate": 1.0, "lp": 0}], "wind": [[900, 0.14], [320, 0.07]], "drones": []},
	"graves": {"loops": [{"file": "bed_wind", "gain": 0.28, "rate": 1.0, "lp": 0}, {"file": "bed_wind", "gain": 0.1, "rate": 0.78, "lp": 0}, {"file": "bed_rain", "gain": 0.18, "rate": 1, "lp": 2600}], "wind": [[700, 0.22], [260, 0.12]], "drones": []},
	"ossuary": {"loops": [{"file": "bed_hollow", "gain": 0.26, "rate": 0.9, "lp": 0}], "wind": [[350, 0.08]], "drones": [[49, 0.03]]},
	"nave": {"loops": [{"file": "bed_hollow", "gain": 0.22, "rate": 0.85, "lp": 0}, {"file": "bed_water", "gain": 0.1, "rate": 0.7, "lp": 1800}], "wind": [[450, 0.1]], "drones": [[41.2, 0.026], [61.7, 0.014]]},
	"sanctum": {"loops": [{"file": "bed_hollow", "gain": 0.28, "rate": 0.7, "lp": 0}, {"file": "bed_wind", "gain": 0.08, "rate": 0.7, "lp": 700}], "wind": [[380, 0.08]], "drones": [[36.7, 0.034]]},
	"cloister": {"loops": [{"file": "bed_water", "gain": 0.09, "rate": 0.8, "lp": 2200}, {"file": "bed_hollow", "gain": 0.12, "rate": 0.95, "lp": 0}, {"file": "bed_wind", "gain": 0.05, "rate": 0.9, "lp": 800}, {"file": "bed_rain", "gain": 0.28, "rate": 1, "lp": 3000}], "wind": [[520, 0.1], [200, 0.08]], "drones": [[43.7, 0.02]]},
	"pyre": {"loops": [{"file": "bed_flame", "gain": 0.24, "rate": 1.0, "lp": 0}, {"file": "bed_fire", "gain": 0.12, "rate": 1.0, "lp": 0}, {"file": "bed_hollow", "gain": 0.12, "rate": 0.8, "lp": 0}], "wind": [[650, 0.16], [240, 0.14]], "drones": [[46.2, 0.03]]},
	"warren": {"loops": [{"file": "bed_hollow", "gain": 0.26, "rate": 0.75, "lp": 0}], "wind": [[240, 0.05]], "drones": [[41.2, 0.024]]},
	"depths": {"loops": [{"file": "bed_hollow", "gain": 0.3, "rate": 0.62, "lp": 0}], "wind": [[200, 0.04]], "drones": [[34.6, 0.03]]},
	"coliseum": {"loops": [{"file": "bed_murmur", "gain": 0.28, "rate": 1.0, "lp": 0}, {"file": "bed_wind", "gain": 0.1, "rate": 1, "lp": 900}], "wind": [[1100, 0.09], [420, 0.1]], "drones": [[55, 0.018]]},
	"fen": {"loops": [{"file": "bed_wind", "gain": 0.12, "rate": 1.2, "lp": 1500}, {"file": "bed_water", "gain": 0.08, "rate": 0.6, "lp": 1600}, {"file": "bed_hollow", "gain": 0.08, "rate": 1.1, "lp": 0}, {"file": "bed_rain", "gain": 0.28, "rate": 1.0, "lp": 0}], "wind": [[900, 0.07], [300, 0.09]], "drones": [[38.9, 0.026]]},
	"alchemist_wing": {"loops": [{"file": "bed_fire", "gain": 0.08, "rate": 0.7, "lp": 900}, {"file": "bed_flame", "gain": 0.06, "rate": 0.7, "lp": 900}, {"file": "bed_hollow", "gain": 0.12, "rate": 1.0, "lp": 0}], "wind": [[260, 0.04]], "drones": [[58.3, 0.02]]},
}

## gap: seconds between details, uniform in [min, max]; sounds: weighted [sfx id, weight].
const ZONE_ACCENTS := {
	"chapterhouse": {"gap": [18.0, 40.0], "sounds": [["distantBell", 2], ["graveCreak", 2], ["waterDrip", 1]]},
	"acre": {"gap": [14.0, 34.0], "sounds": [["crowCaw", 3], ["distantBell", 1], ["graveCreak", 1], ["windGust", 1]]},
	"graves": {"gap": [12.0, 30.0], "sounds": [["crowCaw", 3], ["windGust", 2], ["distantBell", 1], ["graveCreak", 1]]},
	"ossuary": {"gap": [14.0, 34.0], "sounds": [["waterDrip", 3], ["graveCreak", 1], ["dustFall", 2]]},
	"nave": {"gap": [12.0, 30.0], "sounds": [["waterDrip", 3], ["distantBell", 2], ["crowdMoan", 1]]},
	"sanctum": {"gap": [16.0, 36.0], "sounds": [["distantBell", 3], ["graveCreak", 1], ["crowdMoan", 1]]},
	"cloister": {"gap": [12.0, 28.0], "sounds": [["bogBubble", 2], ["waterDrip", 2], ["graveCreak", 1]]},
	"pyre": {"gap": [8.0, 20.0], "sounds": [["emberCrackle", 4], ["graveCreak", 1], ["windGust", 1]]},
	"warren": {"gap": [12.0, 30.0], "sounds": [["waterDrip", 3], ["dustFall", 3], ["graveCreak", 1]]},
	"depths": {"gap": [10.0, 26.0], "sounds": [["waterDrip", 3], ["dustFall", 3], ["graveCreak", 2]]},
	"coliseum": {"gap": [14.0, 32.0], "sounds": [["crowdMoan", 3], ["distantBell", 2], ["windGust", 1]]},
	"fen": {"gap": [10.0, 26.0], "sounds": [["bogBubble", 4], ["waterDrip", 2], ["crowCaw", 1], ["graveCreak", 1]]},
	"alchemist_wing": {"gap": [10.0, 24.0], "sounds": [["waterDrip", 2], ["emberCrackle", 2]]},
}


static func accent_gap(area: String, rnd: float) -> float:
	var g: Array = ZONE_ACCENTS[area]["gap"]
	return float(g[0]) + (float(g[1]) - float(g[0])) * clampf(rnd, 0.0, 1.0)


static func pick_accent(area: String, rnd: float) -> String:
	var list: Array = ZONE_ACCENTS[area]["sounds"]
	var total := 0.0
	for e in list:
		total += float(e[1])
	var r := minf(0.999999, maxf(0.0, rnd)) * total
	for e in list:
		r -= float(e[1])
		if r < 0.0:
			return e[0]
	return list[list.size() - 1][0]


## True when every loop of a zone's bed has loaded (otherwise the synthesised bed plays). `has` is a Callable(file) -> bool.
static func bed_ready(area: String, has: Callable) -> bool:
	var loops: Array = ZONE_BEDS[area]["loops"]
	if loops.is_empty():
		return false
	for l in loops:
		if not has.call(l["file"]):
			return false
	return true
