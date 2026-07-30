extends Node3D

## ============================================================================
## leaf_bake_check · Prueba REAL de "modelo 3D de hoja → IMAGEN" (FloraConfig)
## ============================================================================
## Dos árboles IGUALES (misma especie/semilla) lado a lado:
##   IZQUIERDA = copa con un MODELO 3D de hoja instanciado en cada punto (pesado)
##   DERECHA   = ese MISMO modelo HORNEADO a imagen una vez → cards baratas
## Imprime los vértices de cada uno y guarda PNG. Correr CON ventana:
##   godot --path . res://systems/procedural_map/test/leaf_bake_check.tscn -- shot
## ============================================================================

const OUT := "res://systems/procedural_map/test/_leaf_bake_check.png"

var _frame := 0
var _shot := false


func _verts(m: ArrayMesh) -> int:
	var t := 0
	for i in m.get_surface_count():
		t += (m.surface_get_arrays(i)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return t


func _ready() -> void:
	_shot = OS.get_cmdline_user_args().has("shot")
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46.0, -55.0, 0.0)
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80, 60)
	floor_mi.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.32, 0.42, 0.24)
	floor_mi.material_override = fm
	add_child(floor_mi)

	# El "modelo 3D de hoja" del usuario: helecho procedural = GEOMETRÍA real
	# (cintas sólidas, 330 verts), no cards. Simula un .glb propio.
	var leaf_model := PlantGenerator.make_fern(7)

	# --- IZQUIERDA: modelo 3D instanciado en cada punto de hoja ---
	var cfg := FloraConfig.new()
	var row := cfg._leaf_type_style("broadleaf")
	row.modelo = leaf_model
	row.modelo_a_imagen = false
	FloraConfig.active = cfg
	var p3d := FloraConfig.apply_active(TreeParams.black_oak(), "tree")
	var tree_3d := FloraFactory.make_tree(p3d, 7) as ArrayMesh

	# --- DERECHA: el MISMO modelo horneado a IMAGEN (1 bake) → cards ---
	row.modelo_a_imagen = true
	await cfg.prepare_bakes(self)
	var pimg := FloraConfig.apply_active(TreeParams.black_oak(), "tree")
	var tree_img := FloraFactory.make_tree(pimg, 7) as ArrayMesh
	FloraConfig.active = null

	var v3d := _verts(tree_3d)
	var vimg := _verts(tree_img)
	print("LEAF_BAKE modelo3d=%d verts · imagen=%d verts (%.0f%%) · bake_ok=%s"
			% [v3d, vimg, 100.0 * vimg / maxf(v3d, 1.0), not FloraConfig._baked.is_empty()])

	for data: Array in [[tree_3d, -11.0, "MODELO 3D · %d verts" % v3d],
			[tree_img, 11.0, "IMAGEN (horneada) · %d verts" % vimg]]:
		var mi := MeshInstance3D.new()
		mi.mesh = data[0]
		mi.position = Vector3(data[1], 0, 0)
		add_child(mi)
		var lbl := Label3D.new()
		lbl.text = data[2]
		lbl.font_size = 72
		lbl.pixel_size = 0.02
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.outline_size = 14
		lbl.position = Vector3(data[1], 1.0, 8.0)
		add_child(lbl)

	var cam := Camera3D.new()
	cam.current = true
	cam.fov = 62.0
	add_child(cam)
	var h := tree_3d.get_aabb().size.y
	cam.look_at_from_position(Vector3(0, h * 0.55, h * 1.9),
			Vector3(0, h * 0.5, 0), Vector3.UP)


func _process(_d: float) -> void:
	_frame += 1
	if _shot and _frame == 40:
		get_viewport().get_texture().get_image().save_png(OUT)
		print("SHOT_SAVED: %s" % ProjectSettings.globalize_path(OUT))
		get_tree().quit()
