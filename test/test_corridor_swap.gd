extends Node
## TEST · Carretera y vía que se INTERCAMBIAN de lado a lo largo del circuito.
## Criterio: el signo del offset debe cambiar `swaps` veces por vuelta (cada cambio
## de signo = un CRUCE), y nunca deben quedar exactamente encimadas.

func _ready() -> void:
	var n := 400
	var half := 20.0
	var swaps := 4
	var off := CorridorPlanner.swap_offsets(n, half, swaps, 0.12)

	# 1) Cuenta de cruces = cambios de signo a lo largo de la vuelta.
	# El anillo es CERRADO: hay que contar tambien la transicion del ultimo punto
	# al primero, o falta siempre un cruce (el que cae justo en el cierre).
	var crossings := 0
	for i in off.size():
		var prev: float = off[(i - 1 + off.size()) % off.size()]
		if signf(off[i]) != signf(prev):
			crossings += 1
	var ok_cross := crossings == swaps
	if not ok_cross:
		print("FAIL: se esperaban %d cruces y hubo %d" % [swaps, crossings])

	# 2) Nunca encimadas: el |offset| mantiene una luz mínima.
	var min_abs := INF
	var max_abs := 0.0
	for v in off:
		min_abs = minf(min_abs, absf(v))
		max_abs = maxf(max_abs, absf(v))
	var ok_gap := min_abs > 1.0
	if not ok_gap:
		print("FAIL: las calzadas se encimaron — separacion minima %.2f m" % min_abs)

	# 3) Los dos lados se usan: hay offset positivo Y negativo (si no, no hay
	#    intercambio real, solo una oscilación de un solo lado).
	var pos := 0
	var neg := 0
	for v in off:
		if v > 0.0: pos += 1
		else: neg += 1
	var ok_both := pos > n / 10 and neg > n / 10
	if not ok_both:
		print("FAIL: no se usan los dos lados (pos=%d neg=%d)" % [pos, neg])

	# 4) La geometría resultante: dos polilíneas que se acercan y se alejan.
	var spine := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU
		spine.append(Vector2(cos(a), sin(a)) * 500.0)
	var neg_off := PackedFloat32Array()
	neg_off.resize(off.size())
	for i in off.size():
		neg_off[i] = -off[i]
	var road := CorridorPlanner.offset_polyline_varying(spine, neg_off, true)
	var rail := CorridorPlanner.offset_polyline_varying(spine, off, true)
	var dmin := INF
	var dmax := 0.0
	for i in mini(road.size(), rail.size()):
		var d := road[i].distance_to(rail[i])
		dmin = minf(dmin, d)
		dmax = maxf(dmax, d)
	var ok_geo := dmax > dmin * 3.0
	if not ok_geo:
		print("FAIL: la separacion no varia (min %.1f max %.1f)" % [dmin, dmax])

	print("CORRIDOR_SWAP: %d cruces · separacion %.1f..%.1f m" % [crossings, dmin, dmax])
	var pass_n := int(ok_cross) + int(ok_gap) + int(ok_both) + int(ok_geo)
	print("CORRIDOR_SWAP_TEST: %s (%d/4)" % ["PASS" if pass_n == 4 else "FAIL", pass_n])
	get_tree().quit(0 if pass_n == 4 else 1)
