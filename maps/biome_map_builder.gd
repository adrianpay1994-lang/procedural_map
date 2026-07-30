class_name BiomeMapBuilder
extends RefCounted

## ============================================================================
## BiomeMapBuilder · Mapa climático RGBA (§5.1) — tint del shader estilo Rust
## ============================================================================
## Pesos por texel desde temperatura×humedad del grafo:
##   arid = t(1-m) · temperate = t·m · tundra = (1-t)m · arctic = (1-t)(1-m)
## (suman 1 por construcción). R=arid G=temperate B=tundra A=arctic.
## ============================================================================

var biome_image: Image

var _sampler: HeightSampler
var _resolution: int
var _bounds: Rect2
var _texel: Vector2
var rows_done: int = 0
var rows_total: int = 1
var _px: PackedByteArray


func build(sampler: HeightSampler, resolution: int, blur_m: float,
		frame_yield: Callable = Callable()) -> void:
	_sampler = sampler
	_resolution = resolution
	_bounds = sampler.bounds
	_texel = Vector2(_bounds.size.x / float(resolution - 1),
			_bounds.size.y / float(resolution - 1))
	_px = PackedByteArray()
	_px.resize(resolution * resolution * 4)
	rows_total = resolution
	rows_done = 0
	var task := WorkerThreadPool.add_group_task(_build_row, resolution, TerrainSettings.worker_count(), false,
			"BiomeMapBuilder.build")
	if frame_yield.is_valid():
		while not WorkerThreadPool.is_group_task_completed(task):
			await frame_yield.call()
	WorkerThreadPool.wait_for_group_task_completion(task)
	biome_image = Image.create_from_data(resolution, resolution, false,
			Image.FORMAT_RGBA8, _px)
	_px = PackedByteArray()
	var blur_tex := blur_m / _texel.x
	if blur_tex >= 1.5:
		var factor := clampi(int(roundf(blur_tex)), 2, 8)
		var small := maxi(floori(float(resolution) / float(factor)), 32)
		biome_image.resize(small, small, Image.INTERPOLATE_BILINEAR)
		biome_image.resize(resolution, resolution, Image.INTERPOLATE_CUBIC)


func _build_row(row: int) -> void:
	var ctx := _sampler.make_context()
	var y := _bounds.position.y + float(row) * _texel.y
	for x in _resolution:
		var pos := Vector2(_bounds.position.x + float(x) * _texel.x, y)
		var c := ctx.get_center(pos)
		var t := clampf(c.temperature, 0.0, 1.0)
		var m := clampf(c.moisture, 0.0, 1.0)
		var off := (row * _resolution + x) * 4
		_px[off + 0] = int(t * (1.0 - m) * 255.0)
		_px[off + 1] = int(t * m * 255.0)
		_px[off + 2] = int((1.0 - t) * m * 255.0)
		_px[off + 3] = int((1.0 - t) * (1.0 - m) * 255.0)
	rows_done += 1
