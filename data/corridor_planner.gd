class_name CorridorPlanner
extends RefCounted

## ============================================================================
## CorridorPlanner · Anillo costero por contorno + corredor único (§F3)
## ============================================================================
## Plantilla "ring road" estilo Rust sobre el heightfield raster:
##   1. Máscara tierra/mar del campo base.
##   2. Distancia a mar por BFS multi-fuente (celdas).
##   3. Erosión: máscara interior dist ≥ inset → componente conexo mayor.
##   4. Traza de borde (Moore) → anillo CERRADO, ordenado, sin
##      auto-intersecciones — gratis, sin offset analítico de polígono.
## El suavizado (Chaikin/relax/resample) lo hace MapDataProvider._smooth_route
## (mismo camino que el circuito actual). Carretera y vía = offsets laterales
## del MISMO spine → el terreno se esculpe UNA vez (corredor completo).
## Determinista: puro respecto al heightfield de entrada.
## ============================================================================

const _DX8: Array[int] = [1, 1, 0, -1, -1, -1, 0, 1]
const _DZ8: Array[int] = [0, 1, 1, 1, 0, -1, -1, -1]


## Anillo interior de la isla a `inset_m` metros de la costa (world-space,
## SIN suavizar — polilínea cerrada de celdas de borde). Vacío si no hay isla.
static func coast_ring(heights: PackedFloat32Array, res: int, bounds: Rect2,
		sea_level: float, inset_m: float) -> PackedVector2Array:
	var texel := bounds.size.x / float(res - 1)
	var inset_cells := maxi(1, int(roundf(inset_m / texel)))
	var n := res * res

	# 1-2. Distancia a mar (BFS 8-conex desde toda celda de agua/borde).
	var dist := PackedInt32Array()
	dist.resize(n)
	dist.fill(-1)
	var queue := PackedInt32Array()
	for i in n:
		var border := (i % res == 0 or i % res == res - 1
				or i < res or i >= n - res)
		if heights[i] <= sea_level or border:
			dist[i] = 0
			queue.append(i)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		var cx := c % res
		var cz := int(c / float(res))
		for k in 8:
			var nx := cx + _DX8[k]
			var nz := cz + _DZ8[k]
			if nx < 0 or nz < 0 or nx >= res or nz >= res:
				continue
			var ni := nz * res + nx
			if dist[ni] >= 0:
				continue
			dist[ni] = dist[c] + 1
			queue.append(ni)

	# 3. Máscara interior + componente conexo mayor.
	var mask := PackedByteArray()
	mask.resize(n)
	for i in n:
		if dist[i] >= inset_cells:
			mask[i] = 1
	var comp := _largest_component(mask, res)
	if comp.is_empty():
		return PackedVector2Array()

	# 4. Traza de borde Moore sobre el componente.
	var ring_cells := _moore_trace(comp, res)
	var out := PackedVector2Array()
	for ci in range(0, ring_cells.size(), 2):  # 1 de cada 2 celdas alcanza
		var c := ring_cells[ci]
		out.append(bounds.position + Vector2(float(c % res) * texel,
				float(int(c / float(res))) * texel))
	return out


## Offset lateral de una polilínea (normal por vértice). closed: envuelve.
static func offset_polyline(pts: PackedVector2Array, offset_m: float,
		closed: bool) -> PackedVector2Array:
	var n := pts.size()
	if n < 2 or absf(offset_m) < 0.001:
		return pts.duplicate()
	# Anillo con punto de cierre duplicado: trabajar sin él y re-cerrar.
	var wrapped := closed and pts[0].distance_to(pts[n - 1]) < 0.01
	var m := n - 1 if wrapped else n
	var out := PackedVector2Array()
	for i in m:
		var prev := pts[(i - 1 + m) % m] if closed else pts[maxi(i - 1, 0)]
		var next := pts[(i + 1) % m] if closed else pts[mini(i + 1, m - 1)]
		var dir := (next - prev).normalized()
		var normal := Vector2(-dir.y, dir.x)
		out.append(pts[i] + normal * offset_m)
	if wrapped:
		out.append(out[0])
	return out


## Componente conexo (8) más grande de una máscara binaria. Devuelve máscara.
static func _largest_component(mask: PackedByteArray, res: int) -> PackedByteArray:
	var n := res * res
	var seen := PackedByteArray()
	seen.resize(n)
	var best := PackedInt32Array()
	for i in n:
		if mask[i] == 0 or seen[i] == 1:
			continue
		var comp := PackedInt32Array([i])
		seen[i] = 1
		var head := 0
		while head < comp.size():
			var c := comp[head]
			head += 1
			var cx := c % res
			var cz := int(c / float(res))
			for k in 8:
				var nx := cx + _DX8[k]
				var nz := cz + _DZ8[k]
				if nx < 0 or nz < 0 or nx >= res or nz >= res:
					continue
				var ni := nz * res + nx
				if mask[ni] == 0 or seen[ni] == 1:
					continue
				seen[ni] = 1
				comp.append(ni)
		if comp.size() > best.size():
			best = comp
	var out := PackedByteArray()
	out.resize(n)
	for c in best:
		out[c] = 1
	return out


## Moore-neighbor tracing: recorre el borde EXTERIOR de la máscara en orden.
## Devuelve celdas del borde (índices) formando un lazo cerrado.
static func _moore_trace(mask: PackedByteArray, res: int) -> PackedInt32Array:
	var n := res * res
	# Celda inicial: primera celda de la máscara en orden de barrido.
	var start := -1
	for i in n:
		if mask[i] == 1:
			start = i
			break
	var out := PackedInt32Array()
	if start < 0:
		return out
	out.append(start)
	# Dirección de backtrack inicial: venimos de la izquierda (oeste = índice 4).
	var cur := start
	var back := 4
	var guard := 0
	var guard_max := n * 4
	while guard < guard_max:
		guard += 1
		# Escanear los 8 vecinos en sentido horario desde el backtrack+1.
		var found := false
		for s in 8:
			var k := (back + 1 + s) % 8
			var cx := cur % res
			var cz := int(cur / float(res))
			var nx := cx + _DX8[k]
			var nz := cz + _DZ8[k]
			if nx < 0 or nz < 0 or nx >= res or nz >= res:
				continue
			var ni := nz * res + nx
			if mask[ni] == 1:
				# backtrack nuevo: dirección opuesta al paso que acabamos de dar.
				back = (k + 4) % 8
				cur = ni
				found = true
				break
		if not found:
			break  # celda aislada
		if cur == start and out.size() > 2:
			break  # lazo cerrado
		out.append(cur)
	return out


## Offset VARIABLE a lo largo del trazado: el desplazamiento oscila y CRUZA EL
## CERO, así que la carretera y la vía INTERCAMBIAN de lado (una pasa del lado de
## la costa al del centro y viceversa). Donde el offset vale ~0 las dos se juntan:
## ese es el punto de CRUCE natural, sin tener que buscarlo aparte.
##
##   swaps      = cuántas veces se intercambian en toda la vuelta
##   min_frac   = separación mínima en el cruce (0 = se tocan; 0.15 deja luz)
## Devuelve el offset por punto; se usa con `offset_polyline_varying`.
static func swap_offsets(count: int, half_m: float, swaps: int,
		min_frac: float = 0.12) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count)
	var n := maxf(float(count), 1.0)
	for i in count:
		# Onda suave con `swaps` cruces por vuelta. El signo es lo que hace el
		# intercambio; el |valor| nunca baja de min_frac para que en el cruce las
		# dos calzadas no queden exactamente encimadas.
		var t := float(i) / n * TAU * maxf(float(swaps), 1.0) * 0.5
		var w := sin(t)
		var mag := lerpf(min_frac, 1.0, absf(w))
		out[i] = half_m * mag * signf(w if absf(w) > 0.0001 else 1.0)
	return out


## Igual que offset_polyline pero con un offset DISTINTO por punto (ver swap_offsets).
static func offset_polyline_varying(pts: PackedVector2Array,
		offsets: PackedFloat32Array, closed: bool) -> PackedVector2Array:
	var n := pts.size()
	if n < 2 or offsets.size() < n:
		return pts.duplicate()
	var wrapped := closed and pts[0].distance_to(pts[n - 1]) < 0.01
	var m := n - 1 if wrapped else n
	var out := PackedVector2Array()
	for i in m:
		var prev := pts[(i - 1 + m) % m] if closed else pts[maxi(i - 1, 0)]
		var next := pts[(i + 1) % m] if closed else pts[mini(i + 1, m - 1)]
		var dir := (next - prev).normalized()
		var normal := Vector2(-dir.y, dir.x)
		out.append(pts[i] + normal * offsets[i])
	if wrapped:
		out.append(out[0])
	return out


## RAMAL: un camino que SALE del circuito en un punto y RECONECTA en otro, metiendose
## hacia el centro de la isla. Es lo que le da sentido a la red — sin ramales, el
## anillo es una pista cerrada y nada lleva al interior.
##
##   spine        el anillo (cerrado)
##   from_i/to_i  indices del anillo donde nace y donde vuelve
##   center       centro de la isla (hacia donde se mete el ramal)
##   bulge        0..1 — cuanto se adentra respecto a la distancia al centro
##   samples      resolucion de la curva
##
## La curva es una Bezier cuadratica cuyo punto de control se empuja hacia el centro:
## nace y muere TANGENTE al anillo (sin codos), que es la condicion para que un
## vehiculo pueda tomarla.
static func branch_route(spine: PackedVector2Array, from_i: int, to_i: int,
		center: Vector2, bulge: float = 0.45,
		samples: int = 24) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := spine.size()
	if n < 8 or samples < 3:
		return out
	var a := spine[posmod(from_i, n)]
	var b := spine[posmod(to_i, n)]
	# Punto de control: el medio del segmento, corrido hacia el centro de la isla.
	var mid := (a + b) * 0.5
	var ctrl := mid.lerp(center, clampf(bulge, 0.0, 0.95))
	for i in samples + 1:
		var t := float(i) / float(samples)
		var u := 1.0 - t
		out.append(a * (u * u) + ctrl * (2.0 * u * t) + b * (t * t))
	return out


## Reparte `count` ramales por el anillo sin que se pisen: cada uno nace y muere en
## tramos distintos, y se alternan los que se meten poco y mucho (variedad de
## recorrido en vez de N curvas iguales).
static func plan_branches(spine: PackedVector2Array, center: Vector2, count: int,
		span_frac: float = 0.18, seed_val: int = 0) -> Array:
	var out: Array = []
	var n := spine.size()
	if n < 16 or count <= 0:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var span := maxi(int(float(n) * span_frac), 4)
	var step := n / count
	for k in count:
		var from_i := k * step + rng.randi_range(0, maxi(step - span - 1, 0))
		var to_i := from_i + span + rng.randi_range(0, span / 2)
		# Alternar cuanto se adentran: unos rozan el interior, otros lo cruzan.
		var bulge := 0.3 + 0.35 * float(k % 2) + rng.randf() * 0.12
		var pts := branch_route(spine, from_i, to_i, center, bulge)
		if pts.size() > 3:
			out.append(pts)
	return out
