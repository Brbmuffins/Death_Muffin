class_name DmHttpTransport
extends Node
## Real transport over HTTPRequest. Add this node to the scene tree (autoload or child), then `DmApi.new(transport.request_callable())`.
## A transport is any `Callable(req: Dictionary) -> Dictionary` (may be a coroutine):
##   req  = {method: String, url: String, headers: Dictionary, body: String}   (body "" = none)
##   resp = {status: int, text: String, network_error: bool}
## Tests inject a fake one; the offline edition injects DmMockBackend.transport().

func request_callable() -> Callable:
	return Callable(self, "send")

func send(req: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = DmConfig.REQUEST_TIMEOUT_S
	http.accept_gzip = true
	add_child(http)
	var headers := PackedStringArray()
	for k in req.get("headers", {}):
		headers.append("%s: %s" % [k, req["headers"][k]])
	var method := HTTPClient.METHOD_GET
	match String(req.get("method", "GET")).to_upper():
		"POST": method = HTTPClient.METHOD_POST
		"PUT": method = HTTPClient.METHOD_PUT
		"DELETE": method = HTTPClient.METHOD_DELETE
		"PATCH": method = HTTPClient.METHOD_PATCH
	var err := http.request(req["url"], headers, method, String(req.get("body", "")))
	if err != OK:
		http.queue_free()
		return {"status": 0, "text": "", "network_error": true}
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"status": 0, "text": "", "network_error": true}
	return {"status": int(res[1]), "text": (res[3] as PackedByteArray).get_string_from_utf8(), "network_error": false}
