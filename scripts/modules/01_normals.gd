extends "res://scripts/lab/lab_module.gd"
## 01 法线与法线贴图: vertex normals, smoothing, tangent space and normal maps.

const SceneKit := preload("res://scripts/lib/scene_kit.gd")
const ProcTextures := preload("res://scripts/lib/proc_textures.gd")
const MeshTools := preload("res://scripts/lib/mesh_tools.gd")
const VectorGizmos := preload("res://scripts/lab/vector_gizmos.gd")
const LIT_SHADER := preload("res://shaders/normal_map_lab.gdshader")
const DEBUG_SHADER := preload("res://shaders/normal_debug.gdshader")

const VIEW_MODES := [
	"Lit 正常光照", "World Normal 世界空间法线", "View Normal 视图空间法线",
	"Tangent 切线 T", "Binormal 副切线 B", "UV 坐标",
	"Normal Map Texel 法线贴图原始颜色", "Perturbed Normal 扰动后的最终法线", "N·L 漫反射项",
]
const SOURCE_LABELS := ["bricks 砖墙", "rivets 铆钉钢板", "waves 波纹 (蛋托)", "noise 噪声"]
const GIZMO_TARGETS := ["低模球", "立方体", "圆柱", "圆环", "法线贴图球", "法线贴图墙"]

# --- Proxy parameters (setters push into materials / meshes) ---
var view_mode := 0:
	set(v):
		view_mode = v
		_apply_view_mode()
var sphere_flat := false:
	set(v):
		sphere_flat = v
		if _lowpoly:
			_lowpoly.mesh = MeshTools.recompute_normals(_src.lowpoly, true) if v else _src.lowpoly
			_refresh_gizmo()
var hard_surface_averaged := false:
	set(v):
		hard_surface_averaged = v
		if _cube:
			_cube.mesh = MeshTools.recompute_normals(_src.cube, false) if v else _src.cube
			_cylinder.mesh = MeshTools.recompute_normals(_src.cylinder, false) if v else _src.cylinder
			_refresh_gizmo()
var tangent_mode := 0:
	set(v):
		tangent_mode = v
		if _nm_sphere:
			_nm_sphere.mesh = MeshTools.with_tangent_mode(_src.nm_sphere, v)
			_wall.mesh = MeshTools.with_tangent_mode(_src.wall, v)
			_refresh_gizmo()
var normal_source := 0:
	set(v):
		normal_source = v
		_apply_textures()
var normal_strength := 1.0:
	set(v):
		normal_strength = v
		_su("normal_strength", v)
var flip_green := false:
	set(v):
		flip_green = v
		_su("flip_green", v)
var wrong_color_space := false:
	set(v):
		wrong_color_space = v
		_su("wrong_color_space", v)
var bump_mode := false:
	set(v):
		bump_mode = v
		_su("bump_mode", v)
var bump_scale := 0.05:
	set(v):
		bump_scale = v
		_su("bump_scale", v)
var uv_tiling := 2.0:
	set(v):
		uv_tiling = v
		_su("uv_tiling", v)
		if _ref_mat:
			_ref_mat.uv1_scale = Vector3(v * 2.0, v, 1.0)
var light_azimuth := 40.0:
	set(v):
		light_azimuth = v
		_update_light()
var light_elevation := 35.0:
	set(v):
		light_elevation = v
		_update_light()
var orbit_light := false:
	set(v):
		orbit_light = v
		if _orbit:
			_orbit.visible = v
var show_vectors := true:
	set(v):
		show_vectors = v
		_refresh_gizmo()
var vector_target := 3:
	set(v):
		vector_target = v
		_refresh_gizmo()
var vector_length := 0.16:
	set(v):
		vector_length = v
		_refresh_gizmo()
var vectors_on_top := false:
	set(v):
		vectors_on_top = v
		if _gizmo:
			_gizmo.set_on_top(v)

var _sun: DirectionalLight3D
var _orbit: OmniLight3D
var _env: Environment
var _objects: Array[MeshInstance3D] = []
var _lit_mats: Array[ShaderMaterial] = []
var _dbg_mats: Array[ShaderMaterial] = []
var _ref_mat: StandardMaterial3D
var _src: Dictionary = {}
var _lowpoly: MeshInstance3D
var _cube: MeshInstance3D
var _cylinder: MeshInstance3D
var _torus: MeshInstance3D
var _nm_sphere: MeshInstance3D
var _ref_sphere: MeshInstance3D
var _wall: MeshInstance3D
var _gizmo: VectorGizmos
var _time := 0.0


func get_title() -> String:
	return "01 法线与法线贴图"


func get_overview() -> String:
	return """[b]法线 (Normal)[/b] 是垂直于表面的单位向量。几乎所有光照计算都从 [b]N·L[/b] 开始：法线与光线方向越一致，表面越亮。所以法线决定了表面在光照里“长什么样”。
• [b]顶点法线[/b]存在网格顶点上，在三角形内部插值。共享顶点 → 法线被平均 → 平滑着色；拆分顶点 → 各用面法线 → 硬边。
• [b]法线贴图[/b]在[b]切线空间[/b] (T 沿 U、B 沿 V、N 为几何法线) 里存储细节法线，颜色 = XYZ×0.5+0.5，所以“平”的地方是 (0.5, 0.5, 1) 的淡紫色。
• Godot 使用 [b]OpenGL 约定[/b] (绿色 = +Y 向上)；DirectX 约定的贴图需要翻转绿通道。

[b]试一试[/b]
1. view_mode 切到 World Normal 后转动相机：颜色不变 (世界空间)；切到 View Normal：颜色随相机变化。
2. 打开 sphere_flat 看低模球的面片感；打开 hard_surface_averaged，立方体侧面会出现错误的渐变 —— 硬边物体必须拆分顶点。
3. 把 light.elevation 降到 5°~10°：掠射光下法线贴图的凹凸最明显，这也是美术检查法线的常用方法。
4. 打开 flip_green：凸起看起来像凹陷，这是 OpenGL/DirectX 约定不一致的典型症状。
5. 选「缺失切线」预设，再切 Tangent 视图：没有切线，法线贴图就失去了参照系。"""


func get_camera_bookmarks() -> Dictionary:
	return {
		"总览": {"target": Vector3(0, 1.2, -0.8), "yaw": 0.0, "pitch": -12.0, "distance": 15.5},
		"低模/硬边": {"target": Vector3(-4.8, 1.0, 0), "yaw": 18.0, "pitch": -16.0, "distance": 5.5},
		"切线 (圆环)": {"target": Vector3(1.2, 0.8, 0), "yaw": 0.0, "pitch": -38.0, "distance": 3.6},
		"法线贴图球": {"target": Vector3(4.8, 1.0, 0), "yaw": -8.0, "pitch": -8.0, "distance": 4.8},
		"法线贴图墙": {"target": Vector3(0, 1.9, -3.2), "yaw": 0.0, "pitch": -2.0, "distance": 5.2},
	}


func get_presets() -> Dictionary:
	return {
		"① 世界空间法线": {"view.mode": 1, "_camera": "总览",
			"_note": "颜色 = 世界空间法线 ×0.5+0.5：朝上 (+Y) 偏绿，朝右 (+X) 偏红，朝向相机方向 (+Z) 偏蓝。转动相机颜色不变。地面是纯绿色 (0.5, 1, 0.5)。"},
		"② 视图空间法线": {"view.mode": 2, "_camera": "总览",
			"_note": "视图空间：以相机为参照。正对相机的面偏蓝，转动相机颜色会跟着变。屏幕空间效果 (SSAO/SSR) 用的就是这种法线，可对照顶部 Debug View → Normal Buffer。"},
		"③ 平直 vs 平滑着色": {"mesh.sphere_flat": true, "mesh.hard_surface_averaged": true, "_camera": "低模/硬边",
			"_note": "低模球用面法线 → 面片感 (flat shading)。立方体和圆柱被强行平均法线 → 侧面出现从亮到暗的错误渐变。结论：圆滑物体共享顶点，硬边物体拆分顶点 (或设置平滑组/硬边)。"},
		"④ 切线空间 TBN": {"view.mode": 3, "vectors.target": 3, "vectors.show": true, "_camera": "切线 (圆环)",
			"_note": "红线 = 切线 T (沿 U 方向)，绿线 = 副切线 B (沿 V 方向)，蓝线 = 法线 N。三者构成切线空间。法线贴图里的 (x, y, z) 就是在这个局部坐标系里表示的。"},
		"⑤ 法线贴图原始颜色": {"view.mode": 6, "_camera": "法线贴图墙",
			"_note": "这就是法线贴图本身的颜色：大面积淡紫 (0.5, 0.5, 1) = 不扰动；偏红 = 向 +U 倾斜，偏绿 = 向 +V (上) 倾斜。"},
		"⑥ 掠射光看凹凸": {"light.elevation": 7.0, "light.azimuth": 70.0, "nm.strength": 1.4, "_camera": "法线贴图墙",
			"_note": "光线几乎贴着表面照射时，N·L 对法线的微小偏转最敏感，凹凸感最强。正面直射光下法线贴图几乎“看不出来”。"},
		"⑦ 绿通道翻转 (DirectX)": {"nm.flip_green": true, "nm.source": 1, "light.elevation": 15.0, "light.azimuth": 0.0, "_camera": "法线贴图墙",
			"_note": "光从上方照来，铆钉 (凸起) 的上沿本应更亮、下沿更暗。翻转绿通道后上下颠倒：铆钉看起来像凹坑，钢板接缝像凸起。按 1 存 A、取消 flip_green 后按 2 存 B，用 Tab 对比最直观。导入 DirectX 法线贴图 (如部分 Substance/Unreal 资源) 时要在导入设置里翻转绿通道。"},
		"⑧ 错误色彩空间 (sRGB)": {"nm.wrong_color_space": true, "_camera": "法线贴图球",
			"_note": "法线贴图被当成颜色贴图做了 sRGB→线性转换：数值整体变小，所有法线向 -X/-Y 倾斜，表面整体偏暗、像被一个方向的光“压”着。法线贴图必须作为线性数据 (Normal Map) 导入。"},
		"⑨ 缺失切线": {"mesh.tangent_mode": 1, "view.mode": 7, "_camera": "法线贴图球",
			"_note": "网格没有切线时，引擎只能猜一个垂直方向，法线贴图被错误旋转。对比默认值的 Perturbed Normal 颜色。导入模型时确保生成/保留切线 (MikkTSpace)。"},
		"⑩ 切线手性翻转": {"mesh.tangent_mode": 2, "light.elevation": 20.0, "_camera": "法线贴图墙",
			"_note": "切线 w (手性) 取反 → 副切线反向，等价于绿通道翻转。镜像 UV 的模型如果手性处理不当，就会出现一半正确一半凹凸反转的接缝。"},
		"⑪ 高度图求导 (Bump)": {"nm.bump_mode": true, "nm.bump_scale": 0.06, "light.elevation": 15.0, "_camera": "法线贴图墙",
			"_note": "不用法线贴图，直接用高度图的屏幕空间导数 (dFdx/dFdy) 现场推出法线。好处是不需要切线；缺点是质量受屏幕分辨率影响，远处会闪烁。"},
		"⑫ 引擎法线缓冲": {"_debug": Viewport.DEBUG_DRAW_NORMAL_BUFFER, "_camera": "总览",
			"_note": "Debug View → Normal Buffer 显示的是引擎为屏幕空间效果写入的法线-粗糙度缓冲 (视图空间)。可以用来检查自定义 shader 写入的 NORMAL 是否正确。"},
	}


# --- Scene -----------------------------------------------------------------

func _build_scene() -> void:
	var we := SceneKit.make_environment(self, Environment.TONE_MAPPER_LINEAR)
	_env = we.environment
	_sun = SceneKit.dir_light(self, "Sun", light_azimuth, light_elevation, Color(1.0, 0.97, 0.92), 1.4)
	_orbit = SceneKit.omni_light(self, "OrbitLight", Vector3(0, 2, -2.2), Color(1.0, 0.75, 0.45), 3.0, 4.5)
	_orbit.visible = false

	# Floor: StandardMaterial3D checker when lit, debug shader otherwise.
	var floor_mi := SceneKit.plane(self, Vector2(40, 40), Vector3.ZERO, null, "Floor")
	_register(floor_mi, SceneKit.checker_mat(Color(0.42, 0.43, 0.45), Color(0.33, 0.34, 0.36), 20.0), false)

	var lowpoly_mesh := SphereMesh.new()
	lowpoly_mesh.radius = 0.9
	lowpoly_mesh.height = 1.8
	lowpoly_mesh.radial_segments = 14
	lowpoly_mesh.rings = 7
	var cube_mesh := BoxMesh.new()
	cube_mesh.size = Vector3(1.4, 1.4, 1.4)
	var cyl_mesh := CylinderMesh.new()
	cyl_mesh.top_radius = 0.7
	cyl_mesh.bottom_radius = 0.7
	cyl_mesh.height = 1.6
	cyl_mesh.radial_segments = 24
	var torus_mesh := TorusMesh.new()
	torus_mesh.inner_radius = 0.45
	torus_mesh.outer_radius = 0.9
	torus_mesh.rings = 32
	torus_mesh.ring_segments = 16
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.9
	sphere_mesh.height = 1.8
	sphere_mesh.radial_segments = 64
	sphere_mesh.rings = 32
	var wall_mesh := QuadMesh.new()
	wall_mesh.size = Vector2(9.0, 3.4)
	_src = {"lowpoly": lowpoly_mesh, "cube": cube_mesh, "cylinder": cyl_mesh, "nm_sphere": sphere_mesh, "wall": wall_mesh}

	_lowpoly = _add_object(lowpoly_mesh, Vector3(-6.0, 1.0, 0), Color(0.85, 0.55, 0.35), false, "低模球\nflat / smooth")
	_cube = _add_object(cube_mesh, Vector3(-3.6, 0.7, 0), Color(0.45, 0.65, 0.85), false, "硬边立方体")
	_cube.rotation_degrees.y = 30.0
	_cylinder = _add_object(cyl_mesh, Vector3(-1.2, 0.8, 0), Color(0.6, 0.8, 0.5), false, "圆柱")
	_torus = _add_object(torus_mesh, Vector3(1.2, 0.45, 0), Color(0.85, 0.75, 0.45), false, "圆环 (看 TBN)")
	_nm_sphere = _add_object(sphere_mesh, Vector3(3.6, 1.0, 0), Color(0.75, 0.75, 0.78), true, "法线贴图球\n自定义 TBN", Vector2(2.0, 1.0))
	_wall = _add_object(wall_mesh, Vector3(0, 1.9, -3.2), Color(0.72, 0.62, 0.55), true, "", Vector2(9.0 / 3.4, 1.0))
	SceneKit.label(self, "法线贴图墙 (normal_map_lab.gdshader)", Vector3(0, 3.95, -3.2), 36)

	_ref_mat = StandardMaterial3D.new()
	_ref_mat.resource_name = "RefMaterial"
	_ref_mat.albedo_color = Color(0.75, 0.75, 0.78)
	_ref_mat.roughness = 0.55
	_ref_mat.normal_enabled = true
	_ref_mat.normal_scale = 1.0
	_ref_sphere = SceneKit.mesh(self, sphere_mesh, Vector3(6.0, 1.0, 0), null, "RefSphere")
	_register(_ref_sphere, _ref_mat, true, Vector2(2.0, 1.0))
	SceneKit.label(self, "参考球\nStandardMaterial3D", Vector3(6.0, 2.45, 0), 36)

	_gizmo = VectorGizmos.new()
	_gizmo.name = "VectorGizmos"
	add_child(_gizmo)


func _add_object(m: Mesh, pos: Vector3, albedo: Color, use_nm: bool, title: String, uv_aspect := Vector2.ONE) -> MeshInstance3D:
	var mi := SceneKit.mesh(self, m, pos)
	var lit := ShaderMaterial.new()
	lit.shader = LIT_SHADER
	lit.set_shader_parameter("albedo", albedo)
	_register(mi, lit, use_nm, uv_aspect)
	if title != "":
		SceneKit.label(self, title, pos + Vector3(0, 1.45, 0), 36)
	return mi


## Every object gets a lit material and an unshaded debug twin; view_mode
## swaps between them while shared uniforms stay in sync.
func _register(mi: MeshInstance3D, lit: Material, use_nm: bool, uv_aspect := Vector2.ONE) -> void:
	var dbg := ShaderMaterial.new()
	dbg.shader = DEBUG_SHADER
	dbg.set_shader_parameter("use_normal_map", use_nm)
	dbg.set_shader_parameter("uv_aspect", uv_aspect)
	_dbg_mats.append(dbg)
	if lit is ShaderMaterial:
		(lit as ShaderMaterial).set_shader_parameter("use_normal_map", use_nm)
		(lit as ShaderMaterial).set_shader_parameter("uv_aspect", uv_aspect)
		_lit_mats.append(lit)
	mi.set_meta("lit", lit)
	mi.set_meta("dbg", dbg)
	mi.material_override = lit
	_objects.append(mi)


# --- Parameters ----------------------------------------------------------------

func _build_params() -> void:
	group("View 可视化")
	add_enum("view.mode", self, "view_mode", VIEW_MODES, "可视化模式：把着色过程中的某个向量直接画成颜色 (v×0.5+0.5)。Lit 为正常光照；其余模式是无光照的调试输出，地面和所有物体都会切换。")

	group("Mesh Normals 网格法线")
	add_bool("mesh.sphere_flat", self, "sphere_flat", "平直着色：用 SurfaceTool 的 smooth group = -1 重建低模球法线，每个三角形使用自己的面法线，呈现明显的面片感。")
	add_bool("mesh.hard_surface_averaged", self, "hard_surface_averaged", "错误平滑：把立方体/圆柱同一位置的顶点法线全部平均 (smooth group = 0)。硬边处的法线被“掰弯”，侧面出现错误渐变。真实项目中对应“模型没有设置硬边/平滑组”。")
	add_enum("mesh.tangent_mode", self, "tangent_mode", ["Generated 正常生成 (MikkTSpace)", "Missing 缺失切线", "Flipped W 手性翻转"], "切线状态：影响法线贴图球和法线贴图墙。缺失切线时引擎只能猜测切线方向；手性 (tangent.w) 翻转会让副切线反向，等效于绿通道翻转。")

	group("Normal Map 法线贴图")
	add_enum("nm.source", self, "normal_source", SOURCE_LABELS, "贴图来源：程序生成的高度图，用 Sobel 算子转换成切线空间法线贴图 (OpenGL 约定)。“波纹”最适合判断凹凸方向是否正确。")
	add_range("nm.strength", self, "normal_strength", 0.0, 3.0, 0.01, "法线强度：在几何法线与贴图法线之间插值 (mix)，等价于 StandardMaterial3D 的 normal_scale。0 = 不起作用，>1 = 夸张。过大时会出现不自然的金属感高光。")
	add_bool("nm.flip_green", self, "flip_green", "翻转绿通道：把贴图 Y 分量取反，模拟把 DirectX 约定的贴图用在 OpenGL 约定 (Godot) 的引擎里。症状：凸起变凹陷，光照上下颠倒。")
	add_bool("nm.wrong_color_space", self, "wrong_color_space", "错误色彩空间：把法线贴图当作 sRGB 颜色采样 (source_color)。采样值被 gamma 解码后整体变小，法线整体朝 -X/-Y 偏。正确做法：法线贴图按线性数据导入 (hint_normal)。")
	add_bool("nm.bump_mode", self, "bump_mode", "高度图求导：不用法线贴图，而是用高度图的屏幕空间导数 dFdx/dFdy 现场推导法线 (bump mapping)。不需要切线。")
	add_range("nm.bump_scale", self, "bump_scale", 0.0, 0.3, 0.001, "凹凸高度：bump 模式下高度值的缩放，越大凹凸越强。")
	add_range("nm.uv_tiling", self, "uv_tiling", 0.25, 8.0, 0.05, "UV 平铺：贴图重复次数。重复越多，单个凹凸越小，远处越容易出现摩尔纹/闪烁 (需要 mipmap 和各向异性过滤)。")

	group("Reference 引擎内置参考球")
	add_bool("ref.normal_enabled", _ref_mat, "normal_enabled", "启用法线贴图：StandardMaterial3D 自带的法线贴图开关。最右边的参考球与“法线贴图球”使用同一张贴图，结果应该一致。")
	add_range("ref.normal_scale", _ref_mat, "normal_scale", 0.0, 3.0, 0.01, "内置法线强度：StandardMaterial3D.normal_scale，与自定义 shader 的 normal_strength 作用相同。")
	add_range("ref.roughness", _ref_mat, "roughness", 0.0, 1.0, 0.01, "粗糙度：越低高光越集中，越容易看出法线细节。")

	group("Light 光源")
	add_range("light.azimuth", self, "light_azimuth", 0.0, 360.0, 1.0, "光源方位角：主光 (DirectionalLight3D) 绕 Y 轴的方向。0° = 从相机一侧照来，90° = 从右侧，180° = 从背后。")
	add_range("light.elevation", self, "light_elevation", 1.0, 90.0, 0.5, "光源仰角：90° 为正上方。仰角越低 (掠射光)，法线细节越明显。")
	add_range("sun.light_energy", _sun, "light_energy", 0.0, 4.0, 0.01, "光照强度：DirectionalLight3D.light_energy。")
	add_color("sun.light_color", _sun, "light_color", "光源颜色：DirectionalLight3D.light_color。")
	add_bool("sun.shadow_enabled", _sun, "shadow_enabled", "投射阴影：主光是否投射阴影。")
	add_bool("light.orbit", self, "orbit_light", "环绕点光：一盏暖色点光在法线贴图墙前绕圈移动。光源移动时最容易看出法线贴图的立体感。")
	add_range("env.ambient_light_sky_contribution", _env, "ambient_light_sky_contribution", 0.0, 1.0, 0.01, "环境光强度 (天空贡献)：环境光里来自天空的比例。环境光颜色为黑色时，它就是天空环境光的强度，0 = 暗部全黑，只剩直接光。[b]坑[/b]：来源为 Sky 时 ambient_light_energy 只缩放 ambient_light_color 那一部分，sky_contribution = 1 时调它完全没有效果。")

	group("Vectors 向量可视化")
	add_bool("vectors.show", self, "show_vectors", "显示 TBN 线框：在所选物体的顶点上画出法线 (蓝)、切线 (红)、副切线 (绿)。注意这是顶点数据，看不到法线贴图的扰动。")
	add_enum("vectors.target", self, "vector_target", GIZMO_TARGETS, "可视化对象：要画 TBN 向量的物体。")
	add_range("vectors.length", self, "vector_length", 0.02, 0.6, 0.01, "线长：向量线段的长度 (米)。")
	add_bool("vectors.on_top", self, "vectors_on_top", "总在最前：关闭深度测试，被遮挡的向量也显示出来。")


func _after_init() -> void:
	_apply_textures()
	_refresh_gizmo()


func _process(delta: float) -> void:
	if orbit_light and _orbit:
		_time += delta
		_orbit.position = Vector3(sin(_time * 0.8) * 3.2, 1.9 + cos(_time * 1.3) * 1.1, -2.4)


# --- Helpers ---------------------------------------------------------------------

func _su(uniform_name: String, value: Variant) -> void:
	for m in _lit_mats:
		m.set_shader_parameter(uniform_name, value)
	for m in _dbg_mats:
		m.set_shader_parameter(uniform_name, value)


func _apply_view_mode() -> void:
	for m in _dbg_mats:
		m.set_shader_parameter("debug_mode", view_mode)
	for mi in _objects:
		mi.material_override = mi.get_meta("lit") if view_mode == 0 else mi.get_meta("dbg")


func _apply_textures() -> void:
	if _ref_mat == null:
		return
	var kind: String = ProcTextures.KINDS[normal_source]
	var normal_tex := ProcTextures.normal_texture(kind)
	_su("normal_tex", normal_tex)
	_su("normal_tex_srgb", normal_tex)
	_su("height_tex", ProcTextures.height_texture(kind))
	_ref_mat.normal_texture = normal_tex


func _update_light() -> void:
	if _sun == null:
		return
	SceneKit.aim_light(_sun, light_azimuth, light_elevation)
	for m in _dbg_mats:
		m.set_shader_parameter("light_dir_world", SceneKit.dir_from_angles(light_azimuth, light_elevation))


func _refresh_gizmo() -> void:
	if _gizmo == null:
		return
	if not show_vectors:
		_gizmo.clear()
		return
	var targets := [_lowpoly, _cube, _cylinder, _torus, _nm_sphere, _wall]
	_gizmo.draw_mesh_frame(targets[clampi(vector_target, 0, targets.size() - 1)], vector_length)
