extends SkeletonModifier3D
## Runs after the arm IK. Points each hand the way its controller points (the rotation stored on
## TargetL / TargetR by charachter.gd) and moves part of the twist into the forearm, so the wrist
## doesn't wring like a wet towel when you rotate your hand.
## Must sit BELOW the two TwoBoneIK3D nodes in the Skeleton3D's children.

## How much of the twist goes into the forearm (0 = all in the wrist, 1 = all in the forearm).
@export_range(0.0, 1.0) var forearm_twist_share := 0.5

var _sides := []
var _last_frame := -1


func _process_modification_with_delta(_delta: float) -> void:
	_apply()


# Older engine versions call this one instead.
func _process_modification() -> void:
	_apply()


func _apply() -> void:
	var frame := Engine.get_process_frames()
	if frame == _last_frame:
		return
	_last_frame = frame

	var skeleton := get_skeleton()
	if skeleton == null:
		return

	if _sides.is_empty():
		for info in [["Left", "TargetL"], ["Right", "TargetR"]]:
			var fore := skeleton.find_bone("mixamorig_%sForeArm" % info[0])
			var hand := skeleton.find_bone("mixamorig_%sHand" % info[0])
			var target := skeleton.get_node_or_null(info[1]) as Node3D
			if fore >= 0 and hand >= 0 and target != null:
				_sides.append({"fore": fore, "hand": hand, "target": target})

	var to_skeleton := skeleton.global_transform.basis.orthonormalized().inverse()

	for side in _sides:
		var fore: int = side["fore"]
		var hand: int = side["hand"]
		var target: Node3D = side["target"]

		# Wanted hand rotation, in skeleton space.
		var wanted := (to_skeleton * target.global_transform.basis.orthonormalized()).get_rotation_quaternion()

		# How far the wanted hand is rotated about the forearm's own long axis (local Y).
		var fore_q := skeleton.get_bone_global_pose(fore).basis.orthonormalized().get_rotation_quaternion()
		var rel := fore_q.inverse() * wanted
		if rel.w < 0.0:
			rel = -rel
		var twist := 2.0 * atan2(rel.y, rel.w)

		# The forearm takes its share. Rolling it about its own axis doesn't move the hand.
		var fore_pose := skeleton.get_bone_pose_rotation(fore)
		skeleton.set_bone_pose_rotation(fore, fore_pose * Quaternion(Vector3.UP, twist * forearm_twist_share))

		# The wrist makes up the rest, so the hand ends exactly on the wanted rotation.
		var new_fore_q := skeleton.get_bone_global_pose(fore).basis.orthonormalized().get_rotation_quaternion()
		skeleton.set_bone_pose_rotation(hand, new_fore_q.inverse() * wanted)
