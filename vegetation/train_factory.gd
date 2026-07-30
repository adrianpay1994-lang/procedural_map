class_name TrainFactory
extends RefCounted

## ============================================================================
## TrainFactory · Locomotora de TEST por piezas (Lego), procedural (#89)
## ============================================================================
## Modelo de prueba armado con cajas/cilindros: chasis + caldera + cabina +
## chimenea + ruedas. El ancho de ejes usa el GAUGE de la vía (coincide con los
## rieles). Colores por vértice (sin textura → nada se ve roto). Swappeable: el
## mapa puede reemplazar por otro mesh/escena desde el Inspector.
## ============================================================================


static func _mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.6
	m.metallic = 0.25
	return m


## Caja (prisma) centrada en `center`, tamaño `size`, color `col`.
static func _box(st: SurfaceTool, center: Vector3, size: Vector3, col: Color) -> void:
	var h := size * 0.5
	var c := [
		center + Vector3(-h.x, -h.y, -h.z), center + Vector3(h.x, -h.y, -h.z),
		center + Vector3(h.x, -h.y, h.z), center + Vector3(-h.x, -h.y, h.z),
		center + Vector3(-h.x, h.y, -h.z), center + Vector3(h.x, h.y, -h.z),
		center + Vector3(h.x, h.y, h.z), center + Vector3(-h.x, h.y, h.z)]
	var faces := [[0, 1, 2, 3], [7, 6, 5, 4], [4, 5, 1, 0],
			[6, 7, 3, 2], [5, 6, 2, 1], [7, 4, 0, 3]]
	for f: Array in faces:
		# Winding CCW (normal HACIA AFUERA): las caras se veían por dentro.
		for tri: Array in [[f[0], f[2], f[1]], [f[0], f[3], f[2]]]:
			for idx: int in tri:
				st.set_color(col)
				st.set_uv(Vector2.ZERO)
				st.add_vertex(c[idx])


## Cilindro a lo largo de un EJE (axis: Vector3.RIGHT horizontal, UP vertical).
static func _cylinder(st: SurfaceTool, center: Vector3, axis: Vector3,
		length: float, radius: float, col: Color, sides: int = 10) -> void:
	var a := axis.normalized()
	var up := Vector3.UP if absf(a.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	var t0 := a.cross(up).normalized()
	var t1 := a.cross(t0).normalized()
	var c0 := center - a * (length * 0.5)
	var c1 := center + a * (length * 0.5)
	for i in sides:
		var an0 := TAU * float(i) / float(sides)
		var an1 := TAU * float(i + 1) / float(sides)
		var d0 := t0 * cos(an0) + t1 * sin(an0)
		var d1 := t0 * cos(an1) + t1 * sin(an1)
		# Winding CCW hacia afuera (pared del cilindro).
		for v: Vector3 in [c0 + d0 * radius, c1 + d1 * radius, c0 + d1 * radius,
				c0 + d0 * radius, c1 + d0 * radius, c1 + d1 * radius]:
			st.set_color(col)
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)
		# tapas (normal hacia afuera en cada extremo)
		for v: Vector3 in [c1, c1 + d1 * radius, c1 + d0 * radius]:
			st.set_color(col.darkened(0.1)); st.set_uv(Vector2.ZERO); st.add_vertex(v)
		for v: Vector3 in [c0, c0 + d0 * radius, c0 + d1 * radius]:
			st.set_color(col.darkened(0.1)); st.set_uv(Vector2.ZERO); st.add_vertex(v)


## Locomotora de vapor de test. +Z = frente (convención de vehículos). El eje
## de ruedas usa `gauge_m` (coincide con la vía).
static func make_locomotive(gauge_m: float = 1.5, _seed_v: int = 1,
		body_color: Color = Color(0.5, 0.14, 0.12)) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat())
	var half_g := gauge_m * 0.5
	var body_w := gauge_m + 0.5
	var wheel_r := 0.42
	var floor_y := wheel_r + 0.15  # el chasis descansa sobre las ruedas
	# Chasis
	_box(st, Vector3(0, floor_y, 0), Vector3(body_w, 0.3, 5.4),
			Color(0.15, 0.15, 0.17))
	# Caldera (cilindro horizontal al frente, +Z)
	_cylinder(st, Vector3(0, floor_y + 0.55, 1.2), Vector3.FORWARD, 3.2, 0.55,
			body_color)
	# Cabina (caja alta atrás)
	_box(st, Vector3(0, floor_y + 0.7, -1.9), Vector3(body_w, 1.4, 1.5),
			body_color.darkened(0.1))
	# Techo cabina
	_box(st, Vector3(0, floor_y + 1.45, -1.9), Vector3(body_w + 0.2, 0.12, 1.7),
			Color(0.1, 0.1, 0.12))
	# Chimenea (cilindro vertical sobre la caldera al frente)
	_cylinder(st, Vector3(0, floor_y + 1.15, 2.4), Vector3.UP, 0.7, 0.16,
			Color(0.08, 0.08, 0.09))
	# Faro
	_box(st, Vector3(0, floor_y + 0.55, 2.85), Vector3(0.3, 0.3, 0.15),
			Color(0.95, 0.9, 0.6))
	# Ruedas: 3 ejes × 2 lados, sobre el gauge.
	var wheel_col := Color(0.12, 0.12, 0.14)
	for zi in [-1.6, 0.0, 1.6]:
		for sgn in [-1.0, 1.0]:
			_cylinder(st, Vector3(half_g * sgn, wheel_r, zi), Vector3.RIGHT,
					0.16, wheel_r, wheel_col, 12)
	st.generate_normals()
	return st.commit()


## WORKCART (Rust above-ground): servicio DIESEL bajo e industrial — cabina con
## ventanas a un extremo, capó de motor al otro, acopladores en las puntas.
## Es la unidad MANEJABLE (la que se conduce). +Z = frente (lado del capó).
static func make_workcart(gauge_m: float = 1.5, _seed_v: int = 1,
		body_color: Color = Color(0.86, 0.66, 0.12)) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat())
	var half_g := gauge_m * 0.5
	var body_w := gauge_m + 0.55
	var wheel_r := 0.4
	var floor_y := wheel_r + 0.15
	var dark := Color(0.14, 0.14, 0.16)
	# Chasis bajo.
	_box(st, Vector3(0, floor_y, 0), Vector3(body_w, 0.3, 5.0), dark)
	# Plataforma/base del cuerpo.
	_box(st, Vector3(0, floor_y + 0.35, 0), Vector3(body_w, 0.4, 4.6), body_color)
	# Capó del motor (frente, +Z): bloque más bajo.
	_box(st, Vector3(0, floor_y + 0.85, 1.3), Vector3(body_w - 0.2, 0.6, 2.0),
			body_color.darkened(0.05))
	# Cabina (atrás, -Z): más alta, con "ventana" (recuadro oscuro).
	_box(st, Vector3(0, floor_y + 1.1, -1.4), Vector3(body_w, 1.5, 1.7),
			body_color)
	_box(st, Vector3(0, floor_y + 1.5, -1.4), Vector3(body_w + 0.05, 0.5, 1.75),
			dark)  # franja de ventanas
	_box(st, Vector3(0, floor_y + 2.0, -1.4), Vector3(body_w + 0.1, 0.12, 1.9),
			dark)  # techo
	# Faro y acopladores (knuckles) en cada punta.
	_box(st, Vector3(0, floor_y + 0.8, 2.35), Vector3(0.3, 0.3, 0.12),
			Color(0.95, 0.9, 0.6))
	for zc: float in [2.5, -2.5]:
		_box(st, Vector3(0, floor_y - 0.05, zc), Vector3(0.3, 0.3, 0.35), dark)
	# 4 ruedas al gauge.
	for zi in [-1.7, 1.7]:
		for sgn in [-1.0, 1.0]:
			_cylinder(st, Vector3(half_g * sgn, wheel_r, zi), Vector3.RIGHT,
					0.16, wheel_r, dark, 12)
	st.generate_normals()
	return st.commit()


## Vagón sobre ruedas al gauge (~4.5 m). `kind`: 0 boxcar (caja), 1 cisterna
## (tanque cilíndrico), 2 plataforma (plano con estacas). Swappeable.
static func make_wagon(gauge_m: float = 1.5, seed_v: int = 1,
		body_color: Color = Color(0.35, 0.3, 0.22), kind: int = 0) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat())
	var half_g := gauge_m * 0.5
	var body_w := gauge_m + 0.5
	var wheel_r := 0.4
	var floor_y := wheel_r + 0.12
	# Chasis común.
	_box(st, Vector3(0, floor_y, 0), Vector3(body_w, 0.25, 4.4),
			Color(0.13, 0.13, 0.14))
	match kind:
		1:  # cisterna: tanque cilíndrico horizontal
			_cylinder(st, Vector3(0, floor_y + 0.75, 0), Vector3.FORWARD, 4.0,
					0.75, body_color.lerp(Color(0.5, 0.5, 0.55), 0.5), 12)
		2:  # plataforma: piso plano + estacas
			_box(st, Vector3(0, floor_y + 0.2, 0), Vector3(body_w, 0.15, 4.2),
					body_color.darkened(0.1))
			for zi in [-1.9, 1.9]:
				for sgn in [-1.0, 1.0]:
					_box(st, Vector3(half_g * sgn, floor_y + 0.5, zi),
							Vector3(0.12, 0.7, 0.12), Color(0.2, 0.16, 0.1))
		_:  # boxcar: caja cerrada
			_box(st, Vector3(0, floor_y + 0.9, 0), Vector3(body_w, 1.5, 4.0),
					body_color.lerp(Color(0.4, 0.32, 0.22), rng.randf()))
			_box(st, Vector3(0, floor_y + 1.68, 0), Vector3(body_w + 0.15, 0.12, 4.2),
					Color(0.1, 0.1, 0.1))
	var wheel_col := Color(0.1, 0.1, 0.12)
	for zi in [-1.4, 1.4]:
		for sgn in [-1.0, 1.0]:
			_cylinder(st, Vector3(half_g * sgn, wheel_r, zi), Vector3.RIGHT,
					0.15, wheel_r, wheel_col, 12)
	# Acopladores (knuckles) en ambas puntas → el convoy se ve enganchado.
	for zc: float in [2.2, -2.2]:
		_box(st, Vector3(0, floor_y - 0.02, zc), Vector3(0.28, 0.28, 0.35),
				Color(0.12, 0.12, 0.13))
	st.generate_normals()
	return st.commit()
