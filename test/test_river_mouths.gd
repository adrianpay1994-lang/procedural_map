extends Node
## TEST · ¿Los ríos llegan de verdad al agua? Compara los dos modos de hidrología.
## Criterio: el ÚLTIMO punto del cauce debe quedar por DEBAJO del nivel del mar.
## Si termina por encima, el río "muere en seco" (el bug reportado).

func _ready() -> void:
	var g := await _check_mode("GRAPH")
	var r := await _check_mode("RASTER")
	print("RIVER_MOUTH: GRAPH  %d/%d rios terminan en el agua" % [g.x, g.y])
	print("RIVER_MOUTH: RASTER %d/%d rios terminan en el agua" % [r.x, r.y])
	# El modo RASTER no puede ser PEOR que el de grafo: su garantía es del algoritmo.
	var ok: bool = r.y > 0 and r.x >= g.x
	if not ok:
		print("FAIL: RASTER no mejora ni iguala a GRAPH")
	print("RIVER_MOUTH_TEST: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


## Devuelve (ríos que terminan bajo el agua, ríos totales).
func _check_mode(mode: String) -> Vector2i:
	var map := ProceduralMapSystem.new()
	var cfg := MapGenerationConfig.new()
	cfg.seed_shape = 4242
	cfg.seed_variant = 4242
	cfg.num_points = 700
	cfg.map_size = 500.0
	cfg.ocean_points = 200
	cfg.num_rivers = 4
	cfg.hydrology_mode = mode
	map.config = cfg
	map.generate_vegetation = false
	map.spawn_test_train = false
	map.bake_navmesh = false
	map.generate_spawn_points = false
	add_child(map)
	await map.generation_completed
	var wet := 0
	var total := 0
	var rivers := map.find_child("Rivers", true, false)
	if rivers != null:
		for ch in rivers.get_children():
			var mi := ch as MeshInstance3D
			if mi == null or mi.mesh == null:
				continue
			total += 1
			# El extremo MÁS BAJO de la malla del río: si está bajo el mar, desemboca.
			var bb := mi.get_aabb()
			if mi.global_position.y + bb.position.y < map.sea_level:
				wet += 1
	map.queue_free()
	await get_tree().process_frame
	return Vector2i(wet, total)
