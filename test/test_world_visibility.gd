extends Node
## TEST · WorldVisibility: LA autoridad única de "qué existe".
## Verifica la cadena que pidió el usuario, en orden:
##   1) la CÁMARA del player define el cono;
##   2) el cono decide qué SUBDIVISIONES existen (lo de atrás NO);
##   3) lo que hay DENTRO de esas subdivisiones (árboles, pasto, props) hereda la
##      misma decisión — un solo dueño, nadie renderiza de más.

var _pass := 0
var _fail := 0


func _ready() -> void:
	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.far = 2000.0
	add_child(cam)
	cam.global_position = Vector3.ZERO
	cam.look_at(Vector3(0, 0, -100), Vector3.UP)   # mira hacia -Z

	var vis := WorldVisibility.new()
	vis.authority_camera = cam
	vis.margin_m = 0.0        # sin colchón: el test mide el cono puro
	vis.height_m = 50.0
	add_child(vis)
	await get_tree().process_frame
	await get_tree().process_frame

	# 1) La cámara manda: hay cono.
	_check("hay_cono", vis.stats().has_cone, "sin planos de frustum")

	# 2) Adelante SÍ, atrás NO. Es la regla que el usuario repitió: lo que no está
	#    en el cono no existe, por más cerca que esté.
	_check("adelante_existe", vis.area_in_frustum(Vector2(0, -60), 20.0), "z=-60 (enfrente)")
	_check("atras_NO_existe", not vis.area_in_frustum(Vector2(0, 60), 20.0), "z=+60 (detrás)")
	_check("costado_NO_existe", not vis.area_in_frustum(Vector2(300, -20), 20.0),
			"x=300 (muy al costado)")

	# 3) Una parcela GRANDE que solo roza el cono sigue contando como visible (el
	#    quadtree la parte después): se comprueba que el test es por caja, no por centro.
	_check("parcela_grande_que_roza_cuenta", vis.area_in_frustum(Vector2(120, -60), 200.0),
			"caja de 200 m que cruza el borde")

	# 4) El interruptor maestro apaga TODO el descarte (modo comparación).
	vis.cone_only = false
	_check("interruptor_apaga_el_descarte", vis.area_in_frustum(Vector2(0, 60), 20.0),
			"con cone_only=false todo debe existir")
	vis.cone_only = true

	# 5) Girar la cámara cambia qué existe (el mundo sigue al player, no al revés).
	cam.look_at(Vector3(0, 0, 100), Vector3.UP)     # ahora mira hacia +Z
	await get_tree().process_frame
	await get_tree().process_frame
	_check("al_girar_cambia_lo_que_existe", vis.area_in_frustum(Vector2(0, 60), 20.0)
			and not vis.area_in_frustum(Vector2(0, -60), 20.0),
			"tras girar 180°, lo de atrás pasa a existir y lo de adelante no")

	# 6) Diagnóstico: cuenta consultas y rechazos (para el HUD).
	var st: Dictionary = vis.stats()
	print("WORLD_VIS: consultas=%d rechazadas=%d cono=%s" % [
			st.asked, st.rejected, str(st.cone_only)])

	print("WORLD_VISIBILITY_TEST: %s (%d/%d)" % ["PASS" if _fail == 0 else "FAIL",
			_pass, _pass + _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(name: String, ok: bool, info: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s — %s" % [name, info])
