extends Window
## One window, one tab per friend or game channel. Sending and invites wait for confirm.

var _tabs: TabContainer
var _pages: Dictionary = {}
var _status: Label
var _retry: Button


func _ready() -> void:
	close_requested.connect(hide)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	_status = Label.new()
	_status.text = ""
	root.add_child(_status)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_tabs)
	if not IrcClient.line.is_connected(_on_line):
		IrcClient.line.connect(_on_line)
	if not IrcClient.joined.is_connected(_on_joined):
		IrcClient.joined.connect(_on_joined)
	if not IrcClient.status.is_connected(_on_status):
		IrcClient.status.connect(_on_status)


func _on_status(text: String) -> void:
	if _status != null:
		_status.text = text
	if text.begins_with("Chat login failed"):
		if _retry != null and is_instance_valid(_retry):
			return
		_retry = Button.new()
		_retry.text = "Retry chat"
		_retry.pressed.connect(func () -> void:
			IrcClient.allow_chat_retry()
			if _retry != null and is_instance_valid(_retry):
				_retry.queue_free()
			_retry = null
		)
		if _status != null and _status.get_parent() != null:
			_status.get_parent().add_child(_retry)
		return
	if _retry != null and is_instance_valid(_retry):
		_retry.queue_free()
		_retry = null


func open_friend(username: String) -> void:
	username = username.strip_edges().to_lower()
	if username.is_empty():
		return
	_ensure("friend:" + username, username, false)


func open_game(game_uid: String) -> void:
	if game_uid.is_empty():
		return
	_ensure("game:" + game_uid, game_uid, true)
	IrcClient.join_game(game_uid)


func _on_joined(channel: String) -> void:
	IrcClient.bind_joined_channel(_pages, channel)


func _ensure(key: String, title: String, game: bool) -> void:
	if _pages.has(key):
		_tabs.current_tab = _pages[key]["index"]
		return
	if not IrcClient.can_open_tab(_pages.size()):
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


func _on_line(channel: String, nick: String, text: String, at: int) -> void:
	if text.begins_with("PLAY:"):
		var uid: String = IrcClient.play_invite_uid(channel, text, Session.is_friend(nick))
		if uid == "":
			return
		var friend_key := "friend:" + nick.strip_edges().to_lower()
		if not _pages.has(friend_key):
			open_friend(nick)
		if _pages.has(friend_key):
			var invite_log: RichTextLabel = _pages[friend_key]["log"]
			var invite_when := Time.get_datetime_string_from_unix_time(at, true)
			var title := Session.game_title(uid)
			invite_log.append_text("%s %s\n" % [invite_when, IrcClient.play_invite_line(nick, title)])
			var join := Button.new()
			join.text = "Join %s" % IrcClient.play_invite_label(title)
			join.pressed.connect(func () -> void:
				Shell.show_play_card(uid)
			)
			var page: VBoxContainer = invite_log.get_parent()
			if page != null:
				page.add_child(join)
		return
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
		var when := Time.get_datetime_string_from_unix_time(at, true)
		log.append_text("%s %s: %s\n" % [when, nick, text])
