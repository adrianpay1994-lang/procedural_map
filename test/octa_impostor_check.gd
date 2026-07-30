extends Node3D

## ============================================================================
## octa_impostor_check · Verificación VISUAL del impostor octaédrico (§F8 T0)
## ============================================================================
## Corre con ventana (no headless): hornea el impostor octaédrico de un lapacho,
## pone el ÁRBOL REAL (izquierda) y el IMPOSTOR (derecha) lado a lado, orbita la
## cámara y guarda 4 capturas (yaw 0/72/144° + vista elevada 35°) en
## test/_octa_check_*.png, luego sale. Si el impostor funciona, su silueta
## CAMBIA entre capturas y se parece al árbol real desde cada ángulo.
##   godot --path . res://systems/procedural_map/test/octa_impostor_check.tscn
## ============================================================================

var _cam: Camera3D
var _shots: Array = []   # [{yaw, pitch, name}]
var _idx := 0
var _frame := 0
var _ready_to_shoot := false


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -60.0, 0.0)
	sun.light_energy = 1.2
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(120, 120)
	floor_mi.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.30, 0.4, 0.22)
	floor_mi.material_override = fmat
	add_child(floor_mi)

	_cam = Camera3D.new()
	_cam.fov = 55.0
	_cam.current = true
	add_child(_cam)

	_shots = [
		{"yaw": 0.0, "pitch": 8.0, "name": "yaw0"},
		{"yaw": 72.0, "pitch": 8.0, "name": "yaw72"},
		{"yaw": 144.0, "pitch": 8.0, "name": "yaw144"},
		{"yaw": 40.0, "pitch": 35.0, "name": "elev35"},
	]
	_setup.call_deferred()


func _setup() -> void:
	var params := TreeParams.lapacho()
	var tree_mesh := FloraFactory.make_tree(params, 42)
	# Árbol REAL a la izquierda.
	var real := MeshInstance3D.new()
	real.mesh = tree_mesh
	real.position = Vector3(-8, 0, 0)
	add_child(real)
	# Impostor OCTAÉDRICO a la derecha (mismo mesh de origen).
	var r: Dictionary = await ImpostorBaker.bake_octahedral(self, tree_mesh,
			"check_lapacho")
	if not r.get("ok", false):
		print("OCTA_CHECK: FAIL (bake no disponible)")
		get_tree().quit(1)
		return
	var imp := MeshInstance3D.new()
	imp.mesh = r["mesh"]
	imp.position = Vector3(8, 0, 0)
	add_child(imp)
	_ready_to_shoot = true


func _process(_d: float) -> void:
	if not _ready_to_shoot:
		return
	_frame += 1
	if _idx >= _shots.size():
		print("OCTA_CHECK: DONE (%d capturas)" % _shots.size())
		get_tree().quit(0)
		return
	var s: Dictionary = _shots[_idx]
	var yaw: float = deg_to_rad(s.yaw)
	var pitch: float = deg_to_rad(s.pitch)
	var dist := 34.0
	var h: float = 6.0 + tan(pitch) * dist
	_cam.position = Vector3(sin(yaw) * dist, h, cos(yaw) * dist)
	_cam.look_at(Vector3(0, 7, 0), Vector3.UP)
	# 20 frames de asentamiento por toma (mipmaps/streaming).
	if _frame % 20 == 0:
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://systems/procedural_map/test/_octa_check_%s.png" % s.name)
		print("  shot %s guardado" % s.name)
		_idx += 1
