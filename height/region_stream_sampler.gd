class_name RegionStreamSampler
extends RefCounted

## ============================================================================
## RegionStreamSampler · Heightfield por REGIONES bajo demanda (16KM-5, §F8.8)
## ============================================================================
## Para mundos que NO entran en un solo bake (16 km ⇒ 8192² floats ≈ 268 MB):
## la MISMA pila de HeightLayer, bakeada en TILES de region_m alrededor de
## quien pregunta, con tope de memoria (LRU de max_regions).
## · DETERMINISTA tras evicción: la pila es pura ⇒ re-bakear una región da
##   EXACTAMENTE los mismos valores (test lo garantiza).
## · SIN COSTURAS: los tiles comparten la columna/fila de borde (cada tile
##   muestrea [origen .. origen+region_m] INCLUSIVO) → continuidad exacta.
## · Restricción del prototipo: capas PURAS por posición (sin bake_targets/
##   bake_rim — los carve de río/lago se integran por región en la fase de
##   integración; hoy el juego chico sigue usando HeightSampler full).
## Bake sync (rápido: un tile 257² ≈ 66k samples); hook async = WorkerThreadPool
## alrededor de get_tile cuando se integre al juego.
## ============================================================================

var layers: Array[HeightLayer] = []
var bounds: Rect2
var height_scale := 40.0
var global_seed := 0
var graph: PolygonGraph = null
var query: GraphQuery = null
## Lado de región en metros y texels por lado (incluye el borde compartido).
var region_m := 512.0
var region_res := 257
var max_regions := 16

## Métricas (tests / overlay de debug).
var bakes_count := 0

var _tiles := {}                 # Vector2i → PackedFloat32Array (region_res²)
var _lru: Array[Vector2i] = []   # orden de uso (frente = más viejo)
var _prepared := false


func setup(p_layers: Array[HeightLayer], p_bounds: Rect2, p_scale: float,
		p_seed: int, p_graph: PolygonGraph = null, p_query: GraphQuery = null) -> void:
	layers = p_layers
	bounds = p_bounds
	height_scale = p_scale
	global_seed = p_seed
	graph = p_graph
	query = p_query


func _ctx() -> HeightContext:
	return HeightContext.new(graph, bounds, height_scale, global_seed, query)


## Altura en metros en p (bilinear dentro del tile de su región; el tile se
## bakea la primera vez que se toca — streaming bajo demanda).
func get_height(p: Vector2) -> float:
	var key := Vector2i(int(floorf((p.x - bounds.position.x) / region_m)),
			int(floorf((p.y - bounds.position.y) / region_m)))
	var tile := _get_tile(key)
	var origin := bounds.position + Vector2(key) * region_m
	var texel := region_m / float(region_res - 1)
	var u := clampf((p.x - origin.x) / texel, 0.0, float(region_res - 1))
	var v := clampf((p.y - origin.y) / texel, 0.0, float(region_res - 1))
	var x0 := clampi(int(floorf(u)), 0, region_res - 1)
	var y0 := clampi(int(floorf(v)), 0, region_res - 1)
	var x1 := mini(x0 + 1, region_res - 1)
	var y1 := mini(y0 + 1, region_res - 1)
	var tx := u - float(x0)
	var ty := v - float(y0)
	var r0 := y0 * region_res
	var r1 := y1 * region_res
	var a := lerpf(tile[r0 + x0], tile[r0 + x1], tx)
	var b := lerpf(tile[r1 + x0], tile[r1 + x1], tx)
	return lerpf(a, b, ty)


func loaded_regions() -> int:
	return _tiles.size()


## Imagen RF (float32, METROS) de una región — para subir a GPU como textura de
## altura del shader (modo use_region_tile). Reusa el bake + LRU de get_height.
## RF encodea el float crudo (mismos metros que .r del heightfield global).
func get_tile_image(key: Vector2i) -> Image:
	var tile := _get_tile(key)
	return Image.create_from_data(region_res, region_res, false,
			Image.FORMAT_RF, tile.to_byte_array())


func _get_tile(key: Vector2i) -> PackedFloat32Array:
	if _tiles.has(key):
		# LRU: mover al final (más reciente).
		var i := _lru.find(key)
		if i >= 0:
			_lru.remove_at(i)
		_lru.append(key)
		return _tiles[key]
	if not _prepared:
		var proto := _ctx()
		for l in layers:
			if l != null and l.enabled:
				l.prepare(proto)
		_prepared = true
	var tile := _bake_tile(key)
	_tiles[key] = tile
	_lru.append(key)
	bakes_count += 1
	while _tiles.size() > max_regions:
		var oldest: Vector2i = _lru.pop_front()
		_tiles.erase(oldest)
	return tile


## Bakea la región: muestrea la pila [origen .. origen+region_m] INCLUSIVO
## (el texel de borde coincide con el del vecino → sin costuras).
func _bake_tile(key: Vector2i) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(region_res * region_res)
	var origin := bounds.position + Vector2(key) * region_m
	var texel := region_m / float(region_res - 1)
	var ctx := _ctx()
	for z in region_res:
		var wy := origin.y + float(z) * texel
		var base := z * region_res
		for x in region_res:
			var pos := Vector2(origin.x + float(x) * texel, wy)
			var h := 0.0
			for l in layers:
				if l == null or not l.enabled:
					continue
				h = l.apply(pos, h, ctx)
			out[base + x] = h
	return out
