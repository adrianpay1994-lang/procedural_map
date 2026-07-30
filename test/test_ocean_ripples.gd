extends Node
## TEST · OceanRipples: un impacto genera una onda REAL que se propaga.
## Necesita ventana (usa SubViewports). Mide la textura de la simulación.

func _ready() -> void:
	var r := OceanRipples.new()
	r.window_m = 100.0
	r.resolution = 128
	add_child(r)
	# CALENTAR los buffers: recién creados están sin inicializar (leerlos da 1.0 y
	# el "reposo" salía 0.92, arruinando la comparación). Unos frames de
	# simulación en vacío los dejan en cero.
	for _i in 120:
		await get_tree().process_frame

	# Estado en reposo: el mar dinámico está quieto.
	var rest := await _energy(r)
	# Impacto en el centro de la ventana (como un barco pasando).
	r.center = Vector2.ZERO
	for i in 8:
		r.splash(Vector3(0, 0, 0), 0.9)
		for _j in 3:
			await get_tree().process_frame
	var after := await _energy(r)

	# Y la onda se PROPAGA: a los pocos frames hay energía lejos del centro.
	for _k in 25:
		await get_tree().process_frame
	var spread := await _ring_energy(r)

	# NO se afloja este umbral. Con 40 frames de calentamiento el reposo daba
	# 0.00736 y con 120 daba 0.00902: la simulacion GANA energia en vez de
	# asentarse. El test esta detectando una INESTABILIDAD real (ver
	# docs/PLAN_OCEANO_REALISTA.md §13) — bajar el umbral la escondería.
	var ok1 := after > rest + 0.001
	var ok2 := spread > 0.0005
	if not ok1:
		print("FAIL: el impacto no genero onda — reposo=%.5f tras impacto=%.5f" % [rest, after])
	if not ok2:
		print("FAIL: la onda no se propago — energia en el anillo=%.5f" % spread)
	print("OCEAN_RIPPLES: reposo=%.5f impacto=%.5f propagacion=%.5f" % [rest, after, spread])
	print("OCEAN_RIPPLES_TEST: %s (%d/2)" % ["PASS" if (ok1 and ok2) else "FAIL",
			int(ok1) + int(ok2)])
	get_tree().quit(0 if (ok1 and ok2) else 1)


## Energía total (media de |altura|) de la simulación.
func _energy(r: OceanRipples) -> float:
	await RenderingServer.frame_post_draw
	var img := r.texture().get_image()
	var acc := 0.0
	var n := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			acc += absf(img.get_pixel(x, y).r)
			n += 1
	return acc / maxf(float(n), 1.0)


## Energía en un ANILLO lejos del centro: prueba que la onda VIAJÓ, no que solo
## quedó el pozo del impacto.
func _ring_energy(r: OceanRipples) -> float:
	await RenderingServer.frame_post_draw
	var img := r.texture().get_image()
	var w := img.get_width()
	var c := float(w) * 0.5
	var acc := 0.0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, w, 2):
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			if d > 0.45 and d < 0.8:
				acc += absf(img.get_pixel(x, y).r)
				n += 1
	return acc / maxf(float(n), 1.0)
