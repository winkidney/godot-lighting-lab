extends RefCounted
## CPU-generated textures: tileable height maps, tangent-space normal maps
## (via a Sobel filter), spot-light cookies and colour-grading LUTs.
## Everything is cached, so each texture is only computed once per run.

const SIZE := 512
## Height-map kinds, in the order used by the UI enums.
const KINDS := ["bricks", "rivets", "waves", "noise"]
## Sobel gain per kind: how strongly height slopes turn into normal tilt.
const STRENGTH := {"bricks": 3.0, "rivets": 5.0, "waves": 10.0, "noise": 14.0}

static var _cache: Dictionary = {}


## Drop cached GPU textures (called on exit so no RIDs outlive the renderer).
static func clear_cache() -> void:
	_cache.clear()


static func heights(kind: String) -> PackedFloat32Array:
	var key := "h_" + kind
	if _cache.has(key):
		return _cache[key]
	var h := PackedFloat32Array()
	h.resize(SIZE * SIZE)
	match kind:
		"bricks":
			_bricks(h)
		"rivets":
			_rivets(h)
		"waves":
			_waves(h)
		_:
			_noise(h, 0.0, 1.0)
	_cache[key] = h
	return h


static func height_texture(kind: String) -> ImageTexture:
	var key := "ht_" + kind
	if _cache.has(key):
		return _cache[key]
	var h := heights(kind)
	var data := PackedByteArray()
	data.resize(SIZE * SIZE)
	for i in h.size():
		data[i] = int(clampf(h[i], 0.0, 1.0) * 255.0)
	var img := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_L8, data)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


## Tangent-space normal map in the OpenGL convention (green = +Y = "up" in the
## texture), which is what Godot expects. directx=true flips green.
static func normal_texture(kind: String, directx := false) -> ImageTexture:
	var key := "n_%s_%s" % [kind, directx]
	if _cache.has(key):
		return _cache[key]
	var h := heights(kind)
	var s: float = STRENGTH.get(kind, 4.0)
	var n := SIZE
	var data := PackedByteArray()
	data.resize(n * n * 3)
	for y in n:
		var r0 := ((y - 1 + n) % n) * n
		var r1 := y * n
		var r2 := ((y + 1) % n) * n
		for x in n:
			var x0 := (x - 1 + n) % n
			var x2 := (x + 1) % n
			var tl := h[r0 + x0]
			var t := h[r0 + x]
			var tr := h[r0 + x2]
			var l := h[r1 + x0]
			var r := h[r1 + x2]
			var bl := h[r2 + x0]
			var b := h[r2 + x]
			var br := h[r2 + x2]
			# Sobel gradients in image space (x right, y down).
			var dx := (tr + 2.0 * r + br) - (tl + 2.0 * l + bl)
			var dy := (bl + 2.0 * b + br) - (tl + 2.0 * t + tr)
			# Normal tilts away from the uphill direction. Image y points down,
			# texture "up" (+green in OpenGL) is -y, hence +dy for green.
			var nv := Vector3(-dx * s, dy * s, 1.0).normalized()
			if directx:
				nv.y = -nv.y
			var i := (r1 + x) * 3
			data[i] = int((nv.x * 0.5 + 0.5) * 255.0)
			data[i + 1] = int((nv.y * 0.5 + 0.5) * 255.0)
			data[i + 2] = int((nv.z * 0.5 + 0.5) * 255.0)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGB8, data)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


# --- Height generators (all tileable) ---------------------------------------

static func _bricks(h: PackedFloat32Array) -> void:
	var bw := SIZE / 4
	var bh := SIZE / 8
	var mortar := 5.0
	var bevel := 12.0
	var grain := _noise_array(7, 0.08)
	for y in SIZE:
		var row := y / bh
		var offset := (row % 2) * (bw / 2)
		var ly := y % bh
		for x in SIZE:
			var lx := (x + offset) % bw
			var d := float(mini(mini(lx, bw - 1 - lx), mini(ly, bh - 1 - ly))) - mortar
			var brick_id := row * 7 + (x + offset) / bw
			var v: float
			if d < 0.0:
				v = 0.08
			else:
				v = 0.55 + 0.35 * smoothstep(0.0, bevel, d) + 0.04 * sin(float(brick_id) * 12.9898)
			h[y * SIZE + x] = clampf(v + grain[y * SIZE + x] * (0.3 if d < 0.0 else 1.0), 0.0, 1.0)


static func _rivets(h: PackedFloat32Array) -> void:
	var cell := 64
	var radius := 9.0
	var panel := SIZE / 2
	for y in SIZE:
		for x in SIZE:
			var v := 0.45
			# Panel seams: a groove every half texture.
			var sx := mini(x % panel, panel - x % panel)
			var sy := mini(y % panel, panel - y % panel)
			var seam := float(mini(sx, sy))
			if seam < 4.0:
				v = 0.2 + 0.25 * seam / 4.0
			# Domed rivets on a grid offset by half a cell.
			var cx := float((x % cell) - cell / 2)
			var cy := float((y % cell) - cell / 2)
			var d := sqrt(cx * cx + cy * cy)
			if d < radius:
				v = maxf(v, 0.45 + 0.5 * sqrt(1.0 - (d / radius) * (d / radius)))
			h[y * SIZE + x] = v


static func _waves(h: PackedFloat32Array) -> void:
	var f := TAU * 4.0 / float(SIZE)
	for y in SIZE:
		for x in SIZE:
			h[y * SIZE + x] = 0.5 + 0.25 * (sin(float(x) * f) + sin(float(y) * f))


static func _noise(h: PackedFloat32Array, _a: float, _b: float) -> void:
	var arr := _noise_array(3, 1.0)
	for i in h.size():
		h[i] = 0.5 + arr[i] * 0.5


## Seamless value in [-amp, amp] per pixel.
static func _noise_array(seed_value: int, amp: float) -> PackedFloat32Array:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	var img := noise.get_seamless_image(SIZE, SIZE, false, false, 0.1, true)
	img.convert(Image.FORMAT_L8)
	var bytes := img.get_data()
	var out := PackedFloat32Array()
	out.resize(SIZE * SIZE)
	for i in out.size():
		out[i] = (float(bytes[i]) / 255.0 * 2.0 - 1.0) * amp
	return out


# --- Spot-light cookies ------------------------------------------------------

const COOKIES := ["none", "window", "dots", "blinds"]


static func cookie(kind: String) -> Texture2D:
	if kind == "none":
		return null
	var key := "c_" + kind
	if _cache.has(key):
		return _cache[key]
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in n:
		for x in n:
			var u := float(x) / n
			var v := float(y) / n
			var c := 1.0
			match kind:
				"window":
					var frame := 0.06
					var bar := 0.025
					if u < frame or u > 1.0 - frame or v < frame or v > 1.0 - frame:
						c = 0.0
					elif absf(u - 0.5) < bar or absf(v - 0.5) < bar:
						c = 0.0
				"dots":
					var cu := fmod(u * 6.0, 1.0) - 0.5
					var cv := fmod(v * 6.0, 1.0) - 0.5
					c = 1.0 - smoothstep(0.25, 0.32, sqrt(cu * cu + cv * cv))
				"blinds":
					c = smoothstep(0.35, 0.45, absf(fmod(v * 9.0, 1.0) - 0.5))
			# Soft circular falloff so the cookie edge isn't a hard square.
			var r := Vector2(u - 0.5, v - 0.5).length()
			c *= 1.0 - smoothstep(0.42, 0.5, r)
			img.set_pixel(x, y, Color(c, c, c))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


# --- Colour-grading LUTs ----------------------------------------------------

const LUTS := ["none", "warm", "cool", "contrast", "teal_orange"]


## GradientTexture1D = per-channel curve; ImageTexture3D = full 3D LUT.
static func lut(kind: String) -> Texture:
	if kind == "none":
		return null
	var key := "lut_" + kind
	if _cache.has(key):
		return _cache[key]
	var tex: Texture
	match kind:
		"warm":
			tex = _gradient_lut([0.0, 0.5, 1.0], [Color(0.02, 0.0, 0.0), Color(0.58, 0.5, 0.42), Color(1.0, 0.97, 0.86)])
		"cool":
			tex = _gradient_lut([0.0, 0.5, 1.0], [Color(0.0, 0.02, 0.06), Color(0.44, 0.5, 0.58), Color(0.9, 0.97, 1.0)])
		"contrast":
			tex = _gradient_lut([0.0, 0.25, 0.75, 1.0], [Color.BLACK, Color(0.12, 0.12, 0.12), Color(0.88, 0.88, 0.88), Color.WHITE])
		_:
			tex = _teal_orange_lut()
	_cache[key] = tex
	return tex


static func _gradient_lut(offsets: Array, colors: Array) -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	var t := GradientTexture1D.new()
	t.gradient = g
	t.width = 256
	return t


static func _teal_orange_lut() -> ImageTexture3D:
	var n := 17
	var teal := Vector3(0.0, 0.42, 0.48)
	var orange := Vector3(1.0, 0.62, 0.32)
	var images: Array[Image] = []
	for bz in n:
		var img := Image.create(n, n, false, Image.FORMAT_RGB8)
		for gy in n:
			for rx in n:
				var c := Vector3(rx, gy, bz) / float(n - 1)
				var lum := c.dot(Vector3(0.2126, 0.7152, 0.0722))
				var tint := teal.lerp(orange, smoothstep(0.15, 0.85, lum))
				var graded := c.lerp(tint * (lum / maxf(tint.dot(Vector3(0.2126, 0.7152, 0.0722)), 0.001)), 0.35)
				img.set_pixel(rx, gy, Color(clampf(graded.x, 0, 1), clampf(graded.y, 0, 1), clampf(graded.z, 0, 1)))
		images.append(img)
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RGB8, n, n, n, false, images)
	return tex
