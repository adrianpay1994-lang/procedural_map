class_name BridgeBuilder
extends RefCounted

## ============================================================================
## BridgeBuilder · ALCANTARILLA DE ARCO en los cruces camino/vía × río
## ============================================================================
## Imagen de referencia del usuario: el camino cruza sobre un TERRAPLÉN de
## piedra con un ARCO SEMICIRCULAR (túnel) por el que pasa el río. Nada de
## tableros sobre pilotes (rechazados). El terreno de la zanja queda intacto
## (banda protegida) — esta estructura es una mesh con colisión: se camina
## por arriba, el agua y el jugador pasan por adentro del arco.
## Texturas: cliff (piedra) triplanar del set del terreno.
## ============================================================================

const ARC_SEGS := 10
const BASE_SINK := 0.4   # la base se entierra bajo el lecho (sin ranuras)
const SPRING_H := 0.3    # arranque del arco sobre el lecho


static func build(sampler: HeightSampler, path_layers: Array[HeightLayer]) -> Node3D:
	var root := Node3D.new()
	root.name = "Bridges"
	var stone := StandardMaterial3D.new()
	stone.albedo_texture = load("res://assets/terrain/cliff_albedo.png")
	stone.normal_enabled = true
	stone.normal_texture = load("res://assets/terrain/cliff_normal.png")
	stone.uv1_triplanar = true
	stone.uv1_scale = Vector3(0.12, 0.12, 0.12)
	stone.roughness = 0.95
	stone.cull_mode = BaseMaterial3D.CULL_DISABLED
	var count := 0
	for l in path_layers:
		var pl := l as PathCarveLayer
		if pl == null or pl.bridge_spans.is_empty():
			continue
		for span in pl.bridge_spans:
			var culvert := _build_culvert(sampler, pl, span, stone)
			if culvert != null:
				culvert.name = "Bridge_%d" % count
				root.add_child(culvert)
				count += 1
	return root


## Alcantarilla de un vano: caja de terraplén en el MARCO DEL RÍO con túnel
## de medio cilindro. Portales triangulados arco→rectángulo (mapeo radial).
static func _build_culvert(sampler: HeightSampler, pl: PathCarveLayer,
		span: Vector2i, stone: Material) -> StaticBody3D:
	# Capa sin bake (p.ej. road_topo fantasma del modo CORRIDOR, enabled=false):
	# target_heights vacío ⇒ el deck_y de abajo indexaría fuera de rango.
	if pl.target_heights.size() != pl.points.size():
		return null
	# ---- Cruce: río protegido más cercano al centro del vano ----
	var mid_i := (span.x + span.y) / 2
	var mid_p := pl.points[mid_i]
	var prot: PathCarveLayer = null
	var best_d := INF
	for pr in pl.protected_layers:
		var d := pr.distance_to_path(mid_p)
		if d < best_d:
			best_d = d
			prot = pr
	if prot == null or prot.target_heights.size() != prot.points.size():
		return null
	# Punto y dirección del río en el cruce (escaneo del eje del receptor).
	var c_pt := prot.points[0]
	var r_dir := Vector2.RIGHT
	var c_best := INF
	for i in prot.points.size() - 1:
		var a := prot.points[i]
		var b := prot.points[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		var t := clampf((mid_p - a).dot(ab) / len2, 0.0, 1.0) if len2 > 0.001 else 0.0
		var q := a + ab * t
		var d2 := mid_p.distance_to(q)
		if d2 < c_best:
			c_best = d2
			c_pt = q
			r_dir = ab.normalized()
	var bed: float = prot.path_height_at(c_pt)
	if bed >= INF:
		return null
	# ---- Dimensiones ----
	var road_dir := (pl.points[mini(mid_i + 1, pl.points.size() - 1)]
			- pl.points[maxi(mid_i - 1, 0)]).normalized()
	var sin_a := absf(road_dir.cross(r_dir))
	var chan_half := prot.width_m * 0.5 * 0.9 + 0.3
	var r := clampf(chan_half + 0.6, 1.8, 2.6)
	var spring_y := bed + SPRING_H
	var apex := spring_y + r
	var base_y := bed - BASE_SINK
	var deck_y := apex + 0.5
	for i in range(span.x, span.y + 1):
		deck_y = maxf(deck_y, pl.target_heights[i])
	# Espesor del terraplén a lo largo del RÍO (túnel más largo si es oblicuo).
	var t_half := (pl.width_m * 0.5 + 2.5) / maxf(sin_a, 0.55)
	# Extensión a lo ancho del río (hasta los taludes de la zanja).
	var q_half := prot.width_m * 0.5 + prot.falloff_m + 3.0

	var q_dir := Vector2(-r_dir.y, r_dir.x)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(stone)
	# Contorno del túnel en el plano del portal (x a lo ancho, y altura).
	var outline: Array[Vector2] = [Vector2(-r, base_y)]
	for k in ARC_SEGS + 1:
		var t2 := PI * float(k) / float(ARC_SEGS)
		outline.append(Vector2(-r * cos(t2), spring_y + r * sin(t2)))
	outline.append(Vector2(r, base_y))
	var center := Vector2(0.0, spring_y)

	# ---- Portales (z = ±t_half): anillo arco → rectángulo (mapeo radial) ----
	for z_s: float in [-t_half, t_half]:
		for k in outline.size() - 1:
			var o0: Vector2 = outline[k]
			var o1: Vector2 = outline[k + 1]
			var b0 := _to_boundary(o0, center, q_half, deck_y, base_y)
			var b1 := _to_boundary(o1, center, q_half, deck_y, base_y)
			_quad(st, _v(c_pt, q_dir, r_dir, o0.x, o0.y, z_s),
					_v(c_pt, q_dir, r_dir, o1.x, o1.y, z_s),
					_v(c_pt, q_dir, r_dir, b0.x, b0.y, z_s),
					_v(c_pt, q_dir, r_dir, b1.x, b1.y, z_s))

	# ---- Barril del túnel + paredes bajo el arranque ----
	for k in outline.size() - 1:
		var o0: Vector2 = outline[k]
		var o1: Vector2 = outline[k + 1]
		_quad(st, _v(c_pt, q_dir, r_dir, o0.x, o0.y, -t_half),
				_v(c_pt, q_dir, r_dir, o1.x, o1.y, -t_half),
				_v(c_pt, q_dir, r_dir, o0.x, o0.y, t_half),
				_v(c_pt, q_dir, r_dir, o1.x, o1.y, t_half))

	# ---- Tapa superior (calzada) + laterales exteriores ----
	_quad(st, _v(c_pt, q_dir, r_dir, -q_half, deck_y, -t_half),
			_v(c_pt, q_dir, r_dir, q_half, deck_y, -t_half),
			_v(c_pt, q_dir, r_dir, -q_half, deck_y, t_half),
			_v(c_pt, q_dir, r_dir, q_half, deck_y, t_half))
	for x_s: float in [-q_half, q_half]:
		_quad(st, _v(c_pt, q_dir, r_dir, x_s, base_y, -t_half),
				_v(c_pt, q_dir, r_dir, x_s, deck_y, -t_half),
				_v(c_pt, q_dir, r_dir, x_s, base_y, t_half),
				_v(c_pt, q_dir, r_dir, x_s, deck_y, t_half))

	st.generate_normals()
	st.index()
	var mesh := st.commit()

	var body := StaticBody3D.new()
	body.collision_layer = 1  # WORLD
	body.collision_mask = 0
	body.set_meta("surface", &"rock")
	var mi := MeshInstance3D.new()
	mi.name = "Culvert"
	mi.mesh = mesh
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.shape = mesh.create_trimesh_shape()
	body.add_child(cs)
	return body


## Proyección radial de un punto del contorno del arco al borde del portal
## (rectángulo x ±q_half, y ∈ [base_y, deck_y]) desde el centro del arco.
static func _to_boundary(p: Vector2, center: Vector2, q_half: float,
		deck_y: float, base_y: float) -> Vector2:
	var dir := (p - center)
	if dir.length_squared() < 0.0001:
		return Vector2(q_half, center.y)
	dir = dir.normalized()
	var s := INF
	if absf(dir.x) > 0.0001:
		s = minf(s, q_half / absf(dir.x))
	if dir.y > 0.0001:
		s = minf(s, (deck_y - center.y) / dir.y)
	elif dir.y < -0.0001:
		s = minf(s, (center.y - base_y) / -dir.y)
	return center + dir * s


## Vértice en el marco del cruce: x sobre q_dir (a lo ancho del río),
## z sobre r_dir (a lo largo del río), y absoluta.
static func _v(c: Vector2, q_dir: Vector2, r_dir: Vector2,
		x: float, y: float, z: float) -> Vector3:
	var w := c + q_dir * x + r_dir * z
	return Vector3(w.x, y, w.y)


static func _quad(st: SurfaceTool, a0: Vector3, a1: Vector3,
		b0: Vector3, b1: Vector3) -> void:
	for v: Vector3 in [a0, a1, b1, a0, b1, b0]:
		st.set_uv(Vector2(v.x + v.z, v.y) * 0.1)
		st.add_vertex(v)
