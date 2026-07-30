class_name VisibilityGate
extends Node

## ============================================================================
## VisibilityGate · "no me dibujes si no estoy en el cono"
## ============================================================================
## Componente que se le cuelga a CUALQUIER entidad (roca, prop, árbol suelto,
## barril, vehículo, NPC) para que sus VISUALES se apaguen fuera del cono del
## player. Pregunta a la autoridad única (`WorldVisibility`); no decide por su
## cuenta ni elige cámara — así no hay dos sistemas peleando por `visible`
## (ese fue el bug de los árboles parpadeando).
##
## REGLA QUE NO SE ROMPE — VISIBILIDAD ≠ EXISTENCIA:
## solo toca `VisualInstance3D`. NUNCA la lógica, la física ni la colisión. Un NPC
## detrás tuyo sigue existiendo, moviéndose y pudiendo dispararte; un loot no
## desaparece porque mires para otro lado. Para descartar por LEJANÍA está el
## AOI/streaming, que es otro criterio (ver DISENO_SERVER_CLIENTE_STREAMING).
##
## Uso: agregarlo como hijo de la entidad. Se autoconfigura.
##     var g := VisibilityGate.new()
##     entidad.add_child(g)
## ============================================================================

## Cada cuánto se pregunta (s). No hace falta por frame: el cono cambia despacio.
@export var check_interval_s: float = 0.15
## Lado de la caja de prueba (m). Debe cubrir la entidad; de más = se apaga tarde.
@export var size_m: float = 4.0
## Apagado, la entidad se dibuja siempre (para depurar o para cosas que nunca
## deben ocultarse, como un jefe o un marcador).
@export var enabled: bool = true

## DISTANCIA de culleo para props (Opciones -> Gráficos -> "Calidad de objetos").
## La escribe el catálogo gráfico; 0 = sin límite.
##
## Es `static` a propósito: son cientos de entidades y el valor es el mismo para
## todas. Un `@export` por nodo obligaría a recorrerlas todas al cambiar la
## opción, y además dejaría a cada prop con su propio valor desincronizado.
static var max_distance_m: float = 0.0

var _vis: WorldVisibility = null
var _visuals: Array[VisualInstance3D] = []
var _accum := 0.0
var _shown := true


func _ready() -> void:
	_collect(get_parent())
	set_process(not _visuals.is_empty())


## Busca la autoridad por grupo (la registra WorldVisibility al entrar al árbol).
func _authority() -> WorldVisibility:
	if _vis != null and is_instance_valid(_vis):
		return _vis
	var g := get_tree().get_first_node_in_group(&"world_visibility")
	_vis = g as WorldVisibility
	return _vis


func _process(delta: float) -> void:
	if not enabled:
		if not _shown:
			_apply(true)
		return
	_accum += delta
	if _accum < check_interval_s:
		return
	_accum = 0.0
	var v := _authority()
	if v == null:
		return
	var p := (get_parent() as Node3D)
	if p == null:
		return
	var c := p.global_position
	var want := v.area_in_frustum(Vector2(c.x, c.z), size_m)
	# La DISTANCIA se mide contra la cámara AUTORIDAD, no contra la que
	# renderiza: con la cámara espía activa, medir contra la que dibuja haría
	# desaparecer los props alrededor del jugador — que es justo lo que se quiere
	# mirar desde afuera.
	if want and max_distance_m > 0.0:
		var cam := v.authority_camera
		if cam != null and is_instance_valid(cam):
			want = c.distance_squared_to(cam.global_position) 					<= max_distance_m * max_distance_m
	if want != _shown:
		_apply(want)


func _apply(show_it: bool) -> void:
	_shown = show_it
	for v in _visuals:
		if is_instance_valid(v):
			v.visible = show_it


## SOLO visuales. Se salta cualquier cosa que no dibuje (colisión, audio, lógica).
func _collect(n: Node) -> void:
	if n == null:
		return
	for c in n.get_children():
		if c is VisualInstance3D:
			_visuals.append(c)
		_collect(c)


## ¿Está dibujándose ahora? (tests/diagnóstico.)
func is_shown() -> bool:
	return _shown
