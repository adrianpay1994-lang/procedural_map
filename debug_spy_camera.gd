extends Node

## ============================================================================
## DebugSpyCamera · F7 en el JUEGO: ver SOLO lo que renderiza el player
## ============================================================================
## Nodo de DEBUG (vive en procedural_map.tscn — borrarlo lo desactiva).
## F7: la cámara se DESACOPLA del player y volás libre (WASD+mouse, Shift
## rápido, E/Q sube/baja) — pero el mundo se CULLEA contra el frustum de la
## CÁMARA DEL PLAYER: a los costados de su cono NO se renderiza nada (vacío).
## El cono se dibuja en amarillo. Pasto y raleo siguen obedeciendo al player
## (camera_override). F8 (con F7 activo): wireframe de TODO lo que se dibuja.
## F7 de nuevo: volvés al player y se restaura todo.
## Inerte en tests/headless: solo reacciona a input.
## ============================================================================

const UPDATE_S := 0.12

## Emitida al entrar/salir del modo espía. El dueño del player (banco o juego) DEBE
## congelar su cámara mientras esté activo: con F7 el player NO se mueve.
signal spy_toggled(active: bool)

var _active := false
var _wire := false
var _player_cam: Camera3D = null
var _cam: Camera3D = null
## Quadtrees (terreno/océano) clavados al player mientras espiamos + su target previo.
var _frozen: Array = []
## GeometryInstance3D → Vector2(range_begin, range_end) guardados mientras espiamos.
var _ranges: Dictionary = {}
## Gates de cono de la vegetación desactivados mientras espiamos (ver _activate).
var _gates: Array = []
var _env: Environment = null
var _env_bg := -1
var _yaw := 0.0
var _pitch := -0.1
var _accum := 0.0
var _visuals: Array[VisualInstance3D] = []
var _frustum_mesh: MeshInstance3D = null
var _hud: Label = null


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and (e as InputEventKey).pressed and not (e as InputEventKey).echo:
		match (e as InputEventKey).keycode:
			KEY_F7:
				_toggle()
			KEY_F8:
				if _active:
					_wire = not _wire
					RenderingServer.set_debug_generate_wireframes(_wire)
					get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if _wire \
							else Viewport.DEBUG_DRAW_DISABLED
	elif _active and e is InputEventMouseMotion \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= (e as InputEventMouseMotion).relative.x * 0.004
		_pitch = clampf(_pitch - (e as InputEventMouseMotion).relative.y * 0.004, -1.4, 1.4)


func _toggle() -> void:
	if _active:
		_deactivate()
	else:
		_activate()


func _activate() -> void:
	var map := get_parent() as ProceduralMapSystem
	if map == null or map.sampler == null:
		return
	_player_cam = get_viewport().get_camera_3d()
	if _player_cam == null:
		return
	_active = true
	# Cámara espía arranca DONDE está el player y se despega.
	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.far = 3000.0
	add_child(_cam)
	_cam.global_transform = _player_cam.global_transform
	_yaw = _player_cam.global_rotation.y
	_pitch = _player_cam.global_rotation.x
	_cam.current = true
	# Pasto/raleo siguen al PLAYER, no a la espía.
	for c in map.get_children():
		if c is VegetationSystem:
			(c as VegetationSystem).camera_override = _player_cam
		elif c is GrassPatchSystem:
			(c as GrassPatchSystem).camera_override = _player_cam
	# El TERRENO/OCÉANO quedan CLAVADOS al player: la espía NO manda LOD ni cull, aunque
	# sea la cámara `current`. Sin esto el quadtree cae a la cámara actual (= la espía)
	# y reconstruye el cono alrededor de ella (bug reportado: "el cono sigue a la voladora").
	_frozen.clear()
	var oc = map.find_child("Ocean", true, false)
	var targets := [map.find_child("TerrainQuadtree", true, false)]
	if oc != null:
		targets.append_array([oc.surface_quadtree(), oc.floor_quadtree()])
	for n in targets:
		if n != null:
			_frozen.append({node = n, prev = n.target_camera})
			n.target_camera = _player_cam
	# UN SOLO DUEÑO de la visibilidad. La vegetación también apaga/prende sus
	# MultiMesh por su propio gate de cono; con la espía activa los DOS escribían
	# `visible` cada tick y los árboles PARPADEABAN ("luchan por la cámara").
	# Mientras espiamos, manda la espía: se apaga el gate propio y se restaura al salir.
	_gates.clear()
	for c in map.get_children():
		if (c is VegetationSystem or c is GrassPatchSystem) and c.get(&"spatial_gate") != null:
			_gates.append({node = c, prev = c.get(&"spatial_gate")})
			c.set(&"spatial_gate", null)
	# Fuera del cono del player NO hay nada: fondo NEGRO para que se vea el vacío real
	# (con cielo parecería que "hay mundo" donde no se renderizó nada).
	var we := map.get_tree().current_scene.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if we != null and we.environment != null:
		_env = we.environment
		_env_bg = _env.background_mode
		_env.background_mode = Environment.BG_COLOR
		_env.background_color = Color(0.02, 0.02, 0.03)
	# Piezas visuales a cullear contra el frustum del PLAYER.
	_visuals.clear()
	_collect(map)
	# LOD de vegetación: `visibility_range_*` lo evalúa el MOTOR contra la cámara que
	# RENDERIZA (la espía) — `camera_override` solo manda en nuestra lógica. Por eso
	# los árboles cambiaban de LOD al volar. Se guardan los rangos, se ANULAN (para que
	# el motor no decida) y el LOD se resuelve a mano contra la cámara del PLAYER.
	_ranges.clear()
	for v in _visuals:
		var gi := v as GeometryInstance3D
		if gi == null:
			continue
		if gi.visibility_range_begin > 0.0 or gi.visibility_range_end > 0.0:
			_ranges[gi] = Vector2(gi.visibility_range_begin, gi.visibility_range_end)
			gi.visibility_range_begin = 0.0
			gi.visibility_range_end = 0.0
	_frustum_mesh = MeshInstance3D.new()
	_frustum_mesh.mesh = ImmediateMesh.new()
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.albedo_color = Color(1.0, 0.9, 0.2)
	_frustum_mesh.material_override = fm
	add_child(_frustum_mesh)
	_hud = Label.new()
	_hud.position = Vector2(14, 40)
	_hud.add_theme_font_size_override(&"font_size", 16)
	_hud.add_theme_color_override(&"font_color", Color(1.0, 0.9, 0.3))
	_hud.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override(&"outline_size", 5)
	var cl := CanvasLayer.new()
	cl.name = "SpyHud"
	add_child(cl)
	cl.add_child(_hud)
	set_process(true)
	spy_toggled.emit(true)   # el dueño del player CONGELA su cámara (no se mueve con F7)


func _deactivate() -> void:
	_active = false
	set_process(false)
	if _wire:
		_wire = false
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	# Restaurar TODO visible + overrides + cámara del player.
	for v in _visuals:
		if is_instance_valid(v):
			v.visible = true
	_visuals.clear()
	# Devolver los rangos de LOD al motor.
	for gi_any in _ranges:
		var gi := gi_any as GeometryInstance3D
		if is_instance_valid(gi):
			var r: Vector2 = _ranges[gi_any]
			gi.visibility_range_begin = r.x
			gi.visibility_range_end = r.y
	_ranges.clear()
	var map := get_parent() as ProceduralMapSystem
	if map != null:
		for c in map.get_children():
			if c is VegetationSystem:
				(c as VegetationSystem).camera_override = null
			elif c is GrassPatchSystem:
				(c as GrassPatchSystem).camera_override = null
	# Devolver el terreno/océano a su dueño previo y el fondo al cielo.
	for f in _frozen:
		if is_instance_valid(f.node):
			f.node.target_camera = f.prev
	_frozen.clear()
	for g in _gates:
		if is_instance_valid(g.node):
			g.node.set(&"spatial_gate", g.prev)
	_gates.clear()
	if _env != null and _env_bg >= 0:
		_env.background_mode = _env_bg
		_env = null
		_env_bg = -1
	if _player_cam != null and is_instance_valid(_player_cam):
		_player_cam.current = true
	if _cam != null:
		_cam.queue_free()
		_cam = null
	if _frustum_mesh != null:
		_frustum_mesh.queue_free()
		_frustum_mesh = null
	var hud_layer := get_node_or_null(^"SpyHud")
	if hud_layer != null:
		hud_layer.queue_free()
	_hud = null
	spy_toggled.emit(false)


## ¿Estamos en modo espía? El dueño del player lo consulta para NO mover su cámara.
func is_active() -> bool:
	return _active


func _collect(n: Node) -> void:
	for c in n.get_children():
		if c is VisualInstance3D:
			_visuals.append(c)
		_collect(c)


func _process(delta: float) -> void:
	if not _active or _player_cam == null or not is_instance_valid(_player_cam):
		return
	# Vuelo libre.
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir.z -= 1
	if Input.is_key_pressed(KEY_S): dir.z += 1
	if Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_D): dir.x += 1
	if Input.is_key_pressed(KEY_E): dir.y += 1
	if Input.is_key_pressed(KEY_Q): dir.y -= 1
	var sp := 24.0 * (3.5 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	_cam.position += Basis(Vector3.UP, _yaw) * dir.normalized() * sp * delta
	_cam.basis = Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)

	_accum += delta
	if _accum < UPDATE_S:
		return
	_accum = 0.0
	var planes := _player_cam.get_frustum()
	var pcam := _player_cam.global_position
	var culled := 0
	for v in _visuals:
		if not is_instance_valid(v):
			continue
		var bb := v.get_aabb()
		var gbb := AABB(v.global_position + bb.position, bb.size)
		var inside := _aabb_in_frustum(gbb, planes)
		# LOD por distancia AL PLAYER (no a la espía): se replica lo que haría el motor
		# con visibility_range, pero medido desde la cámara del player.
		if inside and _ranges.has(v):
			var r: Vector2 = _ranges[v]
			var d := pcam.distance_to(v.global_position)
			if (r.x > 0.0 and d < r.x) or (r.y > 0.0 and d >= r.y):
				inside = false
		v.visible = inside
		if not inside:
			culled += 1
	_draw_frustum()
	if _hud != null:
		_hud.text = "ESPÍA F7 · FPS %d · draws %d · ocultas por el cono del player: %d/%d\nWASD volar · F8 wireframe (%s) · F7 volver" % [
				Engine.get_frames_per_second(),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				culled, _visuals.size(), "ON" if _wire else "off"]


static func _aabb_in_frustum(bb: AABB, planes: Array[Plane]) -> bool:
	for p in planes:
		var v := bb.position
		if p.normal.x < 0.0: v.x += bb.size.x
		if p.normal.y < 0.0: v.y += bb.size.y
		if p.normal.z < 0.0: v.z += bb.size.z
		if p.is_point_over(v):
			return false
	return true


func _draw_frustum() -> void:
	var im := _frustum_mesh.mesh as ImmediateMesh
	im.clear_surfaces()
	var t := _player_cam.global_transform
	var tan_v := tan(deg_to_rad(_player_cam.fov * 0.5))
	var vps := _player_cam.get_viewport().get_visible_rect().size \
			if _player_cam.get_viewport() != null else Vector2(16, 9)
	var aspect := vps.x / maxf(vps.y, 1.0)
	var corners: Array[Vector3] = []
	for d: float in [0.5, 200.0]:
		var h := tan_v * d
		var w := h * aspect
		for s: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			corners.append(t * Vector3(s.x * w, s.y * h, -d))
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in 4:
		im.surface_add_vertex(corners[i])
		im.surface_add_vertex(corners[(i + 1) % 4])
		im.surface_add_vertex(corners[4 + i])
		im.surface_add_vertex(corners[4 + (i + 1) % 4])
		im.surface_add_vertex(corners[i])
		im.surface_add_vertex(corners[4 + i])
	im.surface_end()
