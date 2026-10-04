class_name DmCovenantDialogue
extends DmDialogueSource
## The real DmDialogueSource: content/dialogue.ts lines (DmDialogueLines) over gameplay/guidance.ts state and memory (DmGuidance, DmGuidanceMemory).
## Usage:  var src := DmCovenantDialogue.new(func() -> Dictionary: return build_guidance_state(), DmGuidanceMemory.new("user://dm_guidance_%d.json" % char_id))
##         dialogue_panel.source = src
## `state_provider` returns the current GuidanceState Dictionary (see DmGuidance); it is called every time words are chosen, so the numbers are live.

var state_provider: Callable
var memory: DmGuidanceMemory


func _init(provider: Callable = Callable(), mem: DmGuidanceMemory = null) -> void:
	state_provider = provider
	memory = mem if mem != null else DmGuidanceMemory.new()


func _state() -> Dictionary:
	return state_provider.call() if state_provider.is_valid() else DmGuidance.base_state()


## Words first (they depend on what was still unheard); the panel calls told() right after.
func greeting_lines(npc: String) -> Array:
	var s := _state()
	return DmDialogueLines.greeting_lines(npc, s, memory.unheard(npc, s), memory.met(npc))


func advice_lines(npc: String) -> Array:
	return DmDialogueLines.advice_lines(npc, _state())


func topic_lines(npc: String, topic_id: String) -> Array:
	return DmDialogueLines.topic_lines(npc, topic_id, _state())


func farewell(npc: String) -> String:
	return DmDialogueLines.farewell(npc, _state())


func told(npc: String) -> void:
	memory.told(npc, _state())


func hear_topic(npc: String, id: String) -> void:
	memory.hear_topic(npc, id)


func heard_topic(npc: String, id: String) -> bool:
	return memory.heard_topic(npc, id)


func met(npc: String) -> bool:
	return memory.met(npc)
