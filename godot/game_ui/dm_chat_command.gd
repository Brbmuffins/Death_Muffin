class_name DmChatCommand
extends RefCounted
## WorldScene.chatCommand: `/party [code]`, `/solo`, `/leave` typed in the chat box are the chat-line way to Play together / leave the party.
## parse() is the web's regexp; DmGameUi.chat_command routes it to game.party_create / party_join / party_leave (has_method guarded).

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


## joinParty's code cleanup: lower-case, only a-z 0-9 and "-", 12 characters at most ("" = nothing usable).
static func clean_code(raw: String) -> String:
	var out := ""
	for ch in raw.strip_edges().to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "-":
			out += ch
	return out.substr(0, 12)
