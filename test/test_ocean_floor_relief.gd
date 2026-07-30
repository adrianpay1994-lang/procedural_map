extends Node
## TEST · El suelo oceánico debe tener RELIEVE REAL (cuencas y montes submarinos),
## no una ondulación tímida. La referencia (ocean_floor_system) usa amplitudes por
## capa en METROS, con la capa de cuencas dominante.

func _ready() -> void:
	var oc := OceanSystem.new()
	oc.area_size_m = 4096.0
	oc.floor_depth_m = -120.0
	add_child(oc)
	await get_tree().process_frame

	var lo := INF
	var hi := -INF
	for i in 60:
		for j in 60:
			var p := Vector2(float(i) * 60.0 - 1800.0, float(j) * 60.0 - 1800.0)
			var h: float = oc.floor_height(p)
			lo = minf(lo, h)
			hi = maxf(hi, h)
	var rango := hi - lo
	# Con cuencas 100 m + base 50 + detalle 10, el rango tiene que ser de decenas
	# de metros. Menos de 40 m = volvimos al fondo chato.
	var ok := rango > 40.0
	if not ok:
		print("FAIL: el fondo quedo chato — rango %.1f m (esperado > 40)" % rango)
	print("OCEAN_FLOOR: profundidad %.0f..%.0f m · rango de relieve %.1f m" % [lo, hi, rango])
	print("OCEAN_FLOOR_TEST: %s (%d/1)" % ["PASS" if ok else "FAIL", int(ok)])
	get_tree().quit(0 if ok else 1)
