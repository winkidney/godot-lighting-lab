extends RefCounted
## Helpers for building primitive-based reference scenes in code, so every
## module is self-contained and needs no imported assets.

static var _font: SystemFont


static func ui_font() -> Font:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray([
			"Noto Sans CJK SC", "Source Han Sans SC", "Droid Sans Fallback",
			"Microsoft YaHei", "PingFang SC", "sans-serif",
		])
		_font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	return _font


# --- Materials ---------------------------------------------------------------

static func mat(color: Color, roughness := 0.7, metallic := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m


static func emissive(color: Color, energy := 2.0) -> StandardMaterial3D:
	var m := mat(color.darkened(0.5), 0.5)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


static func checker_mat(a: Color, b: Color, scale: float, roughness := 0.85) -> StandardMaterial3D:
	var m := mat(Color.WHITE, roughness)
	m.albedo_texture = checker_texture(a, b)
	m.uv1_scale = Vector3(scale, scale, scale)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m


static func checker_texture(a: Color, b: Color, cells := 8, cell_px := 16) -> ImageTexture:
	var n := cells * cell_px
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in n:
		for x in n:
			var odd := ((x / cell_px) + (y / cell_px)) % 2 == 1
			img.set_pixel(x, y, b if odd else a)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# --- Geometry ----------------------------------------------------------------

static func mesh(parent: Node, m: Mesh, pos: Vector3, material: Material = null, node_name := "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	if material:
		mi.material_override = material
	mi.position = pos
	if node_name != "":
		mi.name = node_name
	parent.add_child(mi)
	return mi


static func box(parent: Node, size: Vector3, pos: Vector3, material: Material = null, node_name := "") -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	return mesh(parent, bm, pos, material, node_name)


static func sphere(parent: Node, radius: float, pos: Vector3, material: Material = null, segments := 48, node_name := "") -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = segments
	sm.rings = maxi(segments / 2, 4)
	return mesh(parent, sm, pos, material, node_name)


static func cylinder(parent: Node, radius: float, height: float, pos: Vector3, material: Material = null, node_name := "") -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	return mesh(parent, cm, pos, material, node_name)


## Horizontal plane facing +Y.
static func plane(parent: Node, size: Vector2, pos: Vector3, material: Material = null, node_name := "") -> MeshInstance3D:
	var pm := PlaneMesh.new()
	pm.size = size
	return mesh(parent, pm, pos, material, node_name)


static func label(parent: Node, text: String, pos: Vector3, font_size := 40, color := Color(0.92, 0.95, 1.0)) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = ui_font()
	l.font_size = font_size
	l.outline_size = 10
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.modulate = color
	l.pixel_size = 0.006
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.position = pos
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(l)
	return l


# --- Lights & environment ---------------------------------------------------

## Unit vector pointing from the scene towards the light.
## azimuth 0 = from +Z (camera side), 90 = from +X; elevation 90 = from above.
static func dir_from_angles(azimuth_deg: float, elevation_deg: float) -> Vector3:
	var az := deg_to_rad(azimuth_deg)
	var el := deg_to_rad(elevation_deg)
	return Vector3(cos(el) * sin(az), sin(el), cos(el) * cos(az))


static func aim_light(light: Node3D, azimuth_deg: float, elevation_deg: float) -> void:
	var forward := -dir_from_angles(azimuth_deg, elevation_deg)
	var up := Vector3.UP if absf(forward.dot(Vector3.UP)) < 0.999 else Vector3.FORWARD
	light.basis = Basis.looking_at(forward, up)


static func dir_light(parent: Node, node_name: String, azimuth: float, elevation: float, color := Color.WHITE, energy := 1.0, shadows := true) -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.name = node_name
	l.light_color = color
	l.light_energy = energy
	l.shadow_enabled = shadows
	parent.add_child(l)
	aim_light(l, azimuth, elevation)
	return l


static func omni_light(parent: Node, node_name: String, pos: Vector3, color: Color, energy: float, light_range: float, shadows := false) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.name = node_name
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	l.omni_range = light_range
	l.shadow_enabled = shadows
	parent.add_child(l)
	return l


static func make_environment(parent: Node, tonemap := Environment.TONE_MAPPER_FILMIC) -> WorldEnvironment:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.resource_name = "SkyMaterial"
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.resource_name = "Environment"
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = tonemap
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	parent.add_child(we)
	return we


## Approximate black-body colour (Tanner Helland fit), returned in sRGB.
static func kelvin_to_color(kelvin: float) -> Color:
	var t := clampf(kelvin, 1000.0, 40000.0) / 100.0
	var r: float
	var g: float
	var b: float
	if t <= 66.0:
		r = 255.0
		g = 99.4708025861 * log(t) - 161.1195681661
		b = 0.0 if t <= 19.0 else 138.5177312231 * log(t - 10.0) - 305.0447927307
	else:
		r = 329.698727446 * pow(t - 60.0, -0.1332047592)
		g = 288.1221695283 * pow(t - 60.0, -0.0755148492)
		b = 255.0
	return Color(clampf(r, 0.0, 255.0) / 255.0, clampf(g, 0.0, 255.0) / 255.0, clampf(b, 0.0, 255.0) / 255.0)
