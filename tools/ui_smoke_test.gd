extends SceneTree
## UI smoke test (part of `make validate`): drives the real parameter widgets,
## A/B snapshots, reset, recipe blending, time of day and layer toggles.
var fails := 0
func _check(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		fails += 1
func _find_row(panel: Node, key: String) -> Dictionary:
	for r in panel._rows:
		if r.spec.key == key:
			return r
	return {}
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(shell)
	await process_frame
	shell.load_module(2)
	await process_frame
	var m: Node = shell.module
	var panel: Node = shell.param_panel
	var row := _find_row(panel, "sun.shadow_bias")
	(row.slider as HSlider).value = 1.235
	_check(is_equal_approx(m._sun.shadow_bias, 1.235), "slider writes DirectionalLight3D.shadow_bias")
	_check(is_equal_approx((row.spin as SpinBox).value, 1.235), "spinbox mirrors slider")
	row = _find_row(panel, "sun.visible")
	(row.check as CheckButton).button_pressed = false
	_check(m._sun.visible == false, "check button toggles sun.visible")
	row = _find_row(panel, "omni.omni_shadow_mode")
	(row.option as OptionButton).select(1)
	(row.option as OptionButton).item_selected.emit(1)
	_check(m._omni.omni_shadow_mode == OmniLight3D.SHADOW_CUBE, "option button sets omni_shadow_mode")
	shell.save_snapshot("A")
	(_find_row(panel, "sun.shadow_bias").slider as HSlider).value = 3.0
	shell.save_snapshot("B")
	shell.toggle_snapshot()
	_check(is_equal_approx(m._sun.shadow_bias, 1.235), "A/B toggle restores A")
	_check(is_equal_approx((_find_row(panel, "sun.shadow_bias").slider as HSlider).value, 1.235), "panel refreshed after A/B")
	shell.select_preset("")
	_check(is_equal_approx(m._sun.shadow_bias, _find_row(panel, "sun.shadow_bias").spec.default), "reset restores default")
	shell.load_module(4)
	await process_frame
	m = shell.module
	m.set_value("recipe.blend", 0.0)
	var noon_energy: float = m._key.light_energy
	m.recipe_b = "④ 月夜"
	m.recipe_blend = 1.0
	_check(m._key.light_energy < noon_energy, "recipe blend to night lowers key energy (%.2f -> %.2f)" % [noon_energy, m._key.light_energy])
	m.time_of_day = 18.0
	_check(m.key_elevation < 20.0, "time_of_day 18h puts sun low (%.1f°)" % m.key_elevation)
	m.layer_fog = false
	_check(m._env.fog_enabled == false, "layer toggle disables fog")
	var snippet: String = m.export_snippet()
	_check(snippet.contains("key.light_energy"), "export snippet lists changed params")
	if fails == 0:
		print("UI TEST PASSED")
	else:
		printerr("VALIDATION FAILED: UI test, %d failure(s)" % fails)
	quit(fails)
