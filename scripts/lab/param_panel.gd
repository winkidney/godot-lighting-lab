extends VBoxContainer
## Builds the parameter UI from a module's parameter specs: one collapsible
## group per spec group, one row per parameter. Each row shows the real Godot
## property name, the short Chinese name, a reset button and an editor.

signal tip_requested(title: String, body: String)

const LabModule := preload("res://scripts/lab/lab_module.gd")
const ACCENT := Color(0.58, 0.82, 1.0)
const DIM := Color(0.66, 0.69, 0.75)
const OPEN_GROUPS := 2

var module: LabModule
var _rows: Array[Dictionary] = []
var _updating := false


func _ready() -> void:
	add_theme_constant_override("separation", 6)


func bind(m: LabModule) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_rows.clear()
	module = m
	if m == null:
		return
	var boxes := {}
	for p in m.get_params():
		var group_name: String = p.group
		var box: VBoxContainer = boxes.get(group_name)
		if box == null:
			var fold := FoldableContainer.new()
			fold.title = group_name
			fold.folded = boxes.size() >= OPEN_GROUPS
			add_child(fold)
			box = VBoxContainer.new()
			box.add_theme_constant_override("separation", 7)
			fold.add_child(box)
			boxes[group_name] = box
		box.add_child(_make_row(p))
	refresh()


func refresh() -> void:
	if module == null:
		return
	_updating = true
	for row in _rows:
		_refresh_row(row)
	_updating = false


func _refresh_row(row: Dictionary) -> void:
	var p: Dictionary = row.spec
	if p.type == "action":
		return
	var v: Variant = module.read(p)
	if v == null:
		return
	match p.type:
		"range":
			(row.slider as HSlider).value = float(v)
			(row.spin as SpinBox).value = float(v)
		"bool":
			(row.check as CheckButton).button_pressed = bool(v)
		"enum":
			var opt := row.option as OptionButton
			for i in opt.item_count:
				if opt.get_item_metadata(i) == v:
					opt.select(i)
		"color":
			(row.color as ColorPickerButton).color = v


func _make_row(p: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	var entry := {"spec": p}
	_rows.append(entry)
	if p.type == "action":
		var btn := Button.new()
		btn.text = p.label
		btn.pressed.connect(func() -> void:
			(p.callable as Callable).call()
			refresh())
		btn.mouse_entered.connect(_emit_tip.bind(p))
		row.add_child(btn)
		return row

	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_PASS
	var name_label := Label.new()
	name_label.text = p.label
	name_label.add_theme_color_override("font_color", ACCENT)
	name_label.mouse_filter = Control.MOUSE_FILTER_PASS
	var zh := Label.new()
	zh.text = LabModule.short_tip(p)
	zh.add_theme_color_override("font_color", DIM)
	zh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zh.clip_text = true
	zh.mouse_filter = Control.MOUSE_FILTER_PASS
	var reset := Button.new()
	reset.text = "默认"
	reset.flat = true
	reset.add_theme_font_size_override("font_size", 12)
	reset.tooltip_text = "恢复默认值"
	reset.pressed.connect(func() -> void:
		_apply(p, p.default)
		refresh())
	head.add_child(name_label)
	head.add_child(zh)
	head.add_child(reset)
	row.add_child(head)

	var editor: Control
	match p.type:
		"range":
			var line := HBoxContainer.new()
			var slider := HSlider.new()
			var step: float = p.step if p.step > 0.0 else 0.001
			slider.min_value = p.min
			slider.max_value = p.max
			slider.step = step
			slider.exp_edit = p.get("exp", false) and p.min > 0.0
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var spin := SpinBox.new()
			spin.min_value = p.min
			spin.max_value = p.max
			spin.step = step
			spin.custom_minimum_size.x = 104
			spin.select_all_on_focus = true
			slider.value_changed.connect(func(v: float) -> void:
				if _updating:
					return
				_updating = true
				spin.value = v
				_updating = false
				_apply(p, v))
			spin.value_changed.connect(func(v: float) -> void:
				if _updating:
					return
				_updating = true
				slider.value = v
				_updating = false
				_apply(p, v))
			line.add_child(slider)
			line.add_child(spin)
			entry["slider"] = slider
			entry["spin"] = spin
			editor = line
		"bool":
			var check := CheckButton.new()
			check.text = "开启"
			check.toggled.connect(func(on: bool) -> void:
				if not _updating:
					_apply(p, on))
			entry["check"] = check
			editor = check
		"enum":
			var opt := OptionButton.new()
			opt.fit_to_longest_item = false
			for i in p.options.size():
				opt.add_item(p.options[i][0], i)
				opt.set_item_metadata(i, p.options[i][1])
			opt.item_selected.connect(func(idx: int) -> void:
				if not _updating:
					_apply(p, opt.get_item_metadata(idx)))
			entry["option"] = opt
			editor = opt
		"color":
			var picker := ColorPickerButton.new()
			picker.edit_alpha = false
			picker.custom_minimum_size = Vector2(0, 26)
			picker.color_changed.connect(func(c: Color) -> void:
				if not _updating:
					_apply(p, c))
			entry["color"] = picker
			editor = picker
	row.add_child(editor)

	for c: Control in [row, head, name_label, zh, editor]:
		c.mouse_entered.connect(_emit_tip.bind(p))
	if editor is HBoxContainer:
		for c in editor.get_children():
			(c as Control).mouse_entered.connect(_emit_tip.bind(p))
	return row


func _apply(p: Dictionary, value: Variant) -> void:
	module.write(p, value)
	if p.get("refresh_all", false):
		refresh()


func _emit_tip(p: Dictionary) -> void:
	var body: String = p.get("tip", "")
	var info := ""
	match p.type:
		"range":
			info = "范围 %s ~ %s · 默认 %s" % [_fmt(p.min), _fmt(p.max), _fmt(p.default)]
		"bool":
			info = "默认 %s" % ("开" if p.default else "关")
		"enum":
			for o in p.options:
				if o[1] == p.default:
					info = "默认 %s" % o[0]
		"color":
			info = "默认 #%s" % (p.default as Color).to_html(false)
	var where := ""
	if p.type != "action":
		where = "%s.%s · " % [LabModule.target_name(p.target), p.property]
	tip_requested.emit(p.label, "%s\n[color=#8a93a3]%s%s · key: %s[/color]" % [body, where, info, p.key])


static func _fmt(v: Variant) -> String:
	if typeof(v) == TYPE_FLOAT:
		return ("%.3f" % v).rstrip("0").rstrip(".")
	return str(v)
