extends Node3D

## ============================================================================
## mini_world · Banco RÁPIDO de gráficos en vivo (§6.6)
## ============================================================================
## Mini-mundo procedural REAL (semilla FIJA — siempre la misma isla) que genera
## en segundos, con cámara libre y overlay de FPS. Prueba EN VIVO del sistema de
## MALLA POR CELDAS (quadtree LOD): el player (esta cámara) maneja el terreno; la
## cámara ESPÍA F7 solo VE lo que el player construyó (fuera del cono = vacío).
##   1/2/3/4 = calidad Baja/Media/Alta/Ultra EN VIVO
##   G = colores por subdivisión (LOD) + wireframe · F = construir SOLO el cono ↔ 360°
##   F7 = cámara espía (despegar del player y ver su cono) · F8 (con F7) = wireframe global
##   WASD + mouse (clic captura) = volar · Shift = rápido · ESC = soltar mouse
## Correr CON ventana:
##   godot --path . res://systems/procedural_map/test/mini_world.tscn
## ============================================================================

const SEED := 4242  # FIJA: mismo mini-mundo siempre (comparable entre cambios)

var _cam: Camera3D
var _fps: Label
var _yaw := 0.6
var _pitch := -0.25
var _speed := 24.0
var _map: ProceduralMapSystem
var _qt = null            # QuadtreeMeshLOD del terreno (para toggles de debug)
var _spy = null           # DebugSpyCamera (F7): mientras espía, ESTA cámara NO se mueve
var _shot := false
var _shot_frames := 0


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	# Args CLI: "shot" = PNG + salir (verificación); "flora2d" = FloraConfig modo
	# TODO-2D (árboles/arbustos como impostor octaédrico desde 0 m, P3).
	var ua := OS.get_cmdline_user_args()
	_shot = ua.has("shot")
	for a in ua:
		if a.begins_with("q="):   # forzar calidad (benchmarks comparables)
			Settings.set_value(&"graphics", &"world_quality", a.trim_prefix("q=").to_int())
	var flora2d: FloraConfig = null
	if ua.has("flora2d"):
		flora2d = FloraConfig.new()
		flora2d.tree_leaf = LeafStyle.new()
		flora2d.tree_leaf.method = LeafStyle.Method.IMPOSTOR_OCTA
		flora2d.bush_leaf = flora2d.tree_leaf
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.001
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, -55.0, 0.0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 150.0
	sun.directional_shadow_blend_splits = true
	add_child(sun)

	# MALLA POR CELDAS (quadtree LOD) + construir SOLO el cono de la cámara: para VER
	# las subdivisiones (celdas chicas cerca, grandes lejos) y el frustum-cull. Esto es
	# de ESTE test (MiniWorld), NO del juego. Rugosidad ON (más detalle en crestas).
	Settings.set_value(&"graphics", &"terrain_quadtree", true, false)
	Settings.set_value(&"graphics", &"terrain_frustum_cull", true, false)
	Settings.set_value(&"graphics", &"terrain_rough_lod", false, false)  # OFF: anillos LIMPIOS
	Settings.set_value(&"graphics", &"ocean_quadtree", true, false)      # el OCÉANO también por celdas (cullea)

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
	_map.flora_config = flora2d   # null = look normal; "flora2d" = todo-2D (P3)
	_map.spawn_test_train = false
	_map.bake_navmesh = false
	_map.generate_spawn_points = false
	if _shot:
		_map.generate_vegetation = OS.get_cmdline_user_args().has("veg")   # captura LIMPIA de la MALLA (sin veg tapando)
	add_child(_map)
	_map.generation_completed.connect(_on_done, CONNECT_ONE_SHOT)

	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.current = true
	_cam.far = 2500.0
	add_child(_cam)
	_cam.position = Vector3(0, 60, 120)

	var cl := CanvasLayer.new()
	add_child(cl)
	_fps = Label.new()
	_fps.position = Vector2(14, 10)
	_fps.add_theme_font_size_override(&"font_size", 22)
	_fps.add_theme_color_override(&"font_color", Color(0.65, 1.0, 0.55))
	_fps.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_fps.add_theme_constant_override(&"outline_size", 6)
	_fps.text = "Generando mini-mundo (seed %d)…" % SEED
	cl.add_child(_fps)


var _done := false


func _on_done(ms: float) -> void:
	print("mini_world listo en %.1f s" % (ms / 1000.0))
	_done = true
	# El quadtree sigue a ESTA cámara (el "player"): la cámara ESPÍA (F7) NO lo maneja,
	# solo VE lo que el player construyó → fuera del cono del player, el suelo no existe.
	# (Este es el patrón "componente en el player": la cámara del player es el foco del
	# terreno; una cámara sin ese rol solo observa. Formalizar como componente = F-objetos.)
	_qt = _map.find_child("TerrainQuadtree", true, false)
	if _qt != null:
		_qt.target_camera = _cam
		# Arg CLI "rs": render SIN NODOS (RenderingServer/RID) para comparar contra
		# el modo MeshInstance3D con el MISMO mundo (misma semilla, misma cámara).
		if OS.get_cmdline_user_args().has("rs"):
			_qt.use_rendering_server = true
			_qt.clear_leaves()
	# El OCÉANO (por celdas) también sigue al PLAYER y cullea a su cono (nada de mar afuera).
	var oq = _map.find_child("Ocean", true, false)
	if oq != null:
		oq.set_target_camera(_cam)
		oq.frustum_cull = true
	# Cámara ESPÍA F7 — SOLO en este test (se sacó de procedural_map.tscn). Culla los
	# visuales contra el frustum del player; el pasto/raleo siguen al player.
	# Arg "nogate": desactiva el gate de cono del pasto → línea base comparable.
	if OS.get_cmdline_user_args().has("nogate"):
		var g := _map.find_child("GrassPatches", true, false)
		if g != null:
			g.spatial_gate = null
	var spy: Node = load("res://systems/procedural_map/debug_spy_camera.gd").new()
	spy.name = "DebugSpyCamera"
	_map.add_child(spy)
	_spy = spy
	if _shot:
		# Vista a NIVEL DE PLAYER (ojos ~2 m, mirando horizontal hacia la isla):
		# el caso REAL de juego (frustum ve una tajada, no la isla entera). far
		# acotado = distancia de visión realista.
		_cam.far = 800.0
		# Elevada mirando la isla: se ven los ANILLOS de subdivisión (fino cerca del
		# foco → grueso lejos) en el suelo, sin veg tapando.
		_cam.look_at_from_position(Vector3(0, 95, 175), Vector3(0, -30, 0), Vector3.UP)
		# Arg "ground": vista a RAS DEL SUELO (ahí sí hay pasto → medir su culling).
		if OS.get_cmdline_user_args().has("ground"):
			var gy: float = _map.sampler.get_height(Vector2(0, 40)) + 1.8
			_cam.look_at_from_position(Vector3(0, gy, 40), Vector3(60, gy - 6, -60), Vector3.UP)
		if _qt != null:
			_qt.debug_lod_color = true   # la captura muestra los colores de subdivisión
			# Arg "boxes": cajas de nodos — visibles por LOD, descartadas por el cono
			# en gris (el visor de verificación estilo motor AAA).
			if OS.get_cmdline_user_args().has("boxes"):
				_qt.debug_aabb = true


func _process(_d: float) -> void:
	if _map == null or _map.sampler == null:
		return
	if _shot and _done:
		_shot_frames += 1
		# 45 frames deja asentar impostores/sombras; el PASTO además se construye
		# async (3 celdas/frame) → esperar a que termine, o cortar a los 400 frames.
		if _shot_frames >= 45 and (_grass_ready() or _shot_frames >= 400):
			var img := get_viewport().get_texture().get_image()
			img.save_png("res://systems/procedural_map/test/_mini_world.png")
			_print_breakdown()
			print("SHOT_SAVED FPS=%d draws=%d prims=%d" % [Engine.get_frames_per_second(),
					RenderingServer.get_rendering_info(
							RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
					RenderingServer.get_rendering_info(
							RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
			get_tree().quit()
	var q := clampi(int(Settings.get_value(&"graphics", &"world_quality", 2)), 0, 3)
	var dbg := ("ON" if (_qt != null and _qt.debug_lod_color) else "off")
	var cono := ("ON" if (_qt != null and _qt.frustum_cull) else "off")
	var cajas := ("ON" if (_qt != null and _qt.debug_aabb) else "off")
	_fps.text = "FPS: %d · draws: %d · calidad: %s (1-4)\nWASD volar · G colores-LOD(%s) · F cono(%s) · B cajas(%s) · R rugosidad · F7 espía\n%s" % [
			Engine.get_frames_per_second(),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			["Baja", "Media", "Alta", "Ultra"][q], dbg, cono, cajas, _lod_stats_line()]


## TODAS las superficies por celdas de la escena (terreno + superficie y suelo del
## océano). Los toggles de debug se aplican a todas: si no, se ve "media mesh".
func _all_surfaces() -> Array:
	var out: Array = []
	var oc = _map.find_child("Ocean", true, false)
	if oc != null:
		for q in [oc.surface_quadtree(), oc.floor_quadtree()]:
			if q != null:
				out.append(q)
	return out


## Línea de verificación: cuántas subdivisiones existen por nivel de LOD, cuántas
## tiró el cono y cuántos triángulos de terreno hay. Es la prueba EN PANTALLA de
## que solo vive lo que la cámara del player decidió.
func _lod_stats_line() -> String:
	if _qt == null:
		return ""
	var s: Dictionary = _qt.stats()
	var by: PackedInt32Array = s.by_lod
	var cells: PackedFloat32Array = s.cell_m
	var cul: PackedInt32Array = s.culled_by_lod
	var parts := PackedStringArray()
	for i in by.size():
		if by[i] > 0 or cul[i] > 0:
			# "vistas/podadas" por nivel: se ve dónde recorta el cono en cada LOD.
			parts.append("LOD%d(%.0fm):%d%s" % [i, cells[i], by[i],
					("/-%d" % cul[i]) if cul[i] > 0 else ""])
	# "podadas" cuenta NODOS podados, no subdivisiones finales: podar un nodo alto
	# tira su subárbol entero → se muestra también el ÁREA que se ahorró.
	return "subdivisiones VISIBLES %d · podadas por el cono %d (%.2f km²) · nodos recorridos %d · tri %d\n%s" % [
			s.leaves, s.culled, float(s.culled_area_m2) / 1e6, s.visited, s.tris,
			" ".join(parts)]


## ¿El pasto por parches terminó su llenado async? (sin pasto activado: sí).
func _grass_ready() -> bool:
	var g := _map.find_child("GrassPatches", true, false)
	return g == null or (g as GrassPatchSystem).is_idle()


## Desglose de MMIs por categoría: cuántos draw-nodes y cuántas instancias vivas
## hay de cada estrato (troncos 3D · impostores · sombras · pasto) para saber QUÉ
## consume (el diagnóstico que pidió el usuario en vez de adivinar).
func _print_breakdown() -> void:
	var cats := {"Veg_full3D": [0, 0], "VegCross_2D": [0, 0], "VegImp_2D": [0, 0],
			"VegShadow_": [0, 0], "Grass": [0, 0], "otros_MMI": [0, 0]}
	for mmi: MultiMeshInstance3D in _all_mmis(self):
		var n := String(mmi.name)
		var key := "otros_MMI"
		if n.begins_with("VegCross_"): key = "VegCross_2D"
		elif n.begins_with("VegImp_"): key = "VegImp_2D"
		elif n.begins_with("VegShadow_"): key = "VegShadow_"
		elif n.begins_with("Veg_"): key = "Veg_full3D"
		# El pasto vive en GrassPatches/Patch_x_y/<MMI sin nombre propio> → por NOMBRE
		# caía en "otros_MMI" y parecía que no había pasto. Se clasifica por ANCESTRO.
		elif n.begins_with("Grass") or n.begins_with("grass") \
				or _under(mmi, "GrassPatches"): key = "Grass"
		cats[key][0] += 1
		if mmi.multimesh != null:
			var vc: int = mmi.multimesh.visible_instance_count
			cats[key][1] += (mmi.multimesh.instance_count if vc < 0 else vc)
	print("=== BREAKDOWN vegetación (MMIs · instancias) ===")
	for k: String in cats:
		print("  %-12s %4d MMIs · %6d instancias" % [k, cats[k][0], cats[k][1]])


## ¿El nodo cuelga de un ancestro con ese nombre?
func _under(n: Node, ancestor_name: String) -> bool:
	var p := n.get_parent()
	while p != null:
		if String(p.name) == ancestor_name:
			return true
		p = p.get_parent()
	return false


func _all_mmis(node: Node) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is MultiMeshInstance3D:
			out.append(c)
		out.append_array(_all_mmis(c))
	return out


func _physics_process(d: float) -> void:
	if _cam == null:
		return
	# F7 ESPÍA: el PLAYER queda QUIETO (posición Y cono). WASD pasa a volar la espía;
	# esta cámara no se toca hasta salir del modo espía.
	if _spy != null and _spy.is_active():
		return
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir.z -= 1
	if Input.is_key_pressed(KEY_S): dir.z += 1
	if Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_D): dir.x += 1
	if Input.is_key_pressed(KEY_E): dir.y += 1
	if Input.is_key_pressed(KEY_Q): dir.y -= 1
	var sp := _speed * (3.5 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	_cam.position += Basis(Vector3.UP, _yaw) * dir.normalized() * sp * d
	_cam.basis = Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif e is InputEventKey and e.pressed and not e.echo:
		var k := (e as InputEventKey).keycode
		if k == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif k >= KEY_1 and k <= KEY_4:
			# EN VIVO: Settings emite settings_changed → VegetationSystem
			# re-escala LOD/sombras al instante (§6.4). Sin recargar nada.
			Settings.set_value(&"graphics", &"world_quality", int(k - KEY_1))
		elif k == KEY_G and _qt != null:
			# Pinta TODAS las superficies (terreno Y océano): antes solo el terreno
			# cambiaba y parecía que "no pintaba toda la mesh".
			var on: bool = not _qt.debug_lod_color
			_qt.debug_lod_color = on
			for q in _all_surfaces():
				q.debug_lod_color = on
		elif k == KEY_F and _qt != null:
			var fon: bool = not _qt.frustum_cull                 # construir SOLO el cono ↔ 360°
			_qt.frustum_cull = fon
			for q in _all_surfaces():
				q.frustum_cull = fon
		elif k == KEY_B and _qt != null:
			var bon: bool = not _qt.debug_aabb
			_qt.debug_aabb = bon
			for q in _all_surfaces():
				q.debug_aabb = bon
		elif k == KEY_R and _qt != null:
			_qt.rough_gain = 0.0 if _qt.rough_gain > 0.0 else 1.5   # anillos LIMPIOS ↔ adaptativo
	elif e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if _spy != null and _spy.is_active():
			return   # el mouse gira la ESPÍA, no al player (su cono queda fijo)
		_yaw -= (e as InputEventMouseMotion).relative.x * 0.004
		_pitch = clampf(_pitch - (e as InputEventMouseMotion).relative.y * 0.004, -1.4, 1.4)
