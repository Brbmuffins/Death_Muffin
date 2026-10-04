class_name DmAudioMixer
extends RefCounted
## Port of src/audio/mixer.ts: pure mixing rules (bus of a sound, priority, distance/repeat gain, voice caps, ducking maths).
## No Godot audio nodes in here, so it is unit-tested headless. Slider keys match the web Settings: volume, combatVolume,
## ambienceVolume, musicVolume, interfaceVolume (the Godot settings panel's vol_master/vol_combat/vol_amb/vol_music/vol_ui map onto them).

const BUS_IDS: Array[String] = ["combat", "enemies", "thralls", "ui", "ambience"]
## Concurrent sounds (not nodes) each bus may hold at its highest priority.
const BUS_CAP := {"combat": 14, "enemies": 9, "thralls": 5, "ui": 8, "ambience": 10}
## Fixed trim per bus, applied under the user's slider.
const BUS_TRIM := {"combat": 1.0, "enemies": 0.8, "thralls": 0.5, "ui": 0.9, "ambience": 1.0}
const PRIORITY_RESERVE := 3
const GLOBAL_CAP := 34
const PLAYER := 9
const BOSS := 8
const MUSIC_TRIM := 0.72
const CULL_DISTANCE := {"combat": 60.0, "enemies": 34.0, "thralls": 26.0, "ui": INF, "ambience": 60.0}
const REPEAT_WINDOW := 0.15
const REPEAT_GAINS: Array[float] = [1.0, 0.78, 0.6, 0.46, 0.36, 0.28]
const REPEAT_DROP := 6
const BED_DUCK_DEPTH := 0.5

## Tuned profiles of the ids that existed before the recorded map: {bus, priority, dur, thin?, duck?{depth,hold,release}}.
const PROFILES := {
	"needleCast": {"bus": "combat", "priority": 9, "dur": 0.3},
	"needleHit": {"bus": "combat", "priority": 6, "dur": 0.3},
	"spear": {"bus": "combat", "priority": 9, "dur": 0.9},
	"exhume": {"bus": "combat", "priority": 9, "dur": 1.2},
	"thrallRise": {"bus": "combat", "priority": 7, "dur": 0.7},
	"miasma": {"bus": "combat", "priority": 9, "dur": 1.2},
	"litany": {"bus": "combat", "priority": 9, "dur": 3},
	"wail": {"bus": "combat", "priority": 9, "dur": 1.1},
	"bloodStep": {"bus": "combat", "priority": 9, "dur": 0.9},
	"frost": {"bus": "combat", "priority": 9, "dur": 0.7},
	"mantle": {"bus": "combat", "priority": 9, "dur": 0.9},
	"flail": {"bus": "combat", "priority": 9, "dur": 0.3},
	"lantern": {"bus": "combat", "priority": 9, "dur": 0.6},
	"chain": {"bus": "combat", "priority": 9, "dur": 0.4},
	"pyre": {"bus": "combat", "priority": 9, "dur": 0.9},
	"ward": {"bus": "combat", "priority": 9, "dur": 0.9},
	"palm": {"bus": "combat", "priority": 9, "dur": 0.6},
	"choir": {"bus": "combat", "priority": 9, "dur": 1.3},
	"crow": {"bus": "combat", "priority": 9, "dur": 0.4},
	"bloodRite": {"bus": "combat", "priority": 9, "dur": 0.7},
	"veilRite": {"bus": "combat", "priority": 9, "dur": 0.9},
	"spiritBolt": {"bus": "combat", "priority": 9, "dur": 0.4},
	"burst": {"bus": "combat", "priority": 7, "dur": 1.1},
	"raise": {"bus": "combat", "priority": 6, "dur": 1.3},
	"curse": {"bus": "combat", "priority": 5, "dur": 0.5},
	"boneHit": {"bus": "combat", "priority": 5, "dur": 0.35},
	"hurt": {"bus": "combat", "priority": 10, "dur": 0.5, "duck": {"depth": 0.4, "hold": 0.3, "release": 0.35}},
	"playerDeath": {"bus": "combat", "priority": 10, "dur": 3.5, "duck": {"depth": 0.6, "hold": 1.5, "release": 1.2}},
	"bossToll": {"bus": "combat", "priority": 8, "dur": 4.5, "duck": {"depth": 0.3, "hold": 0.7, "release": 0.7}},
	"bossSlam": {"bus": "combat", "priority": 8, "dur": 1.5, "duck": {"depth": 0.35, "hold": 0.4, "release": 0.6}},
	"bossAwaken": {"bus": "combat", "priority": 8, "dur": 6, "duck": {"depth": 0.4, "hold": 2, "release": 1.2}},
	"bossDefeat": {"bus": "combat", "priority": 8, "dur": 7, "duck": {"depth": 0.4, "hold": 1.5, "release": 1.2}},
	"eliteDeath": {"bus": "enemies", "priority": 7, "dur": 1.4},
	"enemyDeath": {"bus": "enemies", "priority": 5, "dur": 0.5},
	"emberBurst": {"bus": "enemies", "priority": 5, "dur": 0.4},
	"emberThrow": {"bus": "enemies", "priority": 4, "dur": 0.4},
	"slagSlam": {"bus": "enemies", "priority": 6, "dur": 1},
	"toll": {"bus": "enemies", "priority": 5, "dur": 2.4},
	"tollSmall": {"bus": "enemies", "priority": 3, "dur": 1.2},
	"thrallMelee": {"bus": "thralls", "priority": 3, "dur": 0.3, "thin": {"window": 0.1, "max": 3}},
	"thrallShot": {"bus": "thralls", "priority": 3, "dur": 0.3, "thin": {"window": 0.1, "max": 3}},
	"thrallMagic": {"bus": "thralls", "priority": 3, "dur": 0.5, "thin": {"window": 0.1, "max": 3}},
	"coin": {"bus": "ui", "priority": 3, "dur": 0.3},
	"shard": {"bus": "ui", "priority": 3, "dur": 0.7},
	"item": {"bus": "ui", "priority": 3, "dur": 0.9},
	"levelUp": {"bus": "ui", "priority": 6, "dur": 1.8},
	"skillUp": {"bus": "ui", "priority": 5, "dur": 1.5},
	"click": {"bus": "ui", "priority": 2, "dur": 0.1},
	"buy": {"bus": "ui", "priority": 3, "dur": 1.2},
	"error": {"bus": "ui", "priority": 3, "dur": 0.2},
	"chainTier": {"bus": "ui", "priority": 4, "dur": 1},
	"chainBreak": {"bus": "ui", "priority": 4, "dur": 0.6},
	"siphon": {"bus": "combat", "priority": 9, "dur": 1.5},
	"prison": {"bus": "combat", "priority": 9, "dur": 1.1},
	"hands": {"bus": "combat", "priority": 9, "dur": 1.1},
	"storm": {"bus": "combat", "priority": 9, "dur": 1.7},
	"soulRelease": {"bus": "combat", "priority": 9, "dur": 1.4},
	"sigWall": {"bus": "combat", "priority": 9, "dur": 1},
	"sigRend": {"bus": "combat", "priority": 9, "dur": 0.9},
	"sigDirge": {"bus": "combat", "priority": 9, "dur": 2.2},
	"sigBloom": {"bus": "combat", "priority": 9, "dur": 1},
	"panelOpen": {"bus": "ui", "priority": 2, "dur": 0.2},
	"panelClose": {"bus": "ui", "priority": 2, "dur": 0.2},
	"equip": {"bus": "ui", "priority": 3, "dur": 0.35},
	"lootRare": {"bus": "ui", "priority": 4, "dur": 0.7},
	"lootEpic": {"bus": "ui", "priority": 5, "dur": 1.6},
	"vaultOpen": {"bus": "ui", "priority": 3, "dur": 1.2},
	"vaultClose": {"bus": "ui", "priority": 3, "dur": 1},
	"gate": {"bus": "ambience", "priority": 6, "dur": 2.5},
	"wave": {"bus": "ambience", "priority": 5, "dur": 1.2},
	"step": {"bus": "ambience", "priority": 1, "dur": 0.25},
	"chop": {"bus": "ambience", "priority": 2, "dur": 0.2},
	"pick": {"bus": "ambience", "priority": 2, "dur": 0.25},
	"splash": {"bus": "ambience", "priority": 2, "dur": 0.4},
	"shovel": {"bus": "ambience", "priority": 2, "dur": 0.3},
	"reel": {"bus": "ambience", "priority": 2, "dur": 1},
	"sawpit": {"bus": "ambience", "priority": 2, "dur": 1.4},
	"kiln": {"bus": "ambience", "priority": 2, "dur": 1.9},
	"cook": {"bus": "ambience", "priority": 2, "dur": 1.2},
	"grind": {"bus": "ambience", "priority": 2, "dur": 1.4},
	"craft": {"bus": "ambience", "priority": 3, "dur": 0.4},
	"distantBell": {"bus": "ambience", "priority": 0, "dur": 2.7},
	"bogBubble": {"bus": "ambience", "priority": 0, "dur": 0.9},
	"crowCaw": {"bus": "ambience", "priority": 0, "dur": 0.4},
	"windGust": {"bus": "ambience", "priority": 0, "dur": 3.6},
	"crowdMoan": {"bus": "ambience", "priority": 0, "dur": 3.6},
	"dustFall": {"bus": "ambience", "priority": 0, "dur": 0.6},
	"graveCreak": {"bus": "ambience", "priority": 0, "dur": 0.8},
	"waterDrip": {"bus": "ambience", "priority": 0, "dur": 0.3},
	"emberCrackle": {"bus": "ambience", "priority": 0, "dur": 0.3},
}
const DEFAULT_PROFILE := {"bus": "combat", "priority": 4, "dur": 0.6}

static var _derived: Dictionary = {}


## Duck rule of an id from the map's MIX_RULES (the four bossTell* ids share the bossTell rule). Empty when none.
static func map_duck(sfx_name: String) -> Dictionary:
	var rules: Dictionary = DmAudioMap.mix_rules()["duck"]
	var key := "bossTell" if sfx_name.begins_with("bossTell") else sfx_name
	if not rules.has(key):
		return {}
	var r: Dictionary = rules[key]
	return {"depth": float(r["sfx"]), "voice": float(r["voice"]), "ambience": float(r["ambience"]), "hold": float(r["holdMs"]) / 1000.0, "release": float(r["releaseMs"]) / 1000.0}


## Bus, priority and duck of a sound. The tuned PROFILES entry wins; the recorded map supplies everything else.
static func profile_of(sfx_name: String) -> Dictionary:
	if PROFILES.has(sfx_name):
		var fixed: Dictionary = PROFILES[sfx_name]
		if fixed.has("duck"):
			return fixed
		var p: Dictionary = fixed.duplicate()
		var d := map_duck(sfx_name)
		if not d.is_empty():
			p["duck"] = d
		return p
	if _derived.has(sfx_name):
		return _derived[sfx_name]
	if DmAudioMap.has_def(sfx_name):
		var bus := DmAudioPacks.mix_bus_of(sfx_name)
		var p := {"bus": bus, "priority": int(DmAudioMap.defn(sfx_name)["priority"]) * 2, "dur": minf(DmAudioPacks.cap_seconds(sfx_name), 4.0)}
		if bus == "thralls":
			p["thin"] = {"window": 0.1, "max": 3}
		elif DmAudioPacks.is_enemy_voice_attack_death(sfx_name):
			p["thin"] = {"window": 0.5, "max": 2}
		var d := map_duck(sfx_name)
		if not d.is_empty():
			p["duck"] = d
		_derived[sfx_name] = p
		return p
	return DEFAULT_PROFILE


# --- bus gain math ------------------------------------------------------------

## Slider (0..1) to linear gain: a gentle power curve.
static func slider_gain(v: float) -> float:
	var x := 1.0 if (is_nan(v) or is_inf(v)) else clampf(v, 0.0, 1.0)
	return pow(x, 1.5)


## Settings dict keyed like the web (volume, combatVolume, ambienceVolume, musicVolume, interfaceVolume); also accepts the Godot
## settings panel's vol_master/vol_combat/vol_amb/vol_music/vol_ui. Missing keys use the web defaults.
static func normalize_settings(s: Dictionary) -> Dictionary:
	var alias := {"volume": "vol_master", "combatVolume": "vol_combat", "ambienceVolume": "vol_amb", "musicVolume": "vol_music", "interfaceVolume": "vol_ui"}
	var defaults := {"volume": 0.6, "combatVolume": 1.0, "ambienceVolume": 1.0, "musicVolume": 0.85, "interfaceVolume": 1.0}
	var out := {}
	for k in defaults:
		if s.has(k):
			out[k] = float(s[k])
		elif s.has(alias[k]):
			out[k] = float(s[alias[k]])
		else:
			out[k] = defaults[k]
	return out


static func bus_slider(bus: String, s: Dictionary) -> float:
	match bus:
		"ui":
			return s["interfaceVolume"]
		"ambience":
			return s["ambienceVolume"]
	return s["combatVolume"]


## Linear gain of one bus (excluding master).
static func bus_gain(bus: String, s: Dictionary) -> float:
	return slider_gain(bus_slider(bus, s)) * float(BUS_TRIM[bus])


static func master_gain(s: Dictionary) -> float:
	return slider_gain(s["volume"]) * 0.9


static func music_gain(s: Dictionary) -> float:
	return slider_gain(s["musicVolume"]) * MUSIC_TRIM


# --- distance -------------------------------------------------------------------

static func distance_gain(distance: float, bus: String) -> float:
	var half := 6.0 if bus == "thralls" else (7.5 if bus == "enemies" else 9.0)
	return 1.0 / (1.0 + pow(distance / half, 2.0))


static func culled(distance: float, bus: String, priority: int) -> bool:
	if priority >= BOSS:
		return false
	return distance > float(CULL_DISTANCE[bus]) or distance_gain(distance, bus) < 0.02


static func pan_for(dx: float) -> float:
	return maxf(-0.85, minf(0.85, dx / 14.0))


# --- repeat attenuation -----------------------------------------------------------

static func repeat_gain(n: int) -> float:
	return REPEAT_GAINS[mini(maxi(0, n), REPEAT_GAINS.size() - 1)]


static func repeat_dropped(n: int, priority: int) -> bool:
	return priority < PLAYER and n >= REPEAT_DROP


## Sliding-window counter of recent events, keyed by string.
class WindowCounter:
	var hits: Dictionary = {}

	func count(key: String, now: float, window: float) -> int:
		if not hits.has(key):
			return 0
		var list: Array = hits[key]
		while list.size() > 0 and now - float(list[0]) >= window:
			list.pop_front()
		return list.size()

	func add(key: String, now: float) -> void:
		if hits.has(key):
			hits[key].append(now)
		else:
			hits[key] = [now]


# --- voice caps and priority --------------------------------------------------------

## Voices a bus will accept for a sound of this priority (lower priority hits the ceiling first).
static func effective_cap(bus: String, priority: int) -> int:
	var base: int = BUS_CAP[bus]
	var frac := 0.55 + 0.45 * (float(mini(10, maxi(0, priority))) / 10.0)
	var cap := DmMath.js_round(float(base) * frac)
	return cap + PRIORITY_RESERVE if priority >= BOSS else cap


## Tracks live sounds per bus and decides whether a new one is admitted.
class VoiceLimiter:
	var voices: Array = []  # {bus, priority, end}
	var dropped := 0
	var dropped_by_bus := {"combat": 0, "enemies": 0, "thralls": 0, "ui": 0, "ambience": 0}
	var peak := {"combat": 0, "enemies": 0, "thralls": 0, "ui": 0, "ambience": 0}

	func _prune(now: float) -> void:
		if voices.size() > 0:
			voices = voices.filter(func(v: Dictionary) -> bool: return float(v["end"]) > now)

	func active(bus: String, now: float) -> int:
		_prune(now)
		var n := 0
		for v in voices:
			if v["bus"] == bus:
				n += 1
		return n

	func total(now: float) -> int:
		_prune(now)
		return voices.size()

	## Admit and register a sound. Returns "" when admitted, else the refusal reason ("bus" / "global").
	func request(bus: String, priority: int, now: float, dur: float) -> String:
		_prune(now)
		var in_bus := 0
		for v in voices:
			if v["bus"] == bus:
				in_bus += 1
		var reason := ""
		if in_bus >= DmAudioMixer.effective_cap(bus, priority):
			reason = "bus"
		elif voices.size() >= DmAudioMixer.GLOBAL_CAP and priority < DmAudioMixer.PLAYER:
			reason = "global"
		if reason != "":
			dropped += 1
			dropped_by_bus[bus] += 1
			return reason
		voices.append({"bus": bus, "priority": priority, "end": now + dur})
		peak[bus] = maxi(int(peak[bus]), in_bus + 1)
		return ""


## Pick a variant index, avoiding the previous pick when there is a choice.
static func pick_variant(count: int, last: int, rnd: float) -> int:
	if count <= 1:
		return 0
	var i := mini(count - 2, int(floorf(rnd * float(count - 1))))
	return i + 1 if (i >= last and last >= 0) else i


# --- combat activity: ambience steps back while a fight is on -------------------------

static func activity_weight(bus: String, priority: int) -> float:
	if bus == "combat":
		return 0.06 + 0.012 * float(priority)
	if bus == "enemies":
		return 0.04
	if bus == "thralls":
		return 0.015
	return 0.0


## Leaky meter of recent combat sounds: 0 in a quiet zone, 1 in a heavy fight.
class CombatActivity:
	const HALF_LIFE := 2.5
	var value := 0.0
	var at := 0.0

	func level(now: float) -> float:
		return value * pow(0.5, maxf(0.0, now - at) / HALF_LIFE)

	func bump(now: float, weight: float) -> void:
		value = minf(1.5, level(now) + weight)
		at = now

	func reset() -> void:
		value = 0.0
		at = 0.0


## Zone-bed gain multiplier at a given combat level (the boss drum is not ducked).
static func bed_duck_gain(level: float) -> float:
	return 1.0 - BED_DUCK_DEPTH * clampf(level, 0.0, 1.0)


## Sparse ambient details wait until the fight has died down.
static func accents_allowed(level: float) -> bool:
	return level < 0.2


## Music duck depth for a combat level (MusicDirector.setCombatLevel).
static func music_combat_gain(level: float, boss: bool) -> float:
	var depth := 0.2 if boss else 0.38
	return 1.0 - depth * clampf(level, 0.0, 1.0)


## Highest rarity picked up this frame decides the loot sound.
static func loot_sfx(rarities: Array) -> String:
	if rarities.has("legendary"):
		return "lootLegendary"
	if rarities.has("epic"):
		return "lootEpic"
	if rarities.has("rare"):
		return "lootRare"
	return "item"


## Gain multiplier of a duck at `t` seconds after it started: WebAudio setTargetAtTime(1-depth, 0, 0.03) then
## setTargetAtTime(1, hold, release). Continuous, so the director can apply it each frame.
static func duck_factor(depth: float, hold: float, release: float, t: float) -> float:
	if t < 0.0:
		return 1.0
	var low := 1.0 - depth
	if t <= hold:
		return _settle(low, t)
	var at_hold := _settle(low, hold)
	return 1.0 - (1.0 - at_hold) * exp(-(t - hold) / maxf(release, 0.001))


## Gain after `t` of an exponential approach from 1 toward `low` (time constant 0.03 s).
static func _settle(low: float, t: float) -> float:
	return low + (1.0 - low) * exp(-t / 0.03)


## Per-id caps: maxVoices and cooldown from the map. Pure; the engine owns the clock.
class IdLimiter:
	var ends: Dictionary = {}
	var last_start: Dictionary = {}
	var dropped := 0

	func request(id: String, now: float, dur: float, max_voices: int, cooldown: float) -> bool:
		if cooldown > 0.0 and last_start.has(id) and now - float(last_start[id]) < cooldown:
			dropped += 1
			return false
		if not ends.has(id):
			ends[id] = []
		var list: Array = ends[id]
		for i in range(list.size() - 1, -1, -1):
			if float(list[i]) <= now:
				list.remove_at(i)
		if list.size() >= max_voices:
			dropped += 1
			return false
		list.append(now + dur)
		last_start[id] = now
		return true

	func reset() -> void:
		ends.clear()
		last_start.clear()
		dropped = 0


## Partner (co-op) sounds: quieter, only nearby.
static func partner_gain(kind: String) -> float:
	var r := DmAudioMap.mix_rules()
	return float(r["partnerFootstepGain"]) if kind == "step" else float(r["partnerSpellGain"])


static func partner_audible(distance: float) -> bool:
	return distance <= float(DmAudioMap.mix_rules()["partnerRadius"])
