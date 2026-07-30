extends Node3D

## ============================================================================
## Vivero · Exhibición de TODA la flora en filas etiquetadas (sin mapa procedural)
## ============================================================================
## Correr CON ventana. Muestra cada especie/planta/arbusto en grilla con su
## nombre (Label3D) + overlay de FPS. Guarda PNG panorámico. Para iterar el arte
## rápido sin generar el mapa entero.
##   godot --path . res://systems/procedural_map/test/vivero.tscn
##   (arg opcional: "trees" | "plants" | "bushes" para filtrar; "shot" para 1 PNG)

const OUT := "res://systems/procedural_map/test/_vivero.png"
const COLS := 6
const GAP := 9.0

## Config data-driven de flora (Inspector): cambia hoja/corteza por categoría para
## previsualizar. null = look procedural por defecto. También se puede probar por
## CLI: args "leaf=<textura>" y/o "bark=<tipo>" arman una config al vuelo.
@export var flora_config: FloraConfig

var _frame := 0
var _fps_label: Label
var _shot_only := false


func _ready() -> void:
	var filter := ""
	var ua := OS.get_cmdline_user_args()
	if ua.size() >= 1:
		filter = ua[0]
	_shot_only = ua.has("shot")
	# FloraConfig: la del Inspector, o una al vuelo por CLI para verificar:
	#   leaf=<textura> · bark=<tipo> · barkimg (corteza = cliff CC0) · density=<0-1>
	for a in ua:
		if not (a.begins_with("leaf=") or a.begins_with("bark=")
				or a == "barkimg" or a.begins_with("density=")):
			continue
		if flora_config == null:
			flora_config = FloraConfig.new()
		if a.begins_with("leaf="):
			var ls := LeafStyle.new()
			ls.procedural_shape = a.trim_prefix("leaf=")
			flora_config.tree_leaf = ls
			flora_config.bush_leaf = ls
		elif a.begins_with("density="):
			if flora_config.tree_leaf == null:
				flora_config.tree_leaf = LeafStyle.new()
			flora_config.tree_leaf.canopy_density = a.trim_prefix("density=").to_float()
			flora_config.tree_leaf.spray_scale = 2.4   # compensa: menos sprays, más grandes
			flora_config.bush_leaf = flora_config.tree_leaf
		elif a == "barkimg":
			var bi := BarkStyle.new()
			bi.albedo_texture = load("res://assets/terrain/cliff_albedo.png")
			bi.normal_texture = load("res://assets/terrain/cliff_normal.png")
			flora_config.bark = bi
		else:
			var bs := BarkStyle.new()
			bs.bark_type = a.trim_prefix("bark=")
			flora_config.bark = bs
	# Sin config propia → previsualizar la GLOBAL del jugador (la que vale en los mapas).
	if flora_config == null:
		flora_config = FloraConfig.load_global()
	# "saveglobal": persistir la config actual como global (el player la lee en todo
	# mapa). "clearglobal": volver al look por defecto en todos lados.
	if ua.has("clearglobal"):
		FloraConfig.clear_global()
		print("FloraConfig: global BORRADA (look por defecto en todos los mapas)")
	elif ua.has("saveglobal") and flora_config != null:
		flora_config.save_global()
		print("FloraConfig: config GUARDADA como global (vale en todo mapa)")
	FloraConfig.active = flora_config
	# Hornear "modelo de hoja → imagen" (filas con modelo_a_imagen) antes de armar.
	if flora_config != null:
		await flora_config.prepare_bakes(self)

	# Ambiente.
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46.0, -55.0, 0.0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(COLS * GAP + 20.0, 90.0)
	floor_mi.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.34, 0.42, 0.24)
	fmat.roughness = 1.0
	floor_mi.material_override = fmat
	floor_mi.position = Vector3(COLS * GAP * 0.5 - GAP * 0.5, 0.0, -18.0)
	add_child(floor_mi)

	var items := _catalog(filter)
	# REGISTRO: tabla especie → verts/textura de hoja/corteza en consola (y verts
	# bajo cada etiqueta 3D) — "ver cuántos polígonos tiene cada flora".
	print("REGISTRO FLORA (%s): %d ítems" % [filter if filter != "" else "todo", items.size()])
	var i := 0
	for it: Array in items:
		var mesh: Mesh = it[1].call()
		if mesh == null:
			continue
		var verts := _mesh_verts(mesh)
		var p: TreeParams = _preset(it[0])
		print("  %-18s %7d verts%s" % [it[0], verts,
				("  hoja=%s corteza=%s" % [p.leaf_texture, p.bark_type]) if p != null else ""])
		var col := i % COLS
		var row := floori(i / float(COLS))   # fila de grilla: división entera intencional
		var pos := Vector3(col * GAP, 0.0, -row * GAP * 2.6)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = pos
		add_child(mi)
		var lbl := Label3D.new()
		lbl.text = "%s\n%s verts" % [it[0], _fmt_k(verts)]
		lbl.font_size = 64
		lbl.pixel_size = 0.022
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.modulate = Color(1, 1, 0.85)
		lbl.outline_size = 12
		lbl.position = pos + Vector3(0.0, 0.4, 1.2)
		add_child(lbl)
		i += 1

	# Cámara panorámica que abarca la grilla.
	var rows := int(ceil(float(items.size()) / float(COLS)))
	var cx := (COLS - 1) * GAP * 0.5
	var cz := -(rows - 1) * GAP * 2.6 * 0.5
	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.current = true
	add_child(cam)
	var dist := maxf(COLS * GAP, rows * GAP * 2.6) * 0.75 + 30.0
	cam.look_at_from_position(Vector3(cx, 34.0, cz + dist),
			Vector3(cx, 9.0, cz), Vector3.UP)

	# Overlay FPS (para correr interactivo).
	var cl := CanvasLayer.new()
	add_child(cl)
	_fps_label = Label.new()
	_fps_label.position = Vector2(16, 12)
	_fps_label.add_theme_font_size_override("font_size", 28)
	_fps_label.add_theme_color_override("font_color", Color(1, 1, 0.4))
	_fps_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_fps_label.add_theme_constant_override("outline_size", 6)
	cl.add_child(_fps_label)


func _process(_d: float) -> void:
	_frame += 1
	if _fps_label != null:
		_fps_label.text = "FPS: %d · config: Inspector del nodo Vivero (Acciones = guardar global/perfil)" \
				% Engine.get_frames_per_second()
	if _frame == 30 and _shot_only:
		var img := get_viewport().get_texture().get_image()
		img.save_png(OUT)
		print("SHOT_SAVED: %s" % ProjectSettings.globalize_path(OUT))
		get_tree().quit()


## Catálogo [nombre, Callable→Mesh]. filter: ""|trees|plants|bushes.
func _catalog(filter: String) -> Array:
	var trees := [
		"araucaria", "palo_rosa", "lapacho", "lapacho_amarillo", "ceibo", "cedro",
		"timbo", "guatambu", "laurel", "ibira_pita", "ombu", "algarrobo",
		"quebracho", "chanar", "palo_borracho", "espinillo", "tala", "arrayan",
		"coihue", "nire", "notro", "aspen", "black_oak", "silver_birch",
		"balsam_fir", "small_pine",
		# Misiones nuevas (FLORA_MISIONES §7) + presets que faltaban en el vivero:
		"incienso", "peteribi", "anchico", "yerba_mate", "ambay",
		"quebracho_blanco", "maiten", "tipa", "cipres_cordillera",
		"calafate", "neneo",
	]
	var bushes := ["leafy_bush", "dry_bush", "juniper", "hideout_bush", "hideout_bush_dry"]
	# Plantas + flores con NOMBRE real (la flor genérica básica se reemplazó por
	# margarita y diente de león en sus 3 etapas).
	var plants := ["fern", "tree_fern", "palmito", "guembe", "bamboo", "caladium", "reed", "cactus",
			"pampas", "grass", "bush", "margarita", "amancay", "trebol",
			"diente_leon_flor", "diente_leon_bocha", "diente_leon_pelado"]
	var out: Array = []
	if filter == "" or filter == "trees":
		for nm: String in trees:
			out.append([nm, func() -> Mesh: return _tree(nm, "tree")])
	if filter == "" or filter == "bushes":
		for nm: String in bushes:
			out.append([nm, func() -> Mesh: return _tree(nm, "bush")])
	if filter == "" or filter == "plants":
		for nm: String in plants:
			var pn := nm
			out.append([pn, func() -> Mesh: return _plant(pn)])
	return out


## Vértices totales de un mesh (para el registro de polígonos del vivero).
func _mesh_verts(m: Mesh) -> int:
	var am := m as ArrayMesh
	if am == null:
		return 0
	var t := 0
	for s in am.get_surface_count():
		t += (am.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return t


## "12.4k" para etiquetas cortas.
func _fmt_k(n: int) -> String:
	return "%.1fk" % (n / 1000.0) if n >= 1000 else str(n)


func _tree(nm: String, category: String = "tree") -> Mesh:
	var p := _preset(nm)
	if p == null:
		return null
	p = FloraConfig.apply_active(p, category)
	return FloraFactory.make_tree(p, 7)


func _plant(nm: String) -> Mesh:
	match nm:
		"fern": return PlantGenerator.make_fern(7)
		"tree_fern": return PlantGenerator.make_tree_fern(7)
		"palmito": return PlantGenerator.make_palmito(7)
		"bamboo": return PlantGenerator.make_bamboo(7)
		"caladium": return PlantGenerator.make_caladium(7)
		"guembe": return PlantGenerator.make_guembe(7)
		"reed": return PlantGenerator.make_reed(7)
		"cactus": return PlantGenerator.make_cactus(7)
		"pampas": return FloraFactory.make_pampas_grass(7)
		"grass": return FloraFactory.make_grass_tuft(Color(0.4, 0.52, 0.24), 1.2, 11, 7)
		"bush": return FloraFactory.make_bush(7, Color(0.3, 0.46, 0.2))
		"margarita": return FloraFactory.make_daisy(7)
		"amancay": return FloraFactory.make_amancay(7)
		"trebol": return FloraFactory.make_clover(7)
		"diente_leon_flor": return FloraFactory.make_dandelion(7, 0)
		"diente_leon_bocha": return FloraFactory.make_dandelion(7, 1)
		"diente_leon_pelado": return FloraFactory.make_dandelion(7, 2)
		_: return null


func _preset(nm: String) -> TreeParams:
	match nm:
		"araucaria": return TreeParams.araucaria()
		"palo_rosa": return TreeParams.palo_rosa()
		"lapacho": return TreeParams.lapacho()
		"lapacho_amarillo": return TreeParams.lapacho_amarillo()
		"ceibo": return TreeParams.ceibo()
		"cedro": return TreeParams.cedro()
		"timbo": return TreeParams.timbo()
		"guatambu": return TreeParams.guatambu()
		"laurel": return TreeParams.laurel()
		"ibira_pita": return TreeParams.ibira_pita()
		"ombu": return TreeParams.ombu()
		"algarrobo": return TreeParams.algarrobo()
		"quebracho": return TreeParams.quebracho()
		"chanar": return TreeParams.chanar()
		"palo_borracho": return TreeParams.palo_borracho()
		"espinillo": return TreeParams.espinillo()
		"tala": return TreeParams.tala()
		"arrayan": return TreeParams.arrayan()
		"coihue": return TreeParams.coihue()
		"nire": return TreeParams.nire()
		"notro": return TreeParams.notro()
		"aspen": return TreeParams.aspen()
		"black_oak": return TreeParams.black_oak()
		"silver_birch": return TreeParams.silver_birch()
		"balsam_fir": return TreeParams.balsam_fir()
		"small_pine": return TreeParams.small_pine()
		"incienso": return TreeParams.incienso()
		"peteribi": return TreeParams.peteribi()
		"anchico": return TreeParams.anchico()
		"yerba_mate": return TreeParams.yerba_mate()
		"ambay": return TreeParams.ambay()
		"quebracho_blanco": return TreeParams.quebracho_blanco()
		"maiten": return TreeParams.maiten()
		"tipa": return TreeParams.tipa()
		"cipres_cordillera": return TreeParams.cipres_cordillera()
		"calafate": return TreeParams.calafate()
		"neneo": return TreeParams.neneo()
		"leafy_bush": return TreeParams.leafy_bush()
		"dry_bush": return TreeParams.dry_bush()
		"juniper": return TreeParams.juniper()
		"hideout_bush": return TreeParams.hideout_bush()
		"hideout_bush_dry": return TreeParams.hideout_bush_dry()
		_: return null
