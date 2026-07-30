class_name BiomeSpawnEntry
extends Resource

## ============================================================================
## BiomeSpawnEntry · Una entrada de spawn: escena + regla + cantidades (§7)
## ============================================================================
## Validación estilo PortalSDK: solo escenas .tscn (entidades con ComponentHost
## o cuerpos completos) — nunca .glb crudo al mapa.
## ============================================================================

@export var entry_name: StringName = &""
@export var scene: PackedScene
## Id opcional para referenciar la entidad colocada por script (PortalSDK).
@export var obj_id: int = -1
@export var rule: PlacementRule
@export_range(1, 200) var count: int = 6
@export var align_to_terrain: bool = true
@export var random_yaw: bool = true
## Repoblar cada N segundos (0 = solo al generar).
@export var respawn_interval: float = 0.0
