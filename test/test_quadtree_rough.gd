extends Node3D

## ============================================================================
## test_quadtree_rough.gd · Guardián F6 (split por rugosidad)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_quadtree_rough.tscn
##   1. Con rough_gain > 0, un mapa RUGOSO subdivide MÁS que uno PLANO (más hojas)
##      a la misma cámara → detalle donde hace falta.
##   2. rough_gain = 0 ⇒ el mapa rugoso da lo MISMO que el plano (split por
##      distancia pura) → opt-in seguro, no cambia el comportamiento por defecto.
## ============================================================================

const QTreeLod := preload("res://systems/procedural_map/terrain/quadtree_mesh_lod.gd")

var _results: Array = []
var _flat := func(_p: Vector2) -> float: return 5.0
var _rough := func(p: Vector2) -> float: return sin(p.x * 0.06) * 45.0 + cos(p.y * 0.06) * 45.0


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_run()


func _check(n: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": n, "ok": ok, "detail": detail})


func _make(rg: float, hq: Callable) -> QuadtreeMeshLOD:
	var q := QTreeLod.new()
	q.area_size_m = 2048.0
	q.area_center = Vector2(1024.0, 1024.0)
	q.min_cell_m = 0.0
	q.max_depth = 6
	q.split_factor = 1.0
	q.rough_gain = rg
	q.height_query = hq
	q.set_process(false)
	add_child(q)
	q.setup(StandardMaterial3D.new())   # dummy: solo la lógica del árbol
	return q


func _run() -> void:
	var cam := Vector3(1024.0, 0.0, 1024.0)

	# 1. rough_gain > 0: rugoso subdivide más que plano.
	var q_flat := _make(1.5, _flat)
	var q_rough := _make(1.5, _rough)
	q_flat.update_for(cam)
	q_rough.update_for(cam)
	var nf := q_flat.leaf_count()
	var nr := q_rough.leaf_count()
	_check("rugoso_mas_hojas", nr > nf, "plano=%d rugoso=%d" % [nf, nr])

	# 2. rough_gain = 0: rugoso == plano (split por distancia pura, opt-in off).
	var q_off_flat := _make(0.0, _flat)
	var q_off_rough := _make(0.0, _rough)
	q_off_flat.update_for(cam)
	q_off_rough.update_for(cam)
	var nof := q_off_flat.leaf_count()
	var nor := q_off_rough.leaf_count()
	_check("gain0_igual", nof == nor, "off_plano=%d off_rugoso=%d" % [nof, nor])

	_report()


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("QUADTREE_ROUGH_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
