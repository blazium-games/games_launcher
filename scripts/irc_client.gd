extends Node
## IRC over ircs://irc.blazium.online:6697. SASL PLAIN uses the short-lived token, not the site JWT.

signal line(channel: String, nick: String, text: String, at: int)
signal status(text: String)
signal invite(from_nick: String, game_uid: String)
signal joined(channel: String)

var connected: bool = false
var nick: String = ""
var _tls: StreamPeerTLS
var _buf: String = ""
var _cap_sent: bool = false
var _sasl_sent: bool = false
var _token: String = ""
var _pending_joins: Array[String] = []


func connect_session() -> void:
	if connected:
		return
	var session := Session.irc_session()
	nick = str(session.get("username", ""))
	_token = str(session.get("token", ""))
	var host := str(session.get("host", "irc.blazium.online"))
	var port := int(session.get("port", 6697))
	if nick.is_empty() or _token.is_empty():
		status.emit(str(session.get("error", "Chat is not available")))
		return
	_tls = StreamPeerTLS.new()
	var err: Error = _tls.connect_to_host(host, port, TLSOptions.client())
	if err != OK:
		status.emit("Could not connect to chat")
		return
	set_process(true)


func _process(_delta: float) -> void:
	if _tls == null:
		return
	_tls.poll()
	var st := _tls.get_status()
	if st == StreamPeerTLS.STATUS_CONNECTED and not _cap_sent:
		_register()
	elif st == StreamPeerTLS.STATUS_ERROR or st == StreamPeerTLS.STATUS_ERROR_HOSTNAME_MISMATCH:
		connected = false
		status.emit("Chat connection failed")
		set_process(false)
		return
	while _tls.get_available_bytes() > 0:
		var chunk := _tls.get_utf8_string(_tls.get_available_bytes())
		_buf += chunk
		while _buf.find("\n") >= 0:
			var line := _buf.substr(0, _buf.find("\n")).strip_edges()
			_buf = _buf.substr(_buf.find("\n") + 1)
			_on_line(line)


func _register() -> void:
	_cap_sent = true
	_send("CAP REQ :sasl")
	_send("NICK %s" % nick)
	_send("USER %s 0 * :%s" % [nick, nick])
	_send("AUTHENTICATE PLAIN")


func join_game(game_uid: String) -> void:
	connect_session()
	if connected:
		_send("GAMEJOIN %s" % game_uid)
	elif game_uid not in _pending_joins:
		_pending_joins.append(game_uid)


func part_game(game_uid: String) -> void:
	_pending_joins.erase(game_uid)
	_send("GAMEPART %s" % game_uid)


func send_privmsg(target: String, text: String) -> void:
	var clean := text.replace("\r", "").replace("\n", " ").strip_edges()
	if clean.is_empty() or target.is_empty():
		return
	connect_session()
	_send("PRIVMSG %s :%s" % [target, clean])
	line.emit(target, nick, clean, int(Time.get_unix_time_from_system()))


func send_invite(username: String, game_uid: String) -> void:
	send_privmsg(username, "PLAY:%s" % game_uid)


func _send(text: String) -> void:
	if _tls == null:
		return
	_tls.put_data((text + "\r\n").to_utf8_buffer())


func _finish_login() -> void:
	if connected:
		return
	connected = true
	_send("CAP END")
	status.emit("Connected as %s" % nick)
	for uid in _pending_joins:
		_send("GAMEJOIN %s" % uid)
	_pending_joins.clear()


func _on_line(raw: String) -> void:
	if raw.begins_with("PING "):
		_send("PONG " + raw.substr(5))
		return
	if raw == "AUTHENTICATE +" or raw.ends_with(" AUTHENTICATE +"):
		if not _sasl_sent:
			_sasl_sent = true
			var plain := "\u0000%s\u0000%s" % [nick, _token]
			_send("AUTHENTICATE %s" % Marshalls.utf8_to_base64(plain))
		return
	if " 903 " in raw:
		_finish_login()
		return
	if " 904 " in raw or " 906 " in raw:
		status.emit("Chat login failed")
		return
	if " JOIN " in raw:
		var ch := raw.get_slice(" JOIN ", 1).strip_edges().trim_prefix(":")
		if ch.begins_with("#"):
			joined.emit(ch)
		return
	if "PRIVMSG " not in raw or not raw.begins_with(":"):
		return
	var bang := raw.find("!")
	var from_nick := raw.substr(1, bang - 1) if bang > 1 else ""
	var colon := raw.find(" :")
	if colon < 0:
		return
	var text := raw.substr(colon + 2)
	var mid := raw.substr(0, colon)
	var target := ""
	var bits := mid.split(" ")
	if bits.size() >= 3:
		target = bits[2]
	if text.begins_with("PLAY:"):
		var uid := text.substr(5).strip_edges()
		invite.emit(from_nick, uid)
		line.emit(from_nick if target == nick else target, from_nick, text, int(Time.get_unix_time_from_system()))
		return
	var where := from_nick if target == nick else target
	line.emit(where, from_nick, text, int(Time.get_unix_time_from_system()))
