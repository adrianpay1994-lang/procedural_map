extends Node3D

## ============================================================================
## clipmap_proto · PROTOTIPO 16KM-1 (§F8.2): terreno por vertex-shader
## ============================================================================
## Prueba la técnica madre de los 16 km SIN tocar el sistema actual:
##  1. Genera el mini-mundo (seed fija) y exporta su heightfield a textura RF.
##  2. Crea UNA grilla plana de presupuesto FIJO (257² ≈ 66k verts, paso 4 m)
##     que SIGUE a la cámara con snap por texel — cubre 1 km² alrededor tuyo;
##     con anillos LOD (fase 2) cubriría 16 km con el MISMO presupuesto.
##  3. Tecla T alterna terreno REAL ↔ CLIPMAP con la misma cámara: comparar
##     siluetas. Modo "shot": guarda ambas capturas y sale (verificación).
##   godot --path . res://systems/procedural_map/test/clipmap_proto.tscn
##   (arg "shot" = automático: _clipmap_real.png + _clipmap_proto.png)
## ============================================================================

const SEED := 4242
## 16KM-2: clipmap por ANILLOS — nivel 0 denso + LEVELS-1 anillos huecos, cada
## uno con paso ×2. Cobertura total = (GRID_N-1)·STEP·2^(LEVELS-1) m con
## presupuesto FIJO (~4k verts nivel + ~3k por anillo). Con 65²/4 m/7 niveles:
## 256 m → 16.4 KM y ~25k verts. Faldones tapan los T-junctions entre niveles.
const GRID_N := 65           # vértices por lado de cada nivel
const STEP := 4.0            # paso del nivel 0 (m)
const LEVELS := 7            # 7 ⇒ 256·2^6 = 16 384 m de cobertura
const SKIRT := 12.0          # caída del faldón en fronteras de nivel (m)
## 16KM-6 · HORIZONTE COMO IMAGEN (pedido del usuario, técnica GoT/Horizon):
## más allá de HORIZON_DIST los últimos HORIZON_LEVELS niveles del clipmap se
## APAGAN y los reemplaza un anillo de 8 quads con la vista HORNEADA (una
## pasada de 8 renders de 45°) — costo de render ≈ 0 para lo lejísimo.
## Toggle: Opciones → graphics/horizon_bake (o tecla H en el banco).
const HORIZON_LEVELS := 2
const HORIZON_DIST := 1900.0
const HORIZON_TILE := 512    # px por vista horneada

var _map: ProceduralMapSystem
var _cam: Camera3D
var _clip: Node3D                       # raíz de los niveles del clipmap
var _levels: Array[MeshInstance3D] = []
var _total_verts := 0
var _terrain_root: Node3D
var _horizon_root: Node3D = null        # anillo de quads horneados (16KM-6)
var _horizon_on := false
var _fps: Label
var _yaw := 0.0        # mirando a -Z: directo a la isla desde la costa sur
var _pitch := -0.22
var _shot := false
var _frame := 0
var _stage := 0
var _ready_world := false


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_shot = OS.get_cmdline_user_args().has("shot")
	# El toggle real es la OPCIÓN graphics/terrain_clipmap (menú de pausa);
	# el banco reacciona en vivo al cambio (T solo escribe la opción).
	if typeof(GameEvents) != TYPE_NIL and GameEvents != null:
		GameEvents.settings_changed.connect(func(section: StringName) -> void:
			if section == &"graphics" and _ready_world:
				_toggle(bool(Settings.get_value(&"graphics", &"terrain_clipmap", false)))
				_set_horizon(bool(Settings.get_value(&"graphics", &"horizon_bake", false))))
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, -55.0, 0.0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 150.0
	add_child(sun)

	_map = ProceduralMapSystem.new()
	var cfg := MapGenerationConfig.new()
	cfg.seed_shape = SEED
	cfg.seed_variant = SEED
	cfg.num_points = 700
	cfg.map_size = 380.0
	cfg.ocean_points = 200
	cfg.ocean_distance = 120.0
	cfg.num_rivers = 4
	_map.config = cfg
	_map.generate_vegetation = false   # comparar SOLO el terreno
	_map.spawn_test_train = false
	_map.bake_navmesh = false
	_map.generate_spawn_points = false
	_map.generate_colliders = false
	add_child(_map)
	_map.generation_completed.connect(_on_done, CONNECT_ONE_SHOT)

	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.current = true
	_cam.far = 3000.0
	add_child(_cam)
	_cam.position = Vector3(0, 55, 185)
	_cam.basis = Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)

	var cl := CanvasLayer.new()
	add_child(cl)
	_fps = Label.new()
	_fps.position = Vector2(14, 10)
	_fps.add_theme_font_size_override(&"font_size", 20)
	_fps.add_theme_color_override(&"font_color", Color(0.65, 1.0, 0.55))
	_fps.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_fps.add_theme_constant_override(&"outline_size", 6)
	_fps.text = "Generando…"
	cl.add_child(_fps)


func _on_done(_ms: float) -> void:
	# 16KM-2: niveles concéntricos — nivel 0 lleno, 1..LEVELS-1 anillos huecos
	# (el agujero central lo cubre el nivel anterior). Muestreo en WORLD SPACE
	# → los niveles empalman solos; faldones tapan el T-junction fino↔grueso.
	# 16KM-3: material REAL del juego (TerrainPBRBiomeMap: splat + biomas +
	# normalmap global + triplanar) con clipmap_displace — paridad visual
	# completa; el heightfield ya viene enlazado en el material.
	var mat := (_map.terrain_material as ShaderMaterial).duplicate() as ShaderMaterial
	mat.set_shader_parameter(&"clipmap_displace", true)
	_clip = Node3D.new()
	_clip.name = "Clipmap"
	_clip.visible = false
	add_child(_clip)
	_total_verts = 0
	for lv in LEVELS:
		var mi := MeshInstance3D.new()
		mi.name = "L%d" % lv
		mi.mesh = _build_level(STEP * pow(2.0, lv), lv > 0)
		mi.material_override = mat
		_clip.add_child(mi)
		_levels.append(mi)
		_total_verts += _count_verts(mi.mesh as ArrayMesh)

	_terrain_root = _map.find_child("Terrain", true, false) as Node3D
	_ready_world = true
	var coverage := float(GRID_N - 1) * STEP * pow(2.0, LEVELS - 1)
	print("clipmap_proto: %d niveles · %d verts FIJOS · cobertura %.0f m (%.1f km)"
			% [LEVELS, _total_verts, coverage, coverage / 1000.0])


## Grilla (GRID_N²) de paso `step`, con agujero central de la mitad si `hole`
## (lo cubre el nivel anterior) + FALDONES en borde exterior y en el borde del
## agujero (tapan T-junctions entre niveles). Winding antihorario desde +Y.
func _build_level(step: float, hole: bool) -> ArrayMesh:
	var side := GRID_N
	var half := float(side - 1) * step * 0.5
	# Agujero = mitad central ENCOGIDA 2 celdas por lado: los snaps de niveles
	# consecutivos se desalinean hasta ~1 celda gruesa — sin solape quedaba una
	# RENDIJA (se veía el faldón como franja oscura). El solape es coplanar; el
	# sesgo de altura por nivel (en _process) hace ganar al nivel fino.
	var hole_lo := (side - 1) / 4 + 2
	var hole_hi := ((side - 1) / 4) * 3 - 2
	var verts := PackedVector3Array()
	verts.resize(side * side)
	for z in side:
		for x in side:
			verts[z * side + x] = Vector3(float(x) * step - half, 0.0, float(z) * step - half)
	var idx := PackedInt32Array()
	for z in side - 1:
		for x in side - 1:
			if hole and x >= hole_lo and x < hole_hi and z >= hole_lo and z < hole_hi:
				continue  # agujero: lo cubre el nivel interior
			var i0 := z * side + x
			idx.append(i0); idx.append(i0 + 1); idx.append(i0 + side)
			idx.append(i0 + 1); idx.append(i0 + side + 1); idx.append(i0 + side)
	# Faldones: el shader empuja el vértice a la altura del terreno en su XZ;
	# los duplicados bajados SKIRT m cuelgan (el shader suma la altura al Y
	# LOCAL, así que un vértice con y=-SKIRT queda SKIRT por debajo del suelo).
	var sk := PackedInt32Array()   # pares (a,b) de vértices de borde en orden
	for x in side - 1:             # borde exterior norte y sur
		sk.append_array([x, x + 1])
		sk.append_array([(side - 1) * side + x + 1, (side - 1) * side + x])
	for z in side - 1:             # oeste y este
		sk.append_array([(z + 1) * side, z * side])
		sk.append_array([z * side + side - 1, (z + 1) * side + side - 1])
	if hole:                       # borde del agujero (interior)
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
		var a2 := base + (p / 2) * 2
		# Quad vertical a→b hacia abajo (doble cara vía cull del shader no hay:
		# winding hacia afuera; alcanza para tapar el gap).
		idx.append(a); idx.append(bidx); idx.append(a2)
		idx.append(bidx); idx.append(a2 + 1); idx.append(a2)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
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


## ---- 16KM-6 · Horizonte horneado -----------------------------------------

## Hornea 8 vistas de 45° del MUNDO LEJANO (solo los últimos niveles del
## clipmap visibles) desde la posición de la cámara, y arma el anillo de quads.
func _bake_horizon() -> void:
	if _horizon_root != null:
		_horizon_root.queue_free()
	_horizon_root = Node3D.new()
	_horizon_root.name = "HorizonRing"
	add_child(_horizon_root)
	# Mostrar SOLO lo que se va a hornear (niveles lejanos del clipmap).
	var was_clip := _clip.visible
	var was_terr: bool = _terrain_root.visible if _terrain_root != null else false
	if _terrain_root != null:
		_terrain_root.visible = false
	_clip.visible = true
	for lv in _levels.size():
		_levels[lv].visible = lv >= LEVELS - HORIZON_LEVELS
	var vp := SubViewport.new()
	vp.size = Vector2i(HORIZON_TILE, HORIZON_TILE)
	vp.transparent_bg = true   # solo terreno; el cielo real se ve detrás
	vp.own_world_3d = false    # comparte el mundo
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	cam.fov = 45.0             # cuadrado 45° = una vista por cada octavo justo
	cam.far = 30000.0
	vp.add_child(cam)
	var origin := _cam.global_position
	for i in 8:
		var yaw := TAU * float(i) / 8.0
		cam.global_position = origin
		cam.basis = Basis(Vector3.UP, yaw)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		if img == null:
			continue
		var tex := ImageTexture.create_from_image(img)
		# Quad del anillo: centrado en la dirección de la vista, tamaño exacto
		# del cono de 45° a HORIZON_DIST (leve solape para no dejar ranuras).
		var dir := Basis(Vector3.UP, yaw) * Vector3(0, 0, -1)
		var w := 2.0 * HORIZON_DIST * tan(deg_to_rad(22.5)) * 1.03
		var qm := QuadMesh.new()
		qm.size = Vector2(w, w)
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = tex
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.2
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var mi := MeshInstance3D.new()
		mi.mesh = qm
		mi.material_override = mat
		mi.position = origin + dir * HORIZON_DIST
		mi.basis = Basis(Vector3.UP, yaw)   # el quad mira hacia la cámara
		mi.extra_cull_margin = 200.0
		_horizon_root.add_child(mi)
	vp.queue_free()
	# Restaurar visibilidad y aplicar el modo: lejanos APAGADOS, anillo ON.
	if _terrain_root != null:
		_terrain_root.visible = was_terr
	_clip.visible = was_clip
	_apply_horizon()


## Enciende/apaga el modo horizonte: últimos niveles ocultos ↔ anillo visible.
func _apply_horizon() -> void:
	for lv in _levels.size():
		_levels[lv].visible = (not _horizon_on) or lv < LEVELS - HORIZON_LEVELS
	if _horizon_root != null:
		_horizon_root.visible = _horizon_on


func _set_horizon(on: bool) -> void:
	_horizon_on = on
	if on and _horizon_root == null:
		await _bake_horizon()
	else:
		_apply_horizon()


func _process(_d: float) -> void:
	if not _ready_world:
		return
	# Cada NIVEL sigue a la cámara con snap a 2× su paso (clipmap clásico:
	# mantiene los vértices del nivel alineados con la grilla del padre).
	for lv in _levels.size():
		var s := STEP * pow(2.0, lv) * 2.0
		# Sesgo de altura: el nivel FINO gana en la banda de solape (4 cm/nivel
		# — invisible a ojo, mata el z-fight del solape coplanar).
		_levels[lv].position = Vector3(floorf(_cam.position.x / s) * s,
				0.04 * float(LEVELS - lv),
				floorf(_cam.position.z / s) * s)
	_fps.text = "FPS %d · draws %d · %s\nT = alternar REAL ↔ CLIPMAP (%d verts fijos · %d niveles · 16.4 km)" % [
			Engine.get_frames_per_second(),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			"CLIPMAP" if _clip.visible else "terreno REAL",
			_total_verts, LEVELS]

	if not _shot:
		return
	_frame += 1
	# Automático: 30 frames real → captura; alternar → 30 frames → captura; salir.
	if _stage == 0 and _frame == 30:
		get_viewport().get_texture().get_image().save_png(
				"res://systems/procedural_map/test/_clipmap_real.png")
		_toggle(true)
		_stage = 1
	elif _stage == 1 and _frame == 60:
		get_viewport().get_texture().get_image().save_png(
				"res://systems/procedural_map/test/_clipmap_proto.png")
		_stage = 2
		_set_horizon(true)   # 16KM-6: hornear y activar el anillo
	elif _stage == 2 and _frame == 120:
		get_viewport().get_texture().get_image().save_png(
				"res://systems/procedural_map/test/_clipmap_horizon.png")
		print("CLIPMAP_PROTO: DONE")
		get_tree().quit(0)


func _toggle(to_clip: bool) -> void:
	_clip.visible = to_clip
	if _terrain_root != null:
		_terrain_root.visible = not to_clip


func _physics_process(d: float) -> void:
	if _cam == null or _shot:
		return
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir.z -= 1
	if Input.is_key_pressed(KEY_S): dir.z += 1
	if Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_D): dir.x += 1
	if Input.is_key_pressed(KEY_E): dir.y += 1
	if Input.is_key_pressed(KEY_Q): dir.y -= 1
	var sp := 24.0 * (3.5 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	_cam.position += Basis(Vector3.UP, _yaw) * dir.normalized() * sp * d
	_cam.basis = Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif e is InputEventKey and e.pressed and not e.echo:
		var kk := (e as InputEventKey).keycode
		if kk == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif kk == KEY_T and _ready_world:
			# Atajo del banco; la opción REAL vive en Opciones (pausa):
			# graphics/terrain_clipmap — ver _on_settings_changed.
			Settings.set_value(&"graphics", &"terrain_clipmap", not _clip.visible)
		elif kk == KEY_H and _ready_world:
			Settings.set_value(&"graphics", &"horizon_bake", not _horizon_on)
	elif e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= (e as InputEventMouseMotion).relative.x * 0.004
		_pitch = clampf(_pitch - (e as InputEventMouseMotion).relative.y * 0.004, -1.4, 1.4)
