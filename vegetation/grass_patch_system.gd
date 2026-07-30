class_name GrassPatchSystem
extends Node3D

## ============================================================================
## GrassPatchSystem · Pasto DENSO por parches alrededor del jugador (#56.1)
## ============================================================================
## Port CPU del diseño mb_grass_* de Melba/preface-shaders: el mundo se divide
## en celdas; solo las celdas dentro del radio de la cámara tienen un
## MultiMesh de matas denso. Al moverse, las celdas nuevas se construyen
## (determinista por celda — MP-safe) y las lejanas se liberan. El pasto
## global disperso de VegetationSystem sigue cubriendo la distancia.
##
## Las TRANSFORMS de cada celda se calculan en WorkerThreadPool (patrón
## TerrainPatch3D de forest-demo): el hilo principal solo sube el buffer al
## MultiMesh — sin microtirones al caminar. El task hace SOLO lecturas puras
## del bake (sampler/topology); el bioma se resuelve en el main thread al
## despachar (la caché de localización del provider NO es thread-safe).
## Headless/sin cámara: inactivo (los tests no lo tocan).
## ============================================================================

const CELL := 14.0
const PER_CELL := 300
const UPDATE_S := 0.4
## Tope GLOBAL de briznas vivas (técnica MGrass.grass_count_limit): si el total
## de instancias supera esto, no se despachan celdas nuevas (las lejanas quedan
## sin pasto antes que las cercanas — la cola ya está ordenada por cercanía).
## Con RADIUS/PER_CELL actuales el total ronda 25k; es una red de seguridad para
## cuando esos suban (calidad ultra / radio mayor). 0 = sin límite.
const GRASS_COUNT_LIMIT := 60000
## Amortización: despachar POCOS tasks por frame; los completados se aplican
## cuando terminan. Liberar solo más allá de RADIUS·RELEASE_MULT (histéresis)
## evita reconstruir al ir y volver.
const MAX_DISPATCH_PER_FRAME := 3
const RELEASE_MULT := 1.35


## Radio de parches POR PRESET (AUDITORÍA_LOD A3: era 64 m fijo para todos, contra
## la plantilla). potato 22 · bajo 38 · medio 55 · alto 70 · ultra 90 (= distancia).
func _radius() -> float:
	return [22.0, 38.0, 55.0, 70.0, 90.0][clampi(VegetationQuality.preset_index, 0, 4)]


## Fin de la mata 3D (después, billboard cruzado). potato/bajo 0 = todo billboard.
func _near_r() -> float:
	return [0.0, 0.0, 20.0, 28.0, 34.0][clampi(VegetationQuality.preset_index, 0, 4)]

var sampler: HeightSampler
var topology: TopologyMap
var sea_level: float = 0.0
var blade_mesh: Mesh
## Provider para consultar el bioma de cada celda (pasto por bioma, Fase 3).
## Si es null, todas las celdas usan blade_mesh (comportamiento previo).
var data_provider: MapDataProvider
## Escala de densidad (calidad de Opciones).
var density_scale: float = 1.0
## Cámara que MANDA (null = la activa del viewport). Para espectador/debug:
## el test de frustum (frustum_spy_test) fija acá la cámara del jugador.
var camera_override: Camera3D = null
## Contenedor espacial que decide qué parcelas EXISTEN (el QuadtreeMeshLOD del
## terreno). Si está seteado y tiene frustum_cull, el pasto fuera del cono del
## player no se construye. null = comportamiento por radio de siempre.
var spatial_gate = null

## Cache bioma → mata de pasto (se genera una vez por bioma visto).
var _blade_cache: Dictionary = {}
## Cache bioma → billboard cruzado (LOD barato para calidad Baja).
var _blade_bb_cache: Dictionary = {}

var _patches: Dictionary = {}   # Vector2i → MultiMeshInstance3D
var _total_grass := 0           # instancias vivas (para GRASS_COUNT_LIMIT)
var _build_queue: Array[Vector2i] = []
var _queued: Dictionary = {}    # Vector2i → true (evita duplicar en la cola)
## Tasks en vuelo: Vector2i → {tid, blade, result} — result[0] lo escribe SOLO
## el task; se lee recién cuando is_task_completed (barrera del pool).
var _pending: Dictionary = {}
var _accum := 0.0
## XZ del último escaneo. INF = nunca escaneó ⇒ el PRIMER _process escanea ya (sin
## 0.4 s de mundo pelado al arrancar) y un SALTO de cámara (spawn/teleport/respawn)
## fuerza el rescan al instante en vez de esperar el tick.
var _last_scan := Vector2(INF, INF)


## ¿Terminó de construir todo lo que quiere? (bancos/capturas: esperar a esto en vez
## de a un número fijo de frames — el llenado inicial es async).
func is_idle() -> bool:
	return _pending.is_empty() and _build_queue.is_empty()


## Cámara que MANDA el LOD: player local (PlayerRegistry) o la activa del viewport.
func _lod_camera() -> Camera3D:
	if typeof(PlayerRegistry) != TYPE_NIL and PlayerRegistry != null:
		var c: Camera3D = PlayerRegistry.active_camera()
		if c != null:
			return c
	return get_viewport().get_camera_3d() if get_viewport() != null else null


func _process(delta: float) -> void:
	var cam := camera_override if camera_override != null else _lod_camera()
	if cam == null or sampler == null or topology == null or blade_mesh == null:
		return
	var c := cam.global_position

	# Escaneo de celdas deseadas: solo cada UPDATE_S (barato); actualiza la COLA
	# de construcción y libera las lejanas con histéresis. NO construye acá.
	_accum += delta
	var cxz0 := Vector2(c.x, c.z)
	if _accum >= UPDATE_S or cxz0.distance_squared_to(_last_scan) > CELL * CELL:
		_accum = 0.0
		_last_scan = cxz0
		var cc := Vector2i(int(floorf(c.x / CELL)), int(floorf(c.z / CELL)))
		var radius := _radius()
		var span := int(ceilf(radius / CELL))
		var release := radius * RELEASE_MULT
		for dy in range(-span, span + 1):
			for dx in range(-span, span + 1):
				var key := cc + Vector2i(dx, dy)
				var center := Vector2((float(key.x) + 0.5) * CELL, (float(key.y) + 0.5) * CELL)
				if center.distance_to(Vector2(c.x, c.z)) > radius:
					continue
				# CONO del player: si la parcela no entra en el frustum, ni se construye
				# (un test descarta las ~18k briznas de esa celda). Lo decide el MISMO
				# quadtree del terreno → pasto y suelo comparten el criterio.
				if spatial_gate != null and not spatial_gate.area_in_frustum(center, CELL):
					continue
				if not _patches.has(key) and not _queued.has(key) \
						and not _pending.has(key):
					_queued[key] = true
					_build_queue.append(key)
		# Liberar solo lo que quedó MÁS ALLÁ del radio de retención (histéresis).
		for key: Vector2i in _patches.keys():
			var center := Vector2((float(key.x) + 0.5) * CELL, (float(key.y) + 0.5) * CELL)
			if center.distance_to(Vector2(c.x, c.z)) > release:
				var pm: Node3D = _patches[key]
				_total_grass -= int(pm.get_meta(&"grass_n", 0))
				pm.queue_free()
				_patches.erase(key)

	# Aplicar tasks COMPLETADOS (subir buffer al MultiMesh: barato, sin muestreos).
	for key: Vector2i in _pending.keys():
		var e: Dictionary = _pending[key]
		if not WorkerThreadPool.is_task_completed(e.tid):
			continue
		WorkerThreadPool.wait_for_task_completion(e.tid)
		_pending.erase(key)
		if _patches.has(key):
			continue
		_patches[key] = _make_patch_mmi(key, e.blade3d, e.blade_bb, (e.result as Array)[0])

	# Despachar a lo sumo MAX_DISPATCH_PER_FRAME celdas nuevas, las más cercanas
	# primero. El cálculo pesado (topología/altura/slope por mata) va al pool.
	if _build_queue.is_empty():
		return
	var cxz := Vector2(c.x, c.z)
	_build_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var ca := Vector2((float(a.x) + 0.5) * CELL, (float(a.y) + 0.5) * CELL)
		var cb := Vector2((float(b.x) + 0.5) * CELL, (float(b.y) + 0.5) * CELL)
		return ca.distance_squared_to(cxz) < cb.distance_squared_to(cxz))
	var dispatched := 0
	while dispatched < MAX_DISPATCH_PER_FRAME and not _build_queue.is_empty():
		# Tope global (MGrass): con el presupuesto lleno, no despachar más (la cola
		# está ordenada por cercanía → se sacrifican las celdas lejanas).
		if GRASS_COUNT_LIMIT > 0 and _total_grass >= GRASS_COUNT_LIMIT:
			break
		var key: Vector2i = _build_queue.pop_front()
		_queued.erase(key)
		if _patches.has(key) or _pending.has(key):
			continue
		_dispatch_patch(key)
		dispatched += 1


## Resuelve bioma/densidad EN MAIN THREAD (caché no thread-safe) y despacha el
## cálculo de transforms al WorkerThreadPool.
func _dispatch_patch(key: Vector2i) -> void:
	# LOD de pasto (docs/LOD_PLANTILLA §5): mata 3D (~108 tris) cerca + BILLBOARD
	# cruzado (~8 tris) lejos (Media+); en Baja todo billboard. Se resuelven ambas
	# mallas del bioma (una vez por bioma); el LOD por distancia lo hace
	# visibility_range en _make_patch_mmi.
	var blade3d := blade_mesh
	var blade_bb := blade_mesh
	var dens := 1.0
	if data_provider != null:
		var center := Vector2((float(key.x) + 0.5) * CELL, (float(key.y) + 0.5) * CELL)
		var biome: String = data_provider.get_biome_at(center)
		if not _blade_cache.has(biome):
			_blade_cache[biome] = BiomeFloraLibrary.build_grass_blade(biome)
		if not _blade_bb_cache.has(biome):
			_blade_bb_cache[biome] = BiomeFloraLibrary.build_grass_billboard(biome)
		blade3d = _blade_cache[biome]
		blade_bb = _blade_bb_cache[biome]
		dens = BiomeFloraLibrary.grass_for(biome).get("density", 1.0)
	# Calidad de pasto de Opciones (densidad): multiplica el conteo por celda. Se
	# aplica a las celdas NUEVAS al moverse (las ya construidas se rehacen al reentrar).
	var gq := 1.0
	if typeof(Settings) != TYPE_NIL and Settings != null:
		gq = clampf(float(Settings.get_value(&"graphics", &"grass_quality", 1.0)), 0.2, 1.5)
	var count := int(PER_CELL * density_scale * dens * gq)
	var result: Array = [null]  # slot que escribe SOLO el task
	var tid := WorkerThreadPool.add_task(
			_compute_patch_transforms.bind(key, count, result),
			false, "GrassPatch %s" % str(key))
	_pending[key] = {"tid": tid, "blade3d": blade3d, "blade_bb": blade_bb, "result": result}


## CORRE EN WORKER: solo lecturas puras del bake (sampler/topology inmutables
## post-generación). Determinista por celda: mismas matas en cualquier cliente.
func _compute_patch_transforms(key: Vector2i, count: int, result: Array) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([key.x, key.y, "grass_patch"])
	var transforms: Array[Transform3D] = []
	for _i in count:
		var pos := Vector2((float(key.x) + rng.randf()) * CELL,
				(float(key.y) + rng.randf()) * CELL)
		if not topology.has_any(pos, TopologyMap.TOPO_FIELD
				| TopologyMap.TOPO_FOREST | TopologyMap.TOPO_FORESTSIDE):
			continue
		# También el BALASTO/banquina (ROADSIDE/RAILSIDE): nada de pasto sobre
		# la vía ni sus durmientes (regla del usuario).
		if topology.has_any(pos, TopologyMap.TOPO_ROAD | TopologyMap.TOPO_RAIL
				| TopologyMap.TOPO_ROADSIDE | TopologyMap.TOPO_RAILSIDE
				| TopologyMap.TOPO_RIVER | TopologyMap.TOPO_LAKE
				| TopologyMap.TOPO_OCEAN | TopologyMap.TOPO_BEACH):
			continue
		var h: float = sampler.get_height(pos)
		if h < sea_level + 0.3 or sampler.get_slope(pos) > 0.5:
			continue
		var s := rng.randf_range(0.55, 1.05)
		var spin := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
		transforms.append(Transform3D(spin, Vector3(pos.x, h - 0.03, pos.y)))
	result[0] = transforms


## EN MAIN THREAD: contenedor de la celda con la mata 3D (cerca) + billboard
## (lejos). El LOD por distancia lo hace visibility_range (dist a la AABB de la
## celda) → sin rebuild al acercarse. Baja: solo billboard en todo el rango.
func _make_patch_mmi(key: Vector2i, blade3d: Mesh, blade_bb: Mesh, transforms_any: Variant) -> Node3D:
	var transforms := transforms_any as Array[Transform3D]
	var root := Node3D.new()
	root.name = "Patch_%d_%d" % [key.x, key.y]
	# Celda sin pasto (agua/roca/calzada): nodo vacío igual — marca construida.
	if transforms == null or transforms.is_empty():
		add_child(root)
		return root
	root.set_meta(&"grass_n", transforms.size())
	_total_grass += transforms.size()
	# AABB compartido (margen de viento §6.1: GrassWind dobla las matas en GPU).
	var bb := AABB(transforms[0].origin, Vector3.ZERO)
	for i in transforms.size():
		bb = bb.expand(transforms[i].origin)
	bb = bb.grow(1.6)
	bb.size.y += 1.6
	var fade_end := _radius() * 1.15
	var near_r := _near_r()
	if near_r <= 0.0:   # potato + bajo: pasto todo billboard
		root.add_child(_grass_mmi(blade_bb, transforms, bb, 0.0, fade_end))
	else:
		root.add_child(_grass_mmi(blade3d, transforms, bb, 0.0, near_r))
		root.add_child(_grass_mmi(blade_bb, transforms, bb, near_r, fade_end))
	add_child(root)
	return root


## Un MultiMeshInstance3D de pasto con rango de visibilidad [vbegin, vend].
func _grass_mmi(mesh: Mesh, transforms: Array[Transform3D], bb: AABB,
		vbegin: float, vend: float) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	mmi.multimesh = mm
	mmi.custom_aabb = bb
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if vbegin > 0.0:
		mmi.visibility_range_begin = vbegin
		mmi.visibility_range_begin_margin = 4.0
	mmi.visibility_range_end = vend
	mmi.visibility_range_end_margin = clampf((vend - vbegin) * 0.15, 2.0, 8.0)
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return mmi


func _exit_tree() -> void:
	# No dejar tasks huérfanos apuntando a un nodo muerto.
	for key: Vector2i in _pending.keys():
		WorkerThreadPool.wait_for_task_completion((_pending[key] as Dictionary).tid)
	_pending.clear()
