extends Node
## Main shell: hosts one learning module at a time, the orbit camera and the
## UI (module list, presets, camera bookmarks, parameter panel, info panel,
## engine debug views, A/B snapshots, perf readout, screenshots).

const LabModule := preload("res://scripts/lab/lab_module.gd")
const OrbitCamera := preload("res://scripts/lab/orbit_camera.gd")
const ParamPanel := preload("res://scripts/lab/param_panel.gd")
const PerfOverlay := preload("res://scripts/lab/perf_overlay.gd")
const SceneKit := preload("res://scripts/lib/scene_kit.gd")
const ProcTextures := preload("res://scripts/lib/proc_textures.gd")

const MODULES := [
	{"id": "01", "title": "01 法线与法线贴图", "scene": "res://scenes/modules/01_normals.tscn"},
	{"id": "02", "title": "02 光照模型对比", "scene": "res://scenes/modules/02_lighting_models.tscn"},
	{"id": "03", "title": "03 光源类型与阴影", "scene": "res://scenes/modules/03_lights_shadows.tscn"},
	{"id": "04", "title": "04 GI、环境与后处理", "scene": "res://scenes/modules/04_gi_environment.tscn"},
	{"id": "05", "title": "05 场景氛围配方", "scene": "res://scenes/modules/05_atmosphere.tscn"},
]

const DEBUG_VIEWS := [
	["Normal 正常渲染", Viewport.DEBUG_DRAW_DISABLED],
	["Unshaded 无光照 (只看反照率)", Viewport.DEBUG_DRAW_UNSHADED],
	["Lighting 只看光照 (反照率=白)", Viewport.DEBUG_DRAW_LIGHTING],
	["Wireframe 线框", Viewport.DEBUG_DRAW_WIREFRAME],
	["Overdraw 过度绘制", Viewport.DEBUG_DRAW_OVERDRAW],
	["Normal Buffer 法线缓冲", Viewport.DEBUG_DRAW_NORMAL_BUFFER],
	["Directional Shadow Atlas 平行光阴影图集", Viewport.DEBUG_DRAW_DIRECTIONAL_SHADOW_ATLAS],
	["Shadow Atlas 点光/聚光阴影图集", Viewport.DEBUG_DRAW_SHADOW_ATLAS],
	["PSSM Splits 阴影级联分割", Viewport.DEBUG_DRAW_PSSM_SPLITS],
	["SSAO 环境光遮蔽", Viewport.DEBUG_DRAW_SSAO],
	["SSIL 屏幕空间间接光", Viewport.DEBUG_DRAW_SSIL],
	["SDFGI 体素化场景", Viewport.DEBUG_DRAW_SDFGI],
	["SDFGI Probes 探针", Viewport.DEBUG_DRAW_SDFGI_PROBES],
	["VoxelGI Albedo", Viewport.DEBUG_DRAW_VOXEL_GI_ALBEDO],
	["VoxelGI Lighting", Viewport.DEBUG_DRAW_VOXEL_GI_LIGHTING],
	["VoxelGI Emission", Viewport.DEBUG_DRAW_VOXEL_GI_EMISSION],
	["GI Buffer 间接光缓冲", Viewport.DEBUG_DRAW_GI_BUFFER],
	["Scene Luminance 场景亮度 (自动曝光)", Viewport.DEBUG_DRAW_SCENE_LUMINANCE],
	["Internal Buffer 未色调映射 HDR", Viewport.DEBUG_DRAW_INTERNAL_BUFFER],
	["Cluster Omni Lights 点光分簇", Viewport.DEBUG_DRAW_CLUSTER_OMNI_LIGHTS],
	["Cluster Spot Lights 聚光分簇", Viewport.DEBUG_DRAW_CLUSTER_SPOT_LIGHTS],
	["Cluster Area Lights 面光分簇", Viewport.DEBUG_DRAW_CLUSTER_AREA_LIGHTS],
	["Cluster Reflection Probes 反射探针分簇", Viewport.DEBUG_DRAW_CLUSTER_REFLECTION_PROBES],
	["Area Light Atlas 面光贴图图集", Viewport.DEBUG_DRAW_AREA_LIGHT_ATLAS],
]

const LEFT_W := 272
const RIGHT_W := 448
const INFO_H := 196
const PAD := 8

const HELP_TEXT := """[b]操作[/b]
• 左键/右键拖拽：环绕相机　• 中键或 Shift+拖拽：平移　• 滚轮：缩放　• WASD/QE：移动观察点
• [b]1[/b] 存为快照 A　• [b]2[/b] 存为快照 B　• [b]Tab[/b] 在 A/B 间切换 (对比参数改动前后)
• [b]F[/b] 回到默认机位　• [b]H[/b] 隐藏/显示界面　• [b]F12[/b] 截图到 captures/　• [b]F1[/b] 帮助

[b]学习方法[/b]
1. 先读底部「模块概述」，再按左侧预设顺序逐个点开，每个预设都有说明和推荐的 Debug View。
2. 鼠标悬停在右侧任意参数上，底部会显示：作用、调大/调小的效果、典型值和常见坑。
3. 改参数前按 1 存 A，改完按 2 存 B，再用 Tab 来回切换，最容易看出一个参数的真实影响。
4. 顶部 Debug View 是排查光照问题的利器：Lighting 只看光照，Normal Buffer 看法线，PSSM Splits 看阴影级联，SSAO/SDFGI 看各自贡献。
5. 「导出参数」会把与默认值不同的参数复制到剪贴板，方便记录或搬到自己的项目里。
6. 右上角性能数据里的 GPU 时间可以用来估算每个效果的开销 (开关某个效果对比 GPU ms)。"""

var camera: OrbitCamera
var module: LabModule
var module_index := -1
var param_panel: ParamPanel

var _ui_root: Control
var _module_list: ItemList
var _preset_list: ItemList
var _bookmark_box: HFlowContainer
var _debug_option: OptionButton
var _info_title: Label
var _info_text: RichTextLabel
var _ab_label: Label
var _status_label: Label
var _help_panel: PanelContainer
var _preset_names: Array[String] = []
var _snap := {"A": {}, "B": {}}
var _showing := ""


func _enter_tree() -> void:
	# Needed before any mesh is created, otherwise the Wireframe view is empty.
	RenderingServer.set_debug_generate_wireframes(true)


func _exit_tree() -> void:
	if module:
		module.on_exit()
	ProcTextures.clear_cache()


func _ready() -> void:
	camera = OrbitCamera.new()
	camera.name = "OrbitCamera"
	add_child(camera)
	camera.make_current()
	_build_ui()
	set_ui_visible(true)
	var start := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--module="):
			start = clampi(int(arg.trim_prefix("--module=")) - 1, 0, MODULES.size() - 1)
	load_module(start)


# --- Module lifecycle ---------------------------------------------------------

func load_module(index: int) -> void:
	if module:
		module.on_exit()
		remove_child(module)
		module.free()
		module = null
	set_debug_draw(Viewport.DEBUG_DRAW_DISABLED)
	module_index = index
	var packed: PackedScene = load(MODULES[index].scene)
	module = packed.instantiate() as LabModule
	add_child(module)
	module.values_changed.connect(_on_values_changed)
	param_panel.bind(module)
	_fill_presets()
	_fill_bookmarks()
	_snap = {"A": {}, "B": {}}
	_showing = ""
	_update_ab_label()
	reset_camera(true)
	show_overview()
	_module_list.select(index)
	module.on_enter(self)


func select_preset(preset_name: String) -> void:
	if module == null:
		return
	if preset_name == "":
		module.reset_all()
		set_debug_draw(Viewport.DEBUG_DRAW_DISABLED)
		show_overview()
		return
	module.apply_preset(preset_name)
	var preset: Dictionary = module.presets().get(preset_name, {})
	set_debug_draw(preset.get("_debug", Viewport.DEBUG_DRAW_DISABLED))
	if preset.has("_camera"):
		apply_bookmark(preset._camera)
	_show_info("预设：" + preset_name, preset.get("_note", ""))


func apply_bookmark(bookmark_name: String, instant := false) -> void:
	var bms := module.get_camera_bookmarks()
	if bms.has(bookmark_name):
		camera.apply_bookmark(bms[bookmark_name], instant)


func reset_camera(instant := false) -> void:
	var bms := module.get_camera_bookmarks()
	if not bms.is_empty():
		camera.apply_bookmark(bms.values()[0], instant)


func set_debug_draw(mode: int) -> void:
	get_viewport().debug_draw = mode as Viewport.DebugDraw
	if _debug_option:
		var idx := _debug_option.get_item_index(mode)
		if idx >= 0:
			_debug_option.select(idx)


func set_ui_visible(on: bool) -> void:
	_ui_root.visible = on
	if on:
		camera.set_insets(LEFT_W + PAD * 2, 40 + PAD * 2, RIGHT_W + PAD * 2, INFO_H + PAD * 2)
	else:
		camera.set_insets(0, 0, 0, 0)


func show_overview() -> void:
	_show_info(MODULES[module_index].title + " · 概述", module.get_overview())


# --- A/B snapshots -------------------------------------------------------------

func save_snapshot(slot: String) -> void:
	_snap[slot] = module.capture_state(true)
	_showing = slot
	_update_ab_label()
	_flash("已保存快照 %s" % slot)


func toggle_snapshot() -> void:
	if _snap.A.is_empty() or _snap.B.is_empty():
		_flash("先按 1 和 2 分别保存 A、B 两个快照")
		return
	_showing = "B" if _showing == "A" else "A"
	module.apply_state(_snap[_showing])
	_update_ab_label()


func _update_ab_label() -> void:
	var a := "A✓" if not _snap.A.is_empty() else "A-"
	var b := "B✓" if not _snap.B.is_empty() else "B-"
	_ab_label.text = "%s %s  当前: %s" % [a, b, _showing if _showing != "" else "-"]


# --- Export / screenshot ----------------------------------------------------------

func export_params() -> void:
	var text := module.export_snippet()
	DisplayServer.clipboard_set(text)
	print(text)
	_show_info("导出参数 (已复制到剪贴板)", "[code]%s[/code]" % text.replace("[", "[lb]"))


func screenshot() -> String:
	var dir := ProjectSettings.globalize_path("res://captures")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/shot_%s_%s.png" % [dir, MODULES[module_index].id, Time.get_datetime_string_from_system().replace(":", "-")]
	var img := get_viewport().get_texture().get_image()
	if img:
		img.save_png(path)
		_flash("截图已保存：" + path)
	return path


# --- Input -------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	var handled := true
	match (event as InputEventKey).physical_keycode:
		KEY_1:
			save_snapshot("A")
		KEY_2:
			save_snapshot("B")
		KEY_TAB:
			toggle_snapshot()
		KEY_F:
			reset_camera()
		KEY_H:
			set_ui_visible(not _ui_root.visible)
		KEY_F12:
			screenshot()
		KEY_F1:
			_help_panel.visible = not _help_panel.visible
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()


# --- UI construction ------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_ui_root = Control.new()
	_ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_root.theme = _make_theme()
	layer.add_child(_ui_root)

	_build_top_bar()
	_build_left_panel()
	_build_right_panel()
	_build_info_panel()

	var perf := PerfOverlay.new()
	perf.position = Vector2(LEFT_W + PAD * 3, 54)
	_ui_root.add_child(perf)

	_help_panel = PanelContainer.new()
	_help_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_help_panel.custom_minimum_size = Vector2(720, 420)
	_help_panel.position = Vector2(-360, -210)
	_help_panel.visible = false
	var help := RichTextLabel.new()
	help.bbcode_enabled = true
	help.text = HELP_TEXT + "\n\n[color=#8a93a3](按 F1 关闭)[/color]"
	help.fit_content = true
	_help_panel.add_child(help)
	_ui_root.add_child(_help_panel)


func _panel(left: float, top: float, right: float, bottom: float) -> PanelContainer:
	var p := PanelContainer.new()
	p.anchor_left = left
	p.anchor_top = top
	p.anchor_right = right
	p.anchor_bottom = bottom
	_ui_root.add_child(p)
	return p


func _build_top_bar() -> void:
	var bar := _panel(0, 0, 1, 0)
	bar.offset_left = PAD
	bar.offset_right = -PAD
	bar.offset_top = PAD
	bar.offset_bottom = PAD + 40
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	bar.add_child(h)
	var title := Label.new()
	title.text = "Godot Lighting Lab · 光照实验室"
	title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.55))
	h.add_child(title)
	h.add_child(VSeparator.new())
	var dl := Label.new()
	dl.text = "Debug View"
	h.add_child(dl)
	_debug_option = OptionButton.new()
	for item in DEBUG_VIEWS:
		_debug_option.add_item(item[0], item[1])
	_debug_option.item_selected.connect(func(i: int) -> void:
		get_viewport().debug_draw = _debug_option.get_item_id(i) as Viewport.DebugDraw)
	_debug_option.custom_minimum_size.x = 300
	h.add_child(_debug_option)
	h.add_child(VSeparator.new())
	_add_button(h, "存为 A [1]", save_snapshot.bind("A"))
	_add_button(h, "存为 B [2]", save_snapshot.bind("B"))
	_add_button(h, "切换 A/B [Tab]", toggle_snapshot)
	_ab_label = Label.new()
	_ab_label.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	h.add_child(_ab_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(spacer)
	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.75))
	h.add_child(_status_label)
	_add_button(h, "导出参数", export_params)
	_add_button(h, "截图 [F12]", screenshot)
	_add_button(h, "帮助 [F1]", func() -> void: _help_panel.visible = not _help_panel.visible)


func _build_left_panel() -> void:
	var panel := _panel(0, 0, 0, 1)
	panel.offset_left = PAD
	panel.offset_right = PAD + LEFT_W
	panel.offset_top = PAD * 2 + 40
	panel.offset_bottom = -PAD
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	v.add_child(_section_label("学习模块"))
	_module_list = ItemList.new()
	for m in MODULES:
		_module_list.add_item(m.title)
	_module_list.custom_minimum_size.y = 150
	_module_list.item_selected.connect(load_module)
	v.add_child(_module_list)
	v.add_child(_section_label("预设 / 配方 (点击应用)"))
	_preset_list = ItemList.new()
	_preset_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preset_list.item_selected.connect(func(i: int) -> void:
		select_preset("" if i == 0 else _preset_names[i - 1]))
	v.add_child(_preset_list)
	v.add_child(_section_label("机位 [F 回默认]"))
	_bookmark_box = HFlowContainer.new()
	v.add_child(_bookmark_box)


func _build_right_panel() -> void:
	var panel := _panel(1, 0, 1, 1)
	panel.offset_left = -PAD - RIGHT_W
	panel.offset_right = -PAD
	panel.offset_top = PAD * 2 + 40
	panel.offset_bottom = -PAD
	var v := VBoxContainer.new()
	panel.add_child(v)
	var head := HBoxContainer.new()
	var l := _section_label("参数 (悬停查看说明)")
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(l)
	_add_button(head, "全部重置", func() -> void: select_preset(""))
	v.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	param_panel = ParamPanel.new()
	param_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	param_panel.tip_requested.connect(_show_info)
	scroll.add_child(param_panel)


func _build_info_panel() -> void:
	var panel := _panel(0, 1, 1, 1)
	panel.offset_left = PAD * 2 + LEFT_W
	panel.offset_right = -PAD * 2 - RIGHT_W
	panel.offset_top = -PAD - INFO_H
	panel.offset_bottom = -PAD
	var v := VBoxContainer.new()
	panel.add_child(v)
	var head := HBoxContainer.new()
	_info_title = Label.new()
	_info_title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.55))
	_info_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_title.clip_text = true
	head.add_child(_info_title)
	_add_button(head, "模块概述", show_overview)
	v.add_child(head)
	_info_text = RichTextLabel.new()
	_info_text.bbcode_enabled = true
	_info_text.scroll_active = true
	_info_text.selection_enabled = true
	_info_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_info_text)


func _fill_presets() -> void:
	_preset_list.clear()
	_preset_names.clear()
	_preset_list.add_item("（默认）全部重置")
	for preset_name in module.presets():
		_preset_names.append(preset_name)
		_preset_list.add_item(preset_name)


func _fill_bookmarks() -> void:
	for c in _bookmark_box.get_children():
		c.queue_free()
	for bm_name in module.get_camera_bookmarks():
		_add_button(_bookmark_box, bm_name, apply_bookmark.bind(bm_name))


func _add_button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
	l.add_theme_font_size_override("font_size", 13)
	return l


func _make_theme() -> Theme:
	var th := Theme.new()
	th.default_font = SceneKit.ui_font()
	th.default_font_size = 14
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.07, 0.08, 0.1, 0.86)
	panel.border_color = Color(1, 1, 1, 0.07)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(6)
	panel.set_content_margin_all(10)
	th.set_stylebox("panel", "PanelContainer", panel)
	return th


func _show_info(title: String, body: String) -> void:
	_info_title.text = title
	_info_text.text = body
	_info_text.scroll_to_line(0)


func _flash(text: String) -> void:
	_status_label.text = text
	var t := get_tree().create_timer(3.0)
	t.timeout.connect(func() -> void:
		if _status_label.text == text:
			_status_label.text = "")


func _on_values_changed() -> void:
	param_panel.refresh()
