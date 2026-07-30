class_name TerrainBuilder
extends RefCounted

## ============================================================================
## TerrainBuilder · Chunks de grilla regular + LODs + skirts (§4.1)
## ============================================================================
## Cada chunk: 1 MeshInstance3D por LOD con visibility_range + fade SELF.
## Vértices locales al centro del chunk; normales del sampler (idénticas entre
## LODs → sin saltos de sombreado). Skirt perimetral anti-costuras.
## ============================================================================


static func build(sampler: HeightSampler, settings: TerrainSettings,
		material: Material, frame_yield: Callable = Callable()) -> Node3D:
	var root := Node3D.new()
	root.name = "Terrain"
	var b := sampler.bounds
	var nx := int(ceilf(b.size.x / settings.chunk_size_m))
	var nz := int(ceilf(b.size.y / settings.chunk_size_m))
	for cz in nz:
		if frame_yield.is_valid():
			await frame_yield.call()  # una fila de chunks por frame: UI viva
		for cx in nx:
			var rect := Rect2(
					b.position + Vector2(cx, cz) * settings.chunk_size_m,
					Vector2(settings.chunk_size_m, settings.chunk_size_m))
			rect = rect.intersection(Rect2(b.position, b.size))
			if rect.size.x < 1.0 or rect.size.y < 1.0:
				continue
			var chunk := _build_chunk(sampler, settings, rect, material)
			chunk.name = "Chunk_%d_%d" % [cx, cz]
			root.add_child(chunk)
	return root


static func _build_chunk(sampler: HeightSampler, settings: TerrainSettings,
		rect: Rect2, material: Material) -> Node3D:
	var chunk := Node3D.new()
	var center := rect.get_center()
	chunk.position = Vector3(center.x, 0.0, center.y)
	var lod_count := settings.lod_steps_m.size()
	for lod in lod_count:
		var step := settings.lod_steps_m[lod]
		var mesh := _build_grid_mesh(sampler, rect, step,
				step * settings.skirt_depth_factor)
		var mi := MeshInstance3D.new()
		mi.name = "LOD%d" % lod
		mi.mesh = mesh
		mi.material_override = material
		var range_begin := 0.0 if lod == 0 else settings.lod_ranges_m[lod - 1]
		var range_end := 0.0
		if lod < settings.lod_ranges_m.size():
			range_end = settings.lod_ranges_m[lod]
		mi.visibility_range_begin = range_begin
		mi.visibility_range_end = range_end
		mi.visibility_range_begin_margin = 8.0 if lod > 0 else 0.0
		mi.visibility_range_end_margin = 8.0 if range_end > 0.0 else 0.0
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		chunk.add_child(mi)
	return chunk


## Grilla regular sobre rect (coordenadas locales al centro del rect) + skirt.
static func _build_grid_mesh(sampler: HeightSampler, rect: Rect2, step_m: float,
		skirt_m: float) -> ArrayMesh:
	var nx := maxi(int(roundf(rect.size.x / step_m)), 1)
	var nz := maxi(int(roundf(rect.size.y / step_m)), 1)
	var vx := nx + 1
	var vz := nz + 1
	var center := rect.get_center()
	var map_bounds := sampler.bounds

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(vx * vz)
	normals.resize(vx * vz)
	uvs.resize(vx * vz)

	for z in vz:
		for x in vx:
			var wpos := rect.position + Vector2(
					rect.size.x * float(x) / float(nx),
					rect.size.y * float(z) / float(nz))
			var h := sampler.get_height(wpos)
			var i := z * vx + x
			verts[i] = Vector3(wpos.x - center.x, h, wpos.y - center.y)
			normals[i] = sampler.get_normal(wpos)
			uvs[i] = Vector2((wpos.x - map_bounds.position.x) / map_bounds.size.x,
					(wpos.y - map_bounds.position.y) / map_bounds.size.y)

	# Winding: en Godot las caras frontales son horarias vistas desde el frente;
	# el orden anterior (i0,i2,i1) dejaba el terreno mirando HACIA ABAJO
	# (invisible desde arriba, visible desde abajo — reporte del usuario).
	var indices := PackedInt32Array()
	indices.resize(nx * nz * 6)
	var ii := 0
	for z in nz:
		for x in nx:
			var i0 := z * vx + x
			var i1 := i0 + 1
			var i2 := i0 + vx
			var i3 := i2 + 1
			indices[ii] = i0; indices[ii + 1] = i1; indices[ii + 2] = i2
			indices[ii + 3] = i1; indices[ii + 4] = i3; indices[ii + 5] = i2
			ii += 6

	# ---- Skirt: anillo perimetral duplicado hacia abajo ----
	var perimeter := PackedInt32Array()
	for x in vx:
		perimeter.append(x)                      # borde norte (z=0)
	for z in range(1, vz):
		perimeter.append(z * vx + (vx - 1))      # este
	for x in range(vx - 2, -1, -1):
		perimeter.append((vz - 1) * vx + x)      # sur
	for z in range(vz - 2, 0, -1):
		perimeter.append(z * vx)                 # oeste
	var base_count := verts.size()
	for k in perimeter.size():
		var src := perimeter[k]
		verts.append(verts[src] + Vector3(0, -skirt_m, 0))
		normals.append(normals[src])
		uvs.append(uvs[src])
	for k in perimeter.size():
		var a := perimeter[k]
		var b := perimeter[(k + 1) % perimeter.size()]
		var a2 := base_count + k
		var b2 := base_count + ((k + 1) % perimeter.size())
		indices.append(a); indices.append(b); indices.append(a2)
		indices.append(b); indices.append(b2); indices.append(a2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
