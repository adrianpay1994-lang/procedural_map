class_name LakeCraterLayer
extends HeightLayer

## ============================================================================
## LakeCraterLayer · Cuenco CÓNCAVO de lago (pipeline C4 — cilindro cerrado)
## ============================================================================
## Regla del usuario: los lagos usan un método similar al cilindro del río —
## determinar el contorno y generar una forma cóncava que hace un CRÁTER; desde
## ahí sale la zanja del lago y sabe dónde va el agua. Rampa perimetral suave →
## repisa caminable → pozo central, sin escalones planos.
##
## El bed baja radialmente del borde (rim, a la altura del agua) al centro
## (rim − depth) con un perfil suave (smoothstep). La máscara (PolygonMask con
## falloff) da la rampa exterior que empalma con el terreno. ICE = plato llano.
## ============================================================================

## Centro del cuenco y radio máximo (borde más lejano).
@export var centroid: Vector2 = Vector2.ZERO
@export var radius_m: float = 20.0
## Altura del borde del cráter (donde el bed toca la orilla).
@export var rim_height_m: float = 8.0
## Profundidad del pozo central bajo el borde.
@export var depth_m: float = 3.5
## Lago congelado: plato llano (no cuenco) — se camina encima.
@export var frozen: bool = false
## Perímetro (para bake_rim): el borde real del cráter = terreno MÁS BAJO del
## contorno, leído del terreno YA formado (no de la elevación cruda del grafo,
## que con la meseta base no coincide y dejaba el agua flotando).
var perimeter_points: PackedVector2Array = PackedVector2Array()


func _init() -> void:
	layer_name = &"lake_crater"
	blend = BlendMode.REPLACE


## Fija rim_height_m al terreno real más bajo del perímetro (lo llama el sampler
## antes del bake, muestreando la pila DEBAJO de esta capa). Devuelve ese rim.
func bake_rim(sample_below: Callable) -> float:
	if perimeter_points.is_empty():
		return rim_height_m
	var lo := INF
	for p in perimeter_points:
		lo = minf(lo, float(sample_below.call(p)))
	if lo < INF:
		rim_height_m = lo
	return rim_height_m


func apply(pos: Vector2, h: float, ctx: HeightContext) -> float:
	var w := strength * (1.0 if mask == null else mask.weight(pos, ctx))
	if w <= 0.0001:
		return h
	var target: float
	if frozen:
		target = rim_height_m - 0.2  # plato de hielo casi a ras del borde
	else:
		# Cuenco: 0 en el borde (r=1) → depth en el centro (r=0). smoothstep
		# suaviza la transición repisa→pozo (nada de escalón).
		var r := clampf(centroid.distance_to(pos) / maxf(radius_m, 0.001), 0.0, 1.0)
		var bowl := smoothstep(0.0, 1.0, 1.0 - r)
		target = rim_height_m - depth_m * bowl
	return lerpf(h, target, minf(w, 1.0))
