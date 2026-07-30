class_name OceanRipples
extends Node

## ============================================================================
## OceanRipples · Capa DINÁMICA del océano (estelas, chapoteos, ondas que chocan)
## ============================================================================
## El FFT da el caos de fondo, pero no reacciona a nada. Esta capa sí: los objetos
## que tocan el agua ESCRIBEN su impacto en una textura donde la altura se propaga
## con la ecuación de onda, y el resultado se SUMA al oleaje.
##
## Es la arquitectura de los motores (Crest, AC Black Flag, el paper híbrido
## FFT+wave-particles de 2025): NADIE simula el océano entero reaccionando a un
## barco — se simula una VENTANA LOCAL alrededor de la acción y se suma.
## Ahí las ondas se propagan, se cruzan y rebotan de verdad.
##
## Corre en SubViewports con un shader canvas_item (ping-pong), NO en compute:
## por eso funciona también donde el FFT no está disponible (Compatibility, web).
##
## POR QUÉ TRES BUFFERS Y NO DOS: la ecuación de onda necesita t−1 y t−2, así que
## con dos el que dibuja tendría que leerse a sí mismo — y Godot lo prohíbe:
##   "Attempted to use the same texture in framebuffer attachment and a uniform"
## (ese error salía 102 veces por corrida y era la causa REAL de que la onda
## naciera pero no se propagara). Con tres, el que escribe nunca es ninguno de los
## dos que lee.
##
## Uso:
##     var r := OceanRipples.new(); add_child(r)
##     r.center = Vector2(player.x, player.z)       # la ventana sigue al player
##     r.splash(barco.global_position, 0.5)         # estela / impacto
##     mat.set_shader_parameter(&"ripples", r.texture())
## ============================================================================

## Lado de la ventana simulada (m). Cubre el área alrededor del player donde se
## ven las estelas; más grande = menos resolución por metro.
@export var window_m: float = 256.0
## Resolución de la simulación. 256 alcanza para estelas; subir cuesta fillrate.
@export var resolution: int = 256
## Pasos de simulación por segundo. Más = ondas más rápidas y estables.
@export_range(10, 120) var steps_per_second: int = 60
@export_range(0.0, 0.5) var speed: float = 0.32
@export_range(0.9, 1.0) var damping: float = 0.985

## Centro de la ventana en world XZ (lo mueve el dueño: normalmente el player).
var center := Vector2.ZERO

const RIPPLE_SHADER := preload("res://shaders/ocean/OceanRipples.gdshader")

var _vp: Array[SubViewport] = []
var _rect: Array[ColorRect] = []
var _mat: Array[ShaderMaterial] = []
var _cur := 0
var _accum := 0.0
## Impactos pendientes de inyectar (uno por paso: el shader inyecta de a uno).
var _queue: Array[Vector3] = []   # x,y = UV, z = fuerza


func _ready() -> void:
	for i in 3:
		var vp := SubViewport.new()
		vp.size = Vector2i(resolution, resolution)
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		# Fondo TRANSPARENTE = el viewport se limpia a 0, no al color de fondo por
		# defecto. Sin esto los tres buffers arrancan en ~0.91 (blanco) y ese valor
		# entra a la ecuacion de onda como una perturbacion enorme que despues nunca
		# se disipa: era la causa de que la energia en reposo no bajara a cero.
		vp.transparent_bg = true
		vp.disable_3d = true
		add_child(vp)
		var cr := ColorRect.new()
		cr.size = Vector2(resolution, resolution)
		var m := ShaderMaterial.new()
		m.shader = RIPPLE_SHADER
		m.set_shader_parameter(&"texel", Vector2(1.0 / float(resolution), 1.0 / float(resolution)))
		m.set_shader_parameter(&"speed", speed)
		m.set_shader_parameter(&"damping", damping)
		cr.material = m
		vp.add_child(cr)
		_vp.append(vp)
		_rect.append(cr)
		_mat.append(m)
	_bind(0)


func _process(delta: float) -> void:
	_accum += delta
	var step := 1.0 / float(maxi(steps_per_second, 1))
	if _accum < step:
		return
	_accum = 0.0
	_cur = (_cur + 1) % 3
	_bind(_cur)
	var imp := Vector4(0.0, 0.0, 0.0, 0.0)
	if not _queue.is_empty():
		var q: Vector3 = _queue.pop_front()
		imp = Vector4(q.x, q.y, q.z, 0.03)
	_mat[_cur].set_shader_parameter(&"impact", imp)
	for i in 3:
		if i != _cur:
			_mat[i].set_shader_parameter(&"impact", Vector4.ZERO)



## Un objeto toca el agua: barco navegando (llamar seguido y flojo), jugador
## nadando, o algo que cae (una vez y fuerte). Fuera de la ventana se ignora.
## El buffer `cur` lee los DOS anteriores en la rotación (nunca a sí mismo).
func _bind(cur: int) -> void:
	_mat[cur].set_shader_parameter(&"prev_tex", _vp[(cur + 2) % 3].get_texture())
	_mat[cur].set_shader_parameter(&"prev2_tex", _vp[(cur + 1) % 3].get_texture())


func splash(world_pos: Vector3, strength: float = 0.5) -> void:
	var uv := world_to_uv(Vector2(world_pos.x, world_pos.z))
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return
	_queue.append(Vector3(uv.x, uv.y, clampf(strength, -1.0, 1.0)))


## World XZ → UV de la ventana (0..1). Fuera de la ventana devuelve fuera de rango.
func world_to_uv(xz: Vector2) -> Vector2:
	var half := window_m * 0.5
	return (xz - center + Vector2(half, half)) / window_m


## Textura con el estado actual (canal R = altura). Se la pasa al shader del mar.
func texture() -> Texture2D:
	return _vp[_cur].get_texture() if _vp.size() == 3 else null


## Parámetros que el shader del océano necesita para ubicar la ventana en el mundo.
func window_params() -> Plane:
	return Plane(center.x, center.y, window_m, 1.0)
