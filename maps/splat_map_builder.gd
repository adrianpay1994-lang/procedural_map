class_name SplatMapBuilder
extends RefCounted

## ============================================================================
## SplatMapBuilder · Genera splat_0/splat_1 (pesos de 8 materiales) — §5.1
## ============================================================================
## Orden fijo de canales:
##   splat_0: R=grass  G=dirt         B=sand    A=rock
##   splat_1: R=snow   G=forest_floor B=gravel  A=mud
## Blur de transiciones vía doble resize (nativo, rápido) en vez de gaussiano
## por canal en GDScript. ponytail: si el blur por regla importa, compute shader.
## ============================================================================

var splat_0: Image
var splat_1: Image

var _sampler: HeightSampler
var _topology: TopologyMap
var _rules: Array[SplatRule]
var _resolution: int
var _bounds: Rect2
var _texel: Vector2
var rows_done: int = 0
var rows_total: int = 1
var _px0: PackedByteArray
var _px1: PackedByteArray


func build(sampler: HeightSampler, topology: TopologyMap, rules: SplatRules,
		resolution: int, edge_blur_m: float,
		frame_yield: Callable = Callable()) -> void:
	_sampler = sampler
	_topology = topology
	_rules = rules.rules
	_resolution = resolution
	_bounds = sampler.bounds
	_texel = Vector2(_bounds.size.x / float(resolution - 1),
			_bounds.size.y / float(resolution - 1))
	_px0 = PackedByteArray()
	_px0.resize(resolution * resolution * 4)
	_px1 = PackedByteArray()
	_px1.resize(resolution * resolution * 4)
	rows_total = resolution
	rows_done = 0
	var task := WorkerThreadPool.add_group_task(_build_row, resolution, TerrainSettings.worker_count(), false,
			"SplatMapBuilder.build")
	if frame_yield.is_valid():
		while not WorkerThreadPool.is_group_task_completed(task):
			await frame_yield.call()
	WorkerThreadPool.wait_for_group_task_completion(task)
	splat_0 = Image.create_from_data(resolution, resolution, false, Image.FORMAT_RGBA8, _px0)
	splat_1 = Image.create_from_data(resolution, resolution, false, Image.FORMAT_RGBA8, _px1)
	_px0 = PackedByteArray()
	_px1 = PackedByteArray()
	# Blur de transiciones: down/up-sample nativo ≈ gaussiano de radio (factor/2) texels.
	var blur_tex := edge_blur_m / _texel.x
	if blur_tex >= 1.5:
		var factor := clampi(int(roundf(blur_tex)), 2, 8)
		var small := maxi(floori(float(resolution) / float(factor)), 32)
		for img in [splat_0, splat_1]:
			img.resize(small, small, Image.INTERPOLATE_BILINEAR)
			img.resize(resolution, resolution, Image.INTERPOLATE_CUBIC)
	# El blur de 12 m se come una calzada de 7-9 m → re-pintar la grava NÍTIDA
	# desde la topología (los caminos deben leerse, como en Rust).
	await _sharpen_roads(topology, frame_yield)


func _sharpen_roads(topology: TopologyMap, frame_yield: Callable = Callable()) -> void:
	for z in _resolution:
		if frame_yield.is_valid() and z % 48 == 0:
			await frame_yield.call()
		var wy := _bounds.position.y + float(z) * _texel.y
		for x in _resolution:
			var pos := Vector2(_bounds.position.x + float(x) * _texel.x, wy)
			var bits := topology.get_topology(pos)
			if bits & (TopologyMap.TOPO_ROAD | TopologyMap.TOPO_RAIL):
				splat_0.set_pixel(x, z, Color(0, 0, 0, 0))
				splat_1.set_pixel(x, z, Color(0, 0, 1.0, 0))  # B = GRAVEL (calzada/balasto)
			elif bits & TopologyMap.TOPO_ROADSIDE:
				var c0 := splat_0.get_pixel(x, z)
				var c1 := splat_1.get_pixel(x, z)
				# Banquina: mezcla 50% tierra sobre lo que haya.
				splat_0.set_pixel(x, z, Color(c0.r * 0.5, c0.g * 0.5 + 0.5, c0.b * 0.5, c0.a * 0.5))
				splat_1.set_pixel(x, z, Color(c1.r * 0.5, c1.g * 0.5, c1.b * 0.5, c1.a * 0.5))


func _build_row(row: int) -> void:
	var ctx := _sampler.make_context()
	var y := _bounds.position.y + float(row) * _texel.y
	var weights: Array[float] = []
	weights.resize(8)
	for x in _resolution:
		var pos := Vector2(_bounds.position.x + float(x) * _texel.x, y)
		var h := _sampler.get_height(pos)
		var slope := _sampler.get_slope(pos)
		var biome := ctx.get_biome(pos)
		var topo := _topology.get_topology(pos)
		for i in 8:
			weights[i] = 0.0
		var total := 0.0
		for rule in _rules:
			if total >= 0.999:
				break
			if rule.matches(biome, slope, h, topo):
				var contrib := rule.weight * (1.0 - total)
				weights[rule.ground] += contrib
				total += contrib
		if total < 0.999:
			weights[SplatRule.Ground.GRASS] += 1.0 - total
		var off := (row * _resolution + x) * 4
		_px0[off + 0] = int(clampf(weights[SplatRule.Ground.GRASS], 0, 1) * 255.0)
		_px0[off + 1] = int(clampf(weights[SplatRule.Ground.DIRT], 0, 1) * 255.0)
		_px0[off + 2] = int(clampf(weights[SplatRule.Ground.SAND], 0, 1) * 255.0)
		_px0[off + 3] = int(clampf(weights[SplatRule.Ground.ROCK], 0, 1) * 255.0)
		_px1[off + 0] = int(clampf(weights[SplatRule.Ground.SNOW], 0, 1) * 255.0)
		_px1[off + 1] = int(clampf(weights[SplatRule.Ground.FOREST_FLOOR], 0, 1) * 255.0)
		_px1[off + 2] = int(clampf(weights[SplatRule.Ground.GRAVEL], 0, 1) * 255.0)
		_px1[off + 3] = int(clampf(weights[SplatRule.Ground.MUD], 0, 1) * 255.0)
	rows_done += 1


## Pinta un disco de material (plataforma de monumento, F7). Post-build.
func paint_disc(center: Vector2, radius_m: float, ground: SplatRule.Ground) -> void:
	if splat_0 == null:
		return
	var r_tex := int(ceilf(radius_m / _texel.x))
	var cx := int((center.x - _bounds.position.x) / _texel.x)
	var cz := int((center.y - _bounds.position.y) / _texel.y)
	for dz in range(-r_tex, r_tex + 1):
		var z := cz + dz
		if z < 0 or z >= _resolution:
			continue
		for dx in range(-r_tex, r_tex + 1):
			var x := cx + dx
			if x < 0 or x >= _resolution:
				continue
			var d := Vector2(dx * _texel.x, dz * _texel.y).length()
			if d > radius_m:
				continue
			# Borde suave en el 20% exterior del radio.
			var w := 1.0 - smoothstep(radius_m * 0.8, radius_m, d)
			var c0 := splat_0.get_pixel(x, z)
			var c1 := splat_1.get_pixel(x, z)
			var vals := [c0.r, c0.g, c0.b, c0.a, c1.r, c1.g, c1.b, c1.a]
			for i in 8:
				vals[i] = lerpf(vals[i], 1.0 if i == int(ground) else 0.0, w)
			splat_0.set_pixel(x, z, Color(vals[0], vals[1], vals[2], vals[3]))
			splat_1.set_pixel(x, z, Color(vals[4], vals[5], vals[6], vals[7]))


## Material dominante en una posición (para ProceduralSurfaceOverride, F5).
func dominant_material(world_xz: Vector2) -> SplatRule.Ground:
	var u := clampf((world_xz.x - _bounds.position.x) / _bounds.size.x, 0.0, 1.0)
	var v := clampf((world_xz.y - _bounds.position.y) / _bounds.size.y, 0.0, 1.0)
	var x := clampi(int(u * float(_resolution - 1)), 0, _resolution - 1)
	var z := clampi(int(v * float(_resolution - 1)), 0, _resolution - 1)
	var c0 := splat_0.get_pixel(x, z)
	var c1 := splat_1.get_pixel(x, z)
	var vals := [c0.r, c0.g, c0.b, c0.a, c1.r, c1.g, c1.b, c1.a]
	var best := 0
	for i in 8:
		if vals[i] > vals[best]:
			best = i
	return best as SplatRule.Ground
