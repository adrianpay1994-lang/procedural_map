extends Node3D

## Prueba del DayNightCycle: arma sol+luna+entorno+árboles y captura el cielo a
## una hora dada. Correr CON ventana.
##   godot --path . res://systems/procedural_map/test/day_night_test.tscn -- 0.5
## arg1 = time_of_day [0,1] (0.25 amanecer, 0.5 mediodía, 0.9 noche). "loop" = no captura.

var _frame := 0
var _loop := false


func _ready() -> void:
	var t := 0.5
	var ua := OS.get_cmdline_user_args()
	if ua.size() >= 1 and ua[0].is_valid_float():
		t = ua[0].to_float()
	_loop = ua.has("loop")

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.002
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	add_child(sun)
	var moon := DirectionalLight3D.new()
	add_child(moon)

	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(120, 120)
	floor_mi.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.30, 0.4, 0.22)
	fmat.roughness = 1.0
	floor_mi.material_override = fmat
	add_child(floor_mi)

	# Un árbol de silueta (1 solo → render rápido en software).
	var mi := MeshInstance3D.new()
	mi.mesh = FloraFactory.make_tree(TreeParams.lapacho(), 5)
	mi.position = Vector3(0, 0, -8)
	add_child(mi)

	var cyc := DayNightCycle.new()
	cyc.sun = sun
	cyc.moon = moon
	cyc.world_environment = we
	cyc.time_of_day = t
	cyc.paused = not _loop
	cyc.day_length_s = 20.0 if _loop else 300.0
	add_child(cyc)

	print("DBG sky_material=", we.environment.sky.sky_material)

	var cam := Camera3D.new()
	cam.current = true
	cam.fov = 62.0
	add_child(cam)
	# Mirar EL CIELO (30° arriba): las nubes/estrellas viven sobre el horizonte.
	cam.look_at_from_position(Vector3(0, 6, 26), Vector3(0, 26, -10), Vector3.UP)

	var cl := CanvasLayer.new()
	add_child(cl)
	var lbl := Label.new()
	lbl.position = Vector2(16, 12)
	lbl.add_theme_font_size_override("font_size", 26)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 6)
	lbl.text = "t=%.2f · %s" % [t, cyc.phase()]
	cl.add_child(lbl)


func _process(_d: float) -> void:
	_frame += 1
	if _frame == 20 and not _loop:
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://systems/procedural_map/test/_daynight.png")
		print("SHOT_SAVED")
		get_tree().quit()
