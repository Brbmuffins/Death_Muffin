class_name DmMockSource
extends DmDialogueSource
## Gallery stand-in for the guidance-driven dialogue lines.


func greeting_lines(_npc: String) -> Array:
	return ["Welcome to the Chapterhouse, child of the Covenant. I am the Prior; the seals and the dead of this diocese are my charge.", "No one commands you here. Ask me where to go and I will say it plainly; you may ignore every word."]


func advice_lines(_npc: String) -> Array:
	return ["The Marrow Ossuary is open to you now, and its dead are level 8. Go when you feel ready."]


func topic_lines(_npc: String, topic_id: String) -> Array:
	return ["(the %s topic would be spoken here)" % topic_id]
