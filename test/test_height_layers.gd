extends Node

## ============================================================================
## test_height_layers.gd · Unit del núcleo de altura (PROCEDURAL_MAP_PLAN.md §13.1)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_height_layers.tscn --quit-after 60000
## Imprime "HEIGHT_TEST: PASS (n/n)" o "HEIGHT_TEST: FAIL" y sale (0/1).
## ============================================================================

const BAKE_RES := 257

var _results: Array = []


func _ready() -> void:
	# smoke.tscn instancia TODO res://systems — no correr (ni hacer quit) ahí.
	if get_tree().current_scene != self:
		return
	_run_all()
	_report()


func _check(check_name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": check_name, "ok": ok, "detail": detail})


func _make_config() -> MapGenerationConfig:
	var cfg := MapGenerationConfig.new()
	cfg.num_points = 600
	cfg.map_size = 400.0
	cfg.ocean_points = 200
	cfg.ocean_distance = 150.0
	cfg.height_scale = 40.0
	cfg.num_rivers = 6
	return cfg


func _build_sampler(cfg: MapGenerationConfig, layers: Array[HeightLayer],
		provider_out: Array = []) -> HeightSampler:
	var provider := MapDataProvider.new()
	add_child(provider)
	provider.generate(cfg)
	provider_out.append(provider)
	var sampler := HeightSampler.new()
	sampler.setup(provider.graph, layers, provider.get_map_bounds(),
			cfg.height_scale, cfg.seed_variant, provider.query)
	return sampler


func _land_point(provider: MapDataProvider, min_elev: float = 0.3) -> Vector2:
	for c in provider.graph.centers:
		var cc := c as Center
		if not cc.water and cc.elevation >= min_elev:
			return cc.point
	return Vector2.ZERO


func _run_all() -> void:
	var cfg := _make_config()

	# ---- 1. Determinismo: dos bakes independientes ⇒ arrays idénticos ----
	var s1 := _build_sampler(cfg, [VoronoiBaseLayer.new(), NoiseHeightLayer.new()])
	s1.bake(BAKE_RES)
	var s2 := _build_sampler(cfg, [VoronoiBaseLayer.new(), NoiseHeightLayer.new()])
	s2.bake(BAKE_RES)
	var h1 := s1.get_heights_raw()
	var h2 := s2.get_heights_raw()
	var same := h1.size() == h2.size()
	if same:
		for i in h1.size():
			if h1[i] != h2[i]:
				same = false
				break
	_check("determinismo", same)

	# ---- 2. Base sola: interior más alto que océano; océano bajo 0 ----
	var pv: Array = []
	var base := _build_sampler(cfg, [VoronoiBaseLayer.new()], pv)
	var provider: MapDataProvider = pv[0]
	base.bake(BAKE_RES)
	var land := _land_point(provider)
	var ocean_pt := provider.get_map_bounds().position + Vector2(4, 4)  # esquina = océano
	_check("base_isla", base.get_height(land) > 1.0 and base.get_height(ocean_pt) < 0.0,
			"land=%.2f ocean=%.2f" % [base.get_height(land), base.get_height(ocean_pt)])

	# ---- 3. Máscara circular: fuera del círculo+falloff el campo NO cambia ----
	var noise := NoiseHeightLayer.new()
	noise.amplitude_m = 10.0
	var m := CircleMask.new()
	m.center = land
	m.radius_m = 30.0
	m.falloff_m = 15.0
	noise.mask = m
	var masked := HeightSampler.new()
	masked.setup(provider.graph, [VoronoiBaseLayer.new(), noise],
			provider.get_map_bounds(), cfg.height_scale, cfg.seed_variant, provider.query)
	masked.bake(BAKE_RES)
	var far_pt := land + Vector2(80, 0)
	var delta_far := absf(masked.get_height(far_pt) - base.get_height(far_pt))
	var delta_in := absf(masked.get_height(land) - base.get_height(land))
	_check("mascara_circulo", delta_far < 0.005 and delta_in > 0.005,
			"far=%.4f in=%.4f" % [delta_far, delta_in])

	# ---- 4. Flatten: centro clavado al target, falloff monótono ----
	var flat := FlattenHeightLayer.new()
	flat.target_height_m = 12.0
	var fm := CircleMask.new()
	fm.center = land
	fm.radius_m = 25.0
	fm.falloff_m = 20.0
	flat.mask = fm
	var flat_s := HeightSampler.new()
	flat_s.setup(provider.graph, [VoronoiBaseLayer.new(), flat],
			provider.get_map_bounds(), cfg.height_scale, cfg.seed_variant, provider.query)
	flat_s.bake(BAKE_RES)
	_check("flatten_target", absf(flat_s.get_height(land) - 12.0) < 0.05,
			"h=%.3f" % flat_s.get_height(land))

	# ---- 5. Carve: eje del canal depth_m más bajo; fuera de banda sin cambio ----
	var carve := PathCarveLayer.new()
	carve.path_mode = PathCarveLayer.PathMode.CARVE
	carve.points = PackedVector2Array([land + Vector2(-50, 0), land + Vector2(50, 0)])
	carve.width_m = 6.0
	carve.depth_m = 3.0
	carve.falloff_m = 8.0
	var carve_s := HeightSampler.new()
	carve_s.setup(provider.graph, [VoronoiBaseLayer.new(), carve],
			provider.get_map_bounds(), cfg.height_scale, cfg.seed_variant, provider.query)
	carve_s.bake(BAKE_RES)
	var on_axis := absf((carve_s.get_height(land) - base.get_height(land)) + 3.0)
	var off_band := absf(carve_s.get_height(land + Vector2(0, 40)) - base.get_height(land + Vector2(0, 40)))
	_check("carve", on_axis < 0.15 and off_band < 0.005,
			"axis_err=%.3f off=%.4f" % [on_axis, off_band])

	# ---- 6. Terraza: alturas agrupadas en múltiplos de step ----
	var terr := TerraceHeightLayer.new()
	terr.step_m = 5.0
	terr.sharpness = 1.0
	var terr_s := HeightSampler.new()
	terr_s.setup(provider.graph, [VoronoiBaseLayer.new(), terr],
			provider.get_map_bounds(), cfg.height_scale, cfg.seed_variant, provider.query)
	terr_s.bake(BAKE_RES)
	# Sobre texels CRUDOS (get_height interpola entre escalones y falsea el chequeo).
	# ≥90% de los texels de tierra deben caer en múltiplos de step (los restantes
	# son texels en la banda de transición del smoothstep).
	var raw := terr_s.get_heights_raw()
	var n_land := 0
	var n_quant := 0
	for i in range(0, raw.size(), 97):
		var h := raw[i]
		if h <= 1.0:
			continue
		n_land += 1
		var rem := fmod(h, 5.0)
		if minf(rem, 5.0 - rem) < 0.5:
			n_quant += 1
	_check("terraza", n_land > 20 and float(n_quant) / maxf(n_land, 1) > 0.9,
			"quant=%d/%d" % [n_quant, n_land])

	# ---- 7. Capa disabled no altera nada ----
	var off_noise := NoiseHeightLayer.new()
	off_noise.amplitude_m = 50.0
	off_noise.enabled = false
	var off_s := HeightSampler.new()
	off_s.setup(provider.graph, [VoronoiBaseLayer.new(), off_noise],
			provider.get_map_bounds(), cfg.height_scale, cfg.seed_variant, provider.query)
	off_s.bake(BAKE_RES)
	var off_same := true
	var bh := base.get_heights_raw()
	var oh := off_s.get_heights_raw()
	for i in bh.size():
		if bh[i] != oh[i]:
			off_same = false
			break
	_check("capa_disabled", off_same)

	# ---- 8. Normales unitarias, slope en [0,1] ----
	var norm_ok := true
	for i in 50:
		var p := provider.get_map_bounds().position + Vector2(
				(i * 37 % 100) / 100.0 * provider.get_map_bounds().size.x,
				(i * 53 % 100) / 100.0 * provider.get_map_bounds().size.y)
		var n := base.get_normal(p)
		var s := base.get_slope(p)
		if absf(n.length() - 1.0) > 0.001 or s < 0.0 or s > 1.0:
			norm_ok = false
			break
	_check("normales_slope", norm_ok)

	# ---- 9. Capas automáticas de río/carretera se construyen ----
	var river_layers := provider.build_river_layers(6.0, 2.5, 8.0)
	var road_layers := provider.build_road_layers(7.0, 10.0)
	_check("capas_auto", river_layers.size() > 0 and road_layers.size() > 0,
			"rivers=%d roads=%d" % [river_layers.size(), road_layers.size()])

	# ---- 10. TerrainStamp (§F2): perfil radial asentado sobre el terreno local ----
	# Centro = base_ref + amplitude (curva=1 en r=0, REPLACE con peso 1).
	# Fuera de radius+falloff el campo NO cambia (footprint acotado).
	var stamp := TerrainStamp.new()
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	stamp.radial_profile = curve
	stamp.amplitude_m = 8.0
	stamp.radius_m = 30.0
	stamp.falloff_m = 15.0
	var sl := TerrainStampLayer.new()
	sl.stamp = stamp
	sl.position = land
	var stamp_s := HeightSampler.new()
	stamp_s.setup(provider.graph, [VoronoiBaseLayer.new(), sl],
			provider.get_map_bounds(), cfg.height_scale, cfg.seed_variant, provider.query)
	stamp_s.bake(BAKE_RES)
	var center_err := absf(stamp_s.get_height(land) - (base.get_height(land) + 8.0))
	var stamp_far := absf(stamp_s.get_height(land + Vector2(80, 0))
			- base.get_height(land + Vector2(80, 0)))
	_check("terrain_stamp", center_err < 0.25 and stamp_far < 0.005,
			"center_err=%.3f far=%.4f" % [center_err, stamp_far])


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("HEIGHT_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
