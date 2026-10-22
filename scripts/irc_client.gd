extends Node
## IRC over ircs://irc.blazium.online:6697. SASL PLAIN uses the short-lived token, not the site JWT.

signal line(channel: String, nick: String, text: String, at: int)
signal status(text: String)
signal invite(from_nick: String, game_uid: String)
signal joined(channel: String)

const IDLE_MS := 90000
const MAX_TABS := 20

var connected: bool = false
var nick: String = ""
var _tls: StreamPeerTLS
var _raw: PackedByteArray = PackedByteArray()
var _cap_sent: bool = false
var _sasl_sent: bool = false
var _token: String = ""
var _pending_joins: Array[String] = []
var _active_joins: Array[String] = []
var _attempt: int = 0
var _retry_msec: int = 0
var _last_rx_ms: int = 0


func connect_session() -> void:
	if connected or _tls != null:
		return
	var session := Session.irc_session()
	nick = str(session.get("username", ""))
	_token = str(session.get("token", ""))
	var host := str(session.get("host", "irc.blazium.online"))
	var port := int(session.get("port", 6697))
	if nick.is_empty() or _token.is_empty():
		status.emit(str(session.get("error", "Chat is not available")))
		if _attempt > 0:
			_schedule_retry()
		return
	_tls = StreamPeerTLS.new()
	var err: Error = _tls.connect_to_host(host, port, TLSOptions.client())
	if err != OK:
		_tls = null
		note_disconnect()
		return
	_last_rx_ms = Time.get_ticks_msec()
	set_process(true)


func _process(_delta: float) -> void:
	if _tls == null:
		if _retry_msec > 0 and Time.get_ticks_msec() >= _retry_msec:
			_retry_msec = 0
			connect_session()
		return
	_tls.poll()
	var st := _tls.get_status()
	if st == StreamPeerTLS.STATUS_CONNECTED and not _cap_sent:
		_register()
	elif st == StreamPeerTLS.STATUS_ERROR or st == StreamPeerTLS.STATUS_ERROR_HOSTNAME_MISMATCH or st == StreamPeerTLS.STATUS_DISCONNECTED:
		note_disconnect()
		return
	if connected and idle_timed_out(_last_rx_ms, Time.get_ticks_msec(), IDLE_MS):
		note_disconnect()
		return
	var available := _tls.get_available_bytes()
	if available <= 0:
		return
	var got: Array = _tls.get_data(available)
	if got.size() < 2 or not (got[1] is PackedByteArray):
		return
	_last_rx_ms = Time.get_ticks_msec()
	for row in push_bytes(got[1]):
		_on_line(row)


func _register() -> void:
	_cap_sent = true
	_send("CAP REQ :sasl")
	_send("NICK %s" % nick)
	_send("USER %s 0 * :%s" % [nick, nick])
	_send("AUTHENTICATE PLAIN")


func join_game(game_uid: String) -> void:
	var command := game_join_line(game_uid)
	if command.is_empty():
		return
	connect_session()
	if connected:
		_send(command)
		if not _active_joins.has(game_uid):
			_active_joins.append(game_uid)
	elif not _pending_joins.has(game_uid):
		_pending_joins.append(game_uid)


func part_game(game_uid: String) -> void:
	_pending_joins.erase(game_uid)
	_active_joins.erase(game_uid)
	var command := game_part_line(game_uid)
	if command.is_empty():
		return
	_send(command)


func send_privmsg(target: String, text: String) -> void:
	var command := privmsg_line(target, text)
	if command.is_empty():
		return
	connect_session()
	_send(command)
	var clean := command.substr(command.find(" :") + 2)
	line.emit(target, nick, clean, int(Time.get_unix_time_from_system()))


func send_invite(username: String, game_uid: String) -> void:
	if not target_ok(username) or not UriRouter.valid_uid(game_uid):
		return
	send_privmsg(username, "PLAY:%s" % game_uid)


func _send(text: String) -> void:
	if _tls == null or text.contains(String.chr(13)) or text.contains("\n") or text.contains(String.chr(0)):
		return
	_tls.put_data((text + String.chr(13) + "\n").to_utf8_buffer())


func _finish_login() -> void:
	if connected:
		return
	connected = true
	_attempt = 0
	_retry_msec = 0
	_last_rx_ms = Time.get_ticks_msec()
	_send("CAP END")
	status.emit("Connected as %s" % nick)
	for uid in _pending_joins:
		_send("GAMEJOIN %s" % uid)
		if not _active_joins.has(uid):
			_active_joins.append(uid)
	_pending_joins.clear()


func note_disconnect() -> void:
	connected = false
	_cap_sent = false
	_sasl_sent = false
	_raw = PackedByteArray()
	_tls = null
	for uid in _active_joins:
		if not _pending_joins.has(uid):
			_pending_joins.append(uid)
	_active_joins.clear()
	_attempt += 1
	_schedule_retry()
	status.emit("Reconnecting to chat")


func _schedule_retry() -> void:
	var seconds := backoff_seconds(_attempt) * (1.0 + randf() * 0.25)
	_retry_msec = Time.get_ticks_msec() + int(seconds * 1000.0)
	set_process(true)


func backoff_seconds(attempt: int) -> float:
	var exp := 1.0
	var steps := attempt - 1
	if steps < 0:
		steps = 0
	for _i in steps:
		exp *= 2.0
		if exp >= 30.0:
			return 30.0
	return exp


func idle_timed_out(last_ms: int, now_ms: int, limit_ms: int) -> bool:
	return last_ms > 0 and limit_ms > 0 and now_ms - last_ms >= limit_ms


func target_ok(target: String) -> bool:
	if target.is_empty() or target.length() > 200:
		return false
	for i in target.length():
		var ch := target.unicode_at(i)
		if ch < 33 or ch == 44 or ch == 58:
			return false
	return true


func game_join_line(game_uid: String) -> String:
	if not UriRouter.valid_uid(game_uid):
		return ""
	return "GAMEJOIN %s" % game_uid


func game_part_line(game_uid: String) -> String:
	if not UriRouter.valid_uid(game_uid):
		return ""
	return "GAMEPART %s" % game_uid


func privmsg_line(target: String, text: String) -> String:
	if not target_ok(target):
		return ""
	var clean := text.replace(String.chr(13), "").replace("\n", " ").replace(String.chr(0), "").strip_edges()
	if clean.is_empty():
		return ""
	return "PRIVMSG %s :%s" % [target, clean]


func push_bytes(chunk: PackedByteArray) -> PackedStringArray:
	var lines := PackedStringArray()
	_raw.append_array(chunk)
	while true:
		var nl := _raw.find(10)
		if nl < 0:
			break
		var row := _raw.slice(0, nl)
		_raw = _raw.slice(nl + 1)
		if row.size() > 0 and row[row.size() - 1] == 13:
			row = row.slice(0, row.size() - 1)
		lines.append(row.get_string_from_utf8())
	if _raw.size() > 65536:
		_raw = PackedByteArray()
	return lines


func parse_line(raw: String) -> Dictionary:
	var text := raw.strip_edges()
	var prefix := ""
	if text.begins_with(":"):
		var sp := text.find(" ")
		if sp < 0:
			return {"prefix": text.substr(1), "command": "", "params": []}
		prefix = text.substr(1, sp - 1)
		text = text.substr(sp + 1).strip_edges()
	var trailing := ""
	var has_trailing := false
	var colon := text.find(" :")
	if colon >= 0:
		trailing = text.substr(colon + 2)
		text = text.substr(0, colon)
		has_trailing = true
	var params: Array = []
	if not text.is_empty():
		params = text.split(" ", false)
	var command := ""
	if params.size() > 0:
		command = str(params[0])
		params = params.slice(1)
	if has_trailing:
		params.append(trailing)
	return {"prefix": prefix, "command": command, "params": params}


func server_numeric(parsed: Dictionary, code: String) -> bool:
	if str(parsed.get("command", "")) != code:
		return false
	var prefix := str(parsed.get("prefix", ""))
	return prefix != "" and not prefix.contains("!") and not prefix.contains("@")


func join_channel_from(raw: String) -> String:
	var parsed := parse_line(raw)
	if str(parsed.get("command", "")) != "JOIN":
		return ""
	var params: Array = parsed.get("params", [])
	if params.is_empty():
		return ""
	var channel := str(params[0]).strip_edges().trim_prefix(":")
	if not channel.begins_with("#"):
		return ""
	return channel


func _on_line(raw: String) -> void:
	var parsed := parse_line(raw)
	var command := str(parsed.get("command", ""))
	var params: Array = parsed.get("params", [])
	if command == "PING":
		var token := str(params[0]) if params.size() > 0 else ""
		token = token.replace(String.chr(13), "").replace("\n", "")
		_send("PONG " + token)
		_last_rx_ms = Time.get_ticks_msec()
		return
	if command == "AUTHENTICATE":
		var arg := str(params[0]) if params.size() > 0 else ""
		if arg == "+" and not _sasl_sent:
			_sasl_sent = true
			var plain := "%s%s%s%s" % [String.chr(0), nick, String.chr(0), _token]
			_send("AUTHENTICATE %s" % Marshalls.utf8_to_base64(plain))
		return
	if server_numeric(parsed, "903"):
		_finish_login()
		return
	if server_numeric(parsed, "904") or server_numeric(parsed, "906"):
		status.emit("Chat login failed")
		return
	var channel := join_channel_from(raw)
	if channel != "":
		joined.emit(channel)
		return
	if command != "PRIVMSG" or params.size() < 2 or not raw.begins_with(":"):
		return
	var prefix := str(parsed.get("prefix", ""))
	var bang := prefix.find("!")
	var from_nick := prefix.substr(0, bang) if bang > 0 else prefix
	var target := str(params[0])
	var text := str(params[1])
	if text.begins_with("PLAY:"):
		var uid := accept_play_invite(target, from_nick, text, Session.is_friend(from_nick))
		if uid != "":
			invite.emit(from_nick, uid)
		var where := from_nick if target == nick else target
		line.emit(where, from_nick, text, int(Time.get_unix_time_from_system()))
		return
	var where := from_nick if target == nick else target
	line.emit(where, from_nick, text, int(Time.get_unix_time_from_system()))


func play_invite_uid(channel: String, text: String, friend: bool) -> String:
	if channel.begins_with("#") or not friend or not text.begins_with("PLAY:"):
		return ""
	var uid := text.substr(5).strip_edges()
	if not UriRouter.valid_uid(uid):
		return ""
	return uid


func accept_play_invite(target: String, from_nick: String, text: String, friend: bool) -> String:
	if from_nick.strip_edges().is_empty():
		return ""
	if nick != "" and target != nick:
		return ""
	return play_invite_uid(target, text, friend)


func bind_joined_channel(pages: Dictionary, channel: String) -> String:
	var name := channel.strip_edges()
	if name.begins_with(":"):
		name = name.substr(1)
	if not name.begins_with("#"):
		return ""
	var best_key := ""
	var best_len := 0
	for key in pages.keys():
		var id := str(key)
		if not id.begins_with("game:"):
			continue
		var uid := id.substr(5)
		if uid == "":
			continue
		if name == "#game-" + uid or name == "#" + uid or name.ends_with("-" + uid):
			if uid.length() > best_len:
				best_len = uid.length()
				best_key = id
	if best_key == "":
		return ""
	pages[best_key]["channel"] = name
	return best_key


func can_open_tab(open_count: int) -> bool:
	return open_count < MAX_TABS
