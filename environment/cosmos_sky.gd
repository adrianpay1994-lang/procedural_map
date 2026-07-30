class_name CosmosSky
extends DayNightCycle

## ============================================================================
## CosmosSky · Cielo tierra-plana FASE 1: cuerpos celestes finitos + parallax
## ============================================================================
## Extiende DayNightCycle (reusa toda la lógica de luz/color/día-noche) y AGREGA:
##  · Sol y luna como CUERPOS finitos (esfera emisiva o billboard) que orbitan a
##    `orbit_distance` del centro → se ven en el cielo y ORBITAN.
##  · Parallax real: el disco del DaySky se calcula desde la posición del cuerpo
##    (sun_world_pos) en vez de una dirección infinita.
## El resto (estrellas, fases lunares, eclipses, auroras, clima) son fases
## siguientes — ver docs/SKY_COSMOS_PLAN.md.
## Barato: 2 mallas + la luz direccional de siempre. Costo fijo (no por-árbol).
## ============================================================================

## SKY = el DaySky dibuja disco+halo con parallax (más barato, default).
## SPHERE/BILLBOARD = malla real (se puede ocluir con nubes/relieve).
enum BodyMode { SKY, SPHERE, BILLBOARD }

@export_group("Cuerpos celestes")
@export var body_mode: BodyMode = BodyMode.SKY
## RADIO del círculo HORIZONTAL que el sol/luna recorren alrededor del centro (m).
## Ajustar al tamaño de la isla. El sol NO pasa por el cenit: gira en horizontal.
@export var orbit_distance: float = 2500.0
## ALTURA del círculo sobre el suelo (m). Comparable a la altura de las nubes.
@export var orbit_height: float = 1500.0
## Reflector de día: el sol ilumina una zona alrededor de su punto subsolar.
## day=1 si la cámara está a <lit_inner del subsolar; day=0 si está a >lit_outer
## (el sol está del otro lado = noche). Calibrar al radio de la isla. Un lado de
## la isla queda de día y el opuesto de noche a medida que el sol orbita.
@export var lit_inner: float = 1200.0
@export var lit_outer: float = 3600.0
## Tamaño angular (rad) del disco: 0.026 ≈ 1.5° (algo más grande que el real 0.5°
## para que se vea lindo en juego).
@export var sun_disc_size: float = 0.05
@export var moon_disc_size: float = 0.058
@export var sun_emission_energy: float = 8.0
@export var moon_emission_energy: float = 3.6
## Color del disco lunar (plateado, más claro que la luz que tiñe la escena).
@export var moon_disc_color: Color = Color(0.88, 0.9, 0.97)

@export_group("Fase 2 · cielo nocturno")
## Días de juego de un ciclo lunar completo (real 29.5; corto para que el jugador
## vea las fases). Nueva→creciente→llena→menguante→nueva.
@export var moon_cycle_days: float = 8.0
## Fase inicial [0,1): 0 luna nueva, 0.5 llena.
@export_range(0.0, 1.0) var moon_phase_start: float = 0.5
@export_range(0.0, 1.0) var milky_way: float = 0.7
@export_range(0.0, 1.0) var shooting_freq: float = 0.35

var _sun_body: MeshInstance3D
var _moon_body: MeshInstance3D
var _day_count: float = 0.0


func _ready() -> void:
	super._ready()
	if body_mode == BodyMode.SKY:
		return   # el cielo dibuja disco+halo (parallax); sin mallas
	_sun_body = _make_body(sun_day_color, sun_emission_energy)
	_moon_body = _make_body(moon_disc_color, moon_emission_energy)
	# El cuerpo-malla es el disco; el cielo solo aporta el halo (sin doble disco).
	if _sky_shader != null:
		_sky_shader.set_shader_parameter("sky_draws_discs", false)


func _make_body(col: Color, energy: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	# Emisivo shaded (no unshaded: en unshaded la emisión no se sumaba y salía
	# negro). disable_ambient para que no lo laven las luces. El halo lo pone el sky.
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = energy
	mat.albedo_color = col
	mat.disable_receive_shadows = true
	if body_mode == BodyMode.BILLBOARD:
		# Quad que siempre mira a cámara + textura radial (disco suave con alpha).
		var qm := QuadMesh.new()
		qm.size = Vector2.ONE
		mi.mesh = qm
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mat.billboard_keep_scale = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_texture = _disc_texture()
	else:
		var sm := SphereMesh.new()
		sm.radius = 0.5
		sm.height = 1.0
		sm.radial_segments = 20
		sm.rings = 12
		mi.mesh = sm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 16384.0   # cuerpo lejano: no se cull-ea por AABB chico
	add_child(mi)
	return mi


## Textura radial (disco lleno con borde suave) para el modo billboard.
static func _disc_texture(size: int = 64) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := (size - 1) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x - c, y - c).length() / c
			var a := clampf(1.0 - smoothstep(0.7, 1.0, d), 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


## Posición FINITA de un cuerpo en su círculo horizontal a altura orbit_height.
## phase_offset=0 sol, =PI luna (opuesta = yin-yang).
func _body_pos(t: float, phase_offset: float) -> Vector3:
	var ang := TAU * t + orbit_heading + phase_offset
	return global_position + Vector3(cos(ang), 0.0, sin(ang)) * orbit_distance \
			+ Vector3.UP * orbit_height


## Referencia del día/noche local: la cámara activa (jugador); headless = centro.
func _reference_point() -> Vector3:
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	return cam.global_position if cam != null else global_position


## Geometría tierra-plana: órbita HORIZONTAL + day por distancia al SUBSOLAR.
## (Sobreescribe el modelo tierra-redonda de DayNightCycle.)
func _compute(t: float) -> Dictionary:
	var c := global_position
	var ref := _reference_point()
	var spos := _body_pos(t, 0.0)
	var mpos := _body_pos(t, PI)
	var d_sun := Vector2(ref.x - spos.x, ref.z - spos.z).length()
	var day := 1.0 - smoothstep(lit_inner, lit_outer, d_sun)   # reflector
	var dawn := 1.0 - absf(day - 0.5) * 2.0                    # pico en la transición
	return {"travel": (c - spos).normalized(), "day": day, "dawn": dawn,
			"sun_pos": spos, "moon_pos": mpos}


func _process(delta: float) -> void:
	super._process(delta)   # _apply()→_compute() ya setea luz/color/sky + world_pos
	# Fase lunar por días de juego (ciclo sinódico configurable).
	if not paused and day_length_s > 0.0:
		_day_count += delta / day_length_s
	var mphase := fposmod(moon_phase_start + _day_count / maxf(moon_cycle_days, 0.1), 1.0)
	if _sky_shader != null:
		_sky_shader.set_shader_parameter("moon_phase", mphase)
		_sky_shader.set_shader_parameter("milky_way", milky_way)
		_sky_shader.set_shader_parameter("shooting_freq", shooting_freq)
	# Mallas de cuerpo (modos SPHERE/BILLBOARD).
	if _sun_body != null:
		_place(_sun_body, _body_pos(time_of_day, 0.0), sun_disc_size * orbit_distance)
	if _moon_body != null:
		_place(_moon_body, _body_pos(time_of_day, PI), moon_disc_size * orbit_distance)


func _place(body: MeshInstance3D, pos: Vector3, diam: float) -> void:
	body.global_position = pos
	body.scale = Vector3.ONE * maxf(diam, 1.0)
