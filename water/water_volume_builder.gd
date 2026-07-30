class_name WaterVolumeBuilder
extends RefCounted

## ============================================================================
## WaterVolumeBuilder · ProceduralWaterVolume automáticos (§6)
## ============================================================================
## Océano: una caja que cubre todo el mar. Lagos: caja por celda. Ríos: cadena
## de cajas orientadas a lo largo de la polilínea. Cada volumen conoce su
## superficie (surface_world_y) — nado del Player + buoyancy de rígidos.
## ============================================================================


static func build(sampler: HeightSampler, provider: MapDataProvider,
		_config: MapGenerationConfig, sea_level: float,
		sea_mask: SeaMask = null) -> Node3D:
	var root := Node3D.new()
	root.name = "WaterVolumes"

	# ---- Océano ----
	var b := sampler.bounds
	if sea_mask != null:
		# FIX "traspaso el suelo, caigo al agua": el volumen de nado cubre SOLO
		# las celdas de mar reales (SeaMask). La caja global anterior abarcaba
		# TODO el mapa hasta cota 0 → el jugador "nadaba" en tierra seca bajo
		# el nivel del mar (depresiones interiores, lechos) y el suelo dejaba
		# de sostenerlo. Un solo volumen, una caja por rectángulo de mar.
		var ocean := ProceduralWaterVolume.new()
		ocean.name = "WaterVol_ocean"
		ocean.surface_world_y = sea_level
		for r in sea_mask.sea_rects():
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(r.size.x, 30.0, r.size.y)
			cs.shape = box
			cs.position = Vector3(r.get_center().x, sea_level - 15.0, r.get_center().y)
			ocean.add_child(cs)
		root.add_child(ocean)
	else:
		# Sin SeaMask (llamadas viejas): caja global de siempre.
		root.add_child(_make_box_volume("WaterVol_ocean",
				Vector3(b.get_center().x, sea_level - 15.0, b.get_center().y),
				Vector3(b.size.x, 30.0, b.size.y), sea_level))

	# ---- Lagos (agua repuesta): caja por cuenco ----
	var li := 0
	for lake in provider.lakes:
		if lake.get("frozen", false):
			li += 1
			continue  # hielo: se camina encima, no se nada adentro
		var poly: PackedVector2Array = lake.polygon
		var aabb := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			aabb = aabb.expand(p)
		var water_y: float = lake.water_y
		root.add_child(_make_box_volume("WaterVol_lake_%d" % li,
				Vector3(aabb.get_center().x, water_y - 1.5, aabb.get_center().y),
				Vector3(aabb.size.x, 3.0, aabb.size.y), water_y))
		li += 1

	# ---- Ríos (agua repuesta): cadena de cajas siguiendo el lecho ----
	var ri := 0
	for l in sampler.layers:
		var pl := l as PathCarveLayer
		if pl == null or pl.layer_name != &"river_carve" \
				or pl.target_heights.size() != pl.points.size():
			continue
		var stride := 6
		for i in range(0, pl.points.size() - stride, stride):
			var a := pl.points[i]
			var c := pl.points[mini(i + stride, pl.points.size() - 1)]
			var mid := (a + c) * 0.5
			var j := mini(i + stride, pl.points.size() - 1)
			var water_y2: float
			if pl.water_levels.size() == pl.points.size():
				water_y2 = (pl.water_levels[i] + pl.water_levels[j]) * 0.5
			else:
				water_y2 = (pl.target_heights[i] + pl.target_heights[j]) * 0.5 \
						+ WaterBuilder.WATER_DEPTH_M
			var vol := _make_box_volume("WaterVol_river_%d_%d" % [ri, i],
					Vector3(mid.x, water_y2 - 1.2, mid.y),
					Vector3(a.distance_to(c) + 3.0, 2.4, pl.width_m + 2.0), water_y2)
			vol.rotation.y = -(c - a).angle()
			root.add_child(vol)
		ri += 1
	return root


static func _make_box_volume(vol_name: String, center: Vector3, size: Vector3,
		surface_y: float) -> ProceduralWaterVolume:
	var vol := ProceduralWaterVolume.new()
	vol.name = vol_name
	vol.surface_world_y = surface_y
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	vol.add_child(cs)
	vol.position = center
	return vol
