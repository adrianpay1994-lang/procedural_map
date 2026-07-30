extends Node3D

## ============================================================================
## frustum_spy_test · Observador que ve SOLO lo que renderiza la cámara 1
## ============================================================================
## Vista GRANDE = observador (detrás/arriba de la cámara del jugador).
## Recuadro ↗ = lo que ve la cámara 1 (el "jugador").
## CULLING MANUAL REAL: cada tick se testea el AABB de cada pieza visual del
## mapa contra el FRUSTUM de la cámara 1 — lo que queda fuera se OCULTA.
## El observador entonces ve el mundo RECORTADO al cono de la cámara 1:
## a los costados NEGRO/vacío (no se renderiza), y dentro del cono se ven los
## niveles de LOD reales (árboles llenos cerca de cam1, impostores planos
## lejos — de costado se nota que son carteles). Pasto y raleo siguen a cam1
## (camera_override). El cono se dibuja como wireframe amarillo.
##   Controles: WASD+mouse mueve la CÁMARA 1 · O = mover observador ·
##   F = congelar/descongelar el culling · ESC suelta mouse
##   godot --path . res://systems/procedural_map/test/frustum_spy_test.tscn
## ============================================================================

const SEED := 4242

var _map: ProceduralMapSystem
var _cam1: Camera3D          # jugador (manda)
var _obs: Camera3D           # observador (vista grande)
var _fps: Label
var _yaw := 0.0
var _pitch := -0.1
var _move_obs := false
var _frozen := false
var _accum := 0.0
var _visuals: Array[VisualInstance3D] = []
var _frustum_mesh: MeshInstance3D
var _ready_world := false


func _ready() -> void:
	if get_tree().current_scene != self:
		return
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
	_map.spawn_test_train = false
	_map.bake_navmesh = false
	_map.generate_spawn_points = false
	add_child(_map)
	_map.generation_completed.connect(_on_done, CONNECT_ONE_SHOT)

	# Cámara 1 (jugador): vive en el PiP; el orden de LOD del motor en el PiP
	# es el de ELLA (su viewport propio) — ahí ves su render real.
	var pip := SubViewportContainer.new()
	pip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	pip.position = Vector2(-372, 12)
	pip.custom_minimum_size = Vector2(360, 240)
	pip.stretch = true
	var cl := CanvasLayer.new()
	add_child(cl)
	cl.add_child(pip)
	var svp := SubViewport.new()
	svp.own_world_3d = false
	svp.size = Vector2i(360, 240)
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	pip.add_child(svp)
	_cam1 = Camera3D.new()
	_cam1.fov = 70.0
	_cam1.far = 2500.0
	svp.add_child(_cam1)
	_cam1.position = Vector3(0, 26, 60)

	# Observador: cámara ACTIVA de la vista grande.
	_obs = Camera3D.new()
	_obs.fov = 65.0
	_obs.current = true
	_obs.far = 3000.0
	add_child(_obs)

	# Wireframe del cono de la cámara 1.
	_frustum_mesh = MeshInstance3D.new()
	_frustum_mesh.mesh = ImmediateMesh.new()
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.albedo_color = Color(1.0, 0.9, 0.2)
	_frustum_mesh.material_override = fm
	add_child(_frustum_mesh)

	_fps = Label.new()
	_fps.position = Vector2(14, 10)
	_fps.add_theme_font_size_override(&"font_size", 18)
	_fps.add_theme_color_override(&"font_color", Color(0.65, 1.0, 0.55))
	_fps.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_fps.add_theme_constant_override(&"outline_size", 6)
	_fps.text = "Generando…"
	cl.add_child(_fps)


func _on_done(_ms: float) -> void:
	# Pasto y raleo obedecen a la CÁMARA 1 (no al observador).
	for c in _map.get_children():
		if c is VegetationSystem:
			(c as VegetationSystem).camera_override = _cam1
		elif c is GrassPatchSystem:
			(c as GrassPatchSystem).camera_override = _cam1
	# Piezas visuales a cullear manualmente (celdas de veg, chunks, agua, vía).
	_visuals.clear()
	_collect_visuals(_map)
	_ready_world = true
	print("frustum_spy: %d piezas visuales bajo culling manual" % _visuals.size())


func _collect_visuals(n: Node) -> void:
	for c in n.get_children():
		if c is VisualInstance3D:
			_visuals.append(c)
		_collect_visuals(c)


func _process(delta: float) -> void:
	if not _ready_world:
		return
	# Observador pegado detrás/arriba de cam1 (salvo modo O).
	if not _move_obs:
		var back := -_cam1.basis.z
		_obs.position = _cam1.position - back * 46.0 + Vector3(0, 26, 0)
		_obs.look_at(_cam1.position + back * 30.0, Vector3.UP)

	_accum += delta
	if _accum >= 0.12 and not _frozen:
		_accum = 0.0
		_apply_frustum_cull()
		_draw_frustum()

	var culled := 0
	for v in _visuals:
		if not v.visible:
			culled += 1
	_fps.text = "FPS %d · draws %d · piezas ocultas por el cono de cam1: %d/%d%s\nWASD+mouse = cámara 1 · O = observador (%s) · F = congelar cull (%s)" % [
			Engine.get_frames_per_second(),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			culled, _visuals.size(),
			"  [CONGELADO]" if _frozen else "",
			"moviendo" if _move_obs else "auto", "sí" if _frozen else "no"]


## Oculta toda pieza cuyo AABB global quede FUERA del frustum de la cámara 1.
func _apply_frustum_cull() -> void:
	var planes := _cam1.get_frustum()
	for v in _visuals:
		if not is_instance_valid(v):
			continue
		var bb := v.get_aabb()
		# custom_aabb es LOCAL: llevar a mundo (sin rotación en nuestras piezas).
		var gbb := AABB(v.global_position + bb.position, bb.size)
		v.visible = _aabb_in_frustum(gbb, planes)


static func _aabb_in_frustum(bb: AABB, planes: Array[Plane]) -> bool:
	for p in planes:
		# Vértice del AABB MÁS del lado positivo del plano; si aún así queda
		# detrás, el AABB entero está fuera de ese plano → fuera del frustum.
		var v := bb.position
		if p.normal.x < 0.0: v.x += bb.size.x
		if p.normal.y < 0.0: v.y += bb.size.y
		if p.normal.z < 0.0: v.z += bb.size.z
		if p.is_point_over(v):
			return false
	return true


func _draw_frustum() -> void:
	var im := _frustum_mesh.mesh as ImmediateMesh
	im.clear_surfaces()
	var t := _cam1.global_transform
	var near := 0.5
	var far := 220.0   # dibujar solo el tramo cercano del cono (legible)
	var tan_v := tan(deg_to_rad(_cam1.fov * 0.5))
	var vp_size := _cam1.get_viewport().get_visible_rect().size if _cam1.get_viewport() != null else Vector2(16, 9)
	var aspect := vp_size.x / maxf(vp_size.y, 1.0)
	var corners: Array[Vector3] = []
	for d: float in [near, far]:
		var h := tan_v * d
		var w := h * aspect
		for s: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			corners.append(t * Vector3(s.x * w, s.y * h, -d))
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in 4:
		im.surface_add_vertex(corners[i])
		im.surface_add_vertex(corners[(i + 1) % 4])
		im.surface_add_vertex(corners[4 + i])
		im.surface_add_vertex(corners[4 + (i + 1) % 4])
		im.surface_add_vertex(corners[i])
		im.surface_add_vertex(corners[4 + i])
	im.surface_end()


func _physics_process(d: float) -> void:
	if not _ready_world:
		return
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir.z -= 1
	if Input.is_key_pressed(KEY_S): dir.z += 1
	if Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_D): dir.x += 1
	if Input.is_key_pressed(KEY_E): dir.y += 1
	if Input.is_key_pressed(KEY_Q): dir.y -= 1
	var sp := 22.0 * (3.5 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	var target := _obs if _move_obs else _cam1
	target.position += Basis(Vector3.UP, _yaw) * dir.normalized() * sp * d
	if not _move_obs:
		_cam1.basis = Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif e is InputEventKey and e.pressed and not e.echo:
		match (e as InputEventKey).keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_O:
				_move_obs = not _move_obs
			KEY_F:
				_frozen = not _frozen
	elif e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= (e as InputEventMouseMotion).relative.x * 0.004
		_pitch = clampf(_pitch - (e as InputEventMouseMotion).relative.y * 0.004, -1.4, 1.4)
