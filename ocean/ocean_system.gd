class_name OceanSystem
extends Node3D

## ============================================================================
## OceanSystem · Océano AAA por capas (reemplaza al OceanQuadtree viejo)
## ============================================================================
## Diseño desde cero, en CAPAS independientes (ver docs/PLAN_OCEANO_REALISTA.md):
##
##   1. SUPERFICIE  — malla por `QuadtreeMeshLOD` (celdas por cámara, cone-cull,
##                    morph) + `shaders/ocean/OceanSurface.gdshader`.
##   2. OLEAJE      — `OceanWaveGPU`: FFT sobre un espectro TMA en compute
##                    shaders. Caos SIN dirección dominante (miles de
##                    componentes, no N olas sumadas a mano) + espuma por
##                    Jacobiano. Es lo que mata el look "de computadora".
##   3. SUELO       — fondo marino a `floor_depth_m` (negativo), misma clase de
##                    malla. Su profundidad ALIMENTA el espectro: mar somero ⇒
##                    olas más cortas, como en la realidad.
##   4. (pendiente) DINÁMICA — ripple map local para estelas de barcos.
##
## REGLA DEL PROYECTO: todo se configura por @export desde el Inspector.
## El nivel del mar es 0 y el suelo se mide en metros NEGATIVOS desde ahí.
## ============================================================================

## Nivel del mar (m). El proyecto trabaja con 0.
@export var sea_level_m: float = 0.0
## Profundidad del SUELO OCEÁNICO en metros NEGATIVOS desde el nivel del mar.
## Además de poner el fondo, alimenta el espectro de olas (agua somera ⇒ olas más
## cortas y atenuadas: es física real, no un truco visual).
@export var floor_depth_m: float = -120.0:
	set(v):
		floor_depth_m = minf(v, -0.5)
		if _wave_gpu != null:
			_wave_gpu.depth_m = absf(floor_depth_m)
		if _floor_qt != null:
			_floor_qt.position.y = floor_depth_m
## Dibujar el suelo oceánico. Apagarlo si el terreno ya cubre el fondo.
@export var floor_enabled: bool = true
## COLISIÓN del fondo marino: se puede caminar/apoyar en el lecho al bucear. Reusa
## `TerrainColliderRing` (anillo de shapes alrededor del jugador), no un collider
## gigante — regla del proyecto: reusar antes de crear.
@export var floor_collision: bool = true
## Radio del anillo de colisión del fondo (m).
@export var floor_collision_radius_m: float = 96.0
## Material del fondo marino (null = uno gris mate de arranque). Ver
## `TuProyecto/shaders/OceanShaders/` para materiales de fondo reales.
@export var floor_material: Material = null
## RELIEVE del fondo, EN METROS POR CAPA (como el original de
## `ocean_floor_system/OceanFloorGenerator.gd`, no pesos normalizados).
## OJO — error corregido: la primera versión normalizaba por la suma de pesos y
## escalaba todo a 18 m, o sea ~9x MENOS relieve que la referencia, y el fondo
## quedaba plano. En el original cada capa tiene su amplitud propia y la de
## CUENCAS es la DOMINANTE (100 m), no la más chica.
##   cuencas  (0.0005, simplex suave) -> valles y montes submarinos enormes
##   base     (0.005,  simplex suave) -> relieve medio
##   detalle  (0.05,   perlin)        -> rugosidad fina
@export var floor_basin_m: float = 100.0
@export var floor_base_m: float = 50.0
@export var floor_detail_m: float = 10.0
@export var floor_seed: int = 1337

@export_group("Área")
## Lado del área cubierta (m). Con `follow_camera`, el océano se re-centra en la
## cámara y esto es el alcance visible, no el tamaño del mundo.
@export var area_size_m: float = 8192.0
@export var area_center: Vector2 = Vector2.ZERO
## Océano PSEUDO-INFINITO: re-centrar el área en la cámara al alejarse del centro
## más de `recenter_step_m`. Sin esto se ve el borde del mar al navegar.
@export var follow_camera: bool = true
@export var recenter_step_m: float = 512.0

@export_group("Malla (LOD)")
## Celda más fina de la superficie (m). El detalle del FFT se pierde si la malla
## es gruesa: los mapas tienen centímetros por texel.
@export var surface_min_cell_m: float = 12.0
@export var floor_min_cell_m: float = 64.0
@export_range(5, 129, 4) var surface_grid_n: int = 33
@export var split_factor: float = 1.0
## Se aplican EN VIVO a las dos mallas (superficie y suelo).
@export var frustum_cull: bool = true:
	set(v):
		frustum_cull = v
		for qt in [_surface_qt, _floor_qt]:
			if qt != null:
				qt.frustum_cull = v
@export var morph: bool = true:
	set(v):
		morph = v
		if _surface_qt != null:
			_surface_qt.morph = v

@export_group("Oleaje (FFT)")
## Resolución de los mapas FFT. 256 = ~4 MB por cascada; 1024 = ~200 MB (medido
## en el análisis). Empezar en 256 y subir solo si hace falta.
@export_enum("128:128", "256:256", "512:512", "1024:1024") var map_size: int = 256
## Cascadas de oleaje (escalas). 3 = olas grandes + medianas + detalle. Se
## configuran por Inspector (regla del proyecto), no por .tres sueltos.
@export var cascades: Array[OceanCascade] = []
## Actualizaciones del oleaje por segundo. Bajarlo alivia la GPU (el movimiento
## se sigue viendo suave); el generador reparte 1 cascada por frame.
@export_range(1, 120) var updates_per_second: int = 50

@export_group("Estelas (capa dinámica)")
## Capa que REACCIONA: estelas de barcos, chapoteos, ondas que chocan. Se suma al
## FFT. Corre en SubViewports (no compute), así que anda en cualquier renderer.
@export var ripples_enabled: bool = true
## Lado de la ventana simulada alrededor del player (m).
@export var ripple_window_m: float = 256.0
## Altura que aporta una onda de la simulación (m).
@export var ripple_height_m: float = 1.2

var _surface_qt: QuadtreeMeshLOD = null
var _floor_qt: QuadtreeMeshLOD = null
var _wave_gpu: OceanWaveGPU = null
var _ripples: OceanRipples = null
var _floor_noise: Array[FastNoiseLite] = []
var _floor_collider = null
var _surface_mat: ShaderMaterial = null
var _disp_tex: Texture2DArrayRD = null
var _norm_tex: Texture2DArrayRD = null
var _accum := 0.0
var _center := Vector2.ZERO
var _built := false

const SURFACE_SHADER := preload("res://shaders/ocean/OceanSurface.gdshader")


func _ready() -> void:
	if cascades.is_empty():
		cascades = _default_cascades()
	_center = area_center
	_build_surface()
	if floor_enabled:
		_build_floor()
	_built = true


## Tres escalas por defecto: oleaje largo, medio y detalle. Valores de arranque
## (mar moderado); se afinan desde el Inspector.
func _default_cascades() -> Array[OceanCascade]:
	var out: Array[OceanCascade] = []
	var tiles := [Vector2(320.0, 320.0), Vector2(84.0, 84.0), Vector2(19.0, 19.0)]
	var disp := [1.0, 0.75, 0.4]
	for i in 3:
		var c := OceanCascade.new()
		c.tile_length = tiles[i]
		c.displacement_scale = disp[i]
		c.normal_scale = 1.0
		# 12 m/s daba olas de ~9.5 m (temporal). 7 m/s = mar moderado, escala
		# creible respecto a un jugador de 1.8 m.
		c.wind_speed = 7.0
		c.wind_direction = 30.0
		c.fetch_length = 400.0
		c.swell = 0.7
		c.spread = 0.25
		c.detail = 1.0
		# whitecap ALTO = umbral de rotura mas exigente; foam_amount BAJO = la espuma
		# no se acumula. Con 0.5/5.0 la espuma saturaba TODO el mar en blanco (medido).
		c.whitecap = 0.92
		c.foam_amount = 0.6
		out.append(c)
	return out


func _build_surface() -> void:
	_surface_qt = QuadtreeMeshLOD.new()
	_surface_qt.name = "OceanSurface"
	_surface_qt.area_size_m = area_size_m
	_surface_qt.area_center = _center
	_surface_qt.min_cell_m = surface_min_cell_m
	_surface_qt.grid_n = surface_grid_n
	_surface_qt.split_factor = split_factor
	_surface_qt.frustum_cull = frustum_cull
	_surface_qt.morph = morph
	_surface_qt.rough_gain = 0.0            # el mar no tiene "rugosidad de terreno"
	_surface_qt.frustum_height_m = 32.0     # el mar es plano: caja de test baja
	add_child(_surface_qt)

	_surface_mat = ShaderMaterial.new()
	_surface_mat.shader = SURFACE_SHADER
	_surface_mat.set_shader_parameter(&"sea_level_m", sea_level_m)
	_surface_qt.setup(_surface_mat)

	if ripples_enabled:
		_ripples = OceanRipples.new()
		_ripples.name = "Ripples"
		_ripples.window_m = ripple_window_m
		add_child(_ripples)
	_wave_gpu = OceanWaveGPU.new()
	_wave_gpu.name = "WaveGPU"
	_wave_gpu.map_size = map_size
	_wave_gpu.depth_m = absf(floor_depth_m)
	add_child(_wave_gpu)


func _build_floor() -> void:
	_floor_qt = QuadtreeMeshLOD.new()
	_floor_qt.name = "OceanFloor"
	_floor_qt.area_size_m = area_size_m
	_floor_qt.area_center = _center
	_floor_qt.min_cell_m = floor_min_cell_m   # el fondo no necesita detalle fino
	_floor_qt.split_factor = split_factor * 0.5
	_floor_qt.frustum_cull = frustum_cull
	_floor_qt.rough_gain = 0.0
	_floor_qt.frustum_height_m = 32.0
	_floor_qt.position.y = floor_depth_m
	# Relieve por 3 capas de ruido (ver floor_relief_m). El quadtree ya sabe usar
	# un height_query: es el mismo mecanismo del split por rugosidad del terreno.
	if floor_basin_m > 0.0 or floor_base_m > 0.0:
		_build_floor_noise()
		_floor_qt.height_query = Callable(self, &"floor_height")
		_floor_qt.rough_gain = 1.5   # más subdivisión donde el fondo es accidentado
	add_child(_floor_qt)
	var m: Material = floor_material
	if m == null:
		var sm := StandardMaterial3D.new()
		sm.albedo_color = Color(0.22, 0.24, 0.26)
		sm.roughness = 0.95
		m = sm
	_floor_qt.setup(m)
	if floor_collision:
		_build_floor_collider()


## Anillo de colisión del LECHO marino. Sin sea_mask a propósito: el anillo del
## terreno SALTEA el mar (ahí no hay suelo que pisar); acá el mar es justamente
## donde queremos shapes.
func _build_floor_collider() -> void:
	var ring := TerrainColliderRing.new()
	ring.name = "OceanFloorCollider"
	ring.height_source = FloorHeightSource.new(self)
	ring.sampler = null
	ring.sea_mask = null
	ring.sea_level = 10000.0    # nunca descartar por "mar profundo": ES el fondo
	ring.radius_m = floor_collision_radius_m
	ring.chunk_m = 64.0
	ring.step_m = 2.0
	add_child(ring)
	_floor_collider = ring


## Adaptador: `TerrainColliderRing` pide un objeto con `get_height(Vector2)`.
class FloorHeightSource extends RefCounted:
	var _ocean
	var bounds: Rect2

	func _init(ocean) -> void:
		_ocean = ocean
		var half: float = ocean.area_size_m * 0.5
		bounds = Rect2(ocean.area_center - Vector2(half, half),
				Vector2(ocean.area_size_m, ocean.area_size_m))

	func get_height(xz: Vector2) -> float:
		return _ocean.floor_height(xz)


## Tres capas, como en OceanFloorGenerator: cuencas (0.0005) + base (0.005) +
## detalle (0.05), con semillas separadas para que no se correlacionen.
func _build_floor_noise() -> void:
	var freqs := [0.0005, 0.005, 0.05]
	var types := [FastNoiseLite.TYPE_SIMPLEX_SMOOTH, FastNoiseLite.TYPE_SIMPLEX_SMOOTH,
			FastNoiseLite.TYPE_PERLIN]
	_floor_noise.clear()
	for i in 3:
		var n := FastNoiseLite.new()
		n.seed = floor_seed + i * 1000
		n.frequency = freqs[i]
		n.noise_type = types[i]
		_floor_noise.append(n)


## Altura del fondo marino en un punto (m, negativa). La usan la malla del suelo y
## cualquier sistema que necesite saber dónde está el lecho (anclas, corales, loot).
func floor_height(xz: Vector2) -> float:
	if _floor_noise.size() < 3:
		return floor_depth_m
	# Amplitud propia POR CAPA en metros (sin normalizar): así el fondo tiene
	# cuencas y montes submarinos de verdad, no una ondulación tímida.
	var h := _floor_noise[0].get_noise_2d(xz.x, xz.y) * floor_basin_m
	h += _floor_noise[1].get_noise_2d(xz.x, xz.y) * floor_base_m
	h += _floor_noise[2].get_noise_2d(xz.x, xz.y) * floor_detail_m
	return floor_depth_m + h


func _process(delta: float) -> void:
	if not _built or _wave_gpu == null or _wave_gpu.gpu_unavailable:
		return
	# 1) Oleaje: el generador reparte una cascada por frame (evita el tirón).
	_accum += delta
	var step := 1.0 / float(maxi(updates_per_second, 1))
	if _accum >= step:
		_wave_gpu.update(_accum, cascades)
		_accum = 0.0
		_publish_maps()
	# 1b) La ventana de estelas sigue al player y se publica al shader.
	if _ripples != null and _surface_qt != null:
		var c := _camera()
		if c != null:
			_ripples.center = Vector2(c.global_position.x, c.global_position.z)
		_surface_qt.set_shader_param_all(&"ripples", _ripples.texture())
		_surface_qt.set_shader_param_all(&"ripples_on", true)
		_surface_qt.set_shader_param_all(&"ripple_window",
				Plane(_ripples.center.x, _ripples.center.y, _ripples.window_m, 1.0))
		_surface_qt.set_shader_param_all(&"ripple_height_m", ripple_height_m)
	# 2) Pseudo-infinito: re-centrar el área en la cámara.
	if follow_camera:
		var cam := _camera()
		if cam != null:
			var p := Vector2(cam.global_position.x, cam.global_position.z)
			if p.distance_to(_center) > recenter_step_m:
				_recenter(p)


func _camera() -> Camera3D:
	if _surface_qt != null and _surface_qt.target_camera != null:
		return _surface_qt.target_camera
	if typeof(PlayerRegistry) != TYPE_NIL and PlayerRegistry != null:
		var c: Camera3D = PlayerRegistry.active_camera()
		if c != null:
			return c
	return get_viewport().get_camera_3d() if get_viewport() != null else null


## Mueve el área del océano al jugador (mar sin borde). Se re-centra a saltos de
## `recenter_step_m` para no reconstruir el árbol todos los frames.
func _recenter(p: Vector2) -> void:
	_center = p.snapped(Vector2(recenter_step_m, recenter_step_m))
	for qt in [_surface_qt, _floor_qt]:
		if qt != null:
			qt.area_center = _center
			qt.clear_leaves()


## Publica los mapas del FFT en el material de la superficie.
func _publish_maps() -> void:
	if _wave_gpu.gpu_unavailable or _wave_gpu.context == null or _surface_mat == null:
		return
	if _disp_tex == null:
		_disp_tex = Texture2DArrayRD.new()
		_norm_tex = Texture2DArrayRD.new()
		_disp_tex.texture_rd_rid = _wave_gpu.descriptors[&"displacement_map"].rid
		_norm_tex.texture_rd_rid = _wave_gpu.descriptors[&"normal_map"].rid
		_surface_qt.set_shader_param_all(&"displacements", _disp_tex)
		_surface_qt.set_shader_param_all(&"normals", _norm_tex)
	_surface_qt.set_shader_param_all(&"num_cascades", cascades.size())
	# map_scales: [1/tile.x, 1/tile.y, escala de desplazamiento, escala de normal]
	# PackedVector4Array: es el tipo que espera un `uniform vec4 arr[N]` en Godot 4.
	var scales := PackedVector4Array()
	for c in cascades:
		scales.append(Vector4(1.0 / maxf(c.tile_length.x, 0.001),
				1.0 / maxf(c.tile_length.y, 0.001),
				c.displacement_scale, c.normal_scale))
	_surface_qt.set_shader_param_all(&"map_scales", scales)


## Cámara que MANDA el LOD del océano (la del player; la espía solo observa).
func set_target_camera(cam: Camera3D) -> void:
	for qt in [_surface_qt, _floor_qt]:
		if qt != null:
			qt.target_camera = cam


## Le pasa al shader del mar el heightfield del TERRENO: con eso atenúa la ola en
## agua poco profunda y recorta su borde donde el terreno sale del agua.
func set_depth_field(tex, origin, size_m, height_scale: float) -> void:
	if _surface_qt == null or tex == null:
		return
	_surface_qt.set_shader_param_all(&"depth_field", tex)
	_surface_qt.set_shader_param_all(&"depth_origin",
			origin if origin is Vector2 else Vector2.ZERO)
	_surface_qt.set_shader_param_all(&"depth_size_m",
			float(size_m) if size_m != null else 1024.0)
	_surface_qt.set_shader_param_all(&"depth_height_scale", height_scale)
	_surface_qt.set_shader_param_all(&"depth_field_on", true)


## Solo dibujar mar donde hay mar de verdad (SeaMask): evita océano bajo la isla.
func set_surface_query(q) -> void:
	if _surface_qt != null:
		_surface_qt.surface_query = q


## Compatibilidad con la API del quadtree: actualiza las mallas para una posición
## (lo usan bancos y tests que antes hablaban con el OceanQuadtree directo).
func update_for(pos: Vector3) -> void:
	for qt in [_surface_qt, _floor_qt]:
		if qt != null:
			qt.update_for(pos)


## Un objeto toca el agua: barco navegando, jugador nadando, algo que cae.
## Genera una onda REAL que se propaga y choca con las demás.
func splash(world_pos: Vector3, strength: float = 0.5) -> void:
	if _ripples != null:
		_ripples.splash(world_pos, strength)


func ripples() -> OceanRipples:
	return _ripples


func surface_quadtree() -> QuadtreeMeshLOD:
	return _surface_qt


func floor_quadtree() -> QuadtreeMeshLOD:
	return _floor_qt
