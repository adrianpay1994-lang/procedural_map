class_name ShorelineLayer
extends HeightLayer

## ============================================================================
## ShorelineLayer · Costa CAMINABLE (backlog #48)
## ============================================================================
## Regla del usuario: aunque haya acantilado, antes del agua SIEMPRE hay un
## suelo transitable. Comprime la franja de alturas justo sobre el mar en una
## repisa suave: lo que estaba entre sea y sea+band queda tendido (~repisa de
## playa/pie de acantilado); por encima el terreno sigue igual (blend suave).
## Global — vale para toda la línea de costa, oasis y lagos grandes a nivel.
## ============================================================================

@export var sea_level: float = 0.0
## Franja comprimida (alturas sea..sea+band_m se aplanan en la repisa).
@export var band_m: float = 2.6
## Cuánto se aplana la franja (0.25 = la repisa sube solo el 25% del original).
@export_range(0.05, 1.0, 0.05) var flatten_factor: float = 0.3
## Altura mínima de la repisa sobre el mar (que no la lama cada ola).
@export var ledge_min_m: float = 0.5


func _init() -> void:
	layer_name = &"shoreline"


func apply(pos: Vector2, h: float, ctx: HeightContext) -> float:
	var w := strength * (1.0 if mask == null else mask.weight(pos, ctx))
	if w <= 0.0001:
		return h
	var rel := h - sea_level
	if rel <= 0.0 or rel >= band_m * 2.0:
		return h
	var shaped: float
	if rel <= band_m:
		shaped = ledge_min_m + rel * flatten_factor
	else:
		# Transición suave repisa → terreno normal (sin escalón).
		var t := (rel - band_m) / band_m
		var ledge_top := ledge_min_m + band_m * flatten_factor
		shaped = lerpf(ledge_top, rel, smoothstep(0.0, 1.0, t))
	return lerpf(h, sea_level + shaped, w)
