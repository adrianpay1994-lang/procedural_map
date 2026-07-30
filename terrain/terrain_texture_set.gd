class_name TerrainTextureSet
extends Resource

## ============================================================================
## TerrainTextureSet · 8 slots PBR, uno por material del splat (§5.1)
## ============================================================================
## Índices = SplatRule.Ground: 0 grass · 1 dirt · 2 sand · 3 rock · 4 snow ·
## 5 forest_floor · 6 gravel · 7 mud.
## ORM: R=AO, G=Roughness, B=Metallic, A=Height (para height-blend).
## Slots null → el MaterialBuilder genera un plano de color (el mapa funciona
## igual; se ve mejor a medida que se cargan texturas reales).
## ============================================================================

@export var albedo: Array[Texture2D] = [null, null, null, null, null, null, null, null]
@export var normal: Array[Texture2D] = [null, null, null, null, null, null, null, null]
@export var orm: Array[Texture2D] = [null, null, null, null, null, null, null, null]
## Tamaño al que se homogeneizan las capas del Texture2DArray.
@export var layer_size: int = 1024


## Set de fábrica: los 8 materiales GENERADOS por tools/gen_ground_textures.gd
## (regla del usuario: todas las texturas creadas por la IA — tileables, PBR
## completas con height para el blend; regenerables con otra receta/tamaño).
static func make_default() -> TerrainTextureSet:
	var s := TerrainTextureSet.new()
	var by_ground := {
		SplatRule.Ground.GRASS: "grass",
		SplatRule.Ground.DIRT: "dirt",
		SplatRule.Ground.SAND: "sand",
		SplatRule.Ground.ROCK: "cliff",
		SplatRule.Ground.SNOW: "snow",
		SplatRule.Ground.FOREST_FLOOR: "moss",
		SplatRule.Ground.GRAVEL: "gravel",  # piedras Voronoi propias: calzada
		SplatRule.Ground.MUD: "mud",
	}
	for ground in by_ground:
		var mat_name: String = by_ground[ground]
		s.albedo[ground] = load("res://assets/terrain/%s_albedo.png" % mat_name)
		s.normal[ground] = load("res://assets/terrain/%s_normal.png" % mat_name)
		s.orm[ground] = load("res://assets/terrain/%s_orm.png" % mat_name)
	return s
