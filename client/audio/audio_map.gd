class_name DmAudioMap
extends RefCounted
## Typed access to the recorded-sound map (archive/legacy-web:src/content/audioMap.ts, exported to godot/data/content/audioMap.json).
## Fields per id: files[], volume, pitchJitter, maxVoices, cooldownMs, spatial, bus (sfx/ui/ambience/voice), priority 1..5,
## trim{startMs,maxMs}, rate, loopMs, layer{files,volume,delayMs}, status (mapped/partial/keep).


static func _export(name: String) -> Variant:
	return DmContent.get_export("audioMap", name)


static func all() -> Dictionary:
	return _export("AUDIO_MAP")


static func has_def(sfx_name: String) -> bool:
	return all().has(sfx_name)


static func defn(sfx_name: String) -> Dictionary:
	return all().get(sfx_name, {})


static func mix_rules() -> Dictionary:
	return _export("MIX_RULES")


static func area_surface(area: String) -> String:
	return str(_export("AREA_SURFACE").get(area, "stone"))


## Footstep gain multiplier of an area (1 when unlisted).
static func area_step_gain(area: String) -> float:
	return float(_export("AREA_STEP_GAIN").get(area, 1.0))


## Step sound id of a surface ("stone" -> "stepStone").
static func step_sound(surface: String) -> String:
	return str(_export("STEP_SOUND").get(surface, "stepStone"))


## Voice family of an enemy ("beast"/"humanoid"/"brute"/"spirit") or "" for none.
static func enemy_voice(enemy_id: String) -> String:
	var v: Variant = _export("ENEMY_VOICE").get(enemy_id)
	return "" if v == null else str(v)


static func voice_attack(family: String) -> String:
	return str(_export("VOICE_ATTACK").get(family, ""))


static func voice_death(family: String) -> String:
	return str(_export("VOICE_DEATH").get(family, ""))


## Boss tell sound id of a boss ("bossToll" / "bossTellEarth" ...).
static func boss_tell(boss_id: String) -> String:
	return str(_export("BOSS_TELL").get(boss_id, "bossToll"))


## Every clip name some id uses (files + layer files).
static func all_clip_names() -> Array[String]:
	var seen := {}
	var out: Array[String] = []
	for id in all():
		var d: Dictionary = all()[id]
		for f in d["files"]:
			if not seen.has(f):
				seen[f] = true
				out.append(f)
		if d.has("layer"):
			for f in d["layer"]["files"]:
				if not seen.has(f):
					seen[f] = true
					out.append(f)
	return out
