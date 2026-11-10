extends SceneTree
## Drives the lab like a camera operator for the tutorial video.
##
##   --check                    headless: validate every module/preset/key/
##                              bookmark/debug name referenced by video/plan.json
##   --chapter=c2 [--timeline=] play one chapter of video/build/timeline.json.
##                              Under Movie Maker (--write-movie, fixed fps) the
##                              time is frame/fps, so the render is exact; without
##                              it the chapter plays in real time as a preview.
##   --from=c2s3                (preview) jump to a shot: earlier events are
##                              applied instantly, sweeps snap to their end.
##   --stills=/abs/dir          one settled screenshot per shot (at its last
##                              event) for reviewing framing before a render.
##
## Timeline events are produced by video/pipeline.py (assemble); see the action
## table in that file and video/plan.json.

const LabModule := preload("res://scripts/lab/lab_module.gd")
const Overlay := preload("res://scripts/tutorial/tutorial_overlay.gd")

var shell: Node
var overlay: Overlay
var chapter: Dictionary
var fps := 30
var movie := false

var _events: Array = []  # sorted {t, kind, ...}
var _next := 0
var _frame := 0
var _t_start_usec := 0
var _skip_to := 0.0
var _sweeps: Array = []  # {p, from, to, t0, dur, curve}
var _cam: Dictionary = {}  # {from, to, t0, dur}
var _orbit := 0.0
var _errors := PackedStringArray()
var _report: Dictionary = {}
var _frame_label: Label  # --debug-frames: prints the director frame index on screen
var _hidden_labels: Array[Node] = []  # Label3D hidden by a shot with "labels": false


func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	if args.has("check"):
		LabModule.validating = true
		_check.call_deferred()
	else:
		_start.call_deferred(args)


# --- Render / preview -----------------------------------------------------------

func _start(args: Dictionary) -> void:
	var path: String = args.get("timeline", "res://video/build/timeline.json")
	var timeline: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	if timeline.is_empty():
		_fail("cannot read timeline %s" % path)
		return
	fps = int(timeline.fps)
	movie = Engine.get_write_movie_path() != ""
	var wanted: String = args.get("chapter", "")
	for c in timeline.chapters:
		if c.id == wanted:
			chapter = c
	if chapter.is_empty():
		_fail("unknown chapter %s" % wanted)
		return
	var size := Vector2i(int(timeline.size[0]), int(timeline.size[1]))
	if DisplayServer.window_get_size() != size:
		DisplayServer.window_set_size(size)
	shell = load("res://scenes/main.tscn").instantiate()
	root.add_child(shell)
	if int(shell.module_index) != int(chapter.module):
		shell.load_module(int(chapter.module))
	shell.set_process_input(false)
	shell.camera.input_enabled = false
	shell.set_ui_visible(false)
	overlay = Overlay.new()
	root.add_child(overlay)
	overlay.module = shell.module
	var marks: Array = []
	for c in timeline.chapters:
		marks.append(float(c.start))
	var chapters: Array = timeline.chapters
	overlay.setup_timeline(float(timeline.total), marks, float(chapter.start), float(chapter.duration), chapter.id == chapters[-1].id)
	_build_events()
	if args.has("debug-frames"):
		_frame_label = Label.new()
		_frame_label.position = Vector2(860, 420)
		_frame_label.add_theme_font_size_override("font_size", 160)
		_frame_label.add_theme_color_override("font_color", Color.RED)
		overlay.add_child(_frame_label)
	if args.has("from"):
		for e in _events:
			if e.kind == "shot" and e.shot.id == args.from:
				_skip_to = float(e.t)
	await process_frame
	var vp := root.get_visible_rect().size
	if Vector2i(vp) != size:
		_fail("viewport is %s, expected %s (check display scaling / --resolution)" % [vp, size])
		return
	_report = {"chapter": chapter.id, "frames": int(chapter.frames), "fps": fps, "movie": movie,
		"first_frame_drawn": Engine.get_frames_drawn(), "viewport": [vp.x, vp.y]}
	if args.has("stills"):
		if args.has("clean"):
			overlay.visible = false
		_stills(str(args.stills), str(args.get("at", "")))
		return
	_t_start_usec = Time.get_ticks_usec()
	process_frame.connect(_tick)
	_tick()


## at: optional "c1s1:2.0,c4s2:4.5" = only these shots, at these seconds
## after the shot start (default: every shot, at its last event).
func _stills(dir: String, at: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var picks := {}
	for item in at.split(",", false):
		var kv := item.split(":")
		picks[kv[0]] = float(kv[1]) if kv.size() > 1 else -1.0
	for e in _events.duplicate():
		if e.kind != "shot":
			continue
		var shot: Dictionary = e.shot
		if not picks.is_empty() and not picks.has(shot.id):
			continue
		var t := float(shot.start) + 0.6
		for ev in shot.get("events", []):
			t = maxf(t, float(ev.t) + minf(float(ev.get("dur", 0.0)), 6.0) + 0.4)
		if picks.get(shot.id, -1.0) >= 0.0:
			t = float(shot.start) + float(picks[shot.id])
		t = minf(t, float(shot.start) + float(shot.duration) - 0.4)
		_fire_until(t, true)
		for i in (50 if picks.is_empty() else 120):
			overlay.update(t)
			await process_frame
		var img := root.get_texture().get_image()
		img.save_png(dir.path_join("%s.png" % shot.id))
		print("still %s t=%.2f" % [shot.id, t])
	print("DIRECTOR DONE stills %s" % chapter.id)
	shell.module.on_exit()
	quit(0)


func _build_events() -> void:
	_events.clear()
	var card: Dictionary = chapter.get("card", {})
	_events.append({"t": 0.0, "kind": "title", "card": card, "dur": float(chapter.card_duration)})
	for shot in chapter.shots:
		_events.append({"t": float(shot.start), "kind": "shot", "shot": shot})
		for ev in shot.get("events", []):
			var e: Dictionary = ev.duplicate()
			e["kind"] = "action"
			e["shot_end"] = float(shot.start) + float(shot.duration)
			_events.append(e)
	# Stable sort: shot starts before actions scheduled at the same instant.
	for i in _events.size():
		_events[i]["seq"] = i
	_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.t < b.t or (is_equal_approx(a.t, b.t) and a.seq < b.seq))


func _now() -> float:
	if movie:
		return float(_frame) / float(fps)
	return _skip_to + float(Time.get_ticks_usec() - _t_start_usec) / 1e6


func _tick() -> void:
	var t := _now()
	if _skip_to > 0.0 and _frame == 0:
		_fire_until(_skip_to, true)
	_fire_until(t, false)
	_update_sweeps(t)
	_update_camera(t)
	overlay.update(t)
	if _frame_label:
		_frame_label.text = str(_frame)
	_frame += 1
	# One extra tick past the end so the last needed frame is surely drawn
	# and written before quitting; pipeline.py keeps exactly `frames` images.
	if movie and _frame > int(chapter.frames):
		_finish()
	elif not movie and t >= float(chapter.duration) + 0.5:
		_finish()


func _finish() -> void:
	process_frame.disconnect(_tick)
	_report["frames_ticked"] = _frame
	_report["last_frame_drawn"] = Engine.get_frames_drawn()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--report="):
			var f := FileAccess.open(a.trim_prefix("--report="), FileAccess.WRITE)
			f.store_string(JSON.stringify(_report, "  "))
			f.close()
	print("DIRECTOR DONE %s %s" % [chapter.id, JSON.stringify(_report)])
	shell.module.on_exit()
	quit(0)


func _fire_until(t: float, instant: bool) -> void:
	while _next < _events.size() and float(_events[_next].t) <= t + 1e-6:
		_fire(_events[_next], instant)
		_next += 1
	if instant:
		_update_sweeps(INF)
		if not _cam.is_empty():
			shell.camera.apply_bookmark(_cam.to, true)
			_cam = {}


func _fire(e: Dictionary, _instant: bool) -> void:
	var m: LabModule = shell.module
	match e.kind:
		"title":
			overlay.show_title_card(e.card, 0.0, e.dur)
		"shot":
			var shot: Dictionary = e.shot
			overlay.clear_cards()
			overlay.clear_hud()
			_sweeps.clear()
			_cam = {}
			if shot.has("preset"):
				_apply_preset(str(shot.preset))
			if shot.has("camera"):
				shell.camera.apply_bookmark(_bookmark(shot.camera), true)
			_orbit = float(shot.get("orbit", 0.0))
			# Shots may hide the scene's 3D name labels when they clutter a
			# close-up. Only labels hidden here are restored later, so labels the
			# module manages itself (e.g. the N/L/V/H/R letters) keep their state.
			for n in _hidden_labels:
				if is_instance_valid(n):
					(n as Label3D).visible = true
			_hidden_labels.clear()
			if not bool(shot.get("labels", true)):
				for n in shell.module.find_children("*", "Label3D", true, false):
					if (n as Label3D).visible:
						(n as Label3D).visible = false
						_hidden_labels.append(n)
			overlay.set_tag(str(chapter.card.get("num", "")), str(shot.get("label", "")))
		"action":
			_action(e, m)


func _action(e: Dictionary, m: LabModule) -> void:
	var t := float(e.t)
	match str(e["do"]):
		"preset":
			if e.get("shell", false):
				shell.select_preset(str(e.name))
				var idx: int = shell._preset_names.find(str(e.name))
				if idx >= 0:
					shell._preset_list.select(idx + 1)
			else:
				_apply_preset(str(e.name))
		"set":
			var p := m.get_param(str(e.key))
			m.set_value(str(e.key), resolve_value(p, e.value), shell._ui_root.visible)
		"sweep":
			var p := m.get_param(str(e.key))
			var from: Variant = resolve_value(p, e.from) if e.has("from") else m.read(p)
			_sweeps.append({"p": p, "from": from, "to": resolve_value(p, e.to), "t0": t,
				"dur": float(e.get("dur", 2.0)), "curve": str(e.get("curve", "smooth"))})
		"camera":
			var to := _bookmark(e.get("bookmark", e.get("view", {})))
			var dur := float(e.get("dur", 0.0))
			if dur <= 0.0:
				shell.camera.apply_bookmark(to, true)
			else:
				var c = shell.camera
				_cam = {"from": {"target": c.target, "yaw": c.yaw, "pitch": c.pitch, "distance": c.distance},
					"to": to, "t0": t, "dur": dur}
		"orbit":
			_orbit = float(e.rate)
		"debug":
			shell.set_debug_draw(debug_mode(str(e.mode)))
		"hud":
			overlay.set_hud(e.get("keys", []))
		"card":
			var t1 := t + float(e.dur) if e.has("dur") else float(e.shot_end)
			overlay.show_card(str(e.get("title", "")), str(e.get("body", "")), t, t1)
		"ui":
			shell.set_ui_visible(bool(e.on))
			overlay.set_minimal(bool(e.on))
			if bool(e.on):
				shell.show_overview()
		"snapshot":
			if str(e.slot) == "toggle":
				shell.toggle_snapshot()
			else:
				shell.save_snapshot(str(e.slot))
		"export":
			# Same text as the "导出参数" button, without touching the clipboard.
			shell._show_info("导出参数", "[code]%s[/code]" % m.export_snippet().replace("[", "[lb]"))
		"call":
			var p := m.get_param(str(e.key))
			(p.callable as Callable).call()
		"endcard":
			overlay.show_endcard(t)
		_:
			push_error("unknown action %s" % e["do"])


func _apply_preset(preset_name: String) -> void:
	var m: LabModule = shell.module
	if preset_name == "":
		m.reset_all()
		shell.set_debug_draw(Viewport.DEBUG_DRAW_DISABLED)
		return
	m.apply_preset(preset_name)
	shell.set_debug_draw(m.presets()[preset_name].get("_debug", Viewport.DEBUG_DRAW_DISABLED))


func _bookmark(spec: Variant) -> Dictionary:
	if spec is String:
		return shell.module.get_camera_bookmarks()[spec]
	var d: Dictionary = spec
	var out := d.duplicate()
	if d.has("target") and d.target is Array:
		out["target"] = Vector3(d.target[0], d.target[1], d.target[2])
	return out


func _update_sweeps(t: float) -> void:
	var m: LabModule = shell.module
	var done: Array = []
	for s in _sweeps:
		var u := clampf((t - float(s.t0)) / maxf(float(s.dur), 1e-4), 0.0, 1.0)
		var p: Dictionary = s.p
		var v: Variant
		if s.curve == "exp" and p.type == "range" and float(s.from) > 0.0 and float(s.to) > 0.0:
			v = float(s.from) * pow(float(s.to) / float(s.from), smoothstep(0.0, 1.0, u))
		else:
			v = LabModule.blend_value(p, s.from, s.to, smoothstep(0.0, 1.0, u) if s.curve != "linear" else u)
		m.write(p, v)
		if u >= 1.0:
			done.append(s)
	for s in done:
		_sweeps.erase(s)
	if not _sweeps.is_empty() or not done.is_empty():
		if shell._ui_root.visible:
			shell.param_panel.refresh()


func _update_camera(t: float) -> void:
	var c = shell.camera
	if not _cam.is_empty():
		var u := smoothstep(0.0, 1.0, clampf((t - float(_cam.t0)) / float(_cam.dur), 0.0, 1.0))
		var a: Dictionary = _cam.from
		var b: Dictionary = _cam.to
		c.apply_bookmark({
			"target": (a.target as Vector3).lerp(b.get("target", a.target), u),
			"yaw": rad_to_deg(lerp_angle(deg_to_rad(a.yaw), deg_to_rad(float(b.get("yaw", a.yaw))), u)),
			"pitch": lerpf(a.pitch, float(b.get("pitch", a.pitch)), u),
			"distance": lerpf(a.distance, float(b.get("distance", a.distance)), u),
		}, true)
		if u >= 1.0:
			_cam = {}
	elif _orbit != 0.0:
		var dt := 1.0 / float(fps) if movie else root.get_process_delta_time()
		c.apply_bookmark({"yaw": c.yaw + _orbit * dt}, true)


func _fail(msg: String) -> void:
	printerr("DIRECTOR FAILED: " + msg)
	quit(1)


# --- Shared helpers -------------------------------------------------------------

## Plan values are JSON: enum options may be given by label prefix ("AgX",
## "N·L"), ranges accept "default", colours accept "#rrggbb".
static func resolve_value(p: Dictionary, v: Variant) -> Variant:
	if v is String and v == "default":
		return p.default
	match p.type:
		"enum":
			if v is String:
				for o in p.options:
					if str(o[0]) == v or str(o[0]).begins_with(v + " ") or (o[1] is String and o[1] == v):
						return o[1]
				return null
			return int(v)
		"range":
			return float(v)
		"bool":
			return bool(v)
		"color":
			return Color(str(v))
	return v


static func debug_mode(mode_name: String) -> int:
	var key := "DEBUG_DRAW_" + mode_name
	if not ClassDB.class_has_integer_constant("Viewport", key):
		return -1
	return ClassDB.class_get_integer_constant("Viewport", key)


# --- Plan validation (headless) -------------------------------------------------

func _check() -> void:
	var plan: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://video/plan.json"))
	if plan.is_empty():
		_fail("cannot parse video/plan.json")
		return
	var shell_node: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(shell_node)
	shell = shell_node
	await process_frame
	var ids := {}
	for c in plan.chapters:
		shell.load_module(int(c.module))
		await process_frame
		var m: LabModule = shell.module
		var where := "%s(module %d)" % [c.id, int(c.module)]
		for shot in c.shots:
			var sid: String = shot.id
			if ids.has(sid):
				_errors.append("duplicate shot id %s" % sid)
			ids[sid] = true
			if shot.has("preset") and shot.preset != "" and not m.presets().has(shot.preset):
				_errors.append("%s %s: unknown preset %s" % [where, sid, shot.preset])
			if shot.has("camera"):
				if shot.camera is String and not m.get_camera_bookmarks().has(shot.camera):
					_errors.append("%s %s: unknown bookmark %s" % [where, sid, shot.camera])
				elif shot.camera is Dictionary and not shot.camera.has_all(["target", "yaw", "pitch", "distance"]):
					_errors.append("%s %s: camera view needs target/yaw/pitch/distance" % [where, sid])
			var nlines: int = shot.get("lines", []).size()
			for line in shot.get("lines", []):
				if str(line.get("sub", "")).strip_edges() == "":
					_errors.append("%s %s: empty line" % [where, sid])
			if nlines == 0 and not shot.has("hold"):
				_errors.append("%s %s: no lines and no hold" % [where, sid])
			for a in shot.get("actions", []):
				_check_action(m, where + " " + sid, a, nlines)
	shell.queue_free()
	await process_frame
	if _errors.is_empty():
		print("VIDEO PLAN OK: %d chapters, %d shots" % [plan.chapters.size(), ids.size()])
		quit(0)
	else:
		for e in _errors:
			printerr(e)
		printerr("VALIDATION FAILED: video plan has %d problem(s)" % _errors.size())
		quit(1)


func _check_action(m: LabModule, where: String, a: Dictionary, nlines: int) -> void:
	var at: Variant = a.get("at", 0)
	if at is String:
		var rx := RegEx.create_from_string("^(L(\\d+)|end)([+-]\\d+(\\.\\d+)?)?$")
		var r := rx.search(at)
		if r == null:
			_errors.append("%s: bad at '%s'" % [where, at])
		elif r.get_string(2) != "" and int(r.get_string(2)) >= nlines:
			_errors.append("%s: at '%s' refers to a missing line" % [where, at])
	var kind := str(a.get("do", ""))
	match kind:
		"preset":
			if not m.presets().has(str(a.get("name", ""))):
				_errors.append("%s: unknown preset %s" % [where, a.get("name")])
		"set", "sweep":
			var p := m.get_param(str(a.get("key", "")))
			if p.is_empty() or p.type == "action":
				_errors.append("%s: unknown param %s" % [where, a.get("key")])
				return
			for field in (["value"] if kind == "set" else ["to", "from"]):
				if not a.has(field):
					if field != "from":
						_errors.append("%s: %s needs '%s'" % [where, kind, field])
					continue
				var v: Variant = resolve_value(p, a[field])
				if v == null:
					_errors.append("%s: %s=%s is not an option of %s" % [where, field, a[field], p.key])
				elif p.type == "range" and (float(v) < float(p.min) - 1e-6 or float(v) > float(p.max) + 1e-6):
					_errors.append("%s: %s=%s outside [%s, %s] of %s" % [where, field, v, p.min, p.max, p.key])
		"call":
			var p := m.get_param(str(a.get("key", "")))
			if p.is_empty() or p.type != "action":
				_errors.append("%s: %s is not an action param" % [where, a.get("key")])
		"hud":
			for k in a.get("keys", []):
				if m.get_param(str(k)).is_empty():
					_errors.append("%s: hud key %s unknown" % [where, k])
		"camera":
			if a.has("bookmark") and not m.get_camera_bookmarks().has(str(a.bookmark)):
				_errors.append("%s: unknown bookmark %s" % [where, a.bookmark])
		"debug":
			if debug_mode(str(a.get("mode", ""))) < 0:
				_errors.append("%s: unknown debug mode %s" % [where, a.get("mode")])
		"snapshot":
			if not str(a.get("slot", "")) in ["A", "B", "toggle"]:
				_errors.append("%s: bad snapshot slot %s" % [where, a.get("slot")])
		"card", "ui", "orbit", "export", "endcard":
			pass
		_:
			_errors.append("%s: unknown action '%s'" % [where, kind])
