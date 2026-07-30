class_name DayNightCycle
extends Node3D

## ============================================================================
## DayNightCycle · Ciclo día/noche "tierra plana" (sol y luna girando el centro)
## ============================================================================
## Modelo pedido por el usuario: el sol y la luna orbitan sobre el CENTRO del
## mapa en un círculo; cuando el sol está sobre tu horizonte es de DÍA, cuando
## cruza al otro lado es de NOCHE (la luna toma su lugar, opuesta). Desde el
## punto de vista del jugador esto es un amanecer→mediodía→atardecer→noche real.
##
## Maneja: dirección + energía + color de la luz solar y lunar, luz ambiente,
## color de cielo (ProceduralSkyMaterial) y niebla — todo interpolado por la
## ALTURA del sol. Cero assets externos; determinista por `time_of_day`.
##
## Nota técnica: usa DirectionalLight (rayos paralelos) → toda el área visible
## transiciona junta, que es lo que el jugador percibe. Un split literal
## (mitad del mapa día, mitad noche al mismo instante) necesitaría el sol como
## luz de punto finita (caro); esto da el mismo look a coste casi nulo.

@export var sun: DirectionalLight3D
@export var moon: DirectionalLight3D
@export var world_environment: WorldEnvironment

@export_group("Tiempo")
## Duración de un día completo (s). 300 = 5 min. 0 = congelado en time_of_day.
@export var day_length_s: float = 300.0
## Momento del día [0,1): 0=medianoche, 0.25=amanecer, 0.5=mediodía, 0.75=ocaso.
@export_range(0.0, 1.0) var time_of_day: float = 0.35
@export var paused: bool = false

@export_group("Órbita (tierra plana)")
## Inclinación del eje de la órbita (rad). 0 = el sol pasa por el cenit al
## mediodía; >0 = arco más bajo (estaciones/latitud).
@export_range(0.0, 1.2) var orbit_tilt: float = 0.35
## Rumbo de la órbita alrededor del cenit (rad): por dónde "sale" el sol.
@export_range(0.0, 6.283) var orbit_heading: float = 0.0

@export_group("Colores")
@export var day_sun_energy: float = 1.25
@export var moon_energy: float = 0.14
@export var sun_day_color: Color = Color(1.0, 0.97, 0.88)
@export var sun_dawn_color: Color = Color(1.0, 0.55, 0.28)
@export var moon_color: Color = Color(0.55, 0.62, 0.85)
@export var sky_day: Color = Color(0.42, 0.62, 0.92)
@export var sky_dawn: Color = Color(0.92, 0.55, 0.38)
@export var sky_night: Color = Color(0.03, 0.04, 0.09)
@export var horizon_day: Color = Color(0.75, 0.82, 0.9)
@export var horizon_night: Color = Color(0.06, 0.07, 0.13)

var _sky_mat: ProceduralSkyMaterial
var _sky_shader: ShaderMaterial   # DaySky (nubes+estrellas); si carga, manda él
var _env: Environment


func _ready() -> void:
	if world_environment != null:
		_env = world_environment.environment
		if _env != null and _env.sky != null:
			# Cielo propio con nubes/estrellas si el shader existe; si no, se
			# queda con el ProceduralSky (colores desde _apply igual).
			var sh: Shader = load("res://shaders/DaySky.gdshader")
			if sh != null:
				_sky_shader = ShaderMaterial.new()
				_sky_shader.shader = sh
				_env.sky.sky_material = _sky_shader
			elif _env.sky.sky_material is ProceduralSkyMaterial:
				_sky_mat = _env.sky.sky_material
			_apply_sky_budget()
	_apply(time_of_day)
	var ge := get_node_or_null(^"/root/GameEvents")
	if ge != null and ge.has_signal(&"settings_changed"):
		ge.settings_changed.connect(func(section: StringName) -> void:
			if section == &"graphics":
				_apply_sky_budget())


func _process(delta: float) -> void:
	if not paused and day_length_s > 0.0:
		time_of_day = fposmod(time_of_day + delta / day_length_s, 1.0)
	_apply(time_of_day)


## Dirección de VIAJE de la luz del sol para un momento del día (rayos van hacia
## esa dir; el sol está en -dir). Órbita circular inclinada sobre el cenit.
func sun_travel_dir(t: float) -> Vector3:
	# a: 0 en medianoche. En t=0.5 (mediodía) el sol está en el cenit → luz baja.
	var a := TAU * t - PI * 0.5
	# Círculo alrededor del cenit, inclinado orbit_tilt hacia orbit_heading.
	var up := Vector3.UP
	var side := Vector3(cos(orbit_heading), 0.0, sin(orbit_heading))
	# Posición del sol sobre la esfera celeste.
	var sun_pos := (up * cos(orbit_tilt) + side * sin(orbit_tilt)).rotated(
			Vector3(-sin(orbit_heading), 0.0, cos(orbit_heading)), a)
	return -sun_pos.normalized()   # la luz viaja hacia abajo cuando el sol sube


## Geometría de luz de un momento del día. VIRTUAL: la base es "tierra redonda"
## (sol orbita el cenit, day por elevación). CosmosSky la sobreescribe con
## órbita HORIZONTAL a altura fija y day por distancia al subsolar. Devuelve
## {travel, day, dawn, sun_pos, moon_pos}: sun_pos/moon_pos = ZERO → el sky usa
## dirección infinita; != ZERO → parallax desde la posición real del cuerpo.
func _compute(t: float) -> Dictionary:
	var travel := sun_travel_dir(t)
	var elev := -travel.y
	return {
		"travel": travel,
		"day": smoothstep(-0.08, 0.34, elev),
		"dawn": 1.0 - smoothstep(0.0, 0.4, absf(elev)),
		"sun_pos": Vector3.ZERO,
		"moon_pos": Vector3.ZERO,
	}


func _apply(t: float) -> void:
	var geo := _compute(t)
	var travel: Vector3 = geo["travel"]
	var day: float = geo["day"]
	var dawn: float = geo["dawn"]
	var sun_pos: Vector3 = geo["sun_pos"]
	var moon_pos: Vector3 = geo["moon_pos"]

	if sun != null:
		# Dirección de la luz: si hay posición finita (tierra plana), los rayos
		# viajan desde el sol hacia el centro; si no, la dirección orbital.
		if sun_pos != Vector3.ZERO:
			travel = (global_position - sun_pos).normalized()
		sun.look_at_from_position(global_position, global_position + travel, Vector3.UP)
		sun.light_energy = day * day_sun_energy
		sun.light_color = sun_dawn_color.lerp(sun_day_color, smoothstep(0.05, 0.4, -travel.y))
		sun.visible = day > 0.01
	if moon != null:
		var moon_travel := -travel
		if moon_pos != Vector3.ZERO:
			moon_travel = (global_position - moon_pos).normalized()
		moon.look_at_from_position(global_position, global_position + moon_travel, Vector3.UP)
		moon.light_energy = (1.0 - day) * moon_energy
		moon.light_color = moon_color
		moon.visible = day < 0.99
	# UNA sola sombra direccional a la vez (dos shadow maps simultáneos duplican el costo
	# de sombras del frame para nada: la luz dominante manda).
	if sun != null and moon != null:
		sun.shadow_enabled = day >= 0.5
		moon.shadow_enabled = day < 0.5

	if _env != null:
		var amb := sky_night.lerp(sky_day, day)
		_env.ambient_light_color = amb
		_env.ambient_light_energy = lerpf(0.12, 1.0, day)
		if _env.fog_enabled:
			_env.fog_light_color = horizon_night.lerp(horizon_day, day)
			# La niebla NO debe pintar el cielo (default 1.0 lo tapa entero y
			# borra nubes/estrellas/sol); solo un velo leve en el horizonte.
			_env.fog_sky_affect = 0.08
	if _sky_shader != null:
		# Posición finita de los cuerpos (parallax en el sky) — o ZERO = dir infinita.
		_sky_shader.set_shader_parameter("sun_world_pos", sun_pos)
		_sky_shader.set_shader_parameter("moon_world_pos", moon_pos)
		_sky_shader.set_shader_parameter("sun_dir", -travel)
		_sky_shader.set_shader_parameter("moon_dir", travel)
		_sky_shader.set_shader_parameter("day", day)
		_sky_shader.set_shader_parameter("dawn", dawn)
		_sky_shader.set_shader_parameter("sky_top", sky_day)
		_sky_shader.set_shader_parameter("sky_horizon", horizon_day)
		_sky_shader.set_shader_parameter("night_top", sky_night)
		_sky_shader.set_shader_parameter("night_horizon", horizon_night)
		_sky_shader.set_shader_parameter("dawn_tint", sky_dawn)
		_sky_shader.set_shader_parameter("sun_color", sun_day_color)
		_sky_shader.set_shader_parameter("moon_color", moon_color)
	elif _sky_mat != null:
		var top := sky_night.lerp(sky_day, day)
		var horiz := horizon_night.lerp(sky_dawn.lerp(horizon_day, day), 1.0)
		# Mezcla el naranja del amanecer en el horizonte según `dawn`.
		horiz = horiz.lerp(sky_dawn, dawn * (1.0 - day) * 0.6 + dawn * day * 0.3)
		_sky_mat.sky_top_color = top
		_sky_mat.sky_horizon_color = horiz
		_sky_mat.ground_horizon_color = horiz
		_sky_mat.ground_bottom_color = top.darkened(0.3)


## Estado legible (para HUD/gameplay): "día"/"noche"/"amanecer"/"ocaso".
## Usa _compute (misma geometría que la luz) → correcto en ambos modelos.
func phase() -> String:
	var day: float = _compute(time_of_day)["day"]
	if day > 0.7:
		return "día"
	if day < 0.18:
		return "noche"
	# amanecer si el día está creciendo, ocaso si decrece (test barato).
	var later: float = _compute(fposmod(time_of_day + 0.01, 1.0))["day"]
	return "amanecer" if later > day else "ocaso"


## Presupuesto del CIELO según la calidad de nubes.
##
## Godot corre el shader de cielo dos veces: una para la pantalla y otra para el
## cubemap de radiancia, que es lo que ilumina la escena. Ese segundo pase es
## caro y **la mejor optimización es actualizarlo lo menos posible** — es lo que
## dice la propia documentación del motor.
##
##   REALTIME     rehace el cubemap TODOS los cuadros. Solo funciona a 256 px.
##   INCREMENTAL  lo rehace repartido en varios cuadros, con la misma calidad.
##
## Con nubes que se mueven despacio, INCREMENTAL se ve igual y cuesta una
## fracción. REALTIME solo tiene sentido si algo del cielo cambia rápido, y acá
## no pasa: el sol se mueve en minutos.
func _apply_sky_budget() -> void:
	if _env == null or _env.sky == null:
		return
	var q := 1
	var st := get_node_or_null(^"/root/Settings")
	if st != null:
		q = clampi(int(st.call(&"get_value", &"graphics", &"cloud_quality", 1)), 0, 3)
	var sky := _env.sky
	if q == 0:
		# Nubes planas: no hay raymarch, así que el cubemap chico alcanza y sobra.
		sky.radiance_size = Sky.RADIANCE_SIZE_128
		sky.process_mode = Sky.PROCESS_MODE_REALTIME
	elif q == 1:
		sky.radiance_size = Sky.RADIANCE_SIZE_128
		sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	elif q == 2:
		sky.radiance_size = Sky.RADIANCE_SIZE_256
		sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	else:
		# Ni en ultra se usa REALTIME: con un raymarch de 28 pasos, rehacer las
		# seis caras cada cuadro es tirar el presupuesto por la ventana para que
		# nadie note la diferencia.
		sky.radiance_size = Sky.RADIANCE_SIZE_256
		sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
