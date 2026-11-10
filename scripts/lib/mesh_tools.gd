extends RefCounted
## Mesh rebuilding helpers used to show how vertex normals and tangents
## change shading: flat vs smooth normals, and missing / flipped tangents.


## Rebuilds normals with SurfaceTool. flat=true gives every triangle its own
## face normal (smooth group -1). flat=false averages the normals of every
## vertex sharing a position (smooth group 0) — even across hard edges and UV
## seams, which is exactly the "wrong smoothing" artefact on a cube.
static func recompute_normals(src: Mesh, flat: bool) -> ArrayMesh:
	var arrays := src.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs := PackedVector2Array()
	if arrays[Mesh.ARRAY_TEX_UV] != null:
		uvs = arrays[Mesh.ARRAY_TEX_UV]
	var indices := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		indices = arrays[Mesh.ARRAY_INDEX]
	else:
		indices = PackedInt32Array(range(verts.size()))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1 if flat else 0)
	for i in indices:
		if not uvs.is_empty():
			st.set_uv(uvs[i])
		st.add_vertex(verts[i])
	st.generate_normals()
	if not uvs.is_empty():
		st.generate_tangents()
	return st.commit()


## mode 0 = keep generated tangents, 1 = strip tangents, 2 = flip handedness (w).
static func with_tangent_mode(src: Mesh, mode: int) -> Mesh:
	if mode == 0:
		return src
	var arrays := src.surface_get_arrays(0)
	if mode == 1:
		arrays[Mesh.ARRAY_TANGENT] = null
	else:
		var t: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		for i in range(3, t.size(), 4):
			t[i] = -t[i]
		arrays[Mesh.ARRAY_TANGENT] = t
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am
