extends Node3D

@export var keyboard: Node3D
@export var distance := 0.6    # metres in front of the player
@export var drop := 0.25       # metres below eye level

var _layer_backup := 0


func _ready() -> void:
	add_to_group("vr_keyboard")
	if "collision_layer" in keyboard:
		_layer_backup = keyboard.collision_layer
	_set_shown(false)


func show_keyboard() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var pos := cam.global_position + fwd * distance
	pos.y = cam.global_position.y - drop
	global_position = pos
	look_at(Vector3(cam.global_position.x, pos.y, cam.global_position.z), Vector3.UP)
	rotate_y(PI)   # the keyboard quad faces +Z; remove this line if it appears backwards
	_set_shown(true)


func hide_keyboard() -> void:
	_set_shown(false)


func _set_shown(on: bool) -> void:
	keyboard.visible = on
	# a hidden viewport can still be hit by pointers, so switch its collision off too
	if "collision_layer" in keyboard:
		keyboard.collision_layer = _layer_backup if on else 0
