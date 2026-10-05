extends Node
## In-app confirm. Purchases, top-ups, redeems, friend requests, sends, and invites wait here.

signal confirmed(id: String)
signal cancelled(id: String)

var _layer: CanvasLayer
var _panel: PanelContainer
var _title: Label
var _body: Label
var _pending_id: String = ""
var _action: Callable = Callable()


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 100
	add_child(_layer)
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(420, 180)
	_layer.add_child(_panel)
	var box := VBoxContainer.new()
	_panel.add_child(box)
	_title = Label.new()
	_body = Label.new()
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_title)
	box.add_child(_body)
	var row := HBoxContainer.new()
	box.add_child(row)
	var yes := Button.new()
	yes.text = "Confirm"
	yes.pressed.connect(_accept)
	var no := Button.new()
	no.text = "Cancel"
	no.pressed.connect(_cancel)
	row.add_child(yes)
	row.add_child(no)


func ask(id: String, title: String, body: String, action: Callable) -> Dictionary:
	_pending_id = id
	_action = action
	_title.text = title
	_body.text = body
	_panel.visible = true
	return {"ok": false, "needs_confirm": true, "confirm_id": id}


func _accept() -> void:
	var action := _action
	var id := _pending_id
	_panel.visible = false
	_action = Callable()
	_pending_id = ""
	confirmed.emit(id)
	if action.is_valid():
		action.call()


func _cancel() -> void:
	var id := _pending_id
	_panel.visible = false
	_action = Callable()
	_pending_id = ""
	cancelled.emit(id)
