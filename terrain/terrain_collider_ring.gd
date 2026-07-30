class_name TerrainColliderRing
extends StaticBody3D

## ============================================================================
## TerrainColliderRing · Colisión SOLO alrededor del jugador (16KM-4, §F8.3)
## ============================================================================
## Patrón Terrain3D DYNAMIC: en vez de HeightMapShape3D para TODO el mapa
## (imposible a 16 km), un anillo de chunks de colisión que SIGUE al target
## (player → cámara), creando/soltando shapes al cruzar de celda. El TELEPORT
## lo cubre el mismo update (rellena alrededor del nuevo pos, suelta lo viejo).
## La fuente es el heightfield CPU (sampler) — ya desacoplado del render; el
## muestreo reusa TerrainColliderBuilder._chunk_shape (un solo chokepoint).
## Chunks 100 % mar profundo no generan shape (igual que el builder full).
## ============================================================================

var sampler: HeightSampler
## F1b.6 · Fuente de altura para el muestreo (duck-typed get_height). null ⇒ usa
## `sampler` (global). Con streaming por regiones se setea al RegionStreamSampler
## → la colisión cercana coincide con los tiles finos del render (sin flotar/hundir).
var height_source = null
var sea_mask: SeaMask
var sea_level := 0.0
var chunk_m := 128.0
var radius_m := 96.0
var step_m := 1.0
## null ⇒ player (grupo SystemLink.PLAYER) ⇒ cámara actual del viewport.
var target: Node3D = null

const UPDATE_S := 0.15

var _chunks := {}            # Vector2i → CollisionShape3D | null (mar: no reintentar)
var _accum := 0.0
var _last_cell := Vector2i(1 << 30, 1 << 30)


func _ready() -> void:
	collision_layer = 1  # layer_1 = "world" (mismo contrato que TerrainCollider)
	collision_mask = 0
	set_meta(&"surface", &"grass")


func _physics_process(delta: float) -> void:
	_accum += delta
	if _accum < UPDATE_S:
		return
	_accum = 0.0
	if sampler == null:
		return
	var t := _resolve_target()
	if t == null:
		return
	var p := Vector2(t.global_position.x, t.global_position.z)
	var cell := Vector2i(int(floorf(p.x / chunk_m)), int(floorf(p.y / chunk_m)))
	if cell == _last_cell:
		return  # no cruzó de celda: nada que reconstruir (patrón Terrain3D)
	_last_cell = cell
	var span := int(ceilf(radius_m / chunk_m))
	var want := {}
	for dz in range(-span, span + 1):
		for dx in range(-span, span + 1):
			want[cell + Vector2i(dx, dz)] = true
	# Soltar chunks fuera del anillo.
	for key: Vector2i in _chunks.keys():
		if not want.has(key):
			var cs: Variant = _chunks[key]
			if cs != null:
				(cs as CollisionShape3D).queue_free()
			_chunks.erase(key)
	# Crear los que faltan (null cacheado = mar profundo, no reintentar).
	for key: Vector2i in want:
		if not _chunks.has(key):
			_chunks[key] = _build_chunk(key)


func _resolve_target() -> Node3D:
	if target != null and is_instance_valid(target):
		return target
	var pl := get_tree().get_first_node_in_group(SystemLink.PLAYER) as Node3D
	if pl != null:
		return pl
	return get_viewport().get_camera_3d() if get_viewport() != null else null


func _build_chunk(key: Vector2i) -> CollisionShape3D:
	var rect := Rect2(Vector2(key.x, key.y) * chunk_m, Vector2(chunk_m, chunk_m))
	rect = rect.intersection(Rect2(sampler.bounds.position, sampler.bounds.size))
	if rect.size.x < step_m or rect.size.y < step_m:
		return null
	var src: Variant = height_source if height_source != null else sampler
	var shape := TerrainColliderBuilder._chunk_shape(src, rect, step_m,
			sea_level, sea_mask)
	if shape == null:
		return null  # mar profundo real
	var cs := CollisionShape3D.new()
	cs.name = "Ring_%d_%d" % [key.x, key.y]
	cs.shape = shape
	var center := rect.get_center()
	cs.position = Vector3(center.x, 0.0, center.y)
	cs.set_meta(&"surface", &"grass")
	add_child(cs)
	return cs


## Cuántos shapes vivos (para tests/overlays).
func active_chunks() -> int:
	var n := 0
	for v: Variant in _chunks.values():
		if v != null:
			n += 1
	return n
