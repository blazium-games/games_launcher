extends Window
## One window, one tab per friend or game channel. Sending and invites wait for confirm.

var _tabs: TabContainer
var _pages: Dictionary = {}
var _wait_uid: String = ""


func _ready() -> void:
	close_requested.connect(hide)
	_tabs = TabContainer.new()
	_tabs.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_tabs)
	if not IrcClient.line.is_connected(_on_line):
		IrcClient.line.connect(_on_line)
	if not IrcClient.joined.is_connected(_on_joined):
		IrcClient.joined.connect(_on_joined)


func open_friend(username: String) -> void:
	username = username.strip_edges().to_lower()
	if username.is_empty():
		return
	_ensure("friend:" + username, username, false)


func open_game(game_uid: String) -> void:
	if game_uid.is_empty():
		return
	_wait_uid = game_uid
	_ensure("game:" + game_uid, game_uid, true)
	IrcClient.join_game(game_uid)


func _on_joined(channel: String) -> void:
	if _wait_uid.is_empty():
		return
	var key := "game:" + _wait_uid
	if _pages.has(key):
		_pages[key]["channel"] = channel
	_wait_uid = ""


func _ensure(key: String, title: String, game: bool) -> void:
	if _pages.has(key):
		_tabs.current_tab = _pages[key]["index"]
		return
	var page := VBoxContainer.new()
	page.name = title
	var log := RichTextLabel.new()
	log.bbcode_enabled = false
	log.scroll_following = true
	log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(log)
	var row := HBoxContainer.new()
	var input := LineEdit.new()
	input.placeholder_text = "Message"
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var send := Button.new()
	send.text = "Send"
	send.pressed.connect(func () -> void:
		var text := input.text
		input.text = ""
		if text.strip_edges().is_empty():
			return
		Confirm.ask("send", "Send this message?", text, func () -> void:
			var where := title
			if game:
				where = str(_pages[key].get("channel", ""))
			if where.is_empty():
				return
			IrcClient.send_privmsg(where, text)
		)
	)
	row.add_child(input)
	row.add_child(send)
	if not game:
		var invite := Button.new()
		invite.text = "Invite"
		var uid_box := LineEdit.new()
		uid_box.placeholder_text = "game id"
		invite.pressed.connect(func () -> void:
			var uid := uid_box.text.strip_edges()
			if uid.is_empty():
				return
			Confirm.ask("invite", "Invite this friend?", title, func () -> void:
				IrcClient.send_invite(title, uid)
			)
		)
		row.add_child(uid_box)
		row.add_child(invite)
	page.add_child(row)
	_tabs.add_child(page)
	var index := page.get_index()
	_pages[key] = {"index": index, "log": log, "title": title, "game": game}
	_tabs.current_tab = index


func _on_line(channel: String, nick: String, text: String, _at: int) -> void:
	var key := ""
	if channel.begins_with("#"):
		for existing in _pages.keys():
			if str(existing).begins_with("game:") and str(_pages[existing].get("channel", "")) == channel:
				key = existing
		if key.is_empty():
			return
	else:
		var who := channel if channel != IrcClient.nick else nick
		key = "friend:" + who.to_lower()
		if not _pages.has(key):
			open_friend(who)
	if _pages.has(key):
		var log: RichTextLabel = _pages[key]["log"]
		log.append_text("%s: %s\n" % [nick, text])
