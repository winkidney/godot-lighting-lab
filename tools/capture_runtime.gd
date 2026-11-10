extends SceneTree
## Windowed capture (run via `make capture [ONLY=03]`): one screenshot of each
## module with the UI, then one per preset with the UI hidden. Writes
## captures/index.txt mapping file names to preset names for review.

const LabModule := preload("res://scripts/lab/lab_module.gd")


func _initialize() -> void:
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	var out_dir := "res://captures"
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	var abs_dir := ProjectSettings.globalize_path(out_dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)

	var shell: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(shell)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	await _frames(10)
	var index := PackedStringArray()
	var modules: Array = shell.MODULES
	for i in modules.size():
		var info: Dictionary = modules[i]
		if only != "" and not only.split(",").has(info.id):
			continue
		var settle := 120 if info.id in ["04", "05"] else 45
		shell.load_module(i)
		await _frames(settle)
		index.append(_save(abs_dir, "%s_00_overview.png" % info.id, info.title + " (UI)"))
		shell.set_ui_visible(false)
		var m: LabModule = shell.module
		var names: Array = m.presets().keys()
		for j in names.size():
			var preset_name: String = names[j]
			shell.select_preset(preset_name)
			var preset: Dictionary = m.presets()[preset_name]
			if preset.has("_camera"):
				shell.apply_bookmark(preset._camera, true)
			await _frames(settle)
			index.append(_save(abs_dir, "%s_%02d.png" % [info.id, j + 1], preset_name))
		shell.select_preset("")
		shell.set_ui_visible(true)
	var f := FileAccess.open(abs_dir.path_join("index.txt"), FileAccess.WRITE)
	f.store_string("\n".join(index) + "\n")
	f.close()
	print("CAPTURE DONE: %d images in %s" % [index.size(), abs_dir])
	quit(0)


func _save(dir: String, file_name: String, label: String) -> String:
	var img := root.get_texture().get_image()
	img.save_png(dir.path_join(file_name))
	print("captured %s  <- %s" % [file_name, label])
	return "%s\t%s" % [file_name, label]
