class_name SeaMask
extends RefCounted

## ============================================================================
## SeaMask · Qué es MAR de verdad (backlog #49, técnica de Rust)
## ============================================================================
## Flood desde el BORDE del mapa sobre celdas con terreno bajo el nivel del
## mar: solo eso es océano. Una depresión interior bajo cota 0 ("montaña
## invertida") NO se conecta → no tiene agua ni se ve el mar dentro.
## La consumen: la mesh del océano (celdas), los colliders (qué chunk no
## necesita física) y quien pregunte is_sea(pos).
## ============================================================================

const CELL := 8.0

var _cells := PackedByteArray()
var _nx: int
var _nz: int
var _bounds: Rect2


func bake(sampler: HeightSampler, sea_level: float) -> void:
	_bounds = sampler.bounds
	_nx = int(ceilf(_bounds.size.x / CELL))
	_nz = int(ceilf(_bounds.size.y / CELL))
	_cells.resize(_nx * _nz)
	_cells.fill(0)
	# BFS desde todo el perímetro del mapa.
	var queue: Array[Vector2i] = []
	var seen := {}
	for x in _nx:
		queue.append(Vector2i(x, 0))
		queue.append(Vector2i(x, _nz - 1))
	for z in _nz:
		queue.append(Vector2i(0, z))
		queue.append(Vector2i(_nx - 1, z))
	for c in queue:
		seen[c] = true
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		var center := _bounds.position + Vector2((c.x + 0.5) * CELL, (c.y + 0.5) * CELL)
		if sampler.get_height(center) >= sea_level + 0.2:
			continue  # tierra: el mar no pasa
		_cells[c.y * _nx + c.x] = 1
		for off: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n := c + off
			if n.x < 0 or n.x >= _nx or n.y < 0 or n.y >= _nz or seen.has(n):
				continue
			seen[n] = true
			queue.push_back(n)


func is_sea(world_xz: Vector2) -> bool:
	if _cells.is_empty():
		return false
	var x := clampi(int((world_xz.x - _bounds.position.x) / CELL), 0, _nx - 1)
	var z := clampi(int((world_xz.y - _bounds.position.y) / CELL), 0, _nz - 1)
	return _cells[z * _nx + x] == 1


## Rectángulos world-space que cubren EXACTAMENTE las celdas de mar (greedy:
## corridas por fila + fusión vertical de corridas idénticas). Los consume el
## volumen de nado del océano — una caja global cubría TODO el mapa hasta
## cota 0 y el jugador "nadaba" en tierra seca bajo el nivel del mar
## (depresiones interiores): el reporte "traspaso el suelo, caigo al agua".
func sea_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	if _cells.is_empty():
		return out
	# 1. Corridas horizontales por fila: [z, x0, x1)
	var open := {}   # Vector2i(x0, x1) → índice en out del rect abierto
	for z in _nz:
		var next_open := {}
		var x := 0
		while x < _nx:
			if _cells[z * _nx + x] == 0:
				x += 1
				continue
			var x0 := x
			while x < _nx and _cells[z * _nx + x] == 1:
				x += 1
			var run := Vector2i(x0, x)
			# 2. Fusión vertical: misma corrida en la fila anterior → estirar.
			if open.has(run):
				var idx: int = open[run]
				out[idx].size.y += CELL
				next_open[run] = idx
			else:
				out.append(Rect2(
						_bounds.position + Vector2(x0 * CELL, z * CELL),
						Vector2((x - x0) * CELL, CELL)))
				next_open[run] = out.size() - 1
		open = next_open
	return out


## Malla del océano en DOS NIVELES (§F8, técnica Crest adaptada a malla estática):
## · CERCA de la costa (≤ NEAR_CELLS celdas de tierra): quad por celda de 8 m —
##   las olas Gerstner del shader (λ=22 m) se muestrean con detalle pleno donde
##   el jugador las ve de cerca.
## · MAR ADENTRO: bloques de 4×4 celdas = UN quad de 32 m (1/16 de vértices) —
##   a esa distancia el detalle de ola no se percibe.
## · FALDONES anti-grieta en las costuras nivel-fino↔grueso (misma técnica que
##   los chunks del terreno): el T-junction desplazado por Gerstner muestra
##   faldón oscuro, nunca un agujero.
## Vértices en posiciones mundiales → olas continuas entre niveles.
## ALINEADO con wave_fade_end del shader (140 m): todo vértice con ola
## geométrica visible desde la costa cae en el nivel FINO; en la costura
## fino↔grueso la amplitud ya es ~0 → grieta ~0 (el faldón es un seguro).
## Barco mar adentro = olas facetadas 32 m: lo resuelve el parche de malla
## que sigue a la cámara (clipmap fase 2, ver §F8 del plan).
const NEAR_CELLS := 18     # celdas (144 m) de detalle pleno desde la costa
const FAR_BLOCK := 4       # bloque grueso = 4×4 celdas (32 m)
const SKIRT_M := 0.8       # caída del faldón (seguro anti-grieta residual)


func build_ocean_mesh(sea_level: float, material: Material) -> MeshInstance3D:
	# Distancia a tierra por celda (BFS multi-fuente desde toda celda no-mar).
	var n := _nx * _nz
	var dist := PackedInt32Array()
	dist.resize(n)
	dist.fill(-1)
	var queue := PackedInt32Array()
	for i in n:
		if _cells[i] == 0:
			dist[i] = 0
			queue.append(i)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		var cx := c % _nx
		var cz := int(c / float(_nx))
		for off: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx2 := cx + off.x
			var nz2 := cz + off.y
			if nx2 < 0 or nx2 >= _nx or nz2 < 0 or nz2 >= _nz:
				continue
			var ni := nz2 * _nx + nx2
			if dist[ni] >= 0:
				continue
			dist[ni] = dist[c] + 1
			queue.append(ni)

	# Bloques gruesos: 4×4 celdas TODAS mar y TODAS lejos de la costa.
	var bx := int(ceilf(float(_nx) / FAR_BLOCK))
	var bz := int(ceilf(float(_nz) / FAR_BLOCK))
	var far_block := PackedByteArray()
	far_block.resize(bx * bz)
	for j in bz:
		for i in bx:
			var all_far := true
			for dz in FAR_BLOCK:
				for dx in FAR_BLOCK:
					var x := i * FAR_BLOCK + dx
					var z := j * FAR_BLOCK + dz
					if x >= _nx or z >= _nz:
						all_far = false
						break
					var ci := z * _nx + x
					if _cells[ci] == 0 or dist[ci] <= NEAR_CELLS:
						all_far = false
						break
				if not all_far:
					break
			if all_far:
				far_block[j * bx + i] = 1

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(material)
	var near_quads := 0
	var far_quads := 0
	var skirts := 0

	# ---- Nivel FINO: celdas de 8 m (mar cercano + margen costero) ----
	for z in _nz:
		for x in _nx:
			# Celda cubierta por un bloque grueso → la dibuja el nivel grueso.
			if far_block[int(z / float(FAR_BLOCK)) * bx + int(x / float(FAR_BLOCK))] == 1:
				continue
			var sea := _cells[z * _nx + x] == 1
			if not sea:
				# Margen: celda de tierra vecina a mar (el agua llega a la playa).
				var near := false
				for off: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx2 := x + off.x
					var nz2 := z + off.y
					if nx2 >= 0 and nx2 < _nx and nz2 >= 0 and nz2 < _nz \
							and _cells[nz2 * _nx + nx2] == 1:
						near = true
						break
				if not near:
					continue
			_emit_quad(st, _bounds.position.x + x * CELL,
					_bounds.position.y + z * CELL, CELL, sea_level)
			near_quads += 1

	# ---- Nivel GRUESO: bloques de 32 m + faldones hacia vecinos finos ----
	var block_m := CELL * FAR_BLOCK
	for j in bz:
		for i in bx:
			if far_block[j * bx + i] == 0:
				continue
			var x0 := _bounds.position.x + i * block_m
			var z0 := _bounds.position.y + j * block_m
			_emit_quad(st, x0, z0, block_m, sea_level)
			far_quads += 1
			# Faldón por borde que toca zona NO-gruesa (costura fino↔grueso).
			for e: Array in [[Vector2i(0, -1), Vector3(x0, 0, z0), Vector3(x0 + block_m, 0, z0)],
					[Vector2i(0, 1), Vector3(x0 + block_m, 0, z0 + block_m), Vector3(x0, 0, z0 + block_m)],
					[Vector2i(-1, 0), Vector3(x0, 0, z0 + block_m), Vector3(x0, 0, z0)],
					[Vector2i(1, 0), Vector3(x0 + block_m, 0, z0), Vector3(x0 + block_m, 0, z0 + block_m)]]:
				var nb: Vector2i = Vector2i(i, j) + (e[0] as Vector2i)
				var nb_far := nb.x >= 0 and nb.x < bx and nb.y >= 0 and nb.y < bz \
						and far_block[nb.y * bx + nb.x] == 1
				if nb_far:
					continue
				_emit_skirt(st, e[1], e[2], sea_level)
				skirts += 1

	st.index()
	var mi := MeshInstance3D.new()
	mi.name = "OceanPlane"  # nombre estable (tests/lógica existente)
	mi.mesh = st.commit()
	mi.extra_cull_margin = 4.0
	if OS.is_debug_build():
		print("SeaMask: océano 2 niveles — %d quads finos + %d gruesos + %d faldones (antes: %d finos)"
				% [near_quads, far_quads, skirts, near_quads + far_quads * FAR_BLOCK * FAR_BLOCK])
	return mi


## Quad horizontal (2 tris) en (x0,z0)..(x0+s,z0+s) a la cota dada.
static func _emit_quad(st: SurfaceTool, x0: float, z0: float, s: float, y: float) -> void:
	for v: Vector3 in [
			Vector3(x0, y, z0), Vector3(x0 + s, y, z0), Vector3(x0, y, z0 + s),
			Vector3(x0 + s, y, z0), Vector3(x0 + s, y, z0 + s), Vector3(x0, y, z0 + s)]:
		st.set_uv(Vector2(v.x, v.z) * 0.01)
		st.set_normal(Vector3.UP)
		st.add_vertex(v)


## Faldón vertical colgando SKIRT_M del borde a→b (tapa la grieta del T-junction
## cuando la ola desplaza distinto los vértices finos y los gruesos).
static func _emit_skirt(st: SurfaceTool, a: Vector3, b: Vector3, y: float) -> void:
	var a_top := Vector3(a.x, y, a.z)
	var b_top := Vector3(b.x, y, b.z)
	var a_bot := Vector3(a.x, y - SKIRT_M, a.z)
	var b_bot := Vector3(b.x, y - SKIRT_M, b.z)
	for v: Vector3 in [a_top, b_top, a_bot, b_top, b_bot, a_bot]:
		st.set_uv(Vector2(v.x, v.z) * 0.01)
		st.set_normal(Vector3.UP)
		st.add_vertex(v)
