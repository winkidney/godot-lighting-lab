extends SceneTree
## Headless logic validation (run via `make validate`):
## - every module loads,
## - every parameter targets a real property, and accepts min / max / default,
## - every enum option and bool state can be applied,
## - every preset references known keys with well-typed values and applies.
## Prints "VALIDATION FAILED" and exits 1 on any problem.

const LabModule := preload("res://scripts/lab/lab_module.gd")

var _errors := PackedStringArray()


func _initialize() -> void:
	LabModule.validating = true
	_run.call_deferred()


func _run() -> void:
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(shell)
	await process_frame
	var modules: Array = shell.MODULES
	for i in modules.size():
		var info: Dictionary = modules[i]
		if only != "" and not only.split(",").has(info.id):
			continue
		print("== module %s" % info.title)
		shell.load_module(i)
		await process_frame
		var m: LabModule = shell.module
		for e in m.validate_params():
			_errors.append("[%s] %s" % [info.id, e])
		var count := 0
		for p in m.get_params():
			if p.type == "action":
				continue
			count += 1
			for v in _probe_values(p):
				m.write(p, v)
			m.write(p, p.default)
			if not LabModule.values_equal(m.read(p), p.default) and p.type != "color":
				_errors.append("[%s] %s: default not restored (got %s, want %s)" % [info.id, p.key, m.read(p), p.default])
		await process_frame
		for preset_name in m.presets():
			shell.select_preset(preset_name)
			await process_frame
		shell.select_preset("")
		await process_frame
		shell.save_snapshot("A")
		shell.save_snapshot("B")
		shell.toggle_snapshot()
		var _snippet: String = m.export_snippet()
		print("   %d params, %d presets OK" % [count, m.presets().size()])
	shell.queue_free()
	await process_frame
	if _errors.is_empty():
		print("VALIDATION PASSED")
		quit(0)
	else:
		for e in _errors:
			printerr(e)
		printerr("VALIDATION FAILED: %d problem(s)" % _errors.size())
		quit(1)


func _probe_values(p: Dictionary) -> Array:
	match p.type:
		"range":
			return [p.min, p.max, (p.min + p.max) * 0.5]
		"bool":
			return [true, false]
		"enum":
			var vals := []
			for o in p.options:
				vals.append(o[1])
			return vals
		"color":
			return [Color(0.2, 0.4, 0.8)]
	return []
