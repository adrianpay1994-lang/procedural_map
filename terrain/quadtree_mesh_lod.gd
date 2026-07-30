class_name QuadtreeMeshLOD
extends Node3D

## ============================================================================
## QuadtreeMeshLOD · Malla cámara-dependiente por QUADTREE de chunks-grilla
## ============================================================================
## Camino B de docs/PLAN_TERRENO_QUADTREE.md §6. Clase REUSABLE para cualquier
## superficie grande (terreno, océano, futuras): la altura la pone el VERTEX
## shader (`clipmap_displace`) reusando el MATERIAL REAL, igual que TerrainClipmap.
##
## Cada nodo cubre un cuadrado del área. Se SUBDIVIDE en 4 si la cámara está
## cerca (dist < split_factor·lado) hasta max_depth; se FUSIONA si se aleja (con
## histéresis, para no parpadear). Las hojas son grillas planas GRID_N² a un paso
## por profundidad; el shader las desplaza a la altura real. Cerca ⇒ celdas
## chicas (detalle + cull fino); lejos ⇒ celdas grandes (pocos draws). El frustum
## culling lo hace el motor por el AABB de cada hoja ⇒ NO dibuja lo de atrás.
##
## Costuras entre hojas de distinto nivel = FALDONES (patrón terrain_clipmap):
## el borde se duplica hacia abajo y el shader lo desplaza igual ⇒ cuelga y tapa
## la T-junction. No hace falta stitching de índices (frágil).
##
## Uso:
##   var q := QuadtreeMeshLOD.new()
##   q.area_size_m = sampler.bounds.size.x   # extensión del heightfield
##   q.area_center = sampler.bounds.get_center()
##   q.setup(terrain_material)               # duplica + clipmap_displace
##   map.add_child(q)
## Sigue la cámara ACTIVA (o `target_camera`).
## ============================================================================

const GRID_N := 17            ## Default de `grid_n` (17 vértices = 16 celdas por lado).

## RESOLUCIÓN DEL PATCH: vértices por lado de CADA hoja (todas las hojas usan la
## misma, sea LOD0 o LOD5 — lo que cambia entre LODs es el TAMAÑO que cubre, o sea
## el espaciado en metros = size/(grid_n-1)). Es el knob de calidad #2 (el #1 son
## las DISTANCIAS de LOD): Ultra 33×33 · Bajo 9×9, con las MISMAS distancias y la
## MISMA estructura de quadtree. Potencia de 2 + 1 (9/17/33/65). EN VIVO.
@export_range(5, 129, 4) var grid_n: int = GRID_N:
	set(v):
		var n := clampi(v, 5, 129)
		if n == grid_n:
			return
		grid_n = n
		if _ready:
			_rebuild_meshes()

## Lado del área cubierta (m). Debe coincidir con la extensión del heightfield
## (sampler.bounds.size.x) o los UV del shader caen fuera del mapa.
@export var area_size_m: float = 2048.0
## Centro del área en world XZ.
@export var area_center: Vector2 = Vector2.ZERO
## Lado de la CELDA MÍNIMA en metros (la hoja más fina, pegada a la cámara). Es
## "los metros de la celda" configurables. Si > 0, DERIVA max_depth desde el área
## (max_depth = ceil(log2(area/min_cell))). 0 = usar max_depth directo.
@export var min_cell_m: float = 32.0
## Profundidad máx. Leaf mínimo = area_size_m / 2^max_depth. La sobreescribe
## min_cell_m si este es > 0.
@export_range(1, 12) var max_depth: int = 6
## Subdividir si dist(cámara, nodo) < split_factor · lado_nodo. Más alto = celdas
## más chicas cerca (más detalle, MÁS draws). 1.0 ≈ punto razonable; 2.0 explota
## el nº de draws (medido: ~208 hojas cerca vs ~7 del clipmap).
@export var split_factor: float = 1.0
## F6 · Ganancia de RUGOSIDAD: cuánto MÁS lejos subdivide un nodo rugoso (crestas)
## vs uno plano. 0 = split por distancia pura (como antes). Necesita height_query.
@export var rough_gain: float = 1.5
## F-cull · Poda el ÁRBOL por el FRUSTUM: NO construye celdas fuera del cono de la
## cámara (no solo no las dibuja) → menos nodos/memoria, "solo donde mira la cámara"
## (matchea el diagrama NOT-VISIBLE-TO-CAMERA). Al girar, el borde se reconstruye;
## frustum_margin_m da colchón para que no aparezca hueco al girar rápido. Default off.
@export var frustum_cull: bool = false
@export var frustum_margin_m: float = 40.0
## Partir los nodos que CRUZAN el borde del cono mientras sean más grandes que esto
## (m). Sin esto, una hoja de 1 km que solo roza el cono se dibuja entera y asoma
## por los costados. 0 = desactivado. Bajarlo = borde más pegado pero más nodos.
@export var frustum_split_min_m: float = 128.0
## Histéresis: fusionar recién si dist > split_factor · merge_hysteresis · lado.
## >1 evita el parpadeo split/merge en el umbral.
@export var merge_hysteresis: float = 1.35
## Caída del faldón anti-costura (m). Debe cubrir el salto de altura de UNA celda
## gruesa del vecino de menor nivel; subir si aparecen rendijas.
@export var skirt_m: float = 16.0
## Actualizar el árbol solo cuando la cámara se movió > este umbral (m). Evita
## recorrer el árbol si la cámara está quieta.
@export var update_move_threshold_m: float = 2.0
## DEBUG (Inspector): colorea cada celda por su nivel de LOD (fino/cerca = cálido,
## grueso/lejos = frío) + wireframe de la grilla → para VERIFICAR a ojo que el LOD
## por cámara se cumple y ver el tamaño real de las celdas. Se aplica EN VIVO.
@export var debug_lod_color: bool = false:
	set(v):
		debug_lod_color = v
		if _ready:
			_refresh_leaf_materials()
## DEBUG: dibujar el borde SÓLO en el límite de cada celda-LOD (una línea por hoja)
## en vez de la grilla interna 16×16 → anillos concéntricos NÍTIDOS (sin el "ruido" de
## la teselación fina). Solo afecta al color de debug. Se aplica EN VIVO.
@export var debug_ring_outline: bool = false:
	set(v):
		debug_ring_outline = v
		if _ready:
			_apply_debug_cell()
## MORPHING de vértices (CDLOD, F5): mata el POPPING de LOD deslizando las celdas
## finas hacia la grilla del padre al acercarse al borde de su rango. Se aplica EN
## VIVO. Default off (opt-in). Ver docs/HOJA_DE_RUTA_MESH_VEGETACION.md §F5.
@export var morph: bool = false:
	set(v):
		morph = v
		if _ready:
			for d in _depth_material.size():
				if _depth_material[d] != null:
					(_depth_material[d] as ShaderMaterial).set_shader_parameter(&"morph_enabled", morph)
			_refresh_leaf_materials()
## Fracción del rango de LOD donde EMPIEZA el morph (0.6 = último 40%).
@export_range(0.3, 0.95, 0.05) var morph_start_frac: float = 0.6

## Cámara a seguir (null = PlayerRegistry.active_camera o la activa del viewport).
var target_camera: Camera3D = null

var _material: Material = null
var _depth_mesh: Array[ArrayMesh] = []   # ArrayMesh compartida por profundidad
var _debug_mat: Array = []               # material de debug por profundidad (color LOD)
var _depth_material: Array = []          # material real por profundidad (params de morph)
var _root: QNode = null
var _ready := false
var _last_cam := Vector3(INF, INF, INF)
var _leaf_count := 0
## F-cull · planos del frustum de la cámara (6 Plane, world) + última orientación,
## para podar el árbol y actualizar al GIRAR (no solo al moverse).
var _frustum: Array = []
var _last_basis := Basis()
## Estadísticas del último recorrido (para el HUD de verificación): hojas por nivel
## de LOD y nodos que el cono descartó. Ver stats().
var _leaf_by_depth := PackedInt32Array()
var _culled_count := 0
## Área (m²) que se podó: podar UN nodo alto tira su subárbol entero, así que el
## número de nodos podados solo no dice cuánto mundo se ahorró.
var _culled_area := 0.0
## Nodos podados por NIVEL del árbol (para ver dónde recorta el cono).
var _culled_by_depth := PackedInt32Array()
## Nodos que el recorrido llegó a visitar (el resto ni se tocó — esa es la gracia).
var _visited_count := 0
## Cajas de nodos descartados (cx, cz, lado) del último recorrido — solo si debug_aabb.
var _culled_boxes: Array[Vector3] = []
var _aabb_mi: MeshInstance3D = null

## Semi-altura de la AABB del nodo para el test de FRUSTUM (m). Debe cubrir el
## relieve real (pico más alto) — NO más. Con ±2000 las celdas son "columnas" de 4 km
## y los planos superior/inferior del cono incluyen celdas de más. 400 ≈ relieve real.
@export var frustum_height_m: float = 400.0

## RENDER SIN NODOS (opt-in): cada hoja visible es una instancia del RenderingServer
## (RID) en vez de un MeshInstance3D. Es lo que hacen los motores de mundo abierto —
## el SceneTree queda para la JUGABILIDAD (player, NPC, vehículos) y el render masivo
## va directo al servidor: no se crean/destruyen Nodos ni se recorren miles por frame.
## Debe fijarse ANTES de que el árbol construya hojas (o llamar clear_leaves()).
@export var use_rendering_server: bool = false

## DEBUG: dibuja las CAJAS (AABB) de los nodos — visibles coloreadas por LOD y, si
## `debug_aabb_culled`, las DESCARTADAS por el cono en gris. Es el visor de
## verificación: se ve qué subdivisiones existen y cuáles el frustum tiró.
@export var debug_aabb: bool = false:
	set(v):
		debug_aabb = v
		if _ready:
			if not debug_aabb and _aabb_mi != null:
				(_aabb_mi.mesh as ImmediateMesh).clear_surfaces()
			_last_cam = Vector3(INF, INF, INF)   # fuerza recorrido → redibuja
@export var debug_aabb_culled: bool = true
## Caja 3D completa (altura real del test, ±frustum_height_m) en vez de la huella.
@export var debug_aabb_full_box: bool = false
## Altura a la que se dibuja la huella (m). Un poco sobre el nivel del mar para que
## no se pelee con el suelo (z-fighting).
@export var debug_aabb_y_m: float = 2.0

## F1b · Fuente de altura por REGIONES (RegionHeightTextures). null = todo global
## (comportamiento actual). Untyped: evita depender del class_name en el cache.
## Cuando está seteado, las hojas FINAS (depth ≥ _tile_depth, o sea size ≤ region_m)
## usan el material del TILE de alta resolución; las gruesas siguen con el global.
var region_tex = null
var _tile_depth := -1
## F6 · Consulta de altura (Callable(Vector2)->float, p. ej. sampler.get_height) para
## medir el δ de rugosidad por nodo. null = rugosidad 0 (split por distancia pura).
var height_query = null
## Filtro de SUPERFICIE (Callable(Vector2)->bool, p. ej. sea_mask.is_sea): una hoja
## cuyo rectángulo NO contiene nada de esa superficie no se dibuja. Para el OCÉANO:
## evita mar bajo la isla y bajo los lagos (dos superficies de agua superpuestas).
## null = dibujar todas las hojas (terreno).
var surface_query = null
## F1b.7 · Hojas que usan el material GLOBAL de fallback esperando su tile (bake
## amortizado). update_for las mejora a tile cuando pump() lo tiene listo.
var _pending: Array = []


## Nodo del quadtree. RefCounted (no Node): la geometría vive en un MeshInstance3D
## hijo del QuadtreeMeshLOD, referenciado por `mi`.
class QNode extends RefCounted:
	var cx: float
	var cz: float
	var size: float
	var depth: int
	var split := false
	var mi: MeshInstance3D = null   # malla de la hoja (o padre oculto si split)
	var rid := RID()                # instancia del RenderingServer (modo sin Nodos)
	var kids: Array = []            # 4 QNode o vacío (untyped: evita auto-referencia)
	var rough := -1.0               # rugosidad cacheada (-1 = sin calcular) — F6
	func _init(x: float, z: float, s: float, d: int) -> void:
		cx = x
		cz = z
		size = s
		depth = d


## Construye las mallas por profundidad y la raíz. `material` = el material REAL
## del terreno (se duplica y se le activa clipmap_displace, como TerrainClipmap).
func setup(material: Material) -> void:
	if material == null:
		push_warning("QuadtreeMeshLOD: sin material — no se puede desplazar.")
		return
	_material = material.duplicate()
	if _material is ShaderMaterial:
		var sm := _material as ShaderMaterial
		if sm.shader != null:
			sm.set_shader_parameter(&"clipmap_displace", true)
	# La celda mínima (m) manda sobre max_depth si está seteada.
	if min_cell_m > 0.0 and area_size_m > 0.0:
		max_depth = clampi(int(ceilf(log(area_size_m / min_cell_m) / log(2.0))), 1, 12)
	_depth_mesh.clear()
	_depth_mesh.resize(max_depth + 1)
	_debug_mat.clear()
	_debug_mat.resize(max_depth + 1)
	_depth_material.clear()
	_depth_material.resize(max_depth + 1)
	var origin := area_center - Vector2(area_size_m, area_size_m) * 0.5   # area_min
	for d in max_depth + 1:
		var s := area_size_m / pow(2.0, d)
		_depth_mesh[d] = _build_grid(s)
		# Material de debug por profundidad (color por LOD + wireframe). Solo si el
		# material base es ShaderMaterial (el shader tiene los uniforms debug_*).
		if _material is ShaderMaterial:
			var dm := (_material as ShaderMaterial).duplicate() as ShaderMaterial
			dm.set_shader_parameter(&"debug_lod", true)
			dm.set_shader_parameter(&"debug_depth", float(d) / float(maxi(max_depth, 1)))
			dm.set_shader_parameter(&"debug_cell_m", s if debug_ring_outline else s / float(grid_n - 1))
			_debug_mat[d] = dm
			# Material REAL por profundidad con params de MORPH (F5). Rango de LOD de
			# la hoja de depth d ≈ [split·s, split·2s]; morph en el tramo final.
			var range_end := split_factor * s * 2.0
			var range_ini := split_factor * s
			var mm := (_material as ShaderMaterial).duplicate() as ShaderMaterial
			mm.set_shader_parameter(&"morph_enabled", morph)
			mm.set_shader_parameter(&"morph_grid_m", s / float(grid_n - 1))
			mm.set_shader_parameter(&"morph_lo", lerpf(range_ini, range_end, morph_start_frac))
			mm.set_shader_parameter(&"morph_hi", range_end)
			mm.set_shader_parameter(&"morph_origin", origin)
			_depth_material[d] = mm
	_root = QNode.new(area_center.x, area_center.y, area_size_m, 0)
	_ready = true
	if OS.is_debug_build():
		print("QuadtreeMeshLOD: área %.0f m · max_depth %d · hoja mín %.1f m"
				% [area_size_m, max_depth, area_size_m / pow(2.0, max_depth)])


func _active_camera() -> Camera3D:
	if target_camera != null:
		return target_camera
	if typeof(PlayerRegistry) != TYPE_NIL and PlayerRegistry != null:
		var c: Camera3D = PlayerRegistry.active_camera()
		if c != null:
			return c
	return get_viewport().get_camera_3d() if get_viewport() != null else null


func _process(_d: float) -> void:
	if not _ready:
		return
	var cam := _active_camera()
	if cam == null:
		return
	var cp := cam.global_position
	# F5: la cámara del morph se actualiza CADA frame (morph suave al moverse).
	if morph:
		for d in _depth_material.size():
			if _depth_material[d] != null:
				(_depth_material[d] as ShaderMaterial).set_shader_parameter(&"morph_cam", cp)
	# F-cull: al podar por frustum hay que actualizar también al GIRAR (el cono cambia).
	var cb := cam.global_transform.basis
	var turned := frustum_cull and not cb.is_equal_approx(_last_basis)
	if frustum_cull:
		_frustum = cam.get_frustum()
	if cp.distance_squared_to(_last_cam) >= update_move_threshold_m * update_move_threshold_m or turned:
		_last_cam = cp
		_last_basis = cb
		update_for(cp)   # ya hace pump+upgrade si async
	elif region_tex != null and region_tex.async_bake:
		# Cámara quieta: igual seguir horneando los tiles encolados.
		region_tex.pump()
		_upgrade_pending()


## Actualiza el árbol para una cámara en `cam` (world). Público para tests
## (sin necesidad de un Camera3D real).
func update_for(cam: Vector3) -> void:
	if not _ready:
		return
	_leaf_count = 0
	_culled_count = 0
	_culled_area = 0.0
	_visited_count = 0
	_culled_boxes.clear()
	if _leaf_by_depth.size() != max_depth + 1:
		_leaf_by_depth.resize(max_depth + 1)
	if _culled_by_depth.size() != max_depth + 1:
		_culled_by_depth.resize(max_depth + 1)
	for i in _leaf_by_depth.size():
		_leaf_by_depth[i] = 0
		_culled_by_depth[i] = 0
	_update(_root, cam.x, cam.z)
	if debug_aabb:
		_draw_aabbs()
	# F1b.7 · bake amortizado: hornear ≤N tiles encolados y mejorar las hojas cuyo
	# tile ya está listo (de global de fallback → tile de alta res).
	if region_tex != null and region_tex.async_bake:
		region_tex.pump()
		_upgrade_pending()


## Propaga un uniform a TODOS los materiales de las hojas. Hace falta porque
## setup() DUPLICA el material por profundidad (para los params de morph): setear
## el parametro en el material original NO llega a las hojas. Lo usa el oceano
## para pasarle los mapas del FFT.
func set_shader_param_all(param: StringName, value: Variant) -> void:
	if _material is ShaderMaterial:
		(_material as ShaderMaterial).set_shader_parameter(param, value)
	for d in _depth_material.size():
		if _depth_material[d] != null:
			(_depth_material[d] as ShaderMaterial).set_shader_parameter(param, value)
	for d in _debug_mat.size():
		if _debug_mat[d] != null:
			(_debug_mat[d] as ShaderMaterial).set_shader_parameter(param, value)


func leaf_count() -> int:
	return _leaf_count


## ¿Un área del mundo (centro XZ + lado en m) está DENTRO del cono de la cámara?
## API pública para que TODO lo que vive en esa parcela (pasto, árboles, rocas,
## props…) se descarte con el MISMO test que el terreno — el patrón "la hoja del
## quadtree es un contenedor espacial": un test descarta todo lo que contiene.
## Devuelve true si el cull por frustum está apagado (nada que filtrar).
func area_in_frustum(center_xz: Vector2, size_m: float) -> bool:
	if not frustum_cull or _frustum.is_empty():
		return true
	return not _box_outside_frustum(center_xz.x, center_xz.y, size_m)


## Colapsa el árbol y suelta TODA la geometría (Nodos y RID). Se usa al cambiar de
## modo de render en vivo: el próximo update_for lo reconstruye con el modo nuevo.
func clear_leaves() -> void:
	if _root == null:
		return
	_free_kids(_root)
	_root.split = false
	if _root.mi != null:
		_root.mi.queue_free()
		_root.mi = null
	if _root.rid.is_valid():
		RenderingServer.free_rid(_root.rid)
		_root.rid = RID()
	_pending.clear()
	_last_cam = Vector3(INF, INF, INF)   # fuerza recorrido en el próximo _process


## Estadísticas del último recorrido, para el HUD de verificación:
##   {leaves, culled, by_lod: [n0, n1, …], cell_m: [lado0, …], tris}
## `by_lod[i]` = hojas del nivel i (0 = la más FINA, pegada al player).
func stats() -> Dictionary:
	var by_lod := PackedInt32Array()
	var culled_lod := PackedInt32Array()
	var cells := PackedFloat32Array()
	# _leaf_by_depth va de raíz (0) a hoja fina (max_depth); el HUD lo quiere al revés
	# (LOD0 = la más fina), igual que la tabla de LOD.
	for d in range(max_depth, -1, -1):
		by_lod.append(_leaf_by_depth[d] if d < _leaf_by_depth.size() else 0)
		culled_lod.append(_culled_by_depth[d] if d < _culled_by_depth.size() else 0)
		cells.append(area_size_m / pow(2.0, d))
	var tris_per_leaf := (grid_n - 1) * (grid_n - 1) * 2
	return {
		leaves = _leaf_count,
		culled = _culled_count,
		culled_area_m2 = _culled_area,
		visited = _visited_count,
		by_lod = by_lod,
		culled_by_lod = culled_lod,
		cell_m = cells,
		tris = _leaf_count * tris_per_leaf,
		tris_per_leaf = tris_per_leaf,
	}


## Dibuja las cajas de los nodos: VISIBLES por color de LOD (cálido = fino/cerca,
## frío = grueso/lejos) y DESCARTADAS por el cono en GRIS. Un solo ImmediateMesh.
func _draw_aabbs() -> void:
	if _aabb_mi == null or not is_instance_valid(_aabb_mi):
		_aabb_mi = MeshInstance3D.new()
		_aabb_mi.name = "DebugAABB"
		_aabb_mi.mesh = ImmediateMesh.new()
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.no_depth_test = true
		_aabb_mi.material_override = m
		_aabb_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_aabb_mi)
	var im := _aabb_mi.mesh as ImmediateMesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	_draw_node_boxes(_root, im)
	for b in _culled_boxes:   # b = (cx, cz, lado)
		_box(im, b.x, b.z, b.y, Color(0.45, 0.45, 0.45, 1.0))
	im.surface_end()


func _draw_node_boxes(node: QNode, im: ImmediateMesh) -> void:
	if node.split:
		for k: QNode in node.kids:
			_draw_node_boxes(k, im)
		return
	if node.mi == null and not node.rid.is_valid():
		return   # hoja oculta (culleada o filtrada): la dibuja el pase gris
	var t := float(node.depth) / float(maxi(max_depth, 1))
	_box(im, node.cx, node.size, node.cz,
			Color(0.10, 0.35, 0.95).lerp(Color(0.98, 0.30, 0.08), t))


## Contorno de un nodo. Por defecto la HUELLA (el cuadrado del quadtree sobre el
## terreno, que es lo que se subdivide y lo que muestran los diagramas); con
## `debug_aabb_full_box`, la caja 3D completa con la altura REAL del test de cono
## (±frustum_height_m ⇒ columnas altas: sirve para auditar el test, no para mirar).
func _box(im: ImmediateMesh, cx: float, size: float, cz: float, col: Color) -> void:
	var h := size * 0.5
	var y0 := (-frustum_height_m if debug_aabb_full_box else debug_aabb_y_m)
	var c := [Vector3(cx - h, y0, cz - h), Vector3(cx + h, y0, cz - h),
			Vector3(cx + h, y0, cz + h), Vector3(cx - h, y0, cz + h)]
	var edges := [[0, 1], [1, 2], [2, 3], [3, 0]]
	if debug_aabb_full_box:
		var y1 := frustum_height_m
		c.append_array([Vector3(cx - h, y1, cz - h), Vector3(cx + h, y1, cz - h),
				Vector3(cx + h, y1, cz + h), Vector3(cx - h, y1, cz + h)])
		edges.append_array([[4, 5], [5, 6], [6, 7], [7, 4],
				[0, 4], [1, 5], [2, 6], [3, 7]])
	for e in edges:
		im.surface_set_color(col)
		im.surface_add_vertex(c[e[0]])
		im.surface_set_color(col)
		im.surface_add_vertex(c[e[1]])


## Instancias RID vivas (modo sin Nodos) — para tests/diagnóstico.
func rid_count() -> int:
	return _count_rids(_root)


func _count_rids(node: QNode) -> int:
	if node == null:
		return 0
	var n := 1 if node.rid.is_valid() else 0
	for k: QNode in node.kids:
		n += _count_rids(k)
	return n


## Libera TODAS las instancias del RenderingServer del árbol (los RID no los limpia
## el SceneTree: hay que soltarlos a mano o quedan colgados en el servidor).
func _free_all_rids(node: QNode) -> void:
	if node == null:
		return
	if node.rid.is_valid():
		RenderingServer.free_rid(node.rid)
		node.rid = RID()
	for k: QNode in node.kids:
		_free_all_rids(k)


func _exit_tree() -> void:
	_free_all_rids(_root)


## Hojas activas como {cx,cz,size,depth} (para banco/test).
func debug_leaves() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	_collect_leaves(_root, out)
	return out


func _collect_leaves(node: QNode, out: Array[Dictionary]) -> void:
	if node == null:
		return
	if node.split:
		for k: QNode in node.kids:
			_collect_leaves(k, out)
	else:
		out.append({cx = node.cx, cz = node.cz, size = node.size, depth = node.depth})


func _update(node: QNode, camx: float, camz: float) -> void:
	_visited_count += 1
	# F-cull · si el nodo está FUERA del cono, colapsar su subárbol y NO mostrarlo
	# (no se construye lo de atrás/costados = "NOT VISIBLE TO CAMERA"). Al girar, el
	# _process re-actualiza y el borde entrante se reconstruye (frustum_margin_m da colchón).
	if frustum_cull and not _frustum.is_empty() and _node_outside_frustum(node):
		if node.split:
			_free_kids(node)
			node.split = false
		_hide_leaf(node)
		_culled_count += 1
		_culled_area += node.size * node.size
		if node.depth < _culled_by_depth.size():
			_culled_by_depth[node.depth] += 1
		if debug_aabb and debug_aabb_culled:
			_culled_boxes.append(Vector3(node.cx, node.cz, node.size))
		return
	var dist := _dist_to_node(node, camx, camz)
	# Histéresis por DOBLE umbral: un nodo suelto se subdivide al cruzar el umbral
	# bajo (split_factor·lado); uno YA subdividido se mantiene hasta cruzar el
	# umbral alto (×merge_hysteresis). En la banda entre ambos NO cambia de estado
	# ⇒ sin parpadeo split/merge.
	var can_split := node.depth < max_depth
	# F6 · SPLIT POR RUGOSIDAD: un nodo RUGOSO (crestas) subdivide a MÁS distancia
	# (factor efectivo mayor) → detalle donde hace falta; uno PLANO subdivide sólo
	# cerca → menos triángulos en llano. rough∈[0,1] del δ de altura del nodo.
	var eff := split_factor * (1.0 + rough_gain * _node_rough(node))
	var want: bool
	if node.split:
		want = can_split and dist < eff * merge_hysteresis * node.size
	else:
		want = can_split and dist < eff * node.size
	# SPLIT POR BORDE DE CONO: un nodo grande que solo ROZA el cono se dibujaba
	# entero y sobresalía (lo que se veía como "océano detrás del cono"). Si cruza
	# el borde y todavía es grande, se parte: los cuartos de afuera se descartan en
	# la recursión y el borde queda pegado al cono. Acotado por tamaño para no
	# explotar el nº de nodos (partir hasta el infinito en el borde es carísimo).
	if not want and can_split and frustum_cull and frustum_split_min_m > 0.0 \
			and node.size > frustum_split_min_m and not _frustum.is_empty() \
			and _box_straddles_frustum(node.cx, node.cz, node.size):
		want = true
	if want:
		if not node.split:
			_hide_leaf(node)
			_make_kids(node)
			node.split = true
		for k: QNode in node.kids:
			_update(k, camx, camz)
	else:
		if node.split:
			_free_kids(node)
			node.split = false
		# Filtro de superficie: se aplica a la HOJA (ya en su tamaño final), no a los
		# nodos internos — así un nodo grande igual subdivide y la decisión se toma a
		# la resolución que se dibuja (no se pierde una franja de costa).
		# Un Callable VACÍO cuenta como "sin filtro" (además del null histórico):
		# es lo que devuelve `Callable()` y evita el ternario incompatible en el
		# llamador.
		if _has_surface_query() and not _leaf_has_surface(node):
			_hide_leaf(node)
			return
		_show_leaf(node)
		_leaf_count += 1
		if node.depth < _leaf_by_depth.size():
			_leaf_by_depth[node.depth] += 1


## ¿Hay filtro de superficie activo? Acepta null (histórico) y Callable vacío.
func _has_surface_query() -> bool:
	if surface_query == null:
		return false
	if surface_query is Callable:
		return not (surface_query as Callable).is_null()
	return true


## ¿Algún punto del rectángulo de la hoja pertenece a la superficie? Muestreo 3×3 +
## centro: barato y suficiente a la resolución de la hoja.
func _leaf_has_surface(node: QNode) -> bool:
	var q := node.size * 0.5
	for ix in 3:
		for iz in 3:
			var px := node.cx - q + node.size * (float(ix) * 0.5)
			var pz := node.cz - q + node.size * (float(iz) * 0.5)
			if bool(surface_query.call(Vector2(px, pz))):
				return true
	return false


## Distancia horizontal de la cámara al rectángulo del nodo (0 si está dentro).
## Usar el rect, no el centro: con el centro, la cámara dentro de un nodo grande
## contaría como "lejos" y no subdividiría.
func _dist_to_node(node: QNode, camx: float, camz: float) -> float:
	var half := node.size * 0.5
	var dx := maxf(absf(camx - node.cx) - half, 0.0)
	var dz := maxf(absf(camz - node.cz) - half, 0.0)
	# Chebyshev (max) = anillos CUADRADOS concéntricos alrededor del player (norma L1/∞
	# del LOD clásico de terreno: "radial cuadrado"). Euclidiana (sqrt) daría círculos.
	return maxf(dx, dz)


## ¿La AABB del nodo está ENTERAMENTE fuera del frustum? Convención Godot (medida
## por el test): get_frustum() da planos con normal hacia AFUERA → un punto está
## dentro si distance_to ≤ 0 en TODOS. La AABB está fuera si, para ALGÚN plano, su
## vértice MÁS CERCANO al lado interior (n-vertex, el que MINIMIZA la distancia)
## sigue del lado + (fuera) más allá del margen. Test AABB-plano estándar.
func _node_outside_frustum(node: QNode) -> bool:
	return _box_outside_frustum(node.cx, node.cz, node.size)


## Igual pero con escalares: lo usan tanto el árbol como los sistemas que preguntan
## por una parcela (pasto/props) — SIN asignar objetos (se llama por celda y frame).
func _box_outside_frustum(cx: float, cz: float, size: float) -> bool:
	var half := size * 0.5
	var mn := Vector3(cx - half, -frustum_height_m, cz - half)
	var mx := Vector3(cx + half, frustum_height_m, cz + half)
	for pv_any in _frustum:
		var pl := pv_any as Plane
		var nv := Vector3(
				mn.x if pl.normal.x >= 0.0 else mx.x,
				mn.y if pl.normal.y >= 0.0 else mx.y,
				mn.z if pl.normal.z >= 0.0 else mx.z)
		if pl.distance_to(nv) > frustum_margin_m:
			return true   # toda la AABB del lado exterior de este plano → fuera
	return false


## ¿El nodo CRUZA el borde del cono (ni entero adentro ni entero afuera)? Se usa
## para SUBDIVIDIR ahí: una hoja grande que solo roza el cono se dibuja entera y
## "sobresale"; partiéndola, los pedazos de afuera se descartan y el borde queda
## pegado al cono. Test estándar: la caja cruza un plano si su vértice n (el más
## interior) está adentro pero el p (el más exterior) está afuera.
func _box_straddles_frustum(cx: float, cz: float, size: float) -> bool:
	var half := size * 0.5
	var mn := Vector3(cx - half, -frustum_height_m, cz - half)
	var mx := Vector3(cx + half, frustum_height_m, cz + half)
	for pv_any in _frustum:
		var pl := pv_any as Plane
		# IGNORAR los planos casi horizontales (techo/piso del cono): nuestras cajas
		# miden ±frustum_height_m de alto, así que SIEMPRE los cruzan → sin este
		# filtro "roza el borde" daba true en todos lados y subdividía el mapa entero
		# (medido: 42 → 269 hojas). Solo interesan los planos LATERALES y near/far.
		if absf(pl.normal.y) > 0.7:
			continue
		# vértice p = el que MAXIMIZA la distancia (el más "afuera" de este plano)
		var pv := Vector3(
				mx.x if pl.normal.x >= 0.0 else mn.x,
				mx.y if pl.normal.y >= 0.0 else mn.y,
				mx.z if pl.normal.z >= 0.0 else mn.z)
		if pl.distance_to(pv) > 0.0:
			return true   # algo del nodo asoma fuera de este plano
	return false


## F6 · Rugosidad del nodo (δ de altura normalizado, cacheada por nodo). 9 muestras
## del heightfield (esquinas + medios + centro). 0 = plano, 1 = muy accidentado.
func _node_rough(node: QNode) -> float:
	if node.rough >= 0.0:
		return node.rough
	if height_query == null:
		node.rough = 0.0
		return 0.0
	var h := node.size * 0.5
	var lo := INF
	var hi := -INF
	for dz: float in [-h, 0.0, h]:
		for dx: float in [-h, 0.0, h]:
			var hv: float = height_query.call(Vector2(node.cx + dx, node.cz + dz))
			lo = minf(lo, hv)
			hi = maxf(hi, hv)
	node.rough = clampf((hi - lo) / maxf(node.size * 0.35, 1.0), 0.0, 1.0)
	return node.rough


func _make_kids(node: QNode) -> void:
	var q := node.size * 0.25
	var s := node.size * 0.5
	var d := node.depth + 1
	node.kids = [
		QNode.new(node.cx - q, node.cz - q, s, d),
		QNode.new(node.cx + q, node.cz - q, s, d),
		QNode.new(node.cx - q, node.cz + q, s, d),
		QNode.new(node.cx + q, node.cz + q, s, d),
	]


func _free_kids(node: QNode) -> void:
	for k: QNode in node.kids:
		if k.split:
			_free_kids(k)
			k.split = false
		if k.mi != null:
			k.mi.queue_free()
			k.mi = null
		if k.rid.is_valid():
			RenderingServer.free_rid(k.rid)
			k.rid = RID()
	node.kids = []


## Hoja visible: crea (o reusa) su instancia. Con `use_rendering_server` la hoja NO
## es un Node3D — es una instancia del RenderingServer (RID), como hacen los motores
## de mundo abierto: el SceneTree queda para la jugabilidad y el render masivo va
## directo al servidor (sin recorrer/actualizar miles de nodos por frame).
func _show_leaf(node: QNode) -> void:
	if use_rendering_server:
		_show_leaf_rid(node)
		return
	if node.mi == null:
		var mi := MeshInstance3D.new()
		mi.mesh = _depth_mesh[node.depth]
		mi.material_override = _leaf_material(node)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(node.cx, 0.0, node.cz)
		add_child(mi)
		node.mi = mi
	else:
		node.mi.visible = true


func _show_leaf_rid(node: QNode) -> void:
	var w := get_world_3d()
	if w == null:
		return
	if not node.rid.is_valid():
		node.rid = RenderingServer.instance_create2(
				_depth_mesh[node.depth].get_rid(), w.scenario)
		RenderingServer.instance_set_transform(node.rid,
				Transform3D(Basis(), Vector3(node.cx, 0.0, node.cz)))
		RenderingServer.instance_geometry_set_cast_shadows_setting(node.rid,
				RenderingServer.SHADOW_CASTING_SETTING_OFF)
		var mat := _leaf_material(node)
		if mat != null:
			RenderingServer.instance_geometry_set_material_override(node.rid, mat.get_rid())
	else:
		RenderingServer.instance_set_visible(node.rid, true)


## Material de la hoja: si hay region_tex y la hoja es FINA (size ≤ region_m ⇒
## depth ≥ _tile_depth) usa el TILE de alta resolución de su región; si no, el
## material GLOBAL (baja resolución, lejos/grueso). Ver PLAN_F1B §2.4.
func _leaf_material(node: QNode) -> Material:
	# DEBUG: colorea por LOD, sobre TODO lo demás (para ver la estructura de celdas).
	if debug_lod_color and node.depth < _debug_mat.size() and _debug_mat[node.depth] != null:
		return _debug_mat[node.depth]
	if region_tex == null:
		return _global_mat(node.depth)
	if _tile_depth < 0:
		var ratio: float = area_size_m / region_tex.sampler.region_m
		_tile_depth = clampi(int(ceilf(log(maxf(ratio, 1.0)) / log(2.0))), 0, max_depth)
	if node.depth >= _tile_depth:
		var key: Vector2i = region_tex.region_of(Vector2(node.cx, node.cz))
		var m: Variant = region_tex.material_for(key)
		if m == null:
			# async: el tile aún no está horneado → global de fallback + a la cola.
			if not _pending.has(node):
				_pending.append(node)
			return _global_mat(node.depth)
		return m
	return _global_mat(node.depth)


## Material del path GLOBAL para una hoja de profundidad d: el material por
## profundidad (con params de morph) si está construido, si no el base.
func _global_mat(depth: int) -> Material:
	if depth < _depth_material.size() and _depth_material[depth] != null:
		return _depth_material[depth]
	return _material


## F1b.7 · Mejora las hojas pendientes a su material de tile cuando ya está listo.
func _upgrade_pending() -> void:
	if _pending.is_empty():
		return
	var still: Array = []
	for node: QNode in _pending:
		if node.mi == null or not is_instance_valid(node.mi):
			continue   # hoja liberada → descartar
		var key: Vector2i = region_tex.region_of(Vector2(node.cx, node.cz))
		if region_tex.ready(key):
			node.mi.material_override = region_tex.material_for(key)
		else:
			still.append(node)
	_pending = still


## Reaplica el material a todas las hojas vivas (para el toggle de debug en vivo).
func _refresh_leaf_materials() -> void:
	if _root != null:
		_refresh(_root)


## Rehace las mallas por profundidad con la RESOLUCIÓN de patch actual (`grid_n`) y
## se las pasa a las hojas vivas. No toca el ÁRBOL (mismas celdas, mismas distancias)
## → cambiar la calidad no reconstruye el mundo, solo la densidad de vértices.
func _rebuild_meshes() -> void:
	for d in _depth_mesh.size():
		var s := area_size_m / pow(2.0, d)
		_depth_mesh[d] = _build_grid(s)
		# El paso de grilla cambió: morph y wireframe de debug deben seguirlo.
		if d < _depth_material.size() and _depth_material[d] != null:
			(_depth_material[d] as ShaderMaterial).set_shader_parameter(
					&"morph_grid_m", s / float(grid_n - 1))
	_apply_debug_cell()
	if _root != null:
		_reassign_mesh(_root)


func _reassign_mesh(node: QNode) -> void:
	if node.depth < _depth_mesh.size():
		if node.mi != null and is_instance_valid(node.mi):
			node.mi.mesh = _depth_mesh[node.depth]
		if node.rid.is_valid():
			RenderingServer.instance_set_base(node.rid, _depth_mesh[node.depth].get_rid())
	for k: QNode in node.kids:
		_reassign_mesh(k)


## Distancias REALES de cada nivel de LOD (m): [{depth, cell_m, spacing_m, from_m,
## to_m}], de la hoja más fina a la más gruesa. Para el menú/HUD y para verificar
## la tabla de calidad sin adivinar. La hoja de lado S se dibuja entre
## split_factor·S y split_factor·2S (por eso cada banda DOBLA a la anterior).
func lod_table() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in range(max_depth, -1, -1):
		var s := area_size_m / pow(2.0, d)
		out.append({
			depth = d,
			cell_m = s,
			spacing_m = s / float(maxi(grid_n - 1, 1)),
			from_m = (0.0 if d == max_depth else split_factor * s),
			to_m = split_factor * s * 2.0,
		})
	return out


## Ajusta el paso del wireframe de debug: borde por celda-LOD (outline nítido) o
## grilla interna 16×16. Ver debug_ring_outline.
func _apply_debug_cell() -> void:
	for d in _debug_mat.size():
		if _debug_mat[d] != null:
			var s := area_size_m / pow(2.0, d)
			var cm := s if debug_ring_outline else s / float(grid_n - 1)
			(_debug_mat[d] as ShaderMaterial).set_shader_parameter(&"debug_cell_m", cm)


func _refresh(node: QNode) -> void:
	if node.split:
		for k in node.kids:
			_refresh(k)
	elif node.mi != null and is_instance_valid(node.mi):
		node.mi.material_override = _leaf_material(node)
	elif node.rid.is_valid():
		var m := _leaf_material(node)
		if m != null:
			RenderingServer.instance_geometry_set_material_override(node.rid, m.get_rid())


## Profundidad a partir de la cual las hojas usan tile (para tests/diagnóstico).
func tile_depth() -> int:
	if region_tex != null and _tile_depth < 0:
		var ratio: float = area_size_m / region_tex.sampler.region_m
		_tile_depth = clampi(int(ceilf(log(maxf(ratio, 1.0)) / log(2.0))), 0, max_depth)
	return _tile_depth


## Nodo subdividido: su propia malla se oculta (se reusa si vuelve a fusionar).
func _hide_leaf(node: QNode) -> void:
	if node.mi != null:
		node.mi.visible = false
	if node.rid.is_valid():
		RenderingServer.instance_set_visible(node.rid, false)


## Grilla plana GRID_N² de lado `size` centrada en el origen local, con faldones
## en los 4 bordes. Winding antihorario (visible desde +Y). La altura la pone el
## shader; aquí y=0 (bordes de faldón y=-skirt).
func _build_grid(size: float) -> ArrayMesh:
	var side := grid_n
	var step := size / float(side - 1)
	var half := size * 0.5
	var verts := PackedVector3Array()
	verts.resize(side * side)
	for z in side:
		for x in side:
			verts[z * side + x] = Vector3(float(x) * step - half, 0.0, float(z) * step - half)
	var idx := PackedInt32Array()
	for z in side - 1:
		for x in side - 1:
			var i0 := z * side + x
			idx.append(i0); idx.append(i0 + 1); idx.append(i0 + side)
			idx.append(i0 + 1); idx.append(i0 + side + 1); idx.append(i0 + side)
	# Faldones perimetrales (mismo winding que terrain_clipmap._build_level).
	var sk := PackedInt32Array()
	for x in side - 1:
		sk.append_array([x, x + 1])                                    # norte (z=0)
		sk.append_array([(side - 1) * side + x + 1, (side - 1) * side + x])  # sur
	for z in side - 1:
		sk.append_array([(z + 1) * side, z * side])                    # oeste (x=0)
		sk.append_array([z * side + side - 1, (z + 1) * side + side - 1])    # este
	var base := verts.size()
	for p in range(0, sk.size(), 2):
		var a := sk[p]
		var b := sk[p + 1]
		var av := verts[a]
		var bv := verts[b]
		verts.append(Vector3(av.x, -skirt_m, av.z))
		verts.append(Vector3(bv.x, -skirt_m, bv.z))
		var a2 := base + p
		idx.append(a); idx.append(b); idx.append(a2)
		idx.append(b); idx.append(a2 + 1); idx.append(a2)
	# Normales/tangentes constantes: en modo clipmap el shader calcula la normal
	# desde el normalmap global; sin ARRAY_TANGENT el shader de terreno avisa.
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	var tangents := PackedFloat32Array()
	tangents.resize(verts.size() * 4)
	for ti in verts.size():
		normals[ti] = Vector3.UP
		tangents[ti * 4] = 1.0
		tangents[ti * 4 + 3] = 1.0
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# AABB alto en Y: el shader pone la altura; sin esto el culling recorta.
	mesh.custom_aabb = AABB(Vector3(-half, -1000.0, -half), Vector3(size, 2000.0, size))
	return mesh
