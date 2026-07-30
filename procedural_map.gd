class_name ProceduralMapSystem
extends MapSystem

## ============================================================================
## ProceduralMapSystem · Orquesta la generación del mapa procedural (§10.1)
## ============================================================================
## Extiende MapSystem → cumple IMap sin tocar el loop jugable. Las etapas
## viven en un MapPipeline explícito (TERRAIN_PIPELINE_V2_PLAN §F1):
## graph → plan_routes → height_bake → topology → pois_plan → splat →
## terrain_mesh → colliders → water → topology_full → entities → rails →
## vegetation → pois_place → navmesh → spawn_points.
## Generación ASÍNCRONA: generate_map() es corrutina; el runner cede un frame
## entre etapas (phase_completed alimenta la pantalla de carga); dentro de
## cada etapa los pasos pesados paralelizan por filas en WorkerThreadPool.
## ============================================================================

@export var config: MapGenerationConfig
@export var terrain_settings: TerrainSettings
## Pila de capas editable. Vacía ⇒ se auto-crea [VoronoiBaseLayer, NoiseHeightLayer].
@export var height_layers: Array[HeightLayer] = []
## null ⇒ SplatRules.make_default().
@export var splat_rules: SplatRules
@export var sea_level: float = 0.0
@export var generate_colliders: bool = true
## §16KM-4 (opt-in): colisión por ANILLO alrededor del jugador en vez del
## collider full-map — obligatorio para mapas grandes (16 km). El anillo sigue
## al player (grupo) o a la cámara; teleport cubierto por el mismo update.
@export var collider_ring_enabled: bool = false
@export var collider_ring_radius_m: float = 96.0

@export_group("Spawns")
@export var generate_spawn_points: bool = true
@export var spawn_count: int = 8
@export_range(0.0, 1.0) var max_spawn_slope: float = 0.3
## Altura mínima sobre el nivel del mar para spawnear.
@export var min_spawn_height_m: float = 1.0

@export_group("Monumentos y Caminos (F7)")
## Definiciones de POI. Vacío = sin monumentos.
@export var poi_definitions: Array[POIDefinition] = []
## Parámetros de la red de caminos entre monumentos (null = defaults).
@export var road_network: RoadNetworkBuilder

@export_group("Spawning de Entidades")
## Tablas de spawn (F6). Vacío = mundo sin entidades procedurales.
@export var spawn_tables: Array[BiomeSpawnTable] = []
@export var global_max_entities: int = 300

@export_group("Vegetación (F8)")
## Vacío ⇒ VegetationSystem.make_default_profiles() (bosques + rocas).
@export var vegetation_profiles: Array[VegetationProfile] = []
@export var generate_vegetation: bool = true
## Config data-driven de flora (hoja/corteza por categoría, inspector). null = usa
## el look procedural por defecto. Ver systems/.../vegetation/config/flora_config.gd.
@export var flora_config: FloraConfig

@export_group("Vía de tren")
## Config swappeable de la vía (gauge, rieles, durmientes). null = default.
@export var rail_profile: RailProfile
## Tren de TEST sobre la vía. null = locomotora procedural (TrainFactory).
@export var test_train_mesh: Mesh
## Coloca UN tren de prueba parado sobre la vía (para verla a escala).
@export var spawn_test_train: bool = true
## Tren NUEVO (component-based): plataforma caminable + cabina con asiento (bajás y quedás
## arriba) que corre sobre la vía generada. Reemplaza al RailTrain viejo. Modelos swappeables.
@export var component_train_scene: PackedScene = preload("res://systems/vehicles/train.tscn")
## Vagón del convoy: el NUEVO con textura de madera arriba + ESCALERA DE MANO + coupler
## (wagon_container). Reemplaza al flatcar pelado (sin escalera). AnimatableBody3D igual → carro
## pasivo válido (su Drive/asiento quedan dormidos sin conductor). Loco sigue siendo train.tscn
## (su estructura TrainBody/RailPath la exige el ensamblado del convoy).
@export var component_wagon_scene: PackedScene = preload("res://systems/vehicles/wagon_flatcar.tscn")

@export_group("Apariencia")
## null ⇒ TerrainTextureSet.make_default() (texturas de assets/terrain/).
@export var texture_set: TerrainTextureSet
@export var debug_mode: bool = false

@export_group("Debug")
## Overlays de inspección (pedido del usuario, como en pcg-terrain_1):
## 1 = aristas del grafo Voronoi sobre el terreno; 2 = wireframe del render.
@export_enum("Ninguno", "Polígonos Voronoi", "Wireframe") var debug_overlay: int = 0

signal generation_completed(elapsed_ms: float)
signal phase_completed(phase_name: StringName, elapsed_ms: float)
## Fase que EMPIEZA (nombre REAL de la etapa del pipeline) — para mostrar en la
## carga la fase realmente en curso, no la anterior.
signal phase_started(phase_name: StringName)

var data_provider: MapDataProvider
var sampler: HeightSampler
var topology: TopologyMap
var splat: SplatMapBuilder
var biome_map: BiomeMapBuilder
var sea_mask: SeaMask
var terrain_material: ShaderMaterial
## Terreno lejano por clipmap (16 km, opt-in graphics/terrain_clipmap). null =
## apagado (chunks reales = comportamiento default intacto).
var _clipmap: TerrainClipmap = null
## Terreno por QUADTREE cámara-dependiente (Camino B, opt-in graphics/terrain_quadtree).
## Alternativa al clipmap: celdas que se subdividen cerca / fusionan lejos. null =
## apagado. Reemplaza el render de los chunks Y del clipmap cuando está encendido.
var _quadtree: QuadtreeMeshLOD = null
## Océano por el MISMO QuadtreeMeshLOD (F3, opt-in ocean_quadtree). null = usa el
## OceanPlane clásico. Reemplaza el render del océano por anillos LOD cámara-céntricos.
var _ocean: OceanSystem = null
## Autoridad ÚNICA de visibilidad (cono del player → qué existe). Ver WorldVisibility.
var _vis: WorldVisibility = null
## Red de rutas como GRAFO navegable (nodos/aristas/intersecciones). La llenan las
## rutas del corredor; la consumen el tráfico, los NPC y el pathfinding. null si el
## mapa no usa el modo CORRIDOR.
var road_graph: RoadGraph = null
## Cuánto se EXTIENDE el océano más allá del mapa (pseudo-infinito estilo Rust): las
## celdas lejanas son coarse + la niebla/horizonte ocultan el borde. 3× = borde lejos.
@export var ocean_extend_factor: float = 3.0
## Celda mínima de olas del océano cerca de la cámara (m). No depende del área
## extendida → olas nítidas sin importar cuán grande sea el océano pseudo-infinito.
@export var ocean_min_cell_m: float = 12.0

@export_group("Terreno LOD (quadtree)")
## Lado de la celda MÁS FINA, pegada a la cámara (LOD0), en metros. Manda sobre la
## cadena de LODs: cada anillo dobla el lado. 32 m ⇒ bandas 0-64 / 64-128 / 128-256…
@export var terrain_min_cell_m: float = 32.0
## A qué DISTANCIA cambia de LOD: un nodo de lado S se subdivide si dist < split·S.
## Borde entre celdas de S y 2S ≈ 2·split·S metros. Más alto = celdas más chicas más
## lejos (más detalle, MÁS draws). 1.0 = razonable; 2.0 explota los draws.
@export var terrain_split_factor: float = 1.0
## Cuánto MÁS lejos subdivide un nodo RUGOSO (crestas) vs uno plano. Solo con la
## opción "Detalle por rugosidad" encendida.
@export var terrain_rough_gain: float = 1.5
## Colchón del frustum-cull (m): construye un poco MÁS allá del cono para que no
## aparezca hueco al girar rápido la cámara.
@export var terrain_frustum_margin_m: float = 40.0
## Fracción del rango de LOD donde EMPIEZA el morph (0.6 = último 40%).
@export var terrain_morph_start_frac: float = 0.6
var _poi_system: POISystem
## Capas de camino/vía con vanos de puente (las consume BridgeBuilder).
var _bridge_layers: Array[HeightLayer] = []
## Capa de la vía (targets bakeados): RailBuilder pone los rieles sobre el
## TARGET, no sobre el terreno — sobre la zanja protegida el terreno es el
## lecho del río y los rieles se zambullían en él (capturas del usuario).
var _rail_layer: PathCarveLayer = null
## Polilíneas de los apartaderos de la vía (#115): los trenes-spawn viven ahí.
var _rail_sidings: Array = []
## Capas de carve de los apartaderos (para construir sus rieles a la altura del
## lecho que ellas esculpen, igual que la vía principal).
var _siding_layers: Array[PathCarveLayer] = []

## Frame-yield compartido por las etapas (cede un frame al main loop).
var _fy: Callable = Callable()
## Estado que fluye entre etapas del pipeline (lo produce plan_routes).
var _planned_layers: Array[HeightLayer] = []
var _river_layers: Array[HeightLayer] = []
var _road_layers: Array[HeightLayer] = []
var _rail_carve_layers: Array[HeightLayer] = []


## Estampa la vía en la topología (RAIL + RAILSIDE) — el splat pinta el balasto.
func _stamp_rails() -> void:
	if data_provider.rail_points.size() < 2:
		return
	topology.stamp_polyline(data_provider.rail_points,
			config.rail_width_m * 0.5, TopologyMap.TOPO_RAIL)
	topology.stamp_polyline(data_provider.rail_points,
			config.rail_width_m * 0.5 + terrain_settings.topology_side_width_m,
			TopologyMap.TOPO_RAILSIDE)

var _generating: bool = false


func _ready() -> void:
	# MapSystem difiere el navmesh a "un frame después" — demasiado pronto para
	# una generación asíncrona. Se bloquea acá y se hornea al FINAL de _generate.
	var want_nav := bake_navmesh
	bake_navmesh = false
	super._ready()  # registra el grupo "map"
	bake_navmesh = want_nav
	# Gráficos EN VIVO (menú §6.4): efectos/sombras del mapa reaccionan al
	# instante al cambiar opciones (la vegetación tiene su propio listener).
	if typeof(GameEvents) != TYPE_NIL and GameEvents != null:
		GameEvents.settings_changed.connect(func(section: StringName) -> void:
			if section == &"graphics":
				_apply_graphics_live()
				_apply_clipmap()
				_apply_quadtree()
				_apply_ocean_quadtree()
			elif section == &"postfx":
				# Efectos de imagen: solo el Environment, nada de geometría.
				_apply_graphics_live())
	# Sin config NO se genera (explícito): permite instanciar la escena barata
	# (smoke instancia todo res://systems) y que el juego llame generate_map()
	# con su .tres cuando corresponda.
	# Pisado del pasto (Opciones -> Gráficos -> Mundo). Es un sistema del CLIENTE
	# —solo cambia cómo se dibuja el pasto— pero vive acá porque necesita estar
	# donde está el pasto. Se apaga solo si la opción no lo pide y entonces no
	# consume nada.
	var trample := GrassTrample.new()
	trample.name = "GrassTrample"
	add_child(trample)

	if config != null:
		generate_map()


## Genera (o regenera) el mapa con el config actual. Corrutina: cede un frame
## entre fases para que la pantalla de carga respire (dentro de cada fase los
## pasos pesados paralelizan por filas en WorkerThreadPool).
func generate_map() -> void:
	if config == null:
		push_warning("ProceduralMapSystem: config es null — nada que generar.")
		return
	if _generating:
		return
	_generating = true
	await _generate()
	_generating = false


## Multiplicador de densidad de vegetación según calidad (backlog #29).
var _veg_scale := 1.0

## Fuente de progreso de la fase actual (builder con rows_done/rows_total).
var progress_source: Object = null


## Progreso 0..1 de la fase en curso, o -1 si la fase no lo reporta.
func get_phase_progress() -> float:
	if progress_source == null:
		return -1.0
	var total := int(progress_source.get("rows_total"))
	if total <= 0:
		return -1.0
	return clampf(float(int(progress_source.get("rows_done"))) / float(total), 0.0, 1.0)


## Calidad del mundo desde Opciones (0 baja / 1 media / 2 alta): degrada
## vegetación, LOD y resolución de mapas SIN tocar el .tres del usuario.
func _apply_quality() -> void:
	# Calidad 0 potato · 1 bajo · 2 medio · 3 alto · 4 ultra. Default alto (3).
	var q := 3
	if typeof(Settings) != TYPE_NIL and Settings != null:
		q = int(Settings.get_value(&"graphics", &"world_quality", 3))
	q = clampi(q, 0, 4)
	# AUDITORÍA_LOD A2: la densidad se multiplicaba DOS veces (esta escala ×
	# VegetationQuality.density_scale → Ultra 1.375× = lag). ÚNICA fuente ahora:
	# VegetationQuality.density_scale; esto queda en 1.0. Ultra = MÁS DISTANCIA
	# de detalle (lod_bias/plantilla), nunca más instancias que Alto.
	_veg_scale = 1.0
	_apply_graphics_live()
	# CADENA de calidad completa: el selector del menú fija el preset de vegetación
	# (lod_bias + plantilla LOD por preset). Los sistemas leen estos knobs globales.
	VegetationQuality.apply_preset(["potato", "bajo", "medio", "alto", "ultra"][q])
	if q >= 3:
		return
	# potato/bajo/medio: degradar LOD/resolución del TERRENO.
	terrain_settings = terrain_settings.duplicate()
	var lod_mult: float = [0.4, 0.55, 0.8][q]
	for i in terrain_settings.lod_ranges_m.size():
		terrain_settings.lod_ranges_m[i] *= lod_mult
	if q <= 1:   # potato + bajo: media resolución de splat/topología
		terrain_settings.splat_resolution = maxi(floori(terrain_settings.splat_resolution / 2.0), 256)
		terrain_settings.topology_resolution = maxi(floori(terrain_settings.topology_resolution / 2.0), 256)


## Efectos/sombras del MAPA según preset + overrides del menú (EN VIVO).
## Convención (GRAPHICS_MENU_V2): 0/"auto" = decide el preset; valor explícito
## = manual. SSAO solo Ultra por default (caro con selva densa — causa medida
## del reporte "20 FPS"). Lo llama _apply_quality y el listener de settings.
func _apply_graphics_live() -> void:
	var gq := 3
	if typeof(Settings) != TYPE_NIL and Settings != null:
		gq = clampi(int(Settings.get_value(&"graphics", &"world_quality", 3)), 0, 4)
	var shadow_over := float(Settings.get_value(&"graphics", &"shadow_dist", 150.0))
	var wenv := get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	if wenv != null and wenv.environment != null:
		# Los efectos de imagen son del CLIENTE y viven en su propia clase
		# (`ImageEffects`, sección `postfx`). Acá solo se los invoca porque el
		# WorldEnvironment todavía cuelga del mapa; cuando el cliente tenga su
		# propio nodo de render, esta llamada se muda entera y el mapa deja de
		# saber que existen.
		# La profundidad de campo vive en CameraAttributesPractical, no en el
		# Environment (cambió de Godot 3 a 4). Se crea si no existe.
		var cattr := wenv.camera_attributes as CameraAttributesPractical
		if cattr == null:
			cattr = CameraAttributesPractical.new()
			wenv.camera_attributes = cattr
		ImageEffects.apply(wenv.environment, gq, cattr)
	var sun_l := get_node_or_null(^"Sun") as DirectionalLight3D
	if sun_l != null:
		# El slider MANDA (el preset lo escribe). Sin checkbox "automática".
		sun_l.directional_shadow_max_distance = maxf(shadow_over, 20.0)
		# Cascadas del sol EN VIVO (GRAPHICS_MENU_V2 #7): índice 0 = Auto (por
		# preset: 1/2/2/4 splits), 1/2/3 = 1/2/4 fijas. Enum Godot: 0=ORTHOGONAL,
		# 1=PARALLEL_2_SPLITS, 2=PARALLEL_4_SPLITS. Más cascadas = nitidez lejana
		# a más costo (el rubro más caro en bosque denso).
		var casc := int(Settings.get_value(&"graphics", &"shadow_cascades", 0))
		var mode: int = [0, 0, 1, 1, 2][gq] if casc <= 0 else [0, 1, 2][clampi(casc - 1, 0, 2)]
		sun_l.directional_shadow_mode = mode as DirectionalLight3D.ShadowMode


## Reconstruye SOLO el océano, sin tocar el terreno ni la vegetación ni sacar al
## jugador del mundo.
##
## Existe por las opciones que Godot no deja cambiar en caliente: el tamaño del
## mapa FFT se lee en el `_ready` del `OceanSystem` para crear las texturas de
## GPU. En vez de pedir "reiniciar el juego" —que en un survival significa
## perder la sesión— se tira ese nodo y se arma de nuevo. Son unos cuadros de
## congelamiento, no una salida del servidor.
func reload_ocean() -> void:
	if _ocean != null and is_instance_valid(_ocean):
		_ocean.queue_free()
	_ocean = null
	_apply_ocean_quadtree()


## Terreno lejano por CLIPMAP (16 km, opt-in). Enciende/apaga según
## graphics/terrain_clipmap + graphics/horizon_bake. Requiere que el terreno ya
## esté generado (material + nodo "Terrain"); lo llama _generate al final y el
## listener de settings. Default OFF = chunks reales intactos.
func _apply_clipmap() -> void:
	if typeof(Settings) == TYPE_NIL or Settings == null:
		return
	var on := bool(Settings.get_value(&"graphics", &"terrain_clipmap", false))
	var terrain := find_child("Terrain", true, false) as Node3D
	if on and terrain_material != null:
		if _clipmap == null:
			_clipmap = TerrainClipmap.new()
			_clipmap.name = "TerrainClipmap"
			_clipmap.terrain_root = terrain
			add_child(_clipmap)
			_clipmap.setup(terrain_material)
		_clipmap.visible = true   # el quadtree pudo haberlo ocultado; restaurar
		if terrain != null:
			terrain.visible = false   # el clipmap reemplaza el render de los chunks
		# Radio del clipmap por CALIDAD (docs/LOD_PLANTILLA): Bajo=3 niveles
		# (~512 m, resto niebla/horizonte) … Ultra=todos (16 km). Coincide con la
		# idea "árboles impostores arriba del clipmap": el cull de árboles (Familia
		# A) queda cerca del borde del clipmap por preset.
		# Niveles discretos (semi-extensión 128·2^lv): 3→~512 m · 4→~1024 · 5→~2048
		# · 6→~4096. Bajo corto (resto niebla/horizonte), Ultra ~2-4 km (NO 16 km:
		# nadie mira más lejos sin mira). El radio exacto pedido (400/700/1100/2000)
		# cae al nivel 2^n más cercano; el horizonte horneado cubre lo de atrás.
		var gq2 := clampi(int(Settings.get_value(&"graphics", &"world_quality", 3)), 0, 4)
		_clipmap.set_active_levels([2, 3, 4, 5, 6][gq2])
		_clipmap.set_horizon(bool(Settings.get_value(&"graphics", &"horizon_bake", false)))
	else:
		if _clipmap != null:
			_clipmap.queue_free()
			_clipmap = null
		if terrain != null:
			terrain.visible = true


## Terreno por QUADTREE cámara-dependiente (Camino B, opt-in graphics/terrain_quadtree).
## Corre DESPUÉS de _apply_clipmap: cuando está encendido REEMPLAZA a los chunks y
## al clipmap (oculta ambos). Default OFF = comportamiento intacto. Ver
## docs/PLAN_TERRENO_QUADTREE.md. La altura la pone el mismo vertex shader
## (clipmap_displace) reusando el material real.
func _apply_quadtree() -> void:
	if typeof(Settings) == TYPE_NIL or Settings == null:
		return
	var on := bool(Settings.get_value(&"graphics", &"terrain_quadtree", false))
	var terrain := find_child("Terrain", true, false) as Node3D
	if on and terrain_material != null and sampler != null:
		# CALIDAD (potato/bajo/medio/alto/ultra) — como los motores de mundo abierto:
		# la ESTRUCTURA del quadtree NO cambia (misma celda mínima, mismo algoritmo).
		# Solo se tocan DOS parámetros independientes:
		#   1) DISTANCIAS de LOD (split_factor) → el detalle fino muere más cerca.
		#   2) RESOLUCIÓN del patch (grid_n)    → menos vértices por celda, mismas
		#      distancias y mismas transiciones (el cambio se nota mucho menos).
		# Ultra = los valores del Inspector. Ver docs/PROXIMA_SESION_AAA.md §calidad.
		var gq := clampi(int(Settings.get_value(&"graphics", &"world_quality", 3)), 0, 4)
		# CRITERIO (usuario): al bajar la calidad hay que SUBDIVIDIR MENOS, no acercar
		# el detalle. Las distancias se mantienen casi iguales (el jugador conserva su
		# alcance visual); lo que se recorta fuerte es la RESOLUCIÓN del patch, que es
		# lo que realmente cuesta triángulos.
		# ANTES: [0.35, 0.5, 0.7, 0.85, 1.0] -> en potato el detalle moría a 22 m del
		# jugador = "pop" pegado a la cámara. Medido y descartado.
		var split_mult: float = [0.8, 0.85, 0.9, 0.95, 1.0][gq]
		# Potencias de 2 + 1. Ultra 33 = el doble de densidad que antes; potato 5 =
		# 32 tri/celda contra 2048 de ultra (64x menos) SIN mover las distancias.
		var patch_res: int = [5, 9, 17, 25, 33][gq]
		if _quadtree == null:
			_quadtree = QuadtreeMeshLOD.new()
			_quadtree.name = "TerrainQuadtree"
			var b := sampler.bounds
			_quadtree.area_size_m = maxf(b.size.x, b.size.y)
			_quadtree.area_center = b.get_center()
			# Celda mínima = ESTRUCTURA del quadtree: NO depende de la calidad.
			_quadtree.min_cell_m = terrain_min_cell_m
			add_child(_quadtree)
			_quadtree.setup(terrain_material)
		# Los DOS knobs de calidad, ambos EN VIVO (sin regenerar el mapa).
		# El menú puede pisar CADA UNO por separado — es la diferencia con Rust,
		# que ata "calidad de terreno" a un solo número. Acá se puede tener el
		# alcance de ultra con la malla de bajo, o al revés. 0 = seguir el preset.
		var split_ovr := float(Settings.get_value(&"graphics", &"terrain_split_factor", 0.0))
		# El menú guarda el ÍNDICE del desplegable (0 = "según la calidad").
		var res_idx := clampi(int(Settings.get_value(&"graphics", &"terrain_patch_res_idx", 0)), 0, 5)
		_quadtree.split_factor = split_ovr if split_ovr > 0.0 else terrain_split_factor * split_mult
		_quadtree.grid_n = [0, 5, 9, 17, 25, 33][res_idx] if res_idx > 0 else patch_res
		_quadtree.frustum_margin_m = terrain_frustum_margin_m
		_quadtree.morph_start_frac = terrain_morph_start_frac
		# F5 · Morphing de vértices (opt-in terrain_morph): mata el popping de LOD.
		_quadtree.morph = _gfx_bool(&"terrain_morph", false)
		# F-cull · Poda por frustum (opt-in): NO construir celdas fuera del cono.
		_quadtree.frustum_cull = _gfx_bool(&"terrain_frustum_cull", false)
		# F6 · Split por rugosidad (opt-in terrain_rough_lod): menos celdas en llano,
		# más en crestas. Necesita el sampler para el δ de altura por nodo.
		_quadtree.height_query = Callable(sampler, &"get_height")
		_quadtree.rough_gain = terrain_rough_gain if _gfx_bool(&"terrain_rough_lod", false) else 0.0
		# F1b · Altura por REGIONES (opt-in terrain_region_stream). UNIVERSAL: se
		# activa SOLO si los tiles agregan resolución sobre el heightfield global
		# (mapas grandes); en mapas chicos el global ya es más fino → queda todo
		# global sin coste. Las hojas finas usan tiles de alta res STREAMED (mismas
		# capas → alturas idénticas). El collider cercano usa la MISMA fuente (F1b.6).
		var want_tiles := _gfx_bool(&"terrain_region_stream", false)
		if want_tiles:
			var rs := RegionStreamSampler.new()
			rs.setup(sampler.layers, sampler.bounds, sampler.height_scale,
					sampler.global_seed, sampler.graph, sampler.query)
			if _region_tiles_help(rs):
				if _quadtree.region_tex == null:
					var rht := RegionHeightTextures.new()
					rht.setup(rs, terrain_material)
					rht.async_bake = true   # F1b.7: bake amortizado (sin hitch al moverse)
					_quadtree.region_tex = rht
				_set_ring_source(_quadtree.region_tex.sampler)
			else:
				want_tiles = false
		if not want_tiles:
			_quadtree.region_tex = null
			_set_ring_source(null)
		if terrain != null:
			terrain.visible = false
		if _clipmap != null:
			_clipmap.visible = false   # el quadtree reemplaza también al clipmap
		_set_spatial_gate(_visibility())
	else:
		if _quadtree != null:
			_set_spatial_gate(null)
			_quadtree.queue_free()
			_quadtree = null
			_apply_clipmap()   # restaura chunks/clipmap según opciones


## LA autoridad de visibilidad del mundo (se crea una sola vez). Todo lo que
## pregunta "¿esto se ve?" pasa por acá: mesh, pasto, árboles, rocas, props.
func _visibility() -> WorldVisibility:
	if _vis == null:
		_vis = WorldVisibility.new()
		_vis.name = "WorldVisibility"
		_vis.cone_only = _gfx_bool(&"terrain_frustum_cull", false)
		add_child(_vis)
	else:
		_vis.cone_only = _gfx_bool(&"terrain_frustum_cull", false)
	return _vis


## Cablea la AUTORIDAD de visibilidad a los sistemas que viven sobre el terreno:
## se descartan con el MISMO test de cono que el suelo, y con un solo dueño (si
## cada sistema decide por su cuenta, se pelean y las cosas parpadean).
func _set_spatial_gate(gate) -> void:
	for nm in ["GrassPatches", "Vegetation"]:
		var n := find_child(nm, true, false)
		if n != null:
			n.spatial_gate = gate


## ¿Los tiles de región agregan resolución sobre el heightfield GLOBAL? El global
## es fijo (bake_resolution² sobre todo el mapa); los tiles son region_m/region_res.
## Solo conviene streamear tiles si su texel es MÁS FINO que el del global (mapas
## grandes). En mapas chicos el global ya es más fino → false (no gastar en tiles).
func _region_tiles_help(rs) -> bool:
	if sampler == null:
		return false
	var b := sampler.bounds
	var global_texel := maxf(b.size.x, b.size.y) / float(maxi(terrain_settings.bake_resolution - 1, 1))
	var region_texel: float = rs.region_m / float(maxi(rs.region_res - 1, 1))
	return global_texel > region_texel * 1.05   # margen: solo si CLARAMENTE ayuda


## Setea la fuente de altura del anillo de colisión (si existe) — para que la
## colisión cercana coincida con los tiles de región del render (F1b.6).
func _set_ring_source(src) -> void:
	var ring := find_child("TerrainColliderRing", true, false)
	if ring != null:
		ring.height_source = src


## OCÉANO. El viejo (5 Gerstner a mano, `_descartado/OceanQuadtree.gdshader`) quedó
## DESCARTADO: se veía periódico y con dirección dominante. Ahora manda `OceanSystem`
## (oleaje FFT por espectro TMA + suelo oceánico + pseudo-infinito). Se mantiene el
## flag `ocean_quadtree` como interruptor: ON = océano nuevo, OFF = OceanPlane clásico.
func _apply_ocean_quadtree() -> void:
	if sampler == null:
		return
	var on := _gfx_bool(&"ocean_quadtree", false)
	# TODOS los que se llamen así, no solo el primero: hay dos rutas que crean un
	# nodo "OceanPlane" (water_builder y sea_mask.build_ocean_mesh) y con
	# find_child() se ocultaba uno solo -> quedaba una SUPERFICIE DE AGUA DE MÁS,
	# plana y con borde escalonado, que NO respeta el cono (reportado por el usuario).
	var ocean_planes := find_children("OceanPlane", "", true, false)
	if on:
		if _ocean == null:
			_ocean = OceanSystem.new()
			_ocean.name = "Ocean"
			var b := sampler.bounds
			_ocean.area_size_m = maxf(b.size.x, b.size.y) * maxf(ocean_extend_factor, 1.0)
			_ocean.area_center = b.get_center()
			_ocean.sea_level_m = sea_level
			_ocean.surface_min_cell_m = ocean_min_cell_m
			# El TERRENO ya es el fondo del mar acá: el suelo propio del océano solo
			# hace falta en mar abierto (fuera del heightfield).
			_ocean.floor_enabled = false
			# Knobs de agua del menú. Van ACÁ, antes de add_child: `OceanSystem`
			# los lee en su `_ready` para crear las texturas de GPU y el simulador
			# de estelas. Asignarlos después no reasigna nada — el knob quedaría
			# muerto sin dar error. Por eso el menú avisa "al regenerar".
			_ocean.ripples_enabled = _gfx_bool(&"ocean_ripples", true)
			var fft_idx := clampi(int(Settings.get_value(&"graphics", &"ocean_fft_size", 0)), 0, 3)
			if fft_idx > 0:
				_ocean.map_size = [0, 128, 256, 512][fft_idx]
			add_child(_ocean)
		_ocean.morph = _gfx_bool(&"terrain_morph", false)
		_ocean.frustum_cull = _gfx_bool(&"terrain_frustum_cull", false)
		# Mar SOLO donde hay mar de verdad (SeaMask): sin esto aparece océano bajo la
		# isla y bajo los lagos (dos superficies de agua superpuestas).
		# Sin ternario: `Callable` y `null` no son tipos compatibles y Godot avisa.
		# Un Callable VACÍO es el "sin filtro" idiomático (is_null() da true).
		var sea_q := Callable()
		if sea_mask != null:
			sea_q = Callable(sea_mask, &"is_sea")
		_ocean.set_surface_query(sea_q)
		# PROFUNDIDAD: se le pasa al océano la MISMA textura de alturas que ya usa
		# el terreno. Con eso atenúa la ola cerca de la costa y recorta su borde
		# exactamente donde el terreno sale del agua (sin escalones).
		if terrain_material is ShaderMaterial:
			var tm := terrain_material as ShaderMaterial
			_ocean.set_depth_field(tm.get_shader_parameter(&"heightfield"),
					tm.get_shader_parameter(&"map_origin"),
					tm.get_shader_parameter(&"map_size_m"),
					config.height_scale)
		for op in ocean_planes:
			(op as Node3D).visible = false
	else:
		if _ocean != null:
			_ocean.queue_free()
			_ocean = null
		for op in ocean_planes:
			(op as Node3D).visible = true


func _generate() -> void:
	var t_total := Time.get_ticks_msec()
	if terrain_settings == null:
		terrain_settings = TerrainSettings.new()
	_apply_quality()
	# Los pasos pesados ceden frames mientras los workers muelen → la ventana
	# nunca queda "no responde" (alt-tab/clic durante la carga no la mata).
	_fy = func() -> void: await get_tree().process_frame

	# Etapas explícitas (TERRAIN_PIPELINE_V2_PLAN §F1). La condición de cada
	# etapa se evalúa AL LLEGAR (p. ej. rails depende de lo que dejó
	# plan_routes); timing + frame cedido entre etapas los pone el runner.
	var pipe := MapPipeline.new()
	pipe.add(&"graph", _stage_graph)
	pipe.add(&"plan_routes", _stage_plan_routes)
	pipe.add(&"height_bake", _stage_height_bake)
	pipe.add(&"topology", _stage_topology_hydro)
	pipe.add(&"pois_plan", _stage_pois_plan,
			func() -> bool: return not poi_definitions.is_empty())
	pipe.add(&"splat", _stage_splat)
	pipe.add(&"terrain_mesh", _stage_terrain_mesh)
	pipe.add(&"colliders", _stage_colliders,
			func() -> bool: return generate_colliders)
	pipe.add(&"water", _stage_water)
	pipe.add(&"topology_full", _stage_topology_full)
	pipe.add(&"entities", _stage_entities,
			func() -> bool: return not spawn_tables.is_empty())
	pipe.add(&"rails", _stage_rails,
			func() -> bool: return config.rail_enabled and data_provider.rail_points.size() >= 2)
	pipe.add(&"vegetation", _stage_vegetation,
			func() -> bool: return generate_vegetation)
	pipe.add(&"pois_place", _stage_pois_place,
			func() -> bool: return _poi_system != null)
	pipe.add(&"navmesh", _stage_navmesh,
			func() -> bool: return bake_navmesh)
	pipe.add(&"spawn_points", _stage_spawn_points,
			func() -> bool: return generate_spawn_points)
	# PERFIL REAL de generación (§PERF-CARGA): además de alimentar la pantalla
	# de carga, cada fase queda medida y al final se imprime la tabla ordenada
	# (para encontrar QUÉ optimizar). La pantalla muestra estos mismos datos.
	var profile: Array = []
	await pipe.run(
			func(n: StringName, ms: float) -> void:
				profile.append([n, ms])
				phase_completed.emit(n, ms),
			_fy,
			func(n: StringName) -> void: phase_started.emit(n))

	progress_source = null
	_apply_debug_overlay()
	var total_ms := float(Time.get_ticks_msec() - t_total)
	profile.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
	if debug_mode:  # perfilado solo en modo debug (evita spam en release)
		print("PERFIL GENERACIÓN (total %.1f s):" % (total_ms / 1000.0))
		for e: Array in profile:
			print("  %-14s %7.0f ms  (%4.1f%%)" % [e[0], e[1], 100.0 * float(e[1]) / maxf(total_ms, 1.0)])
	# Terreno lejano por clipmap si la opción está encendida (ya existen material
	# y chunks). Default apagado = mapa intacto.
	_apply_clipmap()
	_apply_quadtree()
	_apply_ocean_quadtree()
	_generated = true   # habilita el rebuild en vivo de vegetación (A4)
	generation_completed.emit(total_ms)


## Plano semántico: Seed + ruido + grafo Voronoi + biomas (pcg-terrain_1).
func _stage_graph() -> void:
	data_provider = MapDataProvider.new()
	data_provider.name = "MapDataProvider"
	add_child(data_provider)
	await data_provider.generate_async(config, _fy)


## Fase A (planificación): trazar RUTAS de ríos/carreteras/vías y ubicar
## lagos sobre el grafo plano, ANTES de tocar la altura.
func _stage_plan_routes() -> void:
	_pre_field = null  # el pre-bake base se rehace por generación
	var layers: Array[HeightLayer] = height_layers.duplicate()
	if layers.is_empty():
		# Fase B1: relieve costa→meseta (config.plateau_height_m > 0) o silueta
		# cruda del grafo (viejo comportamiento) si el usuario pone 0.
		if config.plateau_height_m > 0.0:
			var base := CoastalPlateauLayer.new()
			base.plateau_height_m = config.plateau_height_m
			base.ramp_elev = config.plateau_ramp
			layers.append(base)
		else:
			layers.append(VoronoiBaseLayer.new())
		layers.append(NoiseHeightLayer.new())
		# RELIEVE COSTA→INTERIOR con pseudo-erosión (opt-in por config): la isla
		# deja de verse igual en todos lados. Va DESPUÉS del ruido base (compone
		# sobre él) y ANTES de los rasgos por sector, que deben poder pisarla.
		if config.coastal_relief_m > 0.0:
			var cr := CoastalReliefLayer.new()
			cr.relief_m = config.coastal_relief_m
			cr.coast_amount = config.coastal_relief_coast
			cr.cliff_sharpness = config.coastal_relief_cliffs
			cr.ridged_amount = config.coastal_relief_ridged
			cr.warp_strength_m = config.coastal_relief_warp_m
			cr.noise_seed = config.seed_variant
			layers.append(cr)
		# Rasgos por sector (backlog #12): macizos, depresiones con piso sobre
		# el mar, mesetas — aleatorios por seed, como Rust.
		layers.append_array(FeatureLayerFactory.make(config, data_provider, sea_level))
		# Costa CAMINABLE (backlog #48): repisa antes del agua en todo el contorno.
		var shore := ShorelineLayer.new()
		shore.sea_level = sea_level
		layers.append(shore)
	var river_layers: Array[HeightLayer]
	if config.hydrology_mode == "RASTER":
		river_layers = await _raster_river_layers(layers)
	else:
		river_layers = data_provider.build_river_layers(
				config.river_width_m, config.river_depth_m, config.river_falloff_m,
				config.height_scale, config.river_grow_length_m)
	var road_layers: Array[HeightLayer] = []
	var rail_layers: Array[HeightLayer] = []
	if config.corridor_mode == "CORRIDOR":
		# §F3: corredor único por el contorno de la isla (carretera+vía juntas).
		var corridor: Dictionary = await _corridor_layers(layers, river_layers)
		road_layers = corridor.roads
		rail_layers = corridor.rails
	else:
		if config.road_mode != "NETWORK":  # CIRCUIT o BOTH usan el anillo de pcg
			road_layers = data_provider.build_road_layers(
					config.road_width_m, config.road_falloff_m, river_layers)
		if config.rail_enabled:
			rail_layers = data_provider.build_rail_layers(config.rail_shape_scale,
					config.rail_width_m, config.rail_falloff_m,
					hash([config.seed_variant, "rails"]), river_layers)
			if not rail_layers.is_empty():
				_rail_layer = rail_layers[0] as PathCarveLayer
				# APARTADEROS (#115): se calculan en Fase A y cada uno lleva su
				# PROPIA capa de carve (esculpe su lecho como la principal — antes
				# los rieles del ramal flotaban sobre el terreno crudo). Va DESPUÉS
				# de la vía principal en la pila → nivela al lecho que ella dejó.
				_rail_sidings = MapDataProvider.make_sidings(data_provider.rail_points,
						hash([config.seed_variant, "sidings"]), 2)
				_siding_layers.clear()
				for sp: PackedVector2Array in _rail_sidings:
					rail_layers.append(_make_siding_layer(sp))
	# Lagos al FINAL del plan: LEEN los trazados ya decididos y no aparecen
	# bajo ríos/carreteras/vías (regla del usuario — cada etapa hace UNA cosa
	# y la siguiente respeta lo que la anterior dejó).
	var avoid_paths: Array = []
	for pl_any in river_layers + road_layers + rail_layers:
		var pcl0 := pl_any as PathCarveLayer
		if pcl0 != null:
			avoid_paths.append(pcl0.points)
	var lake_layers := data_provider.build_lake_layers(
			config.height_scale, 2.0, avoid_paths, config.num_lakes,
			hash([config.seed_variant, "lakes"]))
	layers.append_array(lake_layers)
	layers.append_array(river_layers)
	for pl_any in road_layers + rail_layers:
		var pcl := pl_any as PathCarveLayer
		if pcl != null:
			for riv in river_layers:
				if riv is PathCarveLayer:
					pcl.protected_layers.append(riv)
	# TODO(#122): carretera POR DEBAJO de la vía respetando su altura. La
	# lógica de cruce actual LEVANTA sobre el protegido (diseñada para ríos);
	# para la vía haría falta el cruce inverso (road dip + rail en puente).
	# Necesita verificación visual — no se activa a ciegas.
	layers.append_array(road_layers)
	layers.append_array(rail_layers)
	_bridge_layers = road_layers.duplicate()
	_bridge_layers.append_array(rail_layers)
	# Estado compartido con las etapas siguientes (contrato del pipeline).
	_planned_layers = layers
	_river_layers = river_layers
	_road_layers = road_layers
	_rail_carve_layers = rail_layers


## Pre-bake del relieve BASE (sin cauces ni caminos) a 513 — lo comparten la
## hidrología raster (§F4) y el corredor por contorno (§F3). Lazy por generación.
var _pre_field: HeightSampler = null

const PRE_BAKE_RES := 513


func _base_field(base_layers: Array[HeightLayer]) -> HeightSampler:
	if _pre_field == null:
		_pre_field = HeightSampler.new()
		_pre_field.setup(data_provider.graph, base_layers,
				data_provider.get_map_bounds(), config.height_scale,
				config.seed_variant, data_provider.query)
		await _pre_field.bake(PRE_BAKE_RES, 0, _fy)
	return _pre_field


## §F4 (modo RASTER): trazado de ríos por hidrología raster (Priority-Flood +
## D8) sobre el campo base — la garantía de llegar al mar es del algoritmo,
## no de rescates heurísticos.
func _raster_river_layers(base_layers: Array[HeightLayer]) -> Array[HeightLayer]:
	var pre: HeightSampler = await _base_field(base_layers)
	var hyd := Hydrology.run(pre.get_heights_raw(), PRE_BAKE_RES, pre.bounds,
			sea_level, config.num_rivers)
	return data_provider.build_river_layers_from_polylines(hyd.rivers,
			config.river_width_m, config.river_depth_m, config.river_falloff_m,
			config.river_grow_length_m)


## §F3 (modo CORRIDOR): anillo por el contorno de la isla; carretera y vía
## JUNTAS como offsets del MISMO spine — un único esculpido para el corredor
## completo (calzada + separación + vía), en vez de dos pasadas de terreno.
func _corridor_layers(base_layers: Array[HeightLayer],
		river_layers: Array[HeightLayer]) -> Dictionary:
	var out := {"roads": [] as Array[HeightLayer], "rails": [] as Array[HeightLayer]}
	var pre: HeightSampler = await _base_field(base_layers)
	var ring := CorridorPlanner.coast_ring(pre.get_heights_raw(), PRE_BAKE_RES,
			pre.bounds, sea_level, config.corridor_coast_dist_m)
	if ring.size() < 12:
		push_warning("ProceduralMapSystem: corredor sin anillo — isla muy chica.")
		return out
	# Mismo pipeline de suavizado que la vía (zigzag → Chaikin ring → relax →
	# resample): un tren jamás gira a 90°.
	var spine := MapDataProvider._smooth_route(ring, true, river_layers,
			0.7, 3, 0.18, 5.0)
	if spine.size() < 8:
		return out
	var half := config.corridor_gap_m * 0.5
	var road_pts: PackedVector2Array
	if config.corridor_swaps > 0:
		# INTERCAMBIO de lados: el offset oscila y cruza el cero, así que a lo largo
		# de la vuelta la carretera y la vía se turnan el lado de la costa. Donde el
		# offset se acerca a cero quedan juntas: ese es el CRUCE.
		var off := CorridorPlanner.swap_offsets(spine.size(), half,
				config.corridor_swaps, config.corridor_swap_min)
		var neg := PackedFloat32Array()
		neg.resize(off.size())
		for i in off.size():
			neg[i] = -off[i]
		road_pts = CorridorPlanner.offset_polyline_varying(spine, neg, true)
		data_provider.rail_points = CorridorPlanner.offset_polyline_varying(spine, off, true)
	else:
		road_pts = CorridorPlanner.offset_polyline(spine, -half, true)
		data_provider.rail_points = CorridorPlanner.offset_polyline(spine, half, true)
	# UNA capa esculpe el corredor completo. Grading de VÍA (el más estricto).
	var corridor := PathCarveLayer.new()
	corridor.layer_name = &"rail_flatten"
	corridor.path_mode = PathCarveLayer.PathMode.FLATTEN_ALONG
	corridor.points = spine
	corridor.is_ring = true
	corridor.width_m = config.road_width_m + config.corridor_gap_m + config.rail_width_m
	corridor.falloff_m = maxf(config.road_falloff_m, config.rail_falloff_m)
	corridor.target_smooth_passes = 8
	corridor.max_grade = 0.03
	corridor.smooth_window_m = 70.0
	corridor.cut_bias = 0.35
	corridor.max_bank_slope = 0.5
	# GRAFO NAVEGABLE de la red (RoadGraph): se arma con lo que el corredor YA
	# calculo. Sin esto las rutas son solo geometria y ningun vehiculo/NPC puede
	# circular. Las intersecciones salen solas de donde los ramales tocan el anillo.
	road_graph = RoadGraph.new()
	road_graph.add_route(road_pts, RoadGraph.Kind.ROAD, true)
	road_graph.add_route(data_provider.rail_points, RoadGraph.Kind.RAIL, true)
	# RAMALES: salen del anillo y vuelven a el, metiendose hacia el centro. Cada uno
	# se esculpe como carretera (mas permisiva que la via: puede tener mas pendiente).
	if config.corridor_branches > 0:
		var isle_center := pre.bounds.get_center()
		for br_any in CorridorPlanner.plan_branches(spine, isle_center,
				config.corridor_branches, config.corridor_branch_span,
				hash([config.seed_variant, "branches"])):
			var br: PackedVector2Array = MapDataProvider._smooth_route(
					br_any, false, river_layers, 0.7, 2, 0.18, 5.0)
			if br.size() < 6:
				continue
			var bl := PathCarveLayer.new()
			bl.layer_name = &"branch_road"
			bl.path_mode = PathCarveLayer.PathMode.FLATTEN_ALONG
			bl.points = br
			bl.is_ring = false
			bl.width_m = config.road_width_m
			bl.falloff_m = config.road_falloff_m
			bl.target_smooth_passes = 6
			bl.max_grade = 0.08     # una carretera sube mas que una via
			bl.smooth_window_m = 50.0
			bl.cut_bias = 0.35
			(out.roads as Array[HeightLayer]).append(bl)
			road_graph.add_route(br, RoadGraph.Kind.ROAD, false)
	(out.rails as Array[HeightLayer]).append(corridor)
	_rail_layer = corridor
	if config.rail_enabled:
		_rail_sidings = MapDataProvider.make_sidings(data_provider.rail_points,
				hash([config.seed_variant, "sidings"]), 2)
		_siding_layers.clear()
		for sp: PackedVector2Array in _rail_sidings:
			(out.rails as Array[HeightLayer]).append(_make_siding_layer(sp))
	# Capa FANTASMA de carretera: enabled=false ⇒ NO esculpe (el corredor ya lo
	# hizo); la topología (bake_hydro lee points/width sin mirar enabled), el
	# splat y los puentes SÍ la consumen. rail_points ya marca RAIL en _stamp_rails.
	var road_topo := PathCarveLayer.new()
	road_topo.layer_name = &"road_flatten"
	road_topo.path_mode = PathCarveLayer.PathMode.FLATTEN_ALONG
	road_topo.points = road_pts
	road_topo.width_m = config.road_width_m
	road_topo.falloff_m = config.road_falloff_m
	road_topo.is_ring = true
	road_topo.enabled = false
	(out.roads as Array[HeightLayer]).append(road_topo)
	return out


## Capa de carve de un apartadero (#115) — compartida por SPLIT y CORRIDOR.
## Registra en _siding_layers (RailBuilder pone los rieles sobre su target).
func _make_siding_layer(sp: PackedVector2Array) -> PathCarveLayer:
	var sl := PathCarveLayer.new()
	sl.layer_name = &"rail_flatten"
	sl.path_mode = PathCarveLayer.PathMode.FLATTEN_ALONG
	sl.points = sp
	sl.width_m = config.rail_width_m
	sl.falloff_m = config.rail_falloff_m
	sl.max_grade = 0.03
	sl.smooth_window_m = 70.0
	sl.max_bank_slope = 0.5
	_siding_layers.append(sl)
	return sl


## Fases B+C (altura): aplicar ruido base + rasgos y ESCULPIR (el cilindro
## del río, carreteras, vías y lagos leen la altura ya formada).
func _stage_height_bake() -> void:
	sampler = HeightSampler.new()
	sampler.setup(data_provider.graph, _planned_layers, data_provider.get_map_bounds(),
			config.height_scale, config.seed_variant, data_provider.query)
	progress_source = sampler
	await sampler.bake(terrain_settings.bake_resolution,
			terrain_settings.bake_smooth_passes, _fy)
	# Nivel de agua de cada lago = terreno BAKEADO más bajo del contorno − 0.3
	# (hielo casi a ras). El cráter ya cavó a esa cota; sin esto el agua se
	# calculaba con la elevación del grafo y flotaba sobre la meseta base.
	for lake in data_provider.lakes:
		var poly: PackedVector2Array = lake.polygon
		var rim := INF
		for p in poly:
			rim = minf(rim, sampler.get_height(p))
		if rim < INF:
			lake.water_y = rim - (0.1 if lake.get("frozen", false) else 0.3)


## Topología hidrológica v1 (para planificar monumentos/caminos).
func _stage_topology_hydro() -> void:
	topology = TopologyMap.new()
	progress_source = topology
	await topology.bake_hydro(sampler, data_provider, sea_level, _river_layers,
			_road_layers, terrain_settings.topology_resolution,
			terrain_settings.topology_side_width_m, _fy)
	_stamp_rails()


## F7: monumentos + red de caminos → capas nuevas → RE-bake.
func _stage_pois_plan() -> void:
	_poi_system = POISystem.new()
	_poi_system.name = "POIs"
	_poi_system.poi_definitions = poi_definitions
	add_child(_poi_system)
	var poi_rng := RandomNumberGenerator.new()
	poi_rng.seed = hash([config.seed_variant, "pois"])
	var flatten_layers := _poi_system.plan(self, poi_rng)
	var net_layers: Array[HeightLayer] = []
	if config.road_mode != "CIRCUIT" and _poi_system.planned.size() >= 2:
		if road_network == null:
			road_network = RoadNetworkBuilder.new()
		var sites: Array[Vector2] = []
		for site in _poi_system.planned:
			sites.append(site.pos)
		# §F5 (CORRIDOR): la red ANCLA al anillo costero — el punto del anillo
		# más cercano a un monumento entra como sitio, y el MST tiende el ramal
		# monumentos↔corredor (como Rust: los caminos conectan monumentos).
		if config.corridor_mode == "CORRIDOR" and not _road_layers.is_empty() \
				and not sites.is_empty():
			var ring_pts := (_road_layers[0] as PathCarveLayer).points
			if ring_pts.size() > 1:
				var best := ring_pts[0]
				var best_d := INF
				for rp in ring_pts:
					for s in sites:
						var d := rp.distance_squared_to(s)
						if d < best_d:
							best_d = d
							best = rp
				sites.append(best)
		var paths := road_network.build(sites, data_provider,
				config.height_scale, poi_rng)
		for path in paths:
			var rl := PathCarveLayer.new()
			rl.layer_name = &"road_flatten"
			rl.path_mode = PathCarveLayer.PathMode.FLATTEN_ALONG
			rl.target_smooth_passes = 6
			rl.max_grade = 0.06
			rl.smooth_window_m = 45.0
			rl.max_bank_slope = 0.55  # la zona acompaña al terraplén
			for riv in _river_layers:
				if riv is PathCarveLayer:
					rl.protected_layers.append(riv)
			rl.points = MapDataProvider._resample(MapDataProvider._relax_sharp(
					MapDataProvider._chaikin(MapDataProvider._deflect_from_rivers(
					path, _river_layers), 2), 0.32, 3), 6.0)
			rl.width_m = config.road_width_m
			rl.falloff_m = config.road_falloff_m
			net_layers.append(rl)
		_bridge_layers.append_array(net_layers)
	if not flatten_layers.is_empty() or not net_layers.is_empty():
		sampler.layers.append_array(flatten_layers)
		sampler.layers.append_array(net_layers)
		progress_source = sampler
		await sampler.bake(terrain_settings.bake_resolution,
				terrain_settings.bake_smooth_passes, _fy)
		# Topología hidro final con TODAS las capas de camino.
		var all_roads := _road_layers.duplicate()
		all_roads.append_array(net_layers)
		topology = TopologyMap.new()
		progress_source = topology
		await topology.bake_hydro(sampler, data_provider, sea_level, _river_layers,
				all_roads, terrain_settings.topology_resolution,
				terrain_settings.topology_side_width_m, _fy)
		_stamp_rails()

## Splat + BiomeMap (sobre alturas/topología finales).
func _stage_splat() -> void:
	# Construir en un LOCAL y asignar `splat` al miembro RECIÉN cuando está listo:
	# build() es async (cede frames), y una entidad que consulta get_surface_at en
	# su _physics_process durante esa ventana veía `splat != null` pero splat_0 null
	# → crash (get_pixel sobre null). Peor al REGENERAR (isla grande = build largo).
	var sb := SplatMapBuilder.new()
	var rules := splat_rules if splat_rules != null else SplatRules.make_default(
			terrain_settings.snow_line_m)
	progress_source = sb
	await sb.build(sampler, topology, rules, terrain_settings.splat_resolution,
			terrain_settings.splat_edge_blur_m, _fy)
	splat = sb   # ya tiene splat_0/splat_1 → nunca se ve a medio construir
	biome_map = BiomeMapBuilder.new()
	progress_source = biome_map
	await biome_map.build(sampler, terrain_settings.splat_resolution,
			terrain_settings.splat_edge_blur_m, _fy)
	if _poi_system != null:
		_poi_system.apply_modifiers(self)  # pinta plataforma + estampa MONUMENT


## Material + chunks/meshes del terreno (+ SeaMask para colliders/agua).
func _stage_terrain_mesh() -> void:
	terrain_material = TerrainMaterialBuilder.build(sampler, splat,
			biome_map.biome_image, texture_set,
			Vector2(global_position.x, global_position.z), sea_level, debug_mode)
	# F1 · STREAMING VIEW-FIRST (docs/PLAN_TERRENO_QUADTREE.md §7): si el render es
	# cámara-céntrico (quadtree/clipmap) y stream_first está ON, NO construir la
	# malla del mapa ENTERO — el quadtree/clipmap materializa solo alrededor de la
	# cámara al spawnear. Ahorra el O(nx·nz) de chunks en la carga del cliente. El
	# heightfield ya está bakeado (fuente de altura del shader + colisión). Guarda:
	# si no hay renderer cámara-céntrico, construir chunks igual (evita mapa vacío).
	var stream_first := _gfx_bool(&"terrain_stream_first", false)
	var cam_renderer := _gfx_bool(&"terrain_quadtree", false) or _gfx_bool(&"terrain_clipmap", false)
	if stream_first and cam_renderer:
		var empty := Node3D.new()
		empty.name = "Terrain"   # nodo esperado por _apply_clipmap/_apply_quadtree
		add_child(empty)
		if OS.is_debug_build():
			print("terrain_mesh: STREAM-FIRST — chunks omitidos (render por cámara).")
	else:
		var terrain: Node3D = await TerrainBuilder.build(sampler, terrain_settings,
				terrain_material, _fy)
		add_child(terrain)
	sea_mask = SeaMask.new()
	sea_mask.bake(sampler, sea_level)


## Lee un bool de Opciones→graphics (o el default si no hay Settings).
func _gfx_bool(key: StringName, def: bool) -> bool:
	if typeof(Settings) == TYPE_NIL or Settings == null:
		return def
	return bool(Settings.get_value(&"graphics", key, def))


func _stage_colliders() -> void:
	if collider_ring_enabled:
		# §16KM-4: anillo dinámico — carga instantánea (los shapes se crean
		# alrededor del target en runtime), memoria acotada a cualquier tamaño.
		var ring := TerrainColliderRing.new()
		ring.name = "TerrainColliderRing"
		ring.sampler = sampler
		ring.sea_mask = sea_mask
		ring.sea_level = sea_level
		ring.chunk_m = terrain_settings.chunk_size_m
		ring.radius_m = collider_ring_radius_m
		ring.step_m = terrain_settings.collider_step_m
		add_child(ring)
		return
	var collider: StaticBody3D = await TerrainColliderBuilder.build(
			sampler, terrain_settings, sea_level, &"grass", _fy, sea_mask)
	add_child(collider)


## Agua: superficies + volúmenes (nado + buoyancy).
func _stage_water() -> void:
	add_child(WaterBuilder.build(sampler, data_provider, config, sea_level, sea_mask))
	add_child(WaterVolumeBuilder.build(sampler, data_provider, config, sea_level,
			sea_mask))


func _stage_topology_full() -> void:
	progress_source = topology
	await topology.bake_full(sampler, data_provider, sea_level,
			terrain_settings.topology_side_width_m, _fy)


func _stage_entities() -> void:
	var ess := EntitySpawnSystem.new()
	ess.name = "EntitySpawning"
	ess.spawn_tables = spawn_tables
	ess.global_max_entities = global_max_entities
	add_child(ess)
	ess.populate(self)

## Vía de tren: rieles + durmientes sobre el terraplén.
func _stage_rails() -> void:
	var rprof: RailProfile = rail_profile if rail_profile != null \
			else RailProfile.make_default()
	add_child(RailBuilder.build(sampler, data_provider.rail_points,
			_rail_layer, rprof))
	# Apartaderos: rieles sobre el LECHO que su capa de carve esculpió (#115).
	for si in _rail_sidings.size():
		var slayer: PathCarveLayer = _siding_layers[si] if si < _siding_layers.size() else null
		var sd := RailBuilder.build(sampler, _rail_sidings[si], slayer, rprof)
		sd.name = "Siding_%d" % si
		add_child(sd)
	if spawn_test_train:
		_place_test_train(rprof)


## A4 (AUDITORÍA_LOD): rebuild ESTRUCTURAL de vegetación al cambiar el preset en
## vivo (start_lod/densidad no se pueden re-escalar sobre MMIs existentes). Con
## debounce de 1 s (arrastrar el selector no re-puebla 5 veces); los pools de
## malla están en caché de memoria y los impostores en disco → repoblar es
## mayormente re-instanciar. Lo pide VegetationSystem._on_settings_changed.
var _veg_rebuild_queued := false
var _generated := false   # true recién al terminar la generación completa


func request_vegetation_rebuild() -> void:
	# No repoblar durante la generación inicial (el populate en curso se
	# rompería al liberarle el nodo debajo).
	if _veg_rebuild_queued or not _generated or sampler == null:
		return
	_veg_rebuild_queued = true
	await get_tree().create_timer(1.0).timeout
	_veg_rebuild_queued = false
	# BUILD-THEN-SWAP (sin el "reload"/flash que veía el usuario): en vez de LIBERAR
	# la vegetación vieja y RECIÉN construir la nueva (deja un hueco visible mientras
	# el populate async corre), RENOMBRAMOS la vieja (libera el nombre canónico),
	# construimos la nueva encima, y recién ENTONCES liberamos la vieja. La vieja
	# queda visible hasta que la nueva está lista → transición sin vacío.
	var olds: Array[Node] = []
	for nm in ["Vegetation", "GrassPatches"]:
		var old := get_node_or_null(nm)
		if old != null:
			old.name = nm + "_old"   # deja libre el nombre para la nueva
			olds.append(old)
	await _stage_vegetation()
	for old in olds:
		if is_instance_valid(old):
			old.queue_free()
	if OS.is_debug_build():
		print("VegetationSystem: repoblada en vivo sin flash (preset %d)" % VegetationQuality.preset_index)


## Vegetación: bosques/rocas por topología.
func _stage_vegetation() -> void:
	# Prioridad: @export del mapa > config GLOBAL del jugador (user://, la que
	# guardó en el vivero — "lo configuro una vez y me sigue a todo mapa") > null.
	FloraConfig.active = flora_config if flora_config != null else FloraConfig.load_global()
	var veg := VegetationSystem.new()
	veg.name = "Vegetation"
	veg.profiles = vegetation_profiles if not vegetation_profiles.is_empty() \
			else VegetationSystem.make_default_profiles()
	add_child(veg)
	await veg.populate(self, _fy, _veg_scale)
	# Pasto DENSO por parches alrededor del jugador (#56.1, diseño
	# mb_grass_* de Melba): celdas deterministas que aparecen/desaparecen
	# con la cámara — el pasto global disperso cubre la distancia.
	var patches := GrassPatchSystem.new()
	patches.name = "GrassPatches"
	patches.sampler = sampler
	patches.topology = topology
	patches.sea_level = sea_level
	patches.blade_mesh = FloraFactory.make_grass_tuft()
	patches.data_provider = data_provider  # pasto por bioma (Fase 3)
	# Pasto = detalle PURAMENTE visual (no es "mundo"): escala con las fracciones
	# del usuario — ULTRA ES LO NORMAL (1.0) y de ahí bajamos: alto 0.75 · medio
	# 0.5 · bajo 0.25 · potato 0.15. El slider grass_quality multiplica aparte.
	var gq := clampi(int(Settings.get_value(&"graphics", &"world_quality", 3)), 0, 4) \
			if typeof(Settings) != TYPE_NIL and Settings != null else 3
	patches.density_scale = [0.15, 0.25, 0.5, 0.75, 1.0][gq]
	# La hoja del quadtree como CONTENEDOR ESPACIAL: el pasto se descarta con el
	# MISMO test de cono que el terreno (una prueba tira miles de briznas de golpe).
	patches.spatial_gate = _quadtree
	add_child(patches)
	_build_terrain_occluder()


## Occlusion culling (experimental, opt-in): un OCLUIDOR grueso del terreno (grilla
## baja desde el heightfield) → las colinas ocultan lo que tienen detrás (bosque, props).
## El pasto/árboles NO ocluyen (tienen huecos); solo lo SÓLIDO. Requiere el flag global
## rendering/occlusion_culling. Default OFF: se mide si rinde (en isla abierta con pocas
## colinas puede no valer). Se aplica al regenerar el mundo.
func _build_terrain_occluder() -> void:
	if sampler == null:
		return
	if typeof(Settings) == TYPE_NIL or Settings == null:
		return
	if not bool(Settings.get_value(&"graphics", &"occlusion", false)):
		return
	var half: float = config.map_size * 0.5
	var n := 40                                   # grilla BAJA: ocluidor barato (CPU raster)
	var step: float = config.map_size / float(n)
	var verts := PackedVector3Array()
	for j in n + 1:
		for i in n + 1:
			var x := -half + float(i) * step
			var z := -half + float(j) * step
			verts.append(Vector3(x, sampler.get_height(Vector2(x, z)), z))
	var idx := PackedInt32Array()
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			idx.append_array([a, a + n + 1, a + 1, a + 1, a + n + 1, a + n + 2])
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, idx)
	var oi := OccluderInstance3D.new()
	oi.name = "TerrainOccluder"
	oi.occluder = occ
	add_child(oi)
	if debug_mode:
		print("OcclusionCulling: ocluidor de terreno %d² (%d tris)" % [n, n * n * 2])


## Monumentos: instanciar sobre plataformas niveladas.
func _stage_pois_place() -> void:
	_poi_system.place(self)


## Navmesh (bloqueado en _ready; se hornea acá, con los colliders listos).
func _stage_navmesh() -> void:
	_setup_navigation()


func _stage_spawn_points() -> void:
	_generate_spawn_points()


## Overlays de inspección post-generación (Inspector → Debug).
func _apply_debug_overlay() -> void:
	if debug_overlay == 1:
		# Aristas Voronoi (v0→v1) apoyadas sobre el terreno, verde brillante.
		var verts := PackedVector3Array()
		for e_any in data_provider.graph.edges:
			var e := e_any as Edge
			if e.v0 == null or e.v1 == null:
				continue
			verts.append(Vector3(e.v0.point.x,
					sampler.get_height(e.v0.point) + 0.4, e.v0.point.y))
			verts.append(Vector3(e.v1.point.x,
					sampler.get_height(e.v1.point) + 0.4, e.v1.point.y))
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.2, 1.0, 0.3)
		mesh.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.name = "PolygonOverlay"
		mi.mesh = mesh
		add_child(mi)
	elif debug_overlay == 2:
		RenderingServer.set_debug_generate_wireframes(true)
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME


## Coloca un tren de TEST que RECORRE la vía (tren componente, por longitud de arco).
## Modelo swappeable (test_train_mesh o locomotora procedural).
func _place_test_train(_rprof: RailProfile) -> void:
	var pts := data_provider.rail_points
	if pts.size() < 3:
		return
	var i := floori(pts.size() / 3.0)   # arranca a un tercio del recorrido
	# Alturas por punto de la vía (target) para que el tren suba/baje con el
	# terraplén; si no hay capa, usa el terreno.
	var ys := PackedFloat32Array()
	for j in pts.size():
		var yj: float = sampler.get_height(pts[j])
		if _rail_layer != null and _rail_layer.target_heights.size() == pts.size():
			yj = maxf(yj, _rail_layer.target_heights[j])
		ys.append(yj)
	# TREN NUEVO (component-based) sobre la vía GENERADA: plataforma caminable + cabina con
	# asiento (bajás y quedás arriba); reemplaza al RailTrain viejo. Reparento el TrainBody bajo
	# un holder "TestTrain" (así su hijo directo es el cuerpo sobre la vía → cumple el guardián).
	if component_train_scene != null:
		var rig := component_train_scene.instantiate()
		rig.name = "TestTrain"
		add_child(rig)   # en el árbol → TrainBody._ready corre (setup de componentes)
		# El Path3D interno no se usa en modo vía (y quedaría fuera del riel) → lo quito para
		# que el único hijo sea el cuerpo del tren, sobre la vía (cumple el guardián #25).
		var rp := rig.get_node_or_null(^"RailPath")
		if rp != null:
			rp.free()
		# LOCO: train.tscn envuelve el cuerpo en "TrainBody"; los vagones-cabina nuevos
		# (wagon_cabin) TIENEN el cuerpo en la RAÍZ (con get_component). Aceptamos ambos.
		var tbody := rig.get_node_or_null(^"TrainBody")
		var wagon_parent: Node = rig   # los vagones cuelgan del rig estático (train.tscn)
		if tbody == null and rig.has_method(&"get_component"):
			tbody = rig            # loco cuyo ROOT es el cuerpo (wagon_cabin, sin wrapper)
			wagon_parent = self    # cuerpo móvil: colgar los vagones del MAPA estático
		var tdrive: Node = tbody.call(&"get_component", &"drive") if tbody != null else null
		if tdrive != null and tdrive.has_method(&"set_rail"):
			tdrive.call(&"set_rail", pts, ys, _arc_at(pts, i))
			# VAGONES enganchados (convoy caminable): mallas procedurales (TrainFactory) en
			# AnimatableBody3D sync_to_physics (te llevan parado arriba). Swappeables.
			if component_wagon_scene != null:
				for wi in 3:
					var wag := component_wagon_scene.instantiate() as Node3D
					wag.name = "Wagon_%d" % wi
					wagon_parent.add_child(wag)   # sobre la vía vía _sample (cumple el guardián)
					tdrive.call(&"add_wagon", wag, 8.0 + float(wi) * 8.0)
			# AGUJAS: los sidings (doble vía) son RAMALES elegibles con A/D en el cruce.
			_wire_train_junctions(tdrive, pts)
	# Tren APARCADO en un apartadero (#115): MISMO tren componente que el de test
	# (una sola implementación; el RailTrain viejo se archivó). Queda quieto sin
	# conductor, y se puede subir y sacar del apartadero — es un spawn real.
	if not _rail_sidings.is_empty() and component_train_scene != null and test_train_mesh == null:
		var sp: PackedVector2Array = _rail_sidings[0]
		var sys := PackedFloat32Array()
		for sq in sp:
			sys.append(sampler.get_height(sq))
		var parked := component_train_scene.instantiate()
		parked.name = "SidingTrain"
		add_child(parked)
		var prp := parked.get_node_or_null(^"RailPath")
		if prp != null:
			prp.free()   # modo vía: el único hijo es el cuerpo sobre el riel (guardián #25)
		var pbody := parked.get_node_or_null(^"TrainBody")
		if pbody == null and parked.has_method(&"get_component"):
			pbody = parked   # loco con el cuerpo en la raíz (wagon_cabin)
		var pdrive: Node = pbody.call(&"get_component", &"drive") if pbody != null else null
		# DENTRO del apartadero (al medio), NO al inicio: un tren que entra por la
		# aguja no lo choca de frente (regla del usuario). start_s = mitad del arco.
		if pdrive != null and pdrive.has_method(&"set_rail"):
			pdrive.call(&"set_rail", sp, sys, _arc_at(sp, floori(sp.size() / 2.0)))


## Conecta los sidings (doble vía) como RAMALES elegibles: en la aguja (punto de la vía principal
## más cercano al inicio del siding) el conductor elige con A/D. Best-effort geométrico.
func _wire_train_junctions(tdrive: Node, pts: PackedVector2Array) -> void:
	if tdrive == null or not tdrive.has_method(&"add_junction") or pts.size() < 2:
		return
	for sp: PackedVector2Array in _rail_sidings:
		if sp.size() < 2:
			continue
		var jn_idx := 0
		var jn_d := INF
		for k in pts.size():
			var dd: float = pts[k].distance_to(sp[0])
			if dd < jn_d:
				jn_d = dd
				jn_idx = k
		if jn_d > config.rail_width_m * 4.0:
			continue   # el siding no arranca cerca de la vía → no es un cruce real
		var sy := PackedFloat32Array()
		for q in sp:
			sy.append(sampler.get_height(q))
		var seg: int = tdrive.call(&"add_rail", sp, sy)
		# Lado (izq/der) por el producto cruz de la dirección de la vía × (siding − vía).
		var fwd: Vector2 = pts[mini(jn_idx + 1, pts.size() - 1)] - pts[jn_idx]
		var to: Vector2 = sp[0] - pts[jn_idx]
		var side := 1 if (fwd.x * to.y - fwd.y * to.x) < 0.0 else -1
		tdrive.call(&"add_junction", 0, _arc_at(pts, jn_idx), seg, 0.0, side)


## Registra las acciones de manejo del tren si no existen (W/S adelante/atrás).
func _ensure_train_actions() -> void:
	for pair: Array in [[&"train_forward", KEY_I], [&"train_reverse", KEY_K]]:
		if not InputMap.has_action(pair[0]):
			InputMap.add_action(pair[0])
			var ev := InputEventKey.new()
			ev.physical_keycode = pair[1]
			InputMap.action_add_event(pair[0], ev)


## Arco acumulado hasta el índice i de una polilínea.
func _arc_at(pts: PackedVector2Array, idx: int) -> float:
	var s := 0.0
	for j in range(1, mini(idx + 1, pts.size())):
		s += pts[j].distance_to(pts[j - 1])
	return s


func _generate_spawn_points() -> void:
	var root := Node3D.new()
	root.name = "SpawnPoints"
	add_child(root)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([config.seed_variant, "spawn_points"])
	var b := sampler.bounds
	var placed := 0
	var attempts := 0
	while placed < spawn_count and attempts < spawn_count * 200:
		attempts += 1
		var pos := Vector2(rng.randf_range(b.position.x, b.end.x),
				rng.randf_range(b.position.y, b.end.y))
		var h := sampler.get_height(pos)
		if h < sea_level + min_spawn_height_m:
			continue
		if sampler.get_slope(pos) > max_spawn_slope:
			continue
		var c := data_provider.get_center_at(pos)
		if c.water:
			continue
		var sp := SpawnPoint.new()
		sp.name = "SpawnPoint_%d" % placed
		# Transform ANTES de add_child: SpawnPoint se registra en _ready y el
		# MapSystem cachea el primer global_transform como spawn activo.
		sp.transform = TerrainPlacer.get_placement_transform(sampler, pos, false)
		sp.transform.origin.y += 0.5  # medio metro sobre el suelo
		root.add_child(sp)
		placed += 1


## ---- API propia (§10.1) ----

## Catálogo ObjId (PortalSDK): referencias directas a objetos colocados.
var _spatial_objects: Dictionary = {}


func register_spatial_object(obj_id: int, node: Node3D) -> void:
	_spatial_objects[obj_id] = node


func get_spatial_object(obj_id: int) -> Node3D:
	var n: Node3D = _spatial_objects.get(obj_id)
	return n if is_instance_valid(n) else null


func get_graph() -> PolygonGraph:
	return data_provider.graph


func get_biome_at(world_pos: Vector3) -> String:
	return data_provider.get_biome_at(Vector2(world_pos.x, world_pos.z))


func get_height_at(world_xz: Vector2) -> float:
	return sampler.get_height(world_xz)


func get_topology_at(world_xz: Vector2) -> int:
	return topology.get_topology(world_xz)


## Material del splat → id de superficie del juego (pasos/impactos).
const GROUND_TO_SURFACE: Array[StringName] = [
	&"grass",    # GRASS
	&"dirt",     # DIRT
	&"sand",     # SAND
	&"stones",   # ROCK
	&"snow",     # SNOW
	&"forest",   # FOREST_FLOOR
	&"gravel",   # GRAVEL
	&"dirt",     # MUD (no hay pasos de barro — dirt es lo más cercano)
]


func get_surface_at(world_pos: Vector3) -> StringName:
	# Guard doble: builder null O imagen a medio construir (defensa; el root fix
	# está en _stage_splat que asigna `splat` recién cuando splat_0 existe).
	if splat == null or splat.splat_0 == null:
		return &"grass"
	var ground := splat.dominant_material(Vector2(world_pos.x, world_pos.z))
	return GROUND_TO_SURFACE[ground]
