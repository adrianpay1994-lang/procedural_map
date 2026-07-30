extends Node

## ============================================================================
## test_corridor.gd · Unit de CorridorPlanner (TERRAIN_PIPELINE_V2_PLAN §F3)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_corridor.tscn
## Isla sintética circular: el anillo costero debe ser un lazo cerrado, entero
## sobre tierra, a ≥ inset de la costa; los offsets de carretera/vía deben
## correr paralelos a la separación pedida. Determinista.
## ============================================================================

const RES := 129
const SEA := 0.0

var _results: Array = []


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_run_all()
	_report()


func _check(check_name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": check_name, "ok": ok, "detail": detail})


func _run_all() -> void:
	# Isla cono: radio de costa ≈ 55 celdas × texel 1 m ⇒ costa a 55 m del centro.
	var h := PackedFloat32Array()
	h.resize(RES * RES)
	var c := Vector2(RES / 2.0, RES / 2.0)
	for z in RES:
		for x in RES:
			var r := Vector2(x, z).distance_to(c)
			h[z * RES + x] = 24.0 * (1.0 - r / 55.0)
	var bounds := Rect2(-64, -64, 128, 128)
	var texel := bounds.size.x / float(RES - 1)
	var inset := 10.0

	var ring := CorridorPlanner.coast_ring(h, RES, bounds, SEA, inset)

	# ---- 1. Anillo existe y es un lazo (extremos adyacentes) ----
	var closed := ring.size() > 20 \
			and ring[0].distance_to(ring[ring.size() - 1]) < texel * 4.0
	_check("anillo_cerrado", closed, "pts=%d gap=%.1f" % [ring.size(),
			ring[0].distance_to(ring[ring.size() - 1]) if ring.size() > 0 else -1.0])

	# ---- 2. Todo el anillo sobre tierra y a ≥ inset-2 de la costa ----
	# (costa = radio 55 desde el centro del mapa; el anillo erosionado debe
	# quedar a radio ≤ 55 − inset + tolerancia de celda)
	var all_inside := ring.size() > 0
	var max_r := 0.0
	for p in ring:
		var r := p.distance_to(Vector2.ZERO)
		max_r = maxf(max_r, r)
		if r > 55.0 - inset + texel * 2.5:
			all_inside = false
	_check("anillo_a_distancia", all_inside, "max_r=%.1f (limite=%.1f)"
			% [max_r, 55.0 - inset + texel * 2.5])

	# ---- 3. Determinismo ----
	var ring2 := CorridorPlanner.coast_ring(h, RES, bounds, SEA, inset)
	_check("determinismo", ring == ring2)

	# ---- 4. Offsets paralelos: separación ≈ 2×offset en línea recta ----
	var line := PackedVector2Array()
	for i in 20:
		line.append(Vector2(float(i) * 5.0, 0.0))
	var left := CorridorPlanner.offset_polyline(line, -4.5, false)
	var right := CorridorPlanner.offset_polyline(line, 4.5, false)
	var sep_ok := left.size() == line.size() and right.size() == line.size()
	if sep_ok:
		for i in line.size():
			if absf(left[i].distance_to(right[i]) - 9.0) > 0.01:
				sep_ok = false
				break
	_check("offsets_paralelos", sep_ok)

	# ---- 5. Offset en anillo conserva el cierre ----
	var closed_ring := PackedVector2Array()
	for i in 33:
		var a := TAU * float(i) / 32.0
		closed_ring.append(Vector2(cos(a), sin(a)) * 30.0)  # [0] == [32]
	var off := CorridorPlanner.offset_polyline(closed_ring, 3.0, true)
	var off_closed := off.size() == closed_ring.size() \
			and off[0].distance_to(off[off.size() - 1]) < 0.01
	# Offset positivo (normal exterior en anillo antihorario) = radio mayor.
	var r_ok := absf(off[0].length() - 33.0) < 0.2 or absf(off[0].length() - 27.0) < 0.2
	_check("offset_anillo", off_closed and r_ok, "r=%.2f" % off[0].length())


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("CORRIDOR_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
