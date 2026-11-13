extends XRCamera3D

func _ready() -> void:
	return
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)

	var mat := ShaderMaterial.new()
	mat.shader = preload("res://PSX.gdshader")

	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = mat
	mi.extra_cull_margin = 16384.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
