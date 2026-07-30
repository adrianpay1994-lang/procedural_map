class_name RegionHeightTextures
extends RefCounted

## ============================================================================
## RegionHeightTextures · Texturas GPU + materiales por región (F1b)
## ============================================================================
## Envuelve una RegionStreamSampler y entrega, por región, un ShaderMaterial listo
## para las hojas FINAS del quadtree: duplica el material base con
## use_region_tile=true + la textura de altura del tile (RF) + tile_origin/size.
## LRU acotado (max_resident) → memoria GPU controlada al moverse la cámara.
## Ver docs/PLAN_F1B_HEIGHTFIELD_REGIONES.md §2.3.
## ============================================================================

var sampler: RegionStreamSampler = null
## Material base (el terrain_material real). Se duplica por región.
var base_material: ShaderMaterial = null
## Tope de regiones residentes en GPU (≈ 5×5 alrededor de la cámara).
var max_resident := 25

## F1b.7 · Bake AMORTIZADO: en vez de bakear el tile sincrónicamente cuando una
## hoja lo pide (hitch si caen varios en un frame), se ENCOLA y se bakea de a
## `max_bakes_per_pump` por pump() (llamado 1×/frame por el quadtree). La hoja usa
## el material GLOBAL de fallback hasta que su tile está listo (sin huecos). NO es
## threading: el bake usa cachés de localización NO thread-safe (skill §2), así que
## amortizar por frame es la forma SEGURA de matar el hitch.
var async_bake := false
var max_bakes_per_pump := 2
var _queue: Array[Vector2i] = []

var _tex := {}   # Vector2i → ImageTexture
var _mat := {}   # Vector2i → ShaderMaterial
var _lru: Array[Vector2i] = []


func setup(p_sampler: RegionStreamSampler, p_base: ShaderMaterial) -> void:
	sampler = p_sampler
	base_material = p_base


## Material para una hoja que cae DENTRO de la región `key`. Sync (default): bakea
## en el acto. async_bake: si el tile no está listo, lo ENCOLA y devuelve null (el
## caller usa el material global de fallback hasta que pump() lo hornee).
func material_for(key: Vector2i):
	if _mat.has(key):
		_touch(key)
		return _mat[key]
	if async_bake:
		if not _queue.has(key):
			_queue.append(key)
		return null
	return _bake_now(key)


## ¿Ya está el tile de esta región horneado y residente?
func ready(key: Vector2i) -> bool:
	return _mat.has(key)


## Hornea hasta max_bakes_per_pump tiles encolados (1×/frame). Devuelve cuántos.
func pump() -> int:
	var n := 0
	while n < max_bakes_per_pump and not _queue.is_empty():
		var key: Vector2i = _queue.pop_front()
		if not _mat.has(key):
			_bake_now(key)
			n += 1
	return n


func _bake_now(key: Vector2i) -> ShaderMaterial:
	var img := sampler.get_tile_image(key)
	var tex := ImageTexture.create_from_image(img)
	var m := base_material.duplicate() as ShaderMaterial
	m.set_shader_parameter(&"clipmap_displace", true)
	m.set_shader_parameter(&"use_region_tile", true)
	m.set_shader_parameter(&"region_tile", tex)
	m.set_shader_parameter(&"tile_origin",
			sampler.bounds.position + Vector2(key) * sampler.region_m)
	m.set_shader_parameter(&"tile_size_m", sampler.region_m)
	m.set_shader_parameter(&"tile_texel_m",
			sampler.region_m / float(sampler.region_res - 1))
	_tex[key] = tex
	_mat[key] = m
	_lru.append(key)
	_evict()
	return m


## Región (Vector2i) que contiene el punto world p.
func region_of(p: Vector2) -> Vector2i:
	return Vector2i(int(floorf((p.x - sampler.bounds.position.x) / sampler.region_m)),
			int(floorf((p.y - sampler.bounds.position.y) / sampler.region_m)))


func resident() -> int:
	return _mat.size()


func _touch(key: Vector2i) -> void:
	var i := _lru.find(key)
	if i >= 0:
		_lru.remove_at(i)
	_lru.append(key)


func _evict() -> void:
	while _mat.size() > max_resident:
		var oldest: Vector2i = _lru.pop_front()
		_mat.erase(oldest)
		_tex.erase(oldest)
