class_name Hydrology
extends RefCounted

## ============================================================================
## Hydrology · Hidrología raster canónica (TERRAIN_PIPELINE_V2_PLAN §F4)
## ============================================================================
## Pipeline GIS estándar sobre un heightfield res×res (index = z*res + x):
##   1. Priority-Flood + epsilon (Barnes 2014): rellena TODA depresión dejando
##      gradiente estrictamente descendente hacia el borde ⇒ ningún descenso
##      puede estancarse. O(N log N).
##   2. D8: cada celda apunta al vecino (8-conex) de máxima bajada.
##   3. Acumulación de flujo en orden de elevación descendente.
##   4. Trazado de ríos: celdas con acc ≥ umbral, siguiendo D8 hasta el mar;
##      al tocar una celda reclamada por otro río se corta ahí (confluencia —
##      el empalme fino lo hace MapDataProvider con su lógica existente).
## Todo determinista y puro: mismo heightfield ⇒ mismos ríos.
## ============================================================================

const _DX: Array[int] = [-1, 0, 1, -1, 1, -1, 0, 1]
const _DZ: Array[int] = [-1, -1, -1, 0, 0, 1, 1, 1]


## Conveniencia: flood → D8+acumulación → trazas. Devuelve
## {rivers: Array[PackedVector2Array], filled, sink, down, acc}.
static func run(h: PackedFloat32Array, res: int, bounds: Rect2, sea_level: float,
		max_rivers: int, acc_threshold: float = -1.0) -> Dictionary:
	var pf := priority_flood(h, res)
	var fa := flow_and_accumulation(pf.filled, res, pf.order)
	if acc_threshold <= 0.0:
		# Umbral por área de tierra: ~0.4% del área drenada mínima por río.
		var land := 0
		var filled: PackedFloat32Array = pf.filled
		for v in filled:
			if v > sea_level:
				land += 1
		acc_threshold = maxf(24.0, float(land) * 0.004)
	var rivers := trace_rivers(pf.filled, fa.down, fa.acc, res, bounds,
			sea_level, acc_threshold, max_rivers)
	return {
		"rivers": rivers,
		"filled": pf.filled,
		"sink": pf.sink,
		"down": fa.down,
		"acc": fa.acc,
	}


## Priority-Flood + epsilon (Barnes, Lehman, Mulla 2014).
## Devuelve {filled: PackedFloat32Array, order: PackedInt32Array (celdas en
## orden de elevación creciente), sink: PackedByteArray (1 = depresión rellenada)}.
static func priority_flood(h: PackedFloat32Array, res: int,
		epsilon: float = 0.0005) -> Dictionary:
	var n := res * res
	var filled := h.duplicate()
	var closed := PackedByteArray()
	closed.resize(n)
	var sink := PackedByteArray()
	sink.resize(n)
	var order := PackedInt32Array()
	# Min-heap binario (prio paralelo a cell).
	var hp := PackedFloat32Array()
	var hc := PackedInt32Array()
	# Semillas: todo el borde del mapa (el mar conecta al borde por diseño).
	for x in res:
		_push(hp, hc, filled[x], x, closed)
		_push(hp, hc, filled[(res - 1) * res + x], (res - 1) * res + x, closed)
	for z in range(1, res - 1):
		_push(hp, hc, filled[z * res], z * res, closed)
		_push(hp, hc, filled[z * res + res - 1], z * res + res - 1, closed)
	while hc.size() > 0:
		var c := _pop(hp, hc)
		order.append(c)
		var cx := c % res
		var cz := int(c / float(res))
		var ce := filled[c]
		for k in 8:
			var nx := cx + _DX[k]
			var nz := cz + _DZ[k]
			if nx < 0 or nz < 0 or nx >= res or nz >= res:
				continue
			var ni := nz * res + nx
			if closed[ni] == 1:
				continue
			if h[ni] <= ce:
				filled[ni] = ce + epsilon  # dentro de una depresión: forzar bajada
				sink[ni] = 1
			else:
				filled[ni] = h[ni]
			_push(hp, hc, filled[ni], ni, closed)
	return {"filled": filled, "order": order, "sink": sink}


## D8 + acumulación. down[i] = índice del vecino de máxima bajada (-1 = salida
## por el borde); acc[i] = celdas que drenan por i (incluida ella misma).
static func flow_and_accumulation(filled: PackedFloat32Array, res: int,
		order: PackedInt32Array) -> Dictionary:
	var n := res * res
	var down := PackedInt32Array()
	down.resize(n)
	var acc := PackedFloat32Array()
	acc.resize(n)
	for i in n:
		acc[i] = 1.0
		var cx := i % res
		var cz := int(i / float(res))
		var best := -1
		var best_drop := 0.0
		for k in 8:
			var nx := cx + _DX[k]
			var nz := cz + _DZ[k]
			if nx < 0 or nz < 0 or nx >= res or nz >= res:
				continue
			var ni := nz * res + nx
			# Normalizar por distancia (diagonal = √2) para elegir la MÁXIMA pendiente.
			var dist := 1.41421356 if (_DX[k] != 0 and _DZ[k] != 0) else 1.0
			var drop := (filled[i] - filled[ni]) / dist
			if drop > best_drop:
				best_drop = drop
				best = ni
		down[i] = best
	# Acumular de MAYOR a MENOR elevación (order viene creciente del heap).
	for oi in range(order.size() - 1, -1, -1):
		var c := order[oi]
		var d := down[c]
		if d >= 0:
			acc[d] += acc[c]
	return {"down": down, "acc": acc}


## Traza polilíneas de río (world-space). Fuente = celda con acc ≥ umbral sin
## padre-río; sigue D8 hasta el mar (filled ≤ sea_level), el borde, o una celda
## reclamada por otro río (confluencia). Devuelve las max_rivers más largas.
static func trace_rivers(filled: PackedFloat32Array, down: PackedInt32Array,
		acc: PackedFloat32Array, res: int, bounds: Rect2, sea_level: float,
		threshold: float, max_rivers: int) -> Array:
	var n := res * res
	var texel := Vector2(bounds.size.x / float(res - 1), bounds.size.y / float(res - 1))
	var has_parent := PackedByteArray()
	has_parent.resize(n)
	for i in n:
		if acc[i] >= threshold and down[i] >= 0 and filled[i] > sea_level:
			has_parent[down[i]] = 1
	# claimed_by[celda] = índice del río que la reclamó (-1 libre): permite saber
	# EN QUIÉN desemboca un afluente para no dejarlo colgando si el tope
	# max_rivers descarta a su receptor.
	var claimed_by := PackedInt32Array()
	claimed_by.resize(n)
	claimed_by.fill(-1)
	var traced: Array = []
	var receiver_of := PackedInt32Array()  # -1 = mar/borde; ≥0 = río receptor
	for i in n:
		if acc[i] < threshold or has_parent[i] == 1 or filled[i] <= sea_level:
			continue
		var ridx := traced.size()
		var pts := PackedVector2Array()
		var recv := -1
		var c := i
		var guard := 0
		while c >= 0 and guard < n:
			guard += 1
			pts.append(bounds.position + Vector2(float(c % res) * texel.x,
					float(int(c / float(res))) * texel.y))
			if filled[c] <= sea_level:
				break  # llegó al mar
			if claimed_by[c] >= 0 and pts.size() > 1:
				recv = claimed_by[c]  # confluencia: tocó el cauce de otro río
				break
			claimed_by[c] = ridx
			c = down[c]
		if pts.size() >= 8:
			traced.append(pts)
			receiver_of.append(recv)
		# Río corto descartado: liberar nada (sus celdas quedan reclamadas con un
		# índice que no existirá en traced) — corregir para no colgar afluentes:
		elif pts.size() > 0:
			for k in pts.size():
				var gx := int(roundf((pts[k].x - bounds.position.x) / texel.x))
				var gz := int(roundf((pts[k].y - bounds.position.y) / texel.y))
				var gi := clampi(gz, 0, res - 1) * res + clampi(gx, 0, res - 1)
				if claimed_by[gi] == ridx:
					claimed_by[gi] = -1
	# Selección: los max_rivers más largos, y por PUNTO FIJO se descarta todo
	# río cuyo receptor no quedó conservado (garantía: cada río conservado
	# termina en el mar o en otro río conservado).
	var order_idx: Array = []
	for ri in traced.size():
		order_idx.append(ri)
	order_idx.sort_custom(func(a: int, b: int) -> bool:
		return (traced[a] as PackedVector2Array).size() > (traced[b] as PackedVector2Array).size())
	var kept: Dictionary = {}
	var cap := max_rivers if max_rivers > 0 else traced.size()
	for k in mini(cap, order_idx.size()):
		kept[order_idx[k]] = true
	var changed := true
	while changed:
		changed = false
		for ri in kept.keys():
			var rv := receiver_of[ri]
			if rv >= 0 and not kept.has(rv):
				kept.erase(ri)
				changed = true
				break
	var out: Array = []
	for k in order_idx:
		if kept.has(k):
			out.append(traced[k])
	return out


## ---- Min-heap binario sobre arrays paralelos ----

static func _push(hp: PackedFloat32Array, hc: PackedInt32Array, p: float, c: int,
		closed: PackedByteArray) -> void:
	if closed[c] == 1:
		return
	closed[c] = 1
	hp.push_back(p)
	hc.push_back(c)
	var i := hp.size() - 1
	while i > 0:
		var parent := (i - 1) >> 1
		if hp[parent] <= hp[i]:
			break
		var tp := hp[parent]; hp[parent] = hp[i]; hp[i] = tp
		var tc := hc[parent]; hc[parent] = hc[i]; hc[i] = tc
		i = parent


static func _pop(hp: PackedFloat32Array, hc: PackedInt32Array) -> int:
	var top := hc[0]
	var last := hp.size() - 1
	hp[0] = hp[last]
	hc[0] = hc[last]
	hp.resize(last)
	hc.resize(last)
	var i := 0
	while true:
		var l := i * 2 + 1
		var r := l + 1
		var smallest := i
		if l < last and hp[l] < hp[smallest]:
			smallest = l
		if r < last and hp[r] < hp[smallest]:
			smallest = r
		if smallest == i:
			break
		var tp := hp[smallest]; hp[smallest] = hp[i]; hp[i] = tp
		var tc := hc[smallest]; hc[smallest] = hc[i]; hc[i] = tc
		i = smallest
	return top
