class_name MapDataProvider
extends Node

## ============================================================================
## MapDataProvider · Wrapper de MapGenerator (pcg-terrain_1) — plano semántico
## ============================================================================
## Genera el grafo Voronoi (biomas, ríos, carreteras, costa) y lo RECENTRA en
## el origen: desde acá, espacio de mapa == espacio de mundo (una sola
## convención para mesh, colliders, placement y capas).
## pcg-terrain_1 NO se modifica: este wrapper es el único punto de contacto.
## ============================================================================

## Hash espacial de segmentos de UNA polilínea (F6.5): celda → índices de
## segmento. Misma segmentación stride-2 que _min_dist_to_polyline, así los
## consumidores (deflect/confluencias) dan EXACTAMENTE el mismo resultado que
## la fuerza bruta punto×segmento a la que reemplazan.
class SegmentHash:
	var cell_m: float
	var _a := PackedVector2Array()
	var _b := PackedVector2Array()
	var _cells := {}  # Vector2i → PackedInt32Array

	func _init(poly: PackedVector2Array, p_cell_m: float = 16.0) -> void:
		cell_m = p_cell_m
		for i in range(0, poly.size() - 1, 2):
			var a := poly[i]
			var b := poly[mini(i + 2, poly.size() - 1)]
			var idx := _a.size()
			_a.append(a)
			_b.append(b)
			var lo := Vector2i(int(floorf(minf(a.x, b.x) / cell_m)),
					int(floorf(minf(a.y, b.y) / cell_m)))
			var hi := Vector2i(int(floorf(maxf(a.x, b.x) / cell_m)),
					int(floorf(maxf(a.y, b.y) / cell_m)))
			for cy in range(lo.y, hi.y + 1):
				for cx in range(lo.x, hi.x + 1):
					var key := Vector2i(cx, cy)
					var arr: PackedInt32Array = _cells.get(key, PackedInt32Array())
					arr.append(idx)
					_cells[key] = arr  # packed array es COW: reasignar

	## Distancia al segmento más cercano DENTRO de radius (INF si no hay).
	## info (opcional) recibe "closest" (Vector2) y "dir" (Vector2 unitario).
	## Candidatos EVALUADOS EN ORDEN DE ÍNDICE: mismo desempate que el barrido
	## lineal (segmentos consecutivos comparten vértice ⇒ distancia idéntica;
	## si gana otro, cambia "dir" y el trazado diverge — medido en curvas_suaves).
	func nearest_in_radius(p: Vector2, radius: float, info: Dictionary = {}) -> float:
		var lo := Vector2i(int(floorf((p.x - radius) / cell_m)),
				int(floorf((p.y - radius) / cell_m)))
		var hi := Vector2i(int(floorf((p.x + radius) / cell_m)),
				int(floorf((p.y + radius) / cell_m)))
		var cand := PackedInt32Array()
		for cy in range(lo.y, hi.y + 1):
			for cx in range(lo.x, hi.x + 1):
				cand.append_array(_cells.get(Vector2i(cx, cy), PackedInt32Array()))
		cand.sort()
		var best := INF
		var last := -1
		for idx in cand:
			if idx == last:
				continue  # duplicado (segmento en varias celdas)
			last = idx
			var a := _a[idx]
			var ab := _b[idx] - a
			var len2 := ab.length_squared()
			var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0) if len2 > 0.001 else 0.0
			var q := a + ab * t
			var d := p.distance_to(q)
			if d < best:
				best = d
				info["closest"] = q
				info["dir"] = ab.normalized()
		return best


var graph: PolygonGraph
var query := GraphQuery.new()
## Info de lagos que llena build_lake_layers(): [{polygon, water_y, center_pos}].
var lakes: Array[Dictionary] = []

var _generator: MapGenerator
var _bounds := Rect2()
var _ctx_biome: HeightContext  # caché para consultas de bioma post-generación


func generate(config: MapGenerationConfig) -> void:
	_start_generator(config)
	_finish_generate(config)


## Versión asíncrona (backlog #50): el grafo Voronoi+biomas (la fase más
## lenta de la carga) corre en un WORKER — el main thread queda libre.
## Determinista: mismo código, otro hilo. frame_yield vacío ⇒ síncrono.
func generate_async(config: MapGenerationConfig, frame_yield: Callable) -> void:
	if not frame_yield.is_valid():
		generate(config)
		return
	var cfg := config
	var tid := WorkerThreadPool.add_task(func() -> void: _start_generator(cfg),
			false, "MapDataProvider.generate")
	while not WorkerThreadPool.is_task_completed(tid):
		await frame_yield.call()
	WorkerThreadPool.wait_for_task_completion(tid)
	_finish_generate(config)


func _start_generator(config: MapGenerationConfig) -> void:
	_generator = MapGenerator.new()
	_generator.num_rivers = config.num_rivers
	_generator.road_shape_scale = config.road_shape_scale
	_generator.north_temperature_bias = config.north_temperature_bias
	_generator.south_temperature_bias = config.south_temperature_bias
	var ocean_mode := config.ocean_point_mode.strip_edges()
	_generator.generate_with_ocean(config.island_shape, config.point_mode,
			config.num_points, config.ocean_points, config.ocean_distance,
			config.map_size, config.seed_shape, config.seed_variant, ocean_mode)


func _finish_generate(config: MapGenerationConfig) -> void:
	graph = _generator.graph
	_recenter_graph()
	query.setup(graph.centers, _bounds)
	_ctx_biome = HeightContext.new(graph, _bounds, config.height_scale,
			config.seed_variant, query)


## Traslada TODO el grafo para que el mapa quede centrado en el origen.
func _recenter_graph() -> void:
	var offset := Vector2(graph.size, graph.size) * 0.5
	for c in graph.centers:
		(c as Center).point -= offset
	for co in graph.corners:
		(co as Corner).point -= offset
	for e in graph.edges:
		(e as Edge).midpoint -= offset
	_bounds = Rect2(-offset, Vector2(graph.size, graph.size))


func get_map_bounds() -> Rect2:
	return _bounds


## ---- Capas automáticas derivadas del grafo (se insertan tras las del usuario) ----

## Lagos ESTILO OASIS (regla del usuario): rampa perimetral subible → repisa
## poco profunda → POZO central hondo. En bioma ICE: plato llano congelado.
## Se llaman DESPUÉS de ríos/carreteras/vías: el lago LEE esos trazados y no
## aparece bajo ninguno (avoid_paths) — ellos ya reclamaron el terreno.
func build_lake_layers(height_scale: float, depth_m: float = 2.0,
		avoid_paths: Array = [], desired_lakes: int = 0,
		rng_seed: int = 0) -> Array[HeightLayer]:
	lakes.clear()
	var out: Array[HeightLayer] = []
	for c in get_lake_centers():
		# Solo lagos de verdad: MARSH (pantano costero) generaba planos de agua
		# cortando laderas cerca de la costa — las "esquirlas" del reporte.
		if c.biome != "LAKE" and c.biome != "ICE":
			continue
		_build_lake(c, height_scale, depth_m, avoid_paths, out)
	# CANTIDAD DE LAGOS (regla del usuario: "deberíamos poner cuántos lagos
	# queremos"): si el grafo no dio suficientes celdas LAKE, se eligen
	# celdas de tierra adentro aptas (determinista por seed) y se cavan como
	# oasis — el veto por trazados sigue mandando.
	if desired_lakes > 0 and lakes.size() < desired_lakes:
		var candidates: Array[Center] = []
		for c in get_land_centers():
			if c.corners.size() < 5 or c.water or c.coast:
				continue
			var e := c.elevation * height_scale
			if e < 3.0 or e > 26.0:
				continue
			candidates.append(c)
		candidates.sort_custom(func(a, b) -> bool:
			return hash([rng_seed, a.index]) < hash([rng_seed, b.index]))
		for c in candidates:
			if lakes.size() >= desired_lakes:
				break
			var far_enough := true
			for lk in lakes:
				if c.point.distance_to(lk.center_pos) < 90.0:
					far_enough = false
					break
			if far_enough:
				_build_lake(c, height_scale, depth_m, avoid_paths, out)
	return out


## Cava UN lago oasis en la celda c (si el veto lo permite): rampa → repisa
## caminable → pozo central. ICE = plato congelado. Registra en lakes[].
func _build_lake(c: Center, height_scale: float, depth_m: float,
		avoid_paths: Array, out: Array[HeightLayer]) -> void:
	if c.corners.size() < 3:
		return
	if c.elevation * height_scale < 2.0:
		return  # celda casi al nivel del mar: el océano ya la cubre
	# Polígono ordenado por ángulo alrededor del center (celda convexa).
	var poly := PackedVector2Array()
	var sorted := c.corners.duplicate()
	sorted.sort_custom(func(a, b) -> bool:
		return (a.point - c.point).angle() < (b.point - c.point).angle())
	var rim_min := INF
	var rim_max := -INF
	var radius := 0.0
	var coast_rim := false
	for co in sorted:
		poly.append((co as Corner).point)
		var e := (co as Corner).elevation
		var em := (0.0 if (co as Corner).ocean else e) * height_scale
		rim_min = minf(rim_min, em)
		rim_max = maxf(rim_max, em)
		radius = maxf(radius, c.point.distance_to((co as Corner).point))
		if (co as Corner).coast or (co as Corner).ocean:
			coast_rim = true
	# CONTORNO A NIVEL (regla del usuario): el lago va donde el borde es
	# parejo — si el rim varía mucho es una ladera, no una cuenca.
	if rim_max - rim_min > 5.0:
		return
	# LEJOS DE LA COSTA: ningún corner del borde toca mar/costa.
	if coast_rim:
		return
	# VETO por carretera/vía/río: al menos ~2 centers (≈ 2 radios) de distancia
	# (regla del usuario: 2 centers / 3 corners lejos), no solo el borde.
	for path_any in avoid_paths:
		if _min_dist_to_polyline(c.point, path_any) < radius * 2.0:
			return
	var frozen: bool = c.biome == "ICE"
	# CRÁTER cóncavo (método del cilindro cerrado, regla del usuario): un solo
	# cuenco radial rampa→repisa→pozo, no dos flatten planos escalonados. El
	# borde queda a rim − 1.0 (repisa caminable con agua a la rodilla).
	var crater := LakeCraterLayer.new()
	crater.centroid = c.point
	crater.radius_m = radius
	crater.perimeter_points = poly  # bake_rim lee el terreno REAL del contorno
	crater.rim_height_m = rim_min - 1.0  # fallback si no hay bake
	crater.depth_m = 0.0 if frozen else depth_m + 1.5
	crater.frozen = frozen
	var m := PolygonMask.new()
	m.polygon = poly
	# 14 m: orillas con pendiente SUBIBLE (backlog: lagos rodeados de
	# acantilados imposibles de escalar).
	m.falloff_m = 14.0
	crater.mask = m
	out.append(crater)
	# Lecho orgánico (backlog #11): ondulación suave del cuenco (0.6 m:
	# no debe asomar islas sobre el agua de la repisa).
	var bed_noise := NoiseHeightLayer.new()
	bed_noise.layer_name = &"lake_bed_noise"
	bed_noise.noise_seed = c.index
	bed_noise.amplitude_m = 0.6
	bed_noise.frequency = 0.08
	bed_noise.octaves = 3
	bed_noise.erosion_weight = 0.0
	var nm := PolygonMask.new()
	nm.polygon = poly
	nm.falloff_m = 4.0
	bed_noise.mask = nm
	out.append(bed_noise)
	lakes.append({
		# El agua se apoya DENTRO del cráter (borde en rim−1.0): hielo casi a
		# ras del plato; líquido 0.3 m bajo el borde (deja repisa caminable).
		"polygon": poly,
		"water_y": rim_min - (1.15 if frozen else 1.3),
		"center_pos": c.point,
		"frozen": frozen,
	})


func build_river_layers(width_m: float, depth_m: float, falloff_m: float,
		_height_scale: float = 40.0, grow_length_m: float = 0.0) -> Array[HeightLayer]:
	var out: Array[HeightLayer] = []
	var rivers := _generator.get_rivers()
	if rivers == null:
		return out
	for river_any in rivers.rivers:
		var corners: Array = river_any
		if corners.size() < 2:
			continue
		var pts := PackedVector2Array()
		var reached_sea := false
		var last_corner: Corner = null
		for co in corners:
			var corner := co as Corner
			pts.append(corner.point)
			last_corner = corner
			if corner.ocean or corner.coast:
				reached_sea = true
				break  # primer contacto con el mar: cortar (seguir el trazado
				# post-costa levantaba CRESTAS en costas cóncavas — medido)
		# GARANTÍA nacimiento→mar (regla del usuario): si el trazado del grafo
		# no llegó a la costa, seguir el downslope corner a corner hasta el mar.
		# Sin camino al mar ⇒ ese río NO EXISTE (descartado con aviso).
		if not reached_sea and last_corner != null:
			var cur := last_corner.downslope
			var guard := 0
			while cur != null and guard < 200:
				pts.append(cur.point)
				if cur.ocean or cur.coast:
					reached_sea = true
					break
				cur = cur.downslope
				guard += 1
		# El downslope se atascó en una depresión interior: en vez de DESCARTAR
		# el río (regla del usuario: OBLIGAR a llegar al mar), enrutar al corner
		# de COSTA más cercano si está a distancia razonable (< media isla).
		if not reached_sea:
			var tail := pts[pts.size() - 1]
			var best_coast := Vector2.INF
			var best_d := INF
			for co_any in graph.corners:
				var co := co_any as Corner
				if not (co.ocean or co.coast):
					continue
				var d := tail.distance_squared_to(co.point)
				if d < best_d:
					best_d = d
					best_coast = co.point
			if best_coast != Vector2.INF and sqrt(best_d) < graph.size * 0.5:
				pts.append(best_coast)
				reached_sea = true
		if not reached_sea:
			push_warning("MapDataProvider: río descartado — no encontró camino al mar.")
			continue
		if pts.size() < 3:
			continue
		# La boca abre EN el agua: proyectar 12 m mar adentro en la dirección
		# del último tramo (sin depender del trazado post-costa).
		var mouth_dir := (pts[pts.size() - 1] - pts[pts.size() - 2]).normalized()
		pts.append(pts[pts.size() - 1] + mouth_dir * 12.0)
		# DENSIFICACIÓN (regla del usuario): más puntos entre corners — Chaikin
		# suaviza y el resample uniforme (~5 m) deja un punto de control por
		# tramo: la altura REAL del terreno se mapea punto a punto ANTES de
		# cavar → excavación consistente (ni de más ni de menos) y resolución
		# suficiente para empalmar uniones de causes.
		var smooth_pts := MapDataProvider._resample(MapDataProvider._relax_sharp(
				MapDataProvider._chaikin(pts, 3), 0.5, 2), 5.0)
		_append_river_carve(smooth_pts, out, width_m, depth_m, falloff_m,
				grow_length_m)
	return out


## Ríos desde polilíneas YA garantizadas al mar (Hydrology §F4, modo RASTER).
## Misma post-pro que el modo grafo: simplificar (raster = denso, un punto por
## texel) → suavizar → resample → boca mar adentro → confluencias → carve.
func build_river_layers_from_polylines(polys: Array, width_m: float,
		depth_m: float, falloff_m: float,
		grow_length_m: float = 0.0) -> Array[HeightLayer]:
	var out: Array[HeightLayer] = []
	for poly_any in polys:
		var raw := poly_any as PackedVector2Array
		if raw.size() < 3:
			continue
		var pts := raw.duplicate()
		# La boca abre EN el agua: 12 m mar adentro (misma regla que el grafo).
		var mouth_dir := (pts[pts.size() - 1] - pts[pts.size() - 2]).normalized()
		pts.append(pts[pts.size() - 1] + mouth_dir * 12.0)
		var smooth_pts := MapDataProvider._resample(MapDataProvider._relax_sharp(
				MapDataProvider._chaikin(MapDataProvider._douglas_peucker(pts, 3.0),
				2), 0.5, 2), 5.0)
		if smooth_pts.size() < 3:
			continue
		_append_river_carve(smooth_pts, out, width_m, depth_m, falloff_m,
				grow_length_m)
	return out


## Construye la capa de carve de UN río y la agrega a `out` — incluida la
## CONFLUENCIA contra los ríos ya trazados. Compartido por GRAPH y RASTER.
## (Causa raíz medida: los ríos COMPARTEN tramos finales; el segundo tallaba su
## lecho 4 m POR DEBAJO del primero en el tramo común. En la realidad el
## afluente desemboca EN el río mayor: se trunca al alcanzar su zanja, TOCA su
## eje y su lecho empalma con el del receptor — mouth_from_layer.)
func _append_river_carve(smooth_pts: PackedVector2Array, out: Array[HeightLayer],
		width_m: float, depth_m: float, falloff_m: float,
		grow_length_m: float) -> void:
	var confluenced := false
	var receiver: PathCarveLayer = null
	var cut := smooth_pts.size()
	# F6.5: hash espacial por capa existente (antes punto×río×segmento).
	var hashes: Array[SegmentHash] = []
	for other_any in out:
		hashes.append(SegmentHash.new((other_any as PathCarveLayer).points))
	var reach := width_m * 0.8
	for i in smooth_pts.size():
		for k in hashes.size():
			if hashes[k].nearest_in_radius(smooth_pts[i], reach) < reach:
				receiver = out[k] as PathCarveLayer
				break
		if receiver != null:
			cut = i + 1  # incluye el punto de unión
			confluenced = true
			break
	if confluenced:
		smooth_pts = smooth_pts.slice(0, cut)
		smooth_pts.append(_closest_point_on_polyline(
				smooth_pts[smooth_pts.size() - 1], receiver.points))
	if smooth_pts.size() < 3:
		return
	var layer := PathCarveLayer.new()
	layer.layer_name = &"river_carve"
	layer.path_mode = PathCarveLayer.PathMode.FLATTEN_ALONG
	layer.points = smooth_pts
	layer.width_m = width_m
	layer.depth_m = depth_m
	layer.falloff_m = falloff_m
	layer.width_start_scale = 0.35  # nace angosto, desemboca ancho (pcg)
	layer.grow_length_m = grow_length_m  # engrosa con el TRAYECTO (metros)
	# AGUA PRIMERO (LEY del usuario): se diseña el CUERPO DE AGUA
	# (monotónico, contenido bajo el terreno, empalmado con el mar o con
	# el agua del receptor) y el lecho/zanja es su molde a medida —
	# la isla se adapta al agua. WaterBuilder construye ESE diseño exacto.
	layer.water_first = true
	layer.target_smooth_passes = 4   # puntos uniformes → perfil tendido
	layer.max_bank_slope = 0.38      # talud TENDIDO: rampa disimulada
	layer.bed_u_m = 0.8              # U honda: el contenedor del agua
	# 0.35: aguas arriba el nivel puede subir 35 cm/m (rápidos) — con
	# 0.15 la boca "pinneaba" el agua y cavaba CAÑONES en el nacimiento
	# (captura del usuario: terreno bajado de más en el punto más alto).
	layer.max_backcut_per_m = 0.35
	if confluenced:
		layer.mouth_from_layer = receiver
		# El RECEPTOR ahora carga DOS flujos aguas abajo de la unión:
		# se ensancha desde el punto de unión hasta el mar (regla del
		# usuario: dos cilindros se unen → sale uno más grande). Varios
		# afluentes acumulan (tope 1.9×).
		var jidx := _nearest_index_on(smooth_pts[smooth_pts.size() - 1],
				receiver.points)
		if receiver.confluence_index < 0 or jidx < receiver.confluence_index:
			receiver.confluence_index = jidx
		receiver.confluence_scale = minf(receiver.confluence_scale * 1.25, 1.9)
	else:
		# Boca al ras del mar: el río y el océano parecen el MISMO cuerpo.
		layer.mouth_target_m = -0.05
	out.append(layer)


## Punto de una polilínea más cercano a p (escaneo completo — se usa poco).
static func _closest_point_on_polyline(p: Vector2,
		poly: PackedVector2Array) -> Vector2:
	var best := poly[0]
	var best_d := INF
	for i in poly.size() - 1:
		var a := poly[i]
		var b := poly[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0) if len2 > 0.001 else 0.0
		var q := a + ab * t
		var d := p.distance_to(q)
		if d < best_d:
			best_d = d
			best = q
	return best


## Regla del usuario: si un CENTER hace un zigzag sin sentido real, se lo
## IGNORA y el trazado pasa directo al siguiente — vía/carretera mejor
## formada desde el origen, antes de cualquier suavizado.
## APARTADEROS (#115, regla del usuario): en lugares random de la vía, un ramal
## que se SEPARA un poco de la principal y VUELVE (bucle de cruce), sobre una
## tirada de `sep` centers. Ahí viven los trenes-spawn sin tapar la vía
## principal. Devuelve una polilínea por apartadero (empieza/termina en la vía).
## Los 2 puntos de rama se eligen SEPARADOS 6-10 "centers" del trayecto
## principal (regla del usuario). rail_pts está resampleado (~5 m), así que un
## center del grafo ≈ ~4 puntos → 6-10 centers ≈ 24-40 puntos. Entre las ramas
## el ramal corre PARALELO (bucle de cruce), no un bulto: rampa → paralelo →
## rampa (trapezoide), para que quepa un tren aparcado sin tapar la principal.
static func make_sidings(rail_pts: PackedVector2Array, rng_seed: int,
		count: int, sep_min: int = 24, sep_max: int = 40,
		offset_m: float = 7.0) -> Array:
	var out: Array = []
	var n := rail_pts.size()
	if n < sep_max + 6 or count <= 0:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var used: Array[int] = []
	var tries := 0
	while out.size() < count and tries < count * 16:
		tries += 1
		var sep := rng.randi_range(sep_min, sep_max)
		var i0 := rng.randi_range(2, n - sep - 3)
		var clash := false
		for u in used:
			if absi(u - i0) < sep + 8:
				clash = true
				break
		if clash:
			continue
		used.append(i0)
		var side := 1.0 if rng.randf() < 0.5 else -1.0
		var poly := PackedVector2Array()
		var ramp := 0.22  # fracción de rampa a cada extremo
		for k in range(i0, i0 + sep + 1):
			var t := float(k - i0) / float(sep)     # 0..1
			# Trapezoide: sube en [0,ramp], paralelo en [ramp,1-ramp], baja.
			var env := smoothstep(0.0, ramp, t) * (1.0 - smoothstep(1.0 - ramp, 1.0, t))
			var dir := (rail_pts[mini(k + 1, n - 1)]
					- rail_pts[maxi(k - 1, 0)]).normalized()
			var perp := Vector2(-dir.y, dir.x)
			poly.append(rail_pts[k] + perp * (offset_m * side * env))
		out.append(poly)
	return out


## Detector de ZIGZAG POR ÁREA (Douglas-Peucker): descarta los centers cuyo
## desvío respecto a la línea entre puntos conservados es menor que `tol` metros
## → los serruchos locales colapsan a un trazo limpio, conservando la forma
## general (regla del usuario: darse cuenta del zigzag por metros y simplificar).
## Trabaja sobre polilínea ABIERTA (para anillos se llama antes de cerrar).
static func _douglas_peucker(pts: PackedVector2Array, tol: float) -> PackedVector2Array:
	var n := pts.size()
	if n < 3:
		return pts
	var keep := PackedByteArray()
	keep.resize(n)
	keep[0] = 1
	keep[n - 1] = 1
	# Pila de rangos [inicio, fin] a procesar (iterativo, sin recursión).
	var stack: Array[Vector2i] = [Vector2i(0, n - 1)]
	while not stack.is_empty():
		var r: Vector2i = stack.pop_back()
		var a := pts[r.x]
		var b := pts[r.y]
		var ab := b - a
		var len2 := ab.length_squared()
		var max_d := -1.0
		var max_i := -1
		for i in range(r.x + 1, r.y):
			var t := clampf((pts[i] - a).dot(ab) / len2, 0.0, 1.0) if len2 > 0.001 else 0.0
			var d := pts[i].distance_to(a + ab * t)
			if d > max_d:
				max_d = d
				max_i = i
		if max_d > tol and max_i > 0:
			keep[max_i] = 1
			stack.append(Vector2i(r.x, max_i))
			stack.append(Vector2i(max_i, r.y))
	var out := PackedVector2Array()
	for i in n:
		if keep[i] == 1:
			out.append(pts[i])
	return out


## Descarte de centers zigzag con LOOK-AHEAD (regla del usuario: al descartar,
## seguir al MEJOR siguiente center, viendo el mejor trayecto). Cuando un center
## produce un giro > max_turn, prueba saltar 1..3 centers y elige el que deja el
## giro más suave (mejor continuación), en vez de tomar siempre el siguiente.
## Giro máximo de camino/vía (regla del usuario: curvas ≥120° interior → giro
## exterior ≤60°). Más allá, se descarta el center que lo causa.
const MAX_CURVE_TURN := PI / 3.0   # 60°


## Cap DURO del giro (regla del usuario: curvas ≥120° interior = giro ≤60°).
## Descarta iterativamente el center del giro MÁS AGUDO hasta que ninguno supere
## `max_turn`, SIN romper el circuito (cíclico si closed; nunca baja de min_pts).
## Garantía robusta en cualquier seed (no solo donde el relax alcanza). Chaikin
## posterior redondea estos vértices en arcos → curvas finales bien suaves.
static func _enforce_max_turn(pts: PackedVector2Array, max_turn: float,
		closed: bool, min_pts: int = 6) -> PackedVector2Array:
	var out := pts.duplicate()
	while out.size() > min_pts:
		var n := out.size()
		var worst_i := -1
		var worst := max_turn
		var lo := 0 if closed else 1
		var hi := n if closed else n - 1
		for i in range(lo, hi):
			var a := out[(i - 1 + n) % n]
			var b := out[i]
			var c := out[(i + 1) % n]
			var v0 := b - a
			var v1 := c - b
			if v0.length_squared() < 0.01 or v1.length_squared() < 0.01:
				continue
			var turn := absf(v0.angle_to(v1))
			if turn > worst:
				worst = turn
				worst_i = i
		if worst_i < 0:
			break  # todos los giros ya ≤ max_turn
		out.remove_at(worst_i)
	return out


static func _drop_zigzag(pts: PackedVector2Array, max_turn: float = 1.1,
		passes: int = 2) -> PackedVector2Array:
	var cur := pts
	for _p in passes:
		if cur.size() < 4:
			return cur
		var out := PackedVector2Array([cur[0]])
		var i := 1
		while i < cur.size() - 1:
			var prev := out[out.size() - 1]
			var v0 := cur[i] - prev
			var v1 := cur[i + 1] - cur[i]
			var sharp := v0.length_squared() > 0.01 and v1.length_squared() > 0.01 \
					and absf(v0.angle_to(v1)) > max_turn
			if sharp:
				# Buscar entre i..i+3 el center que deja el giro prev→cand→sig
				# más suave (mejor trayecto). Se salta lo del medio.
				var best_k := i
				var best_turn := INF
				for k in range(i, mini(i + 4, cur.size() - 1)):
					var a := (cur[k] - prev)
					var b := (cur[k + 1] - cur[k])
					if a.length_squared() < 0.01 or b.length_squared() < 0.01:
						continue
					var turn := absf(a.angle_to(b))
					if turn < best_turn:
						best_turn = turn
						best_k = k
				out.append(cur[best_k])
				i = best_k + 1
				continue
			out.append(cur[i])
			i += 1
		out.append(cur[cur.size() - 1])
		cur = out
	return cur


## Relaja esquinas cerradas: si el giro en un punto supera max_turn (rad), el
## punto se acerca al promedio de sus vecinos. Las curvas se ABREN y se toman
## su espacio (regla del usuario) — nada de picos ni quiebres.
static func _relax_sharp(pts: PackedVector2Array, max_turn: float,
		passes: int) -> PackedVector2Array:
	var out := pts.duplicate()
	for _p in passes:
		for i in range(1, out.size() - 1):
			var v0 := out[i] - out[i - 1]
			var v1 := out[i + 1] - out[i]
			if v0.length_squared() < 0.01 or v1.length_squared() < 0.01:
				continue
			var ang := absf(v0.angle_to(v1))
			if ang > max_turn:
				# Colapso PROPORCIONAL: cuanto más cerca de 90°+ (hairpin), más
				# se acerca al punto medio — nada de codos de casi 90° (feos en
				# vías, regla del usuario). Cerca de 180° casi funde los vecinos.
				var over := clampf((ang - max_turn) / (PI - max_turn), 0.0, 1.0)
				out[i] = out[i].lerp((out[i - 1] + out[i + 1]) * 0.5,
						0.55 + 0.4 * over)
	return out


## Índice del punto de poly más cercano a p.
static func _nearest_index_on(p: Vector2, poly: PackedVector2Array) -> int:
	var best := 0
	var best_d := INF
	for i in poly.size():
		var d := p.distance_squared_to(poly[i])
		if d < best_d:
			best_d = d
			best = i
	return best


## Resample uniforme por longitud de arco: un punto cada step metros.
static func _resample(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	if pts.size() < 2:
		return pts
	var out := PackedVector2Array([pts[0]])
	var next_d := step
	var traveled := 0.0
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.0001:
			continue
		while next_d <= traveled + seg:
			out.append(a.lerp(b, (next_d - traveled) / seg))
			next_d += step
		traveled += seg
	if out[out.size() - 1].distance_to(pts[pts.size() - 1]) > step * 0.25:
		out.append(pts[pts.size() - 1])
	return out


static func _min_dist_to_polyline(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	for i in range(0, poly.size() - 1, 2):
		var a := poly[i]
		var b := poly[mini(i + 2, poly.size() - 1)]
		var ab := b - a
		var len2 := ab.length_squared()
		var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0) if len2 > 0.001 else 0.0
		best = minf(best, p.distance_to(a + ab * t))
	return best


func build_road_layers(width_m: float, falloff_m: float,
		river_layers: Array[HeightLayer] = []) -> Array[HeightLayer]:
	var out: Array[HeightLayer] = []
	var roads := _generator.get_roads()
	if roads == null or roads.circuit.size() < 2:
		return out
	var pts := PackedVector2Array()
	for c in roads.circuit:
		pts.append((c as Center).point)
	var layer := PathCarveLayer.new()
	layer.layer_name = &"road_flatten"
	layer.path_mode = PathCarveLayer.PathMode.FLATTEN_ALONG
	layer.target_smooth_passes = 6
	layer.max_grade = 0.06
	layer.smooth_window_m = 45.0
	layer.cut_bias = 0.35   # prefiere CORTAR lomas antes que rellenar valles
	# El terreno VECINO acompaña al terraplén/desmonte (regla del usuario:
	# no un muro — la zona entera se adapta con talud tendido).
	layer.max_bank_slope = 0.55
	# Centers zigzag FUERA primero (regla del usuario), después desviar,
	# re-suavizar (con WRAP si es anillo: el empalme inicio/fin queda liso),
	# relajar giros y resample: curvas que se abren de verdad.
	layer.points = _smooth_route(pts, roads.closed_loop, river_layers,
			1.1, 2, 0.32, 6.0)
	layer.is_ring = roads.closed_loop  # grading cíclico → empalme sin escalón
	layer.width_m = width_m
	layer.depth_m = 0.0
	layer.falloff_m = falloff_m
	out.append(layer)
	return out


## Vía de tren: MISMO método que la carretera de pcg-terrain_1 (anillo por
## distancia a costa) pero con su propio shape_scale — instancia propia de
## SimpleCircuitRoad, la librería no se toca. Devuelve la polilínea también
## (RailBuilder construye rieles/durmientes encima).
var rail_points := PackedVector2Array()


func build_rail_layers(shape_scale: float, width_m: float,
		falloff_m: float, rng_seed: int,
		river_layers: Array[HeightLayer] = []) -> Array[HeightLayer]:
	rail_points = PackedVector2Array()
	var out: Array[HeightLayer] = []
	var rails := SimpleCircuitRoad.new()
	rails.shape_scale = shape_scale
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	rails.generate(graph, rng)
	if rails.circuit.size() < 2:
		return out
	var pts := PackedVector2Array()
	for c in rails.circuit:
		pts.append((c as Center).point)
	# Centers zigzag FUERA con umbral AGRESIVO (regla del usuario: un tren
	# jamás gira a 90° — si hace falta se salta el center), suavizado con
	# WRAP en anillo (inicio y fin de la vía COINCIDEN lisos) y curvas
	# grandes de radio real.
	rail_points = _smooth_route(pts, rails.closed_loop, river_layers,
			0.7, 3, 0.18, 5.0)
	var layer := PathCarveLayer.new()
	layer.layer_name = &"rail_flatten"
	layer.path_mode = PathCarveLayer.PathMode.FLATTEN_ALONG
	# Los trenes toleran aún MENOS pendiente que las carreteras.
	layer.target_smooth_passes = 8
	layer.max_grade = 0.03
	layer.smooth_window_m = 70.0
	layer.cut_bias = 0.35   # prefiere CORTAR lomas antes que rellenar valles
	layer.max_bank_slope = 0.5  # el terreno vecino acompaña el terraplén
	layer.is_ring = rails.closed_loop  # grading cíclico → empalme sin escalón
	layer.points = rail_points
	layer.width_m = width_m
	layer.falloff_m = falloff_m
	out.append(layer)
	return out


## Pipeline de trazado completo: zigzag fuera → suavizado (con WRAP si es
## anillo cerrado — el empalme inicio/fin queda liso) → desvío de ríos →
## re-suavizado → relax de giros → resample uniforme. Anillo: se re-cierra.
static func _smooth_route(pts: PackedVector2Array, closed: bool,
		river_layers: Array[HeightLayer], zigzag_turn: float,
		chaikin_passes: int, relax_turn: float, step: float,
		simplify_tol: float = 12.0) -> PackedVector2Array:
	# 1º ÁREA-zigzag (Douglas-Peucker): colapsa serruchos locales. 2º descarte
	# por giro con look-ahead. Recién después se suaviza — así las curvas se
	# abren más (menos puntos apretados que forzarían curvas cerradas).
	var cur := _drop_zigzag(_douglas_peucker(pts, simplify_tol), zigzag_turn)
	# Cap DURO del giro a 60° (interior ≥120°, regla del usuario): descarta el
	# center del giro más agudo sin romper el circuito. Garantía en todo seed.
	cur = _enforce_max_turn(cur, MAX_CURVE_TURN, closed)
	if closed:
		cur = _chaikin_ring(cur, chaikin_passes)
		cur = _deflect_from_rivers(cur, river_layers)
		cur = _chaikin_ring(cur, chaikin_passes)
		cur = _relax_ring(cur, relax_turn, 6)   # ABRE los giros (faltaba: 90°)
		cur = _resample(cur, step)
		cur = _relax_ring(cur, relax_turn, 4)   # resample reintroduce ángulos
		if cur.size() > 2:
			cur.append(cur[0])
		return cur
	cur = _relax_sharp(_resample(_relax_sharp(_chaikin(_deflect_from_rivers(
			_chaikin(cur, chaikin_passes), river_layers), chaikin_passes),
			relax_turn, 3), step), relax_turn, 3)
	return cur


## Relax de giros CÍCLICO (anillo): abre los codos cerrados envolviendo la
## costura — sin esto el circuito de la vía conservaba giros de 90°.
static func _relax_ring(pts: PackedVector2Array, max_turn: float,
		passes: int) -> PackedVector2Array:
	var n := pts.size()
	if n < 4:
		return pts
	var out := pts.duplicate()
	for _p in passes:
		var prev := out.duplicate()
		for i in n:
			var a := prev[(i - 1 + n) % n]
			var b := prev[(i + 1) % n]
			var v0 := prev[i] - a
			var v1 := b - prev[i]
			if v0.length_squared() < 0.01 or v1.length_squared() < 0.01:
				continue
			var ang := absf(v0.angle_to(v1))
			if ang > max_turn:
				var over := clampf((ang - max_turn) / (PI - max_turn), 0.0, 1.0)
				out[i] = prev[i].lerp((a + b) * 0.5, 0.55 + 0.4 * over)
	return out


## Chaikin para ANILLO cerrado (con wrap): sin puntas fijas — el cierre del
## circuito queda tan liso como cualquier otro tramo.
static func _chaikin_ring(pts: PackedVector2Array, passes: int) -> PackedVector2Array:
	var cur := pts
	for _i in passes:
		if cur.size() < 3:
			return cur
		var next := PackedVector2Array()
		for j in cur.size():
			var a := cur[j]
			var b := cur[(j + 1) % cur.size()]
			next.append(a.lerp(b, 0.25))
			next.append(a.lerp(b, 0.75))
		cur = next
	return cur


## Desvía un trazado de camino/vía de los ríos cuando corre casi PARALELO a
## menos de avoid_m (lo aplastaría a lo largo). Los CRUCES francos (ángulo
## alto) se dejan: ahí el terraplén pasa por arriba, como pide la doctrina.
static func _deflect_from_rivers(pts: PackedVector2Array,
		river_layers: Array[HeightLayer], avoid_m: float = 16.0) -> PackedVector2Array:
	if river_layers.is_empty() or pts.size() < 3:
		return pts
	# F6.5: hash espacial POR RÍO (mismo "más cercano por capa" que la fuerza
	# bruta: solo importa cuando cae bajo avoid_m, y ahí el hash lo encuentra).
	var hashes: Array[SegmentHash] = []
	for l in river_layers:
		var pl := l as PathCarveLayer
		if pl == null or pl.points.size() < 2:
			continue
		hashes.append(SegmentHash.new(pl.points))
	if hashes.is_empty():
		return pts
	var out := pts.duplicate()
	for i in range(1, pts.size() - 1):
		var path_dir := (pts[i + 1] - pts[i - 1]).normalized()
		for h in hashes:
			var info := {}
			if h.nearest_in_radius(pts[i], avoid_m, info) >= avoid_m:
				continue
			# Solo paralelismo franco (>45°): los cruces los resuelve el
			# falloff suprimido en banda de río (forense: el desvío agresivo
			# empeoraba — empujaba el terraplén ladera arriba sobre la zanja).
			var seg_dir: Vector2 = info["dir"]
			if absf(path_dir.dot(seg_dir)) > 0.7:
				# Paralelo y encima: empujar el punto lejos del río.
				var closest: Vector2 = info["closest"]
				var away := (pts[i] - closest).normalized()
				if away.length_squared() < 0.5:
					away = Vector2(-seg_dir.y, seg_dir.x)
				out[i] = closest + away * (avoid_m + 6.0)
	return out


## Suavizado de esquinas de polilínea (Chaikin corner-cutting).
static func _chaikin(pts: PackedVector2Array, passes: int) -> PackedVector2Array:
	var cur := pts
	for _i in passes:
		if cur.size() < 3:
			return cur
		var next := PackedVector2Array()
		next.append(cur[0])
		for j in cur.size() - 1:
			var a := cur[j]
			var b := cur[j + 1]
			next.append(a.lerp(b, 0.25))
			next.append(a.lerp(b, 0.75))
		next.append(cur[cur.size() - 1])
		cur = next
	return cur


## ---- Consultas (post-generación) ----

func get_center_at(world_pos: Vector2) -> Center:
	if _ctx_biome == null:
		return null   # provider en teardown/regeneración (clear_graph anuló el ctx)
	return _ctx_biome.get_center(world_pos)


func get_biome_at(world_pos: Vector2) -> String:
	# GUARDA: una populate de vegetación async (cede frames) puede consultar bioma
	# DESPUÉS de que clear_graph()/_exit_tree anuló _ctx_biome al regenerar el mapa.
	# Sin bioma, el biome_filter descarta la planta (no spawnea de más). No es mask:
	# es el manejo correcto de la carrera async teardown↔populate.
	if _ctx_biome == null:
		return ""
	return _ctx_biome.get_biome(world_pos)


func get_road_centers() -> Array[Center]:
	var roads := _generator.get_roads()
	return roads.circuit if roads != null else ([] as Array[Center])


func get_river_corners() -> Array:
	var rivers := _generator.get_rivers()
	return rivers.rivers if rivers != null else []


func get_land_centers() -> Array[Center]:
	var out: Array[Center] = []
	for c_any in graph.centers:
		var c := c_any as Center
		if not c.water:
			out.append(c)
	return out


func get_coast_centers() -> Array[Center]:
	var out: Array[Center] = []
	for c_any in graph.centers:
		var c := c_any as Center
		if c.coast:
			out.append(c)
	return out


func get_lake_centers() -> Array[Center]:
	var out: Array[Center] = []
	for c_any in graph.centers:
		var c := c_any as Center
		if c.water and not c.ocean:
			out.append(c)
	return out


func get_centers_by_biome(biome: String) -> Array[Center]:
	var out: Array[Center] = []
	for c_any in graph.centers:
		var c := c_any as Center
		if c.biome == biome:
			out.append(c)
	return out


func get_generation_step_name() -> String:
	return _generator.get_step_name() if _generator != null else ""


## El grafo de pcg-terrain_1 tiene ciclos RefCounted (Center↔Edge↔Corner con
## referencias bidireccionales) que el conteo de referencias NUNCA libera.
## Sin esto, cada generación fuga ~30k objetos (crítico en un server MP que
## regenera mapas). Se rompen los ciclos a mano al salir del árbol.
func _exit_tree() -> void:
	clear_graph()


func clear_graph() -> void:
	if graph == null:
		return
	for c_any in graph.centers:
		var c := c_any as Center
		c.neighbors.clear()
		c.borders.clear()
		c.corners.clear()
	for co_any in graph.corners:
		var co := co_any as Corner
		co.touches.clear()
		co.protrudes.clear()
		co.adjacent.clear()
		co.downslope = null
		co.watershed = null
	for e_any in graph.edges:
		var e := e_any as Edge
		e.d0 = null
		e.d1 = null
		e.v0 = null
		e.v1 = null
	graph.centers.clear()
	graph.corners.clear()
	graph.edges.clear()
	graph = null
	_generator = null
	_ctx_biome = null
