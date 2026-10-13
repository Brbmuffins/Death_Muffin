class_name DmSocialWindow
extends DmTabbedWindow
## Social (key O, the HUD's Social button; owner 2026-10-13): one window with the Friends tab (O, ui/panels/dm_friends_pane.gd) and the Party tab
## (F, ui/panels/dm_party_pane.gd). Pure UI; game_ui/dm_ui_social.gd wires both panes to the game.

var friends: DmFriendsPane
var party: DmPartyPane


func _init() -> void:
	super._init()
	title = "Social"
	aka = "O"
	panel_width = 580
	friends = DmFriendsPane.new()
	party = DmPartyPane.new()
	add_tab("friends", "Friends", friends, "O")
	add_tab("party", "Party", party, "F")
