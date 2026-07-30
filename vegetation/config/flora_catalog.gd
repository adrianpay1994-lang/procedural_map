class_name FloraCatalog
extends RefCounted

## ============================================================================
## FloraCatalog · Registro NOMBRADO de la flora: especies, tipos de hoja y de
## tronco, y QUIÉN usa cada uno (para el inspector y los diseñadores de assets)
## ============================================================================
## Fuente única de verdad: los presets de TreeParams. Todo se computa de ahí
## (agregar una especie nueva actualiza el catálogo solo).
##
## Costo de la hoja procedural: cada "spray" de copa = 2 quads cruzados = 12
## vértices; el costo real de un árbol lo manda su leaf_count (sprays totales).
## ============================================================================

## Especie → preset (canónico; el vivero muestra estas mismas).
static func species() -> Dictionary:
	return {
		"aspen": TreeParams.aspen, "black_oak": TreeParams.black_oak,
		"silver_birch": TreeParams.silver_birch, "balsam_fir": TreeParams.balsam_fir,
		"small_pine": TreeParams.small_pine, "juniper": TreeParams.juniper,
		"araucaria": TreeParams.araucaria, "lapacho": TreeParams.lapacho,
		"lapacho_amarillo": TreeParams.lapacho_amarillo, "ceibo": TreeParams.ceibo,
		"palo_rosa": TreeParams.palo_rosa, "ombu": TreeParams.ombu,
		"algarrobo": TreeParams.algarrobo, "coihue": TreeParams.coihue,
		"cedro": TreeParams.cedro, "anchico": TreeParams.anchico,
		"timbo": TreeParams.timbo, "guatambu": TreeParams.guatambu,
		"laurel": TreeParams.laurel, "incienso": TreeParams.incienso,
		"peteribi": TreeParams.peteribi, "ambay": TreeParams.ambay,
		"yerba_mate": TreeParams.yerba_mate, "ibira_pita": TreeParams.ibira_pita,
		"quebracho": TreeParams.quebracho, "chanar": TreeParams.chanar,
		"palo_borracho": TreeParams.palo_borracho, "espinillo": TreeParams.espinillo,
		"tala": TreeParams.tala, "arrayan": TreeParams.arrayan,
		"nire": TreeParams.nire, "notro": TreeParams.notro,
		"quebracho_blanco": TreeParams.quebracho_blanco, "maiten": TreeParams.maiten,
		"cipres_cordillera": TreeParams.cipres_cordillera, "tipa": TreeParams.tipa,
		"leafy_bush": TreeParams.leafy_bush, "dry_bush": TreeParams.dry_bush,
		"hideout_bush": TreeParams.hideout_bush,
		"hideout_bush_dry": TreeParams.hideout_bush_dry,
		"calafate": TreeParams.calafate, "neneo": TreeParams.neneo,
	}


## Tipo de hoja → PackedStringArray de especies que la usan.
static func leaf_types() -> Dictionary:
	var out := {}
	var sp := species()
	for nm: String in sp:
		var p: TreeParams = (sp[nm] as Callable).call()
		var lt: String = p.leaf_texture
		# PackedStringArray es value-type: append sobre el cast modifica una COPIA.
		var arr: PackedStringArray = out.get(lt, PackedStringArray())
		arr.append(nm)
		out[lt] = arr
	return out


## Biomas con flora declarada (los que consulta el mapa).
const BIOMES := ["TROPICAL_RAIN_FOREST", "TROPICAL_SEASONAL_FOREST",
		"TEMPERATE_RAIN_FOREST", "TEMPERATE_DECIDUOUS_FOREST", "TAIGA",
		"SUBTROPICAL_DESERT", "TEMPERATE_DESERT", "GRASSLAND", "SAVANNA", "SHRUBLAND"]


## Tipo de planta/pasto → PackedStringArray de BIOMAS que la usan.
static func plant_types() -> Dictionary:
	var out := {}
	for biome: String in BIOMES:
		for kind: String in BiomeFloraLibrary.plants_for(biome):
			var arr: PackedStringArray = out.get(kind, PackedStringArray())
			arr.append(biome)
			out[kind] = arr
	# El junco de orilla se coloca aparte (no por bioma).
	var reed_arr: PackedStringArray = out.get("reed", PackedStringArray())
	reed_arr.append("orillas de agua")
	out["reed"] = reed_arr
	return out


## Tipo de tronco/corteza → especies que lo usan.
static func bark_types() -> Dictionary:
	var out := {}
	var sp := species()
	for nm: String in sp:
		var p: TreeParams = (sp[nm] as Callable).call()
		var bt: String = p.bark_type
		var arr: PackedStringArray = out.get(bt, PackedStringArray())
		arr.append(nm)
		out[bt] = arr
	return out
