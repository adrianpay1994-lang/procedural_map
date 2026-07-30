class_name POISystem
extends Node3D

## ============================================================================
## POISystem · Monumentos en dos tiempos (§7.6, F7)
## ============================================================================
## plan(): elige sitios con la topología hidrológica del bake v1 y devuelve
## los FlattenHeightLayers a inyectar ANTES del bake v2.
## apply_modifiers(): post-bake — pinta splat, estampa MONUMENT, registra
## radios de limpieza. place(): instancia las escenas sobre la plataforma.
## ============================================================================

@export var poi_definitions: Array[POIDefinition] = []

## Sitios elegidos por plan(): [{def, pos, target_h}].
var planned: Array[Dictionary] = []


func plan(map: ProceduralMapSystem, rng: RandomNumberGenerator) -> Array[HeightLayer]:
	planned.clear()
	var out: Array[HeightLayer] = []
	var taken: Array[Vector2] = []
	for def in poi_definitions:
		if def == null or def.scene == null:
			continue
		var mods := def.modifiers if def.modifiers != null else TerrainModifierSet.new()
		var placed := 0
		var candidates := map.topology.find_positions(
				TopologyMap.TOPO_MAINLAND, 0,
				TopologyMap.TOPO_OCEAN | TopologyMap.TOPO_LAKE | TopologyMap.TOPO_RIVER
				| TopologyMap.TOPO_RIVERSIDE  # la plataforma (Ø50 m) enterraba ríos cercanos
				| TopologyMap.TOPO_CLIFF | TopologyMap.TOPO_MONUMENT,
				def.count * 20, def.min_distance_between_pois_m * 0.5, rng)
		for pos in candidates:
			if placed >= def.count:
				break
			var h: float = map.sampler.get_height(pos)
			if h < def.min_height_m or h > def.max_height_m:
				continue
			if map.sampler.get_slope(pos) > def.max_site_slope:
				continue
			if not def.allowed_biomes.is_empty() \
					and not def.allowed_biomes.has(map.data_provider.get_biome_at(pos)):
				continue
			var ok := true
			for t in taken:
				if t.distance_to(pos) < def.min_distance_between_pois_m:
					ok = false
					break
			if not ok:
				continue
			# Distancia REAL a los ríos: la FALDA de la plataforma (radio +
			# falloff) no puede tapar una zanja (forense: poi_flatten +6.1
			# sobre el lecho aunque el centro estaba fuera de RIVERSIDE).
			var clear_r := mods.flatten_radius_m + mods.flatten_falloff_m
			if def.terrain_stamp != null:
				clear_r = maxf(clear_r,
						def.terrain_stamp.radius_m + def.terrain_stamp.falloff_m)
			var near_river := false
			for l in map.sampler.layers:
				var rl := l as PathCarveLayer
				if rl != null and rl.layer_name == &"river_carve" \
						and MapDataProvider._min_dist_to_polyline(pos, rl.points) \
						< clear_r + rl.width_m:
					near_river = true
					break
			if near_river:
				continue
			taken.append(pos)
			placed += 1
			var target := h + mods.height_offset_m
			planned.append({"def": def, "pos": pos, "target_h": target})
			if def.terrain_stamp != null:
				# §F5: el monumento impone su PERFIL (TerrainStamp §F2) en vez
				# de la plataforma plana; rotación determinista por seed.
				var st := TerrainStampLayer.new()
				st.layer_name = &"poi_stamp"
				st.stamp = def.terrain_stamp
				st.position = pos
				st.rotation_deg = rng.randf_range(-180.0, 180.0)
				out.append(st)
			elif mods.flatten:
				var layer := FlattenHeightLayer.new()
				layer.layer_name = &"poi_flatten"
				layer.target_height_m = target
				var m := CircleMask.new()
				m.center = pos
				m.radius_m = mods.flatten_radius_m
				m.falloff_m = mods.flatten_falloff_m
				layer.mask = m
				out.append(layer)
	return out


## Post-bake: splat + topología + limpieza (la vegetación/spawning respetan MONUMENT).
func apply_modifiers(map: ProceduralMapSystem) -> void:
	for site in planned:
		var def: POIDefinition = site.def
		var mods := def.modifiers if def.modifiers != null else TerrainModifierSet.new()
		var pos: Vector2 = site.pos
		map.topology.stamp_disc(pos, mods.topology_radius_m, TopologyMap.TOPO_MONUMENT)
		if mods.paint_splat and map.splat != null:
			map.splat.paint_disc(pos, mods.splat_radius_m, mods.splat_ground)


## Instancia los monumentos sobre la plataforma nivelada.
func place(map: ProceduralMapSystem) -> void:
	var i := 0
	for site in planned:
		var def: POIDefinition = site.def
		var inst := def.scene.instantiate()
		add_child(inst)
		if inst is Node3D:
			var pos: Vector2 = site.pos
			(inst as Node3D).global_transform = TerrainPlacer.get_placement_transform(
					map.sampler, pos, def.align_to_terrain)
		if def.obj_id >= 0:
			map.register_spatial_object(def.obj_id + i, inst)
		i += 1


func get_placed_pois() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for c in get_children():
		if c is Node3D:
			out.append(c)
	return out
