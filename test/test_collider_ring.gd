extends Node3D

## ============================================================================
## test_collider_ring.gd · Guardián del anillo de colisión (16KM-4)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_collider_ring.tscn
## 1. Con collider_ring_enabled: hay piso BAJO el target, y NO hay collider
##    lejos (fuera del anillo) — eso es lo que hace viable 16 km.
## 2. TELEPORT: mover el target lejos ⇒ aparece piso ahí y desaparece el viejo.
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
	cfg.num_rivers = 4
	map.config = cfg
	map.collider_ring_enabled = true
	map.collider_ring_radius_m = 96.0
	map.generate_vegetation = false
	map.spawn_test_train = false
	map.bake_navmesh = false
	map.generate_spawn_points = false
	add_child(map)
	await map.generation_completed

	# Dos puntos de tierra BIEN separados (> 2×(radio+chunk)).
	var pts := _two_far_land_points(map, 300.0)
	if pts.is_empty():
		_check("puntos_de_tierra", false, "no hay 2 puntos separados")
		_report()
		return
	var a: Vector2 = pts[0]
	var b: Vector2 = pts[1]

	var ring := map.find_child("TerrainColliderRing", true, false) as TerrainColliderRing
	_check("ring_existe", ring != null)
	var tgt := Node3D.new()
	add_child(tgt)
	tgt.global_position = Vector3(a.x, map.sampler.get_height(a) + 2.0, a.y)
	ring.target = tgt
	await _settle()

	# ---- 1. Piso bajo el target; NADA en el punto lejano ----
	_check("piso_en_target", _hits_ground(map, a), "chunks=%d" % ring.active_chunks())
	_check("sin_piso_lejos", not _hits_ground(map, b),
			"dist=%.0f m" % a.distance_to(b))

	# ---- 2. TELEPORT: el anillo se muda ----
	tgt.global_position = Vector3(b.x, map.sampler.get_height(b) + 2.0, b.y)
	await _settle()
	_check("teleport_piso_nuevo", _hits_ground(map, b), "chunks=%d" % ring.active_chunks())
	_check("teleport_suelta_viejo", not _hits_ground(map, a))

	_report()


## Espera a que el anillo actualice (UPDATE_S=0.15 + creación de shapes).
func _settle() -> void:
	for _i in 30:
		await get_tree().physics_frame


func _hits_ground(map: ProceduralMapSystem, p: Vector2) -> bool:
	var h: float = map.sampler.get_height(p)
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(p.x, h + 60.0, p.y), Vector3(p.x, h - 60.0, p.y), 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return not hit.is_empty() and absf((hit.position as Vector3).y - h) < 3.0


## Dos puntos de tierra firme separados al menos min_sep.
func _two_far_land_points(map: ProceduralMapSystem, min_sep: float) -> Array:
	var found: Array = []
	var bnd := map.sampler.bounds
	var z := bnd.position.y
	while z < bnd.end.y:
		var x := bnd.position.x
		while x < bnd.end.x:
			var p := Vector2(x, z)
			x += 12.0
			if map.sampler.get_height(p) < SEA + 1.5 or map.sea_mask.is_sea(p):
				continue
			if found.is_empty():
				found.append(p)
			elif p.distance_to(found[0]) >= min_sep:
				found.append(p)
				return found
		z += 12.0
	return []


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("RING_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
