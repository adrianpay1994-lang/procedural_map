extends Node

## ============================================================================
## test_region_stream.gd · Guardián del streaming de regiones (16KM-5)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_region_stream.tscn
## Mundo SINTÉTICO de 16×16 km (capas puras de ruido, sin grafo):
## 1. Caminata diagonal de 16 km ⇒ regiones en memoria NUNCA superan el tope.
## 2. Determinismo tras EVICCIÓN: volver a una región ya descartada da
##    EXACTAMENTE los mismos valores.
## 3. Costuras: a ambos lados del borde entre regiones la altura es continua.
## ============================================================================

var _results: Array = []


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_run()


func _check(check_name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": check_name, "ok": ok, "detail": detail})


func _make_sampler() -> RegionStreamSampler:
	var noise := NoiseHeightLayer.new()
	noise.noise_seed = 77
	noise.amplitude_m = 30.0
	noise.frequency = 0.0006
	noise.octaves = 4
	noise.erosion_weight = 0.0   # capa PURA (sin consultas al grafo)
	var base := ConstHeightLayer.new()
	base.value_m = 5.0
	var s := RegionStreamSampler.new()
	s.setup([base, noise] as Array[HeightLayer],
			Rect2(-8192, -8192, 16384, 16384), 40.0, 4242)
	s.region_m = 512.0
	s.region_res = 129
	s.max_regions = 12
	return s


func _run() -> void:
	var s := _make_sampler()

	# ---- 1. Caminata de 16 km: memoria acotada ----
	var max_loaded := 0
	var first_val := 0.0
	var first_pt := Vector2(-8000, -8000)
	first_val = s.get_height(first_pt)
	var pt := first_pt
	while pt.x < 8000.0:
		s.get_height(pt)
		max_loaded = maxi(max_loaded, s.loaded_regions())
		pt += Vector2(97.0, 97.0)  # paso no alineado a la región (cruza bordes)
	_check("memoria_acotada", max_loaded <= 12,
			"max_regiones=%d bakes=%d" % [max_loaded, s.bakes_count])
	_check("streaming_real", s.bakes_count > 20, "bakes=%d" % s.bakes_count)

	# ---- 2. Determinismo tras evicción ----
	var revisit := s.get_height(first_pt)   # la región inicial ya fue desalojada
	_check("determinismo_post_eviccion", revisit == first_val,
			"%.6f vs %.6f" % [revisit, first_val])

	# ---- 3. Costuras entre regiones: continuidad a ambos lados del borde ----
	var seam_ok := true
	var worst := 0.0
	for i in 12:
		var bx := -8192.0 + 512.0 * float(3 + i)       # borde vertical de región
		var y := -3000.0 + 700.0 * float(i)
		var d := absf(s.get_height(Vector2(bx - 0.01, y))
				- s.get_height(Vector2(bx + 0.01, y)))
		worst = maxf(worst, d)
		if d > 0.02:
			seam_ok = false
	_check("costuras_continuas", seam_ok, "peor=%.4f m" % worst)

	# ---- 4. Determinismo entre INSTANCIAS (MP-safe) ----
	var s2 := _make_sampler()
	var same := true
	for i in 24:
		var q := Vector2(-7000.0 + 610.0 * float(i), 2500.0 - 400.0 * float(i))
		if s.get_height(q) != s2.get_height(q):
			same = false
			break
	_check("determinismo_instancias", same)

	_report()


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("STREAM_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
