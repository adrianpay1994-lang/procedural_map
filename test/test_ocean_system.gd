extends Node
## TEST · OceanSystem (océano nuevo por FFT). Necesita VENTANA: usa compute
## shaders (en headless el RenderingDevice es dummy y no hay FFT).
##   godot --path . res://systems/procedural_map/test/test_ocean_system.tscn
## Verifica: se arma superficie+suelo, el suelo queda a la profundidad pedida,
## el FFT produce DESPLAZAMIENTO REAL (no un mar plano) y el re-centrado corre.

var _pass := 0
var _fail := 0
var _ocean: OceanSystem = null
var _cam: Camera3D = null


func _ready() -> void:
	if RenderingServer.get_rendering_device() == null:
		print("OCEAN_SYSTEM_TEST: SKIP (sin RenderingDevice — correr con ventana)")
		get_tree().quit(0)
		return
	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.far = 4000.0
	add_child(_cam)
	_cam.global_position = Vector3(0, 12, 0)
	_cam.look_at(Vector3(300, 0, 0), Vector3.UP)

	_ocean = OceanSystem.new()
	_ocean.area_size_m = 2048.0
	_ocean.floor_depth_m = -35.0
	_ocean.map_size = 256
	_ocean.frustum_cull = false      # 360°: medir sin depender de la orientación
	add_child(_ocean)
	_ocean.set_target_camera(_cam)

	# Dejar correr el pipeline: 1 cascada por frame + publicación de mapas.
	for _i in 40:
		await get_tree().process_frame

	_check("superficie_creada", _ocean.surface_quadtree() != null, "")
	_check("suelo_creado", _ocean.floor_quadtree() != null, "")
	var f := _ocean.floor_quadtree()
	if f != null:
		_check("suelo_a_la_profundidad_pedida", is_equal_approx(f.position.y, -35.0),
				"y=%.2f (esperado -35.00)" % f.position.y)
	var s := _ocean.surface_quadtree()
	if s != null:
		var st: Dictionary = s.stats()
		_check("superficie_con_celdas", st.leaves > 0, "celdas=%d" % st.leaves)
		print("OCEAN_SYSTEM: superficie %d celdas · %d tri · suelo %d celdas" % [
				st.leaves, st.tris, (f.stats().leaves if f != null else 0)])

	# Sincronizar con el render antes de leer la textura de la GPU.
	await RenderingServer.frame_post_draw
	# El FFT tiene que producir OLAS: se lee el mapa de desplazamiento y se mide
	# su amplitud. Si el pipeline no corrió, sería todo ceros (mar plano).
	var amp := _measure_displacement()
	_check("el_FFT_genera_olas", amp > 0.01, "amplitud maxima medida = %.4f m" % amp)
	print("OCEAN_SYSTEM: amplitud maxima del desplazamiento = %.3f m" % amp)

	# Pseudo-infinito: al alejarse, el área se re-centra en la cámara.
	var c0: Vector2 = s.area_center
	_cam.global_position = Vector3(4000, 12, 0)
	for _j in 6:
		await get_tree().process_frame
	_check("recentra_con_la_camara", s.area_center != c0,
			"antes %s ahora %s" % [c0, s.area_center])

	# PRUEBA VISUAL: si el FFT anda, se ven olas. Es decisivo aunque la lectura
	# GPU->CPU falle (esa solo hace falta para la flotabilidad).
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, -40, 0)
	sun.light_energy = 1.3
	add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	_cam.global_position = Vector3(0, 14, 0)
	_cam.look_at(Vector3(220, 0, 60), Vector3.UP)
	for _k in 30:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://systems/procedural_map/test/_ocean_system.png")
	print("OCEAN_SYSTEM: captura guardada")

	print("OCEAN_SYSTEM_TEST: %s (%d/%d)" % ["PASS" if _fail == 0 else "FAIL",
			_pass, _pass + _fail])
	get_tree().quit(0 if _fail == 0 else 1)


## Lee el mapa de desplazamiento de la GPU y devuelve la mayor |altura| hallada.
func _measure_displacement() -> float:
	var gpu = _ocean.get_node_or_null(^"WaveGPU")
	if gpu == null or gpu.context == null:
		return -1.0
	var rd := RenderingServer.get_rendering_device()
	var rid: RID = gpu.descriptors[&"displacement_map"].rid
	# Diagnostico: leer TODAS las capas + el espectro, para partir el problema.
	var spec_rid: RID = gpu.descriptors[&"spectrum"].rid
	for lay in 3:
		var sb := rd.texture_get_data(spec_rid, lay)
		var smax := 0.0
		if not sb.is_empty():
			for i in range(0, sb.size() / 16, maxi((sb.size() / 16) / 2048, 1)):
				smax = maxf(smax, absf(sb.decode_float(i * 16)))
		var db := rd.texture_get_data(rid, lay)
		var dmax := 0.0
		if not db.is_empty():
			for i in range(0, db.size() / 8, maxi((db.size() / 8) / 2048, 1)):
				dmax = maxf(dmax, absf(db.decode_half(i * 8 + 2)))
		print("OCEAN_SYSTEM: cascada %d -> espectro_max=%.5f  desplaz_max=%.5f" % [lay, smax, dmax])
	var bytes := rd.texture_get_data(rid, 0)   # capa 0 = cascada de olas largas
	print("OCEAN_SYSTEM: bytes leidos=%d · cascadas pendientes=%s · contexto=%s"
			% [bytes.size(), str(gpu.pass_num_cascades_remaining), str(gpu.context != null)])
	if bytes.is_empty():
		return -1.0
	# RGBA16F: 8 bytes por texel, el canal G (offset 2) es la altura Y.
	var best := 0.0
	var texels := bytes.size() / 8
	var step := maxi(texels / 4096, 1)          # muestreo: no recorrer 65k texeles
	for i in range(0, texels, step):
		var y := bytes.decode_half(i * 8 + 2)
		best = maxf(best, absf(y))
	return best


func _check(name: String, ok: bool, info: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s — %s" % [name, info])
