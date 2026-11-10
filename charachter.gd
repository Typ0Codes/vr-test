extends Node3D


@export var camera: XRCamera3D
@export var left_ctrl: XRController3D
@export var right_ctrl: XRController3D
@export var fallback_eye_height := 1.6
@export var turn_deadzone_deg := 35.0
@export var turn_speed := 6.0
@export var finger_smoothing := 20.0
@export var flip_finger_curl := false
@export_range(0.0, 1.0) var palm_center := 0.45
@export var hand_rotation_offset_deg := Vector3.ZERO
@export var hand_position_offset := Vector3.ZERO
@export var wingspan_margin := 1.03
@export var max_growth := 1.3

var _eye_height := 1.6
var _height_scale := 1.0
var _span_rest := 0.0   # avatar's grip-to-grip wingspan at scale 1
var _span_seen := 0.0   # widest your controllers have been apart

const FINGERS := ["Index", "Middle", "Ring", "Pinky", "Thumb"]
# Maximum bend per joint (degrees), base -> tip.
const MAX_CURL_DEG := {
	"Index": [70.0, 85.0, 60.0],
	"Middle": [70.0, 85.0, 60.0],
	"Ring": [70.0, 85.0, 60.0],
	"Pinky": [70.0, 85.0, 60.0],
	"Thumb": [35.0, 45.0, 45.0],
}

@onready var skeleton: Skeleton3D = $Skeleton3D
@onready var target_l: Marker3D = $Skeleton3D/TargetL
@onready var target_r: Marker3D = $Skeleton3D/TargetR

var _eye_rest := Vector3.ZERO  # eye position in the skeleton's rest space (skeleton units)
var _yaw := 0.0
var _calibrated := false
var _wait := 0.0
var _hands := {}  # "Left" / "Right" -> { "joints": {finger: [joint, ...]}, "curl": {finger: 0..1} }

## Head pitch (degrees) where the spine starts bending, and where it is fully bent.
@export var bend_start_deg := 50.0
@export var bend_full_deg := 85.0
## Total forward spine bend (degrees) at full bend.
@export var max_bend_deg := 80.0
## Squat depth (fraction of leg length) where crouching turns into sitting, and fully sitting.
@export var sit_start := 0.35
@export var sit_full := 0.55
## The hips never drop more than this fraction of the leg length.
@export var max_squat := 0.85
@export var posture_smoothing := 12.0

const SPINE := ["mixamorig_Spine", "mixamorig_Spine1", "mixamorig_Spine2"]
const SPINE_SHARE := [0.25, 0.35, 0.4]

@onready var foot_target_l: Marker3D = $Skeleton3D/FootTargetL
@onready var foot_target_r: Marker3D = $Skeleton3D/FootTargetR

var _hips := -1
var _head := -1
var _neck := -1
var _spine := []
var _leg_len := 0.0    # skeleton units
var _thigh_len := 0.0  # skeleton units
var _foot_rest := {}   # "Left" / "Right" -> rest position in skeleton space
var _eye_in_head := Vector3.ZERO
var _head_rest_basis := Basis.IDENTITY
var _base_position := Vector3.ZERO
var _bend := 0.0
var _squat := 0.0
var _sit := 0.0


func _ready() -> void:
	# Run after the XR nodes have updated this frame so hands don't lag a frame behind.
	process_priority = 100

	var head := skeleton.find_bone("mixamorig_Head")
	var top := skeleton.find_bone("mixamorig_HeadTop_End")
	var head_pos := skeleton.get_bone_global_rest(head).origin
	var top_pos := skeleton.get_bone_global_rest(top).origin
	_eye_rest = head_pos.lerp(top_pos, 0.45)

	_hands["Left"] = _build_hand("Left", 1.0)
	_hands["Right"] = _build_hand("Right", -1.0)
	
	var arm_l := skeleton.find_bone("mixamorig_LeftArm")
	var arm_r := skeleton.find_bone("mixamorig_RightArm")
	var fore_l := skeleton.find_bone("mixamorig_LeftForeArm")
	var hand_l := skeleton.find_bone("mixamorig_LeftHand")
	var middle_l := skeleton.find_bone("mixamorig_LeftHandMiddle1")
	var arm_len := _rest_pos(arm_l).distance_to(_rest_pos(fore_l)) + _rest_pos(fore_l).distance_to(_rest_pos(hand_l))
	var palm_len := _rest_pos(hand_l).distance_to(_rest_pos(middle_l)) * palm_center
	_span_rest = _rest_pos(arm_l).distance_to(_rest_pos(arm_r)) + 2.0 * (arm_len + palm_len)
	
	_hips = skeleton.find_bone("mixamorig_Hips")
	_head = head
	_neck = skeleton.find_bone("mixamorig_Neck")
	_eye_in_head = skeleton.get_bone_global_rest(head).affine_inverse() * _eye_rest
	_head_rest_basis = skeleton.get_bone_global_rest(head).basis.orthonormalized()

	for i in SPINE.size():
		var bone := skeleton.find_bone(SPINE[i])
		var axis := (skeleton.get_bone_global_rest(bone).basis.orthonormalized().inverse() * Vector3.RIGHT).normalized()
		_spine.append({
			"bone": bone,
			"axis": axis,
			"rest": skeleton.get_bone_rest(bone).basis.get_rotation_quaternion(),
			"share": SPINE_SHARE[i],
		})

	var up_leg := skeleton.find_bone("mixamorig_LeftUpLeg")
	var knee := skeleton.find_bone("mixamorig_LeftLeg")
	var foot := skeleton.find_bone("mixamorig_LeftFoot")
	_thigh_len = _rest_pos(up_leg).distance_to(_rest_pos(knee))
	_leg_len = _thigh_len + _rest_pos(knee).distance_to(_rest_pos(foot))
	_foot_rest["Left"] = _rest_pos(foot)
	_foot_rest["Right"] = _rest_pos(skeleton.find_bone("mixamorig_RightFoot"))
	
	visible = false  # hidden until we know the player's height


func recalibrate() -> void:
	_calibrated = false
	_wait = 0.0
	visible = false
	_span_seen = 0.0
	_bend = 0.0
	_squat = 0.0
	_sit = 0.0


func _calibrate(eye_height: float) -> void:
	_eye_height = eye_height
	_height_scale = eye_height / _eye_rest.y
	_apply_scale()
	_yaw = camera.global_rotation.y
	_calibrated = true
	visible = true


func _apply_scale() -> void:
	var span_scale := _span_seen * wingspan_margin / _span_rest
	var s := clampf(span_scale, _height_scale, _height_scale * max_growth)
	var rot := Basis(Vector3.UP, PI).scaled(Vector3.ONE * s)
	var eye := rot * _eye_rest
	_base_position = Vector3(-eye.x, _eye_height - eye.y, -eye.z)
	skeleton.transform = Transform3D(rot, _base_position)


func _process(delta: float) -> void:
	if camera == null or left_ctrl == null or right_ctrl == null:
		return

	if not _calibrated:
		_wait += delta
		var height := camera.position.y 
		if height > 0.3:
			_calibrate(height)
		elif _wait > 2.0:
			_calibrate(fallback_eye_height)
		else:
			return
	
	_track_wingspan()
	_update_body(delta)
	_update_posture(delta)
	_update_hands()
	_update_fingers("Left", left_ctrl, delta)
	_update_fingers("Right", right_ctrl, delta)


func _update_body(delta: float) -> void:
	var origin := camera.get_parent() as Node3D

	
	var diff := angle_difference(_yaw, camera.global_rotation.y)
	var dead := deg_to_rad(turn_deadzone_deg)
	if absf(diff) > dead:
		_yaw += (diff - signf(diff) * dead) * (1.0 - exp(-turn_speed * delta))

	var pos := Vector3(camera.global_position.x, origin.global_position.y, camera.global_position.z)
	global_transform = Transform3D(Basis(Vector3.UP, _yaw), pos)


func _update_hands() -> void:
	_update_hand_target("Left", left_ctrl, target_l)
	_update_hand_target("Right", right_ctrl, target_r)



func _update_hand_target(side: String, ctrl: XRController3D, target: Marker3D) -> void:
	var hand: Dictionary = _hands[side]
	var side_sign: float = hand["sign"]

	
	var ctrl_basis := ctrl.global_transform.basis.orthonormalized()
	var offset_deg := Vector3(hand_rotation_offset_deg.x, hand_rotation_offset_deg.y * side_sign, hand_rotation_offset_deg.z * side_sign)
	var offset := Basis.from_euler(Vector3(deg_to_rad(offset_deg.x), deg_to_rad(offset_deg.y), deg_to_rad(offset_deg.z)))
	var fingers_world := ctrl_basis * (offset * Vector3(0, 0, -1))
	var palm_world := ctrl_basis * (offset * Vector3(side_sign, 0, 0))
	var wanted := Basis(fingers_world, palm_world, fingers_world.cross(palm_world))

	var fingers_local: Vector3 = hand["fingers_local"]
	var palm_local: Vector3 = hand["palm_local"]
	var rest_frame := Basis(fingers_local, palm_local, fingers_local.cross(palm_local))
	var hand_rotation := wanted * rest_frame.inverse()  

	
	var skeleton_scale := skeleton.global_transform.basis.get_scale().x
	var palm_point: Vector3 = hand_rotation * ((hand["palm_point_local"] as Vector3) * skeleton_scale)
	var grip := ctrl.global_position + ctrl_basis * Vector3(hand_position_offset.x * side_sign, hand_position_offset.y, hand_position_offset.z)
	target.global_transform = Transform3D(hand_rotation, grip - palm_point)




func _rest_pos(bone: int) -> Vector3:
	return skeleton.get_bone_global_rest(bone).origin



func _build_hand(side: String, side_sign: float) -> Dictionary:
	var hand := skeleton.find_bone("mixamorig_%sHand" % side)
	var index1 := skeleton.find_bone("mixamorig_%sHandIndex1" % side)
	var middle1 := skeleton.find_bone("mixamorig_%sHandMiddle1" % side)
	var pinky1 := skeleton.find_bone("mixamorig_%sHandPinky1" % side)

	var across := (_rest_pos(pinky1) - _rest_pos(index1)).normalized() 
	var along := (_rest_pos(middle1) - _rest_pos(hand)).normalized()    
	var palm := (side_sign * across.cross(along)).normalized()


	var hand_basis_inv := skeleton.get_bone_global_rest(hand).basis.orthonormalized().inverse()
	var fingers_local := (hand_basis_inv * along).normalized()
	var palm_local := (hand_basis_inv * palm).normalized()
	var palm_point_local := hand_basis_inv * ((_rest_pos(middle1) - _rest_pos(hand)) * palm_center)

	var joints := {}
	var curl := {}
	for finger in FINGERS:
		
		var curl_dir := palm
		if finger == "Thumb":
			curl_dir = (palm * 0.6 + across * 0.8).normalized()

		var chain := []
		for k in 3:
			var bone := skeleton.find_bone("mixamorig_%sHand%s%d" % [side, finger, k + 1])
			var child := skeleton.find_bone("mixamorig_%sHand%s%d" % [side, finger, k + 2])
			var rest_global := skeleton.get_bone_global_rest(bone)
			var dir := (_rest_pos(child) - rest_global.origin).normalized()
			var axis_global := dir.cross(curl_dir).normalized()
			
			var axis_local := (rest_global.basis.orthonormalized().inverse() * axis_global).normalized()
			chain.append({
				"bone": bone,
				"axis": axis_local,
				"rest": skeleton.get_bone_rest(bone).basis.get_rotation_quaternion(),
				"max": deg_to_rad(MAX_CURL_DEG[finger][k]),
			})
		joints[finger] = chain
		curl[finger] = 0.0
	return {
		"joints": joints,
		"curl": curl,
		"sign": side_sign,
		"fingers_local": fingers_local,
		"palm_local": palm_local,
		"palm_point_local": palm_point_local,
	}



func _curl_goals(ctrl: XRController3D) -> Dictionary:
	var trigger := ctrl.get_float("trigger")
	var grip := ctrl.get_float("grip")
	var index_rest := 0.25 if ctrl.is_button_pressed("trigger_touch") else 0.0
	var thumb_on_controller := (
		ctrl.is_button_pressed("primary_touch")
		or ctrl.is_button_pressed("secondary_touch")
		or ctrl.is_button_pressed("ax_touch")
		or ctrl.is_button_pressed("by_touch")
	)
	return {
		"Index": maxf(trigger, index_rest),
		"Middle": grip,
		"Ring": grip,
		"Pinky": grip,
		"Thumb": 1.0 if thumb_on_controller else 0.0,
	}


func _update_fingers(side: String, ctrl: XRController3D, delta: float) -> void:
	var hand: Dictionary = _hands[side]
	var goals := _curl_goals(ctrl)
	var blend := 1.0 - exp(-finger_smoothing * delta)
	var direction := -1.0 if flip_finger_curl else 1.0

	for finger in FINGERS:
		var c: float = lerpf(hand["curl"][finger], goals[finger], blend)
		hand["curl"][finger] = c
		for joint in hand["joints"][finger]:
			var angle: float = c * joint["max"] * direction
			skeleton.set_bone_pose_rotation(joint["bone"], joint["rest"] * Quaternion(joint["axis"], angle))

func _track_wingspan() -> void:
	if not (left_ctrl.get_has_tracking_data() and right_ctrl.get_has_tracking_data()):
		return
	var span := left_ctrl.global_position.distance_to(right_ctrl.global_position)
	if span > _span_seen and span < 2.5:  
		_span_seen = span
		_apply_scale()

func _update_posture(delta: float) -> void:
	var blend := 1.0 - exp(-posture_smoothing * delta)
	var s := skeleton.global_transform.basis.get_scale().x
	skeleton.position = _base_position 

	
	var pitch_down := rad_to_deg(-camera.global_rotation.x)
	var bend_goal := clampf(inverse_lerp(bend_start_deg, bend_full_deg, pitch_down), 0.0, 1.0)
	_bend = lerpf(_bend, bend_goal, blend)
	for j in _spine:
		var angle: float = deg_to_rad(max_bend_deg) * _bend * j["share"]
		skeleton.set_bone_pose_rotation(j["bone"], j["rest"] * Quaternion(j["axis"], angle))

	
	var neck_global := skeleton.get_bone_global_pose(_neck)
	var skeleton_basis := skeleton.global_transform.basis.orthonormalized()
	var want := skeleton_basis.inverse() * camera.global_transform.basis.orthonormalized() * Basis(Vector3.UP, PI) * _head_rest_basis
	var head_local := neck_global.basis.orthonormalized().inverse() * want
	skeleton.set_bone_pose_rotation(_head, head_local.get_rotation_quaternion())

	
	var eye_world := skeleton.global_transform * (skeleton.get_bone_global_pose(_head) * _eye_in_head)
	_squat = clampf(eye_world.y - camera.global_position.y, 0.0, max_squat * _leg_len * s)
	var hips_rest := skeleton.get_bone_rest(_hips).origin
	skeleton.set_bone_pose_position(_hips, hips_rest - Vector3(0.0, _squat / s, 0.0))

	
	skeleton.global_position += Vector3(camera.global_position.x - eye_world.x, 0.0, camera.global_position.z - eye_world.z)

	
	var squat_ratio := _squat / (_leg_len * s)
	_sit = lerpf(_sit, clampf(inverse_lerp(sit_start, sit_full, squat_ratio), 0.0, 1.0), blend)
	var forward := -global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	foot_target_l.global_position = skeleton.global_transform * (_foot_rest["Left"] as Vector3) + forward * (_thigh_len * s * _sit)
	foot_target_r.global_position = skeleton.global_transform * (_foot_rest["Right"] as Vector3) + forward * (_thigh_len * s * _sit)
