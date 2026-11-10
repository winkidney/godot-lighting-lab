extends "res://scripts/lab/lab_module.gd"
## 02 光照模型对比: Lambert / Half-Lambert / Phong / Blinn-Phong / Toon written
## in light(), next to Godot's PBR, plus a roughness x metallic sphere chart.

const SceneKit := preload("res://scripts/lib/scene_kit.gd")
const VectorGizmos := preload("res://scripts/lab/vector_gizmos.gd")
const MODEL_SHADER := preload("res://shaders/lighting_models.gdshader")

const MODELS := ["Lambert", "Half-Lambert", "Phong", "Blinn-Phong", "Toon 卡通"]
const TERM_VIEWS := [
	"Full 完整结果", "Diffuse 只看漫反射", "Specular 只看高光",
	"Fresnel/Rim (1-N·V)^p", "N·L 兰伯特项", "N·H 半程向量项",
]

var term_view := 0:
	set(v):
		term_view = v
		_su("term_view", v)
var albedo := Color(0.8, 0.36, 0.26):
	set(v):
		albedo = v
		_su("albedo", v)
		if _pbr_mat:
			_pbr_mat.albedo_color = v
var shininess := 48.0:
	set(v):
		shininess = v
		_su("shininess", v)
var specular_strength := 0.6:
	set(v):
		specular_strength = v
		_su("specular_strength", v)
var energy_conserving := false:
	set(v):
		energy_conserving = v
		_su("energy_conserving", v)
var wrap := 0.5:
	set(v):
		wrap = v
		_su("wrap", v)
var toon_steps := 3:
	set(v):
		toon_steps = v
		_su("toon_steps", v)
var toon_smooth := 0.02:
	set(v):
		toon_smooth = v
		_su("toon_smooth", v)
var rim_strength := 0.0:
	set(v):
		rim_strength = v
		_su("rim_strength", v)
var rim_power := 4.0:
	set(v):
		rim_power = v
		_su("rim_power", v)
var grid_albedo := Color(0.9, 0.62, 0.3):
	set(v):
		grid_albedo = v
		for m in _grid_mats:
			m.albedo_color = v
var light_azimuth := 35.0:
	set(v):
		light_azimuth = v
		if _key:
			SceneKit.aim_light(_key, light_azimuth, light_elevation)
var light_elevation := 40.0:
	set(v):
		light_elevation = v
		if _key:
			SceneKit.aim_light(_key, light_azimuth, light_elevation)
var point_orbit := true
var show_lvh := false:
	set(v):
		show_lvh = v
		if _gizmo and not v:
			_gizmo.clear()

var _key: DirectionalLight3D
var _point: OmniLight3D
var _env: Environment
var _model_mats: Array[ShaderMaterial] = []
var _pbr_mat: StandardMaterial3D
var _grid_mats: Array[StandardMaterial3D] = []
var _spheres: Array[MeshInstance3D] = []
var _gizmo: VectorGizmos
var _time := 0.0


func get_title() -> String:
	return "02 光照模型对比"


func get_overview() -> String:
	return """光照模型就是一个公式：输入法线 N、光线方向 L、视线方向 V (和材质参数)，输出这个像素反射了多少光。
• [b]漫反射[/b]与视角无关：[b]Lambert[/b] = max(N·L, 0)。[b]Half-Lambert[/b] 把 N·L 从 [-1,1] 映射到 [0,1] 再平方，背光面不会死黑，常用于卡通/角色。
• [b]高光[/b]与视角有关：[b]Phong[/b] 用反射向量 R 与 V 的夹角；[b]Blinn-Phong[/b] 用半程向量 H = normalize(L+V) 与 N 的夹角，更便宜也更接近真实。指数 (shininess) 越大高光越小越亮。
• [b]PBR[/b] (Godot 的 StandardMaterial3D) 用 roughness/metallic 描述材质，内部是 Burley 漫反射 + GGX 高光 + Schlick 菲涅尔，并且能量守恒。
• 这些模型都写在 shader 的 [code]light()[/code] 函数里：引擎为每盏光调用一次，把结果累加。

[b]试一试[/b]
1. term_view 依次切到 N·L、N·H、Fresnel，看公式的每一项“长什么样”。
2. 打开 debug.show_lvh：在 Blinn-Phong 球上画出 N/L/V/H/R 向量，转动相机看高光如何跟着 H 移动。
3. 把光源转到背后 (azimuth≈170°)，对比 Lambert 与 Half-Lambert 的暗面。
4. 打开 energy_conserving 后把 shininess 从 8 拉到 512：高光变小时亮度自动升高，这就是“能量守恒”。
5. 切到「PBR 球阵」机位：横向 roughness 0→1，纵向 metallic 0→1。"""


func get_camera_bookmarks() -> Dictionary:
	return {
		"总览": {"target": Vector3(0, 1.1, 0), "yaw": 0.0, "pitch": -10.0, "distance": 14.5},
		"Blinn-Phong 特写": {"target": Vector3(1.2, 1.0, 0), "yaw": 15.0, "pitch": -12.0, "distance": 4.0},
		"向量侧视": {"target": Vector3(1.4, 1.6, 0.6), "yaw": 72.0, "pitch": -14.0, "distance": 4.6},
		"漫反射对比": {"target": Vector3(-4.8, 1.0, 0), "yaw": 0.0, "pitch": -8.0, "distance": 6.0},
		"PBR 球阵": {"target": Vector3(0, 2.7, -8), "yaw": 0.0, "pitch": -4.0, "distance": 9.0},
	}


func get_presets() -> Dictionary:
	return {
		"① 只看漫反射": {"model.term_view": 1,
			"_note": "只保留漫反射项 (含光源颜色与衰减)。Lambert/Phong/Blinn 三个球的漫反射完全相同 —— 它们的区别只在高光。"},
		"② 只看高光": {"model.term_view": 2, "_camera": "Blinn-Phong 特写",
			"_note": "只保留高光项。对比 Phong 与 Blinn-Phong：同样的 shininess，Blinn-Phong 的高光更大更圆 (N·H 比 R·V 变化慢)，一般需要约 4 倍指数才接近 Phong。"},
		"③ N·L 兰伯特项": {"model.term_view": 4,
			"_note": "N·L = cos(法线与光线夹角)。正对光源为 1 (白)，与光线垂直为 0，背光面被 max() 截成 0。所有漫反射都从这一项出发。"},
		"④ N·H 与向量可视化": {"model.term_view": 5, "debug.show_lvh": true, "_camera": "向量侧视",
			"_note": "N·H：法线与半程向量 H 夹角的余弦。箭头：N 蓝 / L 黄 / V 白 / H 品红 / R 青 (L 关于 N 的镜像)。V 指向球前方一个固定的观察点，所以可以从侧面看清所有向量。Blinn-Phong 比较 N 与 H，Phong 比较 R 与 V：当 N 转到与 H 重合时，R 也恰好与 V 重合，两种模型在同一点达到高光峰值。"},
		"⑤ 菲涅尔/边缘项": {"model.term_view": 3, "model.rim_power": 3.0,
			"_note": "(1 - N·V)^p：视线越掠过表面越接近 1。真实材质在掠射角反射更强 (菲涅尔效应)，卡通渲染常用它做边缘光 (rim light)。"},
		"⑥ 高光指数 512": {"model.shininess": 512.0, "_camera": "Blinn-Phong 特写",
			"_note": "指数越大，高光越小越锐利，对应越光滑的表面。没有能量守恒时，高光只是变小却不变亮，看起来像“变暗了”。"},
		"⑦ 能量守恒": {"model.energy_conserving": true, "model.shininess": 256.0, "_camera": "Blinn-Phong 特写",
			"_note": "乘上归一化系数 (n+8)/8 (Blinn) 或 (n+2)/2 (Phong) 后，高光越集中峰值越亮，总反射能量保持不变。PBR 天生满足这一点。"},
		"⑧ 卡通渲染": {"model.toon_steps": 2, "model.toon_smooth": 0.01, "model.rim_strength": 0.5, "model.rim_power": 6.0, "_camera": "Blinn-Phong 特写",
			"_note": "把 N·L 量化成几个色阶，高光用阈值硬切，再加一圈边缘光，就是最基础的 Toon shading。toon_smooth 控制色阶边缘的柔和度。"},
		"⑨ 逆光：Half-Lambert 的意义": {"light.azimuth": 150.0, "light.elevation": 15.0, "env.ambient_light_sky_contribution": 0.15, "key.shadow_enabled": false, "_camera": "漫反射对比",
			"_note": "光从侧后方照来时，Lambert 球的暗面几乎全黑 (只剩环境光)；Half-Lambert 把暗面也映射出层次 (wrap 越大越亮)，代价是不再物理正确。[b]注意本预设关闭了阴影[/b]：light() 里的 ATTENUATION 包含阴影，背光面处在球自身的阴影中，ATTENUATION=0 会把 wrap 的效果吃掉。按 key.shadow_enabled 打开阴影再看一次 —— 这就是卡通渲染常对角色关闭自阴影、或把阴影单独处理的原因。"},
		"⑩ 关闭环境光": {"env.ambient_light_sky_contribution": 0.0,
			"_note": "环境光为 0 时，背光面完全由直接光决定 (Lambert 暗面纯黑)。对比默认值，就能看出环境光对暗部的贡献有多大。"},
		"⑪ PBR 球阵": {"_camera": "PBR 球阵", "light.azimuth": 25.0, "light.elevation": 30.0,
			"_note": "横向 roughness 0 → 1，纵向 metallic 0 (下) → 1 (上)。注意：金属没有漫反射，颜色全部来自高光与反射；粗糙度越高，高光越宽越暗。"},
		"⑫ 强光 + ACES 色调映射": {"key.light_energy": 4.0, "env.tonemap_mode": Environment.TONE_MAPPER_ACES, "_camera": "总览",
			"_note": "光照强度 4 时，Linear 色调映射下高光大片“死白”。ACES/AgX 会把超过 1 的亮度压缩进可显示范围。按 1/2 存 A/B 再切 tonemap_mode 对比。"},
	}


func _build_scene() -> void:
	var we := SceneKit.make_environment(self, Environment.TONE_MAPPER_LINEAR)
	_env = we.environment
	_env.ambient_light_sky_contribution = 0.6
	_key = SceneKit.dir_light(self, "KeyLight", light_azimuth, light_elevation, Color(1.0, 0.97, 0.92), 1.2)
	_point = SceneKit.omni_light(self, "PointLight", Vector3(0, 2.2, 2.0), Color(0.45, 0.65, 1.0), 2.0, 6.0)
	_point.visible = false
	SceneKit.plane(self, Vector2(60, 60), Vector3.ZERO, SceneKit.checker_mat(Color(0.2, 0.21, 0.23), Color(0.16, 0.17, 0.19), 30.0), "Floor")

	for i in MODELS.size():
		var m := ShaderMaterial.new()
		m.shader = MODEL_SHADER
		m.set_shader_parameter("model", i)
		_model_mats.append(m)
		var pos := Vector3(-6.0 + 2.4 * i, 1.0, 0)
		_spheres.append(SceneKit.sphere(self, 0.85, pos, m, 64, "Model_%s" % MODELS[i]))
		SceneKit.label(self, MODELS[i], pos + Vector3(0, 1.3, 0), 40)
	_pbr_mat = SceneKit.mat(albedo, 0.35)
	_pbr_mat.resource_name = "PBRMaterial"
	var pbr_pos := Vector3(6.0, 1.0, 0)
	_spheres.append(SceneKit.sphere(self, 0.85, pbr_pos, _pbr_mat, 64, "Model_PBR"))
	SceneKit.label(self, "Godot PBR\nStandardMaterial3D", pbr_pos + Vector3(0, 1.45, 0), 36)

	# Roughness (x) x metallic (y) chart in front of a dark backdrop.
	# The chart must not shadow the model row when the light comes from behind.
	var backdrop := SceneKit.box(self, Vector3(8, 6.4, 0.2), Vector3(0, 3.0, -9.0), SceneKit.mat(Color(0.08, 0.085, 0.1), 0.9), "Backdrop")
	backdrop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for row in 5:
		for col in 5:
			var gm := SceneKit.mat(grid_albedo, col / 4.0, row / 4.0)
			_grid_mats.append(gm)
			var gs := SceneKit.sphere(self, 0.42, Vector3(-2.2 + col * 1.1, 0.75 + row * 1.1, -8), gm, 48)
			gs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	SceneKit.label(self, "roughness 0 → 1", Vector3(0, 0.3, -7.0), 40)
	SceneKit.label(self, "metallic\n0 → 1 ↑", Vector3(-3.4, 2.95, -8), 40)

	_gizmo = VectorGizmos.new()
	_gizmo.set_on_top(true)
	add_child(_gizmo)


func _build_params() -> void:
	group("Model 光照模型 (前五个球)")
	add_enum("model.term_view", self, "term_view", TERM_VIEWS, "显示项：只显示公式中的某一项。Full 为完整结果；Diffuse/Specular 含光源颜色与衰减；Fresnel、N·L、N·H 是只取主光 (平行光) 的纯几何项，用灰度显示 0~1。最右边的 PBR 球不受影响。")
	add_color("model.albedo", self, "albedo", "反照率：表面本身的颜色 (漫反射颜色)。同时作用于 PBR 参考球。")
	add_range("model.shininess", self, "shininess", 1.0, 1024.0, 0.5, "高光指数：pow(cos, n) 中的 n。越大高光越小越锐利，表示表面越光滑。", {"exp": true})
	add_range("model.specular_strength", self, "specular_strength", 0.0, 4.0, 0.01, "高光强度：高光项的倍数。经典模型里它和漫反射是独立调的，所以很容易“不守恒”。")
	add_bool("model.energy_conserving", self, "energy_conserving", "能量守恒归一化：给高光乘上 (n+8)/8 (Blinn) 或 (n+2)/2 (Phong)。指数越大峰值越亮，总能量不变。")
	add_range("model.wrap", self, "wrap", 0.0, 1.0, 0.01, "包裹系数：Half-Lambert 的 wrap。0 = 普通 Lambert；0.5 = 经典 Half-Lambert ((N·L×0.5+0.5)²)；1 = 背面也全亮。")
	add_range("model.toon_steps", self, "toon_steps", 1.0, 8.0, 1.0, "色阶数：Toon 模型把 N·L 量化成几个亮度台阶。")
	add_range("model.toon_smooth", self, "toon_smooth", 0.0, 0.2, 0.001, "色阶柔边：台阶边缘的过渡宽度，0 为硬边。")
	add_range("model.rim_strength", self, "rim_strength", 0.0, 2.0, 0.01, "边缘光强度：(1-N·V)^p 乘以光照，叠加到高光上，模拟菲涅尔/轮廓光。")
	add_range("model.rim_power", self, "rim_power", 0.5, 16.0, 0.1, "边缘光指数：越大边缘光越窄、只留在轮廓处。")

	group("Godot PBR 参考球")
	add_range("pbr.roughness", _pbr_mat, "roughness", 0.0, 1.0, 0.01, "粗糙度：微表面的凹凸程度。0 = 镜面，1 = 完全漫反射般的宽高光。替代了经典模型里的 shininess。")
	add_range("pbr.metallic", _pbr_mat, "metallic", 0.0, 1.0, 0.01, "金属度：1 时没有漫反射，高光带上 albedo 颜色；0 时为电介质 (塑料/木头/石头)，高光为白色约 4% 反射率。")
	add_range("pbr.metallic_specular", _pbr_mat, "metallic_specular", 0.0, 1.0, 0.01, "电介质高光：非金属的镜面反射率 (默认 0.5 ≈ 4% F0)。一般无需修改。")
	add_enum("pbr.diffuse_mode", _pbr_mat, "diffuse_mode", [["Burley", BaseMaterial3D.DIFFUSE_BURLEY], ["Lambert", BaseMaterial3D.DIFFUSE_LAMBERT], ["Lambert Wrap", BaseMaterial3D.DIFFUSE_LAMBERT_WRAP], ["Toon", BaseMaterial3D.DIFFUSE_TOON]], "引擎漫反射模型：Godot 内置的漫反射实现。Burley (Disney) 会随粗糙度在边缘变化；Lambert Wrap 类似 Half-Lambert。")
	add_enum("pbr.specular_mode", _pbr_mat, "specular_mode", [["SchlickGGX", BaseMaterial3D.SPECULAR_SCHLICK_GGX], ["Toon", BaseMaterial3D.SPECULAR_TOON], ["Disabled", BaseMaterial3D.SPECULAR_DISABLED]], "引擎高光模型：GGX 是现代 PBR 标准，高光有长长的“拖尾”；Toon 为硬边高光。")

	group("PBR 球阵")
	add_color("grid.albedo", self, "grid_albedo", "球阵颜色：5×5 球阵的 albedo。金属行的高光会带上这个颜色。")

	group("Key Light 主光 (平行光)")
	add_range("light.azimuth", self, "light_azimuth", 0.0, 360.0, 1.0, "方位角：0° 从相机方向照来，90° 从右侧，180° 从背后 (逆光)。")
	add_range("light.elevation", self, "light_elevation", -10.0, 90.0, 0.5, "仰角：90° 为正上方。")
	add_color("key.light_color", _key, "light_color", "光源颜色：会同时影响漫反射和高光。")
	add_range("key.light_energy", _key, "light_energy", 0.0, 6.0, 0.01, "光照强度：light_energy。超过 1 的亮度需要色调映射才能正确显示。")
	add_range("key.light_specular", _key, "light_specular", 0.0, 4.0, 0.01, "高光贡献：这盏光对高光的贡献倍数 (PBR 球与 SPECULAR_AMOUNT)。设为 0 可得到“只有漫反射”的灯，常用于补光。")
	add_bool("key.shadow_enabled", _key, "shadow_enabled", "投射阴影：light() 里的 ATTENUATION 已经包含了阴影，所以自定义光照模型也能接收阴影。")

	group("Point Light 点光")
	add_bool("point.visible", _point, "visible", "启用点光：一盏蓝色点光。light() 会为它再执行一次，结果与主光叠加。")
	add_bool("point.orbit", self, "point_orbit", "点光环绕：让点光沿球排来回移动。")
	add_color("point.light_color", _point, "light_color", "点光颜色")
	add_range("point.light_energy", _point, "light_energy", 0.0, 8.0, 0.01, "点光强度")
	add_range("point.omni_range", _point, "omni_range", 0.5, 20.0, 0.1, "点光范围：超出范围的像素不受这盏光影响。")
	add_range("point.omni_attenuation", _point, "omni_attenuation", 0.0, 4.0, 0.01, "衰减曲线：1 接近物理的平方反比；越小衰减越慢 (范围内更均匀)；越大越集中在中心。")

	group("Environment 环境")
	add_range("env.ambient_light_sky_contribution", _env, "ambient_light_sky_contribution", 0.0, 1.0, 0.01, "环境光强度 (天空贡献)：环境光里来自天空的比例。环境光颜色为黑色时，它就是天空环境光的强度，0 = 暗部全黑，只剩直接光。[b]坑[/b]：来源为 Sky 时 ambient_light_energy 只缩放 ambient_light_color 那一部分，sky_contribution = 1 时调它完全没有效果。")
	add_enum("env.tonemap_mode", _env, "tonemap_mode", [["Linear", Environment.TONE_MAPPER_LINEAR], ["Reinhard", Environment.TONE_MAPPER_REINHARDT], ["Filmic", Environment.TONE_MAPPER_FILMIC], ["ACES", Environment.TONE_MAPPER_ACES], ["AgX", Environment.TONE_MAPPER_AGX]], "色调映射：把 HDR 亮度压到屏幕可显示范围。本模块默认 Linear，便于看清公式的原始数值。")
	add_range("env.tonemap_exposure", _env, "tonemap_exposure", 0.1, 4.0, 0.01, "曝光：色调映射前对画面亮度的整体乘数。")

	group("Debug")
	add_bool("debug.show_lvh", self, "show_lvh", "画出光照向量：在 Blinn-Phong 球表面一点画出 N(蓝) L(黄) V(白) H(品红) R(青)。V 指向球前方一个固定的观察点，转动相机从侧面观察向量间的夹角。")


func _process(delta: float) -> void:
	if _point and _point.visible and point_orbit:
		_time += delta
		_point.position = Vector3(sin(_time * 0.6) * 6.5, 1.6, 1.8)
	if show_lvh and _gizmo:
		# Fixed eye in front of the sphere so the arrows can be viewed from the
		# side (V always points straight at the real camera otherwise).
		var center := _spheres[3].global_position
		var l := SceneKit.dir_from_angles(light_azimuth, light_elevation)
		var v := (center + Vector3(0, 1.5, 6.0) - center).normalized()
		var h := (l + v).normalized()
		# Sample a point whose normal is 25° away from H, so N≠H and R≠V.
		var side := l.cross(v)
		side = side.normalized() if side.length() > 1e-3 else Vector3.RIGHT
		var n := h.rotated(side, deg_to_rad(25.0))
		_gizmo.draw_lighting_vectors(center + n * 0.85, n, l, v, 1.0)


func _su(uniform_name: String, value: Variant) -> void:
	for m in _model_mats:
		m.set_shader_parameter(uniform_name, value)
