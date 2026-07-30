extends Node3D

## ============================================================================
## culling_view_test · DOS cámaras: probar que el mundo se adapta a la PRINCIPAL
## ============================================================================
## Vista grande = tu cámara (WASD + mouse). Recuadro arriba-derecha = cámara
## AÉREA fija mirando la isla (mismo mundo).
##
## Qué demuestra (y qué no — honesto):
## · Los sistemas CPU son cámara-céntricos: el ANILLO DE PASTO viaja con la
##   cámara principal y el RALEO de árboles lejanos (visible_instance_count)
##   se calcula respecto a ELLA. En la vista aérea se ve el anillo moverse
##   con vos y los bosques ralear alrededor TUYO — prueba directa.
## · El frustum/visibility_range del MOTOR se re-evalúa POR CÁMARA en cada
##   viewport (así funciona Godot): la vista aérea NO muestra "negro" donde
##   no mirás — ella culléa para sí misma. El ahorro de TU vista existe igual
##   (el overlay de FPS + draw calls es de TU vista).
##   godot --path . res://systems/procedural_map/test/culling_view_test.tscn
##   1/2/3/4 = calidad EN VIVO · WASD volar · Shift rápido · ESC suelta mouse
## ============================================================================

const SEED := 4242  # misma isla que mini_world (comparable)

var _cam: Camera3D
var _fps: Label
var _yaw := 0.6
var _pitch := -0.2
var _speed := 24.0
var _map: ProceduralMapSystem


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

	# Cámara PRINCIPAL (la que manda sobre pasto/raleo).
	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.current = true
	_cam.far = 2500.0
	add_child(_cam)
	_cam.position = Vector3(0, 30, 90)

	# Vista AÉREA (PiP): mismo mundo, cámara ortográfica fija desde arriba.
	var pip := SubViewportContainer.new()
	pip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	pip.position = Vector2(-372, 12)
	pip.custom_minimum_size = Vector2(360, 360)
	pip.stretch = true
	var cl := CanvasLayer.new()
	add_child(cl)
	cl.add_child(pip)
	var svp := SubViewport.new()
	svp.own_world_3d = false   # COMPARTE el mundo principal
	svp.size = Vector2i(360, 360)
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	pip.add_child(svp)
	var top_cam := Camera3D.new()
	top_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	top_cam.size = 420.0
	top_cam.position = Vector3(0, 400, 0)
	top_cam.rotation_degrees = Vector3(-90, 0, 0)
	svp.add_child(top_cam)

	_fps = Label.new()
	_fps.position = Vector2(14, 10)
	_fps.add_theme_font_size_override(&"font_size", 20)
	_fps.add_theme_color_override(&"font_color", Color(0.65, 1.0, 0.55))
	_fps.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_fps.add_theme_constant_override(&"outline_size", 6)
	cl.add_child(_fps)


func _process(_d: float) -> void:
	if _fps == null:
		return
	var q := clampi(int(Settings.get_value(&"graphics", &"world_quality", 2)), 0, 3)
	_fps.text = "FPS %d · draws %d · calidad %s (1-4 en vivo)\nVista aérea ↗: mirá el ANILLO DE PASTO y el raleo seguir a TU cámara" % [
			Engine.get_frames_per_second(),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			["Baja", "Media", "Alta", "Ultra"][q]]


func _physics_process(d: float) -> void:
	if _cam == null:
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
			Settings.set_value(&"graphics", &"world_quality", int(k - KEY_1))
	elif e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= (e as InputEventMouseMotion).relative.x * 0.004
		_pitch = clampf(_pitch - (e as InputEventMouseMotion).relative.y * 0.004, -1.4, 1.4)
