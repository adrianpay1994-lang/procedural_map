extends Node
## TEST · CoastalReliefLayer enchufada al pipeline: con coastal_relief_m > 0 el
## terreno REAL debe cambiar (mismo seed), y con 0 debe quedar idéntico al de antes.

func _ready() -> void:
	var a := await _sample(0.0)      # apagada = comportamiento actual
	var b := await _sample(60.0)     # encendida
	var diff := 0.0
	for i in a.size():
		diff += absf(a[i] - b[i])
	diff /= maxf(float(a.size()), 1.0)
	var ok := diff > 1.0
	if not ok:
		print("FAIL: encender el relieve no cambio el terreno (dif media %.3f m)" % diff)
	print("RELIEF_WIRED: diferencia media de altura = %.2f m" % diff)
	print("RELIEF_WIRED_TEST: %s (%d/1)" % ["PASS" if ok else "FAIL", int(ok)])
	get_tree().quit(0 if ok else 1)


## Genera un mapa con el knob dado y devuelve alturas en una grilla fija.
func _sample(relief: float) -> PackedFloat32Array:
	var map := ProceduralMapSystem.new()
	var cfg := MapGenerationConfig.new()
	cfg.seed_shape = 4242
	cfg.seed_variant = 4242
	cfg.num_points = 500
	cfg.map_size = 500.0
	cfg.ocean_points = 150
	cfg.num_rivers = 0
	cfg.coastal_relief_m = relief
	map.config = cfg
	map.generate_vegetation = false
	map.spawn_test_train = false
	map.bake_navmesh = false
	map.generate_spawn_points = false
	add_child(map)
	await map.generation_completed
	var out := PackedFloat32Array()
	var b: Rect2 = map.sampler.bounds
	for i in 15:
		for j in 15:
			var p := b.position + Vector2(b.size.x * (float(i) + 0.5) / 15.0,
					b.size.y * (float(j) + 0.5) / 15.0)
			out.append(map.sampler.get_height(p))
	map.queue_free()
	await get_tree().process_frame
	return out
