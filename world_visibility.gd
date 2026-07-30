class_name WorldVisibility
extends Node

## ============================================================================
## WorldVisibility · LA autoridad de "qué existe" este frame
## ============================================================================
## Componente único por el que pasa TODO. La cadena es la que describió el
## usuario, en ese orden exacto:
##
##     PLAYER → su CÁMARA → CONO (frustum) → qué SUBDIVISIONES existen
##            → qué hay DENTRO de esas subdivisiones (mesh, árboles, rocas,
##              pasto, props, NPC) → render
##
## Nadie más decide. Una cámara secundaria (espía, cinemática, minimapa) NO manda:
## solo observa lo que esta autoridad dejó existir. Por eso `authority_camera` es
## explícita — si dos sistemas eligen cámara por su cuenta, se pelean (medido: los
## árboles PARPADEABAN porque dos sistemas escribían `visible` sobre el mismo
## MultiMesh).
##
## Uso:
##     var vis := WorldVisibility.new()
##     vis.authority_camera = player_cam
##     add_child(vis)
##     veg.spatial_gate = vis      # misma API que ya usaban (area_in_frustum)
##     grass.spatial_gate = vis
##
## Los planos del cono se calculan UNA vez por frame y los comparten todos los
## sistemas (antes cada uno llamaba a get_frustum() por su cuenta).
## ============================================================================

## Cámara que MANDA. null = la del player (PlayerRegistry) o la activa del viewport.
var authority_camera: Camera3D = null

## Interruptor maestro: apagado, todo es visible (comportamiento clásico) — sirve
## para comparar y para escenas donde no interesa el culling direccional.
@export var cone_only: bool = true
## Colchón alrededor del cono (m). Da margen para que al girar rápido no aparezca
## un hueco en el borde. Más chico = más pegado al cono, más riesgo de "pop".
@export var margin_m: float = 24.0
## Semi-altura de la caja de prueba (m). Debe cubrir el relieve real; de más, el
## cono acepta parcelas que en realidad no se ven.
@export var height_m: float = 300.0

var _planes: Array = []
var _frame := -1
## Diagnóstico: consultas y cuántas se rechazaron este frame.
var _asked := 0
var _rejected := 0
var _asked_prev := 0
var _rejected_prev := 0


func _ready() -> void:
	# Se registra para que cualquier VisibilityGate la encuentre sin cablearla a mano.
	add_to_group(&"world_visibility")


func _process(_d: float) -> void:
	# Un solo recálculo de planos por frame, compartido por todos los sistemas.
	var f := Engine.get_process_frames()
	if f == _frame:
		return
	_frame = f
	_asked_prev = _asked
	_rejected_prev = _rejected
	_asked = 0
	_rejected = 0
	var cam := camera()
	_planes = cam.get_frustum() if cam != null else []


## La cámara que manda (explícita > player > la activa del viewport).
func camera() -> Camera3D:
	if authority_camera != null and is_instance_valid(authority_camera):
		return authority_camera
	# Por `get_node_or_null` y NO por el identificador global `PlayerRegistry`:
	# en modo `--script` los autoloads existen en el árbol pero NO como
	# identificador global, así que este archivo no compilaba ahí — y arrastraba
	# a todo lo que dependiera de él. El guard `typeof(...) != TYPE_NIL` no
	# alcanzaba: el error es de COMPILACIÓN, no de ejecución, así que se dispara
	# antes de que ese guard llegue a correr.
	var reg := get_node_or_null(^"/root/PlayerRegistry")
	if reg != null and reg.has_method(&"active_camera"):
		var c := reg.call(&"active_camera") as Camera3D
		if c != null:
			return c
	return get_viewport().get_camera_3d() if get_viewport() != null else null


## ¿Esta parcela del mundo EXISTE este frame? Misma firma que el gate que ya usaban
## la vegetación y el pasto, así que se enchufa sin tocarlos.
func area_in_frustum(center_xz: Vector2, size_m: float) -> bool:
	if not cone_only:
		return true
	if _planes.is_empty():
		# Todavía sin cono (primer frame o sin cámara): no esconder nada.
		return true
	_asked += 1
	var half := size_m * 0.5
	var mn := Vector3(center_xz.x - half, -height_m, center_xz.y - half)
	var mx := Vector3(center_xz.x + half, height_m, center_xz.y + half)
	for pv in _planes:
		var pl := pv as Plane
		# Vértice n: el que MINIMIZA la distancia al plano. Si ese queda del lado
		# de afuera, la caja entera está afuera (test AABB-plano estándar).
		var nv := Vector3(
				mn.x if pl.normal.x >= 0.0 else mx.x,
				mn.y if pl.normal.y >= 0.0 else mx.y,
				mn.z if pl.normal.z >= 0.0 else mx.z)
		if pl.distance_to(nv) > margin_m:
			_rejected += 1
			return false
	return true


## ¿Este punto está en el cono? (props sueltos, NPC, loot.)
func point_visible(p: Vector3) -> bool:
	return area_in_frustum(Vector2(p.x, p.z), 1.0)


## Consultas y rechazos del frame ANTERIOR (el actual está a medio contar).
func stats() -> Dictionary:
	return {asked = _asked_prev, rejected = _rejected_prev,
			cone_only = cone_only, has_cone = not _planes.is_empty()}
