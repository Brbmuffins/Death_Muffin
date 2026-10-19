extends SceneTree
## Gathering-layer tests (test_gather.gd) and laborer views + labor/garden glue tests (test_labor.gd) in ONE process.
## godot --headless --path client --script res://tests/gathering_labor/run.gd
## (Formerly gather_run + labor_run.) Prints "N passed, M failed" and exits non-zero on failure.
var _g := preload("res://tests/gathering_labor/test_gather.gd").new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _g.run(self)
	var t = load("res://tests/gathering_labor/test_labor.gd").new()
	await t.run(self)
	print("%d passed, %d failed" % [_g.passed + t.passed, _g.failed + t.failed])
	var nfail: int = _g.failed + t.failed
	print("%s gathering_labor %d checks%s" % ["PASS" if nfail == 0 else "FAIL", _g.passed + t.passed + nfail, "" if nfail == 0 else " (%d failed)" % nfail])
	quit(1 if (_g.failed + t.failed) > 0 else 0)
