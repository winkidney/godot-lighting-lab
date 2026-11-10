extends Camera3D
## Orbit camera: left/right drag = orbit, middle or Shift+drag = pan,
## wheel = zoom, WASD/QE = move the pivot. Bookmarks animate smoothly.

var target := Vector3.ZERO
var yaw := 0.0
var pitch := -20.0
var distance := 8.0
var min_distance := 0.4
var max_distance := 400.0
## Vertical field of view. The camera uses an off-centre (frustum) projection
## so the orbit pivot sits in the middle of the area not covered by UI panels.
var view_fov := 55.0
var _insets := Vector4.ZERO  # left, top, right, bottom in pixels
var _last_vp := Vector2.ZERO

var _goal: Dictionary = {}
var _drag := 0  # 0 none, 1 orbit, 2 pan
## False while a script drives the camera (tutorial recording): mouse and
## keyboard are ignored so a stray key press can't move the shot.
var input_enabled := true


func _ready() -> void:
	near = 0.05
	far = 2000.0
	projection = Camera3D.PROJECTION_FRUSTUM
	_update_projection()
	_update_transform()


## Pixel sizes of the UI panels covering each screen edge (0 when UI hidden).
func set_insets(left: float, top: float, right: float, bottom: float) -> void:
	_insets = Vector4(left, top, right, bottom)
	_update_projection()


## Lens shift: same vertical FOV, but the projection centre is moved to the
## centre of the free area so panels don't hide the subject.
func _update_projection() -> void:
	var vp := get_viewport().get_visible_rect().size
	_last_vp = vp
	if vp.y <= 0.0:
		return
	var h := 2.0 * near * tan(deg_to_rad(view_fov) * 0.5)
	var w := h * vp.x / vp.y
	var cx := (_insets.x - _insets.z) * 0.5
	var cy := (_insets.y - _insets.w) * 0.5
	size = h
	frustum_offset = Vector2(-cx / vp.x * w, cy / vp.y * h)


func apply_bookmark(bm: Dictionary, instant := false) -> void:
	var goal := {
		"target": bm.get("target", target),
		"yaw": float(bm.get("yaw", yaw)),
		"pitch": float(bm.get("pitch", pitch)),
		"distance": float(bm.get("distance", distance)),
	}
	if instant:
		target = goal.target
		yaw = goal.yaw
		pitch = goal.pitch
		distance = goal.distance
		_goal = {}
		_update_transform()
	else:
		_goal = goal


func _process(delta: float) -> void:
	if get_viewport().get_visible_rect().size != _last_vp:
		_update_projection()
	_move_with_keys(delta)
	if _goal.is_empty():
		return
	var w := 1.0 - exp(-delta * 7.0)
	target = target.lerp(_goal.target, w)
	yaw = rad_to_deg(lerp_angle(deg_to_rad(yaw), deg_to_rad(_goal.yaw), w))
	pitch = lerpf(pitch, _goal.pitch, w)
	distance = lerpf(distance, _goal.distance, w)
	if target.distance_to(_goal.target) < 0.005 and absf(angle_difference(deg_to_rad(yaw), deg_to_rad(_goal.yaw))) < 0.001 and absf(distance - _goal.distance) < 0.005:
		apply_bookmark(_goal, true)
	_update_transform()


func _move_with_keys(delta: float) -> void:
	if not input_enabled:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	var move := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		move.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		move.z += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		move.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		move.x += 1.0
	if Input.is_physical_key_pressed(KEY_E):
		move.y += 1.0
	if Input.is_physical_key_pressed(KEY_Q):
		move.y -= 1.0
	if move == Vector3.ZERO:
		return
	var flat := Basis(Vector3.UP, deg_to_rad(yaw))
	target += (flat * move) * maxf(distance, 2.0) * 0.6 * delta
	_goal = {}
	_update_transform()


func _update_transform() -> void:
	var rot := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0))
	global_transform = Transform3D(rot, target + rot * Vector3(0.0, 0.0, distance))


func _input(event: InputEvent) -> void:
	# Releases may happen over the UI, which would swallow them before
	# _unhandled_input; always end drags here without consuming the event.
	if event is InputEventMouseButton and not event.pressed:
		_drag = 0


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					_drag = 2 if mb.shift_pressed else 1
			MOUSE_BUTTON_MIDDLE:
				if mb.pressed:
					_drag = 2
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom(0.88)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom(1.0 / 0.88)
	elif event is InputEventMouseMotion and _drag != 0:
		var mm := event as InputEventMouseMotion
		if _drag == 1:
			yaw -= mm.relative.x * 0.3
			pitch = clampf(pitch - mm.relative.y * 0.3, -89.0, 89.0)
		else:
			var b := global_transform.basis
			target += (-b.x * mm.relative.x + b.y * mm.relative.y) * distance * 0.0016
		_goal = {}
		_update_transform()


func _zoom(factor: float) -> void:
	distance = clampf(distance * factor, min_distance, max_distance)
	_goal = {}
	_update_transform()
