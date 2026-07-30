extends Node3D

## ============================================================================
## test_collider_fall.gd · Detector de "traspaso el suelo" (reporte del usuario)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_collider_fall.tscn
## 1. Genera un mapa chico COMPLETO (colliders incluidos).
## 2. RAYCAST SWEEP: barre toda la tierra con rayos verticales — cada rayo debe
##    pegar en el collider a ±2 m de la altura del sampler. Miss = AGUJERO
##    (posición reportada). Detecta huecos estáticos de HeightMapShape3D.
## 3. CUERPOS: deja caer esferas rígidas sobre tierra y simula ~2 s — ninguna
##    puede quedar bajo el terreno (tunneling de Jolt).
## ============================================================================

const SEA := 0.0

var _results: Array = []


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_run()


func _check(check_name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": check_name, "ok": ok, "detail": detail})


func _run() -> void:
	var map := ProceduralMapSystem.new()
	var cfg := MapGenerationConfig.new()
	cfg.num_points = 600
	cfg.map_size = 400.0
	cfg.ocean_points = 200
	cfg.ocean_distance = 150.0
	cfg.num_rivers = 6
	map.config = cfg
	map.generate_vegetation = false
	map.spawn_test_train = false
	map.bake_navmesh = false
	add_child(map)  # _ready lanza generate_map
	await map.generation_completed
	await get_tree().physics_frame
	await get_tree().physics_frame

	_raycast_sweep(map)
	await _drop_bodies(map)
	_check_water_volumes(map)
	_report()


## El volumen de nado del océano debe cubrir el MAR y NO la tierra seca bajo
## cota 0 (depresiones/lechos) — causa raíz del "traspaso el suelo, caigo al agua".
func _check_water_volumes(map: ProceduralMapSystem) -> void:
	var vols := map.find_child("WaterVolumes", true, false)
	if vols == null:
		_check("volumen_oceano", false, "sin nodo WaterVolumes")
		return
	var ocean := vols.find_child("WaterVol_ocean", false, false) as Node3D
	if ocean == null:
		_check("volumen_oceano", false, "sin WaterVol_ocean")
		return
	# Cajas del océano en mundo (XZ).
	var boxes: Array[Rect2] = []
	for c in ocean.get_children():
		var cs := c as CollisionShape3D
		if cs == null or not (cs.shape is BoxShape3D):
			continue
		var size: Vector3 = (cs.shape as BoxShape3D).size
		var center: Vector3 = ocean.position + cs.position
		boxes.append(Rect2(Vector2(center.x - size.x * 0.5, center.z - size.z * 0.5),
				Vector2(size.x, size.z)))
	# Punto de MAR profundo → debe estar cubierto.
	var b := map.sampler.bounds
	var sea_pt := Vector2.INF
	var dry_low := Vector2.INF
	var y := b.position.y
	while y < b.end.y:
		var x := b.position.x
		while x < b.end.x:
			var p := Vector2(x, y)
			x += 6.0
			var h: float = map.sampler.get_height(p)
			if sea_pt == Vector2.INF and h < SEA - 3.0 and map.sea_mask.is_sea(p):
				sea_pt = p
			# Tierra SECA bajo el mar: hondo pero NO conectado al borde.
			if dry_low == Vector2.INF and h < SEA - 0.5 and not map.sea_mask.is_sea(p):
				dry_low = p
		y += 6.0
	var sea_ok := sea_pt != Vector2.INF and _in_any(sea_pt, boxes)
	_check("volumen_oceano_cubre_mar", sea_ok,
			"sea_pt=%s boxes=%d" % [str(sea_pt), boxes.size()])
	if dry_low == Vector2.INF:
		_check("volumen_no_invade_tierra", true, "n/a (sin depresiones bajo 0 en este seed)")
	else:
		_check("volumen_no_invade_tierra", not _in_any(dry_low, boxes),
				"dry_low=%s" % str(dry_low))


func _in_any(p: Vector2, boxes: Array[Rect2]) -> bool:
	for r in boxes:
		if r.has_point(p):
			return true
	return false


## Barrido de rayos sobre TODA la tierra (paso 6 m). Sin agujeros permitidos.
func _raycast_sweep(map: ProceduralMapSystem) -> void:
	var space := get_world_3d().direct_space_state
	var b := map.sampler.bounds
	var holes := 0
	var mismatches := 0
	var tested := 0
	var first_holes: Array[Vector2] = []
	var y := b.position.y
	while y < b.end.y:
		var x := b.position.x
		while x < b.end.x:
			var p := Vector2(x, y)
			x += 6.0
			var h: float = map.sampler.get_height(p)
			# Solo tierra firme (el mar de verdad no tiene collider por diseño).
			if h < SEA + 0.3 or map.sea_mask.is_sea(p):
				continue
			tested += 1
			var q := PhysicsRayQueryParameters3D.create(
					Vector3(p.x, h + 100.0, p.y), Vector3(p.x, h - 100.0, p.y), 1)
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				holes += 1
				if first_holes.size() < 6:
					first_holes.append(p)
			elif absf((hit.position as Vector3).y - h) > 2.0:
				mismatches += 1
				if first_holes.size() < 6:
					first_holes.append(p)
		y += 6.0
	var detail := "tested=%d holes=%d mismatch=%d" % [tested, holes, mismatches]
	if not first_holes.is_empty():
		detail += " en %s" % [str(first_holes)]
	_check("sin_agujeros_collider", tested > 300 and holes == 0, detail)
	_check("collider_coincide_visual", mismatches == 0, detail)


## Esferas rígidas sobre puntos de tierra deterministas: tras ~2 s de física
## ninguna puede estar bajo el terreno (tunneling) ni bajo el mar.
func _drop_bodies(map: ProceduralMapSystem) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var b := map.sampler.bounds
	var bodies: Array = []
	var attempts := 0
	while bodies.size() < 12 and attempts < 400:
		attempts += 1
		var p := Vector2(rng.randf_range(b.position.x, b.end.x),
				rng.randf_range(b.position.y, b.end.y))
		var h: float = map.sampler.get_height(p)
		if h < SEA + 0.5 or map.sea_mask.is_sea(p):
			continue
		var body := RigidBody3D.new()
		body.collision_layer = 2
		body.collision_mask = 1  # choca contra "world"
		var cs := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 0.4
		cs.shape = sphere
		body.add_child(cs)
		body.position = Vector3(p.x, h + 5.0, p.y)
		add_child(body)
		bodies.append({"body": body, "ground": h})
	for _i in 120:
		await get_tree().physics_frame
	var sunk := 0
	var detail := ""
	for e in bodies:
		var body := e.body as RigidBody3D
		# Hundido = bajo el TERRENO EN SU POSICIÓN FINAL (las esferas ruedan
		# cuesta abajo — terminar en el lecho de un río NO es atravesar el suelo).
		var final_ground: float = map.sampler.get_height(
				Vector2(body.global_position.x, body.global_position.z))
		if body.global_position.y < final_ground - 1.5:
			sunk += 1
			if detail.length() < 120:
				detail += " (%.0f,%.0f)y=%.1f suelo=%.1f" % [body.global_position.x,
						body.global_position.z, body.global_position.y, final_ground]
	_check("cuerpos_no_se_hunden", bodies.size() >= 8 and sunk == 0,
			"bodies=%d hundidos=%d%s" % [bodies.size(), sunk, detail])


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("FALL_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
