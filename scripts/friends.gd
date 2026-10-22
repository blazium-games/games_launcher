extends Window
## Friends list in its own window. Requests are confirmed before they are sent.

var _box: VBoxContainer
var _status: Label
var _invite_picker: OptionButton
var _invite_send: Button


func _ready() -> void:
	close_requested.connect(hide)
	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	_box = VBoxContainer.new()
	root.add_child(_box)
	_status = Label.new()
	_box.add_child(_status)
	var row := HBoxContainer.new()
	_box.add_child(row)
	var name := LineEdit.new()
	name.placeholder_text = "username"
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name)
	var add := Button.new()
	add.text = "Add friend"
	add.pressed.connect(func () -> void:
		var username := name.text.strip_edges().to_lower()
		if username.is_empty():
			return
		Confirm.ask("friend", "Send friend request?", username, func () -> void:
			var result := Session.send_friend_request(username)
			_status.text = "Request sent" if Session.ok(result) else _err(result)
			refresh()
		)
	)
	row.add_child(add)
	var reload := Button.new()
	reload.text = "Refresh"
	reload.pressed.connect(refresh)
	_box.add_child(reload)


func refresh() -> void:
	var extras: Array = []
	for i in range(3, _box.get_child_count()):
		extras.append(_box.get_child(i))
	for node in extras:
		_box.remove_child(node)
		node.free()
	if not Session.is_authenticated():
		_status.text = "Sign in to see friends"
		return
	_clear_invite_picker()
	var friends := Session.friends()
	var playing := {"playing": Session.playing_from(friends)}
	_status.text = "" if Session.ok(friends) else _err(friends)
	_section("Requests")
	for row in _rows(friends, ["requests", "incoming"]):
		if row is Dictionary:
			_request(row)
	_section("Outgoing")
	for row in _rows(friends, ["outgoing"]):
		if row is Dictionary:
			_box.add_child(_label("Waiting on %s" % str(row.get("username", ""))))
	_section("Friends")
	for row in _rows(friends, ["friends"]):
		if row is Dictionary:
			_friend(row, playing)
	_section("Playing")
	for row in _rows(playing, ["playing", "friends"]):
		if row is Dictionary:
			var who := str(row.get("username", row.get("name", "")))
			var game := str(row.get("game_name", row.get("name", "")))
			if who != "":
				_box.add_child(_label("%s is playing %s" % [who, game]))


func _request(row: Dictionary) -> void:
	var username := str(row.get("username", ""))
	var uid := str(row.get("uid", row.get("request_uid", "")))
	var line := HBoxContainer.new()
	line.add_child(_label(username))
	var yes := Button.new()
	yes.text = "Accept"
	yes.pressed.connect(func () -> void:
		var result := Session.respond_friend_request(uid, true)
		_status.text = Session.friend_action_status(result, true)
		if Session.ok(result):
			refresh()
	)
	var no := Button.new()
	no.text = "Decline"
	no.pressed.connect(func () -> void:
		var result := Session.respond_friend_request(uid, false)
		_status.text = Session.friend_action_status(result, false)
		if Session.ok(result):
			refresh()
	)
	line.add_child(yes)
	line.add_child(no)
	_box.add_child(line)


func _friend(row: Dictionary, _playing: Dictionary) -> void:
	var username := str(row.get("username", row.get("name", "")))
	if username.is_empty():
		return
	var line := HBoxContainer.new()
	line.add_child(_label(username))
	var chat := Button.new()
	chat.text = "Chat"
	chat.pressed.connect(func () -> void:
		Shell.open_chat_friend(username)
	)
	line.add_child(chat)
	var presence: Variant = row.get("presence", {})
	var state := ""
	var game_name := ""
	if presence is Dictionary:
		state = str(presence.get("state", ""))
		var game: Variant = presence.get("game", {})
		if game is Dictionary:
			game_name = str(game.get("name", ""))
	if state != "":
		var where := game_name if game_name != "" else state
		line.add_child(_label(where))
	var invite := Button.new()
	invite.text = "Invite"
	invite.pressed.connect(func () -> void:
		_invite(username)
	)
	line.add_child(invite)
	_box.add_child(line)


func _invite(username: String) -> void:
	var games := Session.owned_games()
	if games.is_empty():
		_status.text = "You have no games to invite them to"
		return
	_clear_invite_picker()
	var pick := OptionButton.new()
	for row in games:
		if row is Dictionary:
			var title := str(row.get("name", "")).strip_edges()
			if title == "":
				title = Session.display_name("", str(row.get("game_uid", "")))
			pick.add_item(title)
			pick.set_item_metadata(pick.item_count - 1, str(row.get("game_uid", "")))
	var send := Button.new()
	send.text = "Send invite"
	send.pressed.connect(func () -> void:
		var uid := str(pick.get_item_metadata(pick.selected))
		if uid.is_empty():
			return
		var title := Session.game_title(uid)
		Confirm.ask("invite", "Invite this friend?", Session.display_name(title, uid), func () -> void:
			IrcClient.send_invite(username, uid)
			_status.text = "Invite sent"
		)
	)
	_invite_picker = pick
	_invite_send = send
	_box.add_child(pick)
	_box.add_child(send)


func picker_count() -> int:
	var count := 0
	if _box == null:
		return 0
	for child in _box.get_children():
		if child is OptionButton:
			count += 1
	return count


func _clear_invite_picker() -> void:
	if _invite_picker != null and is_instance_valid(_invite_picker):
		if _invite_picker.get_parent() == _box:
			_box.remove_child(_invite_picker)
		_invite_picker.free()
	if _invite_send != null and is_instance_valid(_invite_send):
		if _invite_send.get_parent() == _box:
			_box.remove_child(_invite_send)
		_invite_send.free()
	_invite_picker = null
	_invite_send = null


func _section(title: String) -> void:
	var label := _label(title)
	label.add_theme_font_size_override("font_size", 18)
	_box.add_child(label)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _rows(body: Dictionary, keys: Array) -> Array:
	for key in keys:
		if body.get(key) is Array:
			return body[key]
	return []


func _err(result: Dictionary) -> String:
	var err = result.get("error", {})
	if err is Dictionary:
		return str(err.get("message", "Request failed"))
	return str(err) if str(err) != "" else "Request failed"
