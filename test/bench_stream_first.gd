extends Node3D

## ============================================================================
## bench_stream_first.gd · Cuánto ahorra el streaming view-first (F1)
## ============================================================================
## Mide DIRECTO el costo de construir TODOS los chunks del mapa (TerrainBuilder),
## que es EXACTAMENTE lo que stream-first omite al arrancar. Genera un mapa,
## luego cronometra el build de chunks en aislamiento.
##   godot --headless --path . res://systems/procedural_map/test/bench_stream_first.tscn
## ============================================================================

func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_run()


func _run() -> void:
	var map := ProceduralMapSystem.new()
	var cfg := MapGenerationConfig.new()
	cfg.num_points = 2000
	cfg.map_size = 600.0
	cfg.ocean_points = 500
	cfg.ocean_distance = 300.0
	map.config = cfg
	map.terrain_settings = TerrainSettings.new()
	map.generate_vegetation = false
	map.spawn_test_train = false
	map.bake_navmesh = false
	map.generate_spawn_points = false
	add_child(map)
	await map.generation_completed

	# El heightfield/material ya están: medir SOLO construir los chunks (lo que
	# stream-first evita). Cronometrar el build en aislamiento.
	var t0 := Time.get_ticks_msec()
	var terrain: Node3D = await TerrainBuilder.build(
			map.sampler, map.terrain_settings, map.terrain_material, Callable())
	var t_chunks := Time.get_ticks_msec() - t0
	var nchunks := terrain.get_child_count()
	var nmesh := 0
	for c in terrain.get_children():
		nmesh += c.get_child_count()
	terrain.queue_free()

	print("BENCH_STREAM_FIRST: chunks=%d meshes=%d build_ms=%d  (stream-first omite TODO esto en la carga)"
			% [nchunks, nmesh, t_chunks])
	get_tree().quit(0)
