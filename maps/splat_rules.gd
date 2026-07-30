class_name SplatRules
extends Resource

## ============================================================================
## SplatRules · Set ordenado de reglas de material (§5.1)
## ============================================================================

@export var rules: Array[SplatRule] = []


## Set de fábrica — replica el comportamiento de Rust:
## roca en acantilados, arena en playas, grava en calzadas, barro en orillas,
## nieve por bioma frío o altura, hojarasca en bosques, pasto por defecto.
static func make_default(snow_line_m: float = 80.0) -> SplatRules:
	var out := SplatRules.new()
	var r: SplatRule

	r = SplatRule.new()   # 1. acantilados
	r.ground = SplatRule.Ground.ROCK
	r.min_slope = 0.55
	out.rules.append(r)

	r = SplatRule.new()   # 2. playa
	r.ground = SplatRule.Ground.SAND
	r.topology_any = TopologyMap.TOPO_BEACH
	out.rules.append(r)

	r = SplatRule.new()   # 3. calzada
	r.ground = SplatRule.Ground.GRAVEL
	r.topology_any = TopologyMap.TOPO_ROAD
	out.rules.append(r)

	r = SplatRule.new()   # 4. banquina
	r.ground = SplatRule.Ground.DIRT
	r.topology_any = TopologyMap.TOPO_ROADSIDE
	r.weight = 0.7
	out.rules.append(r)

	r = SplatRule.new()   # 5. orillas de agua dulce
	r.ground = SplatRule.Ground.MUD
	r.topology_any = TopologyMap.TOPO_RIVERSIDE | TopologyMap.TOPO_LAKESIDE
	r.weight = 0.8
	out.rules.append(r)

	r = SplatRule.new()   # 6. nieve por bioma
	r.ground = SplatRule.Ground.SNOW
	r.biomes = ["SNOW", "ICE"] as Array[String]
	out.rules.append(r)

	r = SplatRule.new()   # 7. nieve por altura
	r.ground = SplatRule.Ground.SNOW
	r.min_height_m = snow_line_m
	out.rules.append(r)

	r = SplatRule.new()   # 8. hojarasca en bosques
	r.ground = SplatRule.Ground.FOREST_FLOOR
	r.biomes = ["TAIGA", "TEMPERATE_RAIN_FOREST", "TEMPERATE_DECIDUOUS_FOREST",
			"TROPICAL_RAIN_FOREST", "TROPICAL_SEASONAL_FOREST"] as Array[String]
	out.rules.append(r)

	r = SplatRule.new()   # 9. desiertos y suelo pelado
	r.ground = SplatRule.Ground.SAND
	r.biomes = ["SUBTROPICAL_DESERT", "TEMPERATE_DESERT", "BEACH"] as Array[String]
	out.rules.append(r)

	r = SplatRule.new()   # 10. tundra/estepa/pantano → tierra
	r.ground = SplatRule.Ground.DIRT
	r.biomes = ["TUNDRA", "BARE", "SCORCHED", "SHRUBLAND", "MARSH"] as Array[String]
	r.weight = 0.8
	out.rules.append(r)

	r = SplatRule.new()   # 11. default
	r.ground = SplatRule.Ground.GRASS
	out.rules.append(r)
	return out
