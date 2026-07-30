class_name TerraceHeightLayer
extends HeightLayer

## ============================================================================
## TerraceHeightLayer · Cuantiza la altura acumulada en escalones (bancales)
## ============================================================================
## Opera sobre h previa → override de apply() (no usa _value).
## ============================================================================

@export var step_m: float = 6.0
## 0 = rampa (sin efecto), 1 = escalón duro.
@export_range(0.0, 1.0, 0.05) var sharpness: float = 0.8


func _init() -> void:
	layer_name = &"terrace"


func apply(pos: Vector2, h: float, ctx: HeightContext) -> float:
	var w := strength * (1.0 if mask == null else mask.weight(pos, ctx))
	if w <= 0.0001 or step_m <= 0.001:
		return h
	var t := h / step_m
	var f := floorf(t)
	var frac := t - f
	# Banda de transición = (1 - sharpness): sharpness 0 → rampa completa (sin
	# efecto), sharpness 1 → escalón casi duro. band mínima 0.005 para no
	# degenerar smoothstep(0.5, 0.5, x) (división por cero).
	var band := maxf(1.0 - sharpness, 0.005)
	var lo := 0.5 - 0.5 * band
	var hi := 0.5 + 0.5 * band
	var shaped := f + smoothstep(lo, hi, frac)
	return lerpf(h, shaped * step_m, w)
