class_name GraphQuery
extends RefCounted

## ============================================================================
## GraphQuery · Índice espacial de Centers (grid hash)
## ============================================================================
## nearest_center() es O(1) amortizado. En Voronoi, el center más cercano ES
## el polígono que contiene el punto (definición de celda de Voronoi).
## Solo lectura tras setup() → seguro entre threads del bake.
## ============================================================================

var _cells: Dictionary = {}          # Vector2i -> Array[Center]
var _cell_size: float = 16.0
var _origin: Vector2 = Vector2.ZERO
var _all: Array = []                 # Array[Center]


func setup(centers: Array, bounds: Rect2, cells_per_axis: int = 64) -> void:
	_all = centers
	_origin = bounds.position
	_cell_size = maxf(bounds.size.x, bounds.size.y) / float(maxi(cells_per_axis, 1))
	_cells.clear()
	for c in centers:
		var key := _key((c as Center).point)
		if not _cells.has(key):
			_cells[key] = []
		(_cells[key] as Array).append(c)


func _key(p: Vector2) -> Vector2i:
	return Vector2i(int(floorf((p.x - _origin.x) / _cell_size)),
			int(floorf((p.y - _origin.y) / _cell_size)))


## Center más cercano a pos. Busca en anillos crecientes del grid.
func nearest_center(pos: Vector2) -> Center:
	var k := _key(pos)
	var best: Center = null
	var best_d := INF
	var ring := 0
	# Expandir anillos hasta encontrar candidatos y un anillo extra de seguridad
	# (el más cercano puede estar en la celda vecina aunque haya uno local).
	while ring < 64:
		var found_any := false
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if absi(dx) != ring and absi(dy) != ring:
					continue  # solo el borde del anillo
				var cell: Array = _cells.get(k + Vector2i(dx, dy), [])
				for c in cell:
					found_any = true
					var d := (c as Center).point.distance_squared_to(pos)
					if d < best_d:
						best_d = d
						best = c
		if best != null and found_any and ring >= 1:
			break  # un anillo más allá del primer hit alcanza
		if best != null and ring >= 1:
			break
		ring += 1
	if best == null:
		# Fallback lineal (grid vacío en esa zona — no debería pasar)
		for c in _all:
			var d := (c as Center).point.distance_squared_to(pos)
			if d < best_d:
				best_d = d
				best = c
	return best
