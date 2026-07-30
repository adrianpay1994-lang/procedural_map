class_name TerrainClipmap
extends Node3D

## ============================================================================
## TerrainClipmap · Terreno lejano de presupuesto FIJO que sigue a la cámara
## ============================================================================
## Extraído del banco `clipmap_proto` a un nodo REUSABLE para el mapa jugable
## (RENDIMIENTO_ESTADO §6.7/§6.8, 16KM-2/3/6). Grilla plana por ANILLOS
## concéntricos (nivel 0 denso + LEVELS-1 anillos ×2 paso); la altura sale del
## heightfield en el VERTEX shader (`clipmap_displace`), reusando el material
## REAL del terreno (splat + biomas + normalmap global). Cobertura 16.4 km con
## ~34,5k verts FIJOS. Los faldones tapan los T-junctions entre niveles.
##
## Uso (lo cablea ProceduralMapSystem, opt-in por graphics/terrain_clipmap):
##   var cm := TerrainClipmap.new()
##   cm.terrain_root = <nodo "Terrain">    # chunks reales (ocultar/mostrar)
##   cm.setup(map.terrain_material)        # duplica + activa clipmap_displace
##   map.add_child(cm)
## Sigue la cámara ACTIVA del viewport (o `target_camera` si se fija).
## ============================================================================

const GRID_N := 65           # vértices por lado de cada nivel
const STEP := 4.0            # paso del nivel 0 (m)
const LEVELS := 7            # 7 ⇒ 256·2^6 = 16 384 m de cobertura
const SKIRT := 12.0          # caída del faldón en fronteras de nivel (m)
const HORIZON_LEVELS := 2
const HORIZON_DIST := 1900.0
const HORIZON_TILE := 512
## Capa de render EXCLUSIVA del clipmap (bit 20). La cámara del horneado del
## horizonte usa solo esta capa → NO captura pasto/árboles/chunks cercanos (que
## se colaban y salían como "pasto gigante parado" en el anillo). Los niveles van
## en su capa normal (1) + esta, así la cámara del jugador los sigue viendo.
const HORIZON_CULL_BIT := 1 << 19

## Cámara que sigue el clipmap (null = la activa del viewport). El espectador/
## debug puede fijarla; en juego se usa la del jugador automáticamente.
var target_camera: Camera3D = null
## Chunks reales del terreno (para ocultarlos durante el horneado del horizonte).
var terrain_root: Node3D = null

var _levels: Array[MeshInstance3D] = []
var _total_verts := 0
var _horizon_root: Node3D = null
var _horizon_on := false
var _ready := false
## Niveles activos (radio por calidad). LEVELS = todos (16 km). Lo fija
## ProceduralMapSystem según world_quality.
var _active_levels := LEVELS


## Construye los niveles con el material REAL del terreno (duplicado + clipmap).
func setup(terrain_material: ShaderMaterial) -> void:
	if terrain_material == null:
		push_warning("TerrainClipmap: sin terrain_material — no se puede desplazar.")
		return
	var mat := terrain_material.duplicate() as ShaderMaterial
	mat.set_shader_parameter(&"clipmap_displace", true)
	_total_verts = 0
	for lv in LEVELS:
		var mi := MeshInstance3D.new()
		mi.name = "L%d" % lv
		mi.mesh = _build_level(STEP * pow(2.0, lv), lv > 0)
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # lejano: sin sombra
		mi.layers = mi.layers | HORIZON_CULL_BIT   # capa 1 (jugador) + capa de horneado
		add_child(mi)
		_levels.append(mi)
		_total_verts += _count_verts(mi.mesh as ArrayMesh)
	_ready = true
	var coverage := float(GRID_N - 1) * STEP * pow(2.0, LEVELS - 1)
	if OS.is_debug_build():
		print("TerrainClipmap: %d niveles · %d verts FIJOS · cobertura %.0f m (%.1f km)"
				% [LEVELS, _total_verts, coverage, coverage / 1000.0])


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
	# Cada NIVEL sigue a la cámara con snap a 2× su paso (clipmap clásico) +
	# sesgo de altura 4 cm/nivel: el nivel FINO gana el z-fight del solape.
	for lv in _levels.size():
		var s := STEP * pow(2.0, lv) * 2.0
		_levels[lv].global_position = Vector3(floorf(cp.x / s) * s,
				0.04 * float(LEVELS - lv), floorf(cp.z / s) * s)
	if _horizon_on and _horizon_root != null:
		_horizon_root.global_position = Vector3(cp.x, 0.0, cp.z)


## Grilla (GRID_N²) de paso `step`, con agujero central si `hole` (lo cubre el
## nivel interior) + FALDONES en bordes (tapan T-junctions). Winding antihorario.
func _build_level(step: float, hole: bool) -> ArrayMesh:
	var side := GRID_N
	var half := float(side - 1) * step * 0.5
	# Agujero encogido 2 celdas/lado: los snaps de niveles consecutivos se
	# desalinean hasta ~1 celda gruesa → el solape evita RENDIJAS.
	var quarter := (side - 1) >> 2   # /4 en enteros (bit-shift = sin warning ni ignore)
	var hole_lo := quarter + 2
	var hole_hi := quarter * 3 - 2
	var verts := PackedVector3Array()
	verts.resize(side * side)
	for z in side:
		for x in side:
			verts[z * side + x] = Vector3(float(x) * step - half, 0.0, float(z) * step - half)
	var idx := PackedInt32Array()
	for z in side - 1:
		for x in side - 1:
			if hole and x >= hole_lo and x < hole_hi and z >= hole_lo and z < hole_hi:
				continue
			var i0 := z * side + x
			idx.append(i0); idx.append(i0 + 1); idx.append(i0 + side)
			idx.append(i0 + 1); idx.append(i0 + side + 1); idx.append(i0 + side)
	# Faldones: vértices de borde duplicados y bajados SKIRT (el shader suma la
	# altura al Y LOCAL → cuelgan por debajo del suelo y tapan el gap).
	var sk := PackedInt32Array()
	for x in side - 1:
		sk.append_array([x, x + 1])
		sk.append_array([(side - 1) * side + x + 1, (side - 1) * side + x])
	for z in side - 1:
		sk.append_array([(z + 1) * side, z * side])
		sk.append_array([z * side + side - 1, (z + 1) * side + side - 1])
	if hole:
		for x in range(hole_lo, hole_hi):
			sk.append_array([hole_lo * side + x + 1, hole_lo * side + x])
			sk.append_array([hole_hi * side + x, hole_hi * side + x + 1])
		for z in range(hole_lo, hole_hi):
			sk.append_array([z * side + hole_lo, (z + 1) * side + hole_lo])
			sk.append_array([(z + 1) * side + hole_hi, z * side + hole_hi])
	var base := verts.size()
	for p in range(0, sk.size(), 2):
		var a := sk[p]
		var bidx := sk[p + 1]
		var av := verts[a]
		var bv := verts[bidx]
		verts.append(Vector3(av.x, -SKIRT, av.z))
		verts.append(Vector3(bv.x, -SKIRT, bv.z))
		var a2 := base + p   # p es par (range paso 2) → (p/2)*2 == p
		idx.append(a); idx.append(bidx); idx.append(a2)
		idx.append(bidx); idx.append(a2 + 1); idx.append(a2)
	# Tangentes constantes: el shader de terreno usa NORMAL_MAP (detalle) y exige
	# ARRAY_TANGENT; la grilla plana no las trae (el shader calcula la normal desde
	# el normalmap global en modo clipmap). Sin esto: warning "requires tangents".
	var tangents := PackedFloat32Array()
	tangents.resize(verts.size() * 4)
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	for ti in verts.size():
		tangents[ti * 4] = 1.0        # tangente +X
		tangents[ti * 4 + 3] = 1.0    # binormal handedness
		normals[ti] = Vector3.UP      # el shader la reemplaza en modo clipmap
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = AABB(Vector3(-half, -500, -half), Vector3(half * 2, 1000, half * 2))
	return mesh


func _count_verts(m: ArrayMesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		n += (m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return n


# === 16KM-6 · Horizonte horneado (imagen a lo lejos, costo ≈ 0) ==============

## Enciende/apaga el anillo de horizonte horneado. Al encender la 1ª vez hornea.
## GUARD: solo tiene sentido si el RADIO del clipmap (active_levels) llega a los
## niveles que se hornean; con radio chico (potato/bajo/medio) esos niveles están
## culleados → el anillo mostraría "2 imágenes flotando" de terreno que no existe
## (bug reportado). En ese caso se apaga.
func set_horizon(on: bool) -> void:
	if on and _active_levels <= LEVELS - HORIZON_LEVELS:
		on = false   # radio insuficiente: sin horizonte (la niebla cubre lo lejos)
	_horizon_on = on
	if on and _horizon_root == null and _ready:
		await _bake_horizon()
	else:
		_apply_horizon()


## Radio de dibujado del clipmap por CALIDAD (docs/LOD_PLANTILLA): en Bajo solo
## los niveles cercanos (terreno lejano apagado → niebla/horizonte); en Ultra
## todos (16 km). Los niveles son discretos (semi-extensión 128·2^lv m):
## L0-2≈512 m · L0-3≈1024 · L0-4≈2048 · L0-6≈8192. n = cuántos niveles activos.
func set_active_levels(n: int) -> void:
	_active_levels = clampi(n, 2, LEVELS)
	_refresh_visibility()


func _apply_horizon() -> void:
	_refresh_visibility()
	if _horizon_root != null:
		_horizon_root.visible = _horizon_on


## Visibilidad de cada nivel = dentro del radio (active_levels) Y no apagado por
## el horizonte horneado (que reemplaza los últimos niveles por la imagen).
func _refresh_visibility() -> void:
	for lv in _levels.size():
		var within := lv < _active_levels
		var not_baked := (not _horizon_on) or lv < LEVELS - HORIZON_LEVELS
		_levels[lv].visible = within and not_baked


func _bake_horizon() -> void:
	var cam := _active_camera()
	if cam == null:
		return
	if _horizon_root != null:
		_horizon_root.queue_free()
	_horizon_root = Node3D.new()
	_horizon_root.name = "HorizonRing"
	add_child(_horizon_root)
	# Mostrar SOLO los niveles lejanos (lo que se hornea); ocultar chunks reales.
	var was_terr: bool = terrain_root.visible if terrain_root != null else false
	if terrain_root != null:
		terrain_root.visible = false
	for lv in _levels.size():
		_levels[lv].visible = lv >= LEVELS - HORIZON_LEVELS
	var vp := SubViewport.new()
	vp.size = Vector2i(HORIZON_TILE, HORIZON_TILE)
	vp.transparent_bg = true
	vp.own_world_3d = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var bcam := Camera3D.new()
	bcam.fov = 45.0
	bcam.far = 30000.0
	bcam.cull_mask = HORIZON_CULL_BIT   # SOLO el clipmap: nada de pasto/árboles/chunks cercanos
	vp.add_child(bcam)
	var origin := cam.global_position
	for i in 8:
		var yaw := TAU * float(i) / 8.0
		bcam.global_position = origin
		bcam.basis = Basis(Vector3.UP, yaw)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		if img == null:
			continue
		var tex := ImageTexture.create_from_image(img)
		var dir := Basis(Vector3.UP, yaw) * Vector3(0, 0, -1)
		var w := 2.0 * HORIZON_DIST * tan(deg_to_rad(22.5)) * 1.03
		var qm := QuadMesh.new()
		qm.size = Vector2(w, w)
		var qmat := StandardMaterial3D.new()
		qmat.albedo_texture = tex
		qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		qmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		qmat.alpha_scissor_threshold = 0.2
		qmat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var mi := MeshInstance3D.new()
		mi.mesh = qm
		mi.material_override = qmat
		mi.position = Vector3(origin.x, origin.y, origin.z) + dir * HORIZON_DIST
		mi.basis = Basis(Vector3.UP, yaw)
		mi.extra_cull_margin = 200.0
		_horizon_root.add_child(mi)
	vp.queue_free()
	if terrain_root != null:
		terrain_root.visible = was_terr
	_apply_horizon()
