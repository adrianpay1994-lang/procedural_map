class_name ProceduralSpawner
extends Spawner

## ============================================================================
## ProceduralSpawner · Spawner del juego + puntos calculados por el mapa (§7)
## ============================================================================
## Hereda TODO el ciclo de vida de Spawner (fill/interval/tracking); solo
## cambia de dónde salen los puntos: transforms precalculados por
## EntitySpawnSystem en vez de un grupo de markers.
## ============================================================================

var points: Array[Transform3D] = []
var _next := 0


func _next_point() -> Transform3D:
	if points.is_empty():
		return global_transform
	# Rotación determinista sobre la lista (sin randi global).
	var t := points[_next % points.size()]
	_next += 1
	return t
