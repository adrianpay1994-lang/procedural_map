extends Node3D

## ============================================================================
## test_quadtree_lod.gd · Guardián del QuadtreeMeshLOD (Camino B)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_quadtree_lod.tscn
## Invariantes:
##   1. FALDONES: cada malla por profundidad tiene más índices que la grilla sola.
##   2. PRESUPUESTO FIJO: las hojas cerca de la cámara NO escalan con el tamaño
##      del mundo (4× área + 1 nivel ⇒ casi el mismo nº de hojas).
##   3. FINO CERCA / GRUESO LEJOS: hay hoja a max_depth pegada al foco y hojas
##      gruesas (nivel bajo) lejos.
##   4. ESTABILIDAD: ir lejos y volver deja el MISMO estado (histéresis correcta).
## ============================================================================

## preload (no por class_name): un class_name recién agregado no está en el
## global_script_class_cache hasta un reescaneo del editor; correr una escena
## headless NO reescanea. preload lo resuelve directo.
const QTreeLod := preload("res://systems/procedural_map/terrain/quadtree_mesh_lod.gd")

var _results: Array = []


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_run()


func _check(check_name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": check_name, "ok": ok, "detail": detail})


func _make(area: float, depth: int) -> QTreeLod:
	var q := QTreeLod.new()
	q.area_size_m = area
	q.area_center = Vector2.ZERO
	q.min_cell_m = 0.0   # usar max_depth explícito (no derivar)
	q.max_depth = depth
	q.set_process(false)   # el test maneja el update a mano
	add_child(q)
	q.setup(StandardMaterial3D.new())   # material dummy: solo para construir mallas
	return q


func _run() -> void:
	# --- 1. Faldones ---
	var q := _make(2048.0, 6)
	var side := 17
	var grid_only := (side - 1) * (side - 1) * 6
	var m0 := q._depth_mesh[0] as ArrayMesh
	var idx0 := (m0.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	_check("faldones", idx0 > grid_only, "idx=%d grid=%d" % [idx0, grid_only])

	# --- 2. Presupuesto fijo (independiente del tamaño del mundo) ---
	# Ambos con hoja mínima = 32 m (area/2^depth), pero qb cubre 4× el área.
	var qa := _make(2048.0, 6)
	var qb := _make(4096.0, 7)
	qa.update_for(Vector3.ZERO)
	qb.update_for(Vector3.ZERO)
	var na := qa.leaf_count()
	var nb := qb.leaf_count()
	# Invariante FIJO = SUB-LINEAL: cubrir 4× el mundo (1 nivel más) agrega un
	# ANILLO grueso constante, NO multiplica. Si escalara con el área, nb ≈ 4·na.
	_check("budget_sublineal", nb - na < na / 2, "a=%d b=%d (4x mundo)" % [na, nb])
	_check("budget_no_escala", nb < na * 2, "a=%d b=%d" % [na, nb])

	# --- 3. Fino cerca / grueso lejos (profundidad media, no absolutos) ---
	qa.update_for(Vector3.ZERO)
	var deep_near := false
	var near_sum := 0
	var near_n := 0
	var far_sum := 0
	var far_n := 0
	for l: Dictionary in qa.debug_leaves():
		var dist: float = Vector2(l.cx, l.cz).length()
		var dep := int(l.depth)
		if dep == qa.max_depth and dist < 120.0:
			deep_near = true
		if dist < 200.0:
			near_sum += dep; near_n += 1
		elif dist > 600.0:
			far_sum += dep; far_n += 1
	_check("fino_cerca", deep_near, "hoja max_depth pegada al foco")
	var near_avg := float(near_sum) / maxi(near_n, 1)
	var far_avg := float(far_sum) / maxi(far_n, 1)
	_check("grueso_lejos", far_n > 0 and far_avg < near_avg,
			"prof media cerca=%.1f lejos=%.1f" % [near_avg, far_avg])

	# --- 4. Estabilidad (ir lejos y volver = mismo estado) ---
	qa.update_for(Vector3.ZERO)
	var n1 := qa.leaf_count()
	qa.update_for(Vector3(1600.0, 0.0, 1600.0))
	qa.update_for(Vector3.ZERO)
	var n2 := qa.leaf_count()
	_check("estable", n1 == n2, "n1=%d n2=%d" % [n1, n2])

	_report()


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("QUADTREE_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
