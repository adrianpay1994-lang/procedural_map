class_name VegetationProfile
extends Resource

## ============================================================================
## VegetationProfile · Un estrato de vegetación/props (F8)
## ============================================================================
## Reusa PlacementRule (misma lógica que entidades: topología + pendiente +
## bioma). El mesh sale de una escena (.glb/.tscn) o de un Mesh directo
## (rocas procedurales). Render: UN MultiMeshInstance3D por perfil.
## ============================================================================

@export var profile_name: StringName = &""
## Escena con el modelo (se extrae el primer MeshInstance3D). Ignorada si mesh != null.
@export var scene: PackedScene
## Mesh directo (p.ej. roca procedural). Prioridad sobre scene.
@export var mesh: Mesh
## Pool de meshes variantes (Fase 1): si no está vacío, las instancias se
## reparten round-robin en K MultiMesh → variedad real (no clones). Prioridad
## sobre mesh/scene.
@export var meshes: Array[Mesh] = []
## Pool LOD-lejano paralelo a `meshes` (mismo tamaño): si no está vacío, las
## instancias más allá de `lod_distance` usan estas mallas baratas (Fase 5).
@export var meshes_far: Array[Mesh] = []
## LOD2 MUY reducido (≈18%): nivel intermedio ENTRE `meshes_far` y el impostor, para que
## el salto reducida→2D no se note. Opcional (mismo tamaño que `meshes`). Vacío = sin nivel.
@export var meshes_far2: Array[Mesh] = []
## Distancia (m) del cruce full→reducido. Solo aplica si meshes_far != vacío.
@export var lod_distance: float = 55.0
## Distancia (m) del cruce reducido→IMPOSTOR (billboard horneado). El impostor se
## hornea en runtime si la malla es alta (árboles/arbustos) y hay render (no headless).
@export var impostor_distance: float = 160.0
## Distancia (m) máxima de visión del impostor (más allá = culleado). Miles de
## metros por casi nada (2 tris/instancia).
@export var far_view_m: float = 1800.0
@export var rule: PlacementRule
@export_range(1, 20000) var count: int = 400
@export var scale_min: float = 0.8
@export var scale_max: float = 1.3
@export var random_yaw: bool = true
## Alinear a la pendiente (rocas sí, árboles no — crecen a plomo).
@export var align_to_terrain: bool = false
## Hundir la base N metros (que el tronco no flote en pendientes).
@export var sink_m: float = 0.15
## Distancia de visibilidad del estrato completo (0 = siempre visible).
@export var visibility_range_m: float = 900.0

## STANDS (rodales): si stand_count>1, esta especie SOLO se planta donde el ruido
## de rodales (compartido por el bioma) la elige como dominante → manchas de una
## especie en vez de 12 mezcladas por celda = ~stand_count× menos draws (menos
## MMIs por celda). stand_index = qué especie es; stand_seed = semilla del bioma
## (igual para todas sus especies); stand_size_m = tamaño típico de mancha.
@export var stand_count: int = 0
@export var stand_index: int = 0
@export var stand_seed: int = 0
@export var stand_size_m: float = 90.0


func resolve_mesh() -> Mesh:
	if mesh != null:
		return mesh
	if scene == null:
		return null
	var inst := scene.instantiate()
	var found := _find_mesh(inst)
	inst.free()
	return found


static func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return (node as MeshInstance3D).mesh
	for child in node.get_children():
		var m := _find_mesh(child)
		if m != null:
			return m
	return null
