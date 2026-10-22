extends Node
## Second launcher forwards SHOW or a blazium:// URI, then exits. Port 39219.

const PORT := 39219
const HOST := "127.0.0.1"
const TOKEN_PATH := "user://launcher_ipc.token"

var _server: TCPServer
var _peers: Array[StreamPeerTCP] = []
var _token := ""


func _ready() -> void:
	if _ensure_only():
		return
	_server = TCPServer.new()
	_token = _load_or_create_token()
	var err := _server.listen(PORT, HOST)
	if err != OK:
		_forward_and_quit()
		return
	set_process(true)


func _ensure_only() -> bool:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if str(arg) == "--ensure-launcher-remote":
			return true
	return false


func _process(_delta: float) -> void:
	if _server != null and _server.is_connection_available():
		var peer := _server.take_connection()
		if peer:
			_peers.append(peer)
	var still: Array[StreamPeerTCP] = []
	for peer in _peers:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			if peer.get_available_bytes() > 0:
				var msg := peer.get_utf8_string(mini(peer.get_available_bytes(), 4096)).strip_edges()
				_handle(msg)
			still.append(peer)
		elif peer.get_status() == StreamPeerTCP.STATUS_CONNECTING:
			still.append(peer)
	_peers = still


func _handle(msg: String) -> void:
	var command := accept_command(_token, msg)
	if command == "SHOW":
		Shell.focus_window()
		return
	if command.begins_with("blazium://"):
		UriRouter.open_uri(command)


func accept_command(token: String, msg: String) -> String:
	if token.is_empty() or msg.is_empty():
		return ""
	var parts := msg.split(" ", false, 1)
	if parts.size() != 2 or parts[0] != token:
		return ""
	var command := parts[1].strip_edges()
	if command == "SHOW":
		return command
	if command.begins_with("blazium://") and command.length() < 2048:
		return command
	return ""


func _load_or_create_token() -> String:
	if FileAccess.file_exists(TOKEN_PATH):
		var existing := FileAccess.get_file_as_string(TOKEN_PATH).strip_edges()
		if existing.length() >= 32:
			return existing
	var fresh := _random_token()
	var file := FileAccess.open(TOKEN_PATH, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(fresh)
	file.close()
	return fresh


func _random_token() -> String:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(32).hex_encode()


func command_message(args: PackedStringArray) -> String:
	for arg in args:
		var text := str(arg).strip_edges()
		if text.begins_with("blazium://") and text.length() < 2048:
			return text
	return "SHOW"


func _forward_and_quit() -> void:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host(HOST, PORT)
	var ticks := 0
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and ticks < 50:
		peer.poll()
		OS.delay_msec(20)
		ticks += 1
	var msg := command_message(OS.get_cmdline_user_args() + OS.get_cmdline_args())
	var token := FileAccess.get_file_as_string(TOKEN_PATH).strip_edges()
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED and not token.is_empty():
		peer.put_data(("%s %s" % [token, msg]).to_utf8_buffer())
	get_tree().quit(0)
