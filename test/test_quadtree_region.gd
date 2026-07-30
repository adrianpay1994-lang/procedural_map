extends Node3D

## ============================================================================
## test_quadtree_region.gd · Guardián F1b.4 (quadtree elige tile vs global)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_quadtree_region.tscn
## Con region_tex inyectado: toda hoja FINA (depth ≥ tile_depth) lleva material con
## use_region_tile=true (tile de alta res); toda hoja GRUESA (depth < tile_depth)
## lleva el material global. Cámara en una ESQUINA para que existan ambas.
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
	layer.value_m = 8.0
	layer.enabled = true
	var layers: Array[HeightLayer] = [layer]
	var rs := RegionStreamSampler.new()
	rs.setup(layers, Rect2(0.0, 0.0, area, area), 40.0, 7, null, null)

	var base := ShaderMaterial.new()
	base.shader = TERRAIN_SHADER
	var rht := RegionHeightTex.new()
	rht.setup(rs, base)

	var q := QTreeLod.new()
	q.area_size_m = area
	q.area_center = Vector2(area * 0.5, area * 0.5)   # área en [0, area]; esquina en (0,0)
	q.min_cell_m = 0.0
	q.max_depth = 6
	q.split_factor = 1.0
	q.region_tex = rht
	q.set_process(false)
	add_child(q)
	q.setup(base)

	var td := q.tile_depth()
	# area 2048 / region_m 512 = 4 → tile_depth = ceil(log2 4) = 2.
	_check("tile_depth", td == 2, "tile_depth=%d (esperado 2)" % td)

	# Cámara en la esquina (0,0): fino pegado a la esquina, grueso en la opuesta.
	q.update_for(Vector3(0.0, 0.0, 0.0))

	var fine := 0
	var coarse := 0
	var mismatches := 0
	for ch in q.get_children():
		if not (ch is MeshInstance3D):
			continue
		var mi := ch as MeshInstance3D
		var depth: int = q._depth_mesh.find(mi.mesh)
		var m: Variant = mi.material_override
		# get_shader_parameter devuelve null si nunca se seteó (material global) →
		# comparar con true maneja null sin crashear (bool(null) no existe).
		var is_tile := false
		if m is ShaderMaterial:
			is_tile = (m as ShaderMaterial).get_shader_parameter(&"use_region_tile") == true
		var should_tile := depth >= td
		if is_tile != should_tile:
			mismatches += 1
		if should_tile:
			fine += 1
		else:
			coarse += 1

	_check("hay_hojas_finas", fine > 0, "finas=%d" % fine)
	_check("hay_hojas_gruesas", coarse > 0, "gruesas=%d" % coarse)
	_check("material_por_profundidad", mismatches == 0, "mismatches=%d" % mismatches)

	_report()


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("QUADTREE_REGION_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
