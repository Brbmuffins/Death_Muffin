class_name DmChatCommand
extends RefCounted
## WorldScene.chatCommand: `/party`, `/solo`, `/leave` typed in the chat box are the chat-line way to make / leave a party.
## parse() is the web's regexp; DmGameUi.chat_command routes it to game.party_create / party_leave (has_method guarded). An argument after /party
## (an old party code) only gets a pointer to the Social window.

static var _re: RegEx


## {cmd: "party"|"solo"|"leave", arg: String} or {} when the line is not a command.
static func parse(text: String) -> Dictionary:
	if _re == null:
		_re = RegEx.new()
		_re.compile("(?i)^/(party|solo|leave)(?:\\s+(\\S+))?\\s*$")
	var m := _re.search(text.strip_edges())
	if m == null:
		return {}
	return {"cmd": m.get_string(1).to_lower(), "arg": m.get_string(2)}

