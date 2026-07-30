extends Node3D

## ============================================================================
## clipmap_game_check · Verifica el clipmap por la RUTA REAL del juego
## ============================================================================
## A diferencia de clipmap_proto (que arma el clipmap a mano), este banco enciende
## graphics/terrain_clipmap y deja que ProceduralMapSystem._apply_clipmap() cree el
## nodo TerrainClipmap solo, al terminar de generar — probando la integración real.
## Guarda 2 PNG (chunks vs clipmap) y sale.
##   godot --path . res://systems/procedural_map/test/clipmap_game_check.tscn -- shot
## ============================================================================

const SEED := 4242
var _map: ProceduralMapSystem
var _cam: Camera3D
var _fps: Label
var _shot := false
var _frame := 0
var _stage := 0
var _done := false


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_shot = OS.get_cmdline_user_args().has("shot")
	Settings.set_value(&"graphics", &"terrain_clipmap", false, false)

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
	_map.generate_vegetation = false
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
	_cam.position = Vector3(0, 55, 185)
	_cam.basis = Basis(Vector3.UP, 0.0) * Basis(Vector3.RIGHT, -0.22)
	add_child(_cam)

	var cl := CanvasLayer.new()
	add_child(cl)
	_fps = Label.new()
	_fps.position = Vector2(14, 10)
	_fps.add_theme_font_size_override(&"font_size", 20)
	_fps.add_theme_color_override(&"font_color", Color(0.65, 1.0, 0.55))
	_fps.text = "Generando…"
	cl.add_child(_fps)


func _on_done(_ms: float) -> void:
	_done = true
	var cm := _map.find_child("TerrainClipmap", true, false)
	print("clipmap_game_check: TerrainClipmap presente tras generar (default off) = %s"
			% [cm != null])


func _process(_d: float) -> void:
	if not _done:
		return
	var cm := _map.find_child("TerrainClipmap", true, false)
	_fps.text = "FPS %d · draws %d · clipmap=%s (nodo=%s)" % [
			Engine.get_frames_per_second(),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			Settings.get_value(&"graphics", &"terrain_clipmap", false), cm != null]
	if not _shot:
		return
	_frame += 1
	if _stage == 0 and _frame == 30:
		get_viewport().get_texture().get_image().save_png(
				"res://systems/procedural_map/test/_gamecheck_chunks.png")
		Settings.set_value(&"graphics", &"terrain_clipmap", true)  # enciende → _apply_clipmap
		_stage = 1
	elif _stage == 1 and _frame == 70:
		get_viewport().get_texture().get_image().save_png(
				"res://systems/procedural_map/test/_gamecheck_clipmap.png")
		print("CLIPMAP_GAME_CHECK: DONE clipmap_node=%s"
				% [_map.find_child("TerrainClipmap", true, false) != null])
		get_tree().quit(0)
