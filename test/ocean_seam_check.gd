extends Node3D

## ============================================================================
## ocean_seam_check · Verificación VISUAL del océano 2-niveles (§F8)
## ============================================================================
## Genera un mapa chico REAL (con agua), pone la cámara rasante sobre el mar
## mirando la transición fino(8 m)↔grueso(32 m) y guarda 2 capturas. Si los
## faldones funcionan, NO se ven ranuras/agujeros en la superficie del agua.
##   godot --path . res://systems/procedural_map/test/ocean_seam_check.tscn
## ============================================================================

var _map: ProceduralMapSystem
var _cam: Camera3D
var _frame := 0
var _idx := 0
var _ready_shots := false
var _shots: Array = []


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	# Sol + cielo (instanciamos el sistema pelado, sin la escena .tscn del sol).
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
	sun.rotation_degrees = Vector3(-38.0, -70.0, 0.0)
	sun.light_energy = 1.3
	add_child(sun)
	_map = ProceduralMapSystem.new()
	var cfg := MapGenerationConfig.new()
	cfg.num_points = 600
	cfg.map_size = 400.0
	cfg.ocean_points = 200
	cfg.ocean_distance = 150.0
	cfg.num_rivers = 4
	_map.config = cfg
	_map.generate_vegetation = false
	_map.spawn_test_train = false
	_map.bake_navmesh = false
	_map.generate_spawn_points = false
	add_child(_map)
	_map.generation_completed.connect(_on_done, CONNECT_ONE_SHOT)


func _on_done(_ms: float) -> void:
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.current = true
	add_child(_cam)
	# Punto de mar a ~70 m de la costa (zona de transición fino↔grueso ≈ 48 m).
	var b := _map.sampler.bounds
	var sea_pt := Vector2.ZERO
	var best := INF
	var z := b.position.y
	while z < b.end.y:
		var x := b.position.x
		while x < b.end.x:
			var p := Vector2(x, z)
			x += 8.0
			if not _map.sea_mask.is_sea(p):
				continue
			# distancia aproximada a tierra: busca la celda no-mar más cercana en cruz
			var d := INF
			for r in range(8, 120, 8):
				for off: Vector2 in [Vector2(r, 0), Vector2(-r, 0), Vector2(0, r), Vector2(0, -r)]:
					if not _map.sea_mask.is_sea(p + off):
						d = minf(d, float(r))
				if d < INF:
					break
			if absf(d - 70.0) < best:
				best = absf(d - 70.0)
				sea_pt = p
		z += 8.0
	_shots = [
		# Rasante mirando a la costa (cruza la costura fino↔grueso de frente).
		{"pos": Vector3(sea_pt.x, 2.2, sea_pt.y), "look": Vector3(0, 0, 0), "name": "grazing"},
		# Elevada mirando el mar abierto (bloques gruesos en masa).
		{"pos": Vector3(sea_pt.x, 26.0, sea_pt.y), "look": Vector3(sea_pt.x * 1.6, 0, sea_pt.y * 1.6), "name": "open"},
	]
	_ready_shots = true


func _process(_d: float) -> void:
	if not _ready_shots:
		return
	_frame += 1
	if _idx >= _shots.size():
		print("OCEAN_SEAM_CHECK: DONE")
		get_tree().quit(0)
		return
	var s: Dictionary = _shots[_idx]
	_cam.position = s.pos
	_cam.look_at(s.look, Vector3.UP)
	if _frame % 25 == 0:
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://systems/procedural_map/test/_ocean_seam_%s.png" % s.name)
		print("  shot %s guardado" % s.name)
		_idx += 1
