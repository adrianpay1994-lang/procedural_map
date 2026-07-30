class_name ProceduralSurfaceOverride
extends Component

## ============================================================================
## ProceduralSurfaceOverride · Superficie por material del splat (F5, §5.1)
## ============================================================================
## Componente para el Player/NPC en mapas procedurales: cada tick físico lee
## el material dominante del splat bajo los pies y lo inyecta como override en
## el SurfaceComponent → los pasos suenan a grava en la carretera aunque cruce
## un bosque. Sin mapa procedural (u otro mapa), no hace nada (sin override).
## ============================================================================

var _surface: SurfaceComponent
var _move: Node
var _map: ProceduralMapSystem


func component_ready() -> void:
	if host.has_method(&"get_component"):
		_surface = host.call(&"get_component", &"surface") as SurfaceComponent
		_move = host.call(&"get_component", &"movement")


func component_physics(_delta: float) -> void:
	if _surface == null:
		return
	# EN EL AGUA manda: los pasos suenan a chapoteo aunque el suelo sea arena
	# (pedido del usuario: pisar el agua no sonaba). water_level ≥1 = pies mojados.
	if _move != null and _move.has_method(&"get_water_level") \
			and int(_move.call(&"get_water_level")) >= 1:
		_surface.set_surface_override(&"water")
		return
	if _map == null or not is_instance_valid(_map):
		_map = _find_map()
		if _map == null:
			return
	if _map.splat == null:
		return
	var pos: Vector3 = (host as Node3D).global_position
	_surface.set_surface_override(_map.get_surface_at(pos))


func _exit_tree() -> void:
	if _surface != null:
		_surface.clear_surface_override()


func _find_map() -> ProceduralMapSystem:
	for m in get_tree().get_nodes_in_group(SystemLink.MAP):
		if m is ProceduralMapSystem:
			return m
	return null
