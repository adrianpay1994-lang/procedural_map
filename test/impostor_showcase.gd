extends Node3D

## Prueba del impostor: árbol REAL (izq) vs IMPOSTOR horneado (der). Guarda PNG.
## Correr CON ventana (el bake necesita render real). _ready es async.

const OUT := "res://systems/procedural_map/test/_impostor_showcase.png"


func _ready() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, -50.0, 0.0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var fm := PlaneMesh.new()
	fm.size = Vector2(40.0, 20.0)
	floor_mi.mesh = fm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.34, 0.42, 0.26)
	floor_mi.material_override = fmat
	add_child(floor_mi)

	var mesh := FloraFactory.make_tree(TreeParams.black_oak(), 7)
	var real := MeshInstance3D.new()
	real.mesh = mesh
	real.position = Vector3(-4.5, 0.0, 0.0)
	add_child(real)

	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.current = true
	add_child(cam)
	cam.look_at_from_position(Vector3(0.0, 6.0, 22.0), Vector3(0.0, 5.0, 0.0), Vector3.UP)

	# Hornear el impostor (async) y ponerlo a la derecha.
	var res := await ImpostorBaker.bake(self, mesh, 256)
	if res.get("ok", false):
		var imp := MeshInstance3D.new()
		imp.mesh = res["mesh"]
		imp.position = Vector3(4.5, 0.0, 0.0)
		add_child(imp)
	else:
		push_warning("Impostor bake falló (headless?)")

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(OUT)
	print("SHOT_SAVED: %s" % ProjectSettings.globalize_path(OUT))
	get_tree().quit()
