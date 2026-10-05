extends Node
## Live calls through the Blazium host singleton. The JWT stays in the module.

signal login_url_ready(url: String)
signal login_state_changed(state: int, error: String)
signal authenticated

var login_url: String = ""
var profile: Dictionary = {}
var pending_uri: String = ""
var _owners: Dictionary = {}


func _ready() -> void:
	var host := _host()
	if host == null:
		return
	if host.has_signal("login_url_ready"):
		host.login_url_ready.connect(_on_login_url)
	if host.has_signal("login_state_changed"):
		host.login_state_changed.connect(_on_login_state)


func _host() -> Object:
	if Engine.has_singleton("Blazium"):
		return Engine.get_singleton("Blazium")
	return null


func payload(result: Dictionary) -> Dictionary:
	if bool(result.get("success", true)) == false:
		return result
	var data = result.get("data", null)
	if data is Dictionary:
		return data
	return result


func ok(result: Dictionary) -> bool:
	if result.is_empty():
		return false
	if result.has("success") and bool(result["success"]) == false:
		return false
	if result.has("error"):
		return false
	return true


func is_authenticated() -> bool:
	var host := _host()
	if host == null or not host.has_method("is_authenticated"):
		return false
	return bool(host.is_authenticated())


func start_login() -> void:
	var host := _host()
	if host != null and host.has_method("start_login"):
		host.start_login()


func _on_login_url(url: String) -> void:
	login_url = url
	login_url_ready.emit(url)
	if not url.is_empty():
		OS.shell_open(url)


func _on_login_state(state: int, error: String) -> void:
	login_state_changed.emit(state, error)
	if state == 4:
		profile = payload(call_host("get_profile"))
		authenticated.emit()
		if not pending_uri.is_empty():
			var held := pending_uri
			pending_uri = ""
			UriRouter.open_uri(held)


func call_host(method: String, args: Array = []) -> Dictionary:
	var host := _host()
	if host == null or not host.has_method(method):
		return {"success": false, "error": {"message": "Blazium host is not available"}}
	var result = host.callv(method, args)
	if result is Dictionary:
		return result
	return {}


func library() -> Dictionary:
	return payload(call_host("get_library"))


func owns(game_uid: String) -> bool:
	var rows = library().get("library", [])
	if rows is Array:
		for row in rows:
			if row is Dictionary and str(row.get("game_uid", "")) == game_uid:
				return true
	return false


func files(game_uid: String) -> Dictionary:
	return payload(call_host("list_game_files", [game_uid]))


func download(file_uid: String) -> Dictionary:
	return payload(call_host("get_download", [file_uid]))


func wallet() -> Dictionary:
	return payload(call_host("get_wallet"))


func quote(game_uid: String, kind: String, amount_cents: int) -> Dictionary:
	return payload(call_host("quote_purchase", [game_uid, kind, amount_cents]))


func purchase(game_uid: String, kind: String, amount_cents: int, confirm_total: int, idem: String) -> Dictionary:
	return payload(call_host("purchase_game", [game_uid, kind, amount_cents, confirm_total, idem]))


func create_top_up(amount_cents: int) -> Dictionary:
	return payload(call_host("create_top_up", [amount_cents]))


func top_up(uid: String) -> Dictionary:
	return payload(call_host("get_top_up", [uid]))


func redeem(code: String) -> Dictionary:
	return payload(call_host("redeem_key", [code]))


func write_review(game_uid: String, enjoyed: bool, quality: int, with_friends: bool, text: String) -> Dictionary:
	return payload(call_host("write_review", [game_uid, enjoyed, quality, with_friends, text]))


func report_bug(game_uid: String, message: String) -> Dictionary:
	return payload(call_host("report_bug", [game_uid, message, OS.get_name(), Engine.get_architecture_name()]))


func friends() -> Dictionary:
	return payload(call_host("list_friends"))


func friends_playing() -> Dictionary:
	return payload(call_host("friends_playing"))


func send_friend_request(username: String) -> Dictionary:
	return payload(call_host("send_friend_request", [username]))


func respond_friend_request(request_uid: String, accept: bool) -> Dictionary:
	return payload(call_host("respond_friend_request", [request_uid, accept]))


func irc_session() -> Dictionary:
	return payload(call_host("get_irc_session"))


func shelf(kind: String) -> Dictionary:
	var os_name := "windows" if OS.get_name() == "Windows" else "linux"
	return payload(call_host("get_shelf", [kind, os_name, 24]))


func search_games(query: String) -> Dictionary:
	return payload(call_host("get_public_games", [query, "game", 1, 24]))


func remember_owner(game_uid: String, username: String) -> void:
	var uid := game_uid.strip_edges()
	var name := username.strip_edges().to_lower()
	if uid != "" and name != "":
		_owners[uid] = name


func owner_name(game_uid: String) -> String:
	if _owners.has(game_uid):
		return str(_owners[game_uid])
	for row in _rows(library(), ["library", "games"]):
		if row is Dictionary and str(row.get("game_uid", "")) == game_uid:
			remember_owner(game_uid, str(row.get("developer", "")))
			return str(_owners.get(game_uid, ""))
	for kind in ["featured", "new", "recently_updated", "made_with_blazium", "in_development", "browser_playable", "community", "tools_and_assets", "tonight", "unheard_of"]:
		for row in _rows(shelf(kind), ["games", "items"]):
			if row is Dictionary:
				var uid := str(row.get("uid", row.get("game_uid", "")))
				remember_owner(uid, str(row.get("username", "")))
		if _owners.has(game_uid):
			return str(_owners[game_uid])
	return ""


func overview(game_uid: String) -> Dictionary:
	return payload(call_host("get_game_overview", [owner_name(game_uid), game_uid]))


func changelog(game_uid: String) -> Dictionary:
	return payload(call_host("get_game_changelog", [owner_name(game_uid), game_uid]))


func play_seconds(game_uid: String) -> int:
	for row in _rows(library(), ["library", "games"]):
		if row is Dictionary and str(row.get("game_uid", "")) == game_uid:
			return int(row.get("play_seconds", 0))
	return 0


func may_write(game_uid: String) -> bool:
	return owns(game_uid) or play_seconds(game_uid) > 0


func owned_games() -> Array:
	var out: Array = []
	for row in _rows(library(), ["library", "games"]):
		if row is Dictionary and str(row.get("game_uid", "")) != "":
			out.append(row)
	return out


func _rows(body: Dictionary, keys: Array) -> Array:
	for key in keys:
		if body.get(key) is Array:
			return body[key]
	return []


func public_user(username: String) -> Dictionary:
	return payload(call_host("get_public_user", [username]))
