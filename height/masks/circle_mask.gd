class_name CircleMask
extends HeightMask

## Peso 1 dentro de radius_m, cae suave a 0 en radius_m + falloff_m.

@export var center: Vector2 = Vector2.ZERO
@export var radius_m: float = 50.0
@export var falloff_m: float = 20.0


func _aabb() -> Rect2:
	var r := radius_m + maxf(falloff_m, 0.0)
	return Rect2(center - Vector2(r, r), Vector2(r, r) * 2.0)


func _weight(pos: Vector2, _ctx: HeightContext) -> float:
	var d := pos.distance_to(center)
	if d <= radius_m:
		return 1.0
	if falloff_m <= 0.0:
		return 0.0
	return 1.0 - smoothstep(radius_m, radius_m + falloff_m, d)
