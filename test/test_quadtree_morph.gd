extends Node3D

## ============================================================================
## test_quadtree_morph.gd · Guardián F5 (morphing CDLOD — params de materiales)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_quadtree_morph.tscn
## Verifica el CABLEADO (el suavizado visual se comprueba en el juego):
##   1. Materiales por profundidad construidos con morph_grid_m = s/(GRID_N-1).
##   2. morph_origin = area_min (el lattice al que se snapea).
##   3. morph_enabled sigue el toggle `morph` (on/off en vivo).
##   4. Rango de morph coherente (lo < hi, hi crece con la profundidad grande).
##   5. Una hoja global usa un material por profundidad (no el base pelado).
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
	var base := ShaderMaterial.new()
	base.shader = TERRAIN_SHADER
	var q := QTreeLod.new()
	q.area_size_m = area
	q.area_center = Vector2(area * 0.5, area * 0.5)   # area_min = (0,0)
	q.min_cell_m = 0.0
	q.max_depth = 6
	q.split_factor = 1.0
	q.morph = true
	q.set_process(false)
	add_child(q)
	q.setup(base)

	# 1/2. Params por profundidad.
	var ok_grid := true
	var ok_origin := true
	for d in q.max_depth + 1:
		var m: ShaderMaterial = q._depth_material[d]
		if m == null:
			ok_grid = false
			continue
		var expect_grid: float = (area / pow(2.0, d)) / float(17 - 1)
		if absf(float(m.get_shader_parameter(&"morph_grid_m")) - expect_grid) > 0.001:
			ok_grid = false
		var orig: Vector2 = m.get_shader_parameter(&"morph_origin")
		if not orig.is_equal_approx(Vector2(0.0, 0.0)):
			ok_origin = false
	_check("morph_grid_por_depth", ok_grid)
	_check("morph_origin_area_min", ok_origin)

	# 3. Toggle en vivo.
	var m3: ShaderMaterial = q._depth_material[3]
	_check("morph_on", m3.get_shader_parameter(&"morph_enabled") == true)
	q.morph = false
	_check("morph_off_toggle", m3.get_shader_parameter(&"morph_enabled") == false)
	q.morph = true

	# 4. Rango coherente (lo < hi).
	var mlo: float = m3.get_shader_parameter(&"morph_lo")
	var mhi: float = m3.get_shader_parameter(&"morph_hi")
	_check("rango_coherente", mlo < mhi and mlo > 0.0, "lo=%.1f hi=%.1f" % [mlo, mhi])

	# 5. Una hoja global usa un material por profundidad.
	q.update_for(Vector3(area * 0.5, 0.0, area * 0.5))
	var used_depth_mat := false
	for ch in q.get_children():
		if ch is MeshInstance3D:
			var mm: Variant = (ch as MeshInstance3D).material_override
			if q._depth_material.has(mm):
				used_depth_mat = true
				break
	_check("hoja_usa_material_depth", used_depth_mat)

	_report()


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("QUADTREE_MORPH_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
