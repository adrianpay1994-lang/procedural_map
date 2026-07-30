extends Node3D

## ============================================================================
## test_quadtree_frustum.gd · Guardián F-cull (poda del árbol por frustum)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_quadtree_frustum.tscn
## Cámara en el centro mirando -Z: las celdas del FRENTE se construyen, las de
## ATRÁS NO ("NOT VISIBLE TO CAMERA"). VALIDA la convención de get_frustum():
## si estuviera invertida, o no se cullea nada (atrás > 0) o se cullea todo
## (frente = 0) — el test lo caza.
## ============================================================================

const QTreeLod := preload("res://systems/procedural_map/terrain/quadtree_mesh_lod.gd")
const TERRAIN_SHADER := preload("res://shaders/TerrainPBRBiomeMap.gdshader")

var _results: Array = []


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_run()


func _check(n: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": n, "ok": ok, "detail": detail})


func _run() -> void:
	var area := 2048.0
	var cam := Camera3D.new()
	add_child(cam)
	cam.global_position = Vector3(area * 0.5, 60.0, area * 0.5)   # centro, mira -Z

	var base := ShaderMaterial.new()
	base.shader = TERRAIN_SHADER
	var q := QTreeLod.new()
	q.area_size_m = area
	q.area_center = Vector2(area * 0.5, area * 0.5)
	q.min_cell_m = 0.0
	q.max_depth = 6
	q.split_factor = 1.0
	q.morph = false
	q.frustum_cull = true
	q.frustum_margin_m = 0.0
	q.set_process(false)
	add_child(q)
	q.setup(base)

	q._frustum = cam.get_frustum()
	q.update_for(cam.global_position)

	# Contar MeshInstance VISIBLES (las hojas cullas quedan sin mi o mi.visible=false).
	var front := _count_visible(q, area * 0.5, true)
	var behind := _count_visible(q, area * 0.5 + 300.0, false)
	_check("hay_hojas_al_frente", front > 0, "frente=%d" % front)
	_check("nada_renderizado_atras", behind == 0, "atras=%d" % behind)

	# Sin frustum_cull se construye/renderiza TODO (control): debe haber hojas atrás.
	q.frustum_cull = false
	q.update_for(cam.global_position)
	var behind2 := _count_visible(q, area * 0.5 + 300.0, false)
	_check("sin_cull_si_renderiza_atras", behind2 > 0, "atras_sin_cull=%d" % behind2)

	_report()


## Cuenta MeshInstance3D VISIBLES con position.z < z_lim (front=true) o > z_lim (front=false).
func _count_visible(q: Node, z_lim: float, front: bool) -> int:
	var n := 0
	for ch in q.get_children():
		if ch is MeshInstance3D and (ch as MeshInstance3D).visible:
			var z: float = (ch as MeshInstance3D).position.z
			if front and z < z_lim:
				n += 1
			elif not front and z > z_lim:
				n += 1
	return n


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("QUADTREE_FRUSTUM_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
