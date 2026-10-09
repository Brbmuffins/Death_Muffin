class_name DmBossKeyPrompt
extends DmWindow
## Port of archive/legacy-web:src/ui/BossKeyPrompt.ts: the boss altar's choice when the hero carries a Covenant Seal (wake it with soul shards, or call it Empowered).
## open_offer({boss, seals, gold, shards, bound}); signals mirror the two callbacks. Server-priced: this card only shows the price and the stakes.

signal normal_chosen(boss: String)
signal empowered_chosen(boss: String)

var boss := ""
var normal_button: Button
var emp_button: Button


func _init() -> void:
	super._init()
	panel_width = 440


func open_offer(o: Dictionary) -> void:
	for c in body.get_children():
		c.queue_free()
	boss = String(o["boss"])
	var def := DmContent.boss(boss)
	var cost := DmGoldSink.empower_gold(int(def["shards"]))
	var shards := int(o.get("shards", 0))
	var gold := int(o.get("gold", 0))
	var bound := bool(o.get("bound", false))
	var can_normal := shards >= int(def["shards"])
	var why := ""
	if not bound:
		if int(o.get("seals", 0)) < 1:
			why = "You have no Covenant Seal."
		elif gold < cost:
			why = "You need %s gold (you have %s)." % [DmJsFmt.locale(cost), DmJsFmt.locale(gold)]
	set_title(String(def["summonLabel"]), "")
	body.add_child(DmUi.label("Wake %s." % def["name"], "DmHint"))
	normal_button = Button.new()
	normal_button.theme_type_variation = "DmButtonPrimary" if DmUi.theme().has_stylebox("normal", "DmButtonPrimary") else "Button"
	normal_button.text = "Wake it · %d soul shards (you have %d)" % [int(def["shards"]), shards]
	normal_button.disabled = not can_normal
	normal_button.pressed.connect(func() -> void:
		close()
		normal_chosen.emit(boss))
	body.add_child(normal_button)
	emp_button = Button.new()
	emp_button.text = "Call it Empowered · %s%s" % ["your summon is bound: free" if bound else "1 Covenant Seal + %s gold" % DmJsFmt.locale(cost), (" — " + why) if why != "" else ""]
	emp_button.disabled = why != ""
	emp_button.pressed.connect(func() -> void:
		close()
		empowered_chosen.emit(boss))
	body.add_child(emp_button)
	var E: Dictionary = DmGoldSink.EMPOWER
	var chance := minf(float(E["legendaryCap"]), DmLegendarySets.boss_chance(String(def["area"])) * float(E["legendaryMult"]))
	body.add_child(DmUi.label("Empowered: %d+ levels stronger, %d%% more health and a red-gold glow. Its kill pays one guaranteed epic-or-better piece, a legendary %s%% of the time. The Seal and gold are taken now; a fight you lose can be tried again free." % [int(E["levelsFlat"]), DmMath.js_round((float(E["hpMult"]) - 1.0) * 100.0), DmJsFmt.num_str(snappedf(chance * 100.0, 0.1))], "DmHint", true))
	open()
