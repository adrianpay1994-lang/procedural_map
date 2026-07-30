class_name TerrainSettings
extends Resource

## ============================================================================
## TerrainSettings · Parámetros de chunks, LOD, bake y mapas
## ============================================================================

@export_group("Chunks y LOD")
@export var chunk_size_m: float = 128.0
## Paso de vértice en metros por nivel de LOD.
@export var lod_steps_m: PackedFloat32Array = PackedFloat32Array([2.0, 4.0, 8.0, 16.0])
## Distancia de fin de visibilidad por LOD (el último llega a infinito).
@export var lod_ranges_m: PackedFloat32Array = PackedFloat32Array([384.0, 1024.0, 2600.0])
## Profundidad de la falda anti-costuras = factor × paso del LOD.
@export var skirt_depth_factor: float = 2.0

@export_group("Bake de altura")
## DEBE ser 2^n + 1 (513, 1025, 2049…).
@export var bake_resolution: int = 1025:
	set(v):
		var m := v - 1
		bake_resolution = v if (m > 1 and (m & (m - 1)) == 0) else 1025
@export_range(0, 4) var bake_smooth_passes: int = 1

@export_group("Mapas")
@export var splat_resolution: int = 512
@export var splat_edge_blur_m: float = 12.0
@export var topology_resolution: int = 512
@export var topology_side_width_m: float = 12.0
## Altura donde empieza la nieve por elevación (SplatRule de fábrica).
@export var snow_line_m: float = 80.0

## Hilos de trabajo para los bakes (backlog: la generación NO debe lagear la
## PC). Lee Opciones→"Hilos de generación": 0=2 hilos, 1=mitad, 2=casi todos.
static func worker_count() -> int:
	var mode := 1
	var ml := Engine.get_main_loop()
	if ml is SceneTree:
		var settings := (ml as SceneTree).root.get_node_or_null(^"Settings")
		if settings != null and settings.has_method(&"get_value"):
			mode = int(settings.call(&"get_value", &"graphics", &"gen_threads", 1))
	match clampi(mode, 0, 2):
		0:
			return 2
		1:
			return maxi(floori(OS.get_processor_count() / 2.0), 2)
		_:
			return maxi(OS.get_processor_count() - 1, 2)


@export_group("Colliders")
## Paso de la grilla del HeightmapShape3D por chunk (1 m = sin escalado del shape).
@export var collider_step_m: float = 1.0
