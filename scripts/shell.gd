extends Node
## Player windows. Links and tools call these methods; none of them spend money or send chat on their own.

signal navigate(page: String, extra: Dictionary)

var notice: String = ""
var pending_page: String = ""
var pending_extra: Dictionary = {}

var _friends: Window
var _chats: Window


func _ready() -> void:
	_friends = load("res://scenes/friends_window.tscn").instantiate()
	_chats = load("res://scenes/chat_window.tscn").instantiate()
	add_child(_friends)
	add_child(_chats)
	_friends.hide()
	_chats.hide()
	if IrcClient.has_signal("invite"):
		IrcClient.invite.connect(func (from_nick: String, game_uid: String) -> void:
			show_play_card(game_uid)
			show_notice("%s invited you to play" % from_nick)
		)


func show_notice(text: String) -> void:
	notice = text
	_go("notice", {"text": text})


func show_login() -> void:
	_go("login", {})


func focus_window() -> void:
	var win := get_tree().root.get_window()
	if win != null:
		win.grab_focus()
	_go("home", {})


func show_page(name: String) -> void:
	_go(name, {})


func show_user(username: String) -> void:
	_go("user", {"username": username})


func show_search(query: String) -> void:
	_go("search", {"q": query})


func show_listing(uid: String, launch_if_owned: bool) -> void:
	_go("listing", {"uid": uid, "launch": launch_if_owned})


func install_game(uid: String, channel: String) -> void:
	_go("install", {"uid": uid, "channel": channel})


func show_checkout(uid: String) -> void:
	_go("checkout", {"uid": uid})


func show_play_card(uid: String) -> void:
	_go("play", {"uid": uid})


func show_review(uid: String) -> void:
	_go("review", {"uid": uid})


func show_bug(uid: String) -> void:
	_go("bug", {"uid": uid})


func show_redeem(code: String) -> void:
	_go("redeem", {"code": code})


func open_friends() -> void:
	_friends.show()
	_friends.grab_focus()
	if _friends.has_method("refresh"):
		_friends.refresh()


func open_chat_friend(username: String) -> void:
	_chats.show()
	_chats.grab_focus()
	if _chats.has_method("open_friend"):
		_chats.open_friend(username)


func open_chat_game(game_uid: String) -> void:
	_chats.show()
	_chats.grab_focus()
	if _chats.has_method("open_game"):
		_chats.open_game(game_uid)


func poll_top_up(uid: String) -> void:
	_go("topup", {"uid": uid})


func _go(page: String, extra: Dictionary) -> void:
	pending_page = page
	pending_extra = extra
	navigate.emit(page, extra)
