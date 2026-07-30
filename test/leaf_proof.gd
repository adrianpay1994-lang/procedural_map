extends Node3D

## ============================================================================
## leaf_proof · PRUEBA de que la copa son IMÁGENES y el tronco es limitable
## ============================================================================
## Tres árboles (misma especie/semilla):
##   1. ÁRBOL ACTUAL — copa de quads con imagen de hoja (surf 1) + tronco (surf 0)
##   2. SOLO TRONCO  — leaf_count 0: lo que queda al quitar las imágenes
##   3. TRONCO 4 LADOS — max_trunk_sides=4 (FloraConfig.lod): menos polys
## Imprime el desglose de vértices POR SUPERFICIE (tronco vs copa) y saca DOS
## capturas: normal y WIREFRAME (se ve que cada hoja es un quad plano).
##   godot --path . res://systems/procedural_map/test/leaf_proof.tscn -- shot
## ============================================================================

var _frame := 0
var _shot := false


func _surf_verts(m: ArrayMesh, s: int) -> int:
	if s >= m.get_surface_count():
		return 0
	return (m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()


func _ready() -> void:
	_shot = OS.get_cmdline_user_args().has("shot")
	# ANTES de crear mallas: si no, las ya subidas no generan su versión wireframe.
	RenderingServer.set_debug_generate_wireframes(true)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46.0, -55.0, 0.0)
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(110, 70)
	floor_mi.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.32, 0.42, 0.24)
	floor_mi.material_override = fmat
	add_child(floor_mi)

	# 1. Árbol actual.
	var normal := FloraFactory.make_tree(TreeParams.black_oak(), 7) as ArrayMesh
	# 2. Solo tronco/ramas (sin imágenes de hoja).
	var solo := TreeParams.black_oak()
	solo.leaf_count = 0
	var trunk_only := FloraFactory.make_tree(solo, 7) as ArrayMesh
	# 3. Tronco limitado a 4 lados vía FloraConfig.lod (lo configurable).
	var cfg := FloraConfig.new()
	cfg.lod = FloraLodStyle.new()
	cfg.lod.max_trunk_sides = 4
	FloraConfig.active = cfg
	var capped := FloraFactory.make_tree(
			FloraConfig.apply_active(TreeParams.black_oak(), "tree"), 7) as ArrayMesh
	FloraConfig.active = null

	print("PROOF arbol_actual: tronco+ramas=%d verts · COPA(imagenes)=%d verts"
			% [_surf_verts(normal, 0), _surf_verts(normal, 1)])
	print("PROOF solo_tronco: %d verts (copa quitada = eran solo imagenes)"
			% _surf_verts(trunk_only, 0))
	print("PROOF tronco_4_lados: tronco+ramas=%d verts (limite FUNCIONA: %d -> %d)"
			% [_surf_verts(capped, 0), _surf_verts(normal, 0), _surf_verts(capped, 0)])

	var items: Array = [
		[normal, -16.0, "ACTUAL\ncopa=imagenes"],
		[trunk_only, 0.0, "SIN imagenes\n(solo tronco)"],
		[capped, 16.0, "tronco 4 lados\n(limitado)"],
	]
	for it: Array in items:
		var mi := MeshInstance3D.new()
		mi.mesh = it[0]
		mi.position = Vector3(it[1], 0, 0)
		add_child(mi)
		var lbl := Label3D.new()
		lbl.text = it[2]
		lbl.font_size = 64
		lbl.pixel_size = 0.02
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.outline_size = 14
		lbl.position = Vector3(it[1], 1.2, 9.0)
		add_child(lbl)

	var cam := Camera3D.new()
	cam.current = true
	cam.fov = 60.0
	add_child(cam)
	var h := normal.get_aabb().size.y
	cam.look_at_from_position(Vector3(0, h * 0.55, h * 2.2),
			Vector3(0, h * 0.5, 0), Vector3.UP)


func _process(_d: float) -> void:
	_frame += 1
	if not _shot:
		return
	if _frame == 40:
		get_viewport().get_texture().get_image() \
				.save_png("res://systems/procedural_map/test/_leaf_proof.png")
		print("SHOT_SAVED normal")
		# Segunda captura en WIREFRAME: se VE que cada hoja es un quad plano.
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
	elif _frame == 80:
		get_viewport().get_texture().get_image() \
				.save_png("res://systems/procedural_map/test/_leaf_proof_wire.png")
		print("SHOT_SAVED wireframe")
		# Tercera captura: cámara PEGADA a la copa del árbol actual — se ve que
		# cada "hoja" es un quad plano con una imagen (de canto = línea fina).
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
		var cam := get_viewport().get_camera_3d()
		cam.look_at_from_position(Vector3(-9.8, 10.2, 6.0),
				Vector3(-16.5, 9.2, -1.5), Vector3.UP)
	elif _frame == 120:
		get_viewport().get_texture().get_image() \
				.save_png("res://systems/procedural_map/test/_leaf_proof_close.png")
		print("SHOT_SAVED closeup")
		get_tree().quit()
