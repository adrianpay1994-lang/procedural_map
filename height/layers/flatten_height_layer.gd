class_name FlattenHeightLayer
extends HeightLayer

## ============================================================================
## FlattenHeightLayer · Nivela el terreno hacia una altura objetivo
## ============================================================================
## POISystem inyecta una por monumento (con CircleMask + falloff) ANTES del
## bake. El peso de la máscara ES el lerp hacia el target.
## ============================================================================

@export var target_height_m: float = 10.0


func _init() -> void:
	layer_name = &"flatten"
	blend = BlendMode.REPLACE


func apply(pos: Vector2, h: float, ctx: HeightContext) -> float:
	var w := strength * (1.0 if mask == null else mask.weight(pos, ctx))
	if w <= 0.0001:
		return h
	return lerpf(h, target_height_m, minf(w, 1.0))
