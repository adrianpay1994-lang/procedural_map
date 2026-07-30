class_name PlantGenerator
extends RefCounted

## ============================================================================
## PlantGenerator · Plantas de sotobosque que NO son árboles (Fase 2)
## ============================================================================
## Helecho (abanico de frondas arqueadas) y cactus (columna acanalada + brazos).
## Deterministas por seed, color por vértice, sin texturas externas. Comparten
## el estilo del resto de FloraFactory.
## ============================================================================


static func _mat(double_sided: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.9
	if double_sided:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		m.backlight_enabled = true
		m.backlight = Color(0.14, 0.22, 0.08)
	return m


## Material de tallo/tronco de planta: DOBLE CARA (sin inversión) + viento por
## altura SINCRONIZADO con la copa (PlantSway). Fallback a _mat(true) si falta.
static func _sway_mat(plant_height: float) -> Material:
	var sh: Shader = load("res://shaders/PlantSway.gdshader")
	if sh != null:
		var sm := ShaderMaterial.new()
		sm.shader = sh
		sm.set_shader_parameter("plant_height", plant_height)
		return sm
	var m := _mat(false)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Helecho: N frondas que salen del centro y se arquean hacia afuera-abajo.
## Cada fronda = cinta de 3 tramos (reusa la técnica de las frondas de palmera).
static func make_fern(fern_seed: int,
		frond_color: Color = Color(0.19, 0.36, 0.15)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = fern_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat(true))
	var fronds := rng.randi_range(8, 12)
	for f in fronds:
		var a := TAU * float(f) / float(fronds) + rng.randf_range(-0.12, 0.12)
		var dir := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-dir.z, 0, dir.x)
		var length := rng.randf_range(0.28, 0.5)   # apertura horizontal MODESTA
		var height := rng.randf_range(0.7, 1.05)   # sube bastante (copa, no araña)
		var col := frond_color.lerp(frond_color.lightened(0.18),
				float(hash([fern_seed, f]) % 1000) / 1000.0)
		var prev := Vector3(0, 0.03, 0)
		var prev_w := 0.016
		var tramos := 5
		for k in tramos:
			var t := float(k + 1) / float(tramos)
			# copa: sube fuerte (seno) y se arquea/afuera despacio (t²)
			var y := height * sin(t * 1.35)
			var outr := length * t * t
			var p := dir * outr + Vector3(0, maxf(0.03, y), 0)
			var wdt := lerpf(0.055, 0.008, t)   # fronda fina que se afina
			var ca := col.darkened(0.14 * (1.0 - t))
			for tri: Array in [
					[prev - side * prev_w, prev + side * prev_w, p + side * wdt],
					[prev - side * prev_w, p + side * wdt, p - side * wdt]]:
				for v: Vector3 in tri:
					st.set_color(ca)
					st.set_uv(Vector2.ZERO)
					st.add_vertex(v)
			prev = p
			prev_w = wdt
	st.generate_normals()
	return st.commit()


## Cardón / cactus columnar (Trichocereus, Monte/Puna): columna acanalada verde
## saturado + brazos en L + ESPINAS en las costillas + flor blanca en la punta.
static func make_cactus(cactus_seed: int,
		body_color: Color = Color(0.12, 0.29, 0.17)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = cactus_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat(false))
	var h := rng.randf_range(1.6, 3.0)
	_add_ribbed_column(st, rng, Vector3.ZERO, Vector3(0, h, 0), 0.2, 0.14, body_color)
	_add_spines(st, Vector3.ZERO, Vector3(0, h, 0), 0.2, 0.14)
	var tops: Array[Vector3] = [Vector3(0, h, 0)]
	# Brazos: salen a media altura y suben en L (con espinas).
	var arms := rng.randi_range(0, 3)
	for _i in arms:
		var ya := rng.randf_range(0.32, 0.62) * h
		var a := rng.randf() * TAU
		var out_dir := Vector3(cos(a), 0, sin(a))
		var elbow := Vector3(0, ya, 0) + out_dir * rng.randf_range(0.28, 0.45)
		var tip := elbow + Vector3(0, rng.randf_range(0.45, 0.9), 0)
		_add_ribbed_column(st, rng, Vector3(0, ya, 0), elbow, 0.1, 0.09, body_color)
		_add_ribbed_column(st, rng, elbow, tip, 0.09, 0.06, body_color)
		_add_spines(st, Vector3(0, ya, 0), elbow, 0.1, 0.09)
		_add_spines(st, elbow, tip, 0.09, 0.06)
		tops.append(tip)
	st.generate_normals()
	var mesh := st.commit()
	# Flores blancas/amarillas en algunas puntas (doble cara, sin viento).
	if rng.randf() < 0.7:
		var fst := SurfaceTool.new()
		fst.begin(Mesh.PRIMITIVE_TRIANGLES)
		var fm := _mat(true)
		fst.set_material(fm)
		for top: Vector3 in tops:
			if rng.randf() < 0.55:
				_add_cactus_flower(fst, rng, top, Color(0.98, 0.96, 0.88))
		mesh = fst.commit(mesh)
	return mesh


## Espinas: manojos de púas pálidas en las costillas, a intervalos verticales.
static func _add_spines(st: SurfaceTool, p0: Vector3, p1: Vector3,
		r0: float, r1: float) -> void:
	var axis := (p1 - p0)
	var len_a := axis.length()
	if len_a < 0.05:
		return
	axis /= len_a
	var up := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var t0 := axis.cross(up).normalized()
	var t1 := axis.cross(t0).normalized()
	var ribs := 12
	var rows := maxi(4, int(len_a / 0.12))
	var spine_col := Color(0.9, 0.86, 0.72)
	for row in rows:
		var f := (float(row) + 0.5) / float(rows)
		var c := p0 + axis * (len_a * f)
		var r := lerpf(r0, r1, f) * 1.24   # cresta de costilla (donde nacen las púas)
		for i in ribs:
			var ang := TAU * float(i) / float(ribs)
			var d := (t0 * cos(ang) + t1 * sin(ang))
			var base := c + d * r
			# Areola: manojo de 5 púas radiando afuera en abanico.
			for k in 5:
				var kd := (d * 1.2 + axis * (0.35 * (k - 2)) + (t0 * sin(ang) - t1 * cos(ang)) * (0.14 * (k - 2))).normalized()
				var tip := base + kd * 0.075
				var sd := axis.cross(d).normalized() * 0.005
				for v: Vector3 in [base - sd, base + sd, tip]:
					st.set_color(spine_col)
					st.set_uv(Vector2.ZERO)
					st.add_vertex(v)


## Flor de cactus: corola de pétalos cortos alrededor de la punta.
static func _add_cactus_flower(st: SurfaceTool, rng: RandomNumberGenerator,
		center: Vector3, col: Color) -> void:
	var petals := 10
	var top := center + Vector3(0, 0.03, 0)
	for i in petals:
		var a := TAU * float(i) / float(petals)
		var d := Vector3(cos(a), 0.0, sin(a))
		var tip := top + d * 0.07 + Vector3(0, 0.05, 0)
		var side := Vector3(-d.z, 0, d.x) * 0.02
		var pc := col.darkened(rng.randf() * 0.1)
		for v: Vector3 in [top - side, top + side, tip]:
			st.set_color(pc)
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)
	# Centro amarillo.
	for i in petals:
		var a0 := TAU * float(i) / float(petals)
		var a1 := TAU * float(i + 1) / float(petals)
		for v: Vector3 in [top, top + Vector3(cos(a0), 0.2, sin(a0)) * 0.022,
				top + Vector3(cos(a1), 0.2, sin(a1)) * 0.022]:
			st.set_color(Color(0.95, 0.85, 0.2))
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)


## Columna acanalada (sección estrella de R costillas) entre dos puntos.
static func _add_ribbed_column(st: SurfaceTool, _rng: RandomNumberGenerator,
		p0: Vector3, p1: Vector3, r0: float, r1: float, col: Color) -> void:
	var axis := (p1 - p0)
	var len_a := axis.length()
	if len_a < 0.01:
		return
	axis /= len_a
	var up := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var t0 := axis.cross(up).normalized()
	var t1 := axis.cross(t0).normalized()
	var ribs := 12
	var seg := 6  # tramos verticales (para la punta redondeada)
	for s in seg:
		var f0 := float(s) / float(seg)
		var f1 := float(s + 1) / float(seg)
		# radio se cierra hacia la punta (tapa redondeada)
		var rr0 := lerpf(r0, r1, f0) * sqrt(maxf(0.0, 1.0 - f0 * f0 * 0.55))
		var rr1 := lerpf(r0, r1, f1) * sqrt(maxf(0.0, 1.0 - f1 * f1 * 0.55))
		var c0 := p0 + axis * (len_a * f0)
		var c1 := p0 + axis * (len_a * f1)
		for i in ribs:
			var a0 := TAU * float(i) / float(ribs)
			var a1 := TAU * float(i + 1) / float(ribs)
			# costillas MARCADAS: radio ondula fuerte con cos(ribs·ang); el valle
			# entre costillas se oscurece (surco) → relieve legible.
			var m0 := 1.0 + 0.22 * cos(ribs * a0)
			var m1 := 1.0 + 0.22 * cos(ribs * a1)
			var d0 := (t0 * cos(a0) + t1 * sin(a0)) * m0
			var d1 := (t0 * cos(a1) + t1 * sin(a1)) * m1
			var groove := 0.5 + 0.5 * cos(ribs * (a0 + a1) * 0.5)  # 1 en cresta, 0 en valle
			var shade := col.darkened((1.0 - groove) * 0.28).lerp(
					col.lightened(0.06), float(hash([i, s]) % 100) / 100.0)
			for v: Vector3 in [c0 + d0 * rr0, c1 + d1 * rr1, c0 + d1 * rr0,
					c0 + d0 * rr0, c1 + d0 * rr1, c1 + d1 * rr1]:
				st.set_color(shade)
				st.set_uv(Vector2.ZERO)
				st.add_vertex(v)


## Helecho arborescente (Selva Misionera): tronco fibroso delgado + corona de
## frondas arqueadas en la punta. Estrato intermedio de la selva.
static func make_tree_fern(fern_seed: int,
		frond_color: Color = Color(0.19, 0.38, 0.15),
		trunk_color: Color = Color(0.3, 0.24, 0.18)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = fern_seed
	# Tronco con VIENTO (TreeSway): se mece a la par de las frondas (antes el
	# tronco quedaba quieto y la copa se movía = raro). Winding CCW hacia afuera
	# (el patrón del frame XZ estaba invertido → se veía de adentro).
	var h := rng.randf_range(2.2, 4.2)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(TreeGenerator._bark_mat(h))
	var sides := 8
	var segs := 6
	for s in segs:
		var t0 := float(s) / float(segs)
		var t1 := float(s + 1) / float(segs)
		# base algo ensanchada (raíces fibrosas), afina poco hacia arriba
		var r0 := lerpf(0.17, 0.1, t0)
		var r1 := lerpf(0.17, 0.1, t1)
		var y0 := h * t0
		var y1 := h * t1
		var c := trunk_color.lerp(trunk_color.lightened(0.12),
				float(hash([fern_seed, s]) % 100) / 100.0)
		for i in sides:
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			var d0 := Vector3(cos(a0), 0, sin(a0))
			var d1 := Vector3(cos(a1), 0, sin(a1))
			for v: Vector3 in [Vector3(0, y0, 0) + d0 * r0, Vector3(0, y0, 0) + d1 * r0,
					Vector3(0, y1, 0) + d1 * r1, Vector3(0, y0, 0) + d0 * r0,
					Vector3(0, y1, 0) + d1 * r1, Vector3(0, y1, 0) + d0 * r1]:
				st.set_color(c)
				st.set_uv(Vector2.ZERO)
				st.add_vertex(v)
	st.generate_normals()
	var mesh := st.commit()
	# Corona de frondas TEXTURADAS (card con alpha de racimo = fronda lujosa y
	# barata, la técnica pro; la geometría sólida se veía como palitos). Cada
	# fronda = tira ancha de 6 tramos que arquea afuera-abajo, con UV a lo largo.
	var fst := SurfaceTool.new()
	fst.begin(Mesh.PRIMITIVE_TRIANGLES)
	fst.set_material(FloraFactory._leaf_mat("fern_frond", h))
	var top := Vector3(0, h, 0)
	# Corona LUJOSA: frondas anchas TEXTURADAS que arquean afuera-abajo. Cada
	# fronda = tira de 6 tramos; ancho real (la textura+alpha da los folíolos).
	var fronds := rng.randi_range(14, 18)
	for f in fronds:
		var a := TAU * float(f) / float(fronds) + rng.randf_range(-0.1, 0.1)
		var dir := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-dir.z, 0, dir.x)
		var length := rng.randf_range(1.7, 2.6)
		var col := frond_color.lerp(frond_color.lightened(0.22),
				float(hash([fern_seed, f, 7]) % 1000) / 1000.0)
		var prev := top
		var prev_w := 0.06
		var prev_v := 0.0
		var arc_steps := 6
		for k in arc_steps:
			var t := float(k + 1) / float(arc_steps)
			var p := top + dir * (length * t) + Vector3(0, 0.6 * t - 1.1 * t * t, 0)
			# Ancho de fronda: se abre rápido y se afina a la punta (forma de pluma).
			var wdt := (0.34 * sin(t * PI * 0.9) + 0.05) * 0.5
			# Tira texturada con UV: v a lo largo (0→1), u a lo ancho (0→1).
			var pc := col.darkened(0.14 * (1.0 - t))
			_frond_quad(fst, prev - side * prev_w, prev + side * prev_w,
					p + side * wdt, p - side * wdt, prev_v, t, pc)
			prev = p
			prev_w = wdt
			prev_v = t
	fst.generate_normals()
	return fst.commit(mesh)


## Palmito (Euterpe edulis): palma grácil de la selva. Estípite MUY DELGADO liso
## anillado gris, rematado en un CROWNSHAFT verde brillante (vaina foliar) bajo una
## corona de pocas frondas pinnadas arqueadas con folíolos PÉNDULOS (plumero llorón).
## Rasgo ícono que lo separa del pindó. Ver FLORA_ARGENTINA_CATALOGO.
static func make_palmito(palm_seed: int,
		frond_color: Color = Color(0.2, 0.42, 0.16),
		trunk_color: Color = Color(0.55, 0.56, 0.5)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = palm_seed
	var h := rng.randf_range(9.0, 13.0)
	var shaft := h * 0.9                          # el crownshaft verde ocupa el 10% superior
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(TreeGenerator._bark_mat(h))
	var sides := 8
	var segs := 10
	var green := Color(0.28, 0.55, 0.2)           # vaina foliar verde vivo (ícono)
	for s in segs:
		var t0 := float(s) / float(segs)
		var t1 := float(s + 1) / float(segs)
		var y0 := h * t0
		var y1 := h * t1
		# Estípite fino que se afina apenas; el crownshaft (arriba de `shaft`) se abulta.
		var r0 := _palm_radius(t0, y0, shaft, h)
		var r1 := _palm_radius(t1, y1, shaft, h)
		var c0 := green if y0 >= shaft else trunk_color
		var c1 := green if y1 >= shaft else trunk_color
		for i in sides:
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			var d0 := Vector3(cos(a0), 0, sin(a0))
			var d1 := Vector3(cos(a1), 0, sin(a1))
			for pair: Array in [[Vector3(0, y0, 0) + d0 * r0, c0],
					[Vector3(0, y0, 0) + d1 * r0, c0], [Vector3(0, y1, 0) + d1 * r1, c1],
					[Vector3(0, y0, 0) + d0 * r0, c0], [Vector3(0, y1, 0) + d1 * r1, c1],
					[Vector3(0, y1, 0) + d0 * r1, c1]]:
				st.set_color(pair[1])
				st.set_uv(Vector2.ZERO)
				st.add_vertex(pair[0])
	st.generate_normals()
	var mesh := st.commit()
	# Corona: POCAS frondas (8-11) largas que salen del tope, arquean afuera y luego
	# CAEN fuerte (folíolos péndulos = look llorón). Textura "palm".
	var fst := SurfaceTool.new()
	fst.begin(Mesh.PRIMITIVE_TRIANGLES)
	fst.set_material(FloraFactory._leaf_mat("palm", h))
	var top := Vector3(0, h, 0)
	var fronds := rng.randi_range(12, 15)
	for f in fronds:
		var a := TAU * float(f) / float(fronds) + rng.randf_range(-0.12, 0.12)
		var dir := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-dir.z, 0, dir.x)
		var length := rng.randf_range(2.8, 3.8)
		var col := frond_color.lerp(frond_color.lightened(0.2),
				float(hash([palm_seed, f, 7]) % 1000) / 1000.0)
		var prev := top
		var prev_w := 0.08
		var prev_v := 0.0
		var arc_steps := 7
		for k in arc_steps:
			var t := float(k + 1) / float(arc_steps)
			# Arco que se ABRE hacia afuera y cae suave: mantiene ancho de corona
			# (plumero), la textura "palm" da los folíolos péndulos. (Un droop fuerte
			# colapsaba la corona contra el tronco = palito.)
			var p := top + dir * (length * t) + Vector3(0, 0.7 * t - 1.5 * t * t, 0)
			var wdt := (0.5 * sin(t * PI * 0.85) + 0.06) * 0.5
			var pc := col.darkened(0.14 * (1.0 - t))
			_frond_quad(fst, prev - side * prev_w, prev + side * prev_w,
					p + side * wdt, p - side * wdt, prev_v, t, pc)
			prev = p
			prev_w = wdt
			prev_v = t
	fst.generate_normals()
	return fst.commit(mesh)


## Radio del estípite del palmito: fino y liso, con crownshaft abultado arriba.
static func _palm_radius(t: float, y: float, shaft: float, h: float) -> float:
	if y >= shaft:
		# Crownshaft: se ensancha respecto al estípite (vaina que envuelve).
		return lerpf(0.11, 0.07, (y - shaft) / maxf(h - shaft, 0.01)) + 0.03
	return lerpf(0.13, 0.09, t)                   # estípite delgado casi cilíndrico


## Quad de fronda texturado (a,b arriba-prev; c,d abajo-p) con UV [u,v].
static func _frond_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		d: Vector3, v0: float, v1: float, col: Color) -> void:
	var uva := Vector2(0.0, v0)
	var uvb := Vector2(1.0, v0)
	var uvc := Vector2(1.0, v1)
	var uvd := Vector2(0.0, v1)
	for pair: Array in [[a, uva], [b, uvb], [c, uvc], [a, uva], [c, uvc], [d, uvd]]:
		st.set_color(col)
		st.set_uv(pair[1])
		st.add_vertex(pair[0])


## Tacuara / bambú (Selva Misionera): mata de cañas altas delgadas segmentadas,
## con nudos y unas hojas finas cerca de la punta.
static func make_bamboo(bamboo_seed: int,
		cane_color: Color = Color(0.42, 0.52, 0.24)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = bamboo_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# PlantSway: doble cara (las cañas finas ya no se ven "de adentro") + se
	# mecen con el viento por altura. plant_height = caña más alta del rango.
	st.set_material(_sway_mat(4.6))
	var canes := rng.randi_range(5, 9)
	var sides := 5
	# Guardar la PUNTA real de cada caña para colgar las hojas exactamente ahí
	# (antes las hojas usaban otra semilla y quedaban flotando fuera de la caña).
	var cane_tops: Array[Vector3] = []
	for _c in canes:
		var az := rng.randf() * TAU
		var base := Vector3(cos(az), 0, sin(az)) * rng.randf_range(0.0, 0.25)
		var lean := Vector3(cos(az), 0, sin(az)) * rng.randf_range(0.05, 0.2)
		var h := rng.randf_range(2.6, 4.6)
		var r := rng.randf_range(0.025, 0.045)
		var nodes := int(h / 0.5)
		var col := cane_color.lerp(cane_color.lightened(0.18), rng.randf())
		cane_tops.append(base + Vector3(0, h, 0) + lean)
		for s in nodes:
			var t0 := float(s) / float(nodes)
			var t1 := float(s + 1) / float(nodes)
			var c0 := base + Vector3(0, h * t0, 0) + lean * (t0 * t0)
			var c1 := base + Vector3(0, h * t1, 0) + lean * (t1 * t1)
			# nudo: leve engrosamiento al inicio del segmento
			var r0 := r * (1.0 + 0.25 * float(s % 2)) * (1.0 - 0.4 * t0)
			var r1 := r * (1.0 - 0.4 * t1)
			for i in sides:
				var a0 := TAU * float(i) / float(sides)
				var a1 := TAU * float(i + 1) / float(sides)
				var d0 := Vector3(cos(a0), 0, sin(a0))
				var d1 := Vector3(cos(a1), 0, sin(a1))
				# Winding CCW hacia AFUERA (antes estaba invertido: se veía de adentro).
				for v: Vector3 in [c0 + d0 * r0, c0 + d1 * r0, c1 + d1 * r1,
						c0 + d0 * r0, c1 + d1 * r1, c1 + d0 * r1]:
					st.set_color(col)
					st.set_uv(Vector2.ZERO)
					st.add_vertex(v)
	# Hojas SOLDADAS a la punta real de cada caña (cards lanceoladas texturadas).
	var mesh := st.commit()
	var lst := SurfaceTool.new()
	lst.begin(Mesh.PRIMITIVE_TRIANGLES)
	lst.set_material(FloraFactory._leaf_mat("laurel", 3.0))
	for top: Vector3 in cane_tops:
		# 4-7 hojas repartidas en el tramo superior de LA MISMA caña (no flotando).
		for _l in rng.randi_range(4, 7):
			var la := rng.randf() * TAU
			var ldir := Vector3(cos(la), rng.randf_range(-0.4, 0.25), sin(la)).normalized()
			# nacen sobre el eje de la caña (top baja un poco) → pegadas a la caña
			var lp := top - Vector3(0, rng.randf_range(0.0, 0.9), 0)
			FloraFactory._add_leaf_card(lst, lp + ldir * 0.16, rng.randf_range(0.28, 0.4),
					ldir, Color(0.4, 0.52, 0.24))
	mesh = lst.commit(mesh)
	return mesh


## Caladium / oreja de elefante (sotobosque tropical húmedo): roseta de HOJAS
## GRANDES acorazonadas sobre pecíolos, saliendo del suelo. Card texturada
## "cordate". Estrato herbáceo de la selva misionera.
static func make_caladium(cal_seed: int,
		leaf_color: Color = Color(0.2, 0.42, 0.16)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = cal_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(FloraFactory._leaf_mat("cordate", 1.2))
	var n := rng.randi_range(4, 7)
	for i in n:
		var a := TAU * float(i) / float(n) + rng.randf_range(-0.35, 0.35)
		var lean := Vector3(cos(a), 0, sin(a))
		var h := rng.randf_range(0.42, 0.85)
		var pos := lean * rng.randf_range(0.1, 0.32) + Vector3(0, h, 0)
		# la hoja mira afuera-arriba (lámina casi vertical, algo volcada)
		var facedir := (lean * 0.65 + Vector3.UP * 0.55).normalized()
		var sz := rng.randf_range(0.55, 0.9)
		var tint := leaf_color.lerp(leaf_color.lightened(0.22), rng.randf())
		FloraFactory._add_leaf_card(st, pos, sz, facedir, tint)
	st.generate_normals()
	return st.commit()


## Güembé / guaimbé (Thaumatophyllum bipinnatifidum): epífita/terrestre ICÓNICA de
## la selva. Mata de HOJAS ENORMES (60-70 cm) profundamente pinnatífidas/recortadas
## (textura "digitate") sobre PECÍOLOS largos verdes. Da el look "selva" en el suelo
## y en la base de troncos. (Las raíces aéreas colgantes son sobre un tronco
## hospedador, no modelado aquí; forma terrestre = la roseta de hojas gigantes.)
## Ver FLORA_ARGENTINA_CATALOGO.
static func make_guembe(guembe_seed: int,
		leaf_color: Color = Color(0.15, 0.35, 0.12),
		stalk_color: Color = Color(0.3, 0.44, 0.22)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = guembe_seed
	var n := rng.randi_range(7, 10)
	# Pecíolos CORTOS y algo gruesos: apenas alzan la lámina; quedan casi tapados por
	# la masa de hojas (una mata de güembé de costado es un montículo de hojas
	# solapadas, NO un starburst de tallos largos — ese era el error).
	var pst := SurfaceTool.new()
	pst.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = stalk_color
	pmat.roughness = 0.9
	pmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pst.set_material(pmat)
	var leaf_tips: Array[Vector3] = []
	var leaf_dirs: Array[Vector3] = []
	for i in n:
		var a := TAU * float(i) / float(n) + rng.randf_range(-0.3, 0.3)
		var lean := Vector3(cos(a), 0, sin(a))
		var reach := rng.randf_range(0.1, 0.3)           # láminas juntas → se solapan
		var h := rng.randf_range(0.4, 0.65)              # pecíolo corto
		var tip := lean * reach + Vector3(0, h, 0)
		leaf_tips.append(tip)
		leaf_dirs.append(lean)
		_stalk(pst, Vector3.ZERO, tip, 0.045, stalk_color)
	pst.generate_normals()
	var mesh := pst.commit()
	# Hojas gigantes recortadas encaradas afuera-arriba (lámina casi horizontal
	# volcada), textura "digitate" = folíolos profundos tipo pinnatífida.
	var lst := SurfaceTool.new()
	lst.begin(Mesh.PRIMITIVE_TRIANGLES)
	lst.set_material(FloraFactory._leaf_mat("palmate", 1.4))  # hoja redonda de cortes profundos (llena la card; digitate traía tallo vacío)
	for i in n:
		var lean: Vector3 = leaf_dirs[i]
		var sz := rng.randf_range(1.7, 2.3)              # hoja ENORME (60-70 cm) que solapa
		# Lámina un poco por AFUERA de la punta del pecíolo (sigue al pecíolo).
		var lpos: Vector3 = leaf_tips[i] + lean * (sz * 0.22)
		var tint := leaf_color.lerp(leaf_color.lightened(0.2), rng.randf())
		# CARDS CRUZADAS: una encara afuera, otra perpendicular → la hoja se ve desde
		# cualquier ángulo (una card plana sola queda de canto = línea fina invisible).
		var face_a := (lean * 0.9 + Vector3.UP * 0.3).normalized()
		var side := Vector3(-lean.z, 0.0, lean.x)
		var face_b := (side * 0.9 + Vector3.UP * 0.3).normalized()
		FloraFactory._add_leaf_card(lst, lpos, sz, face_a, tint)
		FloraFactory._add_leaf_card(lst, lpos, sz * 0.92, face_b, tint.darkened(0.06))
	lst.generate_normals()
	return lst.commit(mesh)


## Cilindro fino recto entre a y b (pecíolo/tallo), 5 lados.
static func _stalk(st: SurfaceTool, a: Vector3, b: Vector3, r: float, col: Color) -> void:
	var axis := (b - a)
	var up := axis.normalized()
	var side := up.cross(Vector3.RIGHT)
	if side.length_squared() < 0.01:
		side = up.cross(Vector3.FORWARD)
	side = side.normalized()
	var fwd := up.cross(side).normalized()
	var sides := 5
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var d0 := side * cos(a0) + fwd * sin(a0)
		var d1 := side * cos(a1) + fwd * sin(a1)
		for v: Vector3 in [a + d0 * r, a + d1 * r, b + d1 * r,
				a + d0 * r, b + d1 * r, b + d0 * r]:
			st.set_color(col)
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)


## Juncos / totora de orilla (borde de lago/río): mata de cañas-brizna altas y
## rígidas verde-azuladas + algunas espigas marrones. Doble cara + viento suave.
static func make_reed(reed_seed: int,
		blade_color: Color = Color(0.26, 0.44, 0.24)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = reed_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_sway_mat(2.0))
	var blades := rng.randi_range(24, 34)   # mata densa (era rala)
	for _b in blades:
		var az := rng.randf() * TAU
		var base := Vector3(cos(az), 0, sin(az)) * rng.randf_range(0.0, 0.34)
		var h := rng.randf_range(1.3, 2.2)
		var lean := Vector3(cos(az), 0, sin(az)) * rng.randf_range(0.05, 0.3)
		var side := Vector3(-sin(az), 0, cos(az))
		# poca variación de tono (antes lightened 0.2 → cañas blancuzcas)
		var col := blade_color.lerp(blade_color.lightened(0.1), rng.randf())
		var prev := base
		var prev_w := rng.randf_range(0.022, 0.036)
		var segs := 4
		for k in segs:
			var t := float(k + 1) / float(segs)
			var p := base + Vector3(0, h * t, 0) + lean * (t * t)
			var wdt := prev_w * (1.0 - t)
			for tri: Array in [[prev - side * prev_w, prev + side * prev_w, p + side * wdt],
					[prev - side * prev_w, p + side * wdt, p - side * wdt]]:
				for v: Vector3 in tri:
					st.set_color(col.darkened(0.12 * (1.0 - t)))
					st.set_uv(Vector2.ZERO)
					st.add_vertex(v)
			prev = p
			prev_w = wdt
		# espiga marrón (totora) en ~1 de cada 4 cañas
		if rng.randf() < 0.28:
			var tip := base + Vector3(0, h, 0) + lean
			for k in 5:
				var t := float(k) / 5.0
				var c := tip + Vector3(0, t * 0.18, 0)
				var rr := 0.03 * (1.0 - absf(t - 0.5) * 1.4)
				for tri: Array in [[c - side * rr, c + side * rr, c + Vector3(0, 0.04, 0) + side * rr],
						[c - side * rr, c + Vector3(0, 0.04, 0) + side * rr, c + Vector3(0, 0.04, 0) - side * rr]]:
					for v: Vector3 in tri:
						st.set_color(Color(0.42, 0.3, 0.17))
						st.set_uv(Vector2.ZERO)
						st.add_vertex(v)
	st.generate_normals()
	return st.commit()
