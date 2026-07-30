extends Node3D

## Vitrina de árboles: una especie por árbol en fila, sol+cielo+piso, y guarda
## un PNG a res://systems/procedural_map/test/_tree_showcase.png. Correr CON
## ventana (no --headless, si no el renderer dummy no dibuja).

const OUT := "res://systems/procedural_map/test/_tree_showcase.png"
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
	floor_mesh.size = Vector2(60.0, 24.0)
	floor_mi.mesh = floor_mesh
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.32, 0.4, 0.24)
	fmat.roughness = 1.0
	floor_mi.material_override = fmat
	add_child(floor_mi)

	var species := [
		["araucaria", TreeParams.araucaria()],
		["palo_rosa", TreeParams.palo_rosa()],
		["lapacho", TreeParams.lapacho()],
		["ceibo", TreeParams.ceibo()],
		["ombu", TreeParams.ombu()],
		["algarrobo", TreeParams.algarrobo()],
	]
	var x := -20.0
	for sp: Array in species:
		# fila delante = LOD cercano (full)
		var mi := MeshInstance3D.new()
		mi.mesh = FloraFactory.make_tree(sp[1], 7)
		mi.position = Vector3(x, 0.0, 4.0)
		add_child(mi)
		# fila atrás = LOD lejano (malla barata) — debe leerse como el mismo árbol
		var far := MeshInstance3D.new()
		far.mesh = BiomeFloraLibrary.build_tree_lod_pool(sp[1], 7, 1)[0]
		far.position = Vector3(x, 0.0, -10.0)
		add_child(far)
		x += 8.0

	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.current = true
	add_child(cam)
	cam.look_at_from_position(Vector3(0.0, 15.0, 64.0), Vector3(0.0, 13.0, 0.0), Vector3.UP)


func _process(_d: float) -> void:
	_frame += 1
	if _frame == 12:
		var img := get_viewport().get_texture().get_image()
		img.save_png(OUT)
		print("SHOT_SAVED: %s" % ProjectSettings.globalize_path(OUT))
		get_tree().quit()
