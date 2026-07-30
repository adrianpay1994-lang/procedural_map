class_name PlacementRule
extends Resource

## ============================================================================
## PlacementRule · Dónde puede aparecer un contenido (§7.2)
## ============================================================================
## ZoneType = preset amigable; las máscaras de topología permiten combinaciones
## finas ("FIELD + MAINLAND − MONUMENT"). Todo placement corre sobre
## TopologyMap.find_positions() — un solo camino de código.
## ============================================================================

enum ZoneType { BIOME, ROAD_SIDE, RIVER_BANK, COAST, LAKE_SHORE, FIELD, FOREST, RANDOM, CUSTOM }

@export var zone_type: ZoneType = ZoneType.BIOME
## Vacío = cualquier bioma (nombres mapgen2: GRASSLAND, TAIGA...).
@export var biome_filter: Array[String] = []
@export_range(0.0, 1.0, 0.01) var min_slope: float = 0.0
@export_range(0.0, 1.0, 0.01) var max_slope: float = 0.35
@export var min_height_m: float = 0.5
@export var max_height_m: float = 10000.0
@export var min_spacing_m: float = 8.0

@export_group("Topología (CUSTOM)")
@export_flags("Ocean","Oceanside","Beach","Beachside","Lake","Lakeside","River",
	"Riverside","Swamp","Cliff","Cliffside","Summit","Hilltop","Field","Forest",
	"Forestside","Road","Roadside","Monument","Decor","Mainland")
var topology_all: int = 0
@export_flags("Ocean","Oceanside","Beach","Beachside","Lake","Lakeside","River",
	"Riverside","Swamp","Cliff","Cliffside","Summit","Hilltop","Field","Forest",
	"Forestside","Road","Roadside","Monument","Decor","Mainland")
var topology_any: int = 0
@export_flags("Ocean","Oceanside","Beach","Beachside","Lake","Lakeside","River",
	"Riverside","Swamp","Cliff","Cliffside","Summit","Hilltop","Field","Forest",
	"Forestside","Road","Roadside","Monument","Decor","Mainland")
var topology_not: int = 0


## Máscaras efectivas: el preset se traduce a topología; CUSTOM usa las crudas.
func get_masks() -> Dictionary:
	var all_m := topology_all
	var any_m := topology_any
	# Nada sobre calzada/vía NI su banquina/balasto (RAILSIDE/ROADSIDE): árboles
	# y rocas se veían sobre los durmientes (regla del usuario). La zona
	# ROAD_SIDE quita ROADSIDE del veto (juncos al borde sí, a propósito).
	var not_m := topology_not | TopologyMap.TOPO_OCEAN | TopologyMap.TOPO_LAKE \
			| TopologyMap.TOPO_RIVER | TopologyMap.TOPO_MONUMENT \
			| TopologyMap.TOPO_ROAD | TopologyMap.TOPO_RAIL \
			| TopologyMap.TOPO_ROADSIDE | TopologyMap.TOPO_RAILSIDE
	match zone_type:
		ZoneType.ROAD_SIDE:
			any_m |= TopologyMap.TOPO_ROADSIDE
			not_m &= ~TopologyMap.TOPO_ROADSIDE  # esta zona SÍ va en la banquina
			not_m |= TopologyMap.TOPO_ROAD
		ZoneType.RIVER_BANK:
			any_m |= TopologyMap.TOPO_RIVERSIDE
		ZoneType.COAST:
			any_m |= TopologyMap.TOPO_BEACH
		ZoneType.LAKE_SHORE:
			any_m |= TopologyMap.TOPO_LAKESIDE
		ZoneType.FIELD:
			all_m |= TopologyMap.TOPO_FIELD | TopologyMap.TOPO_MAINLAND
		ZoneType.FOREST:
			all_m |= TopologyMap.TOPO_FOREST
		ZoneType.RANDOM, ZoneType.BIOME:
			all_m |= TopologyMap.TOPO_MAINLAND
		ZoneType.CUSTOM:
			pass  # solo las máscaras crudas
	return {"all": all_m, "any": any_m, "not": not_m}
