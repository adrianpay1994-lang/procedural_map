class_name RoadNetworkBuilder
extends Resource

## ============================================================================
## RoadNetworkBuilder · Red de caminos entre monumentos (§7.7)
## ============================================================================
## Como Rust: los caminos CONECTAN monumentos. Prim (árbol de expansión mínima
## sobre los sitios) + aristas extra para loops, y cada arista se traza con A*
## sobre los Centers de tierra (coste por pendiente, penalización por agua).
## Cruces de agua angostos → sitio de puente.
## ============================================================================

@export_range(0.0, 1.0, 0.05) var extra_link_ratio: float = 0.2
@export var slope_cost: float = 6.0
@export var water_penalty: float = 50.0
@export var max_bridge_length_m: float = 24.0

var _bridge_sites: Array[Transform3D] = []


func get_bridge_sites() -> Array[Transform3D]:
	return _bridge_sites


## Devuelve una polilínea (suavizada) por arista de la red.
func build(sites: Array[Vector2], provider: MapDataProvider,
		height_scale: float, rng: RandomNumberGenerator) -> Array[PackedVector2Array]:
	_bridge_sites.clear()
	var out: Array[PackedVector2Array] = []
	if sites.size() < 2:
		return out
	var edges := _prim_with_extras(sites, rng)
	for e in edges:
		var path := _astar_centers(sites[e.x], sites[e.y], provider, height_scale)
		if path.size() >= 2:
			out.append(MapDataProvider._chaikin(path, 2))
	return out


## MST de Prim + extra_link_ratio aristas adicionales (las más cortas no usadas).
func _prim_with_extras(sites: Array[Vector2], rng: RandomNumberGenerator) -> Array[Vector2i]:
	var n := sites.size()
	var in_tree := {0: true}
	var edges: Array[Vector2i] = []
	while in_tree.size() < n:
		var best := Vector2i(-1, -1)
		var best_d := INF
		for a in in_tree:
			for b in n:
				if in_tree.has(b):
					continue
				var d := sites[a].distance_squared_to(sites[b])
				if d < best_d:
					best_d = d
					best = Vector2i(a, b)
		edges.append(best)
		in_tree[best.y] = true
	# Aristas extra (loops de jugabilidad): las más cortas que no estén ya.
	var extra := int(ceilf(edges.size() * extra_link_ratio))
	var candidates: Array[Vector2i] = []
	for a in n:
		for b in range(a + 1, n):
			var e := Vector2i(a, b)
			if not edges.has(e) and not edges.has(Vector2i(b, a)):
				candidates.append(e)
	candidates.sort_custom(func(x: Vector2i, y: Vector2i) -> bool:
		return sites[x.x].distance_squared_to(sites[x.y]) \
				< sites[y.x].distance_squared_to(sites[y.y]))
	for i in mini(extra, candidates.size()):
		edges.append(candidates[i])
	if rng.randf() < 0.0:  # rng reservado para variantes futuras (determinismo estable)
		pass
	return edges


## A* sobre el grafo de Centers. Coste = distancia × (1 + slope_cost·pendiente²),
## agua × water_penalty. Registra puentes en cruces de agua cortos.
func _astar_centers(from_pos: Vector2, to_pos: Vector2,
		provider: MapDataProvider, height_scale: float) -> PackedVector2Array:
	var start := provider.get_center_at(from_pos)
	var goal := provider.get_center_at(to_pos)
	if start == null or goal == null:
		return PackedVector2Array()
	var open := {start: 0.0}            # Center -> f
	var g := {start: 0.0}               # Center -> coste acumulado
	var came := {}                      # Center -> Center
	var closed := {}
	while not open.is_empty():
		var current: Center = null
		var best_f := INF
		for c in open:
			if open[c] < best_f:
				best_f = open[c]
				current = c
		open.erase(current)
		if current == goal:
			break
		closed[current] = true
		for n_any in current.neighbors:
			var nb := n_any as Center
			if closed.has(nb) or nb.ocean:
				continue
			var dist := current.point.distance_to(nb.point)
			var dh := absf(nb.elevation - current.elevation) * height_scale
			var slope := dh / maxf(dist, 0.1)
			var cost := dist * (1.0 + slope_cost * slope * slope)
			if nb.water:
				cost *= water_penalty
			var ng: float = g[current] + cost
			if not g.has(nb) or ng < g[nb]:
				g[nb] = ng
				came[nb] = current
				open[nb] = ng + nb.point.distance_to(goal.point)
	if not came.has(goal) and goal != start:
		return PackedVector2Array()
	# Reconstrucción + detección de puentes (tramo agua ≤ max_bridge_length_m).
	var path := PackedVector2Array()
	var node := goal
	while node != null:
		path.append(node.point)
		var prev: Center = came.get(node)
		if prev != null and (node.water or prev.water):
			var span := node.point.distance_to(prev.point)
			if span <= max_bridge_length_m:
				var mid := (node.point + prev.point) * 0.5
				var yaw := (node.point - prev.point).angle()
				_bridge_sites.append(Transform3D(
						Basis(Vector3.UP, -yaw),
						Vector3(mid.x, 0.0, mid.y)))
		node = prev
	path.reverse()
	return path
