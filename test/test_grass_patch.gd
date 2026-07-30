extends Node3D

## ============================================================================
## test_grass_patch.gd · Unit de GrassPatchSystem (refactor a WorkerThreadPool)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_grass_patch.tscn
## El sistema real solo corre con cámara (headless inactivo), así que testeamos
## la FUNCIÓN PURA _compute_patch_transforms (la que ahora corre en worker):
## 1. Determinismo — misma celda dos veces ⇒ transforms idénticas (MP-safe).
## 2. Filtros — ninguna mata sobre agua/calzada/vía ni bajo el mar ni en pendiente.
## 3. Densidad — celdas de campo producen matas (no todo vacío).
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
	add_child(map)
	await map.generation_completed

	var gp := GrassPatchSystem.new()
	gp.sampler = map.sampler
	gp.topology = map.topology
	gp.sea_level = map.sea_level
	gp.blade_mesh = FloraFactory.make_grass_tuft()
	# data_provider = null → una sola mata (evita la caché de bioma no thread-safe
	# en el test; el cómputo de transforms es idéntico).

	# Recolectar celdas de TIERRA con topología de pasto (FIELD/FOREST): la isla
	# está centrada en el origen; muestrear desde la esquina caía en océano.
	var span := 14.0  # GrassPatchSystem.CELL
	var cells: Array[Vector2i] = []
	var seen := {}
	var b := map.sampler.bounds
	var probe := b.position
	var pz := b.position.y
	while pz < b.end.y and cells.size() < 40:
		var px := b.position.x
		while px < b.end.x and cells.size() < 40:
			var p := Vector2(px, pz)
			px += span
			if map.sampler.get_height(p) < SEA + 1.0:
				continue
			if not map.topology.has_any(p, TopologyMap.TOPO_FIELD
					| TopologyMap.TOPO_FOREST | TopologyMap.TOPO_FORESTSIDE):
				continue
			var cell := Vector2i(int(floorf(p.x / span)), int(floorf(p.y / span)))
			if seen.has(cell):
				continue
			seen[cell] = true
			cells.append(cell)
		pz += span

	# ---- 1. Determinismo: dos cómputos de la misma celda ⇒ idénticos ----
	var det_ok := true
	var total_blades := 0
	var cells_with_grass := 0
	var bad_placement := 0
	for cell in cells:
		var r1: Array = [null]
		var r2: Array = [null]
		gp._compute_patch_transforms(cell, 300, r1)
		gp._compute_patch_transforms(cell, 300, r2)
		var t1 := r1[0] as Array
		var t2 := r2[0] as Array
		if t1.size() != t2.size():
			det_ok = false
		else:
			for i in t1.size():
				if not (t1[i] as Transform3D).is_equal_approx(t2[i] as Transform3D):
					det_ok = false
					break
		if not t1.is_empty():
			cells_with_grass += 1
		total_blades += t1.size()
		# ---- 2. Filtros: cada mata en tierra firme, sin calzada/agua ----
		for tr in t1:
			var p := Vector2((tr as Transform3D).origin.x, (tr as Transform3D).origin.z)
			var h: float = map.sampler.get_height(p)
			if h < SEA + 0.29 or map.sampler.get_slope(p) > 0.5:
				bad_placement += 1
			elif map.topology.has_any(p, TopologyMap.TOPO_ROAD | TopologyMap.TOPO_RAIL
					| TopologyMap.TOPO_OCEAN | TopologyMap.TOPO_LAKE
					| TopologyMap.TOPO_RIVER):
				bad_placement += 1

	_check("determinismo", det_ok, "blades=%d" % total_blades)
	_check("filtros_placement", bad_placement == 0, "malas=%d de %d" % [bad_placement, total_blades])
	_check("hay_pasto", cells_with_grass > 0 and total_blades > 50,
			"celdas_con_pasto=%d blades=%d" % [cells_with_grass, total_blades])

	# ---- 4. Pipeline vivo: escanea en el PRIMER frame y sigue los TELEPORTS ----
	# Regresión: el escaneo solo miraba el reloj (UPDATE_S) ⇒ un spawn/captura
	# temprano salía sin pasto, y un salto de cámara dejaba los parches clavados
	# en la posición vieja (fuera de visibility_range = mundo pelado).
	var cam := Camera3D.new()
	add_child(cam)
	var home := Vector3((float(cells[0].x) + 0.5) * span, 50.0, (float(cells[0].y) + 0.5) * span)
	cam.global_position = home
	gp.camera_override = cam
	add_child(gp)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("escanea_1er_frame", gp._last_scan.is_equal_approx(Vector2(home.x, home.z)),
			"last_scan=%s" % gp._last_scan)
	for _f in 300:
		await get_tree().process_frame
		if gp.is_idle():
			break
	_check("construye_pasto", gp._total_grass > 0,
			"patches=%d briznas=%d" % [gp._patches.size(), gp._total_grass])
	var far := home + Vector3(300.0, 0.0, 300.0)
	cam.global_position = far
	await get_tree().process_frame
	await get_tree().process_frame
	_check("sigue_teleport", gp._last_scan.is_equal_approx(Vector2(far.x, far.z)) and not gp.is_idle(),
			"last_scan=%s idle=%s" % [gp._last_scan, gp.is_idle()])

	_report()


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("GRASS_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
