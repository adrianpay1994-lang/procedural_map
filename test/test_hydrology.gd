extends Node

## ============================================================================
## test_hydrology.gd · Unit de Hydrology (TERRAIN_PIPELINE_V2_PLAN §F4)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_hydrology.tscn
## Isla sintética (cono con ondulación + una DEPRESIÓN interior) y asserts:
## el priority-flood elimina todo mínimo local, detecta la depresión, y cada
## río trazado termina en el mar. Determinista (dos corridas idénticas).
## ============================================================================

const RES := 129
const SEA := 0.0

var _results: Array = []


func _ready() -> void:
	# smoke.tscn instancia TODO res://systems — no correr (ni hacer quit) ahí.
	if get_tree().current_scene != self:
		return
	_run_all()
	_report()


func _check(check_name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": check_name, "ok": ok, "detail": detail})


## Cono de isla (radio ~55 celdas) + ondulación determinista + pozo interior
## (depresión real: cuenca cerrada que SIN flood atraparía el descenso).
func _make_island() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(RES * RES)
	var c := Vector2(RES / 2.0, RES / 2.0)
	for z in RES:
		for x in RES:
			var r := Vector2(x, z).distance_to(c)
			var base := 24.0 * (1.0 - r / 55.0)
			var wave := 1.6 * sin(x * 0.37) * cos(z * 0.29)
			var v := base + wave
			# Pozo: cuenca de radio 6 centrada en (44, 64), 5 m bajo su borde.
			var pit_d := Vector2(x, z).distance_to(Vector2(44, 64))
			if pit_d < 6.0:
				v -= 5.0 * (1.0 - pit_d / 6.0)
			h[z * RES + x] = v
	return h


func _run_all() -> void:
	var h := _make_island()
	var bounds := Rect2(-64, -64, 128, 128)

	var res1 := Hydrology.run(h, RES, bounds, SEA, 8)
	var res2 := Hydrology.run(h, RES, bounds, SEA, 8)

	# ---- 1. Sin mínimos locales: toda celda interior sobre el mar tiene un
	# vecino estrictamente más bajo en el campo rellenado ----
	var filled: PackedFloat32Array = res1.filled
	var stuck := 0
	for z in range(1, RES - 1):
		for x in range(1, RES - 1):
			var i := z * RES + x
			if filled[i] <= SEA:
				continue
			var has_lower := false
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					if dz == 0 and dx == 0:
						continue
					if filled[(z + dz) * RES + (x + dx)] < filled[i]:
						has_lower = true
						break
				if has_lower:
					break
			if not has_lower:
				stuck += 1
	_check("sin_minimos_locales", stuck == 0, "atascadas=%d" % stuck)

	# ---- 2. La depresión fue detectada (celdas sink > 0 cerca del pozo) ----
	var sink: PackedByteArray = res1.sink
	var sink_count := 0
	for v in sink:
		if v == 1:
			sink_count += 1
	_check("depresion_detectada", sink_count > 5, "sinks=%d" % sink_count)

	# ---- 3. Hay ríos y TODOS terminan en el mar ----
	var rivers: Array = res1.rivers
	var all_reach := rivers.size() > 0
	var texel := bounds.size.x / float(RES - 1)
	for river_any in rivers:
		var pts := river_any as PackedVector2Array
		var tail: Vector2 = pts[pts.size() - 1]
		var gx := int(roundf((tail.x - bounds.position.x) / texel))
		var gz := int(roundf((tail.y - bounds.position.y) / texel))
		var gi := clampi(gz, 0, RES - 1) * RES + clampi(gx, 0, RES - 1)
		# Fin válido: bajo el nivel del mar, o cortado en confluencia con otro
		# río (que a su vez termina en el mar — propiedad transitiva del trace).
		var in_sea: bool = filled[gi] <= SEA + 0.001
		var confluence := false
		if not in_sea:
			for other_any in rivers:
				var other := other_any as PackedVector2Array
				if other == pts:
					continue
				for k in other.size():
					if other[k].distance_to(tail) < texel * 2.0:
						confluence = true
						break
				if confluence:
					break
		if not (in_sea or confluence):
			all_reach = false
			break
	_check("rios_llegan_al_mar", all_reach, "rivers=%d" % rivers.size())

	# ---- 4. Determinismo: dos corridas ⇒ mismos ríos ----
	var same: bool = rivers.size() == (res2.rivers as Array).size()
	if same:
		for ri in rivers.size():
			var a := rivers[ri] as PackedVector2Array
			var b := (res2.rivers as Array)[ri] as PackedVector2Array
			if a != b:
				same = false
				break
	_check("determinismo", same)

	# ---- 5. Acumulación coherente: la celda de mayor acc drena área > umbral ----
	var acc: PackedFloat32Array = res1.acc
	var max_acc := 0.0
	for v in acc:
		max_acc = maxf(max_acc, v)
	_check("acumulacion", max_acc > 100.0, "max_acc=%.0f" % max_acc)


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("HYDRO_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
