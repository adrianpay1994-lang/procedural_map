class_name VoronoiBaseLayer
extends HeightLayer

## ============================================================================
## VoronoiBaseLayer · Capa 0 — silueta macro de la isla desde el grafo
## ============================================================================
## Interpola la elevación firmada del grafo (océano < 0) y la escala a metros.
## La costa cruza h=0 exactamente en la línea de agua. blend por defecto: REPLACE.
## ============================================================================

## >1 acentúa montañas (curva de contraste sobre la elevación 0..1).
@export_range(0.1, 3.0, 0.05) var elevation_curve_power: float = 1.0
## Profundidad normalizada del lecho oceánico (0.15 ⇒ 15% de height_scale bajo el mar).
@export_range(0.0, 1.0, 0.01) var ocean_depth_norm: float = 0.15


func _init() -> void:
	blend = BlendMode.REPLACE
	layer_name = &"voronoi_base"


func _value(pos: Vector2, ctx: HeightContext) -> float:
	ctx.ocean_depth_norm = ocean_depth_norm
	var e := ctx.get_graph_elevation(pos)
	if e >= 0.0:
		return pow(e, elevation_curve_power) * ctx.height_scale
	return e * ctx.height_scale
