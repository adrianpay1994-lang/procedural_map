class_name PolygonMask
extends HeightMask

## Peso 1 dentro del polígono, falloff por distancia al borde.

@export var polygon: PackedVector2Array = PackedVector2Array()
@export var falloff_m: float = 15.0


func _aabb() -> Rect2:
	if polygon.size() < 3:
		return Rect2()
	var r := Rect2(polygon[0], Vector2.ZERO)
	for p in polygon:
		r = r.expand(p)
	return r.grow(maxf(falloff_m, 0.0))


func _weight(pos: Vector2, _ctx: HeightContext) -> float:
	if polygon.size() < 3:
		return 0.0
	var inside := Geometry2D.is_point_in_polygon(pos, polygon)
	if inside and falloff_m <= 0.0:
		return 1.0
	# Distancia al borde (mínimo sobre los segmentos).
	var d := INF
	var n := polygon.size()
	for i in n:
		var a := polygon[i]
		var b := polygon[(i + 1) % n]
		d = minf(d, _dist_point_segment(pos, a, b))
	if inside:
		return 1.0  # dentro: peso pleno; el falloff actúa solo hacia afuera
	if falloff_m <= 0.0:
		return 0.0
	return 1.0 - smoothstep(0.0, falloff_m, d)


static func _dist_point_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)
