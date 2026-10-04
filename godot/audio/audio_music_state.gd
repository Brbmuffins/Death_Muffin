class_name DmMusicState
extends RefCounted
## Pure state machine of src/audio/music.ts MusicDirector (no audio nodes): which cue is wanted for the area / boss / volume,
## when to crossfade, and when a playing cue hands over to a fresh copy of itself so it loops without the encoder-padding gap.
## Every mutator returns an Array of commands for the node to run, in order:
##   {op:"start", cue, slot}    create a player for `cue`, begin playing it, then call started(slot) (or start_failed(slot, err))
##   {op:"dispose", slot}       stop and free that slot now
##   {op:"retire", slot}        fade that slot out over FADE_SECONDS, then dispose
##   {op:"loop", slot}          the failed hand-over's playing copy keeps going on its own: loop it

## Five themes cover the world without restarting on every adjacent room.
const MUSIC_FOR_AREA := {
	"chapterhouse": "chapterhouse", "alchemist_wing": "chapterhouse",
	"acre": "chapterhouse",  # the calm, enemy-free gathering sanctuary takes the quiet theme
	"graves": "graves", "cloister": "graves", "fen": "graves", "coliseum": "graves",
	"ossuary": "ossuary", "nave": "ossuary", "sanctum": "ossuary", "warren": "ossuary", "depths": "ossuary",
	"pyre": "pyre",
}
const CUES: Array[String] = ["chapterhouse", "graves", "ossuary", "pyre", "boss"]
const FADE_SECONDS := 3.0
## A hand-over starts once this little of a cue is left (FADE_SECONDS + 0.25).
const HANDOVER_LEFT := FADE_SECONDS + 0.25

var current_slot := 0  # 0 = none
var current_cue := ""
var pending_slot := 0
var pending_cue := ""
var desired := ""
var area := ""
var boss := false
var volume := 0.0
var serial := 0
var last_error := ""
var _slot_cue: Dictionary = {}  # slot -> cue (live slots)


## The cue that should play for an area, or "" for none.
static func cue_for(area_id: String) -> String:
	return str(MUSIC_FOR_AREA.get(area_id, ""))


func set_volume(value: float) -> Array:
	var previous := volume
	volume = value
	if value <= 0.0 and previous > 0.0:
		return _change("")
	if value > 0.0 and previous <= 0.0:
		return _sync()
	return []


func set_area(area_id: String) -> Array:
	if area == area_id:
		return []
	area = area_id
	boss = false
	return _sync()


func set_boss(active: bool) -> Array:
	if boss == active:
		return []
	boss = active
	return _sync()


func _sync() -> Array:
	var cue := ""
	if area != "" and volume > 0.0:
		cue = "boss" if boss else cue_for(area)
	return _change(cue)


func _change(cue: String) -> Array:
	if cue == desired:
		return []
	desired = cue
	var cmds: Array = []
	if cue == "" or current_cue == cue:
		serial += 1
		if pending_slot != 0:
			cmds.append({"op": "dispose", "slot": pending_slot})
			_slot_cue.erase(pending_slot)
		pending_slot = 0
		pending_cue = ""
		if cue == "" and current_slot != 0:
			cmds.append({"op": "retire", "slot": current_slot})
			current_slot = 0
			current_cue = ""
		return cmds
	return _start(cue)


## Begin a new copy of `cue` as the pending slot (also the loop hand-over).
func _start(cue: String) -> Array:
	var cmds: Array = []
	serial += 1
	if pending_slot != 0:
		cmds.append({"op": "dispose", "slot": pending_slot})
		_slot_cue.erase(pending_slot)
	pending_slot = serial
	pending_cue = cue
	_slot_cue[serial] = cue
	cmds.append({"op": "start", "cue": cue, "slot": serial})
	return cmds


## The pending slot began playing: it becomes current and the old current retires (crossfade). Stale slots are disposed.
func started(slot: int) -> Array:
	if slot != serial:
		_slot_cue.erase(slot)
		return [{"op": "dispose", "slot": slot}]
	var cmds: Array = []
	pending_slot = 0
	pending_cue = ""
	last_error = ""
	if current_slot != 0:
		cmds.append({"op": "retire", "slot": current_slot})
	current_slot = slot
	current_cue = _slot_cue.get(slot, "")
	return cmds


## Playing the pending slot failed (file missing / gesture needed).
func start_failed(slot: int, error: String) -> Array:
	if slot != serial:
		return []
	last_error = error
	var cue: String = _slot_cue.get(slot, "")
	pending_slot = 0
	pending_cue = ""
	_slot_cue.erase(slot)
	var cmds: Array = [{"op": "dispose", "slot": slot}]
	# A failed hand-over keeps the playing copy going (and lets it loop on its own) rather than falling silent.
	if current_cue == cue and current_slot != 0:
		cmds.append({"op": "loop", "slot": current_slot})
		return cmds
	desired = ""
	return cmds


## Call as the current cue plays (timeupdate / ended): true commands list is non-empty once a hand-over to a fresh copy is due.
func handover_check(slot: int, left_seconds: float) -> Array:
	if current_slot != slot or pending_slot != 0 or desired != current_cue:
		return []
	if is_finite(left_seconds) and left_seconds <= HANDOVER_LEFT:
		return _start(current_cue)
	return []


## A retired slot's fade finished.
func disposed(slot: int) -> void:
	_slot_cue.erase(slot)
