extends Node3D

## Vitrina del océano: plano de agua (OceanWater) subdividido sobre un lecho.
## Guarda PNG y sale. Correr CON ventana (no --headless).

const OUT := "res://systems/procedural_map/test/_ocean_showcase.png"
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
	sun.rotation_degrees = Vector3(-25.0, -110.0, 0.0)  # sol bajo = reflejo largo
	sun.light_energy = 1.4
	add_child(sun)

	# Lecho marino (para profundidad Beer-Lambert): sube hacia una "playa".
	var bed := MeshInstance3D.new()
	var bm := PlaneMesh.new()
	bm.size = Vector2(160.0, 160.0)
	bed.mesh = bm
	bed.position = Vector3(0.0, -3.0, 0.0)
	bed.rotation_degrees = Vector3(4.0, 0.0, 0.0)  # rampa suave → orilla somera
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.6, 0.54, 0.38)
	bmat.roughness = 1.0
	bed.material_override = bmat
	add_child(bed)

	# Agua: plano subdividido (Gerstner necesita vértices) con OceanWater.
	var water := MeshInstance3D.new()
	var wm := PlaneMesh.new()
	wm.size = Vector2(160.0, 160.0)
	wm.subdivide_width = 160
	wm.subdivide_depth = 160
	water.mesh = wm
	var wmat := ShaderMaterial.new()
	wmat.shader = load("res://shaders/OceanWater.gdshader")
	water.material_override = wmat
	add_child(water)

	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.current = true
	add_child(cam)
	cam.look_at_from_position(Vector3(0.0, 3.0, 26.0), Vector3(0.0, 0.0, -20.0), Vector3.UP)


func _process(_d: float) -> void:
	_frame += 1
	if _frame == 30:  # dejar animar las olas un instante
		var img := get_viewport().get_texture().get_image()
		img.save_png(OUT)
		print("SHOT_SAVED: %s" % ProjectSettings.globalize_path(OUT))
		get_tree().quit()
