extends Node3D

## ============================================================================
## forest_stress · Prueba de FPS con MILES de árboles + LOD por distancia
## ============================================================================
## Bosque grande instanciado igual que VegetationSystem (troceo en celdas +
## MultiMesh por variante + visibility_range: full cerca / malla barata lejos),
## con overlay de FPS/instancias. Sirve para validar que "miles de árboles sin
## perder FPS" y para probar el sesgo de LOD (VegetationQuality.lod_bias).
##   godot --path . res://systems/procedural_map/test/forest_stress.tscn
##   arg opcional: cantidad (default 4000). "shot" = captura FPS y sale.
## Cámara: WASD + mouse (click para capturar el mouse), Shift = rápido.

const AREA := 480.0
const CELL := 48.0
const FULL_END := 55.0
const FAR_END := 320.0

var _fps: Label
var _info := ""
var _cam: Camera3D
var _yaw := 0.0
var _pitch := -0.1
var _speed := 22.0
var _frame := 0
var _shot := false
var _count := 4000
var _dlods: Array = []
var _dacc := 0.0
var _bench_time := 0.0


func _ready() -> void:
	var ua := OS.get_cmdline_user_args()
	for a in ua:
		if a.is_valid_int():
			_count = a.to_int()
		elif a == "shot":
			_shot = true
		elif a == "hojasimg":
			# Test A/B del usuario: "hojas como imágenes" = MENOS cards más grandes
			# (la imagen de hoja hace el trabajo). Mide FPS vs baseline con la
			# misma semilla y cámara.
			var fc := FloraConfig.new()
			fc.tree_leaf = LeafStyle.new()
			fc.tree_leaf.canopy_density = 0.4
			fc.tree_leaf.spray_scale = 2.3
			fc.bush_leaf = fc.tree_leaf
			fc.lod = FloraLodStyle.new()
			fc.lod.max_trunk_sides = 5   # tubo de 5 lados: misma silueta, menos polys
			FloraConfig.active = fc

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.0015
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -60.0, 0.0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(AREA * 1.3, AREA * 1.3)
	floor_mi.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.30, 0.4, 0.22)
	fmat.roughness = 1.0
	floor_mi.material_override = fmat
	add_child(floor_mi)

	_build_forest()

	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.current = true
	_cam.far = 600.0
	add_child(_cam)
	_cam.position = Vector3(0, 2.0, 0)
	_yaw = 0.6

	var cl := CanvasLayer.new()
	add_child(cl)
	_fps = Label.new()
	_fps.position = Vector2(16, 12)
	_fps.add_theme_font_size_override("font_size", 26)
	_fps.add_theme_color_override("font_color", Color(0.6, 1, 0.5))
	_fps.add_theme_color_override("font_outline_color", Color.BLACK)
	_fps.add_theme_constant_override("outline_size", 6)
	cl.add_child(_fps)


func _build_forest() -> void:
	# Pool de especies (full + malla lejana barata), variadas.
	var species := [TreeParams.lapacho(), TreeParams.araucaria(),
			TreeParams.timbo(), TreeParams.cedro(), TreeParams.algarrobo()]
	var full: Array[Mesh] = []
	var far: Array[Mesh] = []
	for i in species.size():
		var p := FloraConfig.apply_active(species[i], "tree")   # config del test/global
		full.append(FloraFactory.make_tree(p, 100 + i))
		var lp := BiomeFloraLibrary.build_tree_lod_pool(species[i], 100 + i, 1)
		far.append(lp[0])

	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	# Reparte posiciones en celdas → cada celda 1 MultiMesh por variante (AABB
	# local = frustum + distancia cullean por celda, igual que VegetationSystem).
	var cells := {}   # Vector2i → Array[species] de Array[Transform3D]
	for _n in _count:
		var x := rng.randf_range(-AREA * 0.5, AREA * 0.5)
		var z := rng.randf_range(-AREA * 0.5, AREA * 0.5)
		var sp := rng.randi() % species.size()
		var cell := Vector2i(floori(x / CELL), floori(z / CELL))
		if not cells.has(cell):
			var arr: Array = []
			for _s in species.size():
				arr.append([] as Array[Transform3D])
			cells[cell] = arr
		var s := rng.randf_range(0.85, 1.4)
		var t := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s)),
				Vector3(x, 0, z))
		(cells[cell][sp] as Array[Transform3D]).append(t)

	var lb := VegetationQuality.lod_bias
	for cell: Vector2i in cells:
		var center := Vector3((float(cell.x) + 0.5) * CELL, 0.0, (float(cell.y) + 0.5) * CELL)
		for sp in species.size():
			var bucket: Array[Transform3D] = cells[cell][sp]
			if bucket.is_empty():
				continue
			# Ordenar por prioridad → density-LOD ralea uniforme.
			bucket.sort_custom(func(a: Transform3D, b: Transform3D) -> bool:
				return hash([int(a.origin.x * 7), int(a.origin.z * 7)]) \
						< hash([int(b.origin.x * 7), int(b.origin.z * 7)]))
			var fmmi := _mmi("F_%d_%d_%d" % [cell.x, cell.y, sp], full[sp], bucket, 0.0, FULL_END * lb)
			add_child(fmmi)
			_dlods.append({"mmi": fmmi, "center": center, "full": bucket.size()})
			var lmmi := _mmi("L_%d_%d_%d" % [cell.x, cell.y, sp], far[sp], bucket, FULL_END * lb, FAR_END * lb)
			add_child(lmmi)
			_dlods.append({"mmi": lmmi, "center": center, "full": bucket.size()})
	_info = "%d árboles · %d especies · celda %dm · density-LOD ON" % [_count, species.size(), int(CELL)]


func _mmi(nm: String, mesh: Mesh, bucket: Array[Transform3D],
		vb: float, ve: float) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = bucket.size()
	for j in bucket.size():
		mm.set_instance_transform(j, bucket[j])
	var mi := MultiMeshInstance3D.new()
	mi.name = nm
	mi.multimesh = mm
	if vb > 0.0:
		mi.visibility_range_begin = vb
		mi.visibility_range_begin_margin = 8.0
	if ve > 0.0:
		mi.visibility_range_end = ve
		mi.visibility_range_end_margin = 16.0
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	if not VegetationQuality.cast_shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _process(d: float) -> void:
	_frame += 1
	# Density-LOD: ralear chunks lejanos por distancia a cámara (cada ~0.18 s).
	_dacc += d
	if _dacc >= 0.18 and _cam != null:
		_dacc = 0.0
		var cp := _cam.global_position
		for e: Dictionary in _dlods:
			var mmi: MultiMeshInstance3D = e["mmi"]
			if mmi.multimesh == null:
				continue
			var full: int = e["full"]
			var dist := cp.distance_to(e["center"])
			var frac := 1.0
			if dist > 55.0:
				var t := clampf((dist - 55.0) / 185.0, 0.0, 1.0)
				frac = lerpf(1.0, 0.22, t * t * (3.0 - 2.0 * t))
			var vc := clampi(int(round(float(full) * frac)), 1, full)
			if mmi.multimesh.visible_instance_count != vc:
				mmi.multimesh.visible_instance_count = vc
	if _fps != null:
		_fps.text = "FPS: %d\n%s\ndraw calls: %d" % [
				Engine.get_frames_per_second(), _info,
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)]
	# Medición SERIA: frames 120-300 acumulan frame-time (los primeros ~100 frames
	# compilan shaders/suben mallas = ruido); reporta FPS PROMEDIO + verts totales.
	if _shot and _frame >= 60 and _frame < 180:
		_bench_time += d
	if _shot and _frame == 180:
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://systems/procedural_map/test/_forest_stress.png")
		var avg_fps := 120.0 / maxf(_bench_time, 0.0001)
		print("SHOT_SAVED avg_fps=%.1f draws=%d prims=%d" % [avg_fps,
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
		get_tree().quit()


func _physics_process(d: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir.z -= 1
	if Input.is_key_pressed(KEY_S): dir.z += 1
	if Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_D): dir.x += 1
	var sp := _speed * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	var basis := Basis(Vector3.UP, _yaw)
	_cam.position += basis * dir.normalized() * sp * d
	_cam.position.y = clampf(_cam.position.y, 1.5, 60.0)
	_cam.basis = Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= e.relative.x * 0.005
		_pitch = clampf(_pitch - e.relative.y * 0.005, -1.3, 1.3)
