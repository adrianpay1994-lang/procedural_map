class_name HeightMask
extends Resource

## ============================================================================
## HeightMask · Dónde aplica una HeightLayer (peso 0..1 por posición)
## ============================================================================
## weight()=1 dentro, 0 fuera, falloff suave en la transición.
## Subclases implementan _weight().
## ============================================================================

@export var invert: bool = false
## null = transición lineal-suave por defecto. La curva remapea el peso 0..1.
@export var falloff_curve: Curve


func weight(pos: Vector2, ctx: HeightContext) -> float:
	var w := clampf(_weight(pos, ctx), 0.0, 1.0)
	if falloff_curve != null:
		w = clampf(falloff_curve.sample_baked(w), 0.0, 1.0)
	return 1.0 - w if invert else w


## AABB (metros) fuera del cual weight() == 0. size 0 ⇒ GLOBAL (sin cota).
## invert (peso fuera del área) o una curva que remapea 0→>0 invalidan la
## cota de la subclase ⇒ global.
func aabb() -> Rect2:
	if invert:
		return Rect2()
	if falloff_curve != null and falloff_curve.sample_baked(0.0) > 0.0001:
		return Rect2()
	return _aabb()


func _aabb() -> Rect2:
	return Rect2()


func _weight(_pos: Vector2, _ctx: HeightContext) -> float:
	return 1.0
