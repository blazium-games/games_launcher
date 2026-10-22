extends Node
## Live calls through the Blazium host singleton. The JWT stays in the module.

signal login_url_ready(url: String)
signal login_state_changed(state: int, error: String)
signal authenticated

const LIBRARY_TTL_SEC := 30 * 24 * 60 * 60
const TOP_UP_CAP_CENTS := 50000

var login_url: String = ""
var profile: Dictionary = {}
var pending_uri: String = ""
var _owners: Dictionary = {}
var _library: Dictionary = {}
var _library_fresh: bool = false
var _library_live: bool = false
var _host_log: Array = []
var _scripted: Dictionary = {}
var _purchase_keys: Dictionary = {}
var _purchase_flight: Dictionary = {}


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
		External.open(url)


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
	_host_log.append(method)
	if _scripted.has(method):
		var scripted = _scripted[method]
		if scripted is Dictionary:
			return scripted
		return {}
	var host := _host()
	if host == null or not host.has_method(method):
		return {"success": false, "error": {"message": "Blazium host is not available"}}
	var result = host.callv(method, args)
	if result is Dictionary:
		return result
	return {}


func library() -> Dictionary:
	if _library_fresh:
		return _library
	var live := payload(call_host("get_library"))
	if _library_body_ok(live):
		_remember_library(live, true)
		return _library
	var cached := _read_library_cache()
	if not cached.is_empty():
		_library = cached
		_library_fresh = true
		_library_live = false
		_index_owners(_library)
		return _library
	_library_live = false
	return live


func owns(game_uid: String) -> bool:
	return _uid_in_library(library(), game_uid)


func invalidate_library() -> void:
	_library_fresh = false


func library_is_live() -> bool:
	return _library_live and _library_fresh


func note_live_library(body: Dictionary) -> void:
	_remember_library(body, true)


func write_library_cache(body: Dictionary, saved_at: int) -> void:
	_write_library_cache(body, saved_at)


func library_cache_current(saved_at: int, now: int) -> bool:
	return saved_at > 0 and now >= saved_at and now - saved_at <= LIBRARY_TTL_SEC


func library_cache_path() -> String:
	return OS.get_user_data_dir().path_join("library_cache.json")


func files(game_uid: String) -> Dictionary:
	return payload(call_host("list_game_files", [game_uid]))


func download(file_uid: String) -> Dictionary:
	return payload(call_host("get_download", [file_uid]))


func wallet() -> Dictionary:
	return payload(call_host("get_wallet"))


func quote(game_uid: String, kind: String, amount_cents: int) -> Dictionary:
	return payload(call_host("quote_purchase", [game_uid, kind, amount_cents]))


func purchase(game_uid: String, kind: String, amount_cents: int, confirm_total: int, idem: String) -> Dictionary:
	var result := payload(call_host("purchase_game", [game_uid, kind, amount_cents, confirm_total, idem]))
	invalidate_library()
	return result


func create_top_up(amount_cents: int) -> Dictionary:
	return payload(call_host("create_top_up", [amount_cents]))


func top_up(uid: String) -> Dictionary:
	return payload(call_host("get_top_up", [uid]))


func redeem(code: String) -> Dictionary:
	var result := payload(call_host("redeem_key", [code]))
	invalidate_library()
	return result


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
	_index_owners(library())
	return str(_owners.get(game_uid, ""))


func listing(game_uid: String) -> Dictionary:
	invalidate_library()
	var lib := library()
	var owned := _uid_in_library(lib, game_uid)
	var seconds := _seconds_in_library(lib, game_uid)
	var overview_body := overview(game_uid)
	var owner := str(overview_body.get("username", overview_body.get("developer", "")))
	if owner != "":
		remember_owner(game_uid, owner)
	return {
		"overview": overview_body,
		"changelog": changelog(game_uid),
		"owned": owned,
		"may_write": owned or seconds > 0,
	}


func overview(game_uid: String) -> Dictionary:
	return payload(call_host("get_game_overview", [owner_name(game_uid), game_uid]))


func changelog(game_uid: String) -> Dictionary:
	return payload(call_host("get_game_changelog", [owner_name(game_uid), game_uid]))


func play_seconds(game_uid: String) -> int:
	return _seconds_in_library(library(), game_uid)


func may_write(game_uid: String) -> bool:
	var lib := library()
	return _uid_in_library(lib, game_uid) or _seconds_in_library(lib, game_uid) > 0


func is_friend(username: String) -> bool:
	var name := username.strip_edges().to_lower()
	if name.is_empty():
		return false
	for row in _rows(friends(), ["friends"]):
		if row is Dictionary and str(row.get("username", row.get("name", ""))).strip_edges().to_lower() == name:
			return true
	return false


func owned_games() -> Array:
	var out: Array = []
	for row in _rows(library(), ["library", "games"]):
		if row is Dictionary and str(row.get("game_uid", "")) != "":
			out.append(row)
	return out


func format_cents(cents: int) -> String:
	var sign := "-" if cents < 0 else ""
	var abs_cents := absi(cents)
	return "%s$%d.%02d" % [sign, abs_cents / 100, abs_cents % 100]


func purchase_scope(game_uid: String, kind: String, total_cents: int) -> String:
	var user := str(profile.get("username", profile.get("uid", "")))
	return "%s|%s|%s|%d" % [user, game_uid, kind, total_cents]


func purchase_key(game_uid: String, kind: String, total_cents: int) -> String:
	var scope := purchase_scope(game_uid, kind, total_cents)
	if str(_purchase_keys.get(scope, "")).is_empty():
		_purchase_keys[scope] = "%s|%d|%d" % [scope, int(Time.get_unix_time_from_system()), randi()]
	return str(_purchase_keys[scope])


func begin_purchase(scope: String) -> bool:
	if _purchase_flight.has(scope):
		return false
	_purchase_flight[scope] = true
	return true


func end_purchase(scope: String) -> void:
	_purchase_flight.erase(scope)


func card_top_up_cents(total_cents: int, balance_cents: int, cap_cents: int = TOP_UP_CAP_CENTS) -> int:
	if total_cents < 0 or balance_cents < 0 or cap_cents < 0:
		return -1
	if total_cents > cap_cents:
		return -1
	var need := total_cents - balance_cents
	if need <= 0:
		return 0
	if need > cap_cents or balance_cents + need > cap_cents:
		return -1
	return need


func can_show_purchase(overview: Dictionary) -> bool:
	return ok(overview)


func purchase_confirm_text(total_cents: int, detail: String) -> String:
	return "Total %s. %s" % [format_cents(total_cents), detail]


func _library_body_ok(body: Dictionary) -> bool:
	if body.is_empty() or body.has("error"):
		return false
	if body.has("success") and bool(body.get("success")) == false:
		return false
	return body.get("library") is Array or body.get("games") is Array


func _remember_library(body: Dictionary, live: bool) -> void:
	_library = body
	_library_fresh = true
	_library_live = live
	_index_owners(body)
	if live:
		_write_library_cache(body, int(Time.get_unix_time_from_system()))


func _index_owners(body: Dictionary) -> void:
	for row in _rows(body, ["library", "games"]):
		if row is Dictionary:
			remember_owner(str(row.get("game_uid", "")), str(row.get("developer", row.get("username", ""))))


func _uid_in_library(body: Dictionary, game_uid: String) -> bool:
	for row in _rows(body, ["library", "games"]):
		if row is Dictionary and str(row.get("game_uid", "")) == game_uid:
			return true
	return false


func _seconds_in_library(body: Dictionary, game_uid: String) -> int:
	for row in _rows(body, ["library", "games"]):
		if row is Dictionary and str(row.get("game_uid", "")) == game_uid:
			return int(row.get("play_seconds", 0))
	return 0


func _write_library_cache(body: Dictionary, saved_at: int) -> void:
	var out := FileAccess.open(library_cache_path(), FileAccess.WRITE)
	if out == null:
		return
	out.store_string(JSON.stringify({"saved_at": saved_at, "body": body}))
	out.close()


func _read_library_cache() -> Dictionary:
	var path := library_cache_path()
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return {}
	if not library_cache_current(int(parsed.get("saved_at", 0)), int(Time.get_unix_time_from_system())):
		return {}
	var body = parsed.get("body", {})
	if body is Dictionary and _library_body_ok(body):
		return body
	return {}


func _rows(body: Dictionary, keys: Array) -> Array:
	for key in keys:
		if body.get(key) is Array:
			return body[key]
	return []


func public_user(username: String) -> Dictionary:
	return payload(call_host("get_public_user", [username]))
