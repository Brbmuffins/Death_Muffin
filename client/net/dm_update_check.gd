class_name DmUpdateCheck
extends Node
## Tells a running game that a newer build is out. The launcher only installs updates when it starts, so a game left open would stay
## on an old build all evening (and, since PROTOCOL 2, could not play co-op with friends on the new one). Reads the client manifest
## a minute after loading and every 5 minutes after that (one small HTTP GET on a Timer, nothing per frame) and emits
## `update_available` once per newer version (DmNextGame toasts it at once, mid-fight included). Only for an installed release build: a dev build has nothing to compare.

signal update_available(version: String)

const FIRST_S := 60.0
const EVERY_S := 300.0

var installed: String = ""
var fetch_manifest: Callable          ## () -> Dictionary (awaited): DmApi.fetch_client_manifest; {} when unreadable
var notified: String = ""             ## the newest version already announced
var _timer: Timer


func setup(installed_: String, fetch: Callable, first_s: float = FIRST_S, every_s: float = EVERY_S) -> void:
	installed = installed_
	fetch_manifest = fetch
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = first_s
	_timer.timeout.connect(func() -> void:
		_timer.one_shot = false
		_timer.wait_time = every_s
		_timer.start()
		check())
	add_child(_timer)
	_timer.start()


func check() -> void:
	if not fetch_manifest.is_valid():
		return
	var m: Variant = await fetch_manifest.call()
	if not (m is Dictionary):
		return
	var v := String((m as Dictionary).get("version", ""))
	if v != notified and DmBuild.newer(v, installed) and (notified == "" or DmBuild.newer(v, notified)):
		notified = v
		update_available.emit(v)
