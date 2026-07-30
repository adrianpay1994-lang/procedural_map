extends Node3D

## ============================================================================
## frustum_proof.gd · Prueba VISUAL del frustum-cull (2 cámaras) — modo SHOT
## ============================================================================
## Corre CON VENTANA (headless no tiene framebuffer para el screenshot):
##   godot --path . res://systems/procedural_map/test/frustum_proof.tscn -- --shot
## Genera un mapa con quadtree + frustum_cull + debug_lod_color, y guarda 2 PNG:
##   - player_view.png  : lo que ve la cámara del PLAYER (terreno coloreado por LOD).
##   - top_view.png     : el MISMO mundo desde arriba → se ve que SOLO se construyeron
##     las celdas del CONO del player (atrás/costados = vacío). Prueba "NOT VISIBLE
##     TO CAMERA" + las celdas que se agrandan al alejarse (anillos de LOD).
## Los PNG van al scratchpad (ruta abajo). Restaura Settings al final.
## ============================================================================

const SHOT_DIR := "C:/Users/ggntez/AppData/Local/Temp/claude/D--godot-proyects/f30998de-314c-43b9-b369-b29d156f955c/scratchpad"

var _prev: Dictionary = {}


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	await _run()


func _ovr(section: StringName, key: StringName, val: Variant) -> void:
	_prev[key] = Settings.get_value(section, key, false)
	Settings.set_value(section, key, val, false)


func _restore() -> void:
	for k: StringName in _prev:
		if _prev[k] != null:
			Settings.set_value(&"graphics", k, _prev[k], false)


func _run() -> void:
	if typeof(Settings) != TYPE_NIL and Settings != null:
		_ovr(&"graphics", &"terrain_quadtree", true)
		_ovr(&"graphics", &"terrain_frustum_cull", true)
		_ovr(&"graphics", &"terrain_morph", false)   # sin morph: celdas nítidas para la foto

	var map := ProceduralMapSystem.new()
	var cfg := MapGenerationConfig.new()
	cfg.num_points = 1400
	cfg.map_size = 1000.0
	cfg.ocean_points = 350
	cfg.ocean_distance = 300.0
	map.config = cfg
	map.terrain_settings = TerrainSettings.new()
	map.generate_vegetation = false
	map.spawn_test_train = false
	map.bake_navmesh = false
	map.generate_spawn_points = false
	add_child(map)
	await map.generation_completed

	var qt := map.find_child("TerrainQuadtree", true, false)
	if qt == null:
		print("FRUSTUM_PROOF: FAIL — no hay TerrainQuadtree")
		_finish()
		return
	qt.debug_lod_color = true
	qt.debug_ring_outline = true   # borde por celda-LOD → anillos concéntricos NÍTIDOS
	qt.frustum_cull = true
	# Ocultar el agua clásica: en la cenital queremos ver SOLO las celdas de LOD.
	var water := map.find_child("Water", true, false) as Node3D
	if water != null:
		water.visible = false

	var b: Rect2 = map.sampler.bounds
	var c: Vector2 = b.get_center()
	var h: float = map.sampler.get_height(c) + 4.0

	# Cámaras: se crean, se meten en SubViewports que COMPARTEN el mundo, y RECIÉN
	# ahí (ya en el árbol) se les da posición + orientación — look_at requiere que la
	# cámara esté en el árbol (si no, queda con orientación default → mira al cielo).
	var player_cam := Camera3D.new()
	player_cam.fov = 70.0
	player_cam.far = 2000.0
	qt.target_camera = player_cam   # el quadtree sigue ESTA cámara (no la de arriba)

	var side: float = maxf(b.size.x, b.size.y)
	var top_cam := Camera3D.new()
	top_cam.fov = 55.0
	top_cam.far = 6000.0

	var vp_player := _make_viewport(player_cam)
	var vp_top := _make_viewport(top_cam)
	add_child(vp_player)
	add_child(vp_top)

	# Ahora SÍ (en el árbol): PLAYER en el centro mirando diagonal horizontal; CENITAL
	# bien arriba mirando -Y, encuadrando todo el mapa (solo OBSERVA lo construido).
	var eye: float = map.sampler.get_height(c) + 1.7   # a nivel de ojos: mesh de CERCA
	player_cam.global_position = Vector3(c.x, eye, c.y)
	player_cam.look_at(Vector3(c.x - 300.0, eye - 14.0, c.y - 300.0), Vector3.UP)
	top_cam.global_position = Vector3(c.x, h + side * 1.25, c.y)
	top_cam.look_at(Vector3(c.x, 0.0, c.y), Vector3(0, 0, -1))

	# Dibujar el CONO del player (líneas) para ver qué entra/sale del frustum.
	_draw_frustum(player_cam)

	# Dejar que el quadtree construya (sigue a player_cam) y que ambos VP rendericen.
	for _i in 60:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var visible_leaves := _count_visible_mi(qt)
	print("FRUSTUM_PROOF: hojas visibles (solo cono del player) = %d" % visible_leaves)

	_save(vp_player, "player_view.png")
	_save(vp_top, "top_view.png")

	# GIRAR la cámara y esperar: el quadtree reconstruye hacia el nuevo lado (prueba
	# que al girar/caminar se REEMPLAZAN las subdivisiones — el cono se mueve).
	player_cam.look_at(Vector3(c.x + 380.0, h, c.y + 220.0), Vector3.UP)
	_draw_frustum(player_cam)
	for _j in 70:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	print("FRUSTUM_PROOF: tras GIRAR, hojas visibles = %d" % _count_visible_mi(qt))
	_save(vp_top, "top_view_turned.png")

	# ANILLOS DE LOD completos: frustum OFF (construye 360°) + cámara al centro → se ven
	# los anillos concéntricos (chico en el centro, DOBLANDO hacia afuera). Es la prueba
	# de que las celdas se COMBINAN al alejarse (4 finas → 1 gruesa), como el diagrama.
	if _cone_mi != null and is_instance_valid(_cone_mi):
		_cone_mi.queue_free()   # sin cono acá: solo los anillos
	qt.frustum_cull = false
	qt.update_for(Vector3(c.x, eye, c.y))
	for _k in 55:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	print("FRUSTUM_PROOF: anillos 360°, hojas = %d" % _count_visible_mi(qt))
	_save(vp_top, "rings_view.png")

	_finish()


## Dibuja el frustum del player como LÍNEAS (rayos de borde + rectángulos near/far)
## → en la cenital se ve el CONO sobre las celdas: qué está dentro y qué afuera.
var _cone_mi: MeshInstance3D = null


func _draw_frustum(cam: Camera3D) -> void:
	if _cone_mi != null and is_instance_valid(_cone_mi):
		_cone_mi.queue_free()   # redibujar al girar
	var near := 3.0
	var far := 1100.0           # largo real del cono (encierra las celdas construidas)
	var vs := Vector2(760, 460)   # tamaño del SubViewport del player
	var corners := [Vector2(0, 0), Vector2(vs.x, 0), Vector2(vs.x, vs.y), Vector2(0, vs.y)]
	var np: Array = []
	var fp: Array = []
	for cpx: Vector2 in corners:
		np.append(cam.project_position(cpx, near))
		fp.append(cam.project_position(cpx, far))
	var origin := cam.global_position
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.15, 1.0, 0.9)
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for i in 4:
		im.surface_add_vertex(origin)          # rayo del borde del cono
		im.surface_add_vertex(fp[i])
		im.surface_add_vertex(fp[i])           # rectángulo lejano
		im.surface_add_vertex(fp[(i + 1) % 4])
		im.surface_add_vertex(np[i])           # rectángulo cercano
		im.surface_add_vertex(np[(i + 1) % 4])
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	add_child(mi)
	_cone_mi = mi


func _make_viewport(cam: Camera3D) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(760, 460)
	vp.own_world_3d = false             # comparte el mundo (ve el mismo terreno)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = false
	var holder := cam.get_parent()
	if holder != null:
		holder.remove_child(cam)
	vp.add_child(cam)
	cam.current = true
	return vp


func _save(vp: SubViewport, name: String) -> void:
	var img := vp.get_texture().get_image()
	if img == null:
		print("FRUSTUM_PROOF: get_image NULL para %s (¿corriste headless? necesita ventana)" % name)
		return
	var path := SHOT_DIR + "/" + name
	var err := img.save_png(path)
	print("FRUSTUM_PROOF: %s -> %s (err=%d)" % [name, path, err])


func _count_visible_mi(qt: Node) -> int:
	var n := 0
	for ch in qt.get_children():
		if ch is MeshInstance3D and (ch as MeshInstance3D).visible:
			n += 1
	return n


func _finish() -> void:
	_restore()
	print("FRUSTUM_PROOF: DONE")
	get_tree().quit(0)
