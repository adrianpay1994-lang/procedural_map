extends Node3D

## Vitrina de sotobosque (arbustos, helecho, cactus, flor). Guarda PNG y sale.
## Correr CON ventana (no --headless).

const OUT := "res://systems/procedural_map/test/_understory_showcase.png"
var _frame := 0


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
	sun.rotation_degrees = Vector3(-48.0, -50.0, 0.0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)

	var floor_mi := MeshInstance3D.new()
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(24.0, 12.0)
	floor_mi.mesh = floor_mesh
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.32, 0.4, 0.24)
	fmat.roughness = 1.0
	floor_mi.material_override = fmat
	add_child(floor_mi)

	var items := [
		FloraFactory.make_tree(TreeParams.leafy_bush(), 7),
		FloraFactory.make_tree(TreeParams.dry_bush(), 7),
		FloraFactory.make_tree(TreeParams.juniper(), 7),
		PlantGenerator.make_fern(7),
		PlantGenerator.make_cactus(7),
		FloraFactory.make_flower(7, Color(0.95, 0.5, 0.6)),
		BiomeFloraLibrary.build_grass_blade("GRASSLAND"),
		BiomeFloraLibrary.build_grass_blade("TAIGA"),
		BiomeFloraLibrary.build_grass_blade("SUBTROPICAL_DESERT"),
	]
	var x := -8.0
	for m: ArrayMesh in items:
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.position = Vector3(x, 0.0, 0.0)
		# lo muy chico (flor, pasto corto) se agranda para verlo en la vitrina
		if m.get_aabb().size.y < 0.55:
			mi.scale = Vector3(2.5, 2.5, 2.5)
		add_child(mi)
		x += 2.0

	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.current = true
	add_child(cam)
	cam.look_at_from_position(Vector3(0.0, 2.4, 12.0), Vector3(0.0, 1.1, 0.0), Vector3.UP)


func _process(_d: float) -> void:
	_frame += 1
	if _frame == 12:
		var img := get_viewport().get_texture().get_image()
		img.save_png(OUT)
		print("SHOT_SAVED: %s" % ProjectSettings.globalize_path(OUT))
		get_tree().quit()
