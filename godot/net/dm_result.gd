class_name DmResult
extends RefCounted
## What every DmApi call returns (GDScript has no exceptions, so the TS `ApiError` throw becomes `ok == false`).
## `error` is the server's player-readable string, verbatim, or a client message ("Cannot reach server - check your connection").
## `status` is the HTTP status (0 = could not reach the server, 200 with ok == false = the server answered `success: false`).

var ok: bool = true
var data: Variant = null
var error: String = ""
var status: int = 200

static func success(value: Variant, http_status: int = 200) -> DmResult:
	var r := DmResult.new()
	r.data = value
	r.status = http_status
	return r

static func failure(message: String, http_status: int) -> DmResult:
	var r := DmResult.new()
	r.ok = false
	r.error = message
	r.status = http_status
	return r
