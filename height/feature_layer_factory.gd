class_name FeatureLayerFactory
extends RefCounted

## ============================================================================
## FeatureLayerFactory · "Heightmap procedural por sector" (backlog #12)
## ============================================================================
## Rust no es "isla alta en el centro": aplica RASGOS aleatorios por zonas —
## macizos, cañones/depresiones, mesetas — como capas locales sobre el relieve
## base. Esto genera exactamente eso: K capas con máscara circular en sectores
## elegidos del grafo, deterministas por seed. Todas editables/las reemplaza
## el usuario poniendo su propia pila en el Inspector.
## ============================================================================

const TYPE_MOUNTAIN := 0
const TYPE_DEPRESSION := 1
const TYPE_MESA := 2


static func make(config: MapGenerationConfig, provider: MapDataProvider,
		sea_level: float) -> Array[HeightLayer]:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([config.seed_variant, "terrain_features"])
	var out: Array[HeightLayer] = []
	# Candidatos: montañas en interior alto, depresiones/mesetas en interior medio.
	var high: Array[Vector2] = []
	var mid: Array[Vector2] = []
	for c in provider.get_land_centers():
		if c.coast:
			continue
		if c.elevation > 0.45:
			high.append(c.point)
		elif c.elevation > 0.15:
			mid.append(c.point)
	var count := 2 + rng.randi() % 3   # 2-4 rasgos por isla
	var used: Array[Vector2] = []
	for _i in count:
		var kind := rng.randi() % 3
		var pool := high if kind == TYPE_MOUNTAIN else mid
		if pool.is_empty():
			continue
		var pos := pool[rng.randi() % pool.size()]
		var too_close := false
		for u in used:
			if u.distance_to(pos) < 120.0:
				too_close = true
				break
		if too_close:
			continue
		used.append(pos)
		match kind:
			TYPE_MOUNTAIN:
				out.append_array(_mountain(pos, rng))
			TYPE_DEPRESSION:
				out.append_array(_depression(pos, rng, sea_level))
			TYPE_MESA:
				out.append_array(_mesa(pos, rng))
	return out


## Macizo: ruido RIDGED sumado en un sector (crestas afiladas).
static func _mountain(pos: Vector2, rng: RandomNumberGenerator) -> Array[HeightLayer]:
	var noise := NoiseHeightLayer.new()
	noise.layer_name = &"feature_mountain"
	noise.style = NoiseHeightLayer.NoiseStyle.RIDGED
	noise.noise_seed = rng.randi()
	noise.amplitude_m = rng.randf_range(24.0, 44.0)
	noise.frequency = rng.randf_range(0.015, 0.025)
	noise.octaves = 4
	noise.erosion_weight = 0.4
	var m := CircleMask.new()
	m.center = pos
	m.radius_m = rng.randf_range(55.0, 110.0)
	m.falloff_m = rng.randf_range(40.0, 70.0)
	noise.mask = m
	return [noise]


## "Montaña invertida": resta un domo de ruido + piso MAX sobre el mar
## (el océano JAMÁS aparece dentro de la depresión — backlog #18).
static func _depression(pos: Vector2, rng: RandomNumberGenerator,
		sea_level: float) -> Array[HeightLayer]:
	var noise := NoiseHeightLayer.new()
	noise.layer_name = &"feature_depression"
	noise.style = NoiseHeightLayer.NoiseStyle.FBM
	noise.noise_seed = rng.randi()
	noise.blend = HeightLayer.BlendMode.SUBTRACT
	noise.amplitude_m = rng.randf_range(14.0, 24.0)
	noise.frequency = 0.02
	noise.octaves = 3
	noise.erosion_weight = 0.0
	var m := CircleMask.new()
	m.center = pos
	m.radius_m = rng.randf_range(40.0, 80.0)
	m.falloff_m = rng.randf_range(30.0, 50.0)
	noise.mask = m
	# Sin piso artificial (backlog #49): la depresión PUEDE bajar de la cota 0
	# — el SeaMask (mar solo conectado al borde) garantiza que el océano no se
	# vea adentro, como hace Rust con sus "montañas invertidas".
	var floor_layer := ConstHeightLayer.new()
	floor_layer.layer_name = &"feature_depression_floor"
	floor_layer.value_m = sea_level - 6.0  # tope de excavación, no del mar
	var fm := CircleMask.new()
	fm.center = pos
	fm.radius_m = m.radius_m + m.falloff_m
	fm.falloff_m = 10.0
	floor_layer.mask = fm
	return [noise, floor_layer]


## Meseta: aplanado alto + terrazas suaves en el borde (acantilado escalonado).
static func _mesa(pos: Vector2, rng: RandomNumberGenerator) -> Array[HeightLayer]:
	var flat := FlattenHeightLayer.new()
	flat.layer_name = &"feature_mesa"
	flat.target_height_m = rng.randf_range(16.0, 30.0)
	flat.strength = 0.85
	var m := CircleMask.new()
	m.center = pos
	m.radius_m = rng.randf_range(45.0, 85.0)
	m.falloff_m = rng.randf_range(18.0, 30.0)
	flat.mask = m
	var terrace := TerraceHeightLayer.new()
	terrace.layer_name = &"feature_mesa_terrace"
	terrace.step_m = 5.0
	terrace.sharpness = 0.75
	var tm := CircleMask.new()
	tm.center = pos
	tm.radius_m = m.radius_m + m.falloff_m + 12.0
	tm.falloff_m = 14.0
	terrace.mask = tm
	return [flat, terrace]
