extends Node

## ============================================================================
## test_config_matrix.gd · TODAS las combinaciones de config generan (backlog)
## ============================================================================
## Verifica lo prometido en el menú/Inspector: cada forma de isla × cada tipo
## de polígono produce un grafo con tierra y un heightfield válido.
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_config_matrix.tscn --quit-after 20000
## ============================================================================

const SHAPES := ["radial", "perlin", "square", "blob"]
const POINT_MODES := ["relaxed", "hexagon", "square", "random"]

var _results: Array = []


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	for shape in SHAPES:
		for mode in POINT_MODES:
			_try_combo(shape, mode)
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s" % r.name)
	var all_ok := passed == _results.size()
	print("CONFIG_MATRIX: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)


func _try_combo(shape: String, mode: String) -> void:
	var name := "%s+%s" % [shape, mode]
	var cfg := MapGenerationConfig.new()
	cfg.island_shape = shape
	cfg.point_mode = mode
	cfg.num_points = 400
	cfg.map_size = 250.0
	cfg.ocean_points = 100
	cfg.ocean_distance = 80.0
	cfg.num_rivers = 3
	var provider := MapDataProvider.new()
	add_child(provider)
	provider.generate(cfg)
	var land := provider.get_land_centers().size()
	var sampler := HeightSampler.new()
	var layers: Array[HeightLayer] = [VoronoiBaseLayer.new(), NoiseHeightLayer.new()]
	sampler.setup(provider.graph, layers, provider.get_map_bounds(),
			cfg.height_scale, cfg.seed_variant, provider.query)
	sampler.bake(257)
	var range_ok: Vector2 = sampler.get_height_range()
	var ok := land > 30 and range_ok.y > 3.0 and range_ok.x < 0.0
	_results.append({"name": "%s land=%d rango=(%.1f, %.1f)" % [name, land, range_ok.x, range_ok.y], "ok": ok})
	provider.queue_free()
