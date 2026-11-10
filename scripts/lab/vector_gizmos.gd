extends MeshInstance3D
## Debug line renderer: per-vertex normal (blue) / tangent (red) /
## binormal (green), and the N-L-V-H-R vectors of a lighting model.

const COL_N := Color(0.3, 0.55, 1.0)
const COL_T := Color(1.0, 0.3, 0.3)
const COL_B := Color(0.3, 1.0, 0.4)
const COL_L := Color(1.0, 0.85, 0.2)
const COL_V := Color(0.95, 0.95, 0.95)
const COL_H := Color(1.0, 0.35, 0.9)
const COL_R := Color(0.3, 0.95, 0.95)

var _im := ImmediateMesh.new()
var _mat := StandardMaterial3D.new()
var _labels: Dictionary = {}
var _arrows: Dictionary = {}


func _init() -> void:
	mesh = _im
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func set_on_top(enabled: bool) -> void:
	_mat.no_depth_test = enabled
	_mat.render_priority = 10 if enabled else 0


func clear() -> void:
	_im.clear_surfaces()
	for l in _labels.values():
		(l as Label3D).visible = false
	for a in _arrows.values():
		(a as MeshInstance3D).visible = false


## Draws the TBN frame of every few vertices of mi's first surface.
func draw_mesh_frame(mi: MeshInstance3D, length := 0.15, max_vertices := 700) -> void:
	clear()
	if mi == null or mi.mesh == null:
		return
	var arrays := mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var tans := PackedFloat32Array()
	if arrays[Mesh.ARRAY_TANGENT] != null:
		tans = arrays[Mesh.ARRAY_TANGENT]
	if verts.is_empty():
		return
	var xf := global_transform.affine_inverse() * mi.global_transform
	var stride := maxi(1, verts.size() / max_vertices)
	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for i in range(0, verts.size(), stride):
		var p := xf * verts[i]
		var n := (xf.basis * norms[i]).normalized()
		_line(p, p + n * length, COL_N)
		if tans.size() >= (i + 1) * 4:
			var t3 := Vector3(tans[i * 4], tans[i * 4 + 1], tans[i * 4 + 2])
			var w := tans[i * 4 + 3]
			# Godot builds the binormal as cross(normal, tangent) * w.
			var b3 := norms[i].cross(t3) * w
			_line(p, p + (xf.basis * t3).normalized() * length, COL_T)
			_line(p, p + (xf.basis * b3).normalized() * length, COL_B)
	_im.surface_end()


## Draws lighting vectors as arrows at world point p. All directions are unit
## vectors pointing away from the surface (L towards light, V towards the eye).
func draw_lighting_vectors(p: Vector3, n: Vector3, l: Vector3, v: Vector3, length := 1.0) -> void:
	clear()
	var h := (l + v).normalized()
	# Godot's reflect() mirrors across the normal line: R = 2(N·L)N - L.
	var r := l.reflect(n)
	var local := global_transform.affine_inverse()
	var lp := local * p
	var items := [["N", n, COL_N], ["L", l, COL_L], ["V", v, COL_V], ["H", h, COL_H], ["R", r, COL_R]]
	for item in items:
		var dir: Vector3 = (local.basis * (item[1] as Vector3)).normalized()
		_arrow(item[0], lp, dir, length, item[2])
		_label(item[0], lp + dir * (length + 0.15), item[2])


func _arrow(key: String, from: Vector3, dir: Vector3, length: float, c: Color) -> void:
	var mi: MeshInstance3D = _arrows.get(key)
	if mi == null:
		var shaft := CylinderMesh.new()
		shaft.top_radius = 0.012
		shaft.bottom_radius = 0.012
		shaft.height = 1.0
		shaft.radial_segments = 8
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = c
		m.no_depth_test = _mat.no_depth_test
		m.render_priority = _mat.render_priority
		shaft.material = m
		mi = MeshInstance3D.new()
		mi.mesh = shaft
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var tip := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.045
		cone.height = 0.12
		cone.radial_segments = 12
		cone.material = m
		tip.mesh = cone
		tip.name = "Tip"
		mi.add_child(tip)
		add_child(mi)
		_arrows[key] = mi
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x := up.cross(dir).normalized()
	var z := x.cross(dir).normalized()
	mi.transform = Transform3D(Basis(x, dir * length, z), from + dir * length * 0.5)
	var tip_node := mi.get_node("Tip") as MeshInstance3D
	tip_node.transform = Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 1.0 / length, 0), Vector3(0, 0, 1)), Vector3(0, 0.5, 0))
	mi.visible = true


func _line(a: Vector3, b: Vector3, c: Color) -> void:
	_im.surface_set_color(c)
	_im.surface_add_vertex(a)
	_im.surface_set_color(c)
	_im.surface_add_vertex(b)


func _label(text: String, pos: Vector3, c: Color) -> void:
	var l: Label3D = _labels.get(text)
	if l == null:
		l = Label3D.new()
		l.text = text
		l.font_size = 48
		l.outline_size = 10
		l.pixel_size = 0.004
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.modulate = c
		add_child(l)
		_labels[text] = l
	l.position = pos
	l.visible = true
