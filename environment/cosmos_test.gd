extends Node3D

## Banco de prueba del cielo tierra-plana (CosmosSky). Correr CON ventana.
##   godot --path . res://systems/procedural_map/environment/cosmos_test.tscn -- 0.5
##   arg 1 = time_of_day (0=medianoche, 0.25=amanecer, 0.5=mediodía, 0.75=ocaso)
##   arg "shot" = captura PNG y sale. Sin args = animado (día de 20 s).

var _cosmos: CosmosSky
var _fps: Label
var _frame := 0
var _shot := false


func _ready() -> void:
	var ua := OS.get_cmdline_user_args()
	var tod := 0.5
	var animate := true
	for a in ua:
		if a.is_valid_float():
			tod = a.to_float()
			animate = false
		elif a == "shot":
			_shot = true

	# Environment con Sky (CosmosSky le pone el DaySky).
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.0012
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	add_child(sun)
	var moon := DirectionalLight3D.new()
	moon.name = "Moon"
	add_child(moon)

	# Suelo con algunos árboles para ver la iluminación y las sombras.
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	floor_mi.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.30, 0.4, 0.22)
	fmat.roughness = 1.0
	floor_mi.material_override = fmat
	add_child(floor_mi)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 6:
		var mi := MeshInstance3D.new()
		mi.mesh = FloraFactory.make_tree(TreeParams.lapacho(), 10 + i)
		mi.position = Vector3(rng.randf_range(-30, 30), 0, rng.randf_range(-40, 10))
		add_child(mi)

	_cosmos = CosmosSky.new()
	_cosmos.sun = sun
	_cosmos.moon = moon
	_cosmos.world_environment = we
	_cosmos.day_length_s = 20.0 if animate else 0.0
	_cosmos.time_of_day = tod
	_cosmos.paused = not animate
	# Centro de la órbita ("norte"/centro de isla) 2 km al norte → la cámara en el
	# origen queda OFF-CENTER y ve día/noche reales (en el centro sería crepúsculo
	# perpetuo, como el polo). El sol/luna orbitan en HORIZONTAL a orbit_height.
	_cosmos.position = Vector3(0, 0, -2000)
	add_child(_cosmos)

	var cam := Camera3D.new()
	cam.current = true
	cam.fov = 68.0
	cam.far = 12000.0
	add_child(cam)
	# Mirar al NORTE (hacia el centro de la órbita) con leve inclinación arriba:
	# se ve el suelo+árboles cerca y el sol/luna orbitando sobre el horizonte norte.
	cam.look_at_from_position(Vector3(0, 6, 12), Vector3(0, 40, -120), Vector3.UP)

	var cl := CanvasLayer.new()
	add_child(cl)
	_fps = Label.new()
	_fps.position = Vector2(16, 12)
	_fps.add_theme_font_size_override("font_size", 24)
	_fps.add_theme_color_override("font_color", Color(1, 1, 0.6))
	_fps.add_theme_color_override("font_outline_color", Color.BLACK)
	_fps.add_theme_constant_override("outline_size", 6)
	cl.add_child(_fps)


func _process(_d: float) -> void:
	_frame += 1
	if _fps != null and _cosmos != null:
		_fps.text = "FPS %d · t=%.2f · %s" % [Engine.get_frames_per_second(),
				_cosmos.time_of_day, _cosmos.phase()]
	if _shot and _frame == 20:
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://systems/procedural_map/environment/_cosmos.png")
		print("SHOT_SAVED phase=%s" % _cosmos.phase())
		get_tree().quit()
