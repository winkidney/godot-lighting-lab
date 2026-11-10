extends "res://scripts/lab/lab_module.gd"
## 03 光源类型与阴影: directional / omni / spot / area lights, attenuation,
## shadow mapping parameters and their classic failure modes.

const SceneKit := preload("res://scripts/lib/scene_kit.gd")
const ProcTextures := preload("res://scripts/lib/proc_textures.gd")

const QUALITY := [
	["Hard 硬阴影", RenderingServer.SHADOW_QUALITY_HARD],
	["Soft Very Low", RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW],
	["Soft Low (默认)", RenderingServer.SHADOW_QUALITY_SOFT_LOW],
	["Soft Medium", RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM],
	["Soft High", RenderingServer.SHADOW_QUALITY_SOFT_HIGH],
	["Soft Ultra", RenderingServer.SHADOW_QUALITY_SOFT_ULTRA],
]
const ATLAS_SIZES := [["512", 512], ["1024", 1024], ["2048", 2048], ["4096", 4096], ["8192", 8192]]

var sun_azimuth := 40.0:
	set(v):
		sun_azimuth = v
		if _sun:
			SceneKit.aim_light(_sun, sun_azimuth, sun_elevation)
var sun_elevation := 38.0:
	set(v):
		sun_elevation = v
		if _sun:
			SceneKit.aim_light(_sun, sun_azimuth, sun_elevation)
var sun_temperature := 6500.0:
	set(v):
		sun_temperature = v
		if _sun and not _applying:
			_sun.light_color = SceneKit.kelvin_to_color(v)
var omni_height := 2.4:
	set(v):
		omni_height = v
		if _omni:
			_omni.position.y = v
var spot_cookie := 0:
	set(v):
		spot_cookie = v
		if _spot:
			_spot.light_projector = ProcTextures.cookie(ProcTextures.COOKIES[v])
var area_width := 2.0:
	set(v):
		area_width = v
		if _area:
			_area.area_size = Vector2(area_width, area_height)
var area_height := 1.2:
	set(v):
		area_height = v
		if _area:
			_area.area_size = Vector2(area_width, area_height)
var directional_atlas_size := 4096:
	set(v):
		directional_atlas_size = v
		RenderingServer.directional_shadow_atlas_set_size(v, true)
var directional_filter_quality := RenderingServer.SHADOW_QUALITY_SOFT_LOW:
	set(v):
		directional_filter_quality = v
		RenderingServer.directional_soft_shadow_filter_set_quality(v)
var positional_filter_quality := RenderingServer.SHADOW_QUALITY_SOFT_LOW:
	set(v):
		positional_filter_quality = v
		RenderingServer.positional_soft_shadow_filter_set_quality(v)

var _sun: DirectionalLight3D
var _omni: OmniLight3D
var _spot: SpotLight3D
var _area: AreaLight3D
var _env: Environment


func get_title() -> String:
	return "03 光源类型与阴影"


func get_overview() -> String:
	return """[b]光源类型[/b]
• [b]DirectionalLight3D[/b] 平行光：无限远 (太阳)，只有方向没有位置，不衰减。阴影用[b]级联阴影贴图 (PSSM)[/b]：近处一张高精度、远处几张低精度。
• [b]OmniLight3D[/b] 点光：向四周发光，range 内按 attenuation 曲线衰减。阴影要渲染 6 个面 (cube) 或 2 个半球 (dual paraboloid)，开销最大。
• [b]SpotLight3D[/b] 聚光：锥形，有 spot_angle 和边缘衰减，可以加投影纹理 (cookie)。
• [b]AreaLight3D[/b] 面光 (Godot 4.7 新增)：矩形发光面，高光是一块“窗户形”而不是一个点，软阴影更自然。

[b]阴影贴图原理[/b]：先从光源视角渲染一张深度图，再判断像素是否比深度图记录的更远 → 在阴影中。深度精度有限，所以要加[b]偏移 (bias)[/b]：
• bias 太小 → [b]阴影痤疮[/b] (表面出现条纹/摩尔纹)；bias 太大 → [b]漂浮 (peter-panning)[/b]，阴影和物体脱开。
• normal_bias 沿法线方向偏移，对掠射角更有效，通常比单纯加大 bias 副作用小。

[b]试一试[/b]
1. 依次点「阴影痤疮」「漂浮」两个预设，然后自己调 shadow_bias，找到既没条纹也不漂浮的值。
2. 选「级联可视化」：Debug View 用不同颜色标出每一级级联，调 split_1/2/3 和 max_distance 观察覆盖范围。
3. 把阴影图集降到 1024、过滤设为 Hard，看栅栏的阴影如何变成锯齿；再开 Soft Ultra 对比。
4. 关掉太阳，只用点光、聚光、面光，看三种光源的衰减形状和高光形状有什么不同。"""


func get_camera_bookmarks() -> Dictionary:
	return {
		"总览": {"target": Vector3(0, 1.0, -0.5), "yaw": 18.0, "pitch": -22.0, "distance": 15.0},
		"地面特写": {"target": Vector3(-2.2, 0.3, 2.2), "yaw": 30.0, "pitch": -28.0, "distance": 3.5},
		"薄板特写": {"target": Vector3(0.6, 0.4, 0.6), "yaw": 35.0, "pitch": -24.0, "distance": 4.2},
		"栅栏": {"target": Vector3(4.6, 0.4, 3.0), "yaw": 20.0, "pitch": -40.0, "distance": 4.5},
		"长廊 (级联)": {"target": Vector3(11.0, 1.5, -25.0), "yaw": 0.0, "pitch": -10.0, "distance": 30.0},
		"面光特写": {"target": Vector3(-3.9, 1.0, 0.0), "yaw": 55.0, "pitch": -14.0, "distance": 6.0},
	}


func get_presets() -> Dictionary:
	return {
		"① 阴影痤疮 Shadow Acne": {"sun.shadow_bias": 0.0, "sun.shadow_normal_bias": 0.0, "light.sun_elevation": 22.0, "_camera": "地面特写",
			"_note": "bias 与 normal_bias 都为 0：表面和自己的阴影深度“打架”，出现条纹或摩尔纹，掠射角 (太阳低) 时最明显。逐渐调大 sun.shadow_normal_bias，条纹会先消失。"},
		"② 漂浮 Peter Panning": {"sun.shadow_bias": 1.5, "sun.shadow_normal_bias": 4.0, "_camera": "薄板特写",
			"_note": "偏移过大：阴影被推离物体，立方体、桌腿与地面接触处出现缝隙，物体看起来像浮在地面上。薄板这类薄物体的阴影会缩小甚至整片消失 —— 把 shadow_bias 继续调大试试。"},
		"③ 级联可视化 PSSM": {"_debug": Viewport.DEBUG_DRAW_PSSM_SPLITS, "_camera": "长廊 (级联)",
			"_note": "Debug View = PSSM Splits：阴影区域按所属级联着色 (近→远：绿、蓝、黄……)。近处级联覆盖范围小、像素密度高；远处覆盖范围大、精度低。调 split_1/2/3 改变每一级的边界比例，调 max_distance 改变总覆盖距离。"},
		"④ 级联接缝": {"sun.directional_shadow_blend_splits": false, "global.directional_atlas_size": 1024, "global.directional_filter_quality": RenderingServer.SHADOW_QUALITY_HARD, "_camera": "长廊 (级联)",
			"_note": "关闭 blend_splits 并降低分辨率后，相邻级联之间阴影清晰度突变，会出现一条可见的“接缝”。blend_splits 会在交界处混合两级，代价是多一次采样。"},
		"⑤ 阴影距离太短": {"sun.directional_shadow_max_distance": 20.0, "_camera": "长廊 (级联)",
			"_note": "max_distance = 20 米：远处柱子的阴影直接消失。距离越短，同样的分辨率覆盖的区域越小，近处阴影越清晰 —— 这是精度与覆盖范围的权衡。"},
		"⑥ 低分辨率 + 正交单图": {"sun.directional_shadow_mode": DirectionalLight3D.SHADOW_ORTHOGONAL, "sun.directional_shadow_max_distance": 150.0, "global.directional_atlas_size": 1024, "global.directional_filter_quality": RenderingServer.SHADOW_QUALITY_HARD, "_camera": "栅栏",
			"_note": "只用一张阴影图覆盖 150 米，栅栏阴影变成大块锯齿甚至消失。这就是为什么平行光需要级联 (PSSM)。"},
		"⑦ 软阴影 PCSS": {"sun.light_angular_distance": 3.0, "omni.light_size": 0.5, "global.directional_filter_quality": RenderingServer.SHADOW_QUALITY_SOFT_ULTRA, "global.positional_filter_quality": RenderingServer.SHADOW_QUALITY_SOFT_ULTRA, "_camera": "薄板特写",
			"_note": "light_angular_distance (平行光) / light_size (点光、聚光) 让光源有了“大小”：离遮挡物越远，阴影越模糊 (接触硬化)。真实的太阳角直径约 0.5°。"},
		"⑧ 点光阴影": {"sun.visible": false, "env.ambient_light_sky_contribution": 0.08, "omni.omni_shadow_mode": OmniLight3D.SHADOW_CUBE, "_camera": "总览",
			"_note": "只剩暖色点光。点光阴影要覆盖全部 360°：Cube 模式渲染 6 个面，质量好但慢；Dual Paraboloid 只渲染 2 次但边缘会变形。切换 Debug View → Shadow Atlas 看点光阴影在图集里占的格子。"},
		"⑨ 聚光灯 + 投影纹理": {"sun.visible": false, "omni.visible": false, "spot.visible": true, "light.spot_cookie": 1, "env.ambient_light_sky_contribution": 0.06, "_camera": "薄板特写",
			"_note": "聚光灯加上 light_projector (cookie) 投出窗框图案，常用于模拟窗户光、手电筒、舞台灯。spot_angle_attenuation 控制光锥边缘的软硬。"},
		"⑩ 面光源 AreaLight3D": {"sun.visible": false, "omni.visible": false, "area.visible": true, "env.ambient_light_sky_contribution": 0.06, "_camera": "面光特写",
			"_note": "Godot 4.7 的面光源：一块 2×1.2 米、向下倾斜的“柔光箱”(发光方向是节点的 -Z)。注意光滑球上的高光是一块矩形“窗户”而不是一个点；把 area_width/height 调大，阴影边缘会变得更软。"},
		"⑪ 平行光阴影图集": {"_debug": Viewport.DEBUG_DRAW_DIRECTIONAL_SHADOW_ATLAS, "_camera": "总览",
			"_note": "Debug View = Directional Shadow Atlas：直接看阴影深度图本身。4 个级联排成 2×2。改 directional_atlas_size 观察分辨率变化。"},
		"⑫ 夜景多光源": {"sun.visible": false, "spot.visible": true, "area.visible": true, "light.spot_cookie": 2, "env.ambient_light_sky_contribution": 0.03, "_camera": "总览",
			"_note": "多个局部光源叠加。打开 Debug View → Cluster Omni/Spot/Area Lights，可以看到 Forward+ 把屏幕分成小格 (cluster)，每格只计算影响它的灯 —— 这就是 Forward+ 能支持大量光源的原因。"},
	}


func _build_scene() -> void:
	var we := SceneKit.make_environment(self, Environment.TONE_MAPPER_FILMIC)
	_env = we.environment
	_env.ambient_light_sky_contribution = 0.6
	SceneKit.plane(self, Vector2(400, 400), Vector3.ZERO, SceneKit.checker_mat(Color(0.55, 0.55, 0.56), Color(0.46, 0.46, 0.48), 200.0), "Floor")

	var wall_mat := SceneKit.mat(Color(0.72, 0.7, 0.66), 0.85)
	SceneKit.box(self, Vector3(14, 4, 0.3), Vector3(0, 2, -6), wall_mat, "BackWall")
	SceneKit.box(self, Vector3(0.3, 4, 10), Vector3(-7, 2, -1), wall_mat, "LeftWall")
	for x in [-4.5, -2.5]:
		SceneKit.box(self, Vector3(0.6, 3.5, 0.6), Vector3(x, 1.75, -3.8), SceneKit.mat(Color(0.6, 0.62, 0.68), 0.6))
	SceneKit.box(self, Vector3(1.2, 1.2, 1.2), Vector3(-3.0, 0.6, 1.0), SceneKit.mat(Color(0.8, 0.45, 0.35), 0.6), "Cube")
	SceneKit.label(self, "立方体", Vector3(-3.0, 1.6, 1.0), 32)

	# Thin plate on legs: the classic peter-panning victim.
	var plate_mat := SceneKit.mat(Color(0.35, 0.6, 0.85), 0.4)
	SceneKit.box(self, Vector3(2.0, 0.04, 1.4), Vector3(0.8, 0.7, 0.8), plate_mat, "ThinPlate")
	for dx in [-0.9, 0.9]:
		for dz in [-0.6, 0.6]:
			SceneKit.cylinder(self, 0.03, 0.68, Vector3(0.8 + dx, 0.34, 0.8 + dz), plate_mat)
	SceneKit.label(self, "薄板 (看漂浮)", Vector3(0.8, 1.25, 0.8), 32)

	# Fence: thin posts for shadow resolution / filtering.
	var fence_mat := SceneKit.mat(Color(0.75, 0.68, 0.55), 0.7)
	for i in 14:
		SceneKit.box(self, Vector3(0.06, 1.3, 0.06), Vector3(3.0 + i * 0.25, 0.65, 2.6), fence_mat)
	SceneKit.box(self, Vector3(3.4, 0.06, 0.06), Vector3(4.62, 1.2, 2.6), fence_mat)
	SceneKit.label(self, "栅栏 (细节阴影)", Vector3(4.6, 1.75, 2.6), 32)

	for i in 5:
		var h := 0.3 * (i + 1)
		SceneKit.box(self, Vector3(1.8, h, 0.5), Vector3(4.6, h * 0.5, -3.4 - i * 0.5), SceneKit.mat(Color(0.65, 0.65, 0.62), 0.8))
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	SceneKit.mesh(self, capsule, Vector3(-0.8, 0.9, 2.6), SceneKit.mat(Color(0.85, 0.85, 0.82), 0.5), "Character")
	SceneKit.sphere(self, 0.45, Vector3(2.4, 0.45, -1.2), SceneKit.mat(Color(0.9, 0.9, 0.92), 0.12, 0.0), 48, "GlossySphere")

	# Long corridor of pillars to show cascades and max distance.
	var pillar_mat := SceneKit.mat(Color(0.7, 0.66, 0.6), 0.8)
	for i in 16:
		for x in [9.0, 13.0]:
			SceneKit.box(self, Vector3(0.8, 5, 0.8), Vector3(x, 2.5, 2.0 - i * 10.0), pillar_mat)
	SceneKit.label(self, "长廊 → 160 m", Vector3(11, 5.6, 2.0), 40)

	_sun = SceneKit.dir_light(self, "Sun", sun_azimuth, sun_elevation, Color(1.0, 0.96, 0.9), 1.1)
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_omni = SceneKit.omni_light(self, "Omni", Vector3(-4.6, omni_height, -1.6), Color(1.0, 0.72, 0.45), 2.5, 7.0, true)
	_spot = SpotLight3D.new()
	_spot.name = "Spot"
	_spot.position = Vector3(2.6, 4.6, 4.2)
	_spot.light_color = Color(0.78, 0.86, 1.0)
	_spot.light_energy = 8.0
	_spot.spot_range = 12.0
	_spot.spot_angle = 30.0
	_spot.shadow_enabled = true
	_spot.visible = false
	add_child(_spot)
	_spot.look_at(Vector3(0.8, 0.0, 0.6))
	# Free-standing "softbox" area light tilted down towards the cube.
	_area = AreaLight3D.new()
	_area.name = "Area"
	_area.position = Vector3(-5.6, 2.6, 0.4)
	_area.light_color = Color(1.0, 0.95, 0.86)
	_area.light_energy = 10.0
	_area.area_range = 9.0
	_area.area_size = Vector2(area_width, area_height)
	_area.shadow_enabled = true
	_area.visible = false
	add_child(_area)
	_area.look_at(Vector3(-2.6, 0.3, 0.8))
	# Visualise the emitting rectangle (AreaLight3D emits along its local -Z;
	# the panel sits just behind the emission plane and follows area_size).
	var panel := SceneKit.box(_area, Vector3(1, 1, 0.02), Vector3(0, 0, 0.02), SceneKit.emissive(Color(1.0, 0.95, 0.86), 3.0), "AreaPanel")
	panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_area.set_meta("panel", panel)
	SceneKit.sphere(self, 0.45, Vector3(-3.6, 0.45, -1.0), SceneKit.mat(Color(0.9, 0.9, 0.92), 0.08), 48, "GlossySphere2")


func _process(_delta: float) -> void:
	var panel: Node3D = _area.get_meta("panel")
	panel.scale = Vector3(area_width, area_height, 1.0)


func _build_params() -> void:
	group("Directional 平行光 (太阳)")
	add_bool("sun.visible", _sun, "visible", "启用平行光：太阳/月光这类无限远光源。")
	add_range("light.sun_azimuth", self, "sun_azimuth", 0.0, 360.0, 1.0, "方位角：太阳绕 Y 轴的方向。")
	add_range("light.sun_elevation", self, "sun_elevation", 2.0, 90.0, 0.5, "仰角：太阳越低，影子越长，掠射角下阴影痤疮越明显。")
	add_range("sun.light_energy", _sun, "light_energy", 0.0, 4.0, 0.01, "强度：平行光不随距离衰减，整个场景亮度一致。")
	add_color("sun.light_color", _sun, "light_color", "颜色：正午偏白，黄昏偏橙，月光偏蓝。")
	add_range("tool.sun_temperature", self, "sun_temperature", 1500.0, 12000.0, 50.0, "色温工具 (K)：拖动时按黑体辐射近似改写 light_color。1900K 烛光、3000K 钨丝灯、5500K 正午、6500K 阴天、10000K 蓝天阴影。(Godot 自带的 light_temperature 需要开启物理灯光单位)", {"meta": true, "no_init": true, "refresh_all": true})
	add_range("sun.light_angular_distance", _sun, "light_angular_distance", 0.0, 10.0, 0.05, "角直径 (软阴影)：光源在天空中的视角大小。>0 时启用 PCSS 软阴影，离遮挡物越远阴影越虚。太阳约 0.5°。")
	add_range("sun.light_specular", _sun, "light_specular", 0.0, 4.0, 0.01, "高光贡献：这盏光在光滑表面上产生高光的强度倍数。")
	add_bool("sun.shadow_enabled", _sun, "shadow_enabled", "投射阴影")
	add_range("sun.shadow_bias", _sun, "shadow_bias", 0.0, 4.0, 0.005, "深度偏移：比较深度前把表面往光源反方向推一点。太小 → 阴影痤疮 (条纹)；太大 → peter-panning (阴影与物体分离)。")
	add_range("sun.shadow_normal_bias", _sun, "shadow_normal_bias", 0.0, 10.0, 0.01, "法线偏移：沿表面法线方向偏移采样点。对掠射角的痤疮更有效，副作用比加大 bias 小。")
	add_range("sun.shadow_blur", _sun, "shadow_blur", 0.0, 4.0, 0.01, "阴影模糊：PCF 过滤半径的倍数，越大越软。与 light_angular_distance 不同，它对整个阴影统一模糊。")
	add_range("sun.shadow_opacity", _sun, "shadow_opacity", 0.0, 1.0, 0.01, "阴影不透明度：1 为完全遮挡。降低它是“假”补光，物理上不正确但美术上常用。")
	add_enum("sun.directional_shadow_mode", _sun, "directional_shadow_mode", [["Orthogonal 单张", DirectionalLight3D.SHADOW_ORTHOGONAL], ["PSSM 2 Splits", DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS], ["PSSM 4 Splits", DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS]], "阴影模式：级联数量。级联越多，近处越清晰，但要多渲染几次阴影图。")
	add_range("sun.directional_shadow_split_1", _sun, "directional_shadow_split_1", 0.0, 1.0, 0.005, "第 1 级边界：占 max_distance 的比例。越小，第一级越集中在镜头附近、越清晰。")
	add_range("sun.directional_shadow_split_2", _sun, "directional_shadow_split_2", 0.0, 1.0, 0.005, "第 2 级边界：占 max_distance 的比例。")
	add_range("sun.directional_shadow_split_3", _sun, "directional_shadow_split_3", 0.0, 1.0, 0.005, "第 3 级边界：占 max_distance 的比例。")
	add_bool("sun.directional_shadow_blend_splits", _sun, "directional_shadow_blend_splits", "级联混合：在两级交界处平滑过渡，消除接缝，代价是交界区多一次采样。")
	add_range("sun.directional_shadow_max_distance", _sun, "directional_shadow_max_distance", 5.0, 500.0, 0.5, "阴影最大距离：超过该距离不再有阴影。越大覆盖越远，但同样分辨率下精度越低。", {"exp": true})
	add_range("sun.directional_shadow_fade_start", _sun, "directional_shadow_fade_start", 0.0, 1.0, 0.01, "淡出起点：从 max_distance 的这个比例开始阴影逐渐淡出，避免远处阴影突然消失。")
	add_range("sun.directional_shadow_pancake_size", _sun, "directional_shadow_pancake_size", 0.0, 50.0, 0.1, "Pancake 尺寸：把阴影相机前方的物体“压扁”到近平面，提高深度精度。场景很大时若出现阴影缺失，可以调大它。")

	group("Omni 点光")
	add_bool("omni.visible", _omni, "visible", "启用点光：左侧柱子旁的暖色点光。")
	add_range("light.omni_height", self, "omni_height", 0.3, 3.8, 0.01, "点光高度：光源越低，阴影越长。")
	add_range("omni.light_energy", _omni, "light_energy", 0.0, 16.0, 0.01, "强度")
	add_color("omni.light_color", _omni, "light_color", "颜色")
	add_range("omni.omni_range", _omni, "omni_range", 0.5, 30.0, 0.1, "范围：超出 range 的像素完全不受影响 (也是 Forward+ 分簇剔除的依据)。range 越小越省。")
	add_range("omni.omni_attenuation", _omni, "omni_attenuation", 0.0, 4.0, 0.01, "衰减曲线：1 ≈ 物理平方反比 (近处很亮、迅速变暗)；<1 衰减更平缓；>1 更集中。")
	add_range("omni.light_size", _omni, "light_size", 0.0, 2.0, 0.01, "光源尺寸：点光的物理半径。>0 时阴影边缘随距离变软 (PCSS)，高光也更大。")
	add_range("omni.light_specular", _omni, "light_specular", 0.0, 4.0, 0.01, "高光贡献")
	add_bool("omni.shadow_enabled", _omni, "shadow_enabled", "投射阴影：点光阴影最贵 (要覆盖 360°)，大量点光时应只给少数几盏开阴影。")
	add_range("omni.shadow_bias", _omni, "shadow_bias", 0.0, 2.0, 0.005, "深度偏移 (点光)")
	add_range("omni.shadow_normal_bias", _omni, "shadow_normal_bias", 0.0, 4.0, 0.01, "法线偏移 (点光)")
	add_enum("omni.omni_shadow_mode", _omni, "omni_shadow_mode", [["Dual Paraboloid 双抛物面", OmniLight3D.SHADOW_DUAL_PARABOLOID], ["Cube 立方体", OmniLight3D.SHADOW_CUBE]], "点光阴影模式：Cube 渲染 6 次，质量高；Dual Paraboloid 渲染 2 次，更快但低模物体阴影会变形。")

	group("Spot 聚光")
	add_bool("spot.visible", _spot, "visible", "启用聚光：从右前上方照向薄板。")
	add_range("spot.light_energy", _spot, "light_energy", 0.0, 32.0, 0.01, "强度")
	add_color("spot.light_color", _spot, "light_color", "颜色")
	add_range("spot.spot_range", _spot, "spot_range", 0.5, 40.0, 0.1, "范围")
	add_range("spot.spot_angle", _spot, "spot_angle", 1.0, 80.0, 0.1, "锥角：光锥半角 (度)。")
	add_range("spot.spot_angle_attenuation", _spot, "spot_angle_attenuation", 0.01, 8.0, 0.01, "锥边衰减：光锥边缘的过渡。越大中心越集中、边缘越软。")
	add_range("spot.spot_attenuation", _spot, "spot_attenuation", 0.0, 4.0, 0.01, "距离衰减：与点光的 attenuation 含义相同。")
	add_range("spot.light_size", _spot, "light_size", 0.0, 2.0, 0.01, "光源尺寸：>0 时软阴影。")
	add_enum("light.spot_cookie", self, "spot_cookie", ["None", "Window 窗框", "Dots 圆点", "Blinds 百叶窗"], "投影纹理 (light_projector)：给聚光灯一张黑白图案，像幻灯机一样投射出去。")
	add_bool("spot.shadow_enabled", _spot, "shadow_enabled", "投射阴影")
	add_range("spot.shadow_bias", _spot, "shadow_bias", 0.0, 2.0, 0.005, "深度偏移 (聚光)")
	add_range("spot.shadow_normal_bias", _spot, "shadow_normal_bias", 0.0, 4.0, 0.01, "法线偏移 (聚光)")

	group("Area 面光 (4.7)")
	add_bool("area.visible", _area, "visible", "启用面光：立方体左侧向下倾斜的矩形柔光箱 (AreaLight3D，Godot 4.7 新增，沿节点 -Z 方向单面发光)。")
	add_range("area.light_energy", _area, "light_energy", 0.0, 32.0, 0.01, "强度")
	add_color("area.light_color", _area, "light_color", "颜色")
	add_range("light.area_width", self, "area_width", 0.1, 6.0, 0.01, "宽度：发光矩形的宽 (area_size.x)。面积越大，阴影越软，高光越大。")
	add_range("light.area_height", self, "area_height", 0.1, 4.0, 0.01, "高度：发光矩形的高 (area_size.y)。")
	add_range("area.area_range", _area, "area_range", 0.5, 30.0, 0.1, "范围")
	add_range("area.area_attenuation", _area, "area_attenuation", 0.0, 4.0, 0.01, "距离衰减")
	add_bool("area.area_normalize_energy", _area, "area_normalize_energy", "能量归一化：开启时总亮度不随面积变化 (面积变大、单位面积变暗)；关闭时面积越大越亮。")
	add_bool("area.shadow_enabled", _area, "shadow_enabled", "投射阴影")

	group("Global 全局阴影设置")
	add_enum("global.directional_atlas_size", self, "directional_atlas_size", ATLAS_SIZES, "平行光阴影图集尺寸：所有级联共用这张图 (4 级时每级只有 1/4)。越大越清晰，显存与带宽开销越大。项目设置：rendering/lights_and_shadows/directional_shadow/size。", {"global": true})
	add_enum("global.directional_filter_quality", self, "directional_filter_quality", QUALITY, "平行光阴影过滤：每个像素采样阴影图的次数。Hard 只采 1 次 (锯齿)，Ultra 采样最多 (最软最贵)。", {"global": true})
	add_enum("global.positional_filter_quality", self, "positional_filter_quality", QUALITY, "点光/聚光阴影过滤：同上，作用于点光和聚光。", {"global": true})
	add_enum("global.positional_atlas_size", get_viewport(), "positional_shadow_atlas_size", ATLAS_SIZES, "点光/聚光阴影图集尺寸 (Viewport 属性)：所有点光、聚光的阴影共享这张图，按屏幕占比分配格子。", {"global": true})

	group("Environment 环境")
	add_range("env.ambient_light_sky_contribution", _env, "ambient_light_sky_contribution", 0.0, 1.0, 0.01, "环境光强度 (天空贡献)：环境光里来自天空的比例。环境光颜色为黑色时，它就是天空环境光的强度，0 = 暗部全黑，只剩直接光。[b]坑[/b]：来源为 Sky 时 ambient_light_energy 只缩放 ambient_light_color 那一部分，sky_contribution = 1 时调它完全没有效果。 夜景预设把它调得很低，以便看清局部光源。")
