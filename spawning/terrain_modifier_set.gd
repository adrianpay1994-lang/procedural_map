class_name TerrainModifierSet
extends Resource

## ============================================================================
## TerrainModifierSet · Lo que un monumento le hace al terreno (§7.6)
## ============================================================================
## Como TerrainModifier de Rust: aplanar altura (pre-bake), pintar splat y
## marcar topología (post-bake), limpiar vegetación/spawns alrededor.
## ============================================================================

@export_group("Altura (pre-bake)")
@export var flatten: bool = true
@export var flatten_radius_m: float = 30.0
@export var flatten_falloff_m: float = 20.0
## Elevar la plataforma sobre el terreno original (0 = a ras).
@export var height_offset_m: float = 0.0

@export_group("Splat (post-bake)")
@export var paint_splat: bool = true
@export var splat_ground: SplatRule.Ground = SplatRule.Ground.GRAVEL
@export var splat_radius_m: float = 26.0

@export_group("Topología (post-bake)")
## Radio del sello MONUMENT (bloquea spawns/vegetación/otros POIs).
@export var topology_radius_m: float = 36.0

@export_group("Limpieza")
@export var clear_vegetation_radius_m: float = 40.0
@export var clear_spawns_radius_m: float = 45.0
