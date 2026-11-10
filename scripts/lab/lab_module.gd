extends Node3D
## Base class for every learning module.
##
## A module builds its own reference scene (geometry, lights, WorldEnvironment)
## in _build_scene() and registers tweakable parameters in _build_params().
## The shell turns those parameter specs into UI rows, presets, A/B snapshots
## and exportable snippets, so a module only describes *what* can be tuned.
##
## Parameter spec fields:
##   key       unique id inside the module, used by presets ("sun.shadow_bias")
##   type      "range" | "bool" | "enum" | "color" | "action"
##   target    Object whose property is edited (Node, Resource or the module)
##   property  real Godot property name, or "shader_parameter/<uniform>" on a
##             ShaderMaterial, or a proxy var declared on the module script
##   tip       Chinese explanation; text before the first "：" is the short name
## Optional flags:
##   meta      not part of presets/recipes (e.g. layer toggles) but kept in A/B
##   transient UI-only trigger (time of day, recipe blend): never stored/reset
##   global    edits engine-wide state; restored when the module is closed
##   no_init   do not push the initial value through the setter on load
##   exp       logarithmic slider
##   on_change Callable invoked after every write

signal values_changed

## Set by tools/validate_runtime.gd: skip GPU-only work such as VoxelGI baking.
static var validating := false

var _params: Array[Dictionary] = []
var _by_key: Dictionary = {}
var _group := "General"
var _presets_cache: Dictionary = {}
## True while presets / snapshots / resets are being applied, so transient
## trigger setters (time of day, recipe blend) don't re-enter.
var _applying := false


func _ready() -> void:
	_build_scene()
	_build_params()
	for p in _params:
		if p.type == "action":
			continue
		var value: Variant = read(p)
		if p.type == "range" and typeof(value) == TYPE_INT:
			p["int"] = true
		p["default"] = value
	_applying = true
	for p in _params:
		if p.type != "action" and not p.get("no_init", false) and not p.get("transient", false):
			write(p, p.default)
	_applying = false
	_after_init()


# --- Overridable API -------------------------------------------------------

func get_title() -> String:
	return name


## BBCode overview shown in the info panel: theory first, then "试一试" tasks.
func get_overview() -> String:
	return ""


## name -> {target: Vector3, yaw: deg, pitch: deg, distance: float}.
## The first entry is the default view.
func get_camera_bookmarks() -> Dictionary:
	return {}


## name -> {param_key: value, "_note": BBCode, "_camera": bookmark, "_debug": Viewport.DebugDraw}.
## Presets are deltas from the defaults: unspecified keys fall back to default.
func get_presets() -> Dictionary:
	return {}


func _build_scene() -> void:
	pass


func _build_params() -> void:
	pass


func _after_init() -> void:
	pass


func on_enter(_shell: Node) -> void:
	pass


func on_exit() -> void:
	restore_globals()


# --- Parameter registration ------------------------------------------------

func group(title: String) -> void:
	_group = title


func add_range(key: String, target: Object, property: String, min_v: float, max_v: float, step: float, tip: String, extra: Dictionary = {}) -> Dictionary:
	return _add({"key": key, "type": "range", "target": target, "property": property, "min": min_v, "max": max_v, "step": step, "tip": tip}, extra)


func add_bool(key: String, target: Object, property: String, tip: String, extra: Dictionary = {}) -> Dictionary:
	return _add({"key": key, "type": "bool", "target": target, "property": property, "tip": tip}, extra)


## options: Array of labels (value = index) or Array of [label, value] pairs.
func add_enum(key: String, target: Object, property: String, options: Array, tip: String, extra: Dictionary = {}) -> Dictionary:
	var opts: Array = []
	for i in options.size():
		var o: Variant = options[i]
		if o is Array:
			opts.append([str(o[0]), o[1]])
		else:
			opts.append([str(o), i])
	return _add({"key": key, "type": "enum", "target": target, "property": property, "options": opts, "tip": tip}, extra)


func add_color(key: String, target: Object, property: String, tip: String, extra: Dictionary = {}) -> Dictionary:
	return _add({"key": key, "type": "color", "target": target, "property": property, "tip": tip}, extra)


func add_action(key: String, label: String, callable: Callable, tip: String) -> Dictionary:
	return _add({"key": key, "type": "action", "label": label, "callable": callable, "tip": tip, "target": self, "property": ""}, {})


func _add(spec: Dictionary, extra: Dictionary) -> Dictionary:
	spec.merge(extra, true)
	spec["group"] = _group
	if not spec.has("label"):
		spec["label"] = spec.property
	if _by_key.has(spec.key):
		push_error("Duplicate param key: %s" % spec.key)
	_params.append(spec)
	_by_key[spec.key] = spec
	return spec


# --- Reading / writing -----------------------------------------------------

func get_params() -> Array[Dictionary]:
	return _params


func get_param(key: String) -> Dictionary:
	return _by_key.get(key, {})


func read(p: Dictionary) -> Variant:
	if p.type == "action":
		return null
	var target: Object = p.target
	if not is_instance_valid(target):
		return null
	var prop: String = p.property
	if target is ShaderMaterial and prop.begins_with("shader_parameter/"):
		var mat := target as ShaderMaterial
		var uniform_name := prop.trim_prefix("shader_parameter/")
		var v: Variant = mat.get_shader_parameter(uniform_name)
		if v == null and mat.shader:
			v = RenderingServer.shader_get_parameter_default(mat.shader.get_rid(), uniform_name)
		return v
	return target.get(prop)


func write(p: Dictionary, value: Variant) -> void:
	if p.type == "action":
		return
	var target: Object = p.target
	if not is_instance_valid(target):
		return
	if p.type == "range":
		value = int(round(float(value))) if p.get("int", false) else float(value)
	elif p.type == "bool":
		value = bool(value)
	var prop: String = p.property
	if target is ShaderMaterial and prop.begins_with("shader_parameter/"):
		(target as ShaderMaterial).set_shader_parameter(prop.trim_prefix("shader_parameter/"), value)
	else:
		target.set(prop, value)
	var cb: Variant = p.get("on_change")
	if cb is Callable:
		(cb as Callable).call()


func get_value(key: String) -> Variant:
	var p := get_param(key)
	return null if p.is_empty() else read(p)


func set_value(key: String, value: Variant, notify := true) -> void:
	var p := get_param(key)
	if p.is_empty():
		push_error("Unknown param key: %s" % key)
		return
	write(p, value)
	if notify:
		values_changed.emit()


# --- State, presets, blending ---------------------------------------------

static func is_state_param(p: Dictionary) -> bool:
	return p.type != "action" and not p.get("meta", false) and not p.get("transient", false)


static func is_snapshot_param(p: Dictionary) -> bool:
	return p.type != "action" and not p.get("transient", false)


func capture_state(for_snapshot := false) -> Dictionary:
	var state := {}
	for p in _params:
		if is_state_param(p) or (for_snapshot and is_snapshot_param(p)):
			state[p.key] = read(p)
	return state


## Writes every state param (missing keys fall back to defaults). Meta params
## are only written when the state explicitly contains them (A/B snapshots).
func apply_state(state: Dictionary) -> void:
	_applying = true
	for p in _params:
		if is_state_param(p):
			write(p, state.get(p.key, p.default))
		elif is_snapshot_param(p) and state.has(p.key):
			write(p, state[p.key])
	_applying = false
	values_changed.emit()


func reset_all() -> void:
	_applying = true
	for p in _params:
		if p.type != "action":
			write(p, p.default)
	_applying = false
	values_changed.emit()


func presets() -> Dictionary:
	if _presets_cache.is_empty():
		_presets_cache = get_presets()
	return _presets_cache


func preset_state(preset_name: String) -> Dictionary:
	if not presets().has(preset_name):
		push_warning("Unknown preset: %s" % preset_name)
	var preset: Dictionary = presets().get(preset_name, {})
	var state := {}
	for p in _params:
		if is_state_param(p):
			state[p.key] = preset.get(p.key, p.default)
	return state


func apply_preset(preset_name: String) -> void:
	apply_state(preset_state(preset_name))


func blend_states(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for p in _params:
		if is_state_param(p):
			out[p.key] = blend_value(p, a.get(p.key, p.default), b.get(p.key, p.default), t)
	return out


static func blend_value(p: Dictionary, va: Variant, vb: Variant, t: float) -> Variant:
	match p.type:
		"range":
			var v := lerpf(float(va), float(vb), t)
			return int(round(v)) if p.get("int", false) else v
		"color":
			return (va as Color).lerp(vb as Color, t)
		_:
			return va if t < 0.5 else vb


func restore_globals() -> void:
	for p in _params:
		if p.get("global", false):
			write(p, p.default)


# --- Helpers for UI / export / validation ---------------------------------

## Short Chinese name: the part of the tip before the first "：".
static func short_tip(p: Dictionary) -> String:
	var tip: String = p.get("tip", "")
	var idx := tip.find("：")
	return tip.substr(0, idx) if idx > 0 and idx <= 16 else ""


static func values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) == TYPE_FLOAT or typeof(b) == TYPE_FLOAT:
		return is_equal_approx(float(a), float(b))
	if a is Color and b is Color:
		return (a as Color).is_equal_approx(b)
	return a == b


func export_snippet() -> String:
	var lines := PackedStringArray()
	lines.append("# %s — 与默认值不同的参数 (key = 值  # 说明)" % get_title())
	for p in _params:
		if p.type == "action" or p.get("transient", false):
			continue
		var v: Variant = read(p)
		if not values_equal(v, p.default):
			lines.append("%s = %s    # %s.%s %s" % [p.key, var_to_str(v), target_name(p.target), p.property, short_tip(p)])
	if lines.size() == 1:
		lines.append("# (全部为默认值)")
	return "\n".join(lines)


static func target_name(target: Object) -> String:
	if target is Node:
		return String((target as Node).name)
	if target is Resource and (target as Resource).resource_name != "":
		return (target as Resource).resource_name
	return target.get_class() if target else "?"


func validate_params() -> PackedStringArray:
	var errs := PackedStringArray()
	for p in _params:
		if p.type == "action":
			if not (p.callable is Callable and (p.callable as Callable).is_valid()):
				errs.append("%s: invalid action callable" % p.key)
			continue
		var target: Object = p.target
		if not is_instance_valid(target):
			errs.append("%s: target is null/freed" % p.key)
			continue
		var prop: String = p.property
		if target is ShaderMaterial and prop.begins_with("shader_parameter/"):
			var found := false
			var shader := (target as ShaderMaterial).shader
			if shader:
				for u in shader.get_shader_uniform_list():
					if u.name == prop.trim_prefix("shader_parameter/"):
						found = true
			if not found:
				errs.append("%s: shader has no uniform '%s'" % [p.key, prop])
			continue
		var names := {}
		for info in target.get_property_list():
			names[info.name] = true
		if not names.has(prop):
			errs.append("%s: %s has no property '%s'" % [p.key, target.get_class(), prop])
		if p.default == null:
			errs.append("%s: default value is null" % p.key)
	for preset_name in presets():
		var preset: Dictionary = presets()[preset_name]
		for k in preset:
			if String(k).begins_with("_"):
				continue
			if not _by_key.has(k):
				errs.append("preset '%s': unknown key '%s'" % [preset_name, k])
				continue
			var p: Dictionary = _by_key[k]
			if not is_state_param(p):
				errs.append("preset '%s': key '%s' is meta/transient" % [preset_name, k])
			var v: Variant = preset[k]
			var ok := true
			match p.type:
				"range":
					ok = typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT
				"bool":
					ok = typeof(v) == TYPE_BOOL
				"color":
					ok = v is Color
				"enum":
					ok = false
					for o in p.options:
						if o[1] == v:
							ok = true
			if not ok:
				errs.append("preset '%s': bad value %s for '%s' (%s)" % [preset_name, str(v), k, p.type])
		var cam: String = preset.get("_camera", "")
		if cam != "" and not get_camera_bookmarks().has(cam):
			errs.append("preset '%s': unknown camera bookmark '%s'" % [preset_name, cam])
	return errs
