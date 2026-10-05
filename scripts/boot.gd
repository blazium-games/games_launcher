extends Control
## Hands off to the player shell. Login is the live browser flow, not a local password form.


func _ready() -> void:
	var label := Label.new()
	label.text = "Blazium Games"
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(label)
	call_deferred("_open")


func _open() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
