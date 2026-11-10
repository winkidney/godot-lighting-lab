extends "res://scripts/lab/lab_module.gd"
## 05 场景氛围配方: atmosphere "recipes" built from layers (key / fill / rim
## light, sky ambient, GI, fog, volumetric fog, practical lights, screen-space
## effects, post-processing, weather). Layers can be switched off one by one,
## recipes can be blended, and a time-of-day slider drives a day/night cycle.

const SceneKit := preload("res://scripts/lib/scene_kit.gd")
const ProcTextures := preload("res://scripts/lib/proc_textures.gd")
const POST_SHADER := preload("res://shaders/post_process.gdshader")

const R_NOON := "① 晴朗正午"
const R_GOLDEN := "② 黄金时刻"
const R_OVERCAST := "③ 阴天柔光"
const R_NIGHT := "④ 月夜"
const R_GODRAYS := "⑤ 雾林丁达尔光"
const R_NEON := "⑥ 霓虹雨夜"
const R_HORROR := "⑦ 地下室恐怖"
## Time of day keyframes: [hour, recipe].
const DAY_KEYS := [[0.0, R_NIGHT], [5.0, R_NIGHT], [6.5, R_GOLDEN], [9.0, R_NOON], [15.0, R_NOON], [17.5, R_GOLDEN], [19.0, R_NIGHT], [24.0, R_NIGHT]]
const POST_DEFAULTS := {
	"vignette_strength": 0.15, "vignette_radius": 0.8, "vignette_softness": 0.5, "grain_amount": 0.0,
	"chromatic_aberration": 0.0, "tint_color": Color(1, 1, 1), "tint_strength": 0.0,
	"lift_color": Color(0, 0, 0), "lift_strength": 0.0,
}
## Lamp 0 is the one under the "路灯下" bookmark (it stays lit when lamps_lit = 1).
const LAMP_POSITIONS := [Vector3(-6, 0, 7), Vector3(6, 0, -6), Vector3(-6, 0, -6), Vector3(4, 0, 9)]

# --- Layers (meta): which ingredients of the recipe are switched on ---
var layer_key := true:
	set(v):
		layer_key = v
		_apply_layers()
var layer_fill := true:
	set(v):
		layer_fill = v
		_apply_layers()
var layer_rim := true:
	set(v):
		layer_rim = v
		_apply_layers()
var layer_shadows := true:
	set(v):
		layer_shadows = v
		_apply_layers()
var layer_sky_ambient := true:
	set(v):
		layer_sky_ambient = v
		_apply_layers()
var layer_gi := true:
	set(v):
		layer_gi = v
		_apply_layers()
var layer_fog := true:
	set(v):
		layer_fog = v
		_apply_layers()
var layer_volumetric := true:
	set(v):
		layer_volumetric = v
		_apply_layers()
var layer_practical := true:
	set(v):
		layer_practical = v
		_apply_layers()
var layer_screen_space := true:
	set(v):
		layer_screen_space = v
		_apply_layers()
var layer_post := true:
	set(v):
		layer_post = v
		_apply_layers()
var layer_weather := true:
	set(v):
		layer_weather = v
		_apply_layers()

# --- Transient triggers ---
var time_of_day := 12.0:
	set(v):
		time_of_day = v
		if is_node_ready() and not _applying:
			_apply_time(v)
var recipe_a := R_NOON:
	set(v):
		recipe_a = v
		if is_node_ready() and not _applying:
			_apply_blend()
var recipe_b := R_NIGHT:
	set(v):
		recipe_b = v
		if is_node_ready() and not _applying:
			_apply_blend()
var recipe_blend := 0.0:
	set(v):
		recipe_blend = v
		if is_node_ready() and not _applying:
			_apply_blend()

# --- Recipe proxies ---
var key_azimuth := 35.0:
	set(v):
		key_azimuth = v
		_aim_lights()
var key_elevation := 55.0:
	set(v):
		key_elevation = v
		_aim_lights()
var lamp_energy := 0.0:
	set(v):
		lamp_energy = v
		_apply_practical()
var lamp_color := Color(1.0, 0.72, 0.42):
	set(v):
		lamp_color = v
		_apply_practical()
var lamps_lit := 4:
	set(v):
		lamps_lit = v
		_apply_practical()
var flicker := 0.0:
	set(v):
		flicker = v
		_apply_practical()
var neon_energy := 0.0:
	set(v):
		neon_energy = v
		_apply_practical()
var window_emission := 0.0:
	set(v):
		window_emission = v
		_apply_practical()
var interior_energy := 0.0:
	set(v):
		interior_energy = v
		_apply_practical()
var wetness := 0.0:
	set(v):
		wetness = v
		_apply_weather()
var rain := 0.0:
	set(v):
		rain = v
		_apply_weather()

var _env: Environment
var _sky: ProceduralSkyMaterial
var _key: DirectionalLight3D
var _fill: DirectionalLight3D
var _rim: DirectionalLight3D
var _lamps: Array[Dictionary] = []
var _neons: Array[Dictionary] = []
var _interior_light: OmniLight3D
var _interior_mat: StandardMaterial3D
var _window_mat: StandardMaterial3D
var _ground_mat: StandardMaterial3D
var _puddles: Array[MeshInstance3D] = []
var _rain: GPUParticles3D
var _post_rect: ColorRect
var _post_mat: ShaderMaterial
var _noise := FastNoiseLite.new()
var _time := 0.0
var _flicker_factor: Array[float] = [1.0, 1.0, 1.0, 1.0]


func get_title() -> String:
	return "05 场景氛围配方"


func get_overview() -> String:
	return """一个“氛围”从来不是单个参数，而是几层光照的[b]配方[/b]：
• [b]主光 Key[/b]：决定方向、时间与情绪 (颜色温度、角度、软硬)。
• [b]补光 Fill / 天空环境光[/b]：决定暗部有多亮、偏什么颜色。主光暖时补光通常偏冷 —— 冷暖对比。
• [b]轮廓光 Rim[/b]：从背后勾出物体边缘，把主体从背景里分离出来。
• [b]实用光源 Practical[/b]：画面里能看到的灯 (路灯、窗户、霓虹)，夜景的主角。
• [b]大气[/b]：雾、体积雾、大气透视 —— 给空间纵深与光束。
• [b]后处理[/b]：色调映射、辉光、调色、暗角、颗粒 —— 最后的“滤镜”。

[b]试一试[/b]
1. 左侧依次点 7 个配方，再到右侧「Layers 图层」把每一层逐个关掉，看它在配方里的贡献。
2. 「Recipe 配方混合」：选 A、B 两个配方，拖 recipe_blend 在两者之间平滑插值。
3. 拖动 time_of_day (0~24 时)：太阳轨迹 + 在夜/黄金/正午配方之间插值，形成日夜循环。
4. 选一个配方后改几个参数，按「导出参数」把你的配方保存下来。"""


func get_camera_bookmarks() -> Dictionary:
	return {
		"广场全景": {"target": Vector3(0, 3.0, -2.0), "yaw": 0.0, "pitch": -10.0, "distance": 24.0},
		"藤架光柱": {"target": Vector3(-4.0, 2.0, 3.0), "yaw": 12.0, "pitch": -4.0, "distance": 10.0},
		"湿地面倒影": {"target": Vector3(0.5, 2.0, -7.0), "yaw": 0.0, "pitch": -9.0, "distance": 13.0},
		"路灯下": {"target": Vector3(-6.0, 1.4, 6.5), "yaw": 35.0, "pitch": -12.0, "distance": 7.0},
		"咖啡馆": {"target": Vector3(11.0, 1.8, 4.0), "yaw": -70.0, "pitch": -6.0, "distance": 8.0},
	}


func get_presets() -> Dictionary:
	return {
		R_NOON: {"_camera": "广场全景",
			"_note": "[b]晴朗正午[/b]：高角度白色主光 (≈5500K) + 蓝色天空环境光。阴影短而清晰，对比强；几乎没有雾，只有轻微的大气透视让远处略微发蓝。这是“基准光照”，其他配方都在它的基础上修改。"},
		R_GOLDEN: {"key.azimuth": 255.0, "key.elevation": 7.0, "key.light_color": Color(1.0, 0.6, 0.32), "key.light_energy": 1.8, "key.light_angular_distance": 1.2, "key.light_volumetric_fog_energy": 2.0,
			"fill.light_color": Color(0.4, 0.5, 0.85), "fill.light_energy": 0.25, "rim.light_color": Color(1.0, 0.72, 0.45), "rim.light_energy": 0.35,
			"sky.sky_top_color": Color(0.26, 0.36, 0.6), "sky.sky_horizon_color": Color(1.0, 0.62, 0.38), "sky.ground_horizon_color": Color(0.62, 0.45, 0.35),
			"fog.fog_light_color": Color(1.0, 0.72, 0.5), "fog.fog_density": 0.006, "fog.fog_sun_scatter": 0.7, "fog.fog_aerial_perspective": 0.7,
			"vfog.volumetric_fog_density": 0.006, "vfog.volumetric_fog_anisotropy": 0.7, "glow.glow_intensity": 0.9, "glow.glow_bloom": 0.04,
			"prac.lamp_energy": 0.8, "prac.window_emission": 0.6, "adj.adjustment_saturation": 1.12, "post.vignette_strength": 0.3, "env.tonemap_exposure": 1.05, "_camera": "广场全景",
			"_note": "[b]黄金时刻[/b]：低角度暖色主光 (≈2500K，仰角 7°) 拉出长长的阴影；天空补光是冷蓝色 —— [b]冷暖对比[/b]是黄金时刻的灵魂。太阳散射雾 (sun_scatter) 让逆光方向发亮，少量体积雾强化光束。路灯和窗户开始亮起，暗示时间流逝。"},
		R_OVERCAST: {"key.light_energy": 0.35, "key.light_color": Color(0.86, 0.9, 0.95), "key.light_angular_distance": 10.0, "key.elevation": 60.0, "fill.light_energy": 0.0,
			"sky.sky_top_color": Color(0.55, 0.58, 0.62), "sky.sky_horizon_color": Color(0.74, 0.76, 0.78), "sky.ground_horizon_color": Color(0.5, 0.5, 0.5), "sky.sky_energy_multiplier": 1.5,
			"fog.fog_light_color": Color(0.72, 0.74, 0.77), "fog.fog_density": 0.014, "fog.fog_aerial_perspective": 0.2, "ssao.ssao_intensity": 3.0,
			"adj.adjustment_saturation": 0.78, "adj.adjustment_contrast": 0.94, "weather.wetness": 0.25, "_camera": "广场全景",
			"_note": "[b]阴天柔光[/b]：主光很弱且角直径极大 (阴影软到几乎消失)，照明主要来自明亮、均匀的灰色天空。失去了直接光的方向感，物体的立体感靠[b]环境光遮蔽 (SSAO)[/b] 维持。降低饱和度、加浓雾，营造潮湿压抑的感觉。"},
		R_NIGHT: {"key.azimuth": 130.0, "key.elevation": 38.0, "key.light_color": Color(0.55, 0.66, 1.0), "key.light_energy": 0.16, "key.light_volumetric_fog_energy": 2.0, "fill.light_energy": 0.03,
			"sky.sky_top_color": Color(0.008, 0.012, 0.035), "sky.sky_horizon_color": Color(0.03, 0.04, 0.08), "sky.ground_horizon_color": Color(0.02, 0.02, 0.03), "sky.ground_bottom_color": Color(0.01, 0.01, 0.01), "sky.sky_energy_multiplier": 0.6,
			"prac.lamp_energy": 3.0, "prac.window_emission": 3.0, "prac.interior_energy": 3.0,
			"fog.fog_light_color": Color(0.12, 0.14, 0.22), "fog.fog_density": 0.01, "fog.fog_sun_scatter": 0.0, "vfog.volumetric_fog_density": 0.012, "vfog.volumetric_fog_anisotropy": 0.3,
			"glow.glow_intensity": 1.0, "glow.glow_hdr_threshold": 0.8, "env.tonemap_exposure": 1.5, "post.vignette_strength": 0.4, "adj.adjustment_saturation": 0.9, "_camera": "广场全景",
			"_note": "[b]月夜[/b]：弱而冷的月光 (蓝色、低强度) + 强而暖的人工光 (路灯、窗户、室内)。冷暖对比反过来了：环境冷、局部暖。曝光调高，模拟人眼的暗适应；体积雾让路灯周围出现光晕。"},
		R_GODRAYS: {"key.azimuth": 200.0, "key.elevation": 32.0, "key.light_color": Color(1.0, 0.9, 0.74), "key.light_energy": 2.2, "key.light_volumetric_fog_energy": 2.5,
			"vfog.volumetric_fog_density": 0.012, "vfog.volumetric_fog_anisotropy": 0.65, "vfog.volumetric_fog_albedo": Color(0.95, 0.93, 0.88),
			"sky.sky_top_color": Color(0.32, 0.42, 0.55), "sky.sky_horizon_color": Color(0.7, 0.7, 0.66), "sky.sky_energy_multiplier": 0.7, "fog.fog_density": 0.002, "env.ambient_light_sky_contribution": 0.4,
			"glow.glow_intensity": 0.7, "adj.adjustment_contrast": 1.1, "env.tonemap_exposure": 0.9, "fill.light_energy": 0.03, "_camera": "藤架光柱",
			"_note": "[b]丁达尔光 (God rays)[/b] = 体积雾 + 强方向光 + 遮挡物的缝隙 (这里是藤架的格栅)。关键参数：体积雾 anisotropy 高 (向前散射，迎着光看最亮)，主光的 light_volumetric_fog_energy 调大；降低环境光让光束更突出。试着关掉 Volumetric 图层对比。"},
		R_NEON: {"key.light_energy": 0.05, "key.light_color": Color(0.4, 0.5, 0.9), "fill.light_energy": 0.0, "rim.light_color": Color(0.4, 0.9, 1.0), "rim.light_energy": 0.25,
			"sky.sky_top_color": Color(0.004, 0.004, 0.015), "sky.sky_horizon_color": Color(0.06, 0.025, 0.09), "sky.ground_horizon_color": Color(0.02, 0.01, 0.03), "sky.ground_bottom_color": Color(0.01, 0.01, 0.01), "sky.sky_energy_multiplier": 0.5,
			"prac.neon_energy": 7.0, "prac.lamp_energy": 1.6, "prac.lamp_color": Color(0.8, 0.88, 1.0), "prac.window_emission": 1.5, "prac.interior_energy": 2.0,
			"weather.wetness": 1.0, "weather.rain": 1.0, "fog.fog_light_color": Color(0.25, 0.1, 0.3), "fog.fog_density": 0.025,
			"vfog.volumetric_fog_density": 0.02, "vfog.volumetric_fog_emission": Color(0.03, 0.0, 0.05), "vfog.volumetric_fog_emission_energy": 1.0,
			"glow.glow_intensity": 1.4, "glow.glow_bloom": 0.12, "glow.glow_hdr_threshold": 0.7, "post.chromatic_aberration": 1.2, "post.grain_amount": 0.12, "post.vignette_strength": 0.45,
			"post.tint_color": Color(0.85, 0.9, 1.0), "post.tint_strength": 0.15, "adj.adjustment_saturation": 1.25, "env.tonemap_exposure": 1.4, "_camera": "湿地面倒影",
			"_note": "[b]霓虹雨夜[/b]：几乎没有自然光，画面由高饱和的霓虹 (品红/青) 主导。[b]湿地面[/b]是关键：粗糙度很低 + SSR，让霓虹在地上拉出长长的倒影。雾带一点紫色自发光，辉光阈值降低让所有灯都“晕开”。后处理加色差和颗粒，营造镜头感。"},
		R_HORROR: {"key.light_energy": 0.0, "fill.light_energy": 0.0, "rim.light_energy": 0.0,
			"sky.sky_top_color": Color(0.003, 0.003, 0.004), "sky.sky_horizon_color": Color(0.006, 0.007, 0.006), "sky.ground_horizon_color": Color(0.005, 0.005, 0.005), "sky.ground_bottom_color": Color(0, 0, 0), "sky.sky_energy_multiplier": 0.2,
			"prac.lamp_energy": 6.0, "prac.lamps_lit": 1, "prac.lamp_color": Color(0.85, 1.0, 0.7), "prac.flicker": 0.6,
			"vfog.volumetric_fog_density": 0.05, "vfog.volumetric_fog_anisotropy": 0.2, "vfog.volumetric_fog_albedo": Color(0.7, 0.75, 0.6),
			"fog.fog_density": 0.03, "fog.fog_light_color": Color(0.03, 0.035, 0.025), "fog.fog_sun_scatter": 0.0,
			"adj.adjustment_saturation": 0.45, "adj.adjustment_contrast": 1.2, "post.vignette_strength": 0.7, "post.grain_amount": 0.22, "post.tint_color": Color(0.8, 1.0, 0.75), "post.tint_strength": 0.3,
			"env.tonemap_exposure": 1.6, "glow.glow_intensity": 0.5, "ssao.ssao_intensity": 3.0, "_camera": "路灯下",
			"_note": "[b]恐怖[/b]的核心是“看不清”。几乎全黑的环境里只有一盏闪烁的、偏绿的灯；浓雾吞掉远处，强暗角把视线收向画面中央，再加上低饱和、病态的绿色调和胶片颗粒。闪烁 (flicker) 让光源变得不可信赖，比单纯的黑暗更让人不安。"},
	}


# --- Scene -----------------------------------------------------------------------

func _build_scene() -> void:
	var we := SceneKit.make_environment(self, Environment.TONE_MAPPER_AGX)
	_env = we.environment
	_sky = _env.sky.sky_material as ProceduralSkyMaterial
	_sky.sky_top_color = Color(0.3, 0.48, 0.78)
	_sky.sky_horizon_color = Color(0.68, 0.75, 0.84)
	_sky.ground_horizon_color = Color(0.55, 0.53, 0.5)
	_sky.ground_bottom_color = Color(0.18, 0.17, 0.16)
	_env.ssao_intensity = 1.5
	_env.ssao_radius = 1.0
	_env.ssr_max_steps = 96
	_env.sdfgi_cascades = 4
	_env.sdfgi_min_cell_size = 0.25
	_env.fog_light_color = Color(0.7, 0.76, 0.85)
	_env.fog_density = 0.003
	_env.fog_sun_scatter = 0.15
	_env.fog_aerial_perspective = 0.5
	_env.volumetric_fog_density = 0.0
	_env.volumetric_fog_albedo = Color(0.9, 0.9, 0.92)
	_env.volumetric_fog_anisotropy = 0.5
	_env.volumetric_fog_length = 80.0
	_env.glow_intensity = 0.6
	_env.glow_hdr_threshold = 1.0
	_noise.frequency = 0.9

	_build_ground()
	_build_buildings()
	_build_props()

	_key = SceneKit.dir_light(self, "KeyLight", key_azimuth, key_elevation, Color(1.0, 0.96, 0.9), 1.4)
	_key.light_angular_distance = 0.5
	_key.directional_shadow_max_distance = 80.0
	_fill = SceneKit.dir_light(self, "FillLight", 0, 25, Color(0.55, 0.65, 0.9), 0.1, false)
	_fill.light_specular = 0.2
	_rim = SceneKit.dir_light(self, "RimLight", 200, 20, Color(1, 1, 1), 0.0, false)

	_build_rain()
	_build_post()


func _build_ground() -> void:
	_ground_mat = SceneKit.mat(Color(0.42, 0.4, 0.38), 0.85)
	_ground_mat.resource_name = "GroundMaterial"
	_ground_mat.normal_enabled = true
	_ground_mat.normal_texture = ProcTextures.normal_texture("bricks")
	_ground_mat.normal_scale = 0.6
	_ground_mat.uv1_scale = Vector3(40, 40, 1)
	SceneKit.plane(self, Vector2(140, 140), Vector3.ZERO, _ground_mat, "Ground")
	var puddle_mat := SceneKit.mat(Color(0.04, 0.045, 0.05), 0.02)
	for p in [[Vector3(-2.5, 0.012, 4.0), 1.8], [Vector3(3.5, 0.012, -3.5), 1.4], [Vector3(-7.5, 0.012, -1.5), 1.2], [Vector3(1.0, 0.012, -8.5), 2.2], [Vector3(6.5, 0.012, 5.0), 1.0]]:
		var cm := CylinderMesh.new()
		cm.top_radius = p[1]
		cm.bottom_radius = p[1]
		cm.height = 0.01
		cm.radial_segments = 40
		var mi := SceneKit.mesh(self, cm, p[0], puddle_mat)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_puddles.append(mi)


func _build_buildings() -> void:
	var wall_a := SceneKit.mat(Color(0.72, 0.66, 0.6), 0.9)
	var wall_b := SceneKit.mat(Color(0.55, 0.58, 0.62), 0.9)
	var wall_c := SceneKit.mat(Color(0.64, 0.5, 0.42), 0.9)
	var dark_glass := SceneKit.mat(Color(0.06, 0.07, 0.09), 0.15)
	_window_mat = SceneKit.emissive(Color(1.0, 0.78, 0.5), 0.0)
	_window_mat.albedo_color = Color(0.1, 0.09, 0.08)
	_window_mat.roughness = 0.2
	SceneKit.box(self, Vector3(20, 11, 6), Vector3(0, 5.5, -15), wall_a, "BuildingBack")
	SceneKit.box(self, Vector3(7, 14, 18), Vector3(-15.5, 7, -4), wall_b, "BuildingLeft")
	SceneKit.box(self, Vector3(8, 8, 10), Vector3(15, 4, -10), wall_c, "BuildingRight")
	var i := 0
	for row in [2.6, 5.4, 8.2]:
		for x in [-8.0, -4.8, -1.6, 1.6, 4.8, 8.0]:
			var lit := (i * 7) % 3 != 0
			SceneKit.box(self, Vector3(1.4, 1.8, 0.08), Vector3(x, row, -11.96), _window_mat if lit else dark_glass)
			i += 1
	for row in [3.0, 6.5, 10.0]:
		for z in [-11.0, -7.0, -3.0, 1.0]:
			var lit := (i * 5) % 3 != 0
			SceneKit.box(self, Vector3(0.08, 1.8, 1.4), Vector3(-11.96, row, z), _window_mat if lit else dark_glass)
			i += 1
	# Neon signs on the back building.
	for spec in [[Vector3(4.0, 0.7, 0.12), Vector3(-4.5, 4.0, -11.9), Color(1.0, 0.15, 0.6)], [Vector3(0.7, 3.2, 0.12), Vector3(6.4, 5.2, -11.9), Color(0.1, 0.9, 1.0)]]:
		var mat := SceneKit.emissive(spec[2], 0.0)
		var sign_mi := SceneKit.box(self, spec[0], spec[1], mat)
		sign_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var light := SceneKit.omni_light(self, "Neon", spec[1] + Vector3(0, 0, 0.9), spec[2], 0.0, 9.0)
		_neons.append({"light": light, "mat": mat})
	# Open café on the right with a warm interior light.
	var cafe := SceneKit.mat(Color(0.78, 0.74, 0.68), 0.85)
	SceneKit.box(self, Vector3(6, 0.1, 6), Vector3(12, 0.05, 4), SceneKit.mat(Color(0.45, 0.32, 0.22), 0.6))
	SceneKit.box(self, Vector3(0.3, 4.2, 6.3), Vector3(15.1, 2.1, 4), cafe)
	SceneKit.box(self, Vector3(6.3, 4.2, 0.3), Vector3(12, 2.1, 0.85), cafe)
	SceneKit.box(self, Vector3(6.3, 4.2, 0.3), Vector3(12, 2.1, 7.15), cafe)
	SceneKit.box(self, Vector3(6.6, 0.3, 6.6), Vector3(12, 4.3, 4), cafe)
	SceneKit.box(self, Vector3(1.4, 0.8, 0.9), Vector3(12.6, 0.5, 4.0), SceneKit.mat(Color(0.35, 0.22, 0.15), 0.5))
	for dz in [-1.0, 1.0]:
		SceneKit.box(self, Vector3(0.5, 0.5, 0.5), Vector3(12.6, 0.35, 4.0 + dz), SceneKit.mat(Color(0.5, 0.3, 0.2), 0.6))
	_interior_mat = SceneKit.emissive(Color(1.0, 0.75, 0.45), 0.0)
	var shade := SceneKit.sphere(self, 0.3, Vector3(12.6, 3.75, 4.0), _interior_mat, 24)
	shade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_interior_light = SceneKit.omni_light(self, "CafeLight", Vector3(12.6, 3.3, 4.0), Color(1.0, 0.72, 0.45), 0.0, 8.0, true)
	SceneKit.label(self, "Café", Vector3(9.0, 4.8, 4.0), 64, Color(1.0, 0.85, 0.6))


func _build_props() -> void:
	var metal := SceneKit.mat(Color(0.12, 0.12, 0.13), 0.4, 0.8)
	for i in LAMP_POSITIONS.size():
		var base: Vector3 = LAMP_POSITIONS[i]
		SceneKit.cylinder(self, 0.07, 4.2, base + Vector3(0, 2.1, 0), metal)
		var head_mat := SceneKit.emissive(lamp_color, 0.0)
		var head := SceneKit.sphere(self, 0.22, base + Vector3(0, 4.3, 0), head_mat, 24)
		head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var light := SceneKit.omni_light(self, "Lamp%d" % i, base + Vector3(0, 3.95, 0), lamp_color, 0.0, 10.0, i < 2)
		_lamps.append({"light": light, "mat": head_mat})
	# Pergola: a lattice roof that slices sunlight into shafts.
	var wood := SceneKit.mat(Color(0.45, 0.33, 0.24), 0.8)
	for p in [Vector3(-6.5, 1.8, 0.5), Vector3(-1.5, 1.8, 0.5), Vector3(-6.5, 1.8, 5.5), Vector3(-1.5, 1.8, 5.5)]:
		SceneKit.box(self, Vector3(0.25, 3.6, 0.25), p, wood)
	for x in [-6.5, -1.5]:
		SceneKit.box(self, Vector3(0.25, 0.25, 5.6), Vector3(x, 3.55, 3.0), wood)
	for k in 12:
		SceneKit.box(self, Vector3(5.6, 0.12, 0.18), Vector3(-4.0, 3.72, 0.55 + k * 0.45), wood)
	SceneKit.label(self, "藤架 Pergola", Vector3(-4.0, 4.4, 3.0), 44)
	# Trees.
	var bark := SceneKit.mat(Color(0.3, 0.22, 0.16), 0.9)
	var leaves := SceneKit.mat(Color(0.22, 0.4, 0.18), 0.9)
	for t in [Vector3(-10, 0, 9), Vector3(2.5, 0, -8.5), Vector3(-9.5, 0, -9), Vector3(9.5, 0, -4)]:
		SceneKit.cylinder(self, 0.22, 3.0, t + Vector3(0, 1.5, 0), bark)
		SceneKit.sphere(self, 1.5, t + Vector3(0, 3.8, 0), leaves, 24)
		SceneKit.sphere(self, 1.1, t + Vector3(0.8, 4.6, 0.3), leaves, 24)
		SceneKit.sphere(self, 1.0, t + Vector3(-0.7, 4.4, -0.4), leaves, 24)
	# Statue, benches, crates.
	var stone := SceneKit.mat(Color(0.7, 0.68, 0.64), 0.7)
	SceneKit.box(self, Vector3(1.4, 1.0, 1.4), Vector3(1.5, 0.5, 0.5), stone)
	var torso := CapsuleMesh.new()
	torso.radius = 0.35
	torso.height = 1.6
	SceneKit.mesh(self, torso, Vector3(1.5, 1.8, 0.5), SceneKit.mat(Color(0.75, 0.72, 0.66), 0.35, 0.3))
	SceneKit.sphere(self, 0.28, Vector3(1.5, 2.88, 0.5), SceneKit.mat(Color(0.75, 0.72, 0.66), 0.35, 0.3), 32)
	SceneKit.box(self, Vector3(2.0, 0.45, 0.6), Vector3(-1.5, 0.225, -3.0), wood)
	SceneKit.box(self, Vector3(2.0, 0.45, 0.6), Vector3(5.0, 0.225, 3.5), wood)
	SceneKit.box(self, Vector3(0.8, 0.8, 0.8), Vector3(8.5, 0.4, -6.5), wood)
	SceneKit.box(self, Vector3(0.7, 0.7, 0.7), Vector3(9.3, 0.35, -5.6), wood)


func _build_rain() -> void:
	_rain = GPUParticles3D.new()
	_rain.name = "Rain"
	_rain.position = Vector3(0, 16, 0)
	_rain.amount = 6000
	_rain.lifetime = 0.9
	_rain.visibility_aabb = AABB(Vector3(-25, -20, -22), Vector3(50, 26, 44))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(22, 0.5, 20)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 2.0
	pm.initial_velocity_min = 18.0
	pm.initial_velocity_max = 22.0
	pm.gravity = Vector3(0, -9.8, 0)
	_rain.process_material = pm
	var streak := BoxMesh.new()
	streak.size = Vector3(0.012, 0.45, 0.012)
	var rain_mat := StandardMaterial3D.new()
	rain_mat.albedo_color = Color(0.75, 0.8, 0.9, 0.35)
	rain_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rain_mat.roughness = 0.2
	streak.material = rain_mat
	_rain.draw_pass_1 = streak
	_rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rain.emitting = false
	add_child(_rain)


func _build_post() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PostProcess"
	layer.layer = 1
	add_child(layer)
	_post_rect = ColorRect.new()
	_post_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_post_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_post_mat = ShaderMaterial.new()
	_post_mat.resource_name = "PostMaterial"
	_post_mat.shader = POST_SHADER
	# Set every uniform explicitly so get_shader_parameter() returns real values
	# (the headless dummy renderer cannot report shader defaults).
	for uname in POST_DEFAULTS:
		_post_mat.set_shader_parameter(uname, POST_DEFAULTS[uname])
	_post_rect.material = _post_mat
	layer.add_child(_post_rect)


# --- Parameters ---------------------------------------------------------------------

func _build_params() -> void:
	var names: Array = []
	for n in presets():
		names.append([n, n])

	group("Layers 图层开关 (逐层拆解配方)")
	add_bool("layer.key", self, "layer_key", "主光层：太阳/月亮。关掉后只剩环境光与人工光，画面立刻失去方向感和时间感。", {"meta": true})
	add_bool("layer.shadows", self, "layer_shadows", "主光阴影：阴影提供物体之间的空间关系和“落地感”。", {"meta": true})
	add_bool("layer.fill", self, "layer_fill", "补光层：与主光相对的弱光 (不投影)，控制暗部亮度和颜色。", {"meta": true})
	add_bool("layer.rim", self, "layer_rim", "轮廓光层：从背后照来的光，勾出物体边缘 (只在部分配方里有强度)。", {"meta": true})
	add_bool("layer.sky_ambient", self, "layer_sky_ambient", "天空环境光与反射：关掉后暗部发黑、金属/湿地面失去反射。", {"meta": true})
	add_bool("layer.gi", self, "layer_gi", "全局光照 (SDFGI)：光在建筑、地面间的反弹。关掉后室内、阴影里明显变暗变“假”。", {"meta": true})
	add_bool("layer.fog", self, "layer_fog", "雾/大气透视：远处物体融入天空颜色，制造纵深。", {"meta": true})
	add_bool("layer.volumetric", self, "layer_volumetric", "体积雾：光束、灯晕、浓雾。最贵的一层，留意 GPU 时间变化。", {"meta": true})
	add_bool("layer.practical", self, "layer_practical", "实用光源：路灯、窗户、霓虹、咖啡馆室内灯，以及它们的自发光材质。夜景的主角。", {"meta": true})
	add_bool("layer.screen_space", self, "layer_screen_space", "屏幕空间效果：SSAO (接触阴影) + SSR (湿地面反射)。", {"meta": true})
	add_bool("layer.post", self, "layer_post", "后处理：辉光、调色 (亮度/对比度/饱和度) 与自定义 shader (暗角、颗粒、色差、色调)。", {"meta": true})
	add_bool("layer.weather", self, "layer_weather", "天气：雨滴粒子与积水。", {"meta": true})
	add_action("layer.all_on", "全部图层开启", _all_layers_on, "全部图层开启：恢复所有图层。")

	group("Recipe 配方混合 / 日夜循环")
	add_enum("recipe.a", self, "recipe_a", names, "配方 A：recipe_blend = 0 时完全等于 A。", {"transient": true})
	add_enum("recipe.b", self, "recipe_b", names, "配方 B：recipe_blend = 1 时完全等于 B。", {"transient": true})
	add_range("recipe.blend", self, "recipe_blend", 0.0, 1.0, 0.01, "配方插值：对所有数值参数做线性插值 (颜色、强度、角度……)，枚举/开关在 0.5 处切换。这就是游戏里天气/时间过渡的基本做法。", {"transient": true})
	add_range("recipe.time_of_day", self, "time_of_day", 0.0, 24.0, 0.05, "一天中的时间：太阳沿轨迹移动 (6 点升起、18 点落下)，同时在 月夜 → 黄金时刻 → 正午 → 黄金时刻 → 月夜 之间插值。", {"transient": true})

	group("Key 主光 (太阳/月亮)")
	add_range("key.azimuth", self, "key_azimuth", 0.0, 360.0, 0.5, "主光方位角：决定阴影朝向。补光自动放在相反方向。")
	add_range("key.elevation", self, "key_elevation", 1.0, 90.0, 0.5, "主光仰角：越低阴影越长、颜色通常越暖 (大气散射)。")
	add_color("key.light_color", _key, "light_color", "主光颜色：正午白、黄昏橙、月光蓝。")
	add_range("key.light_energy", _key, "light_energy", 0.0, 4.0, 0.01, "主光强度")
	add_range("key.light_angular_distance", _key, "light_angular_distance", 0.0, 12.0, 0.05, "主光软硬：光源的角直径。阴天时太阳被云层扩散，相当于一个巨大的光源 → 阴影很软。")
	add_range("key.light_volumetric_fog_energy", _key, "light_volumetric_fog_energy", 0.0, 16.0, 0.01, "主光对体积雾的贡献：光束的亮度。")
	add_color("fill.light_color", _fill, "light_color", "补光颜色：通常与主光互补 (主光暖 → 补光冷)。")
	add_range("fill.light_energy", _fill, "light_energy", 0.0, 1.0, 0.005, "补光强度：一般为主光的 5%~20%。")
	add_color("rim.light_color", _rim, "light_color", "轮廓光颜色")
	add_range("rim.light_energy", _rim, "light_energy", 0.0, 2.0, 0.01, "轮廓光强度")

	group("Sky & Ambient 天空与环境光")
	add_color("sky.sky_top_color", _sky, "sky_top_color", "天顶颜色：同时决定来自上方的环境光颜色。")
	add_color("sky.sky_horizon_color", _sky, "sky_horizon_color", "地平线颜色：黄昏时偏橙红。")
	add_color("sky.ground_horizon_color", _sky, "ground_horizon_color", "地面地平线颜色")
	add_color("sky.ground_bottom_color", _sky, "ground_bottom_color", "地面底部颜色：来自下方的反弹环境光。")
	add_range("sky.sky_energy_multiplier", _sky, "sky_energy_multiplier", 0.0, 3.0, 0.01, "天空亮度：同时控制天空背景与环境光强度。")
	add_range("env.ambient_light_sky_contribution", _env, "ambient_light_sky_contribution", 0.0, 1.0, 0.01, "环境光强度 (天空贡献)：降低它让暗部更暗、光束和灯光更突出。")
	add_range("sdfgi.sdfgi_energy", _env, "sdfgi_energy", 0.0, 4.0, 0.01, "GI 强度：间接光的整体倍数。")

	group("Atmosphere 雾与体积雾")
	add_color("fog.fog_light_color", _env, "fog_light_color", "雾颜色")
	add_range("fog.fog_density", _env, "fog_density", 0.0, 0.1, 0.0005, "雾密度")
	add_range("fog.fog_sun_scatter", _env, "fog_sun_scatter", 0.0, 1.0, 0.01, "太阳散射：朝向太阳的雾更亮。")
	add_range("fog.fog_aerial_perspective", _env, "fog_aerial_perspective", 0.0, 1.0, 0.01, "大气透视：雾色取自天空。")
	add_range("fog.fog_height_density", _env, "fog_height_density", -1.0, 2.0, 0.01, "高度雾：>0 时低处更浓。")
	add_range("vfog.volumetric_fog_density", _env, "volumetric_fog_density", 0.0, 0.15, 0.0005, "体积雾密度")
	add_color("vfog.volumetric_fog_albedo", _env, "volumetric_fog_albedo", "体积雾散射色")
	add_color("vfog.volumetric_fog_emission", _env, "volumetric_fog_emission", "体积雾自发光")
	add_range("vfog.volumetric_fog_emission_energy", _env, "volumetric_fog_emission_energy", 0.0, 8.0, 0.01, "体积雾自发光强度")
	add_range("vfog.volumetric_fog_anisotropy", _env, "volumetric_fog_anisotropy", -0.9, 0.9, 0.01, "体积雾各向异性：越大越“迎光”，光束越明显。")

	group("Practical 实用光源")
	add_range("prac.lamp_energy", self, "lamp_energy", 0.0, 8.0, 0.01, "路灯强度：同时驱动灯泡自发光与 OmniLight。")
	add_color("prac.lamp_color", self, "lamp_color", "路灯颜色：钠灯橙、LED 冷白、病态的绿……")
	add_range("prac.lamps_lit", self, "lamps_lit", 0.0, 4.0, 1.0, "点亮的路灯数量")
	add_range("prac.flicker", self, "flicker", 0.0, 1.0, 0.01, "闪烁：用噪声调制灯光强度，并随机短暂熄灭。")
	add_range("prac.neon_energy", self, "neon_energy", 0.0, 12.0, 0.01, "霓虹强度：招牌自发光 + 彩色点光。")
	add_range("prac.window_emission", self, "window_emission", 0.0, 6.0, 0.01, "窗户自发光：只是材质发光 (不是真光源)，靠 GI 和辉光影响周围。")
	add_range("prac.interior_energy", self, "interior_energy", 0.0, 8.0, 0.01, "咖啡馆室内灯：带阴影的暖色点光，从门洞向外溢出。")

	group("Weather 天气与地面")
	add_range("weather.wetness", self, "wetness", 0.0, 1.0, 0.01, "湿度：降低地面粗糙度并加深颜色，同时显示积水。湿地面 + SSR 是雨夜氛围的关键。")
	add_range("weather.rain", self, "rain", 0.0, 1.0, 0.01, "雨量：GPUParticles3D 的 amount_ratio。")
	add_range("ssao.ssao_intensity", _env, "ssao_intensity", 0.0, 8.0, 0.01, "SSAO 强度：阴天时尤其重要。")

	group("Post 色调映射与后处理")
	add_enum("env.tonemap_mode", _env, "tonemap_mode", [["Linear", Environment.TONE_MAPPER_LINEAR], ["Reinhard", Environment.TONE_MAPPER_REINHARDT], ["Filmic", Environment.TONE_MAPPER_FILMIC], ["ACES", Environment.TONE_MAPPER_ACES], ["AgX", Environment.TONE_MAPPER_AGX]], "色调映射")
	add_range("env.tonemap_exposure", _env, "tonemap_exposure", 0.1, 4.0, 0.01, "曝光：夜景常把曝光调高，模拟人眼的暗适应。")
	add_range("glow.glow_intensity", _env, "glow_intensity", 0.0, 4.0, 0.01, "辉光强度")
	add_range("glow.glow_bloom", _env, "glow_bloom", 0.0, 0.5, 0.005, "Bloom：整体柔光")
	add_range("glow.glow_hdr_threshold", _env, "glow_hdr_threshold", 0.0, 3.0, 0.01, "辉光阈值：越低越多东西发光。")
	add_range("adj.adjustment_brightness", _env, "adjustment_brightness", 0.2, 2.0, 0.01, "亮度")
	add_range("adj.adjustment_contrast", _env, "adjustment_contrast", 0.5, 2.0, 0.01, "对比度")
	add_range("adj.adjustment_saturation", _env, "adjustment_saturation", 0.0, 2.0, 0.01, "饱和度：恐怖/阴天降低，霓虹提高。")
	add_range("post.vignette_strength", _post_mat, "shader_parameter/vignette_strength", 0.0, 1.5, 0.01, "暗角强度 (自定义 shader)：压暗画面四周，把视线引向中心。")
	add_range("post.vignette_radius", _post_mat, "shader_parameter/vignette_radius", 0.2, 1.5, 0.01, "暗角半径")
	add_range("post.grain_amount", _post_mat, "shader_parameter/grain_amount", 0.0, 0.5, 0.005, "胶片颗粒：逐帧变化的噪点，掩盖色带、增加质感。")
	add_range("post.chromatic_aberration", _post_mat, "shader_parameter/chromatic_aberration", 0.0, 4.0, 0.01, "色差：R/B 通道沿径向错开，模拟廉价镜头。")
	add_color("post.tint_color", _post_mat, "shader_parameter/tint_color", "色调颜色：整体乘一个颜色。")
	add_range("post.tint_strength", _post_mat, "shader_parameter/tint_strength", 0.0, 1.0, 0.01, "色调强度")
	add_color("post.lift_color", _post_mat, "shader_parameter/lift_color", "暗部提升颜色：把最暗的部分抬向这个颜色 (电影常用的“发灰的黑”)。")
	add_range("post.lift_strength", _post_mat, "shader_parameter/lift_strength", 0.0, 0.3, 0.005, "暗部提升强度")


func _after_init() -> void:
	_apply_layers()
	_apply_practical()
	_apply_weather()


func on_enter(_shell: Node) -> void:
	_apply_layers()


# --- Behaviour ------------------------------------------------------------------------

func _process(delta: float) -> void:
	_time += delta
	if flicker > 0.0:
		for i in _flicker_factor.size():
			var n := _noise.get_noise_1d(_time * 6.0 + i * 37.0)
			var dropout := _noise.get_noise_1d(_time * 2.3 + i * 91.0) < -0.55 * flicker
			_flicker_factor[i] = 0.04 if dropout else clampf(1.0 - flicker * 0.6 * (0.5 - 0.5 * n), 0.0, 1.0)
		_apply_practical()


func _all_layers_on() -> void:
	_applying = true
	for p in get_params():
		if String(p.key).begins_with("layer.") and p.type == "bool":
			write(p, true)
	_applying = false
	values_changed.emit()


func _aim_lights() -> void:
	if _key == null:
		return
	SceneKit.aim_light(_key, key_azimuth, key_elevation)
	SceneKit.aim_light(_fill, key_azimuth + 180.0, 25.0)


func _apply_layers() -> void:
	if _env == null or _post_rect == null:
		return
	_key.visible = layer_key
	_key.shadow_enabled = layer_shadows
	_fill.visible = layer_fill
	_rim.visible = layer_rim
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY if layer_sky_ambient else Environment.AMBIENT_SOURCE_DISABLED
	_env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY if layer_sky_ambient else Environment.REFLECTION_SOURCE_DISABLED
	_env.sdfgi_enabled = layer_gi
	_env.fog_enabled = layer_fog
	_env.volumetric_fog_enabled = layer_volumetric
	_env.ssao_enabled = layer_screen_space
	_env.ssr_enabled = layer_screen_space
	_env.glow_enabled = layer_post
	_env.adjustment_enabled = layer_post
	_post_rect.visible = layer_post
	_apply_practical()
	_apply_weather()


func _apply_practical() -> void:
	if _lamps.is_empty() or _interior_light == null:
		return
	for i in _lamps.size():
		var lamp: Dictionary = _lamps[i]
		var on := layer_practical and i < lamps_lit and lamp_energy > 0.001
		var factor: float = _flicker_factor[i] if flicker > 0.0 else 1.0
		var light: OmniLight3D = lamp.light
		var mat: StandardMaterial3D = lamp.mat
		light.visible = on
		light.light_color = lamp_color
		light.light_energy = lamp_energy * factor
		mat.emission_enabled = on
		mat.emission = lamp_color
		mat.emission_energy_multiplier = lamp_energy * 2.0 * factor
	for n in _neons:
		var on := layer_practical and neon_energy > 0.001
		(n.light as OmniLight3D).visible = on
		(n.light as OmniLight3D).light_energy = neon_energy * 0.5
		(n.mat as StandardMaterial3D).emission_enabled = on
		(n.mat as StandardMaterial3D).emission_energy_multiplier = neon_energy
	_window_mat.emission_enabled = layer_practical and window_emission > 0.001
	_window_mat.emission_energy_multiplier = window_emission
	_interior_light.visible = layer_practical and interior_energy > 0.001
	_interior_light.light_energy = interior_energy
	_interior_mat.emission_enabled = _interior_light.visible
	_interior_mat.emission_energy_multiplier = interior_energy * 1.5


func _apply_weather() -> void:
	if _ground_mat == null or _rain == null:
		return
	_ground_mat.roughness = lerpf(0.85, 0.12, wetness)
	_ground_mat.albedo_color = Color(0.42, 0.4, 0.38).darkened(0.45 * wetness)
	for p in _puddles:
		p.visible = layer_weather and wetness > 0.05
		var s := clampf(wetness, 0.3, 1.0)
		p.scale = Vector3(s, 1.0, s)
	_rain.visible = layer_weather and rain > 0.01
	_rain.emitting = _rain.visible and not validating
	_rain.amount_ratio = clampf(rain, 0.0, 1.0)


func _apply_blend() -> void:
	apply_state(blend_states(preset_state(recipe_a), preset_state(recipe_b), recipe_blend))


func _apply_time(t: float) -> void:
	var k := 0
	while k < DAY_KEYS.size() - 2 and t > float(DAY_KEYS[k + 1][0]):
		k += 1
	var t0: float = DAY_KEYS[k][0]
	var t1: float = DAY_KEYS[k + 1][0]
	var f := smoothstep(0.0, 1.0, clampf((t - t0) / maxf(t1 - t0, 0.001), 0.0, 1.0))
	var state := blend_states(preset_state(DAY_KEYS[k][1]), preset_state(DAY_KEYS[k + 1][1]), f)
	# Sun path between 5:00 and 19:00; outside that the night recipe's moon stays.
	if t >= 5.0 and t <= 19.0:
		var day := clampf((t - 6.0) / 12.0, 0.0, 1.0)
		state["key.azimuth"] = lerpf(80.0, 280.0, day)
		state["key.elevation"] = maxf(65.0 * sin(PI * day), 4.0)
	apply_state(state)
