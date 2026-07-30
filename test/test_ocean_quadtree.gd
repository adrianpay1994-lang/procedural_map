extends Node3D

## ============================================================================
## test_ocean_quadtree.gd · Guardián F3 (océano por QuadtreeMeshLOD)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_ocean_quadtree.tscn
## Con ocean_quadtree ON:
##   1. Existe el nodo "Ocean" (OceanSystem, oleaje FFT) y el "OceanPlane"
##      clásico queda oculto. El océano viejo quedó en _descartado/.
##   2. El océano materializa hojas con material que DESPLAZA (clipmap_displace).
##   3. El shader del océano COMPILA (si no, la generación falla arriba).
## Restaura Settings al final.
## ============================================================================

var _results: Array = []
var _prev: Variant = null


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_run()


func _check(n: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": n, "ok": ok, "detail": detail})


func _run() -> void:
	if typeof(Settings) == TYPE_NIL or Settings == null:
		_check("settings", false, "sin autoload Settings")
		_report()
		return
	_prev = Settings.get_value(&"graphics", &"ocean_quadtree", false)
	Settings.set_value(&"graphics", &"ocean_quadtree", true, false)

	var map := ProceduralMapSystem.new()
	var cfg := MapGenerationConfig.new()
	cfg.num_points = 1200
	cfg.map_size = 500.0
	cfg.ocean_points = 300
	cfg.ocean_distance = 200.0
	map.config = cfg
	map.terrain_settings = TerrainSettings.new()
	map.generate_vegetation = false
	map.spawn_test_train = false
	map.bake_navmesh = false
	map.generate_spawn_points = false
	add_child(map)
	await map.generation_completed

	var oq := map.find_child("Ocean", true, false)
	var plane := map.find_child("OceanPlane", true, false) as Node3D
	_check("ocean_quadtree_existe", oq != null)
	_check("ocean_plane_oculto", plane == null or not plane.visible,
			"OceanPlane visible=%s" % (str(plane.visible) if plane != null else "n/a"))

	var leaves := 0
	var disp_ok := false
	if oq != null:
		oq.update_for(Vector3(oq.area_center.x, 0.0, oq.area_center.y))
		# El OceanSystem tiene la malla adentro (superficie); se inspecciona esa.
		var surf: QuadtreeMeshLOD = oq.surface_quadtree()
		if surf != null:
			for ch in surf.get_children():
				if ch is MeshInstance3D:
					leaves += 1
					var m: Variant = (ch as MeshInstance3D).material_override
					if m is ShaderMaterial and bool((m as ShaderMaterial).get_shader_parameter(&"clipmap_displace")):
						disp_ok = true
	_check("ocean_materializa_hojas", leaves > 0, "hojas=%d" % leaves)
	_check("ocean_desplaza", disp_ok, "material con clipmap_displace=true (olas)")

	# Pseudo-infinito: el área del océano EXCEDE el mapa (borde lejos + niebla).
	var map_side: float = maxf(map.sampler.bounds.size.x, map.sampler.bounds.size.y)
	var ok_infinito: bool = oq != null and float(oq.area_size_m) > map_side * 1.5
	_check("ocean_pseudo_infinito", ok_infinito,
			"oceano=%.0f mapa=%.0f" % [float(oq.area_size_m) if oq != null else 0.0, map_side])

	_report()


func _report() -> void:
	if typeof(Settings) != TYPE_NIL and Settings != null and _prev != null:
		Settings.set_value(&"graphics", &"ocean_quadtree", _prev, false)
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("OCEAN_QUADTREE_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
