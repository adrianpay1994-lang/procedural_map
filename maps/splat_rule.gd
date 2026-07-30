class_name SplatRule
extends Resource

## ============================================================================
## SplatRule · Una regla: condiciones → material de suelo (§5.1)
## ============================================================================
## Se evalúan en orden: la primera que matchea aporta weight del peso restante,
## las siguientes rellenan lo que queda.
## ============================================================================

# "Ground" y no "Material": el nombre Material sombrea la clase nativa de Godot.
enum Ground { GRASS, DIRT, SAND, ROCK, SNOW, FOREST_FLOOR, GRAVEL, MUD }

@export var ground: Ground = Ground.GRASS
## Vacío = cualquier bioma. Nombres mapgen2 (GRASSLAND, TAIGA, BEACH...).
@export var biomes: Array[String] = []
@export_range(0.0, 1.0, 0.01) var min_slope: float = 0.0
@export_range(0.0, 1.0, 0.01) var max_slope: float = 1.0
@export var min_height_m: float = -10000.0
@export var max_height_m: float = 10000.0
## Bitmask de TopologyMap (TOPO_*). 0 = sin condición de topología.
@export var topology_any: int = 0
@export_range(0.0, 1.0, 0.05) var weight: float = 1.0


func matches(biome: String, slope: float, height: float, topo_bits: int) -> bool:
	if slope < min_slope or slope > max_slope:
		return false
	if height < min_height_m or height > max_height_m:
		return false
	if topology_any != 0 and (topo_bits & topology_any) == 0:
		return false
	if not biomes.is_empty() and not biomes.has(biome):
		return false
	return true
