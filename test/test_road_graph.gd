extends Node
## TEST · RoadGraph: la red de rutas como GRAFO NAVEGABLE.
## Un anillo con ramales debe dar intersecciones REALES donde los ramales tocan el
## anillo, y toda la red tiene que ser recorrible (si no, un vehículo queda encerrado).

var _pass := 0
var _fail := 0


func _ready() -> void:
	# Anillo + 2 ramales que salen y vuelven (lo que produce el generador).
	var n := 160
	var ring := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU
		ring.append(Vector2(cos(a), sin(a)) * 500.0)
	ring.append(ring[0])

	var g := RoadGraph.new()
	g.add_route(ring, RoadGraph.Kind.ROAD, true)
	var only_ring: Dictionary = g.stats()
	_check("anillo_solo_no_tiene_intersecciones", only_ring.intersections == 0,
			"intersecciones=%d (un anillo puro no bifurca)" % only_ring.intersections)

	for pair in [[10, 45], [80, 115]]:
		var br: PackedVector2Array = CorridorPlanner.branch_route(ring, pair[0], pair[1],
				Vector2.ZERO, 0.4)
		g.add_route(br, RoadGraph.Kind.ROAD, false)

	var s: Dictionary = g.stats()
	# Cada ramal aporta DOS intersecciones (donde nace y donde vuelve).
	_check("los_ramales_crean_intersecciones", s.intersections == 4,
			"intersecciones=%d (esperadas 4: 2 por ramal)" % s.intersections)
	_check("la_red_es_navegable", s.connected,
			"hay tramos sueltos: un vehiculo quedaria encerrado")
	_check("hay_aristas", s.edges >= 6, "aristas=%d" % s.edges)

	# Un pathfinder necesita vecinos con largo: se verifica que los devuelva.
	var inter: PackedInt32Array = g.intersections()
	if inter.size() > 0:
		var nb: Array = g.neighbors(inter[0])
		_check("una_interseccion_ofrece_3_salidas", nb.size() >= 3,
				"salidas=%d (por eso ES una interseccion)" % nb.size())
		var ok_len := true
		for e in nb:
			if float(e.length_m) <= 0.0:
				ok_len = false
		_check("las_salidas_traen_su_largo", ok_len, "hace falta para el pathfinding")

	_test_paths(g)

	print("ROAD_GRAPH: %d nodos · %d aristas · %d intersecciones · navegable=%s" % [
			s.nodes, s.edges, s.intersections, str(s.connected)])
	print("ROAD_GRAPH_TEST: %s (%d/%d)" % ["PASS" if _fail == 0 else "FAIL",
			_pass, _pass + _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(name: String, ok: bool, info: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s — %s" % [name, info])


## Pathfinding: sin esto el grafo es un dibujo con nombres. Un vehiculo tiene que
## poder ir de A a B y que el camino sea REALMENTE recorrible.
func _test_paths(g: RoadGraph) -> void:
	var a := g.nearest_node(Vector2(500, 0))
	var b := g.nearest_node(Vector2(-500, 0))
	var path: PackedInt32Array = g.find_path(a, b)
	_check("encuentra_camino_entre_puntos_opuestos", path.size() >= 2,
			"nodos en el camino=%d" % path.size())
	if path.size() >= 2:
		_check("el_camino_arranca_y_termina_donde_se_pidio",
				path[0] == a and path[path.size() - 1] == b, "")
		# Cada salto tiene que ser por una ARISTA real, no un teletransporte.
		var ok_real := true
		for i in range(1, path.size()):
			var found := false
			for nb in g.neighbors(path[i - 1]):
				if nb.node == path[i]:
					found = true
			if not found:
				ok_real = false
		_check("cada_salto_usa_una_arista_real", ok_real,
				"un salto sin arista seria un teletransporte")
		var l: float = g.path_length(path)
		_check("el_camino_tiene_largo_medible", l > 0.0, "largo=%.0f m" % l)
		print("ROAD_GRAPH: camino de %d nodos, %.0f m" % [path.size(), l])
