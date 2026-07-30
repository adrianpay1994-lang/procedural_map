class_name BiomeFloraLibrary
extends RefCounted

## ============================================================================
## BiomeFloraLibrary · Catálogo declarativo de flora por bioma (Fase 1)
## ============================================================================
## Dos ejes de variedad:
##  · INTER-bioma: cada bioma declara sus especies (trees_for).
##  · INTRA-bioma: build_tree_pool genera K meshes variantes por especie
##    (seeds distintos) → un bosque deja de ser clones idénticos.
## Biomas = taxonomía mapgen2/Whittaker (get_biome_at del map_data_provider).
## ============================================================================


## Especies de árbol (TreeParams Weber-Penn) de un bioma. Vacío = sin árboles
## WP (el bioma usa flora legacy: acacia/palmera/arbusto de FloraFactory).
static func trees_for(biome: String) -> Array[TreeParams]:
	match biome:
		"TEMPERATE_DECIDUOUS_FOREST":
			return [TreeParams.aspen(), TreeParams.black_oak(), TreeParams.silver_birch()]
		"TEMPERATE_RAIN_FOREST":  # Bosque Andino-Patagónico (Nothofagus)
			return [TreeParams.coihue(), TreeParams.nire(), TreeParams.arrayan(),
					TreeParams.notro(), TreeParams.maiten(), TreeParams.cipres_cordillera()]
		"TAIGA":  # bosque de altura + araucaria
			return [TreeParams.balsam_fir(), TreeParams.small_pine(),
					TreeParams.araucaria(), TreeParams.nire()]
		"TROPICAL_RAIN_FOREST":  # Selva Misionera (emergentes + dosel + araucaria)
			return [TreeParams.palo_rosa(), TreeParams.lapacho(), TreeParams.araucaria(),
					TreeParams.ceibo(), TreeParams.cedro(), TreeParams.timbo(),
					TreeParams.guatambu(), TreeParams.incienso(), TreeParams.peteribi(),
					TreeParams.anchico(), TreeParams.yerba_mate(), TreeParams.ambay()]
		"TROPICAL_SEASONAL_FOREST":  # Yungas / transición
			return [TreeParams.lapacho(), TreeParams.lapacho_amarillo(), TreeParams.ceibo(),
					TreeParams.cedro(), TreeParams.laurel(), TreeParams.algarrobo(),
					TreeParams.tipa()]
		"SHRUBLAND":  # Chaco/Monte seco
			return [TreeParams.algarrobo(), TreeParams.quebracho(), TreeParams.chanar(),
					TreeParams.palo_borracho(), TreeParams.espinillo(),
					TreeParams.quebracho_blanco()]
		_:
			return []


## Genera K meshes EN PARALELO (WorkerThreadPool) — PERF-CARGA: la generación
## de mallas era el 60 % del tiempo de carga (220 mallas secuenciales en main
## thread). Cada task escribe SOLO su slot del array (pre-dimensionado, sin
## resize concurrente); gen_fn debe ser pura por (índice) — determinismo
## intacto: mismos seeds, mismo resultado, solo cambia QUIÉN lo calcula.
static func _parallel_pool(k: int, gen_fn: Callable) -> Array[Mesh]:
	k = maxi(1, k)
	var out: Array[Mesh] = []
	out.resize(k)
	if k == 1:
		out[0] = gen_fn.call(0)
		return out
	var tid := WorkerThreadPool.add_group_task(
			func(i: int) -> void: out[i] = gen_fn.call(i),
			k, -1, false, "BiomeFlora pool")
	WorkerThreadPool.wait_for_group_task_completion(tid)
	return out


# --- Caché de mallas a DISCO (OPTIMIZACION_MTERRAIN §6.1): generar 1 vez, después
# cargar del disco (corta el grueso del 42% de carga). Key = versión + tag + seed + k
# + hash de TODOS los @export de params → si algo cambia, regenera solo (invalidación
# segura). Subir MESH_CACHE_VERSION invalida todo. Fallback total: cualquier fallo de
# I/O → se genera igual (nunca rompe). Mismo patrón que user://impostor_cache.
const MESH_CACHE_DIR := "user://veg_mesh_cache/"
const MESH_CACHE_VERSION := 1


## Pool de K meshes variantes de una especie (seeds descorrelacionados).
## Determinista: mismo (params, base_seed, k) → mismos meshes en todo cliente.
static func build_tree_pool(params: TreeParams, base_seed: int, k: int,
		category: String = "tree") -> Array[Mesh]:
	# FloraConfig (inspector): modelo PROPIO de flora entera → todas las variantes
	# son ese mesh (el impostor lejano se hornea de él = "mi modelo vuelto imagen").
	var whole := _whole_model_for(category)
	if whole != null:
		var same: Array[Mesh] = []
		same.resize(maxi(1, k))
		same.fill(whole)
		return same
	# Overridea hoja/corteza por categoría. Sin config activa devuelve el mismo
	# params (0 costo). Como el cache_key hashea TODOS los campos del params
	# resuelto, cambiar la config invalida el caché solo.
	params = FloraConfig.apply_active(params, category)
	var key := _cache_key(params, base_seed, k, "full")
	var hit := _pool_from_cache(key, k)
	if not hit.is_empty():
		return hit
	var pool := _parallel_pool(k, func(i: int) -> Mesh:
		return FloraFactory.make_tree(params, base_seed + i * 1013))
	_pool_to_cache(key, pool)
	return pool


## Modelo de flora entera de la categoría en la config activa, o null.
static func _whole_model_for(category: String) -> Mesh:
	if FloraConfig.active == null:
		return null
	return FloraConfig.active.bush_model if category == "bush" \
			else FloraConfig.active.tree_model


static func _cache_key(params: TreeParams, base_seed: int, k: int, tag: String) -> String:
	var vals: Array = [MESH_CACHE_VERSION, tag, base_seed, k]
	if params != null:
		for p in params.get_property_list():
			if int(p.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				vals.append(params.get(p.name))
	return str(hash(vals))


## Caché EN MEMORIA entre generaciones (static → sobrevive a regenerar mapas en la
## MISMA sesión). El pool_seed es FIJO por bioma (no por seed de mapa), así que
## regenerar un mundo reusa las mismas mallas: cero recomputo del 42% de carga.
## NOTA: el caché a DISCO se intentó (MESH_CACHE_DIR) pero ResourceSaver.save de
## una ArrayMesh con material procedural (ShaderMaterial + BarkTexture generada)
## FALLA ("Initializing already initialized RID" / mem null) → nunca creaba
## archivos y spameaba errores. Persistir a disco necesita un serializador de
## SOLO GEOMETRÍA (surface arrays) + re-armar el material al cargar — pendiente.
static var _mem_cache: Dictionary = {}   # key → Array[Mesh]


## Devuelve el pool cacheado en memoria, o [] si no está (→ el llamador genera).
static func _pool_from_cache(key: String, k: int) -> Array[Mesh]:
	var hit: Array = _mem_cache.get(key, [])
	if hit.size() == k:
		return hit as Array[Mesh]
	return [] as Array[Mesh]


static func _pool_to_cache(key: String, pool: Array[Mesh]) -> void:
	_mem_cache[key] = pool


## Pool LOD-lejano de una especie: mismos seeds que build_tree_pool (misma
## silueta) pero baratísimo (detail 0.12, 2 segmentos, 4 lados, cards grandes).
## Para instancias lejanas vía visibility_range (Fase 5).
## `detail`: 0.45 = LOD1 reducido (≈50%); 0.18 = LOD2 muy reducido (antes del impostor).
static func build_tree_lod_pool(params: TreeParams, base_seed: int, k: int, detail := 0.45,
		category: String = "tree") -> Array[Mesh]:
	# Modelo propio: sin LODs reducidos (el mesh del usuario no se re-teselaría);
	# el mismo modelo sirve de "far" y el impostor lo abarata de lejos.
	var whole := _whole_model_for(category)
	if whole != null:
		var same: Array[Mesh] = []
		same.resize(maxi(1, k))
		same.fill(whole)
		return same
	params = FloraConfig.apply_active(params, category)   # FloraConfig (inspector)
	var lod := params.duplicate() as TreeParams
	# Con el presupuesto pro de copa (full ya es barato), el far debe adelgazar en
	# serio: presupuesto de sprays explícito por pool + menos densidad, cards más
	# grandes (la textura compensa la cobertura).
	lod.canopy_budget_override = 300 if detail >= 0.4 else 120
	lod.canopy_density_override = clampf(detail * 0.8, 0.12, 0.4)
	lod.detail = detail
	lod.max_curve_res = 3
	lod.trunk_sides = 3
	lod.leaf_count = maxi(10, floori(params.leaf_count * detail * 1.1))
	lod.leaf_card_size = params.leaf_card_size * (1.9 if detail >= 0.4 else 2.6)  # menos cards, más grandes
	var key := _cache_key(params, base_seed, k, "far%d" % int(detail * 100.0))
	var hit := _pool_from_cache(key, k)
	if not hit.is_empty():
		return hit
	var pool := _parallel_pool(k, func(i: int) -> Mesh:
		return FloraFactory.make_tree(lod, base_seed + i * 1013))
	# LOD lejano ESTÁTICO + material barato (viento/corteza/backlight off). Un árbol 3D
	# lejano meciéndose junto al impostor 2D estático se ve como "dos versiones" — y el
	# viento lejano es trabajo de vértice regalado. Se corre en el hilo principal.
	for m in pool:
		_cheapen_far_lod(m)
	_pool_to_cache(key, pool)
	return pool


## Abarata el material de un mesh para LOD LEJANO (agnóstico al modelo: sirve igual
## si algún día son .glb). Duplica el material de cada superficie (para no pisar otros
## meshes) y: (1) apaga el viento (LOD lejano estático), (2) saca el normal-map de
## corteza (un sampler menos por fragmento), (3) saca el backlight de hoja. A 55-160 m
## no se distingue y baja el costo de fragmento. set_shader_parameter en un uniform que
## el shader no tenga es inocuo.
static func _cheapen_far_lod(mesh: Mesh) -> void:
	if mesh == null:
		return
	for i in mesh.get_surface_count():
		var sm := mesh.surface_get_material(i) as ShaderMaterial
		if sm == null:
			continue
		var dm := sm.duplicate() as ShaderMaterial
		# Viento REDUCIDO (no cero): las cruzadas ahora se mecen (CrossedWind) —
		# un far 3D totalmente quieto al lado de una cruzada meciéndose delataba
		# la transición (reporte del usuario: "uno con viento y otro sin").
		dm.set_shader_parameter(&"wind_strength", 0.35)
		dm.set_shader_parameter(&"sway_strength", 0.35)
		dm.set_shader_parameter(&"gust_strength", 0.0)
		dm.set_shader_parameter(&"use_bark", false)            # sin normal-map de corteza
		dm.set_shader_parameter(&"backlight_tint", Color(0, 0, 0))  # sin backlight de hoja
		if mesh is ArrayMesh:
			(mesh as ArrayMesh).surface_set_material(i, dm)


## Pool de K variantes de una flora legacy de FloraFactory (make_acacia/palm/bush).
## `fn` = Callable que toma un seed int y devuelve un Mesh.
static func build_legacy_pool(fn: Callable, base_seed: int, k: int) -> Array[Mesh]:
	return _parallel_pool(k, func(i: int) -> Mesh:
		return fn.call(base_seed + i * 1013))


## ---- Sotobosque por bioma (Fase 2): arbustos, plantas, flores ----

## Arbusto del bioma (TreeParams, reusa TreeGenerator+pool+LOD). null = sin arbusto.
static func bush_for(biome: String) -> TreeParams:
	match biome:
		"TEMPERATE_DECIDUOUS_FOREST", "TEMPERATE_RAIN_FOREST", \
		"TROPICAL_RAIN_FOREST", "TROPICAL_SEASONAL_FOREST":
			return TreeParams.leafy_bush()
		"TAIGA", "SHRUBLAND", "TUNDRA":
			return TreeParams.juniper()
		"GRASSLAND", "SAVANNA", "SUBTROPICAL_DESERT", "TEMPERATE_DESERT":
			return TreeParams.dry_bush()
		_:
			return null


## Arbusto-ESCONDITE grande y denso del bioma (~2-2.6 m, tapa al jugador). null =
## el bioma no tiene matorral apto para esconderse.
static func thicket_for(biome: String) -> TreeParams:
	match biome:
		"TEMPERATE_DECIDUOUS_FOREST", "TEMPERATE_RAIN_FOREST", \
		"TROPICAL_RAIN_FOREST", "TROPICAL_SEASONAL_FOREST", "TAIGA":
			return TreeParams.hideout_bush()
		"SHRUBLAND", "SUBTROPICAL_DESERT", "TEMPERATE_DESERT", "GRASSLAND", "SAVANNA":
			return TreeParams.hideout_bush_dry()
		_:
			return null


## Plantas de sotobosque del bioma (varias): "fern"/"tree_fern"/"bamboo"/"cactus".
static func plants_for(biome: String) -> PackedStringArray:
	match biome:
		"TROPICAL_RAIN_FOREST":  # Selva Misionera: estrato intermedio rico
			return PackedStringArray(["fern", "tree_fern", "palmito", "bamboo", "caladium", "guembe"])
		"TROPICAL_SEASONAL_FOREST":
			return PackedStringArray(["fern", "bamboo", "caladium"])
		"TEMPERATE_RAIN_FOREST", "TEMPERATE_DECIDUOUS_FOREST":  # Andino-patagónico: helecho + amancay
			return PackedStringArray(["fern", "amancay"])
		"SUBTROPICAL_DESERT", "TEMPERATE_DESERT":
			return PackedStringArray(["cactus"])
		"GRASSLAND", "SAVANNA":  # Pampa: cortadera + tréboles de campo
			return PackedStringArray(["pampas", "clover"])
		"SHRUBLAND":  # Monte: cardón + cortadera dispersa
			return PackedStringArray(["cactus", "pampas"])
		_:
			return PackedStringArray()


## Pool de K plantas del tipo dado por seed, determinista. FloraConfig (inspector):
## modelo propio reemplaza TODO el pool; el tinte se pasa al color del follaje.
static func build_plant_pool(kind: String, base_seed: int, k: int) -> Array[Mesh]:
	var own := FloraConfig.plant_model(kind)
	if own != null:
		var same: Array[Mesh] = []
		same.resize(maxi(1, k))
		same.fill(own)
		return same
	var t := FloraConfig.plant_tint(kind)
	var tinted := t.a > 0.0
	var tc := Color(t.r, t.g, t.b)
	return _parallel_pool(k, func(i: int) -> Mesh:
		var s := base_seed + i * 1013
		match kind:
			"fern":
				return PlantGenerator.make_fern(s, tc) if tinted else PlantGenerator.make_fern(s)
			"tree_fern":
				return PlantGenerator.make_tree_fern(s, tc) if tinted else PlantGenerator.make_tree_fern(s)
			"palmito":
				return PlantGenerator.make_palmito(s, tc) if tinted else PlantGenerator.make_palmito(s)
			"guembe":
				return PlantGenerator.make_guembe(s, tc) if tinted else PlantGenerator.make_guembe(s)
			"bamboo":
				return PlantGenerator.make_bamboo(s, tc) if tinted else PlantGenerator.make_bamboo(s)
			"cactus":
				return PlantGenerator.make_cactus(s)
			"pampas":
				return FloraFactory.make_pampas_grass(s)
			"caladium":
				return PlantGenerator.make_caladium(s, tc) if tinted else PlantGenerator.make_caladium(s)
			"reed":
				return PlantGenerator.make_reed(s)
			"amancay":
				return FloraFactory.make_amancay(s)
			"clover":
				return FloraFactory.make_clover(s)
		return null)


## Parámetros de pasto del bioma: {color, height, density, blades}.
## density = multiplicador de matas por celda (0 = sin pasto).
static func grass_for(biome: String) -> Dictionary:
	match biome:
		"GRASSLAND", "SAVANNA":  # pampa: pastizal alto
			return {"color": Color(0.5, 0.53, 0.24), "height": 1.45, "density": 1.3, "blades": 9}
		"TROPICAL_RAIN_FOREST", "TROPICAL_SEASONAL_FOREST":  # selva: denso alto
			return {"color": Color(0.2, 0.5, 0.16), "height": 1.2, "density": 1.4, "blades": 9}
		"TEMPERATE_DECIDUOUS_FOREST", "TEMPERATE_RAIN_FOREST":
			return {"color": Color(0.28, 0.5, 0.2), "height": 0.9, "density": 1.05, "blades": 8}
		"TAIGA":
			return {"color": Color(0.3, 0.46, 0.34), "height": 0.7, "density": 0.65, "blades": 6}
		"SHRUBLAND", "TEMPERATE_DESERT":
			return {"color": Color(0.58, 0.54, 0.32), "height": 0.75, "density": 0.45, "blades": 6}
		"SUBTROPICAL_DESERT":
			return {"color": Color(0.62, 0.56, 0.34), "height": 0.6, "density": 0.28, "blades": 5}
		"TUNDRA", "SNOW":
			return {"color": Color(0.5, 0.52, 0.42), "height": 0.5, "density": 0.38, "blades": 6}
		_:
			return {"color": Color(0.32, 0.5, 0.22), "height": 0.9, "density": 1.05, "blades": 8}


## Mata de pasto del bioma (mesh). Determinista.
static func build_grass_blade(biome: String) -> Mesh:
	var g := grass_for(biome)
	return FloraFactory.make_grass_tuft(g["color"], g["height"], g["blades"],
			hash([biome, "grass"]))


## Pasto BILLBOARD CRUZADO (LOD lejano / calidad Baja): 2 quads en X, afinados a
## la punta, coloreados raíz→punta. ~8 tris vs ~108 de la mata 3D. Mece con
## GrassWind. Self-contained (no depende de FloraFactory). docs/LOD_PLANTILLA §5.
static func build_grass_billboard(biome: String) -> Mesh:
	var g := grass_for(biome)
	var base_color: Color = g["color"]
	var height: float = g["height"]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([biome, "grass_bb"])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat: Material
	var sh: Shader = load("res://shaders/GrassWind.gdshader")
	if sh != null:
		var sm := ShaderMaterial.new()
		sm.shader = sh
		mat = sm
	else:
		var m := StandardMaterial3D.new()
		m.albedo_color = base_color
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat = m
	st.set_material(mat)
	var h := height * rng.randf_range(0.9, 1.15)
	var half_w := 0.28
	var tip_c := base_color.lightened(0.16)
	var root_c := base_color.darkened(0.3)
	# 2 quads perpendiculares (X). Cada uno con cara frontal y trasera (~8 tris).
	for qi in 2:
		var ang := float(qi) * (PI / 2.0)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var bl := -dir * half_w
		var br := dir * half_w
		var tl := -dir * (half_w * 0.3) + Vector3.UP * h
		var vtr := dir * (half_w * 0.3) + Vector3.UP * h   # 'tr' pisa Object.tr()
		for tri: Array in [[bl, br, vtr], [bl, vtr, tl], [bl, vtr, br], [bl, tl, vtr]]:
			for v: Vector3 in tri:
				st.set_color(tip_c if v.y > h * 0.5 else root_c)
				st.set_uv(Vector2(0.5, 1.0 - clampf(v.y / h, 0.0, 1.0)))
				st.set_normal(Vector3.UP)   # pasto: iluminado desde el cielo
				st.add_vertex(v)
	return st.commit()


## Paleta de colores de flores del bioma. Vacía = sin flores.
static func flowers_for(biome: String) -> PackedColorArray:
	match biome:
		"GRASSLAND", "SAVANNA", "TEMPERATE_DECIDUOUS_FOREST":
			return PackedColorArray([Color(0.95, 0.5, 0.6), Color(0.98, 0.85, 0.3),
					Color(0.7, 0.55, 0.95), Color(0.98, 0.98, 0.95)])
		"TROPICAL_RAIN_FOREST", "TROPICAL_SEASONAL_FOREST":
			return PackedColorArray([Color(0.95, 0.35, 0.25), Color(0.98, 0.7, 0.15),
					Color(0.85, 0.3, 0.7)])
		"TEMPERATE_RAIN_FOREST":
			return PackedColorArray([Color(0.85, 0.85, 0.95), Color(0.7, 0.6, 0.9)])
		"TUNDRA", "SHRUBLAND":
			return PackedColorArray([Color(0.9, 0.8, 0.9), Color(0.98, 0.95, 0.8)])
		_:
			return PackedColorArray()
