class_name EntitySpawnSystem
extends Node3D

## ============================================================================
## EntitySpawnSystem · Puebla el mundo según tablas + topología (§7, F6)
## ============================================================================
## Por cada BiomeSpawnEntry: pide posiciones a TopologyMap.find_positions()
## (máscaras de la PlacementRule), filtra por pendiente/altura/bioma con el
## sampler, y crea un ProceduralSpawner con SpawnProfile autogenerado.
## Determinista: rng derivado del seed del mapa.
## ============================================================================

@export var spawn_tables: Array[BiomeSpawnTable] = []
@export var global_max_entities: int = 300

var _spawners: Array[ProceduralSpawner] = []


func populate(map: ProceduralMapSystem) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([map.config.seed_variant, "entity_spawns"])
	var budget := global_max_entities
	for table in spawn_tables:
		if table == null:
			continue
		for entry in table.entries:
			if entry == null or entry.scene == null or budget <= 0:
				continue
			if not _validate_scene(entry):
				continue
			var rule := entry.rule if entry.rule != null else PlacementRule.new()
			var masks := rule.get_masks()
			var want := mini(entry.count, budget)
			var raw := map.topology.find_positions(masks.all, masks.any, masks["not"],
					want * 3, rule.min_spacing_m, rng)
			var transforms: Array[Transform3D] = []
			for pos in raw:
				if transforms.size() >= want:
					break
				var h: float = map.sampler.get_height(pos)
				if h < rule.min_height_m or h > rule.max_height_m:
					continue
				var slope: float = map.sampler.get_slope(pos)
				if slope < rule.min_slope or slope > rule.max_slope:
					continue
				if not rule.biome_filter.is_empty() \
						and not rule.biome_filter.has(map.data_provider.get_biome_at(pos)):
					continue
				var yaw := rng.randf() * TAU if entry.random_yaw else 0.0
				transforms.append(TerrainPlacer.get_placement_transform(
						map.sampler, pos, entry.align_to_terrain, yaw))
			if transforms.is_empty():
				continue
			budget -= transforms.size()
			var spawner := ProceduralSpawner.new()
			spawner.name = "Spawner_%s" % (entry.entry_name if entry.entry_name != &"" else table.table_name)
			var profile := SpawnProfile.new()
			profile.scene = entry.scene
			profile.max_alive = transforms.size()
			profile.spawn_on_start = true
			profile.interval = entry.respawn_interval
			spawner.profile = profile
			spawner.points = transforms
			add_child(spawner)
			_spawners.append(spawner)
			if entry.obj_id >= 0:
				map.register_spatial_object(entry.obj_id, spawner)


func get_active_entity_count() -> int:
	var n := 0
	for s in _spawners:
		n += s.alive_count()
	return n


func despawn_all() -> void:
	for s in _spawners:
		s.queue_free()
	_spawners.clear()


## Validación estilo LevelValidator (PortalSDK): nunca mesh cruda al mapa.
func _validate_scene(entry: BiomeSpawnEntry) -> bool:
	var path := entry.scene.resource_path
	if path.ends_with(".glb") or path.ends_with(".gltf") or path.ends_with(".obj"):
		push_error("EntitySpawnSystem: '%s' referencia un modelo crudo (%s). " % [entry.entry_name, path]
				+ "Usar siempre .tscn con la entidad completa.")
		return false
	return true
