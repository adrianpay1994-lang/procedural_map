class_name FloraFactory
extends RefCounted

## ============================================================================
## FloraFactory · Assets de flora propios, generados por código (F8)
## ============================================================================
## Low-poly facetado con colores por vértice (sin texturas → nada puede verse
## "roto"). Deterministas por seed. El estilo es el de los survival estilizados:
## siluetas claras, variación de tono por vértice, normales planas.
## Técnica de desplazamiento coherente tomada de Retopology 2.0.
## ============================================================================


static func _mat(shaded: bool = true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.95
	if not shaded:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return m


## Blob facetado (copa de árbol/arbusto): esfera desplazada coherentemente.
static func _add_blob(st: SurfaceTool, rng: RandomNumberGenerator, center: Vector3,
		radius: float, squash: float, base_col: Color, var_col: float) -> void:
	var sphere := SphereMesh.new()
	sphere.radial_segments = 7
	sphere.rings = 4
	sphere.radius = radius
	sphere.height = radius * 2.0 * squash
	var arrays := sphere.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var seed_k := rng.randi()
	for i in verts.size():
		var v := verts[i]
		var k := Vector3i((v * 9.0).round())
		var h := float(hash([seed_k, k.x, k.y, k.z]) % 1000) / 1000.0
		verts[i] = v * (0.78 + h * 0.4)
	for i in range(0, indices.size(), 3):
		# Color por CARA (plano): mismo tono para los 3 vértices.
		var fk := indices[i]
		var fh := float(hash([seed_k, fk]) % 1000) / 1000.0
		var col := base_col.lerp(base_col.lightened(var_col), fh)
		for j in 3:
			st.set_color(col)
			st.set_uv(Vector2.ZERO)
			st.add_vertex(verts[indices[i + j]] + center)


## Tronco: prisma de 5 lados con leve conicidad.
static func _add_trunk(st: SurfaceTool, rng: RandomNumberGenerator, height: float,
		radius: float, col: Color) -> void:
	var sides := 5
	var lean := Vector3(rng.randf_range(-0.06, 0.06), 0, rng.randf_range(-0.06, 0.06))
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var b0 := Vector3(cos(a0), 0, sin(a0)) * radius
		var b1 := Vector3(cos(a1), 0, sin(a1)) * radius
		var t0 := b0 * 0.6 + Vector3.UP * height + lean * height
		var t1 := b1 * 0.6 + Vector3.UP * height + lean * height
		var fh := float(hash([i, 77]) % 1000) / 1000.0
		var c := col.lerp(col.lightened(0.15), fh)
		for v in [b0, b1, t1, b0, t1, t0]:
			st.set_color(c)
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)


## Material de HOJAS: textura de racimo con alpha scissor (silueta recortada) +
## translucidez a contraluz (backlight = look real) + doble cara. La tinta por
## vértice modula el verde (variación entre cards).
static func _leaf_mat(tex_name: String, tree_height: float = 8.0,
		override_tex: Texture2D = null) -> Material:
	# override_tex (FloraConfig, imagen externa) gana sobre la textura procedural.
	var tex: Texture2D = override_tex if override_tex != null \
			else load("res://assets/vegetation/leaves/%s.png" % tex_name)
	# Shader con VIENTO (la copa se mece CON las ramas). Fallback si falta.
	var sh: Shader = load("res://shaders/LeafWind.gdshader")
	if sh != null:
		var sm := ShaderMaterial.new()
		sm.shader = sh
		sm.set_shader_parameter("leaf_tex", tex)
		sm.set_shader_parameter("tree_height", tree_height)
		return sm
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.4
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.vertex_color_use_as_albedo = true
	m.backlight_enabled = true
	m.backlight = Color(0.16, 0.26, 0.09)
	m.roughness = 0.9
	return m


## Una card de hojas: quad texturado centrado en `center`, tamaño `size`,
## encarado hacia `dir` (billboard estático). tint modula el verde.
static func _add_leaf_card(st: SurfaceTool, center: Vector3, size: float,
		dir: Vector3, tint: Color) -> void:
	var n := dir.normalized()
	if n.length_squared() < 0.01:
		n = Vector3.FORWARD
	var right := n.cross(Vector3.UP)
	if right.length_squared() < 0.01:
		right = Vector3.RIGHT
	right = right.normalized()
	var vup := right.cross(n).normalized()
	var hw := size * 0.5
	var a := center - right * hw - vup * hw
	var b := center + right * hw - vup * hw
	var c := center + right * hw + vup * hw
	var d := center - right * hw + vup * hw
	var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	var verts := [a, b, c, a, c, d]
	var uv_idx := [0, 1, 2, 0, 2, 3]
	for i in 6:
		st.set_color(tint)
		st.set_uv(uvs[uv_idx[i]])
		st.set_normal(vup.lerp(n, 0.5).normalized())
		st.add_vertex(verts[i])


## Card de SPRAY de ramita: la base del tallo (v=1 abajo en el atlas) se ancla en
## `pos` y el spray CRECE a lo largo de `grow` (afuera+arriba de la rama). Dos
## quads cruzados alrededor del eje `grow` → la ramita se lee con volumen desde
## cualquier lado. Reemplaza las 3 cards chatas por hoja: mejor look + menos tris.
static func _add_leaf_spray(st: SurfaceTool, pos: Vector3, grow: Vector3,
		size: float, tint: Color) -> void:
	var g := grow.normalized()
	if g.length_squared() < 0.01:
		g = Vector3.UP
	var side := g.cross(Vector3.UP)
	if side.length_squared() < 0.01:
		side = g.cross(Vector3.FORWARD)
	side = side.normalized()
	_spray_quad(st, pos, g, side, size, tint)
	_spray_quad(st, pos, g, g.cross(side).normalized(), size, tint)


## Un quad de spray: base en `pos`, alto `size*1.35` a lo largo de `g`, ancho
## `size` a lo largo de `side`. UV con la base del tallo abajo (v=1).
static func _spray_quad(st: SurfaceTool, pos: Vector3, g: Vector3, side: Vector3,
		size: float, tint: Color) -> void:
	var hw := size * 0.5
	var ln := size * 1.35
	var nrm := side.cross(g).normalized()
	var a := pos - side * hw                 # base izq (v=1)
	var b := pos + side * hw                 # base der (v=1)
	var c := pos + side * hw + g * ln         # punta der (v=0)
	var d := pos - side * hw + g * ln         # punta izq (v=0)
	var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	var verts := [a, b, c, a, c, d]
	var uv_idx := [0, 1, 2, 0, 2, 3]
	for i in 6:
		st.set_color(tint)
		st.set_uv(uvs[uv_idx[i]])
		st.set_normal(nrm)
		st.add_vertex(verts[i])


## Copa de leaf cards: N cards CRUZADAS distribuidas en un volumen achatado,
## encaradas hacia afuera (cobertura desde todo ángulo). Devuelve la superficie
## de hojas lista para commitear sobre la mesh del tronco.
static func _build_canopy(rng: RandomNumberGenerator, tex_name: String,
		center: Vector3, radius: float, squash: float, count: int,
		card_size: float, base_col: Color, into: ArrayMesh) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_leaf_mat(tex_name))
	for _i in count:
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.4, 1),
				rng.randf_range(-1, 1)).normalized()
		var pos := center + Vector3(rng.randf_range(-1, 1),
				rng.randf_range(-squash, squash), rng.randf_range(-1, 1)) * radius
		# Tamaño de card INDEPENDIENTE del radio de copa: cards CHICAS (racimo
		# de hojas ~0.6 m) y muchas = follaje fino, no sábanas gigantes.
		var sz := card_size * rng.randf_range(0.75, 1.2)
		# Tinta cerca de blanco (modula, no re-colorea: la textura ya es verde);
		# leve variación de brillo entre cards + sesgo del color de bioma.
		var v := rng.randf_range(0.78, 1.06)
		var tint := Color(v, v, v).lerp(base_col.lightened(0.3), 0.25)
		tint.a = 1.0
		# Card + su perpendicular (cruzada) = se lee desde cualquier lado.
		_add_leaf_card(st, pos, sz, dir, tint)
		_add_leaf_card(st, pos, sz, dir.cross(Vector3.UP), tint)
	return st.commit(into)  # anexa la superficie de hojas a la mesh del tronco


## Rama/tronco cónico entre dos puntos (prisma de 5 lados, taper r0→r1).
static func _add_branch(st: SurfaceTool, p0: Vector3, p1: Vector3,
		r0: float, r1: float, col: Color) -> void:
	var axis := (p1 - p0)
	var len_a := axis.length()
	if len_a < 0.01:
		return
	axis /= len_a
	# Base ortonormal alrededor del eje de la rama.
	var up := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var t0 := axis.cross(up).normalized()
	var t1 := axis.cross(t0).normalized()
	var sides := 5
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var d0 := t0 * cos(a0) + t1 * sin(a0)
		var d1 := t0 * cos(a1) + t1 * sin(a1)
		var fh := float(hash([int(p0.x * 13), i]) % 1000) / 1000.0
		var c := col.lerp(col.lightened(0.14), fh)
		# Winding CCW hacia AFUERA (la pared del tronco se veía por dentro).
		for v: Vector3 in [p0 + d0 * r0, p1 + d1 * r1, p0 + d1 * r0,
				p0 + d0 * r0, p1 + d0 * r1, p1 + d1 * r1]:
			st.set_color(c)
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)


## Árbol frondoso realista: tronco que se BIFURCA en 3 ramas, copa de blobs
## sobre las puntas (no una piruleta) + gradiente de tono sombra→sol.
static func make_broadleaf(tree_seed: int, leaf_color: Color = Color(0.28, 0.5, 0.2),
		trunk_color: Color = Color(0.38, 0.28, 0.18)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = tree_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat())
	var h := rng.randf_range(2.4, 3.4)
	var fork := Vector3(0, h * 0.6, 0)  # altura de bifurcación
	_add_branch(st, Vector3.ZERO, fork, 0.24, 0.17, trunk_color)
	# 3 ramas que se abren + un blob de copa en cada punta.
	var tips: Array[Vector3] = []
	var nb := 3
	for b in nb:
		var a := TAU * float(b) / float(nb) + rng.randf_range(-0.3, 0.3)
		var lean := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.7, 1.2)
		var tip := fork + Vector3(0, rng.randf_range(0.9, 1.4), 0) + lean
		_add_branch(st, fork, tip, 0.15, 0.07, trunk_color)
		tips.append(tip)
	st.generate_normals()
	var mesh := st.commit()  # superficie 0 = tronco+ramas (color por vértice)
	# Copa de LEAF CARDS texturadas (superficie 1, UNA sola): follaje real que
	# cubre la corona entera (radio abarca las puntas), no blobs sólidos.
	var cc := fork + Vector3(0, 1.2, 0)
	return _build_canopy(rng, "broadleaf", cc, 1.7, 0.7, 48, 0.7, leaf_color, mesh)


## Acacia de sabana/desierto: tronco alto + COPA PLANA en sombrilla (blobs
## achatados y anchos arriba). Silueta icónica de pradera seca.
static func make_acacia(tree_seed: int, leaf_color: Color = Color(0.36, 0.44, 0.22),
		trunk_color: Color = Color(0.34, 0.26, 0.17)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = tree_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat())
	var h := rng.randf_range(3.2, 4.2)
	var top := Vector3(rng.randf_range(-0.3, 0.3), h, rng.randf_range(-0.3, 0.3))
	_add_branch(st, Vector3.ZERO, top, 0.2, 0.12, trunk_color)
	# Ramas laterales que sostienen la sombrilla.
	var spread := rng.randf_range(1.6, 2.2)
	for b in 5:
		var a := TAU * float(b) / 5.0 + rng.randf_range(-0.2, 0.2)
		var tip := top + Vector3(cos(a) * spread, rng.randf_range(0.1, 0.4),
				sin(a) * spread)
		_add_branch(st, top, tip, 0.09, 0.04, trunk_color)
	st.generate_normals()
	var mesh := st.commit()
	# Sombrilla PLANA de leaf cards (squash 0.28): la silueta de acacia.
	return _build_canopy(rng, "acacia", top + Vector3(0, 0.2, 0),
			spread * 1.05, 0.25, 36, 0.75, leaf_color, mesh)


## Pino/conífera: tronco alto + follaje de leaf cards en SILUETA CÓNICA (anillos
## que se angostan hacia arriba), sin conos de geometría (feos — captura). El
## viento y el alpha los da _leaf_mat.
static func make_pine(tree_seed: int, needle_color: Color = Color(0.16, 0.34, 0.2),
		trunk_color: Color = Color(0.33, 0.24, 0.16)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = tree_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat())
	var h := rng.randf_range(2.6, 3.8)  # tronco visible bajo el follaje
	_add_branch(st, Vector3.ZERO, Vector3(0, h, 0), 0.16, 0.09, trunk_color)
	st.generate_normals()
	var mesh := st.commit()
	# Follaje cónico: 4 anillos de cards, radio decreciente con la altura.
	var rings := 4
	for r in rings:
		var t := float(r) / float(rings - 1)          # 0 base → 1 punta
		var y := h * 0.35 + (h * 0.75) * t
		var radius := lerpf(1.15, 0.15, t)            # ancho abajo, fino arriba
		var cnt := int(lerpf(14, 5, t))
		mesh = _build_canopy(rng, "pine", Vector3(0, y, 0), radius, 0.35, cnt,
				0.85, needle_color, mesh)
	return mesh


## Arbusto: blob de leaf cards al ras (follaje texturado, no blob sólido).
static func make_bush(bush_seed: int, color: Color = Color(0.3, 0.46, 0.2)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = bush_seed
	# Ramitas cortas de base para que no flote.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat())
	_add_branch(st, Vector3.ZERO, Vector3(0, 0.35, 0), 0.06, 0.03,
			Color(0.34, 0.26, 0.16))
	st.generate_normals()
	var mesh := st.commit()
	return _build_canopy(rng, "broadleaf", Vector3(0, 0.45, 0), 0.55, 0.7, 18,
			0.4, color, mesh)


## Diente de león (Taraxacum). stage: 0=flor amarilla, 1=pompón blanco de semillas.
## Roseta de hojas dentadas al ras + 1-3 tallos huecos con la cabeza. Doble cara.
static func make_dandelion(dande_seed: int, stage: int = 0) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = dande_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat(false))   # doble cara
	var leaf_col := Color(0.22, 0.4, 0.15)
	# Roseta: 6-9 hojas lanceoladas DENTADAS pegadas al suelo, abiertas en estrella.
	var rosette := rng.randi_range(6, 9)
	for i in rosette:
		var a := TAU * float(i) / float(rosette) + rng.randf_range(-0.1, 0.1)
		var dir := Vector3(cos(a), 0.12, sin(a)).normalized()
		var length := rng.randf_range(0.16, 0.26)
		_add_toothed_leaf(st, Vector3(0, 0.02, 0), dir, length, leaf_col)
	# Tallos con cabeza.
	var stalks := rng.randi_range(1, 3)
	for s in stalks:
		var off := Vector3(rng.randf_range(-0.05, 0.05), 0, rng.randf_range(-0.05, 0.05))
		var h := rng.randf_range(0.22, 0.4)
		var top := off + Vector3(0, h, 0)
		_add_stalk(st, off + Vector3(0, 0.02, 0), top, 0.008, Color(0.3, 0.46, 0.2))
		if stage <= 0:
			_dandelion_bloom(st, rng, top)
		else:
			_dandelion_puff(st, rng, top)
	st.generate_normals()
	return st.commit()


## Cabeza amarilla: muchos rayos-flósculo finos radiando en un disco leve domo.
static func _dandelion_bloom(st: SurfaceTool, rng: RandomNumberGenerator, top: Vector3) -> void:
	var rays := 46
	var r := 0.05
	for i in rays:
		var a := TAU * float(i) / float(rays) + rng.randf_range(-0.03, 0.03)
		var dir := Vector3(cos(a), 0.0, sin(a))
		var tip := top + dir * r * rng.randf_range(0.85, 1.05) + Vector3(0, 0.012, 0)
		var side := Vector3(-dir.z, 0, dir.x) * 0.006
		var col := Color(0.98, 0.82, 0.12).lerp(Color(0.95, 0.68, 0.06), rng.randf())
		for v: Vector3 in [top - side, top + side, tip]:
			st.set_color(col)
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)


## Pompón blanco: esfera de filamentos (vilanos) radiando desde el centro.
static func _dandelion_puff(st: SurfaceTool, rng: RandomNumberGenerator, top: Vector3) -> void:
	var center := top + Vector3(0, 0.045, 0)
	var seeds := 70
	for _i in seeds:
		# dirección esférica (radiando en todas direcciones = pompón)
		var u := rng.randf() * TAU
		var v := rng.randf_range(-1.0, 1.0)
		var sph := Vector3(sqrt(1.0 - v * v) * cos(u), v, sqrt(1.0 - v * v) * sin(u))
		var tip := center + sph * rng.randf_range(0.04, 0.058)
		var side := sph.cross(Vector3.UP).normalized() * 0.004
		if side.length() < 0.001:
			side = Vector3(0.004, 0, 0)
		var col := Color(0.92, 0.93, 0.9, 1.0).darkened(rng.randf() * 0.06)
		for tri: Array in [[center - side, center + side, tip]]:
			for vtx: Vector3 in tri:
				st.set_color(col)
				st.set_uv(Vector2.ZERO)
				st.add_vertex(vtx)


## Hoja lanceolada DENTADA (borde en zigzag) — típica del diente de león.
static func _add_toothed_leaf(st: SurfaceTool, base: Vector3, dir: Vector3,
		length: float, col: Color) -> void:
	var side := Vector3(-dir.z, 0, dir.x).normalized()
	var segs := 5
	for k in segs:
		var t0 := float(k) / float(segs)
		var t1 := float(k + 1) / float(segs)
		var p0 := base + dir * (length * t0)
		var p1 := base + dir * (length * t1)
		# ancho con dientes (zigzag) que se afina a la punta
		var w0 := length * 0.16 * sin(t0 * PI) * (1.1 if k % 2 == 0 else 0.7)
		var w1 := length * 0.16 * sin(t1 * PI) * (0.7 if k % 2 == 0 else 1.1)
		for tri: Array in [[p0 - side * w0, p0 + side * w0, p1 + side * w1],
				[p0 - side * w0, p1 + side * w1, p1 - side * w1]]:
			for v: Vector3 in tri:
				st.set_color(col.darkened(0.1 * (1.0 - t0)))
				st.set_uv(Vector2.ZERO)
				st.add_vertex(v)


## Margarita (daisy): tallo + disco de pétalos planos radiales + centro amarillo
## abombado. Silvestre muy común. Doble cara. petal_color = color de los pétalos.
static func make_daisy(daisy_seed: int,
		petal_color: Color = Color(0.97, 0.97, 0.95)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = daisy_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat(false))
	var stalks := rng.randi_range(1, 2)
	for _s in stalks:
		var off := Vector3(rng.randf_range(-0.06, 0.06), 0, rng.randf_range(-0.06, 0.06))
		var h := rng.randf_range(0.28, 0.5)
		var top := off + Vector3(0, h, 0)
		_add_stalk(st, off, top, 0.01, Color(0.24, 0.4, 0.17))
		# 2 hojas basales.
		for _l in 2:
			var la := rng.randf() * TAU
			_add_leaf_blade(st, off.lerp(top, 0.25),
					Vector3(cos(la), 0.2, sin(la)).normalized(), 0.12, Color(0.26, 0.42, 0.16))
		# Disco de pétalos planos (tilt leve hacia arriba).
		var petals := rng.randi_range(14, 20)
		var r := rng.randf_range(0.07, 0.1)
		for i in petals:
			var a := TAU * float(i) / float(petals)
			var dir := Vector3(cos(a), 0.0, sin(a))
			var side := Vector3(-sin(a), 0, cos(a)) * r * 0.16
			var base := top + Vector3(0, 0.006, 0)
			var tip := top + dir * r + Vector3(0, r * 0.18, 0)
			var pc := petal_color.darkened(rng.randf() * 0.06)
			for tri: Array in [[base - side, base + side, tip]]:
				for v: Vector3 in tri:
					st.set_color(pc)
					st.set_uv(Vector2.ZERO)
					st.add_vertex(v)
		# Centro amarillo abombado.
		for i in 10:
			var a0 := TAU * float(i) / 10.0
			var a1 := TAU * float(i + 1) / 10.0
			for v: Vector3 in [top + Vector3(0, r * 0.28, 0),
					top + Vector3(cos(a0), 0, sin(a0)) * r * 0.34,
					top + Vector3(cos(a1), 0, sin(a1)) * r * 0.34]:
				st.set_color(Color(0.96, 0.8, 0.16))
				st.set_uv(Vector2.ZERO)
				st.add_vertex(v)
	st.generate_normals()
	return st.commit()


## Amancay (Alstroemeria aurea, Patagonia): tallo con hojas lanceoladas + racimo
## de 2-4 azucenas amarillo-anaranjadas de 6 tépalos con estrías rojizas. Ícono
## del bosque andino-patagónico.
static func make_amancay(amancay_seed: int,
		petal_color: Color = Color(0.97, 0.76, 0.12)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = amancay_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat(false))
	var stalks := rng.randi_range(1, 2)
	for _s in stalks:
		var off := Vector3(rng.randf_range(-0.07, 0.07), 0, rng.randf_range(-0.07, 0.07))
		var h := rng.randf_range(0.4, 0.65)
		var top := off + Vector3(0, h, 0)
		_add_stalk(st, off, top, 0.011, Color(0.22, 0.4, 0.16))
		for _l in rng.randi_range(2, 4):
			var la := rng.randf() * TAU
			_add_leaf_blade(st, off.lerp(top, rng.randf_range(0.2, 0.7)),
					Vector3(cos(la), 0.32, sin(la)).normalized(), rng.randf_range(0.11, 0.17),
					Color(0.24, 0.42, 0.15))
		# Racimo de azucenas cerca de la punta (pedicelos cortos).
		for f in rng.randi_range(2, 4):
			var fa := TAU * float(f) / 3.0 + rng.randf_range(-0.3, 0.3)
			var fdir := Vector3(cos(fa), rng.randf_range(0.3, 0.7), sin(fa)).normalized()
			var fc := top + fdir * rng.randf_range(0.04, 0.11)
			_lily(st, rng, fc, fdir, rng.randf_range(0.05, 0.075), petal_color)
	st.generate_normals()
	return st.commit()


## Azucena de 6 tépalos apuntados alrededor de `center`, encarada a `facedir`,
## amarilla con estrías/centro rojizo. Copa leve (cup).
static func _lily(st: SurfaceTool, rng: RandomNumberGenerator, center: Vector3,
		facedir: Vector3, r: float, col: Color) -> void:
	var n := facedir.normalized()
	var right := n.cross(Vector3.UP)
	if right.length_squared() < 0.01:
		right = Vector3.RIGHT
	right = right.normalized()
	var up := right.cross(n).normalized()
	for i in 6:
		var a := TAU * float(i) / 6.0
		var d := right * cos(a) + up * sin(a)
		var sd := (right * cos(a + PI * 0.5) + up * sin(a + PI * 0.5)) * r * 0.17
		var base := center + n * r * 0.06
		var mid := center + d * r * 0.55 + n * r * 0.12
		var tip := center + d * r
		var pc := col.lerp(Color(0.9, 0.45, 0.1), rng.randf() * 0.25)  # estría anaranjada
		for tri: Array in [[base - sd, base + sd, mid + sd],
				[base - sd, mid + sd, mid - sd], [mid - sd, mid + sd, tip]]:
			for v: Vector3 in tri:
				st.set_color(pc)
				st.set_uv(Vector2.ZERO)
				st.add_vertex(v)
	# Centro rojizo.
	for i in 6:
		var a0 := TAU * float(i) / 6.0
		var a1 := TAU * float(i + 1) / 6.0
		for v: Vector3 in [center + n * r * 0.14,
				center + (right * cos(a0) + up * sin(a0)) * r * 0.2,
				center + (right * cos(a1) + up * sin(a1)) * r * 0.2]:
			st.set_color(Color(0.7, 0.2, 0.1))
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)


## Trébol (campo/pastizal): matitas de hojas trifoliadas al ras + cabezuelas
## blancas/rosadas esféricas en tallos finos.
static func make_clover(clover_seed: int,
		flower_col: Color = Color(0.96, 0.96, 0.98)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = clover_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat(false))
	# Hojas trifoliadas.
	for _i in rng.randi_range(5, 9):
		var a := rng.randf() * TAU
		var base := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.0, 0.13)
		var h := rng.randf_range(0.05, 0.14)
		var top := base + Vector3(0, h, 0)
		_add_stalk(st, base, top, 0.005, Color(0.2, 0.4, 0.14))
		for k in 3:
			var la := TAU * float(k) / 3.0 + rng.randf_range(-0.2, 0.2)
			var ld := Vector3(cos(la), 0.25, sin(la)).normalized()
			_add_leaf_blade(st, top, ld, rng.randf_range(0.045, 0.07),
					Color(0.24, 0.44, 0.16))
	# Cabezuelas de flor.
	for _f in rng.randi_range(1, 3):
		var a := rng.randf() * TAU
		var base := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.02, 0.1)
		var h := rng.randf_range(0.12, 0.2)
		var top := base + Vector3(0, h, 0)
		_add_stalk(st, base, top, 0.004, Color(0.2, 0.38, 0.13))
		# Bola de florcitas (triángulos radiando).
		for _p in 14:
			var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1),
					rng.randf_range(-1, 1)).normalized()
			var pc := flower_col.darkened(rng.randf() * 0.12)
			var s := Vector3(-d.z, 0, d.x).normalized() * 0.006
			for v: Vector3 in [top - s, top + s, top + d * 0.03]:
				st.set_color(pc)
				st.set_uv(Vector2.ZERO)
				st.add_vertex(v)
	st.generate_normals()
	return st.commit()


## Flor: tallo + corola de 5 pétalos alrededor de un centro (colores vivos).
static func make_flower(flower_seed: int,
		petal_color: Color = Color(0.95, 0.5, 0.6)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = flower_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat(false))   # doble cara: la flor se ve de cualquier ángulo
	var stem_col := Color(0.24, 0.4, 0.17)
	# Mata: 1-3 tallos con hojitas + una flor arriba de cada uno (racimo).
	var stalks := rng.randi_range(1, 3)
	for s in stalks:
		var off := Vector3(rng.randf_range(-0.08, 0.08), 0.0, rng.randf_range(-0.08, 0.08))
		var h := rng.randf_range(0.32, 0.6)
		var lean := Vector3(rng.randf_range(-0.06, 0.06), 0, rng.randf_range(-0.06, 0.06))
		var top := off + Vector3(0, h, 0) + lean
		# Tallo: prisma triangular finito (con cuerpo, no un plano).
		_add_stalk(st, off, top, 0.012, stem_col)
		# 1-2 hojas lanceoladas a media altura.
		for _l in rng.randi_range(1, 2):
			var la := rng.randf() * TAU
			var lbase := off.lerp(top, rng.randf_range(0.3, 0.6))
			var ldir := Vector3(cos(la), 0.25, sin(la)).normalized()
			_add_leaf_blade(st, lbase, ldir, rng.randf_range(0.09, 0.16),
					stem_col.lightened(0.05))
		# Flor: corola en COPA de 6-8 pétalos curvos + centro abultado.
		var petals := rng.randi_range(6, 8)
		var flower_r := rng.randf_range(0.06, 0.1)
		var pcol := petal_color.lerp(petal_color.lightened(0.25), rng.randf() * 0.5)
		for i in petals:
			var a := TAU * float(i) / float(petals) + rng.randf_range(-0.05, 0.05)
			var dir := Vector3(cos(a), 0.0, sin(a))
			# Pétalo = quad (2 tris) que sube y se abre (copa), punta redondeada.
			var side := Vector3(-sin(a), 0, cos(a)) * flower_r * 0.42
			var base := top + Vector3(0, 0.004, 0)
			var mid := top + dir * flower_r * 0.6 + Vector3(0, flower_r * 0.5, 0)
			var tip := top + dir * flower_r + Vector3(0, flower_r * 0.7, 0)
			var pc := pcol.darkened(rng.randf() * 0.08)
			for tri: Array in [[base - side, base + side, mid + side],
					[base - side, mid + side, mid - side],
					[mid - side, mid + side, tip]]:
				for v: Vector3 in tri:
					st.set_color(pc)
					st.set_uv(Vector2.ZERO)
					st.add_vertex(v)
		# Centro abultado amarillo (pequeño fan cónico).
		var cc := top + Vector3(0, flower_r * 0.35, 0)
		for i in 8:
			var a0 := TAU * float(i) / 8.0
			var a1 := TAU * float(i + 1) / 8.0
			for v: Vector3 in [top + Vector3(0, flower_r * 0.55, 0),
					top + Vector3(cos(a0), 0, sin(a0)) * flower_r * 0.28,
					top + Vector3(cos(a1), 0, sin(a1)) * flower_r * 0.28]:
				st.set_color(Color(0.97, 0.83, 0.22))
				st.set_uv(Vector2.ZERO)
				st.add_vertex(v)
		cc = cc  # (silencia warning de var sin uso en algunos linters)
	st.generate_normals()
	return st.commit()


## Tallo con cuerpo: prisma triangular fino entre dos puntos.
static func _add_stalk(st: SurfaceTool, p0: Vector3, p1: Vector3, r: float,
		col: Color) -> void:
	var axis := (p1 - p0).normalized()
	var up := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var t0 := axis.cross(up).normalized()
	var t1 := axis.cross(t0).normalized()
	for i in 3:
		var a0 := TAU * float(i) / 3.0
		var a1 := TAU * float(i + 1) / 3.0
		var d0 := t0 * cos(a0) + t1 * sin(a0)
		var d1 := t0 * cos(a1) + t1 * sin(a1)
		for v: Vector3 in [p0 + d0 * r, p1 + d1 * r, p0 + d1 * r,
				p0 + d0 * r, p1 + d0 * r, p1 + d1 * r]:
			st.set_color(col)
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)


## Hoja lanceolada: cinta corta que sube y se arquea afuera.
static func _add_leaf_blade(st: SurfaceTool, base: Vector3, dir: Vector3,
		length: float, col: Color) -> void:
	var side := Vector3(-dir.z, 0, dir.x).normalized() * length * 0.16
	var mid := base + dir * length * 0.6 + Vector3(0, length * 0.15, 0)
	var tip := base + dir * length + Vector3(0, length * 0.05, 0)
	for tri: Array in [[base - side, base + side, mid + side * 0.7],
			[base - side, mid + side * 0.7, mid - side * 0.7],
			[mid - side * 0.7, mid + side * 0.7, tip]]:
		for v: Vector3 in tri:
			st.set_color(col)
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)


## Mata de pasto v3 (creada de cero, más alta y con cuerpo): N briznas BEZIER de
## 6 tramos, curva suave raíz→media→punta que se arquea hacia afuera, se afina a
## pico, base algo más ancha (cuerpo). Variación de TONO por brizna (algunas más
## secas/amarillas = look natural, no un verde plano). Degradado raíz oscura→
## punta clara + backlight. Viento por GrassWind. Determinista por tuft_seed.
static func make_grass_tuft(base_color: Color = Color(0.32, 0.52, 0.2),
		height: float = 1.0, blade_count: int = 9, tuft_seed: int = 9090) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = tuft_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sh: Shader = load("res://shaders/GrassWind.gdshader")
	var mat: Material
	if sh != null:
		var sm := ShaderMaterial.new()
		sm.shader = sh
		mat = sm
	else:
		var m := _mat(false)
		m.backlight_enabled = true
		m.backlight = Color(0.25, 0.35, 0.15)
		mat = m
	st.set_material(mat)
	var segs := 6
	# Color "seco" (amarillento) para variar entre briznas.
	var dry := Color(minf(1.0, base_color.r * 1.35), minf(1.0, base_color.g * 1.08),
			base_color.b * 0.7)
	for _b in maxi(1, blade_count):
		var az := rng.randf() * TAU
		var lean := Vector3(cos(az), 0, sin(az))
		var root := lean * rng.randf_range(0.0, 0.14)   # dispersión en la base
		var h := height * rng.randf_range(0.7, 1.18)
		var bend := rng.randf_range(0.22, 0.5) * h      # arco hacia afuera
		var p0 := root
		var p1 := root + Vector3.UP * (h * 0.5) + lean * (bend * 0.35)
		var p2 := root + Vector3.UP * (h * 0.9) + lean * bend  # punta cae afuera
		var w := rng.randf_range(0.03, 0.052)           # semiancho base (cuerpo)
		var side := Vector3(-lean.z, 0, lean.x)
		# Tono de esta brizna: mezcla con seco según azar.
		var bc := base_color.lerp(dry, rng.randf() * 0.4)
		var tip_c := bc.lightened(0.14)
		var root_c := bc.darkened(0.32)
		var prev_c := p0
		for s in range(1, segs + 1):
			var t := float(s) / float(segs)
			var tp := float(s - 1) / float(segs)
			var pc := _bez3(p0, p1, p2, t)
			var wt := w * (1.0 - t)          # se afina a un pico
			var wp := w * (1.0 - tp)
			var ca := root_c.lerp(tip_c, t)
			var cb := root_c.lerp(tip_c, tp)
			for tri: Array in [
					[prev_c - side * wp, prev_c + side * wp, pc + side * wt],
					[prev_c - side * wp, pc + side * wt, pc - side * wt]]:
				for v: Vector3 in tri:
					st.set_color(ca if v == pc + side * wt or v == pc - side * wt else cb)
					st.set_uv(Vector2.ZERO)
					st.add_vertex(v)
			prev_c = pc
	st.generate_normals()
	return st.commit()


## Cortadera / cola de zorro (Cortaderia selloana), el pastizal icónico de la
## Pampa: matón grande de briznas largas ARQUEADAS + PLUMAS plateadas altas.
static func make_pampas_grass(pampas_seed: int,
		blade_color: Color = Color(0.44, 0.52, 0.28),
		plume_color: Color = Color(0.88, 0.83, 0.72)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = pampas_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sh: Shader = load("res://shaders/GrassWind.gdshader")
	var mat: Material
	if sh != null:
		var sm := ShaderMaterial.new()
		sm.shader = sh
		mat = sm
	else:
		var m := _mat(false)
		m.backlight_enabled = true
		m.backlight = Color(0.4, 0.42, 0.3)
		mat = m
	st.set_material(mat)
	# --- Matón de briznas largas arqueadas ---
	var blades := 30
	var segs := 6
	for _b in blades:
		var az := rng.randf() * TAU
		var lean := Vector3(cos(az), 0, sin(az))
		var root := lean * rng.randf_range(0.0, 0.22)
		var h := rng.randf_range(1.1, 1.9)
		var bend := rng.randf_range(0.5, 0.95) * h          # arqueo fuerte (cae afuera)
		var p0 := root
		var p1 := root + Vector3.UP * (h * 0.55) + lean * (bend * 0.35)
		var p2 := root + Vector3.UP * (h * 0.82) + lean * bend
		var w := rng.randf_range(0.02, 0.035)
		var side := Vector3(-lean.z, 0, lean.x)
		var bc := blade_color.lerp(blade_color.lightened(0.2), rng.randf() * 0.4)
		var tip_c := bc.lightened(0.12)
		var root_c := bc.darkened(0.3)
		var prev := p0
		for s in range(1, segs + 1):
			var t := float(s) / float(segs)
			var tp := float(s - 1) / float(segs)
			var pc := _bez3(p0, p1, p2, t)
			var wt := w * (1.0 - t)
			var wp := w * (1.0 - tp)
			for tri: Array in [
					[prev - side * wp, prev + side * wp, pc + side * wt],
					[prev - side * wp, pc + side * wt, pc - side * wt]]:
				for v: Vector3 in tri:
					st.set_color(root_c.lerp(tip_c, t))
					st.set_uv(Vector2.ZERO)
					st.add_vertex(v)
			prev = pc
	# --- Plumas plateadas (varas altas con espiga fusiforme de pelillos) ---
	var plumes := rng.randi_range(5, 8)
	for _pl in plumes:
		var az := rng.randf() * TAU
		var out_dir := Vector3(cos(az), 0, sin(az))
		var sh_h := rng.randf_range(2.2, 3.1)
		var top := out_dir * rng.randf_range(0.05, 0.35) + Vector3.UP * sh_h \
				+ out_dir * (sh_h * 0.08)          # leve inclinación afuera
		var base := out_dir * rng.randf_range(0.0, 0.1)
		# Vara delgada base→top.
		var vside := Vector3(-out_dir.z, 0, out_dir.x)
		for tri: Array in [
				[base - vside * 0.012, base + vside * 0.012, top + vside * 0.004],
				[base - vside * 0.012, top + vside * 0.004, top - vside * 0.004]]:
			for v: Vector3 in tri:
				st.set_color(blade_color.darkened(0.2))
				st.set_uv(Vector2.ZERO)
				st.add_vertex(v)
		# Espiga: pelillos pálidos alrededor del top (spindle que sube).
		var plume_len := rng.randf_range(0.45, 0.7)
		var hairs := 42
		for hi in hairs:
			var t := float(hi) / float(hairs)
			var along := top + Vector3.UP * (plume_len * t)
			var spindle := sin(t * PI) * 0.09 + 0.02      # más ancho al medio
			var ha := rng.randf() * TAU
			var hdir := (Vector3(cos(ha), 0, sin(ha)) * spindle
					+ Vector3.UP * rng.randf_range(0.04, 0.1)).normalized()
			var hlen := rng.randf_range(0.06, 0.12)
			var tip := along + hdir * hlen
			var pc := plume_color.lerp(plume_color.darkened(0.15), rng.randf())
			var hs := Vector3(-hdir.z, 0, hdir.x).normalized() * 0.006
			for v: Vector3 in [along - hs, along + hs, tip]:
				st.set_color(pc)
				st.set_uv(Vector2.ZERO)
				st.add_vertex(v)
	st.generate_normals()
	return st.commit()


## Bezier cuadrática (posición en t∈[0,1]).
static func _bez3(p0: Vector3, p1: Vector3, p2: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return p0 * (u * u) + p1 * (2.0 * u * t) + p2 * (t * t)


## ============================================================================
## make_tree · Árbol Weber & Penn (TreeGenerator). Entrada pública para el
## sistema de vegetación. Determinista por seed; params por bioma/especie.
## ============================================================================
static func make_tree(params: TreeParams, tree_seed: int) -> ArrayMesh:
	var gen := TreeGenerator.new()
	return gen.generate(params, tree_seed)


## Palmera (oasis, backlog #61): tronco curvado por segmentos + corona de
## frondas que caen en arco. Doble cara (las hojas se ven desde abajo).
static func make_palm(palm_seed: int,
		frond_color: Color = Color(0.25, 0.48, 0.2),
		trunk_color: Color = Color(0.45, 0.36, 0.24)) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = palm_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var m := _mat()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(m)
	# Tronco: 5 segmentos con curvatura progresiva (la palmera se inclina).
	var h := rng.randf_range(4.0, 5.6)
	var lean := Vector3(rng.randf_range(-1.0, 1.0), 0,
			rng.randf_range(-1.0, 1.0)).normalized() * rng.randf_range(0.3, 0.9)
	var segs := 5
	var sides := 5
	var top := Vector3.ZERO
	for s in segs:
		var t0 := float(s) / float(segs)
		var t1 := float(s + 1) / float(segs)
		var c0 := Vector3.UP * (h * t0) + lean * (t0 * t0)
		var c1 := Vector3.UP * (h * t1) + lean * (t1 * t1)
		var r0 := lerpf(0.28, 0.14, t0)
		var r1 := lerpf(0.28, 0.14, t1)
		top = c1
		for i in sides:
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			var d0 := Vector3(cos(a0), 0, sin(a0))
			var d1 := Vector3(cos(a1), 0, sin(a1))
			var fh := float(hash([palm_seed, s, i]) % 1000) / 1000.0
			var c := trunk_color.lerp(trunk_color.lightened(0.14), fh)
			for v: Vector3 in [c0 + d0 * r0, c0 + d1 * r0, c1 + d1 * r1,
					c0 + d0 * r0, c1 + d1 * r1, c1 + d0 * r1]:
				st.set_color(c)
				st.set_uv(Vector2.ZERO)
				st.add_vertex(v)
	# Corona: 8 frondas — cintas de 3 tramos que suben y caen en arco.
	var fronds := 8
	for f in fronds:
		var a := TAU * float(f) / float(fronds) + rng.randf_range(-0.15, 0.15)
		var dir := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-dir.z, 0, dir.x)
		var droop := rng.randf_range(0.55, 0.85)
		var length := rng.randf_range(2.2, 3.0)
		var col := frond_color.lerp(frond_color.lightened(0.25),
				float(hash([palm_seed, f]) % 1000) / 1000.0)
		var prev := top
		var prev_w := 0.3
		for k in 3:
			var t := float(k + 1) / 3.0
			var p := top + dir * (length * t) \
					+ Vector3.UP * (0.7 * t - droop * t * t * 1.6)
			var wdt := lerpf(0.34, 0.06, t)
			for tri: Array in [
					[prev - side * prev_w, prev + side * prev_w, p + side * wdt],
					[prev - side * prev_w, p + side * wdt, p - side * wdt]]:
				for v: Vector3 in tri:
					st.set_color(col if k < 2 else col.darkened(0.1))
					st.set_uv(Vector2.ZERO)
					st.add_vertex(v)
			prev = p
			prev_w = wdt
	st.generate_normals()
	return st.commit()
