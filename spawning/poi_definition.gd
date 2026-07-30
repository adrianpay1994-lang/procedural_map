class_name POIDefinition
extends Resource

## ============================================================================
## POIDefinition · Un monumento/estructura y sus requisitos de sitio (§7.6)
## ============================================================================

@export var poi_name: StringName = &""
@export var scene: PackedScene
@export var icon: Texture2D
## Id para referenciar por script (PortalSDK). -1 = sin registro.
@export var obj_id: int = -1
@export_range(1, 16) var count: int = 1

@export_group("Requisitos de sitio")
## Vacío = cualquier bioma (nombres mapgen2).
@export var allowed_biomes: Array[String] = []
@export var min_height_m: float = 1.0
@export var max_height_m: float = 200.0
@export_range(0.0, 1.0, 0.01) var max_site_slope: float = 0.25
@export var min_distance_between_pois_m: float = 120.0

@export_group("Adaptación")
@export var align_to_terrain: bool = false   ## monumentos suelen ir a plomo (plataforma ya nivelada)
@export var modifiers: TerrainModifierSet
## §F5: perfil de terreno propio del monumento (TerrainStamp §F2). Si está,
## REEMPLAZA a la plataforma plana de modifiers.flatten — el monumento impone
## su relieve (rampa/meseta/cráter) y el falloff lo funde con el entorno.
@export var terrain_stamp: TerrainStamp
