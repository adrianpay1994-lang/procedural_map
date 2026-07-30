class_name RectMask
extends HeightMask

## Peso 1 dentro del rect (rotado), cae a 0 en una banda de falloff_m.

@export var rect: Rect2 = Rect2(-100, -100, 200, 200)
@export_range(-180.0, 180.0, 1.0) var rotation_deg: float = 0.0
@export var falloff_m: float = 20.0


func _aabb() -> Rect2:
	var g := rect.grow(maxf(falloff_m, 0.0))
	var c := g.get_center()
	var out := Rect2(c, Vector2.ZERO)
	for corner: Vector2 in [g.position, g.end,
			Vector2(g.position.x, g.end.y), Vector2(g.end.x, g.position.y)]:
		out = out.expand(c + (corner - c).rotated(deg_to_rad(rotation_deg)))
	return out


func _weight(pos: Vector2, _ctx: HeightContext) -> float:
	var c := rect.get_center()
	var local := (pos - c).rotated(-deg_to_rad(rotation_deg))
	var half := rect.size * 0.5
	# Distancia con signo al borde del rect (negativa adentro).
	var q := local.abs() - half
	var outside := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length()
	if outside <= 0.0:
		return 1.0
	if falloff_m <= 0.0:
		return 0.0
	return 1.0 - smoothstep(0.0, falloff_m, outside)
