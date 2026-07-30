class_name RoadGraph
extends RefCounted

## ============================================================================
## RoadGraph · La red de rutas como GRAFO NAVEGABLE (no solo geometría)
## ============================================================================
## Lección de `godot-road-generator` (ver AUDITORIA §9): sus rutas son
## `road_point` / `road_intersection` / `road_lane` / `road_lane_agent`. Las
## nuestras eran **geometría esculpida** — una zanja aplanada en el terreno.
##
## Sin grafo hay un DIBUJO de carretera: un vehículo o un NPC no puede saber por
## dónde va la calzada, dónde puede doblar, ni cómo llegar de A a B. Con grafo, sí.
##
## Estructura:
##   NODOS   puntos de la red. Los que tienen 3+ conexiones son INTERSECCIONES.
##   ARISTAS tramos entre nodos, con su polilínea, largo y tipo (road/rail).
##
## Se construye a partir de lo que el generador YA produce: el anillo del corredor,
## y los ramales. Las intersecciones salen solas de donde los ramales tocan el
## anillo — no hay que buscarlas aparte.
## ============================================================================

enum Kind { ROAD, RAIL }

## Nodos: posición en XZ.
var nodes: Array[Vector2] = []
## Aristas: {a, b, points, length_m, kind}
var edges: Array[Dictionary] = []

## Distancia (m) bajo la cual dos puntos se consideran el MISMO nodo. Sin esto la
## boca de un ramal y el punto del anillo quedan como nodos separados y el grafo
## no conecta.
const WELD_M := 8.0


## Devuelve el índice del nodo en esa posición, creándolo si no existe cerca.
func node_at(p: Vector2) -> int:
	for i in nodes.size():
		if nodes[i].distance_squared_to(p) <= WELD_M * WELD_M:
			return i
	nodes.append(p)
	var idx := nodes.size() - 1
	# CLAVE: si el punto cae SOBRE una arista ya existente (p. ej. la boca de un
	# ramal aterrizando en el medio del anillo), hay que PARTIR esa arista en dos.
	# Sin esto el nodo queda suelto y la red no conecta — el ramal seria un tramo
	# aislado en vez de una salida del circuito.
	_split_edges_at(idx)
	return idx


## Parte toda arista cuya polilinea pase por el nodo `idx`.
func _split_edges_at(idx: int) -> void:
	var p: Vector2 = nodes[idx]
	var k := 0
	while k < edges.size():
		var e: Dictionary = edges[k]
		if e.a == idx or e.b == idx:
			k += 1
			continue
		var pts: PackedVector2Array = e.points
		var cut := -1
		for i in pts.size():
			if pts[i].distance_squared_to(p) <= WELD_M * WELD_M:
				cut = i
				break
		# No partir en los extremos (ahi ya hay nodo) ni si no toca.
		if cut <= 0 or cut >= pts.size() - 1:
			k += 1
			continue
		var first := pts.slice(0, cut + 1)
		var second := pts.slice(cut)
		edges[k] = {a = e.a, b = idx, points = first,
				length_m = _poly_len(first), kind = e.kind}
		edges.append({a = idx, b = e.b, points = second,
				length_m = _poly_len(second), kind = e.kind})
		k += 1


static func _poly_len(pts: PackedVector2Array) -> float:
	var l := 0.0
	for i in range(1, pts.size()):
		l += pts[i].distance_to(pts[i - 1])
	return l


## Agrega una ruta (polilínea) al grafo, partiéndola en los puntos donde toca
## nodos ya existentes: así un ramal que nace y muere sobre el anillo genera
## automáticamente DOS intersecciones y parte el anillo en tramos.
func add_route(points: PackedVector2Array, kind: Kind, closed: bool = false) -> void:
	if points.size() < 2:
		return
	# Un anillo CERRADO con un solo nodo no genera ninguna arista (inicio y fin son
	# el mismo nodo, y el tramo se descarta por a==b). Se siembra un nodo en la
	# mitad para que la vuelta queden DOS arcos — medido: sin esto el grafo salia
	# con 0 aristas del anillo.
	var start := node_at(points[0])
	if closed and points.size() > 4:
		node_at(points[points.size() / 2])
	var prev_node := start
	var acc := PackedVector2Array([points[0]])
	var length := 0.0
	for i in range(1, points.size()):
		acc.append(points[i])
		length += points[i].distance_to(points[i - 1])
		# ¿Este punto cae sobre un nodo YA existente (que no sea el ultimo usado)?
		var hit := _existing_node(points[i], prev_node)
		var last := i == points.size() - 1
		if hit >= 0 or last:
			var end_node := hit if hit >= 0 else node_at(points[i])
			if end_node != prev_node and acc.size() >= 2:
				edges.append({a = prev_node, b = end_node, points = acc.duplicate(),
						length_m = length, kind = kind})
			prev_node = end_node
			acc = PackedVector2Array([points[i]])
			length = 0.0
	if closed and prev_node != start and acc.size() >= 2:
		edges.append({a = prev_node, b = start, points = acc, length_m = length,
				kind = kind})


## Nodo existente en esa posición (o -1). No cuenta `skip` para no cortar el tramo
## en el nodo del que se acaba de salir.
func _existing_node(p: Vector2, skip: int) -> int:
	for i in nodes.size():
		if i != skip and nodes[i].distance_squared_to(p) <= WELD_M * WELD_M:
			return i
	return -1


## Cuántas aristas tocan cada nodo.
func degree(node_i: int) -> int:
	var d := 0
	for e in edges:
		if e.a == node_i or e.b == node_i:
			d += 1
	return d


## Nodos con 3+ conexiones: son las INTERSECCIONES reales de la red (donde un
## vehículo puede elegir camino). Es lo que hay que señalizar y donde van los
## cruces a distinto nivel.
func intersections() -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in nodes.size():
		if degree(i) >= 3:
			out.append(i)
	return out


## Vecinos de un nodo: [{node, edge, length_m}] — lo que necesita un pathfinder.
func neighbors(node_i: int) -> Array:
	var out: Array = []
	for k in edges.size():
		var e: Dictionary = edges[k]
		if e.a == node_i:
			out.append({node = e.b, edge = k, length_m = e.length_m})
		elif e.b == node_i:
			out.append({node = e.a, edge = k, length_m = e.length_m})
	return out


## ¿La red es NAVEGABLE de punta a punta? (Todos los nodos alcanzables desde el
## primero.) Si da false, hay tramos sueltos: un vehículo quedaría encerrado.
## NO se llama `is_connected`: ese nombre ya existe en Object (señales) y Godot
## rechaza la firma distinta.
func is_navigable() -> bool:
	if nodes.is_empty():
		return true
	var seen := {}
	var stack := [0]
	while not stack.is_empty():
		var n: int = stack.pop_back()
		if seen.has(n):
			continue
		seen[n] = true
		for nb in neighbors(n):
			if not seen.has(nb.node):
				stack.append(nb.node)
	return seen.size() == nodes.size()


func stats() -> Dictionary:
	return {nodes = nodes.size(), edges = edges.size(),
			intersections = intersections().size(), connected = is_navigable()}


## Nodo mas cercano a una posicion del mundo. Es por donde un vehiculo/NPC "entra"
## a la red desde donde este parado.
func nearest_node(p: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in nodes.size():
		var d := nodes[i].distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = i
	return best


## CAMINO MAS CORTO entre dos nodos (A* sobre el grafo, con la distancia en linea
## recta como heuristica — admisible porque nunca sobreestima el largo real).
## Devuelve la secuencia de nodos, vacia si no hay camino.
func find_path(from_i: int, to_i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if from_i < 0 or to_i < 0 or from_i >= nodes.size() or to_i >= nodes.size():
		return out
	if from_i == to_i:
		out.append(from_i)
		return out
	var g := {from_i: 0.0}                       # costo real hasta el nodo
	var came := {}
	var open: Array[int] = [from_i]
	while not open.is_empty():
		# Nodo abierto con menor f = g + heuristica.
		var best := 0
		var best_f := INF
		for k in open.size():
			var n: int = open[k]
			var f: float = g[n] + nodes[n].distance_to(nodes[to_i])
			if f < best_f:
				best_f = f
				best = k
		var cur: int = open[best]
		if cur == to_i:
			break
		open.remove_at(best)
		for nb in neighbors(cur):
			var nn: int = nb.node
			var ng: float = g[cur] + float(nb.length_m)
			if not g.has(nn) or ng < g[nn]:
				g[nn] = ng
				came[nn] = cur
				if not open.has(nn):
					open.append(nn)
	if not came.has(to_i) and from_i != to_i:
		return out                               # inalcanzable
	# Reconstruir de atras para adelante.
	var chain: Array[int] = [to_i]
	var walk: int = to_i
	while came.has(walk):
		walk = came[walk]
		chain.append(walk)
	chain.reverse()
	for n in chain:
		out.append(n)
	return out


## Largo total (m) de un camino de nodos.
func path_length(path: PackedInt32Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		for nb in neighbors(path[i - 1]):
			if nb.node == path[i]:
				total += float(nb.length_m)
				break
	return total
