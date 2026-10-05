extends SceneTree
## Cost of AudioDirector.play_sfx and its parts (headless).

func _initialize() -> void:
	_run.call_deferred()

func _t(label: String, n: int, f: Callable) -> void:
	var t := Time.get_ticks_usec()
	for i in n:
		f.call()
	print("AUDIO %-24s %.4f ms/call" % [label, (Time.get_ticks_usec() - t) / 1000.0 / n])

func _run() -> void:
	var ad = root.get_node("AudioDirector")
	for i in 120:
		await process_frame
	ad.bank.pump(1 << 20)
	print("AUDIO loaded=", ad.bank.loaded())
	var nm := "enemyDeath"
	_t("profile_of", 500, func(): DmAudioMixer.profile_of(nm))
	_t("defn", 500, func(): DmAudioMap.defn(nm))
	_t("bank.pick", 500, func(): ad.bank.pick(nm, 0.5))
	_t("cap_seconds", 500, func(): DmAudioPacks.cap_seconds(nm))
	_t("is_kept", 500, func(): DmSampleBank.is_kept(nm))
	_t("voice_count", 500, func(): ad._voice_count())
	var hit: Dictionary = ad.bank.pick(nm, 0.5)
	if not hit.is_empty():
		_t("_play_clip", 50, func(): ad._play_clip(hit["stream"], 0.5, 1.0, 0.05, {"bus": "enemies", "gain": 1.0, "pos": null}, 4.0))
	if not hit.is_empty():
		var pl := AudioStreamPlayer.new()
		root.add_child(pl)
		var st: AudioStream = hit["stream"]
		print("AUDIO stream class=", st.get_class(), " len=", st.get_length())
		_t("stream assign", 50, func(): pl.stream = null; pl.stream = st)
		_t("play()", 50, func(): pl.play())
		_t("stop()", 50, func(): pl.stop())
		_t("get_length", 200, func(): st.get_length())
		var bi := AudioServer.get_bus_index("DmPan0")
		_t("get_bus_effect", 200, func(): AudioServer.get_bus_effect(bi, 0))
		_t("panner.pan=", 200, func(): (AudioServer.get_bus_effect(bi, 0) as AudioEffectPanner).pan = 0.3)
	_t("play_sfx(enemyDeath)", 200, func(): ad._last.clear(); ad.play_sfx(nm, Vector3(1, 0, 1)))
	quit(0)
