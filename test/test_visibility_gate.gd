extends Node
## TEST · VisibilityGate: los VISUALES de una entidad se apagan fuera del cono,
## pero su LÓGICA/COLISIÓN NO se toca (visibilidad != existencia).

var _pass := 0
var _fail := 0


func _ready() -> void:
	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.far = 2000.0
	add_child(cam)
	cam.global_position = Vector3.ZERO
	cam.look_at(Vector3(0, 0, -100), Vector3.UP)

	var vis := WorldVisibility.new()
	vis.authority_camera = cam
	vis.margin_m = 0.0
	vis.height_m = 50.0
	add_child(vis)

	# Entidad tipo prop: cuerpo con colisión + malla. Una ADELANTE y otra ATRÁS.
	var front := _make_entity(Vector3(0, 0, -60))
	var back := _make_entity(Vector3(0, 0, 60))
	await get_tree().process_frame
	for _i in 12:
		await get_tree().process_frame

	var gf: VisibilityGate = front.get_node("VisibilityGate")
	var gb: VisibilityGate = back.get_node("VisibilityGate")
	_check("gate_encuentra_la_autoridad", gf != null and gb != null, "")
	_check("adelante_se_dibuja", gf.is_shown(), "")
	_check("atras_NO_se_dibuja", not gb.is_shown(), "")
	_check("la_malla_de_atras_esta_oculta",
			not (back.get_node("Mesh") as MeshInstance3D).visible, "")

	# LA REGLA: la lógica y la colisión de la de atrás SIGUEN vivas.
	_check("la_entidad_de_atras_SIGUE_existiendo", is_instance_valid(back), "")
	_check("su_COLISION_sigue_activa",
			not (back.get_node("Col") as CollisionShape3D).disabled,
			"la colisión NO se debe tocar")
	_check("sigue_procesando_su_logica", back.is_processing(), "")

	print("VISIBILITY_GATE_TEST: %s (%d/%d)" % ["PASS" if _fail == 0 else "FAIL",
			_pass, _pass + _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _make_entity(pos: Vector3) -> Node3D:
	var body := StaticBody3D.new()
	add_child(body)
	body.global_position = pos
	body.set_process(true)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = BoxMesh.new()
	body.add_child(mi)
	var col := CollisionShape3D.new()
	col.name = "Col"
	col.shape = BoxShape3D.new()
	body.add_child(col)
	var g := VisibilityGate.new()
	g.name = "VisibilityGate"
	g.check_interval_s = 0.0
	body.add_child(g)
	return body


func _check(name: String, ok: bool, info: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s — %s" % [name, info])
