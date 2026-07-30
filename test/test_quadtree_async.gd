extends Node3D

## ============================================================================
## test_quadtree_async.gd · Guardián F1b.7 (bake de tiles AMORTIZADO)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_quadtree_async.tscn
## Con async_bake: las hojas finas arrancan con material GLOBAL de fallback y el
## pump() hornea ≤ max_bakes_per_pump tiles por llamada; las hojas suben a tile
## cuando el suyo está listo. Al drenar la cola, TODAS las finas usan tile.
## ============================================================================

const QTreeLod := preload("res://systems/procedural_map/terrain/quadtree_mesh_lod.gd")
const RegionHeightTex := preload("res://systems/procedural_map/terrain/region_height_textures.gd")
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
	var layer := ConstHeightLayer.new()
	layer.value_m = 10.0
	layer.enabled = true
	var layers: Array[HeightLayer] = [layer]
	var rs := RegionStreamSampler.new()
	rs.setup(layers, Rect2(0.0, 0.0, area, area), 40.0, 5, null, null)

	var base := ShaderMaterial.new()
	base.shader = TERRAIN_SHADER
	var rht := RegionHeightTex.new()
	rht.setup(rs, base)
	rht.async_bake = true
	rht.max_bakes_per_pump = 2

	var q := QTreeLod.new()
	q.area_size_m = area
	q.area_center = Vector2(area * 0.5, area * 0.5)
	q.min_cell_m = 0.0
	q.max_depth = 6
	q.split_factor = 1.0
	q.region_tex = rht
	q.set_process(false)
	add_child(q)
	q.setup(base)

	var center := Vector3(area * 0.5, 0.0, area * 0.5)

	# 1er update: se encolan tiles; el pump hornea ≤2 → NO todo de una.
	q.update_for(center)
	_check("amortizado_pocos_de_una", rht.resident() <= rht.max_bakes_per_pump,
			"resident=%d (tope/pump=%d)" % [rht.resident(), rht.max_bakes_per_pump])
	_check("hay_cola_o_pendientes", rht._queue.size() > 0 or q._pending.size() > 0,
			"cola=%d pend=%d" % [rht._queue.size(), q._pending.size()])

	# Drenar: varios frames más (cada uno hornea ≤2 y mejora las hojas listas).
	for _i in 40:
		q.update_for(center)

	_check("cola_drenada", rht._queue.size() == 0, "cola=%d" % rht._queue.size())
	_check("pendientes_drenados", q._pending.size() == 0, "pend=%d" % q._pending.size())

	# Tras drenar, TODA hoja fina (depth ≥ tile_depth) usa material de tile.
	var td := q.tile_depth()
	var fine := 0
	var still_global := 0
	for ch in q.get_children():
		if not (ch is MeshInstance3D):
			continue
		var mi := ch as MeshInstance3D
		var depth: int = q._depth_mesh.find(mi.mesh)
		if depth < td:
			continue
		fine += 1
		var m: Variant = mi.material_override
		var is_tile: bool = m is ShaderMaterial and (m as ShaderMaterial).get_shader_parameter(&"use_region_tile") == true
		if not is_tile:
			still_global += 1
	_check("finas_subieron_a_tile", fine > 0 and still_global == 0,
			"finas=%d aun_global=%d" % [fine, still_global])

	_report()


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("QUADTREE_ASYNC_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
