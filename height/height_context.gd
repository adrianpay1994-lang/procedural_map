class_name HeightContext
extends RefCounted

## ============================================================================
## HeightContext · Lo que las capas de altura pueden consultar del grafo
## ============================================================================
## Una instancia POR THREAD del bake (tiene caché mutable de localización).
## El grafo y el GraphQuery se comparten (solo lectura).
##
## Convención de elevación firmada: vértices de océano valen -ocean_depth_norm
## (la costa cruza 0 exactamente en la línea de agua).
## ============================================================================

var graph: PolygonGraph
var bounds: Rect2
var height_scale: float = 40.0
var global_seed: int = 0
var query: GraphQuery
## Profundidad normalizada del lecho oceánico (la fija VoronoiBaseLayer).
var ocean_depth_norm: float = 0.15

# ---- caché de localización (mutable, por-thread) ----
var _cached_center: Center = null
var _last_pos := Vector2(INF, INF)
var _last_elev: float = 0.0
var _last_grad := Vector2.ZERO      # d(elev01)/d(metro)


func _init(p_graph: PolygonGraph, p_bounds: Rect2, p_height_scale: float,
		p_seed: int, p_query: GraphQuery) -> void:
	graph = p_graph
	bounds = p_bounds
	height_scale = p_height_scale
	global_seed = p_seed
	query = p_query


## Center que contiene pos (= el más cercano, por definición de Voronoi).
## Camina por vecinos desde el caché — O(1) en accesos coherentes (bake por filas).
func get_center(pos: Vector2) -> Center:
	var c := _cached_center
	if c == null:
		c = query.nearest_center(pos)
	while true:
		var best := c
		var best_d := c.point.distance_squared_to(pos)
		for n in c.neighbors:
			var d := (n as Center).point.distance_squared_to(pos)
			if d < best_d:
				best_d = d
				best = n
		if best == c:
			break
		c = best
	_cached_center = c
	return c


func get_biome(pos: Vector2) -> String:
	return get_center(pos).biome


## Elevación 0..1 firmada (océano < 0), interpolada baricéntricamente sobre el
## fan de triángulos del Center. Cachea también el gradiente del triángulo.
func get_graph_elevation(pos: Vector2) -> float:
	if pos == _last_pos:
		return _last_elev
	var c := get_center(pos)
	var vc := _signed_center(c)
	var found := false
	for e_any in c.borders:
		var e := e_any as Edge
		if e.v0 == null or e.v1 == null:
			continue
		var p1: Vector2 = e.v0.point
		var p2: Vector2 = e.v1.point
		var bary := _barycentric(pos, c.point, p1, p2)
		if bary.x >= -0.0005 and bary.y >= -0.0005 and bary.z >= -0.0005:
			var v1 := _signed_corner(e.v0)
			var v2 := _signed_corner(e.v1)
			_last_elev = bary.x * vc + bary.y * v1 + bary.z * v2
			_last_grad = _plane_gradient(c.point, p1, p2, vc, v1, v2)
			found = true
			break
	if not found:
		# Fallback: media ponderada por inversa de distancia (borde del hull).
		var wsum := 0.0
		var acc := 0.0
		var gw := 1.0 / maxf(c.point.distance_to(pos), 0.001)
		acc += vc * gw
		wsum += gw
		for co_any in c.corners:
			var co := co_any as Corner
			var w := 1.0 / maxf(co.point.distance_to(pos), 0.001)
			acc += _signed_corner(co) * w
			wsum += w
		_last_elev = acc / maxf(wsum, 0.0001)
		_last_grad = Vector2.ZERO
	_last_pos = pos
	return _last_elev


## Pendiente 0..1 de la elevación macro en metros/metro (clampeada).
## Usa el gradiente del último triángulo localizado (llama get_graph_elevation).
func get_base_slope01(pos: Vector2) -> float:
	if pos != _last_pos:
		get_graph_elevation(pos)
	return clampf(_last_grad.length() * height_scale, 0.0, 1.0)


func _signed_center(c: Center) -> float:
	return -ocean_depth_norm if c.ocean else c.elevation


func _signed_corner(co: Corner) -> float:
	return -ocean_depth_norm if co.ocean else co.elevation


static func _barycentric(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var den := v0.x * v1.y - v1.x * v0.y
	if absf(den) < 0.000001:
		return Vector3(-1, -1, -1)
	var v := (v2.x * v1.y - v1.x * v2.y) / den
	var w := (v0.x * v2.y - v2.x * v0.y) / den
	return Vector3(1.0 - v - w, v, w)


## Gradiente constante del plano que pasa por (a,va) (b,vb) (c,vc).
static func _plane_gradient(a: Vector2, b: Vector2, c: Vector2,
		va: float, vb: float, vc: float) -> Vector2:
	var ab := b - a
	var ac := c - a
	var den := ab.x * ac.y - ac.x * ab.y
	if absf(den) < 0.000001:
		return Vector2.ZERO
	var db := vb - va
	var dc := vc - va
	return Vector2((db * ac.y - dc * ab.y) / den, (dc * ab.x - db * ac.x) / den)
