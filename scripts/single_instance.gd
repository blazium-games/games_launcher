extends Node
## Second launcher forwards SHOW or a blazium:// URI, then exits. Port 39219.

const PORT := 39219
const HOST := "127.0.0.1"

var _server: TCPServer
var _peers: Array[StreamPeerTCP] = []


func _ready() -> void:
	if _ensure_only():
		return
	_server = TCPServer.new()
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
	if msg == "SHOW":
		Shell.focus_window()
		return
	if msg.begins_with("blazium://") and msg.length() < 2048:
		UriRouter.open_uri(msg)


func _forward_and_quit() -> void:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host(HOST, PORT)
	var ticks := 0
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and ticks < 50:
		peer.poll()
		OS.delay_msec(20)
		ticks += 1
	var msg := "SHOW"
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		var text := str(arg)
		if text.begins_with("blazium://"):
			msg = text
			break
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data(msg.to_utf8_buffer())
	get_tree().quit(0)
