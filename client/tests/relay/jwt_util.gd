class_name RelayTestJwt
extends RefCounted
## HS256 JWT minting for the relay tests only (test secret, never a real one).

static func _b64url(b: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(b).replace("+", "-").replace("/", "_").replace("=", "")

static func mint(secret: String, account_id: int, username: String, ttl_s: int = 3600) -> String:
	var h := _b64url('{"alg":"HS256","typ":"JWT"}'.to_utf8_buffer())
	var now := int(Time.get_unix_time_from_system())
	var p := _b64url(JSON.stringify({"accountId": account_id, "username": username, "iat": now, "exp": now + ttl_s}).to_utf8_buffer())
	var sig := Crypto.new().hmac_digest(HashingContext.HASH_SHA256, secret.to_utf8_buffer(), (h + "." + p).to_utf8_buffer())
	return h + "." + p + "." + _b64url(sig)
