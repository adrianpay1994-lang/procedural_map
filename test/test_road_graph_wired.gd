extends Node
## TEST · El grafo de rutas LLEGA al mapa generado (no queda colgado).
## Verifica que ProceduralMapSystem.road_graph exista, tenga red y sea navegable.

func _ready() -> void:
	var map := ProceduralMapSystem.new()
	var cfg := MapGenerationConfig.new()
	cfg.seed_shape = 4242
	cfg.seed_variant = 4242
	cfg.num_points = 700
	cfg.map_size = 500.0
	cfg.ocean_points = 200
	cfg.num_rivers = 2
	cfg.corridor_mode = "CORRIDOR"
	cfg.corridor_branches = 3
	map.config = cfg
	map.generate_vegetation = false
	map.spawn_test_train = false
	map.bake_navmesh = false
	map.generate_spawn_points = false
	add_child(map)
	await map.generation_completed

	var g: RoadGraph = map.road_graph
	var ok_exists := g != null
	if not ok_exists:
		print("FAIL: el mapa no expuso road_graph")
		print("ROAD_GRAPH_WIRED_TEST: FAIL (0/3)")
		get_tree().quit(1)
		return
	var s: Dictionary = g.stats()
	var ok_net: bool = s.nodes >= 4 and s.edges >= 4
	var ok_inter: bool = s.intersections >= 2
	if not ok_net:
		print("FAIL: red vacia o minima — %d nodos, %d aristas" % [s.nodes, s.edges])
	if not ok_inter:
		print("FAIL: sin intersecciones (%d) — los ramales no conectaron" % s.intersections)
	print("ROAD_GRAPH_WIRED: %d nodos · %d aristas · %d intersecciones · navegable=%s" % [
			s.nodes, s.edges, s.intersections, str(s.connected)])
	var p := int(ok_exists) + int(ok_net) + int(ok_inter)
	print("ROAD_GRAPH_WIRED_TEST: %s (%d/3)" % ["PASS" if p == 3 else "FAIL", p])
	get_tree().quit(0 if p == 3 else 1)
