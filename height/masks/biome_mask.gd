class_name BiomeMask
extends HeightMask

## Peso 1 si el punto cae en un Center cuyo bioma está en la lista, con
## falloff suave cruzando el borde hacia biomas no incluidos.
## Biomas de pcg-terrain_1 (mapgen2): OCEAN, LAKE, MARSH, ICE, BEACH, SNOW,
## TUNDRA, BARE, SCORCHED, TAIGA, SHRUBLAND, TEMPERATE_DESERT,
## TEMPERATE_RAIN_FOREST, TEMPERATE_DECIDUOUS_FOREST, GRASSLAND,
## TROPICAL_RAIN_FOREST, TROPICAL_SEASONAL_FOREST, SUBTROPICAL_DESERT.

@export var biomes: Array[String] = []
@export var edge_falloff_m: float = 25.0


func _weight(pos: Vector2, ctx: HeightContext) -> float:
	if biomes.is_empty():
		return 0.0
	var c := ctx.get_center(pos)
	var inside := biomes.has(c.biome)
	if edge_falloff_m <= 0.0:
		return 1.0 if inside else 0.0
	# Distancia local al borde de bioma: mínima distancia a las aristas Voronoi
	# compartidas con vecinos de bioma distinto (si inside) o igual (si outside).
	var d := INF
	for e_any in c.borders:
		var e := e_any as Edge
		if e.v0 == null or e.v1 == null:
			continue
		var other: Center = e.d1 if e.d0 == c else e.d0
		if other == null:
			continue
		var other_in := biomes.has(other.biome)
		if other_in == inside:
			continue
		d = minf(d, PolygonMask._dist_point_segment(pos, e.v0.point, e.v1.point))
	if d == INF:
		return 1.0 if inside else 0.0
	var t := clampf(d / edge_falloff_m, 0.0, 1.0)
	# El falloff se reparte a ambos lados del borde: 0.5 exactamente en la línea.
	return 0.5 + 0.5 * t if inside else 0.5 - 0.5 * t
