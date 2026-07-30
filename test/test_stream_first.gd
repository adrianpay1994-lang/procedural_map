extends Node3D

## ============================================================================
## test_stream_first.gd · Guardián del streaming view-first (F1) + quadtree (F4)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_stream_first.tscn
## Con graphics/terrain_stream_first + terrain_quadtree ON:
##   1. El nodo "Terrain" existe pero está VACÍO (chunks omitidos = no se construyó
##      la malla del mapa entero).
##   2. Existe "TerrainQuadtree" (el render por cámara está activo).
## Compara contra el default (sin flags): "Terrain" con chunks.
## Restaura Settings al final (no ensucia la config real).
## ============================================================================

var _results: Array = []
var _prev_qt: Variant = null
var _prev_sf: Variant = null
var _prev_rs: Variant = null


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_run()


func _check(n: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": n, "ok": ok, "detail": detail})


func _cfg() -> MapGenerationConfig:
	var cfg := MapGenerationConfig.new()
	# Mapa grande (>2048 m) para que el gate de F1b active los tiles de región
	# (a 3000 m el global es ~2.9 m/texel, los tiles 2 m/texel → ayudan).
	cfg.num_points = 1500
	cfg.map_size = 3000.0
	cfg.ocean_points = 400
	cfg.ocean_distance = 400.0
	cfg.num_rivers = 3
	return cfg


func _make_map() -> ProceduralMapSystem:
	var map := ProceduralMapSystem.new()
	map.config = _cfg()
	map.terrain_settings = TerrainSettings.new()
	map.generate_vegetation = false
	map.spawn_test_train = false
	map.bake_navmesh = false
	map.generate_spawn_points = false
	return map


func _run() -> void:
	if typeof(Settings) == TYPE_NIL or Settings == null:
		_check("settings_disponible", false, "sin autoload Settings")
		_report()
		return
	# Guardar y activar los flags.
	_prev_qt = Settings.get_value(&"graphics", &"terrain_quadtree", false)
	_prev_sf = Settings.get_value(&"graphics", &"terrain_stream_first", false)
	_prev_rs = Settings.get_value(&"graphics", &"terrain_region_stream", false)
	Settings.set_value(&"graphics", &"terrain_quadtree", true, false)
	Settings.set_value(&"graphics", &"terrain_stream_first", true, false)
	Settings.set_value(&"graphics", &"terrain_region_stream", true, false)

	var map := _make_map()
	add_child(map)
	await map.generation_completed

	var terrain := map.find_child("Terrain", true, false)
	var qt := map.find_child("TerrainQuadtree", true, false)
	_check("terrain_existe", terrain != null)
	_check("chunks_omitidos", terrain != null and terrain.get_child_count() == 0,
			"hijos=%d (esperado 0)" % (terrain.get_child_count() if terrain != null else -1))
	_check("quadtree_activo", qt != null, "TerrainQuadtree presente")

	# El quadtree solo materializa hojas cuando hay cámara (headless no tiene): las
	# forzamos con update_for y verificamos que llevan el material de desplazamiento.
	var leaves := 0
	var leaf_mat_ok := false
	var tile_leaves := 0
	if qt != null:
		qt.update_for(Vector3(qt.area_center.x, 0.0, qt.area_center.y))
		for ch in qt.get_children():
			if ch is MeshInstance3D:
				leaves += 1
				var m: Variant = (ch as MeshInstance3D).material_override
				if m is ShaderMaterial:
					var sm := m as ShaderMaterial
					if bool(sm.get_shader_parameter(&"clipmap_displace")):
						leaf_mat_ok = true
					if sm.get_shader_parameter(&"use_region_tile") == true:
						tile_leaves += 1
	_check("quadtree_materializa_hojas", leaves > 0, "hojas=%d" % leaves)
	_check("hojas_desplazan", leaf_mat_ok, "material con clipmap_displace=true")
	# F1b: con terrain_region_stream, el quadtree recibe region_tex y las hojas finas
	# (cámara en el centro → todas finas) usan tiles de alta resolución.
	_check("region_tex_cableado", qt != null and qt.region_tex != null, "region_tex presente")
	_check("hay_hoja_tile", tile_leaves > 0, "hojas_tile=%d" % tile_leaves)

	_report()


func _report() -> void:
	# Restaurar Settings (no ensuciar la config real).
	if typeof(Settings) != TYPE_NIL and Settings != null:
		if _prev_qt != null:
			Settings.set_value(&"graphics", &"terrain_quadtree", _prev_qt, false)
		if _prev_sf != null:
			Settings.set_value(&"graphics", &"terrain_stream_first", _prev_sf, false)
		if _prev_rs != null:
			Settings.set_value(&"graphics", &"terrain_region_stream", _prev_rs, false)
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("STREAM_FIRST_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
