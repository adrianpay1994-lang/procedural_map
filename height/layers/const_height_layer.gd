class_name ConstHeightLayer
extends HeightLayer

## ============================================================================
## ConstHeightLayer · Valor constante — piso/techo con blend MAX/MIN
## ============================================================================
## Uso típico: piso de una depresión (blend MAX, value = sea_level + 1) para
## que una "montaña invertida" nunca perfore bajo el nivel del mar y muestre
## el océano adentro.
## ============================================================================

@export var value_m: float = 1.0


func _init() -> void:
	layer_name = &"const"
	blend = BlendMode.MAX


func _value(_pos: Vector2, _ctx: HeightContext) -> float:
	return value_m
