class_name TopologyMap
extends RefCounted

## ============================================================================
## TopologyMap · Bitmask geográfico por texel (PROCEDURAL_MAP_PLAN.md §5.3)
## ============================================================================
## Responde "¿qué ES este lugar?" — el índice que consulta todo el placement.
## F2 bakea el pase hidrológico + bandas de caminos; F6/F7 completan flags
## (FIELD/FOREST/SUMMIT/MONUMENT...) con bake_full() y stamp().
## ============================================================================

enum {
	TOPO_OCEAN      = 1 << 0,
	TOPO_OCEANSIDE  = 1 << 1,
	TOPO_BEACH      = 1 << 2,
	TOPO_BEACHSIDE  = 1 << 3,
	TOPO_LAKE       = 1 << 4,
	TOPO_LAKESIDE   = 1 << 5,
	TOPO_RIVER      = 1 << 6,
	TOPO_RIVERSIDE  = 1 << 7,
	TOPO_SWAMP      = 1 << 8,
	TOPO_CLIFF      = 1 << 9,
	TOPO_CLIFFSIDE  = 1 << 10,
	TOPO_SUMMIT     = 1 << 11,
	TOPO_HILLTOP    = 1 << 12,
	TOPO_FIELD      = 1 << 13,
	TOPO_FOREST     = 1 << 14,
	TOPO_FORESTSIDE = 1 << 15,
	TOPO_ROAD       = 1 << 16,
	TOPO_ROADSIDE   = 1 << 17,
	TOPO_MONUMENT   = 1 << 18,
	TOPO_DECOR      = 1 << 19,
	TOPO_MAINLAND   = 1 << 20,
	TOPO_RAIL       = 1 << 21,
	TOPO_RAILSIDE   = 1 << 22,
}

var rows_done: int = 0
var rows_total: int = 1
var _bits := PackedInt32Array()
var _resolution: int = 0
var _bounds := Rect2()
var _texel := Vector2.ONE


func get_resolution() -> int:
	return _resolution


func _index_of(world_xz: Vector2) -> int:
	var x := clampi(int((world_xz.x - _bounds.position.x) / _texel.x), 0, _resolution - 1)
	var z := clampi(int((world_xz.y - _bounds.position.y) / _texel.y), 0, _resolution - 1)
	return z * _resolution + x


func get_topology(world_xz: Vector2) -> int:
	if _resolution == 0:
		return 0
	return _bits[_index_of(world_xz)]


func has_all(world_xz: Vector2, mask: int) -> bool:
	return (get_topology(world_xz) & mask) == mask


func has_any(world_xz: Vector2, mask: int) -> bool:
	return (get_topology(world_xz) & mask) != 0


## Pase hidrológico + bandas de caminos: OCEAN/OCEANSIDE/BEACH/LAKE/LAKESIDE/
## RIVER/RIVERSIDE/ROAD/ROADSIDE/CLIFF. Suficiente para el splat (F2).
func bake_hydro(sampler: HeightSampler, provider: MapDataProvider, sea_level: float,
		river_layers: Array[HeightLayer], road_layers: Array[HeightLayer],
		resolution: int, side_width_m: float,
		frame_yield: Callable = Callable()) -> void:
	_resolution = resolution
	_bounds = sampler.bounds
	_texel = Vector2(_bounds.size.x / float(resolution - 1),
			_bounds.size.y / float(resolution - 1))
	_bits.resize(resolution * resolution)
	_bits.fill(0)
	rows_total = resolution
	rows_done = 0
	_bake_ctx = {"sampler": sampler, "provider": provider, "sea": sea_level}
	var task := WorkerThreadPool.add_group_task(_bake_hydro_row, resolution, TerrainSettings.worker_count(), false,
			"TopologyMap.bake_hydro")
	if frame_yield.is_valid():
		while not WorkerThreadPool.is_group_task_completed(task):
			await frame_yield.call()
	WorkerThreadPool.wait_for_group_task_completion(task)
	_bake_ctx = {}
	for l in river_layers:
		var pl := l as PathCarveLayer
		if pl != null:
			stamp_polyline(pl.points, pl.width_m * 0.5 + pl.falloff_m * 0.5, TOPO_RIVER)
			stamp_polyline(pl.points, pl.width_m * 0.5 + pl.falloff_m + side_width_m,
					TOPO_RIVERSIDE)
	for l in road_layers:
		var pl := l as PathCarveLayer
		if pl != null:
			stamp_polyline(pl.points, pl.width_m * 0.5, TOPO_ROAD)
			stamp_polyline(pl.points, pl.width_m * 0.5 + side_width_m, TOPO_ROADSIDE)
	# MAINLAND ya es computable acá (tierra = !OCEAN/!LAKE) y lo necesita el
	# plan de monumentos, que corre ANTES de bake_full.
	_mark_mainland()


var _bake_ctx: Dictionary = {}


func _bake_hydro_row(row: int) -> void:
	var sampler: HeightSampler = _bake_ctx.sampler
	var sea: float = _bake_ctx.sea
	var ctx := sampler.make_context()
	var y := _bounds.position.y + float(row) * _texel.y
	var base := row * _resolution
	for x in _resolution:
		var pos := Vector2(_bounds.position.x + float(x) * _texel.x, y)
		var h := sampler.get_height(pos)
		var bits := 0
		if h < sea:
			var c := ctx.get_center(pos)
			if c.water and not c.ocean:
				bits |= TOPO_LAKE
			else:
				bits |= TOPO_OCEAN
				if h > sea - 2.0:
					bits |= TOPO_OCEANSIDE
		else:
			var c2 := ctx.get_center(pos)
			if h < sea + 3.0 and (c2.coast or c2.biome == "BEACH"):
				bits |= TOPO_BEACH
			if c2.water and not c2.ocean:
				bits |= TOPO_LAKE  # lago con lecho sobre sea_level (tallado aparte)
			elif not c2.water:
				for n in c2.neighbors:
					var nc := n as Center
					if nc.water and not nc.ocean:
						bits |= TOPO_LAKESIDE
						break
			if sampler.get_slope(pos) > 0.55:
				bits |= TOPO_CLIFF
		_bits[base + x] = bits
	rows_done += 1


## Pase completo (F6): FIELD/FOREST/SUMMIT/HILLTOP/SWAMP/MAINLAND/DECOR +
## bandas *_SIDE por dilatación. Corre DESPUÉS de bake_hydro.
func bake_full(sampler: HeightSampler, _provider: MapDataProvider,
		sea_level: float, side_width_m: float,
		frame_yield: Callable = Callable()) -> void:
	var forest_biomes := ["TAIGA", "TEMPERATE_RAIN_FOREST",
			"TEMPERATE_DECIDUOUS_FOREST", "TROPICAL_RAIN_FOREST",
			"TROPICAL_SEASONAL_FOREST"]
	# Percentil 92 de altura en tierra (SUMMIT).
	var land_heights: Array[float] = []
	var ctx := sampler.make_context()
	for z in range(0, _resolution, 4):
		for x in range(0, _resolution, 4):
			var p := _bounds.position + Vector2(float(x) * _texel.x, float(z) * _texel.y)
			var h := sampler.get_height(p)
			if h > sea_level:
				land_heights.append(h)
	land_heights.sort()
	var summit_h := land_heights[int(land_heights.size() * 0.92)] \
			if land_heights.size() > 10 else INF

	var hill_r := maxi(int(32.0 / _texel.x), 4)  # ventana HILLTOP ~64 m
	for z in _resolution:
		if frame_yield.is_valid() and z % 24 == 0:
			await frame_yield.call()
		var y := _bounds.position.y + float(z) * _texel.y
		for x in _resolution:
			var i := z * _resolution + x
			var bits := _bits[i]
			if bits & (TOPO_OCEAN | TOPO_LAKE):
				continue
			var pos := Vector2(_bounds.position.x + float(x) * _texel.x, y)
			var h := sampler.get_height(pos)
			var slope := sampler.get_slope(pos)
			var c := ctx.get_center(pos)
			if forest_biomes.has(c.biome):
				bits |= TOPO_FOREST
			elif slope < 0.15 and not (bits & (TOPO_BEACH | TOPO_ROAD | TOPO_RIVER)):
				bits |= TOPO_FIELD
			if c.biome == "MARSH":
				bits |= TOPO_SWAMP
			if h >= summit_h:
				bits |= TOPO_SUMMIT
				# HILLTOP: máximo local (comparación en cruz a ~hill_r texels).
				var is_top := true
				for off: Vector2i in [Vector2i(hill_r, 0), Vector2i(-hill_r, 0),
						Vector2i(0, hill_r), Vector2i(0, -hill_r)]:
					var nx := clampi(x + off.x, 0, _resolution - 1)
					var nz := clampi(z + off.y, 0, _resolution - 1)
					var np := Vector2(_bounds.position.x + float(nx) * _texel.x,
							_bounds.position.y + float(nz) * _texel.y)
					if sampler.get_height(np) > h:
						is_top = false
						break
				if is_top:
					bits |= TOPO_HILLTOP
			_bits[i] = bits
	_dilate(TOPO_BEACH, TOPO_BEACHSIDE, side_width_m)
	_dilate(TOPO_CLIFF, TOPO_CLIFFSIDE, side_width_m)
	_dilate(TOPO_FOREST, TOPO_FORESTSIDE, side_width_m)
	# DECOR: tierra apta para clutter.
	for i in _bits.size():
		var bt := _bits[i]
		if not (bt & (TOPO_OCEAN | TOPO_LAKE | TOPO_RIVER | TOPO_ROAD
				| TOPO_CLIFF | TOPO_MONUMENT)):
			_bits[i] = bt | TOPO_DECOR


## Dilatación morfológica separable: dst = vecindad(src) − src.
func _dilate(src_flag: int, dst_flag: int, radius_m: float) -> void:
	var r := maxi(int(radius_m / _texel.x), 1)
	var tmp := PackedByteArray()
	tmp.resize(_bits.size())
	for z in _resolution:
		var base := z * _resolution
		for x in _resolution:
			if _bits[base + x] & src_flag:
				for dx in range(maxi(x - r, 0), mini(x + r + 1, _resolution)):
					tmp[base + dx] = 1
	for z in _resolution:
		for x in _resolution:
			if tmp[z * _resolution + x] == 1:
				for dz in range(maxi(z - r, 0), mini(z + r + 1, _resolution)):
					var i := dz * _resolution + x
					if not (_bits[i] & src_flag):
						_bits[i] |= dst_flag


## MAINLAND: componente conexo de tierra más grande (BFS).
func _mark_mainland() -> void:
	var labels := PackedInt32Array()
	labels.resize(_bits.size())
	labels.fill(-1)
	var best_label := -1
	var best_size := 0
	var next_label := 0
	for start in _bits.size():
		if labels[start] != -1 or (_bits[start] & (TOPO_OCEAN | TOPO_LAKE)):
			continue
		var stack := [start]
		labels[start] = next_label
		var count := 0
		while not stack.is_empty():
			var i: int = stack.pop_back()
			count += 1
			var x := i % _resolution
			var z := floori(float(i) / float(_resolution))   # fila de la celda (division entera intencional)
			for off: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx := x + off.x
				var nz := z + off.y
				if nx < 0 or nx >= _resolution or nz < 0 or nz >= _resolution:
					continue
				var ni := nz * _resolution + nx
				if labels[ni] == -1 and not (_bits[ni] & (TOPO_OCEAN | TOPO_LAKE)):
					labels[ni] = next_label
					stack.push_back(ni)
		if count > best_size:
			best_size = count
			best_label = next_label
		next_label += 1
	for i in _bits.size():
		if labels[i] == best_label:
			_bits[i] |= TOPO_MAINLAND


## Posiciones que cumplen las máscaras, deterministas, con separación mínima.
## min_spacing_m <= 0 ⇒ sin chequeo de separación (densidades altas tipo pasto:
## el chequeo lineal sería O(n²) y el random puro es lo correcto ahí).
func find_positions(all_mask: int, any_mask: int, not_mask: int,
		max_count: int, min_spacing_m: float,
		rng: RandomNumberGenerator) -> PackedVector2Array:
	var out := PackedVector2Array()
	var check_spacing := min_spacing_m > 0.0
	var attempts := max_count * (60 if check_spacing else 10)
	while out.size() < max_count and attempts > 0:
		attempts -= 1
		var pos := _bounds.position + Vector2(rng.randf() * _bounds.size.x,
				rng.randf() * _bounds.size.y)
		var bits := get_topology(pos)
		if all_mask != 0 and (bits & all_mask) != all_mask:
			continue
		if any_mask != 0 and (bits & any_mask) == 0:
			continue
		if not_mask != 0 and (bits & not_mask) != 0:
			continue
		if check_spacing:
			var ok := true
			for p in out:
				if p.distance_to(pos) < min_spacing_m:
					ok = false
					break
			if not ok:
				continue
		out.append(pos)
	return out


## Marca un flag en todos los texels a menos de radius_m de la polilínea.
func stamp_polyline(points: PackedVector2Array, radius_m: float, flag: int) -> void:
	if points.size() < 2 or _resolution == 0:
		return
	var step := minf(_texel.x, _texel.y) * 0.5
	var r_tex_x := int(ceilf(radius_m / _texel.x))
	var r_tex_z := int(ceilf(radius_m / _texel.y))
	for i in points.size() - 1:
		var a := points[i]
		var b := points[i + 1]
		var seg_len := a.distance_to(b)
		var n := maxi(int(ceilf(seg_len / step)), 1)
		for j in n + 1:
			var p := a.lerp(b, float(j) / float(n))
			var cx := int((p.x - _bounds.position.x) / _texel.x)
			var cz := int((p.y - _bounds.position.y) / _texel.y)
			for dz in range(-r_tex_z, r_tex_z + 1):
				var z := cz + dz
				if z < 0 or z >= _resolution:
					continue
				for dx in range(-r_tex_x, r_tex_x + 1):
					var xx := cx + dx
					if xx < 0 or xx >= _resolution:
						continue
					var tex_pos := _bounds.position + Vector2(float(xx) * _texel.x, float(z) * _texel.y)
					if tex_pos.distance_to(p) <= radius_m:
						_bits[z * _resolution + xx] |= flag


## Marca un flag en un disco (monumentos, F7).
func stamp_disc(center: Vector2, radius_m: float, flag: int) -> void:
	stamp_polyline(PackedVector2Array([center, center + Vector2(0.01, 0)]), radius_m, flag)


## Overlay coloreado para debug (§14.4).
func bake_debug_image() -> Image:
	var img := Image.create_empty(_resolution, _resolution, false, Image.FORMAT_RGBA8)
	for z in _resolution:
		for x in _resolution:
			var b := _bits[z * _resolution + x]
			var col := Color(0, 0, 0, 0)
			if b & TOPO_OCEAN:
				col = Color(0.1, 0.2, 0.6, 0.8)
			elif b & TOPO_LAKE:
				col = Color(0.2, 0.5, 0.8, 0.8)
			elif b & TOPO_ROAD:
				col = Color(0.4, 0.4, 0.4, 0.9)
			elif b & TOPO_RIVER:
				col = Color(0.3, 0.7, 1.0, 0.9)
			elif b & TOPO_BEACH:
				col = Color(0.9, 0.85, 0.5, 0.8)
			elif b & TOPO_CLIFF:
				col = Color(0.6, 0.3, 0.2, 0.8)
			elif b & TOPO_LAKESIDE or b & TOPO_RIVERSIDE:
				col = Color(0.4, 0.6, 0.5, 0.6)
			img.set_pixel(x, z, col)
	return img
