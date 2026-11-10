extends "res://scripts/lab/lab_module.gd"
## 04 GI、环境与后处理: indirect light (SDFGI / VoxelGI / probes / SSIL), sky
## and ambient, tonemapping, SSAO / SSR, glow, fog, volumetric fog, colour
## grading, exposure / DOF and anti-aliasing — all on a Cornell-box style room.

const SceneKit := preload("res://scripts/lib/scene_kit.gd")
const ProcTextures := preload("res://scripts/lib/proc_textures.gd")

const TONEMAPS := [["Linear", Environment.TONE_MAPPER_LINEAR], ["Reinhard", Environment.TONE_MAPPER_REINHARDT], ["Filmic", Environment.TONE_MAPPER_FILMIC], ["ACES", Environment.TONE_MAPPER_ACES], ["AgX", Environment.TONE_MAPPER_AGX]]
const LUT_LABELS := ["None 无", "Warm 暖调 (1D)", "Cool 冷调 (1D)", "Contrast S 曲线 (1D)", "Teal & Orange 青橙 (3D LUT)"]

var gi_mode := 0:
	set(v):
		gi_mode = v
		_apply_gi_mode()
var voxel_subdiv := VoxelGI.SUBDIV_128:
	set(v):
		voxel_subdiv = v
		if _voxel:
			_voxel.subdiv = v
			_voxel_dirty = true
			_apply_gi_mode()
var voxel_energy := 1.0:
	set(v):
		voxel_energy = v
		_apply_voxel_data()
var voxel_propagation := 0.5:
	set(v):
		voxel_propagation = v
		_apply_voxel_data()
var voxel_use_two_bounces := true:
	set(v):
		voxel_use_two_bounces = v
		_apply_voxel_data()
var voxel_interior := false:
	set(v):
		voxel_interior = v
		_apply_voxel_data()
var sun_azimuth := 180.0:
	set(v):
		sun_azimuth = v
		if _sun:
			SceneKit.aim_light(_sun, sun_azimuth, sun_elevation)
var sun_elevation := 34.0:
	set(v):
		sun_elevation = v
		if _sun:
			SceneKit.aim_light(_sun, sun_azimuth, sun_elevation)
var glow_small := 0.0:
	set(v):
		glow_small = v
		_apply_glow_levels()
var glow_medium := 1.0:
	set(v):
		glow_medium = v
		_apply_glow_levels()
var glow_large := 1.0:
	set(v):
		glow_large = v
		_apply_glow_levels()
var color_grading := 0:
	set(v):
		color_grading = v
		if _env:
			_env.adjustment_color_correction = ProcTextures.lut(ProcTextures.LUTS[v])

var _env: Environment
var _sky: ProceduralSkyMaterial
var _cam_attr: CameraAttributesPractical
var _sun: DirectionalLight3D
var _voxel: VoxelGI
var _voxel_dirty := true
var _probe: ReflectionProbe
var _fog_volume: FogVolume
var _fog_mat: FogMaterial
var _floor_mat: StandardMaterial3D
var _emit_mat: StandardMaterial3D


func get_title() -> String:
	return "04 GI、环境与后处理"


func get_overview() -> String:
	return """[b]直接光[/b]只照亮光源“看得见”的地方。真实世界里光会在表面之间反弹：红墙把地面染红、窗口进来的阳光照亮整个房间 —— 这部分叫[b]间接光 / 全局光照 (GI)[/b]。
• [b]SDFGI[/b]：实时，用有符号距离场描述场景，适合大型开放场景，无需烘焙。
• [b]VoxelGI[/b]：把一个盒子范围体素化后烘焙 (可运行时烘焙)，适合室内中小场景，支持动态物体接收。
• [b]LightmapGI[/b]：编辑器离线烘焙到贴图，质量最高、运行最便宜，但只能在编辑器里烘焙 (本 demo 不演示)。
• [b]SSIL / SSAO[/b]：屏幕空间近似，只知道屏幕上看得到的东西；常作为 GI 的细节补充。
• [b]ReflectionProbe / SSR[/b]：间接光的“镜面”部分 —— 反射。

[b]后处理链[/b] (大致顺序)：HDR 场景 → SSR/SSAO/SSIL → 体积雾/雾 → 辉光 (Glow) → 曝光 → [b]色调映射[/b] (HDR→屏幕) → 调色 (亮度/对比度/饱和度/LUT) → 抗锯齿。

[b]试一试[/b]
1. 依次点「只有直接光」「SDFGI」「VoxelGI」：注意天花板、红绿墙在地面上的染色 (color bleeding)。
2. 选 SDFGI 后切 Debug View → SDFGI / GI Buffer，看 GI 自己贡献了什么。
3. 「Linear 过曝」和「AgX」两个预设之间来回切换：同一个 HDR 画面，色调映射决定了高光怎么“收”。
4. 开体积雾，把太阳的 light_volumetric_fog_energy 调大，窗口会出现光柱 (god rays)。
5. 留意右上角的 GPU 时间：每开一个效果，它增加多少？"""


func get_camera_bookmarks() -> Dictionary:
	return {
		"房间正面": {"target": Vector3(0, 2.3, -4.0), "yaw": 0.0, "pitch": -4.0, "distance": 10.5},
		"室内低角度": {"target": Vector3(0.3, 0.9, -4.2), "yaw": 22.0, "pitch": -7.0, "distance": 5.0},
		"窗户光柱": {"target": Vector3(0, 2.0, -5.5), "yaw": 40.0, "pitch": -8.0, "distance": 6.5},
		"室外远景": {"target": Vector3(12, 4, -45), "yaw": 22.0, "pitch": -5.0, "distance": 58.0},
		"深处暗角": {"target": Vector3(-3.4, 4.0, -7.2), "yaw": 46.5, "pitch": 24.0, "distance": 5.9},
		"雾体积": {"target": Vector3(2.2, 0.6, -6.0), "yaw": -60.0, "pitch": -14.0, "distance": 4.6},
	}


func get_presets() -> Dictionary:
	return {
		"① 只有直接光": {"env.ambient_light_source": Environment.AMBIENT_SOURCE_DISABLED, "env.reflected_light_source": Environment.REFLECTION_SOURCE_DISABLED, "_camera": "房间正面",
			"_note": "关闭环境光与反射，也没有 GI：只有阳光直接照到的地方是亮的，其余全黑。这就是“只有直接光”的世界 —— 实时渲染里所有“暗部有细节”都来自间接光的近似。"},
		"② SDFGI": {"gi.mode": 1, "_camera": "房间正面",
			"_note": "SDFGI 实时计算多次反弹：窗口进来的阳光照亮了整个房间，红/绿墙把颜色反弹到地面和白盒子上 (color bleeding)。调 sdfgi_energy、sun.light_indirect_energy 观察 GI 强度。"},
		"③ SDFGI 体素视图": {"gi.mode": 1, "_debug": Viewport.DEBUG_DRAW_SDFGI, "_camera": "房间正面",
			"_note": "Debug View = SDFGI：显示 SDFGI 内部的体素化场景。薄于 min_cell_size 的墙会漏光，这是 SDFGI 最常见的问题 —— 墙要做厚，或减小 min_cell_size。"},
		"④ VoxelGI": {"gi.mode": 2, "_camera": "房间正面",
			"_note": "VoxelGI 在运行时把房间体素化并烘焙 (切换时会卡一下)。相比 SDFGI 范围更小、更精确，室内更稳定。subdiv 越高越精细、越慢。改 subdiv 后会自动重新烘焙。"},
		"⑤ SSAO 环境光遮蔽": {"ssao.ssao_enabled": true, "ssao.ssao_intensity": 3.0, "ssao.ssao_radius": 1.2, "_debug": Viewport.DEBUG_DRAW_SSAO, "_camera": "室内低角度",
			"_note": "Debug View = SSAO：墙角、物体与地面的接触处变暗。SSAO 只压暗环境光 (ambient)，不影响直接光 —— 除非调大 ssao_light_affect。切回 Normal 视图对比。"},
		"⑥ SSIL 屏幕空间间接光": {"ssil.ssil_enabled": true, "ssil.ssil_intensity": 2.0, "ssil.ssil_radius": 3.0, "env.ambient_light_sky_contribution": 0.3, "_camera": "室内低角度",
			"_note": "SSIL 用屏幕上已渲染的颜色做近距离的一次反弹：红绿墙附近的地面被轻微染色。它便宜，但屏幕外的东西不会反弹光。"},
		"⑦ SSR 镜面地板": {"ssr.ssr_enabled": true, "floor.roughness": 0.03, "floor.metallic": 0.5, "_camera": "室内低角度",
			"_note": "屏幕空间反射：沿反射方向在深度缓冲里步进求交。只能反射屏幕上可见的东西 —— 转动相机让物体出屏，反射也随之消失。ssr_max_steps 决定质量与开销。"},
		"⑧ 反射探针 ReflectionProbe": {"probe.visible": true, "floor.roughness": 0.08, "floor.metallic": 0.5, "_camera": "室内低角度",
			"_note": "反射探针在一个点上拍一张立方体贴图，box_projection 把它“投影”到房间盒子上，反射位置更准确。与 SSR 不同，它能反射屏幕外的东西，但不随物体移动实时更新 (update_mode=Once)。"},
		"⑨ Linear 过曝": {"gi.mode": 1, "env.tonemap_mode": Environment.TONE_MAPPER_LINEAR, "env.tonemap_exposure": 2.5, "sun.light_energy": 4.0, "emit.emission_energy_multiplier": 14.0, "_camera": "窗户光柱",
			"_note": "Linear 色调映射：大于 1 的亮度直接截断，窗口和自发光球变成一片死白，颜色也被“洗掉”。与下一个预设 AgX 来回切换对比。"},
		"⑩ AgX 色调映射": {"gi.mode": 1, "env.tonemap_mode": Environment.TONE_MAPPER_AGX, "env.tonemap_exposure": 2.5, "sun.light_energy": 4.0, "emit.emission_energy_multiplier": 14.0, "_camera": "窗户光柱",
			"_note": "同样的曝光和自发光强度，AgX 把高光平滑压缩，过亮的颜色向白色自然过渡 (而不是截断成纯色块)。Filmic/ACES 是另外两种常见曲线：ACES 对比更强、颜色更饱和。"},
		"⑪ 辉光 Glow": {"glow.glow_enabled": true, "glow.glow_intensity": 1.2, "glow.glow_bloom": 0.05, "emit.emission_energy_multiplier": 10.0, "sun.light_energy": 3.0, "_camera": "窗户光柱",
			"_note": "辉光只作用于超过 glow_hdr_threshold 的像素 (自发光球、窗口)：把这些像素模糊后叠加回去。glow_bloom > 0 时所有像素都会参与，画面整体发雾。"},
		"⑫ 体积雾光柱": {"gi.mode": 1, "vfog.volumetric_fog_enabled": true, "vfog.volumetric_fog_density": 0.035, "vfog.volumetric_fog_anisotropy": 0.6, "sun.light_volumetric_fog_energy": 4.0, "_camera": "窗户光柱",
			"_note": "体积雾在视锥内的 3D 网格 (froxel) 中计算散射。阳光穿过窗口形成光柱 (god rays)。anisotropy > 0 时迎着光看最亮；volumetric_fog_gi_inject 让 GI 也照亮雾。"},
		"⑬ 局部雾 FogVolume": {"vfog.volumetric_fog_enabled": true, "vfog.volumetric_fog_density": 0.0, "fogvol.visible": true, "_camera": "雾体积",
			"_note": "全局体积雾密度为 0，只有房间右后角 (自发光球周围) 一个 FogVolume 盒子里有雾 (像地面蒸汽/烟)。FogVolume 依赖体积雾开关。height_falloff 让雾向上变稀，edge_fade 让边缘柔和。"},
		"⑭ 距离雾 + 高度雾": {"fog.fog_enabled": true, "fog.fog_density": 0.012, "fog.fog_aerial_perspective": 0.5, "fog.fog_height": 2.0, "fog.fog_height_density": 0.4, "_camera": "室外远景",
			"_note": "普通雾 (非体积) 很便宜：按距离给像素混入雾色，模拟大气透视。fog_height + fog_height_density 让低处更浓 (山谷晨雾)。aerial_perspective 让雾色取自天空，远处物体“融”进天空。"},
		"⑮ 自动曝光": {"cam.auto_exposure_enabled": true, "gi.mode": 1, "_camera": "深处暗角", "_debug": Viewport.DEBUG_DRAW_DISABLED,
			"_note": "自动曝光像人眼/相机一样适应亮度：仰视天花板的暗角时，画面会在一两秒内慢慢变亮；转向窗口或门口又会变暗。auto_exposure_speed 控制适应速度，scale 控制目标亮度。Debug View → Scene Luminance 显示测光结果。"},
		"⑯ 景深 DOF": {"cam.dof_blur_far_enabled": true, "cam.dof_blur_far_distance": 6.0, "cam.dof_blur_near_enabled": true, "cam.dof_blur_near_distance": 2.0, "cam.dof_blur_amount": 0.15, "_camera": "室内低角度",
			"_note": "景深把焦平面以外的物体模糊。far_distance 之后变模糊，near_distance 之前变模糊，transition 控制过渡带宽度。"},
		"⑰ 调色 Teal & Orange": {"gi.mode": 1, "adj.adjustment_enabled": true, "grading.lut": 4, "adj.adjustment_saturation": 1.15, "adj.adjustment_contrast": 1.08, "_camera": "房间正面",
			"_note": "3D LUT 调色：暗部偏青、亮部偏橙 (电影常用的互补色调)。LUT 在色调映射之后执行，所以作用于最终的 0~1 颜色。1D 渐变 LUT 只能按通道改曲线，3D LUT 可以做任意颜色映射。"},
		"⑱ 全开综合": {"gi.mode": 1, "ssao.ssao_enabled": true, "ssil.ssil_enabled": true, "ssr.ssr_enabled": true, "floor.roughness": 0.15, "glow.glow_enabled": true, "glow.glow_intensity": 0.7, "vfog.volumetric_fog_enabled": true, "vfog.volumetric_fog_density": 0.012, "sun.light_volumetric_fog_energy": 2.0, "env.tonemap_mode": Environment.TONE_MAPPER_AGX, "adj.adjustment_enabled": true, "adj.adjustment_saturation": 1.08, "_camera": "房间正面",
			"_note": "把常用效果都打开：SDFGI + SSAO + SSIL + SSR + 辉光 + 体积雾 + AgX。观察右上角 GPU 时间，再逐个关闭，找出最贵的是哪一个。"},
	}


func _build_scene() -> void:
	var we := SceneKit.make_environment(self, Environment.TONE_MAPPER_FILMIC)
	_env = we.environment
	_sky = _env.sky.sky_material as ProceduralSkyMaterial
	_cam_attr = CameraAttributesPractical.new()
	_cam_attr.resource_name = "CameraAttributes"
	we.camera_attributes = _cam_attr

	SceneKit.plane(self, Vector2(400, 400), Vector3(0, -0.01, 0), SceneKit.mat(Color(0.36, 0.38, 0.33), 0.95), "Ground")
	var white := SceneKit.mat(Color(0.82, 0.8, 0.77), 0.9)
	var red := SceneKit.mat(Color(0.75, 0.1, 0.08), 0.9)
	var green := SceneKit.mat(Color(0.12, 0.58, 0.14), 0.9)
	# Cornell box: 8 x 5 x 8 m, open towards +Z, thick walls (SDFGI leaks through thin ones).
	SceneKit.box(self, Vector3(0.4, 5.4, 8.4), Vector3(-4.2, 2.7, -4.0), red, "WallLeft")
	SceneKit.box(self, Vector3(0.4, 5.4, 8.4), Vector3(4.2, 2.7, -4.0), green, "WallRight")
	SceneKit.box(self, Vector3(8.8, 0.4, 8.4), Vector3(0, 5.2, -4.0), white, "Ceiling")
	# Back wall with a window (x -1.6..1.6, y 1.6..3.6) and a cross-shaped frame.
	SceneKit.box(self, Vector3(8.8, 1.6, 0.4), Vector3(0, 0.8, -8.2), white, "BackBottom")
	SceneKit.box(self, Vector3(8.8, 1.8, 0.4), Vector3(0, 4.5, -8.2), white, "BackTop")
	SceneKit.box(self, Vector3(2.8, 2.0, 0.4), Vector3(-3.0, 2.6, -8.2), white, "BackLeft")
	SceneKit.box(self, Vector3(2.8, 2.0, 0.4), Vector3(3.0, 2.6, -8.2), white, "BackRight")
	SceneKit.box(self, Vector3(0.1, 2.0, 0.3), Vector3(0, 2.6, -8.2), white, "FrameV")
	SceneKit.box(self, Vector3(3.2, 0.1, 0.3), Vector3(0, 2.6, -8.2), white, "FrameH")
	_floor_mat = SceneKit.mat(Color(0.62, 0.6, 0.57), 0.6)
	_floor_mat.resource_name = "FloorMaterial"
	SceneKit.box(self, Vector3(8.0, 0.05, 8.0), Vector3(0, 0.025, -4.0), _floor_mat, "Floor")

	var tall := SceneKit.box(self, Vector3(1.3, 2.6, 1.3), Vector3(-1.6, 1.3, -5.4), white, "TallBox")
	tall.rotation_degrees.y = 20.0
	var short := SceneKit.box(self, Vector3(1.3, 1.3, 1.3), Vector3(1.7, 0.65, -3.4), white, "ShortBox")
	short.rotation_degrees.y = -16.0
	SceneKit.sphere(self, 0.6, Vector3(0.1, 0.6, -2.0), SceneKit.mat(Color(0.95, 0.95, 0.97), 0.06, 1.0), 64, "ChromeSphere")
	_emit_mat = SceneKit.emissive(Color(1.0, 0.55, 0.2), 6.0)
	_emit_mat.resource_name = "EmissiveMaterial"
	SceneKit.sphere(self, 0.38, Vector3(2.7, 0.38, -6.6), _emit_mat, 48, "EmissiveSphere")

	# Outdoor objects for fog / aerial perspective.
	var stone := SceneKit.mat(Color(0.6, 0.58, 0.55), 0.85)
	for i in 10:
		SceneKit.box(self, Vector3(3, 12, 3), Vector3(20 + (i % 2) * 8, 6, -12 - i * 18), stone)
	for i in 4:
		SceneKit.sphere(self, 0.7, Vector3(-3 + i * 2.2, 0.7, 4.5 + (i % 2)), SceneKit.mat(Color(0.7, 0.72, 0.75), 0.5), 32)

	_sun = SceneKit.dir_light(self, "Sun", sun_azimuth, sun_elevation, Color(1.0, 0.95, 0.86), 1.6)
	_sun.directional_shadow_max_distance = 120.0

	_voxel = VoxelGI.new()
	_voxel.name = "VoxelGI"
	_voxel.size = Vector3(9.4, 6.0, 9.2)
	_voxel.position = Vector3(0, 2.7, -4.0)
	_voxel.subdiv = voxel_subdiv
	_voxel.visible = false
	add_child(_voxel)

	_probe = ReflectionProbe.new()
	_probe.name = "ReflectionProbe"
	_probe.size = Vector3(8.0, 5.0, 8.0)
	_probe.position = Vector3(0, 2.5, -4.0)
	_probe.box_projection = true
	_probe.interior = true
	_probe.visible = false
	add_child(_probe)

	_fog_mat = FogMaterial.new()
	_fog_mat.resource_name = "FogMaterial"
	_fog_mat.density = 1.5
	_fog_mat.albedo = Color(0.85, 0.88, 0.95)
	_fog_mat.height_falloff = 1.2
	_fog_mat.edge_fade = 0.4
	_fog_volume = FogVolume.new()
	_fog_volume.name = "FogVolume"
	_fog_volume.size = Vector3(3.6, 1.6, 3.2)
	_fog_volume.position = Vector3(2.2, 0.8, -6.0)
	_fog_volume.material = _fog_mat
	_fog_volume.visible = false
	add_child(_fog_volume)


func _build_params() -> void:
	group("GI 全局光照")
	add_enum("gi.mode", self, "gi_mode", ["None 无", "SDFGI (实时)", "VoxelGI (运行时烘焙)"], "GI 方案：间接光从哪里来。None 时暗部只有环境光；SDFGI 适合大场景；VoxelGI 适合室内。")
	add_range("sun.light_indirect_energy", _sun, "light_indirect_energy", 0.0, 4.0, 0.01, "间接光倍数：这盏灯参与 GI 反弹的强度 (不影响直接光)。调大让房间被反弹光照得更亮。")
	add_range("sdfgi.sdfgi_energy", _env, "sdfgi_energy", 0.0, 4.0, 0.01, "SDFGI 强度：整体间接光倍数。")
	add_range("sdfgi.sdfgi_bounce_feedback", _env, "sdfgi_bounce_feedback", 0.0, 1.99, 0.01, "反弹反馈：多次反弹的能量保留比例。越大暗部越亮；接近 2 可能不稳定 (越来越亮)。")
	add_range("sdfgi.sdfgi_cascades", _env, "sdfgi_cascades", 1.0, 8.0, 1.0, "级联数：像阴影级联一样，近处精细、远处粗糙。越多覆盖越远、越贵。")
	add_range("sdfgi.sdfgi_min_cell_size", _env, "sdfgi_min_cell_size", 0.02, 2.0, 0.01, "最小体素尺寸：第一级级联的体素大小 (米)。越小细节越好、覆盖越近；比墙厚还大时容易漏光。", {"exp": true})
	add_bool("sdfgi.sdfgi_use_occlusion", _env, "sdfgi_use_occlusion", "遮挡：额外检测可见性以减少漏光 (light leaking)，更贵。")
	add_bool("sdfgi.sdfgi_read_sky_light", _env, "sdfgi_read_sky_light", "读取天空光：天空作为光源参与 GI。室内场景关闭可避免天光从缝隙漏进来。")
	add_range("sdfgi.sdfgi_normal_bias", _env, "sdfgi_normal_bias", 0.0, 4.0, 0.01, "法线偏移：采样 GI 时沿法线偏移，减少自遮挡造成的斑点。")
	add_enum("voxel.subdiv", self, "voxel_subdiv", [["64", VoxelGI.SUBDIV_64], ["128", VoxelGI.SUBDIV_128], ["256", VoxelGI.SUBDIV_256], ["512", VoxelGI.SUBDIV_512]], "VoxelGI 分辨率：体素网格最长边的格数。越高越精细，烘焙越慢、显存越大。修改后自动重新烘焙。")
	add_range("voxel.energy", self, "voxel_energy", 0.0, 4.0, 0.01, "VoxelGI 强度：VoxelGIData.energy。")
	add_range("voxel.propagation", self, "voxel_propagation", 0.0, 1.0, 0.01, "传播：光在体素中向远处传播的程度。越大间接光越“铺开”。")
	add_bool("voxel.use_two_bounces", self, "voxel_use_two_bounces", "两次反弹：开启后多算一次反弹，暗部更亮更真实。")
	add_bool("voxel.interior", self, "voxel_interior", "室内模式：忽略天空光，适合封闭室内。")
	add_action("voxel.rebake", "重新烘焙 VoxelGI", _rebake, "重新烘焙：场景改动 (移动物体、改材质) 后需要重新烘焙 VoxelGI。")
	add_bool("probe.visible", _probe, "visible", "反射探针：在房间中心拍一张立方体贴图作为局部反射 (和环境光) 来源。")
	add_range("probe.intensity", _probe, "intensity", 0.0, 2.0, 0.01, "探针强度：反射亮度倍数。")
	add_bool("probe.box_projection", _probe, "box_projection", "盒体投影：把立方体贴图投影到探针盒子的墙面上，让室内反射的位置与视差正确。关掉后反射像“贴在无限远处”。")
	add_bool("probe.interior", _probe, "interior", "室内：探针不使用天空作为环境光/反射的补充。")
	add_enum("probe.update_mode", _probe, "update_mode", [["Once 一次", ReflectionProbe.UPDATE_ONCE], ["Always 每帧", ReflectionProbe.UPDATE_ALWAYS]], "更新模式：Once 只拍一次 (便宜)；Always 每帧重拍 (能反射移动物体，非常贵)。")
	add_enum("probe.ambient_mode", _probe, "ambient_mode", [["Disabled", ReflectionProbe.AMBIENT_DISABLED], ["Environment", ReflectionProbe.AMBIENT_ENVIRONMENT], ["Color", ReflectionProbe.AMBIENT_COLOR]], "探针环境光：探针范围内的环境光来源。Environment 取探针拍到的画面，能让室内环境光更合理。")

	group("Sky & Ambient 天空与环境光")
	add_enum("env.background_mode", _env, "background_mode", [["Clear Color", Environment.BG_CLEAR_COLOR], ["Custom Color", Environment.BG_COLOR], ["Sky 天空", Environment.BG_SKY]], "背景模式：画面背景显示什么。注意：环境光/反射来源选 Background 时也取自这里。")
	add_color("env.background_color", _env, "background_color", "背景颜色：background_mode = Custom Color 时使用。")
	add_range("env.background_energy_multiplier", _env, "background_energy_multiplier", 0.0, 4.0, 0.01, "背景亮度：背景/天空的亮度倍数，会影响取自天空的环境光。")
	add_color("sky.sky_top_color", _sky, "sky_top_color", "天顶颜色：ProceduralSkyMaterial 天空顶部颜色。")
	add_color("sky.sky_horizon_color", _sky, "sky_horizon_color", "地平线颜色：天空靠近地平线的颜色。")
	add_color("sky.ground_horizon_color", _sky, "ground_horizon_color", "地面地平线颜色")
	add_color("sky.ground_bottom_color", _sky, "ground_bottom_color", "地面底部颜色：天空球下半部分，会贡献“来自下方”的环境光。")
	add_range("sky.sky_energy_multiplier", _sky, "sky_energy_multiplier", 0.0, 4.0, 0.01, "天空亮度：天空本身的亮度。")
	add_range("sky.sun_angle_max", _sky, "sun_angle_max", 0.0, 90.0, 0.1, "太阳光晕大小：天空中太阳光晕的角度范围。")
	add_enum("env.ambient_light_source", _env, "ambient_light_source", [["Background", Environment.AMBIENT_SOURCE_BG], ["Disabled", Environment.AMBIENT_SOURCE_DISABLED], ["Color", Environment.AMBIENT_SOURCE_COLOR], ["Sky", Environment.AMBIENT_SOURCE_SKY]], "环境光来源：Sky 从天空球卷积得到 (各方向不同)；Color 是单一常量颜色 (显得平)。")
	add_color("env.ambient_light_color", _env, "ambient_light_color", "环境光颜色：来源为 Color 时使用；来源为 Sky 时与天空按 sky_contribution 混合。")
	add_range("env.ambient_light_energy", _env, "ambient_light_energy", 0.0, 4.0, 0.01, "环境光颜色强度：只缩放 ambient_light_color 那一部分。[b]坑[/b]：来源为 Sky 且 sky_contribution = 1 时，它完全不起作用 —— 要调天空环境光，请用 sky_contribution、天空亮度或 background_energy_multiplier。")
	add_range("env.ambient_light_sky_contribution", _env, "ambient_light_sky_contribution", 0.0, 1.0, 0.01, "天空贡献比例：环境光 = mix(ambient_light_color × energy, 天空, 本值)。1 = 全部来自天空，0 = 全部来自 ambient_light_color。颜色为黑色时，它就是天空环境光的强度。")
	add_enum("env.reflected_light_source", _env, "reflected_light_source", [["Background", Environment.REFLECTION_SOURCE_BG], ["Disabled", Environment.REFLECTION_SOURCE_DISABLED], ["Sky", Environment.REFLECTION_SOURCE_SKY]], "反射来源：镜面反射的默认来源。关闭后光滑物体在没有探针/SSR 时不反射任何东西。")

	group("Tonemap 色调映射与曝光")
	add_enum("env.tonemap_mode", _env, "tonemap_mode", TONEMAPS, "色调映射：把 HDR (可以远大于 1) 映射到屏幕 0~1。Linear 截断；Reinhard 简单压缩；Filmic/ACES 电影曲线；AgX 高光过渡最自然。")
	add_range("env.tonemap_exposure", _env, "tonemap_exposure", 0.05, 8.0, 0.01, "曝光：色调映射前的亮度乘数。", {"exp": true})
	add_range("env.tonemap_white", _env, "tonemap_white", 0.5, 16.0, 0.01, "白点：多亮的 HDR 值被映射成纯白 (Reinhard/Filmic/ACES)。越大高光越不容易死白。")
	add_range("env.tonemap_agx_white", _env, "tonemap_agx_white", 1.0, 64.0, 0.1, "AgX 白点：AgX 专用的白点。", {"exp": true})
	add_range("env.tonemap_agx_contrast", _env, "tonemap_agx_contrast", 0.5, 2.5, 0.01, "AgX 对比度：AgX 曲线中间调的对比。")

	group("SSAO 环境光遮蔽")
	add_bool("ssao.ssao_enabled", _env, "ssao_enabled", "启用 SSAO：用深度和法线估计每个像素被周围几何遮挡的程度，压暗角落和缝隙的环境光。")
	add_range("ssao.ssao_radius", _env, "ssao_radius", 0.01, 8.0, 0.01, "半径：检测遮挡的范围 (米)。大半径适合大尺度明暗，小半径适合细节。")
	add_range("ssao.ssao_intensity", _env, "ssao_intensity", 0.0, 16.0, 0.01, "强度")
	add_range("ssao.ssao_power", _env, "ssao_power", 0.1, 4.0, 0.01, "指数：对 AO 结果做幂运算，越大对比越强。")
	add_range("ssao.ssao_detail", _env, "ssao_detail", 0.0, 5.0, 0.01, "细节：额外的小半径 AO，增强细小缝隙。")
	add_range("ssao.ssao_horizon", _env, "ssao_horizon", 0.0, 1.0, 0.01, "地平线：限制采样角度，减少平面上的错误变暗。")
	add_range("ssao.ssao_sharpness", _env, "ssao_sharpness", 0.0, 1.0, 0.01, "锐度：模糊时保留边缘的程度。")
	add_range("ssao.ssao_light_affect", _env, "ssao_light_affect", 0.0, 1.0, 0.01, "影响直接光：0 = 只压暗环境光 (物理上正确)；>0 时直接光也被压暗，风格化但不真实。")
	add_range("ssao.ssao_ao_channel_affect", _env, "ssao_ao_channel_affect", 0.0, 1.0, 0.01, "与材质 AO 贴图混合：SSAO 与材质自带 AO 贴图的组合方式。")

	group("SSIL 屏幕空间间接光")
	add_bool("ssil.ssil_enabled", _env, "ssil_enabled", "启用 SSIL：用屏幕上已有的颜色估算近距离的一次反弹光。")
	add_range("ssil.ssil_radius", _env, "ssil_radius", 0.01, 16.0, 0.01, "半径")
	add_range("ssil.ssil_intensity", _env, "ssil_intensity", 0.0, 16.0, 0.01, "强度")
	add_range("ssil.ssil_sharpness", _env, "ssil_sharpness", 0.0, 1.0, 0.01, "锐度")
	add_range("ssil.ssil_normal_rejection", _env, "ssil_normal_rejection", 0.0, 1.0, 0.01, "法线剔除：拒绝来自背向表面的光，减少漏光。")

	group("SSR 屏幕空间反射")
	add_bool("ssr.ssr_enabled", _env, "ssr_enabled", "启用 SSR：在深度缓冲里沿反射方向步进，找到被反射的像素。只能反射屏幕内的内容。")
	add_range("ssr.ssr_max_steps", _env, "ssr_max_steps", 1.0, 512.0, 1.0, "最大步数：越多越准、越远，越贵。")
	add_range("ssr.ssr_fade_in", _env, "ssr_fade_in", 0.0, 1.0, 0.01, "淡入：反射在接触点附近的淡入。")
	add_range("ssr.ssr_fade_out", _env, "ssr_fade_out", 0.0, 8.0, 0.01, "淡出：反射在屏幕边缘/远处的淡出，避免突兀消失。")
	add_range("ssr.ssr_depth_tolerance", _env, "ssr_depth_tolerance", 0.01, 2.0, 0.01, "深度容差：认为“击中”的厚度。太大会出现拉伸条纹，太小会漏掉薄物体。")
	add_range("floor.roughness", _floor_mat, "roughness", 0.0, 1.0, 0.01, "地板粗糙度：越低反射越清晰。Godot 会对粗糙表面的 SSR 做模糊。")
	add_range("floor.metallic", _floor_mat, "metallic", 0.0, 1.0, 0.01, "地板金属度：金属的反射更强、更带颜色。")

	group("Glow 辉光")
	add_bool("glow.glow_enabled", _env, "glow_enabled", "启用辉光 (Bloom)：亮部向周围“溢出”，模拟镜头散射。")
	add_range("glow.glow_intensity", _env, "glow_intensity", 0.0, 8.0, 0.01, "强度：辉光叠加的整体强度。")
	add_range("glow.glow_strength", _env, "glow_strength", 0.0, 2.0, 0.01, "力度：模糊过程中的亮度增益。")
	add_range("glow.glow_bloom", _env, "glow_bloom", 0.0, 1.0, 0.01, "Bloom：>0 时低于阈值的像素也参与辉光，画面整体变柔、发雾。")
	add_range("glow.glow_hdr_threshold", _env, "glow_hdr_threshold", 0.0, 4.0, 0.01, "HDR 阈值：亮度超过这个值的像素才发光。设为 1 左右只让“比白还亮”的东西发光。")
	add_range("glow.glow_hdr_scale", _env, "glow_hdr_scale", 0.0, 4.0, 0.01, "HDR 缩放：超过阈值部分的放大倍数。")
	add_range("glow.glow_hdr_luminance_cap", _env, "glow_hdr_luminance_cap", 0.0, 256.0, 0.1, "亮度上限：参与辉光的最大亮度，防止极亮像素产生巨大光晕或闪烁。", {"exp": false})
	add_enum("glow.glow_blend_mode", _env, "glow_blend_mode", [["Additive 叠加", Environment.GLOW_BLEND_MODE_ADDITIVE], ["Screen 滤色", Environment.GLOW_BLEND_MODE_SCREEN], ["Softlight 柔光", Environment.GLOW_BLEND_MODE_SOFTLIGHT], ["Replace 替换", Environment.GLOW_BLEND_MODE_REPLACE], ["Mix 混合", Environment.GLOW_BLEND_MODE_MIX]], "混合模式：辉光怎么叠加回画面。Replace 可以单独看辉光本身 (调试用)。")
	add_range("glow.level_small", self, "glow_small", 0.0, 2.0, 0.01, "小半径层级：glow level 1~2 的强度。主要贡献紧贴亮部的光晕。")
	add_range("glow.level_medium", self, "glow_medium", 0.0, 2.0, 0.01, "中半径层级：glow level 3~4 的强度。")
	add_range("glow.level_large", self, "glow_large", 0.0, 2.0, 0.01, "大半径层级：glow level 5~7 的强度。贡献大范围的柔光。")
	add_range("emit.emission_energy_multiplier", _emit_mat, "emission_energy_multiplier", 0.0, 32.0, 0.01, "自发光强度：橙色小球的亮度。它也是 GI 光源 (SDFGI/VoxelGI 会让它照亮周围)。")
	add_color("emit.emission", _emit_mat, "emission", "自发光颜色")

	group("Fog 雾")
	add_bool("fog.fog_enabled", _env, "fog_enabled", "启用雾：按距离把像素混向雾色，很便宜。")
	add_enum("fog.fog_mode", _env, "fog_mode", [["Exponential 指数", Environment.FOG_MODE_EXPONENTIAL], ["Depth 线性深度", Environment.FOG_MODE_DEPTH]], "雾模式：指数雾更自然；Depth 用 begin/end 线性控制 (更易美术控制)。")
	add_color("fog.fog_light_color", _env, "fog_light_color", "雾颜色")
	add_range("fog.fog_light_energy", _env, "fog_light_energy", 0.0, 4.0, 0.01, "雾亮度")
	add_range("fog.fog_density", _env, "fog_density", 0.0, 0.2, 0.0005, "密度：指数雾的浓度。")
	add_range("fog.fog_sun_scatter", _env, "fog_sun_scatter", 0.0, 1.0, 0.01, "太阳散射：朝太阳方向看时雾更亮 (被阳光照亮的雾)。")
	add_range("fog.fog_aerial_perspective", _env, "fog_aerial_perspective", 0.0, 1.0, 0.01, "大气透视：雾色取自天空，远处物体融入天空颜色。")
	add_range("fog.fog_sky_affect", _env, "fog_sky_affect", 0.0, 1.0, 0.01, "影响天空：雾是否也覆盖天空背景。")
	add_range("fog.fog_height", _env, "fog_height", -50.0, 50.0, 0.1, "高度雾基准：这个高度以下雾更浓。")
	add_range("fog.fog_height_density", _env, "fog_height_density", -2.0, 2.0, 0.01, "高度雾密度：>0 时低处浓、高处稀。")
	add_range("fog.fog_depth_begin", _env, "fog_depth_begin", 0.0, 500.0, 0.1, "线性雾起点 (Depth 模式)")
	add_range("fog.fog_depth_end", _env, "fog_depth_end", 0.0, 1000.0, 0.1, "线性雾终点 (Depth 模式)")

	group("Volumetric Fog 体积雾")
	add_bool("vfog.volumetric_fog_enabled", _env, "volumetric_fog_enabled", "启用体积雾：在视锥 3D 网格 (froxel) 里计算光的散射，能产生光柱和局部雾。比普通雾贵得多。")
	add_range("vfog.volumetric_fog_density", _env, "volumetric_fog_density", 0.0, 0.2, 0.0005, "密度：全局体积雾浓度。")
	add_color("vfog.volumetric_fog_albedo", _env, "volumetric_fog_albedo", "散射颜色 (albedo)：雾把光散射回来的颜色。")
	add_color("vfog.volumetric_fog_emission", _env, "volumetric_fog_emission", "自发光颜色：雾自己发的光 (不需要光源)，适合魔法/霓虹氛围。")
	add_range("vfog.volumetric_fog_emission_energy", _env, "volumetric_fog_emission_energy", 0.0, 8.0, 0.01, "自发光强度")
	add_range("vfog.volumetric_fog_anisotropy", _env, "volumetric_fog_anisotropy", -0.9, 0.9, 0.01, "各向异性：>0 向前散射 (迎光看最亮，光柱明显)；<0 向后散射；0 各向同性。")
	add_range("vfog.volumetric_fog_length", _env, "volumetric_fog_length", 1.0, 512.0, 0.5, "覆盖距离：体积雾计算到多远。越短精度越高。", {"exp": true})
	add_range("vfog.volumetric_fog_detail_spread", _env, "volumetric_fog_detail_spread", 0.5, 6.0, 0.01, "细节分布：froxel 在深度方向的分布，越大近处越精细。")
	add_range("vfog.volumetric_fog_gi_inject", _env, "volumetric_fog_gi_inject", 0.0, 16.0, 0.01, "GI 注入：让 SDFGI/VoxelGI 的间接光照亮雾。")
	add_range("vfog.volumetric_fog_ambient_inject", _env, "volumetric_fog_ambient_inject", 0.0, 16.0, 0.01, "环境光注入：让环境光照亮雾。")
	add_bool("vfog.volumetric_fog_temporal_reprojection_enabled", _env, "volumetric_fog_temporal_reprojection_enabled", "时间重投影：混合多帧结果让雾更平滑，代价是相机快速移动时有拖影。")
	add_range("sun.light_volumetric_fog_energy", _sun, "light_volumetric_fog_energy", 0.0, 16.0, 0.01, "太阳对体积雾的贡献：调大即可让光柱更明显，不影响物体表面的亮度。")
	add_bool("fogvol.visible", _fog_volume, "visible", "局部雾体积 (FogVolume)：房间右后角的一个雾盒子。需要开启体积雾。")
	add_range("fogvol.density", _fog_mat, "density", -4.0, 8.0, 0.01, "局部雾密度：FogMaterial.density，负值可以在全局雾里“挖洞”。")
	add_color("fogvol.albedo", _fog_mat, "albedo", "局部雾颜色")
	add_color("fogvol.emission", _fog_mat, "emission", "局部雾自发光")
	add_range("fogvol.height_falloff", _fog_mat, "height_falloff", 0.0, 8.0, 0.01, "高度衰减：越往上雾越稀。")
	add_range("fogvol.edge_fade", _fog_mat, "edge_fade", 0.0, 1.0, 0.01, "边缘淡出：盒子边缘的柔和程度。")

	group("Adjustments 调色")
	add_bool("adj.adjustment_enabled", _env, "adjustment_enabled", "启用调色：色调映射之后的亮度/对比度/饱和度/LUT。")
	add_range("adj.adjustment_brightness", _env, "adjustment_brightness", 0.0, 3.0, 0.01, "亮度")
	add_range("adj.adjustment_contrast", _env, "adjustment_contrast", 0.0, 3.0, 0.01, "对比度")
	add_range("adj.adjustment_saturation", _env, "adjustment_saturation", 0.0, 3.0, 0.01, "饱和度")
	add_enum("grading.lut", self, "color_grading", LUT_LABELS, "调色 LUT：adjustment_color_correction。1D 渐变按 R/G/B 通道分别映射曲线；3D LUT 把任意颜色映射到任意颜色。")

	group("Camera 自动曝光与景深")
	add_range("cam.exposure_multiplier", _cam_attr, "exposure_multiplier", 0.05, 8.0, 0.01, "曝光倍数：CameraAttributes 上的曝光，与 tonemap_exposure 相乘。", {"exp": true})
	add_bool("cam.auto_exposure_enabled", _cam_attr, "auto_exposure_enabled", "自动曝光：根据画面平均亮度自动调整曝光。")
	add_range("cam.auto_exposure_scale", _cam_attr, "auto_exposure_scale", 0.01, 2.0, 0.01, "目标亮度：自动曝光想把画面调到多亮。")
	add_range("cam.auto_exposure_speed", _cam_attr, "auto_exposure_speed", 0.1, 10.0, 0.01, "适应速度：亮暗变化后多快适应。")
	add_range("cam.auto_exposure_min_sensitivity", _cam_attr, "auto_exposure_min_sensitivity", 0.0, 1600.0, 1.0, "最小感光度 (ISO)：限制自动曝光在亮处最多压暗多少。")
	add_range("cam.auto_exposure_max_sensitivity", _cam_attr, "auto_exposure_max_sensitivity", 50.0, 64000.0, 10.0, "最大感光度 (ISO)：限制在暗处最多提亮多少。", {"exp": true})
	add_bool("cam.dof_blur_far_enabled", _cam_attr, "dof_blur_far_enabled", "远景模糊")
	add_range("cam.dof_blur_far_distance", _cam_attr, "dof_blur_far_distance", 0.1, 100.0, 0.1, "远景模糊起点 (米)", {"exp": true})
	add_range("cam.dof_blur_far_transition", _cam_attr, "dof_blur_far_transition", 0.0, 20.0, 0.1, "远景过渡带")
	add_bool("cam.dof_blur_near_enabled", _cam_attr, "dof_blur_near_enabled", "近景模糊")
	add_range("cam.dof_blur_near_distance", _cam_attr, "dof_blur_near_distance", 0.1, 20.0, 0.05, "近景模糊终点 (米)")
	add_range("cam.dof_blur_near_transition", _cam_attr, "dof_blur_near_transition", 0.0, 10.0, 0.05, "近景过渡带")
	add_range("cam.dof_blur_amount", _cam_attr, "dof_blur_amount", 0.0, 1.0, 0.005, "模糊强度")

	group("Sun 太阳")
	add_range("light.sun_azimuth", self, "sun_azimuth", 0.0, 360.0, 1.0, "太阳方位角：180° 时阳光从房间背后穿过窗户照进来。")
	add_range("light.sun_elevation", self, "sun_elevation", 2.0, 90.0, 0.5, "太阳仰角：决定窗口光斑落在地面的位置。")
	add_range("sun.light_energy", _sun, "light_energy", 0.0, 8.0, 0.01, "太阳强度")
	add_color("sun.light_color", _sun, "light_color", "太阳颜色")

	group("Viewport 抗锯齿与分辨率 (全局)")
	var vp := get_viewport()
	add_enum("vp.msaa_3d", vp, "msaa_3d", [["Disabled", Viewport.MSAA_DISABLED], ["2x", Viewport.MSAA_2X], ["4x", Viewport.MSAA_4X], ["8x", Viewport.MSAA_8X]], "MSAA：只对几何边缘多重采样，不处理着色/透明贴图的锯齿。", {"global": true})
	add_enum("vp.screen_space_aa", vp, "screen_space_aa", [["Disabled", Viewport.SCREEN_SPACE_AA_DISABLED], ["FXAA", Viewport.SCREEN_SPACE_AA_FXAA], ["SMAA", Viewport.SCREEN_SPACE_AA_SMAA]], "屏幕空间抗锯齿：后处理式抗锯齿，FXAA 最便宜但会糊，SMAA 更清晰。", {"global": true})
	add_bool("vp.use_taa", vp, "use_taa", "TAA 时间抗锯齿：混合多帧，能消除高光闪烁 (specular aliasing) 并让 SDFGI/体积雾更平滑；运动时可能有拖影。", {"global": true})
	add_enum("vp.scaling_3d_mode", vp, "scaling_3d_mode", [["Bilinear", Viewport.SCALING_3D_MODE_BILINEAR], ["FSR 1.0", Viewport.SCALING_3D_MODE_FSR], ["FSR 2.2", Viewport.SCALING_3D_MODE_FSR2]], "3D 缩放模式：低分辨率渲染再放大。FSR 2 自带时间抗锯齿。", {"global": true})
	add_range("vp.scaling_3d_scale", vp, "scaling_3d_scale", 0.25, 2.0, 0.01, "渲染比例：3D 渲染分辨率相对窗口的比例。<1 更快更糊，>1 超采样。", {"global": true})


func _after_init() -> void:
	_apply_glow_levels()



# --- Helpers -----------------------------------------------------------------

func _apply_gi_mode() -> void:
	if _env == null:
		return
	_env.sdfgi_enabled = gi_mode == 1
	_voxel.visible = gi_mode == 2
	if gi_mode == 2 and _voxel_dirty and not validating:
		_rebake()


func _rebake() -> void:
	if validating or _voxel == null:
		return
	_voxel.bake()
	_voxel_dirty = false
	_apply_voxel_data()


func _apply_voxel_data() -> void:
	if _voxel == null or _voxel.data == null:
		return
	var d := _voxel.data
	d.energy = voxel_energy
	d.propagation = voxel_propagation
	d.use_two_bounces = voxel_use_two_bounces
	d.interior = voxel_interior


func _apply_glow_levels() -> void:
	if _env == null:
		return
	var levels := [glow_small, glow_small, glow_medium, glow_medium, glow_large, glow_large, glow_large]
	for i in levels.size():
		_env.set_glow_level(i, levels[i])
