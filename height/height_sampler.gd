class_name HeightSampler
extends RefCounted

## ============================================================================
## HeightSampler · Única fuente de verdad de altura (PROCEDURAL_MAP_PLAN.md §3.2)
## ============================================================================
## ANTES del bake: sample() evalúa la pila al vuelo (solo generación).
## DESPUÉS del bake: get_height/get_normal/get_slope leen el campo bakeado
## con interpolación bilineal — lo ÚNICO que consulta el resto del juego.
## Mesh, colliders, shader, placement y agua leen de acá: coincidencia garantizada.
## ============================================================================

var graph: PolygonGraph
var layers: Array[HeightLayer] = []
var bounds: Rect2
var height_scale: float = 40.0
var global_seed: int = 0
var query: GraphQuery

## Progreso para la pantalla de carga (filas completadas por los workers;
## las carreras de escritura solo afectan al contador visual).
var rows_done: int = 0
var rows_total: int = 1

var _baked := PackedFloat32Array()
var _resolution: int = 0
var _layer_bounds: Array[Rect2] = []   # footprint por capa (size 0 = global)
var _texel: Vector2 = Vector2.ONE
var _min_h: float = 0.0
var _max_h: float = 0.0


func setup(p_graph: PolygonGraph, p_layers: Array[HeightLayer], p_bounds: Rect2,
		p_height_scale: float, p_seed: int, p_query: GraphQuery) -> void:
	graph = p_graph
	layers = p_layers
	bounds = p_bounds
	height_scale = p_height_scale
	global_seed = p_seed
	query = p_query


func make_context() -> HeightContext:
	return HeightContext.new(graph, bounds, height_scale, global_seed, query)


## Evalúa la pila completa en un punto (lento — solo generación/bake).
## skip_from: índice de capa donde cortar (para bake_targets de FLATTEN_ALONG).
func sample(world_xz: Vector2, ctx: HeightContext = null, skip_from: int = -1) -> float:
	if ctx == null:
		ctx = make_context()
	var h := 0.0
	for i in layers.size():
		if skip_from >= 0 and i >= skip_from:
			break
		var layer := layers[i]
		if layer == null or not layer.enabled:
			continue
		h = layer.apply(world_xz, h, ctx)
	return h


## Prepara capas (noise/grids/targets). Llamar UNA vez antes de bake().
func prepare_layers() -> void:
	var proto := make_context()
	for i in layers.size():
		var layer := layers[i]
		if layer == null or not layer.enabled:
			continue
		layer.prepare(proto)
		if layer is PathCarveLayer and (layer as PathCarveLayer).path_mode == PathCarveLayer.PathMode.FLATTEN_ALONG:
			var idx := i
			var ctx := make_context()
			(layer as PathCarveLayer).bake_targets(
					func(p: Vector2) -> float: return sample(p, ctx, idx))
		elif layer is LakeCraterLayer:
			var lidx := i
			var lctx := make_context()
			(layer as LakeCraterLayer).bake_rim(
					func(p: Vector2) -> float: return sample(p, lctx, lidx))
		elif layer is TerrainStampLayer and (layer as TerrainStampLayer).needs_base_ref():
			var sidx := i
			var sctx := make_context()
			(layer as TerrainStampLayer).bake_base(
					func(p: Vector2) -> float: return sample(p, sctx, sidx))


## Bakea a grilla regular. resolution DEBE ser 2^n + 1 (513, 1025, 2049…).
## frame_yield válido ⇒ cede frames mientras los workers trabajan (pantalla de
## carga responsiva); vacío ⇒ bloqueante (tests/CLI).
func bake(resolution: int, smooth_passes: int = 0,
		frame_yield: Callable = Callable()) -> void:
	assert(_is_pow2_plus1(resolution), "bake_resolution debe ser 2^n+1 (513/1025/2049...)")
	prepare_layers()
	_rebuild_layer_bounds()
	_resolution = resolution
	_texel = Vector2(bounds.size.x / float(resolution - 1),
			bounds.size.y / float(resolution - 1))
	_baked.resize(resolution * resolution)
	rows_total = resolution
	rows_done = 0
	var task := WorkerThreadPool.add_group_task(_bake_row, resolution, TerrainSettings.worker_count(), false,
			"HeightSampler.bake")
	if frame_yield.is_valid():
		while not WorkerThreadPool.is_group_task_completed(task):
			await frame_yield.call()
	WorkerThreadPool.wait_for_group_task_completion(task)
	for _i in smooth_passes:
		_smooth_laplacian()
	_min_h = INF
	_max_h = -INF
	for v in _baked:
		_min_h = minf(_min_h, v)
		_max_h = maxf(_max_h, v)


func _bake_row(row: int) -> void:
	var ctx := make_context()  # caché de localización por fila → coherencia máxima
	var y := bounds.position.y + float(row) * _texel.y
	var base := row * _resolution
	var nl := layers.size()
	for x in _resolution:
		var pos := Vector2(bounds.position.x + float(x) * _texel.x, y)
		var h := 0.0
		for li in nl:
			var layer := layers[li]
			if layer == null or not layer.enabled:
				continue
			# Early-out por footprint: fuera del AABB la capa devolvería h igual
			# (ríos/caminos/vías). Exacto y barato; gana en mapas grandes donde la
			# mayoría de las celdas está lejos de toda polilínea.
			var b: Rect2 = _layer_bounds[li]
			if b.size.x > 0.0 and not b.has_point(pos):
				continue
			h = layer.apply(pos, h, ctx)
		_baked[base + x] = h
	rows_done += 1


func _rebuild_layer_bounds() -> void:
	_layer_bounds.clear()
	for layer in layers:
		_layer_bounds.append(layer.affect_bounds() if layer != null else Rect2())


func _smooth_laplacian() -> void:
	var prev := _baked.duplicate()
	var r := _resolution
	for z in range(1, r - 1):
		var base := z * r
		for x in range(1, r - 1):
			var i := base + x
			_baked[i] = (prev[i] * 4.0 + prev[i - 1] + prev[i + 1]
					+ prev[i - r] + prev[i + r]) / 8.0


static func _is_pow2_plus1(n: int) -> bool:
	var m := n - 1
	return m > 1 and (m & (m - 1)) == 0


func is_baked() -> bool:
	return _resolution > 0


func get_resolution() -> int:
	return _resolution


func get_height_range() -> Vector2:
	return Vector2(_min_h, _max_h)


func get_heights_raw() -> PackedFloat32Array:
	return _baked


## ---- Post-bake: API para todo el resto del sistema ----

func get_height(world_xz: Vector2) -> float:
	var u := (world_xz.x - bounds.position.x) / _texel.x
	var v := (world_xz.y - bounds.position.y) / _texel.y
	var x0 := clampi(int(floorf(u)), 0, _resolution - 1)
	var y0 := clampi(int(floorf(v)), 0, _resolution - 1)
	var x1 := mini(x0 + 1, _resolution - 1)
	var y1 := mini(y0 + 1, _resolution - 1)
	var tx := clampf(u - float(x0), 0.0, 1.0)
	var ty := clampf(v - float(y0), 0.0, 1.0)
	var a := lerpf(_baked[y0 * _resolution + x0], _baked[y0 * _resolution + x1], tx)
	var b := lerpf(_baked[y1 * _resolution + x0], _baked[y1 * _resolution + x1], tx)
	return lerpf(a, b, ty)


## Normal del terreno (diferencias centrales sobre el campo bakeado).
func get_normal(world_xz: Vector2) -> Vector3:
	var e := _texel.x
	var hl := get_height(world_xz + Vector2(-e, 0))
	var hr := get_height(world_xz + Vector2(e, 0))
	var hd := get_height(world_xz + Vector2(0, -e))
	var hu := get_height(world_xz + Vector2(0, e))
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


## 0 = plano, 1 = pared vertical.
func get_slope(world_xz: Vector2) -> float:
	return 1.0 - clampf(get_normal(world_xz).y, 0.0, 1.0)


## Imagen RF con la altura en metros (para shader/export — sin normalizar).
func bake_to_image() -> Image:
	var img := Image.create_empty(_resolution, _resolution, false, Image.FORMAT_RF)
	for z in _resolution:
		for x in _resolution:
			img.set_pixel(x, z, Color(_baked[z * _resolution + x], 0, 0))
	return img


## Normalmap global RGB8: r=n.x g=n.z b=n.y (b = arriba; el shader lee .z tras
## el remap *2-1 con la convención documentada en §5.2).
func bake_normalmap_image() -> Image:
	var img := Image.create_empty(_resolution, _resolution, false, Image.FORMAT_RGB8)
	for z in _resolution:
		var y := bounds.position.y + float(z) * _texel.y
		for x in _resolution:
			var n := get_normal(Vector2(bounds.position.x + float(x) * _texel.x, y))
			img.set_pixel(x, z, Color(n.x * 0.5 + 0.5, n.z * 0.5 + 0.5, n.y * 0.5 + 0.5))
	return img
