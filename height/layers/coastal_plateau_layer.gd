class_name CoastalPlateauLayer
extends HeightLayer

## ============================================================================
## CoastalPlateauLayer · Relieve base costa→rampa→MESETA (pipeline Fase B1)
## ============================================================================
## DEPRECATED (2026-07-10, OK del usuario): se retira cuando entre el sistema
## TerrainStamp (TERRAIN_PIPELINE_V2_PLAN.md §F2) — los perfiles de heightmap
## reubicables reemplazan este levantado fijo de costa. No agregar usos nuevos.
## ============================================================================
## Regla del usuario (spec exacto): desde el CONTORNO de la isla el terreno sube
## en RAMPA hacia el interior, con pendiente MÁXIMA 1 m cada 2 m (max_ramp_slope
## 0.5). La rampa es RANDOM: puede ser más suave y completarse hasta a
## ramp_max_distance_m (40 m) de la costa. De ahí al centro queda toda la isla a
## `plateau_height_m` (la ondulación fina la agrega la NoiseHeightLayer que sigue,
## "que mueva un poco nomás para que parezca natural"). El lecho oceánico intacto.
##
## Eje de la rampa = ELEVACIÓN del grafo (0 en la costa, sube al interior). Es
## LISA y continua (la distancia métrica elev/gradiente daba spikes sub-celda en
## los bordes de triángulo → desalineaba mesh/collider). La rampa se completa al
## llegar a `ramp_elev` de elevación (fracción baja = meseta cerca de la costa);
## el ruido la ALARGA (más suave, random). Interior plano en plateau_height_m.
## ============================================================================

## Altura de la meseta interior (m sobre el nivel del mar) = a dónde llega la isla.
@export var plateau_height_m: float = 16.0
## Fracción de elevación del grafo (0..1) donde la rampa MÁS CORTA alcanza la
## meseta. Menor = la isla se levanta más cerca de la costa (rampa más corta).
@export_range(0.02, 1.0, 0.01) var ramp_elev: float = 0.12
## Cuánto ALARGA el ruido la rampa (más suave), random a lo largo de la costa.
## 1.0 = puede duplicar el largo; 0 = rampa uniforme.
@export_range(0.0, 2.0, 0.05) var ramp_random: float = 0.8
## Frecuencia del ruido que varía el largo de la rampa (bajo = varía lento).
@export var ramp_noise_freq: float = 0.008
## Profundidad normalizada del lecho oceánico (0.15 ⇒ 15% de height_scale).
@export_range(0.0, 1.0, 0.01) var ocean_depth_norm: float = 0.15

var _noise: FastNoiseLite


func _init() -> void:
	blend = BlendMode.REPLACE
	layer_name = &"coastal_plateau"


func prepare(ctx: HeightContext) -> void:
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = ramp_noise_freq
	_noise.seed = ctx.global_seed if ctx != null else 0


func _value(pos: Vector2, ctx: HeightContext) -> float:
	ctx.ocean_depth_norm = ocean_depth_norm  # lo lee get_base_slope01 (erosión)
	var e := ctx.get_graph_elevation(pos)
	if e < 0.0:
		return e * ctx.height_scale  # lecho oceánico sin tocar
	# Largo de la rampa (en fracción de elevación): mínimo = ramp_elev; el ruido
	# de baja frecuencia lo alarga (rampa más suave) — varía suave a lo largo de
	# la costa, sin discontinuidades. Toda la isla llega a la MISMA meseta.
	var n01 := (_noise.get_noise_2d(pos.x, pos.y) * 0.5 + 0.5) if _noise != null else 0.5
	var re := ramp_elev * (1.0 + n01 * ramp_random)
	var ramp := clampf(e / maxf(re, 0.01), 0.0, 1.0)
	return ramp * plateau_height_m
