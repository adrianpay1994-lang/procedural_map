extends Node3D

## Close-up de pocos árboles para juzgar corteza (relieve/color) y follaje de
## cerca. Correr CON ventana. Guarda PNG. La especie sale del 1er arg de usuario
## (default araucaria,lapacho,algarrobo).

const OUT := "res://systems/procedural_map/test/_tree_closeup.png"
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
	sun.rotation_degrees = Vector3(-42.0, -46.0, 0.0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	add_child(sun)

	var floor_mi := MeshInstance3D.new()
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(40.0, 40.0)
	floor_mi.mesh = floor_mesh
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.30, 0.38, 0.22)
	fmat.roughness = 1.0
	floor_mi.material_override = fmat
	add_child(floor_mi)

	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.current = true
	add_child(cam)
	var ua := OS.get_cmdline_user_args()
	var bark := ua.size() >= 2 and ua[1] == "bark"

	var names := ["araucaria", "lapacho", "algarrobo"]
	if ua.size() >= 1:
		names = ua[0].split(",")

	# Construir meshes y auto-encuadrar por la altura/ancho reales (sirve para
	# árboles de 25 m y para plantas de 1 m).
	var built: Array = []   # [nombre, mesh, aabb]
	var max_h := 1.0
	for nm: String in names:
		var mesh: Mesh = null
		var p := _preset(nm)
		if p != null:
			mesh = FloraFactory.make_tree(p, 5)
		else:
			mesh = _plant(nm)
		if mesh == null:
			continue
		var ab := mesh.get_aabb()
		built.append([nm, mesh, ab])
		max_h = maxf(max_h, ab.position.y + ab.size.y)

	var spacing := 0.0
	for it: Array in built:
		var ab: AABB = it[2]
		spacing = maxf(spacing, maxf(ab.size.x, ab.size.z))
	spacing = maxf(spacing * 1.25, 2.0)
	var total_w := spacing * maxf(built.size(), 1)

	var x := -(total_w - spacing) * 0.5
	for it: Array in built:
		var mi := MeshInstance3D.new()
		mi.mesh = it[1]
		mi.position = Vector3(x, 0.0, 0.0)
		add_child(mi)
		var lbl := Label3D.new()
		lbl.text = it[0]
		lbl.font_size = 56
		lbl.pixel_size = maxf(max_h, 6.0) * 0.0016
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.modulate = Color(1, 1, 0.7)
		lbl.outline_size = 10
		lbl.position = Vector3(x, -0.4, spacing * 0.35)
		add_child(lbl)
		x += spacing

	# Encuadre: la cámara retrocede para que entre todo el ancho y la altura.
	var fit := maxf(total_w * 0.62, max_h * 0.62)
	var dist := fit / tan(deg_to_rad(cam.fov * 0.5)) + spacing * 0.4
	if bark:
		cam.look_at_from_position(Vector3(0.0, max_h * 0.32, spacing * 0.9),
				Vector3(0.0, max_h * 0.38, 0.0), Vector3.UP)
	else:
		cam.look_at_from_position(Vector3(0.0, max_h * 0.5, dist),
				Vector3(0.0, max_h * 0.46, 0.0), Vector3.UP)
	print("CLOSEUP trees=%d max_h=%.1f" % [built.size(), max_h])


func _preset(nm: String) -> TreeParams:
	match nm:
		"araucaria": return TreeParams.araucaria()
		"palo_rosa": return TreeParams.palo_rosa()
		"lapacho": return TreeParams.lapacho()
		"ceibo": return TreeParams.ceibo()
		"ombu": return TreeParams.ombu()
		"algarrobo": return TreeParams.algarrobo()
		"coihue": return TreeParams.coihue()
		"silver_birch": return TreeParams.silver_birch()
		"aspen": return TreeParams.aspen()
		"black_oak": return TreeParams.black_oak()
		"balsam_fir": return TreeParams.balsam_fir()
		"small_pine": return TreeParams.small_pine()
		"cedro": return TreeParams.cedro()
		"timbo": return TreeParams.timbo()
		"guatambu": return TreeParams.guatambu()
		"laurel": return TreeParams.laurel()
		"ibira_pita": return TreeParams.ibira_pita()
		"quebracho": return TreeParams.quebracho()
		"chanar": return TreeParams.chanar()
		"palo_borracho": return TreeParams.palo_borracho()
		"espinillo": return TreeParams.espinillo()
		"tala": return TreeParams.tala()
		"arrayan": return TreeParams.arrayan()
		"nire": return TreeParams.nire()
		"notro": return TreeParams.notro()
		"quebracho_blanco": return TreeParams.quebracho_blanco()
		"maiten": return TreeParams.maiten()
		"cipres_cordillera": return TreeParams.cipres_cordillera()
		"tipa": return TreeParams.tipa()
		"calafate": return TreeParams.calafate()
		"neneo": return TreeParams.neneo()
		"ambay": return TreeParams.ambay()
		"incienso": return TreeParams.incienso()
		"peteribi": return TreeParams.peteribi()
		"anchico": return TreeParams.anchico()
		"yerba_mate": return TreeParams.yerba_mate()
		"lapacho_amarillo": return TreeParams.lapacho_amarillo()
		"guatambu": return TreeParams.guatambu()
		"laurel": return TreeParams.laurel()
		_: return null


func _plant(nm: String) -> Mesh:
	match nm:
		"pampas": return FloraFactory.make_pampas_grass(5)
		"fern": return PlantGenerator.make_fern(5)
		"tree_fern": return PlantGenerator.make_tree_fern(5)
		"bamboo": return PlantGenerator.make_bamboo(5)
		"caladium": return PlantGenerator.make_caladium(5)
		"reed": return PlantGenerator.make_reed(5)
		"cactus": return PlantGenerator.make_cactus(5)
		"grass": return FloraFactory.make_grass_tuft(Color(0.4, 0.52, 0.24), 1.2, 11, 5)
		"flower": return FloraFactory.make_flower(5, Color(0.9, 0.45, 0.6))
		"flower2": return FloraFactory.make_flower(11, Color(0.75, 0.6, 0.95))
		"dandelion": return FloraFactory.make_dandelion(5, 0)
		"dandelion_puff": return FloraFactory.make_dandelion(7, 1)
		"daisy": return FloraFactory.make_daisy(5)
		"daisy2": return FloraFactory.make_daisy(9, Color(0.8, 0.6, 0.95))
		"amancay": return FloraFactory.make_amancay(5)
		"trebol": return FloraFactory.make_clover(5)
		_: return null


func _process(_d: float) -> void:
	_frame += 1
	if _frame == 30:
		var img := get_viewport().get_texture().get_image()
		img.save_png(OUT)
		print("SHOT_SAVED: %s" % ProjectSettings.globalize_path(OUT))
		get_tree().quit()
