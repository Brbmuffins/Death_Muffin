class_name DmDialogueSource
extends RefCounted
## What the Covenant people say, and what the player has already heard. The game plugs in the port of content/dialogue.ts (greetingLines, adviceLines,
## topicLines, farewell: small functions of GuidanceState) and gameplay/guidance.ts (met / heard-topic memory). This base class is the contract plus
## harmless stub text, so DmDialoguePanel works (and the gallery shows it) without those modules.

var _met: Dictionary = {}
var _heard: Dictionary = {}


func greeting_lines(npc: String) -> Array:
	if not _met.has(npc):
		return ["Welcome, child of the Covenant. Ask, and I will answer plainly; you may ignore every word."]
	return ["Back again. What shall it be?"]


func advice_lines(_npc: String) -> Array:
	return ["(advice text comes from the guidance port)"]


func topic_lines(_npc: String, topic_id: String) -> Array:
	return ["(topic '%s' text comes from the dialogue port)" % topic_id]


func farewell(_npc: String) -> String:
	return "Go carefully."


## Remember they have been spoken to / that a topic was heard.
func told(npc: String) -> void:
	_met[npc] = true


func hear_topic(npc: String, id: String) -> void:
	_heard["%s:%s" % [npc, id]] = true


func heard_topic(npc: String, id: String) -> bool:
	return _heard.has("%s:%s" % [npc, id])


func met(npc: String) -> bool:
	return _met.has(npc)
