extends Node
## Consumer blazium:// routes. A link never spends money or sends a chat by itself.

const UID := "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
const USER := "^[a-z0-9](?:[a-z0-9-]{2,30}[a-z0-9])$"

var hub_required: String = ""


func _ready() -> void:
	call_deferred("_take_argv")


func _take_argv() -> void:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		var text := str(arg)
		if text.begins_with("blazium://"):
			open_uri(text)
			return


func open_uri(raw: String) -> void:
	var parsed: Dictionary = parse(raw)
	if not bool(parsed.get("ok", false)):
		hub_required = str(parsed.get("error", "Could not open that link"))
		Shell.show_notice(hub_required)
		return
	if not Session.is_authenticated() and str(parsed.get("host", "")) != "launcher":
		Session.pending_uri = raw
		Shell.show_login()
		return
	_route(parsed)


func parse(raw: String) -> Dictionary:
	var text := raw.strip_edges()
	if not text.to_lower().begins_with("blazium:"):
		return {"ok": false, "error": "Unsupported link"}
	var rest := text.substr(text.find(":") + 1)
	while rest.begins_with("/"):
		rest = rest.substr(1)
	var host := ""
	var path := ""
	var query := ""
	var qpos := rest.find("?")
	if qpos >= 0:
		query = rest.substr(qpos + 1)
		rest = rest.substr(0, qpos)
	var slash := rest.find("/")
	if slash >= 0:
		host = rest.substr(0, slash).to_lower()
		path = rest.substr(slash + 1)
	else:
		host = rest.to_lower()
	if host == "" or host == "hub" or host == "open" or host == "load" or host == "project" or host == "register":
		return {"ok": false, "error": "Hub is required for this link"}
	if host == "install" and _query(query, "version") != "":
		return {"ok": false, "error": "Hub is required to install an editor"}
	return _consumer(host, path, query)


func _consumer(host: String, path: String, query: String) -> Dictionary:
	match host:
		"launcher", "library", "wallet", "friends", "profile":
			if path != "":
				return {"ok": false, "error": "That link is not valid"}
			return {"ok": true, "host": host}
		"game", "buy", "play", "listing", "review", "bug":
			if not _uid(path):
				return {"ok": false, "error": "That game id is not valid"}
			return {"ok": true, "host": host, "uid": path}
		"install":
			if not _uid(path):
				return {"ok": false, "error": "That game id is not valid"}
			var channel := _query(query, "channel")
			if channel != "" and channel != "stable" and channel != "beta":
				return {"ok": false, "error": "Channel must be stable or beta"}
			return {"ok": true, "host": host, "uid": path, "channel": channel}
		"search":
			return {"ok": true, "host": host, "q": _query(query, "q")}
		"redeem":
			return {"ok": true, "host": host, "code": _query(query, "code")}
		"user":
			if not _user(path):
				return {"ok": false, "error": "That username is not valid"}
			return {"ok": true, "host": host, "username": path.to_lower()}
		"chat":
			var parts := path.split("/")
			if parts.size() != 2:
				return {"ok": false, "error": "That chat link is not valid"}
			if parts[0] == "friend" and _user(parts[1]):
				return {"ok": true, "host": "chat_friend", "username": parts[1].to_lower()}
			if parts[0] == "game" and _uid(parts[1]):
				return {"ok": true, "host": "chat_game", "uid": parts[1]}
			return {"ok": false, "error": "That chat link is not valid"}
	return {"ok": false, "error": "Unknown link"}


func _route(parsed: Dictionary) -> void:
	var host := str(parsed.get("host", ""))
	match host:
		"launcher":
			Shell.focus_window()
		"library":
			Shell.show_page("library")
		"wallet":
			Shell.show_page("wallet")
		"friends":
			Shell.open_friends()
		"profile":
			Shell.show_page("profile")
		"user":
			Shell.show_user(str(parsed.get("username", "")))
		"search":
			Shell.show_search(str(parsed.get("q", "")))
		"listing", "game":
			Shell.show_listing(str(parsed.get("uid", "")), host == "game")
		"install":
			Shell.install_game(str(parsed.get("uid", "")), str(parsed.get("channel", "")))
		"buy":
			Shell.show_checkout(str(parsed.get("uid", "")))
		"play":
			Shell.show_play_card(str(parsed.get("uid", "")))
		"review":
			Shell.show_review(str(parsed.get("uid", "")))
		"bug":
			Shell.show_bug(str(parsed.get("uid", "")))
		"redeem":
			Shell.show_redeem(str(parsed.get("code", "")))
		"chat_friend":
			Shell.open_chat_friend(str(parsed.get("username", "")))
		"chat_game":
			Shell.open_chat_game(str(parsed.get("uid", "")))


func _uid(value: String) -> bool:
	var re := RegEx.new()
	re.compile(UID)
	return re.search(value) != null and re.search(value).get_string() == value


func _user(value: String) -> bool:
	var re := RegEx.new()
	re.compile(USER)
	return re.search(value.to_lower()) != null and re.search(value.to_lower()).get_string() == value.to_lower()


func _query(query: String, key: String) -> String:
	for part in query.split("&"):
		var bits := part.split("=", true, 1)
		if bits.size() == 2 and bits[0] == key:
			return bits[1].uri_decode()
	return ""
