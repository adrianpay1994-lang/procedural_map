class_name TerrainColliderBuilder
extends RefCounted

## ============================================================================
## TerrainColliderBuilder · HeightmapShape3D por chunk (§4.2)
## ============================================================================
## Muestrea el MISMO campo bakeado que la mesh → coincidencia física/visual.
## Chunks 100% océano profundo no generan collider (el jugador nada).
## collider_step_m = 1.0 ⇒ sin escalado del shape (evita casos raros de Jolt).
## ============================================================================


static func build(sampler: HeightSampler, settings: TerrainSettings,
		sea_level: float, fallback_surface: StringName = &"grass",
		frame_yield: Callable = Callable(), sea_mask: SeaMask = null) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "TerrainCollider"
	body.collision_layer = 1  # layer_1 = "world" (project.godot)
	body.collision_mask = 0
	body.set_meta("surface", fallback_surface)
	var b := sampler.bounds
	var nx := int(ceilf(b.size.x / settings.chunk_size_m))
	var nz := int(ceilf(b.size.y / settings.chunk_size_m))
	var step := settings.collider_step_m
	for cz in nz:
		if frame_yield.is_valid():
			await frame_yield.call()
		for cx in nx:
			var rect := Rect2(
					b.position + Vector2(cx, cz) * settings.chunk_size_m,
					Vector2(settings.chunk_size_m, settings.chunk_size_m))
			rect = rect.intersection(Rect2(b.position, b.size))
			if rect.size.x < step or rect.size.y < step:
				continue
			var shape := _chunk_shape(sampler, rect, step, sea_level, sea_mask)
			if shape == null:
				continue  # océano profundo REAL (conectado al borde del mapa)
			var cs := CollisionShape3D.new()
			cs.name = "ChunkShape_%d_%d" % [cx, cz]
			cs.shape = shape
			var center := rect.get_center()
			cs.position = Vector3(center.x, 0.0, center.y)
			cs.set_meta("surface", fallback_surface)
			body.add_child(cs)
	return body


## `sampler` se usa SOLO por get_height(Vector2) → acepta HeightSampler o
## RegionStreamSampler (duck-typed) para F1b.6 (colisión desde tiles de región).
static func _chunk_shape(sampler, rect: Rect2, step: float,
		sea_level: float, sea_mask: SeaMask = null) -> HeightMapShape3D:
	var w := int(roundf(rect.size.x / step)) + 1
	var d := int(roundf(rect.size.y / step)) + 1
	var data := PackedFloat32Array()
	data.resize(w * d)
	var all_deep := true
	for z in d:
		var wz := rect.position.y + rect.size.y * float(z) / float(d - 1)
		for x in w:
			var wx := rect.position.x + rect.size.x * float(x) / float(w - 1)
			var h: float = sampler.get_height(Vector2(wx, wz))
			data[z * w + x] = h
			if h > sea_level - 2.0:
				all_deep = false
			elif sea_mask != null and not sea_mask.is_sea(Vector2(wx, wz)):
				all_deep = false  # depresión interior: hondo pero NO es mar → collider SÍ
	if all_deep:
		return null
	var shape := HeightMapShape3D.new()
	shape.map_width = w
	shape.map_depth = d
	shape.map_data = data
	return shape
