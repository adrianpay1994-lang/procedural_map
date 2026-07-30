extends Node3D

## ============================================================================
## lod_compare · Fidelidad de LOD: full 3D · cruzadas (imagen) · impostor, mismo
## árbol al MISMO tamaño, lado a lado. Verifica que la imagen 2D coincida con la
## silueta/altura/ancho reales (reporte del usuario "cambia de tamaño").
##   godot --path . res://systems/procedural_map/test/lod_compare.tscn -- shot [especie]
## ============================================================================

const OUT := "res://systems/procedural_map/test/_lod_compare.png"
var _frame := 0
var _shot := false
var _ready_done := false


func _ready() -> void:
	var ua := OS.get_cmdline_user_args()
	_shot = ua.has("shot")
	var species := "lapacho"
	for a in ua:
		if a != "shot" and not a.is_valid_float():
			species = a

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46, -55, 0)
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(80, 40)
	floor_mi.mesh = pm
	var fmat := StandardMaterial3D.new(); fmat.albedo_color = Color(0.33, 0.42, 0.24)
	floor_mi.material_override = fmat
	add_child(floor_mi)

	var p := _preset(species)
	var full := FloraFactory.make_tree(p, 7) as ArrayMesh
	# Bakear el impostor octaédrico del MISMO mesh.
	var octa: Dictionary = await ImpostorBaker.bake_octahedral(self, full, "cmp_%s" % species)
	var crossed: Mesh = null
	var impostor: Mesh = null
	if octa.get("ok", false):
		impostor = octa["mesh"]
		crossed = ImpostorBaker.make_crossed_from_octa(octa)

	var fb := full.get_aabb()
	print("LODCMP %s full: alto=%.1f ancho=%.1f | impostor span=%.1f center_y=%.1f"
			% [species, fb.size.y, maxf(fb.size.x, fb.size.z),
			octa.get("span", 0.0), octa.get("center_y", 0.0)])

	var items: Array = [[full, -12.0, "FULL 3D"], [crossed, 0.0, "CRUZADAS (img)"],
			[impostor, 12.0, "IMPOSTOR (img)"]]
	for it: Array in items:
		if it[0] == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = it[0]
		mi.position = Vector3(it[1], 0, 0)
		add_child(mi)
		var lbl := Label3D.new()
		lbl.text = it[2]
		lbl.pixel_size = 0.02; lbl.font_size = 64
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true; lbl.outline_size = 12
		lbl.position = Vector3(it[1], 1.0, 6.0)
		add_child(lbl)

	var cam := Camera3D.new()
	cam.current = true; cam.fov = 55.0
	add_child(cam)
	var h := fb.size.y
	cam.look_at_from_position(Vector3(0, h * 0.5, h * 2.4), Vector3(0, h * 0.5, 0), Vector3.UP)
	_ready_done = true
	_frame = 0


func _process(_d: float) -> void:
	if not _ready_done:
		return
	_frame += 1
	if _shot and _frame == 20:
		get_viewport().get_texture().get_image().save_png(OUT)
		print("SHOT_SAVED")
		get_tree().quit()


func _preset(nm: String) -> TreeParams:
	for entry in FloraCatalog.species():
		if entry == nm:
			return (FloraCatalog.species()[nm] as Callable).call()
	return TreeParams.lapacho()
