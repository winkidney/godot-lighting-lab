extends CanvasLayer
## On-screen graphics for the recorded tutorial (tools/tutorial_director.gd):
## chapter title cards, a shot tag, concept/formula cards, a live parameter
## HUD, a progress bar and the end card. Laid out for 1920x1080.
##
## Everything is driven by update(t): opacity is a pure function of the
## timeline time, so a Movie Maker render is reproducible frame by frame.
## The bottom ~15% of the screen is left free for the burned-in subtitles.

const SceneKit := preload("res://scripts/lib/scene_kit.gd")
const LabModule := preload("res://scripts/lab/lab_module.gd")

const ACCENT := Color(1.0, 0.82, 0.45)
const TEXT := Color(0.96, 0.97, 1.0)
const DIM := Color(0.72, 0.77, 0.86)
const CARD_BG := Color(0.035, 0.04, 0.055)
const FADE := 0.3
const MARGIN := 40.0
const CREDIT := "This audio was created with Boson AI's Higgs Audio: https://www.boson.ai/higgs-audio"

var module: LabModule

var _root: Control
var _mono: SystemFont
var _tag: PanelContainer
var _tag_num: Label
var _tag_text: Label
var _cards_box: VBoxContainer
var _cards: Array[Dictionary] = []  # {node, t0, t1}
var _hud: PanelContainer
var _hud_rows: VBoxContainer
var _hud_items: Array[Dictionary] = []  # {param, value, bar, fill}
var _progress: Control
var _title: Control
var _title_num: Label
var _title_main: Label
var _title_sub: Label
var _end: Control
var _fade: ColorRect
var _minimal := false

var _title_t0 := -100.0
var _title_dur := 0.0
var _end_t0 := -1.0
var _chapter_dur := 0.0
var _last_chapter := false
var _total := 1.0
var _chapter_marks: Array = []  # absolute start times
var _global_offset := 0.0


func _init() -> void:
	layer = 20


func _ready() -> void:
	_mono = SystemFont.new()
	_mono.font_names = PackedStringArray(["Noto Sans Mono CJK SC", "Noto Sans Mono", "DejaVu Sans Mono", "monospace"])
	_mono.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var th := Theme.new()
	th.default_font = SceneKit.ui_font()
	th.default_font_size = 26
	_root.theme = th
	add_child(_root)
	_build_tag()
	_build_cards()
	_build_hud()
	_build_progress()
	_build_end()
	_build_title()
	_fade = ColorRect.new()
	_fade.color = CARD_BG
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.modulate.a = 0.0
	_root.add_child(_fade)


# --- Public API ------------------------------------------------------------------

## total: whole video length; marks: chapter start times; offset: this
## chapter's start in the whole video; duration: this chapter's length.
func setup_timeline(total: float, marks: Array, offset: float, duration: float, last: bool) -> void:
	_total = maxf(total, 0.001)
	_chapter_marks = marks
	_global_offset = offset
	_chapter_dur = duration
	_last_chapter = last
	_progress.queue_redraw()


func show_title_card(card: Dictionary, t0: float, dur: float) -> void:
	_title_num.text = str(card.get("num", ""))
	_title_num.visible = _title_num.text != ""
	_title_main.text = str(card.get("title", ""))
	_title_sub.text = str(card.get("subtitle", ""))
	_title_t0 = t0
	_title_dur = dur


func set_tag(num: String, text: String) -> void:
	_tag_num.text = num
	_tag_num.visible = num != ""
	_tag_text.text = text
	_tag.visible = text != "" and not _minimal


func show_card(title: String, body: String, t0: float, t1: float) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(0.82))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var head := Label.new()
	head.text = title
	head.add_theme_color_override("font_color", ACCENT)
	head.add_theme_font_size_override("font_size", 44 if body == "" else 34)
	v.add_child(head)
	if body != "":
		var b := Label.new()
		b.text = body
		b.add_theme_font_override("font", _mono)
		b.add_theme_font_size_override("font_size", 27)
		b.add_theme_color_override("font_color", TEXT)
		b.add_theme_constant_override("line_spacing", 6)
		v.add_child(b)
	panel.modulate.a = 0.0
	_cards_box.add_child(panel)
	_cards.append({"node": panel, "t0": t0, "t1": t1})


func clear_cards() -> void:
	for c in _cards:
		(c.node as Node).queue_free()
	_cards.clear()


func set_hud(keys: Array) -> void:
	clear_hud()
	for key in keys:
		var p := module.get_param(str(key))
		if p.is_empty():
			push_error("HUD: unknown param %s" % key)
			continue
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var head := HBoxContainer.new()
		var k := Label.new()
		k.text = str(p.property).trim_prefix("shader_parameter/")
		k.add_theme_font_override("font", _mono)
		k.add_theme_font_size_override("font_size", 24)
		k.add_theme_color_override("font_color", ACCENT)
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		k.clip_text = true
		head.add_child(k)
		var val := Label.new()
		val.add_theme_font_override("font", _mono)
		val.add_theme_font_size_override("font_size", 24)
		val.add_theme_color_override("font_color", TEXT)
		head.add_child(val)
		row.add_child(head)
		var bar := ColorRect.new()
		bar.color = Color(1, 1, 1, 0.12)
		bar.custom_minimum_size = Vector2(0, 6)
		var fill := ColorRect.new()
		fill.color = ACCENT
		fill.position = Vector2.ZERO
		bar.add_child(fill)
		bar.visible = p.type == "range"
		row.add_child(bar)
		var tip := Label.new()
		tip.text = LabModule.short_tip(p)
		tip.add_theme_font_size_override("font_size", 20)
		tip.add_theme_color_override("font_color", DIM)
		tip.visible = tip.text != ""
		row.add_child(tip)
		_hud_rows.add_child(row)
		_hud_items.append({"param": p, "value": val, "bar": bar, "fill": fill})
	_hud.visible = not _hud_items.is_empty() and not _minimal


func clear_hud() -> void:
	for c in _hud_rows.get_children():
		c.queue_free()
	_hud_items.clear()
	_hud.visible = false


## While the lab's own UI is on screen, only the progress bar stays.
func set_minimal(on: bool) -> void:
	_minimal = on
	_tag.visible = not on and _tag_text.text != ""
	_hud.visible = not on and not _hud_items.is_empty()
	_cards_box.visible = not on


func show_endcard(t0: float) -> void:
	_end_t0 = t0


func update(t: float) -> void:
	# Title card: opaque from the start, content fades in, whole card fades out.
	if _title_dur > 0.0:
		var out := 1.0 - clampf((t - (_title_t0 + _title_dur - 0.55)) / 0.55, 0.0, 1.0)
		var inner := clampf((t - _title_t0 - 0.1) / 0.45, 0.0, 1.0)
		_title.visible = out > 0.0
		_title.modulate.a = out
		(_title.get_child(1) as Control).modulate.a = inner
	for c in _cards:
		(c.node as Control).modulate.a = _window(t, c.t0, c.t1)
	if _end_t0 >= 0.0:
		_end.visible = true
		_end.modulate.a = clampf((t - _end_t0) / 0.6, 0.0, 1.0)
	# Fade out at the chapter end into the next title card (or to black).
	var tail := 0.8 if _last_chapter else 0.35
	_fade.color = Color.BLACK if _last_chapter else CARD_BG
	_fade.modulate.a = clampf((t - (_chapter_dur - tail)) / tail, 0.0, 1.0) if _chapter_dur > 0.0 else 0.0
	_update_hud()
	_progress.set_meta("t", _global_offset + t)
	_progress.queue_redraw()


# --- Building --------------------------------------------------------------------

func _panel_style(alpha: float) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(CARD_BG, alpha)
	s.border_color = Color(1, 1, 1, 0.08)
	s.set_border_width_all(1)
	s.set_corner_radius_all(10)
	s.content_margin_left = 22
	s.content_margin_right = 22
	s.content_margin_top = 14
	s.content_margin_bottom = 16
	return s


func _build_tag() -> void:
	_tag = PanelContainer.new()
	_tag.position = Vector2(MARGIN, 34)
	_tag.add_theme_stylebox_override("panel", _panel_style(0.7))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	_tag.add_child(h)
	_tag_num = Label.new()
	_tag_num.add_theme_color_override("font_color", ACCENT)
	_tag_num.add_theme_font_size_override("font_size", 24)
	h.add_child(_tag_num)
	_tag_text = Label.new()
	_tag_text.add_theme_font_size_override("font_size", 24)
	_tag_text.add_theme_color_override("font_color", TEXT)
	h.add_child(_tag_text)
	_tag.visible = false
	_root.add_child(_tag)


func _build_cards() -> void:
	_cards_box = VBoxContainer.new()
	_cards_box.position = Vector2(MARGIN, 112)
	_cards_box.custom_minimum_size = Vector2(560, 0)
	_cards_box.add_theme_constant_override("separation", 14)
	_root.add_child(_cards_box)


func _build_hud() -> void:
	_hud = PanelContainer.new()
	_hud.add_theme_stylebox_override("panel", _panel_style(0.78))
	_hud.anchor_left = 1.0
	_hud.anchor_right = 1.0
	_hud.offset_left = -MARGIN - 520
	_hud.offset_right = -MARGIN
	_hud.offset_top = 34
	_hud_rows = VBoxContainer.new()
	_hud_rows.add_theme_constant_override("separation", 16)
	_hud.add_child(_hud_rows)
	_hud.visible = false
	_root.add_child(_hud)


func _build_progress() -> void:
	_progress = Control.new()
	_progress.anchor_top = 1.0
	_progress.anchor_bottom = 1.0
	_progress.anchor_right = 1.0
	_progress.offset_top = -6
	_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress.draw.connect(_draw_progress)
	_root.add_child(_progress)


func _draw_progress() -> void:
	var w := _progress.size.x
	var h := _progress.size.y
	_progress.draw_rect(Rect2(0, 0, w, h), Color(0, 0, 0, 0.45))
	var t: float = _progress.get_meta("t", 0.0)
	_progress.draw_rect(Rect2(0, 0, w * clampf(t / _total, 0.0, 1.0), h), Color(ACCENT, 0.85))
	for m in _chapter_marks:
		var x := w * float(m) / _total
		if x > 1.0:
			_progress.draw_rect(Rect2(x - 1.5, 0, 3, h), Color(0.02, 0.02, 0.03, 0.9))


func _build_title() -> void:
	_title = Control.new()
	_title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := ColorRect.new()
	bg.color = CARD_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_title.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_title.add_child(center)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 18)
	center.add_child(v)
	_title_num = _centered_label(64, ACCENT)
	v.add_child(_title_num)
	_title_main = _centered_label(84, TEXT)
	v.add_child(_title_main)
	var line := ColorRect.new()
	line.color = Color(ACCENT, 0.7)
	line.custom_minimum_size = Vector2(120, 3)
	line.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(line)
	_title_sub = _centered_label(34, DIM)
	v.add_child(_title_sub)
	_title.visible = false
	_root.add_child(_title)


func _build_end() -> void:
	_end = Control.new()
	_end.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_end.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := ColorRect.new()
	bg.color = Color(CARD_BG, 0.9)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_end.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.offset_bottom = -120
	_end.add_child(center)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	center.add_child(v)
	v.add_child(_centered_label(64, TEXT, "Godot Lighting Lab · 光照实验室"))
	v.add_child(_centered_label(30, DIM, "Godot 4.7 · Forward+ · 5 个模块 · 315 个可调参数 · 61 个预设"))
	v.add_child(_centered_label(30, DIM, "场景、贴图与 LUT 全部由代码程序生成"))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 24)
	v.add_child(gap)
	v.add_child(_centered_label(24, DIM, "配音：Higgs TTS 3 Q8_0 本地合成；参考音色为 Kokoro zf_001 合成女声，非真人录音"))
	v.add_child(_centered_label(24, DIM, CREDIT))
	_end.visible = false
	_root.add_child(_end)


func _centered_label(size: int, color: Color, text := "") -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


# --- Per-frame -------------------------------------------------------------------

static func _window(t: float, t0: float, t1: float) -> float:
	return clampf((t - t0) / FADE, 0.0, 1.0) * clampf((t1 - t) / FADE, 0.0, 1.0)


func _update_hud() -> void:
	for item in _hud_items:
		var p: Dictionary = item.param
		var v: Variant = module.read(p) if is_instance_valid(module) else null
		var label := item.value as Label
		match p.type:
			"range":
				var f := float(v)
				label.text = str(int(round(f))) if p.get("int", false) else ("%.2f" % f if absf(f) < 100.0 else "%.0f" % f)
				var bar := item.bar as ColorRect
				var u := clampf((f - float(p.min)) / maxf(float(p.max) - float(p.min), 1e-6), 0.0, 1.0)
				if p.get("exp", false) and float(p.min) > 0.0:
					u = clampf(log(f / float(p.min)) / log(float(p.max) / float(p.min)), 0.0, 1.0)
				(item.fill as ColorRect).size = Vector2(bar.size.x * u, bar.size.y)
			"bool":
				label.text = "开 ON" if bool(v) else "关 OFF"
				label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.65) if bool(v) else Color(1.0, 0.55, 0.5))
			"enum":
				var text := str(v)
				for o in p.options:
					if LabModule.values_equal(o[1], v):
						text = str(o[0]).get_slice(" ", 0)
						break
				label.text = text
			_:
				label.text = str(v)
