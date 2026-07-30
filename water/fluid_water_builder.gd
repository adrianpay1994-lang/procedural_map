class_name FluidWaterBuilder
extends RefCounted

## ============================================================================
## FluidWaterBuilder · Agua FLUIDA por celdas, estilo Minecraft (backlog #39)
## ============================================================================
## Doctrina definitiva del usuario: LA ZANJA es el río; el agua es un fluido
## que la LLENA — cae, se nivela y choca contra el terreno. Nada de cintas.
## Celdas de 2 m sobre la grilla del sampler: cada estación del lecho define
## un nivel (monotónico, ya bakeado en la capa del río); se inunda por BFS
## hasta donde el terreno supera el nivel. Top plano por celda + caras
## laterales (cascadas) donde el agua escalona hacia abajo.
## ============================================================================

const CELL := 2.0
const WATER_DEPTH := 0.8   # nivel sobre el lecho tallado


## Ríos: llena la zanja de cada PathCarveLayer river_carve (targets bakeados).
static func build_rivers(sampler: HeightSampler, river_layers: Array[HeightLayer],
		sea_level: float, material: Material) -> Node3D:
	var root := Node3D.new()
	root.name = "Rivers"
	var ri := 0
	for l in river_layers:
		var pl := l as PathCarveLayer
		if pl == null or pl.points.size() < 2 \
				or pl.target_heights.size() != pl.points.size():
			continue
		var cells := {}   # Vector2i -> nivel (float)
		var max_reach := pl.width_m * 0.5 + pl.falloff_m + CELL
		# Columna de agua acotada a la zanja: si el terreno queda más hondo que
		# la zanja bajo el nivel, el agua NO se queda ahí (se derramaría ladera
		# abajo — el bug de agua colgada en pendientes).
		var max_depth := pl.depth_m + 1.0
		for i in pl.points.size():
			var level := maxf(pl.target_heights[i] + WATER_DEPTH, sea_level - 0.15)
			_flood(sampler, cells, pl.points[i], level, max_reach, max_depth)
		if cells.is_empty():
			continue
		var mi := MeshInstance3D.new()
		mi.name = "River_%d" % ri
		mi.mesh = _cells_to_mesh(sampler, cells, material)
		root.add_child(mi)
		ri += 1
	return root


## Lagos: inunda el cuenco desde el centro hasta las paredes.
static func build_lakes(sampler: HeightSampler, lakes_info: Array[Dictionary],
		material: Material) -> Node3D:
	var root := Node3D.new()
	root.name = "Lakes"
	var li := 0
	for lake in lakes_info:
		var cells := {}
		_flood(sampler, cells, lake.center_pos, lake.water_y, 60.0, 3.5)
		if cells.is_empty():
			continue
		var mi := MeshInstance3D.new()
		mi.name = "Lake_%d" % li
		mi.mesh = _cells_to_mesh(sampler, cells, material)
		root.add_child(mi)
		li += 1
	return root


## BFS desde origin: celdas cuyo TERRENO queda bajo el nivel se inundan.
## El agua colisiona con la isla: donde el terreno sube sobre el nivel, para.
static func _flood(sampler: HeightSampler, cells: Dictionary, origin: Vector2,
		level: float, max_reach: float, max_depth: float) -> void:
	var start := Vector2i(int(floorf(origin.x / CELL)), int(floorf(origin.y / CELL)))
	var queue: Array[Vector2i] = [start]
	var seen := {start: true}
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		var center := Vector2((c.x + 0.5) * CELL, (c.y + 0.5) * CELL)
		if center.distance_to(origin) > max_reach:
			continue
		var depth_here := level - sampler.get_height(center)
		if depth_here < 0.05:
			continue  # pared: el fluido choca acá
		if depth_here > max_depth:
			continue  # más hondo que la zanja: el agua se derramaría — acá no hay agua quieta
		if not cells.has(c) or cells[c] < level:
			# Estaciones aguas arriba tienen nivel mayor: conservar el LOCAL
			# (el primero que llega manda — el BFS corre aguas abajo).
			if not cells.has(c):
				cells[c] = level
		for off: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n := c + off
			if not seen.has(n):
				seen[n] = true
				queue.push_back(n)


## Top plano por celda + caras laterales donde el agua escalona (cascadas).
static func _cells_to_mesh(sampler: HeightSampler, cells: Dictionary,
		material: Material) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(material)
	for c: Vector2i in cells:
		var level: float = cells[c]
		var x0 := c.x * CELL
		var z0 := c.y * CELL
		var x1 := x0 + CELL
		var z1 := z0 + CELL
		_quad_up(st, Vector3(x0, level, z0), Vector3(x1, level, z0),
				Vector3(x0, level, z1), Vector3(x1, level, z1))
		# Caras de cascada: vecino con agua más BAJA o sin agua sobre terreno hundido.
		for off: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n := c + off
			var neighbor_level: float = cells.get(n, -1e9)
			var drop_to: float
			if cells.has(n):
				if neighbor_level >= level - 0.01:
					continue
				drop_to = neighbor_level
			else:
				var ncenter := Vector2((n.x + 0.5) * CELL, (n.y + 0.5) * CELL)
				var ground: float = sampler.get_height(ncenter)
				if ground >= level - 0.05:
					continue  # el terreno tapa este lado
				drop_to = maxf(ground, level - 3.0)
			_side_face(st, c, off, level, drop_to)
	st.generate_normals()
	st.index()
	return st.commit()


static func _quad_up(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for v: Vector3 in [a, b, c, b, d, c]:
		st.set_uv(Vector2(v.x, v.z) * 0.15)
		st.set_uv2(Vector2.ZERO)
		st.add_vertex(v)


static func _side_face(st: SurfaceTool, c: Vector2i, off: Vector2i,
		top: float, bottom: float) -> void:
	var x0 := c.x * CELL
	var z0 := c.y * CELL
	var a: Vector3
	var b: Vector3
	match off:
		Vector2i(1, 0):
			a = Vector3(x0 + CELL, top, z0)
			b = Vector3(x0 + CELL, top, z0 + CELL)
		Vector2i(-1, 0):
			a = Vector3(x0, top, z0 + CELL)
			b = Vector3(x0, top, z0)
		Vector2i(0, 1):
			a = Vector3(x0 + CELL, top, z0 + CELL)
			b = Vector3(x0, top, z0 + CELL)
		_:
			a = Vector3(x0, top, z0)
			b = Vector3(x0 + CELL, top, z0)
	var a2 := Vector3(a.x, bottom, a.z)
	var b2 := Vector3(b.x, bottom, b.z)
	for v: Vector3 in [a, b, a2, b, b2, a2]:
		st.set_uv(Vector2(v.x + v.z, v.y) * 0.15)
		st.set_uv2(Vector2(0.3, 0.0))  # las cascadas ondulan como rapids
		st.add_vertex(v)
