class_name TreeGenerator
extends RefCounted

## ============================================================================
## TreeGenerator · Árboles Weber & Penn generados por código (Fase 0)
## ============================================================================
## Reimplementación GDScript propia del ALGORITMO Weber & Penn ("Creation and
## Rendering of Realistic Trees", SIGGRAPH 1995) — método publicado en paper, NO
## protegible por copyright (ver THIRD_PARTY_LICENSES.md). Estructura y código
## propios (no traducción literal de gen.py). Genera en espacio Z-up nativo de
## Weber-Penn y rota a Y-up de Godot al mallar (_to_godot). Determinista por
## seed. Salida ArrayMesh: superficie 0 = corteza (color por vértice),
## superficie 1 = copa de leaf cards (reusa FloraFactory + LeafWind).
## Recorte deliberado (Fase 0): sin helix, sin poda, sin verticilo/abanico,
## sin blossom — se agregan cuando una especie los pida.
## ============================================================================

var _p: TreeParams
var _rng := RandomNumberGenerator.new()
var _base_length: float = 0.0
var _tree_scale: float = 0.0
var _split_error: PackedFloat32Array
var _branches: Array = []   # Array[_Stem]
var _leaves: Array = []     # Array[Dictionary] {pos, dir, right}


## --- Turtle 3D (pos/dir/right), espacio Z-up ---
class _Turtle:
	var pos := Vector3.ZERO
	var dir := Vector3(0, 0, 1)
	var right := Vector3(1, 0, 0)

	func clone() -> _Turtle:
		var t := _Turtle.new()
		t.pos = pos
		t.dir = dir
		t.right = right
		return t

	func move(dist: float) -> void:
		pos += dir * dist

	func turn_right(angle_deg: float) -> void:
		var axis := dir.cross(right).normalized()
		var q := Quaternion(axis, deg_to_rad(angle_deg))
		dir = (q * dir).normalized()
		right = (q * right).normalized()

	func turn_left(angle_deg: float) -> void:
		turn_right(-angle_deg)

	func pitch_down(angle_deg: float) -> void:
		var q := Quaternion(right, deg_to_rad(-angle_deg))
		dir = (q * dir).normalized()

	func pitch_up(angle_deg: float) -> void:
		pitch_down(-angle_deg)

	func roll_right(angle_deg: float) -> void:
		var q := Quaternion(dir, deg_to_rad(angle_deg))
		right = (q * right).normalized()


## --- Una rama: polilínea de puntos con radio, en Z-up ---
class _Stem:
	var depth: int
	var parent: _Stem
	var offset: float = 0.0
	var radius_limit: float = -1.0
	var length: float = 0.0
	var radius: float = 0.0
	var length_child_max: float = 0.0
	var is_branch_base: bool = false   # rama hija: engrosa el 1er anillo (collar)
	var points: PackedVector3Array = PackedVector3Array()
	var radii: PackedFloat32Array = PackedFloat32Array()

	func _init(d: int = 0, par: _Stem = null) -> void:
		depth = d
		parent = par

	func add_point(p: Vector3, r: float) -> void:
		points.append(p)
		radii.append(r)


## Z-up (Weber-Penn) → Y-up (Godot): (x,y,z) → (x, z, -y).
static func _to_godot(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y)


## curve_res efectivo de un nivel, topeado por max_curve_res (presupuesto juego).
func _cr(depth: int) -> int:
	return maxi(1, mini(_p.curve_res[depth], _p.max_curve_res))


## Declinación (grados) respecto al eje Z (arriba en WP).
static func declination(d: Vector3) -> float:
	return rad_to_deg(atan2(sqrt(d.x * d.x + d.y * d.y), d.z))


## Silueta global (Weber-Penn shape_ratio, casos 0-7; 8 cae a cónico).
static func shape_ratio(shape: int, ratio: float) -> float:
	match shape:
		1: return 0.2 + 0.8 * sin(PI * ratio)                       # esférico
		2: return 0.2 + 0.8 * sin(0.5 * PI * ratio)                 # hemisférico
		3: return 1.0                                                # cilíndrico
		4: return 0.5 + 0.5 * ratio                                 # cónico truncado
		5:                                                          # llama
			return ratio / 0.7 if ratio <= 0.7 else (1.0 - ratio) / 0.3
		6: return 1.0 - 0.8 * ratio                                 # cónico inverso
		7:                                                          # llama tendida
			return (0.5 + 0.5 * ratio / 0.7) if ratio <= 0.7 else (0.5 + 0.5 * (1.0 - ratio) / 0.3)
		_: return 0.2 + 0.8 * ratio                                 # cónico (0/8)


## Radio del stem a offset z1∈[0,1] (taper 4 modos + flare de tronco). Port WP.
func _radius_at_offset(stem: _Stem, z1: float) -> float:
	var n_taper: float = _p.taper[stem.depth]
	var unit_taper := 0.0
	if n_taper < 1.0:
		unit_taper = n_taper
	elif n_taper < 2.0:
		unit_taper = 2.0 - n_taper
	var taper := stem.radius * (1.0 - unit_taper * z1)
	var radius := taper
	if n_taper >= 1.0:
		var z2 := (1.0 - z1) * stem.length
		var depth_v := 1.0 if (n_taper < 2.0 or z2 < taper) else (n_taper - 2.0)
		var z3 := z2 if n_taper < 2.0 else absf(z2 - 2.0 * taper * int(z2 / (2.0 * taper) + 0.5))
		if n_taper < 2.0 and z3 >= taper:
			radius = taper
		else:
			radius = (1.0 - depth_v) * taper + depth_v * sqrt(maxf(0.0, taper * taper - (z3 - taper) * (z3 - taper)))
	if stem.depth == 0:
		var y_val := maxf(0.0, 1.0 - 8.0 * z1)
		var flare := _p.flare * ((pow(100.0, y_val) - 1.0) / 100.0) + 1.0
		radius *= flare
	return radius


func _calc_stem_length(stem: _Stem) -> float:
	var result := 0.0
	if stem.depth == 0:
		result = _tree_scale * (_p.length[0] + _rng.randf_range(-1, 1) * _p.length_v[0])
	elif stem.depth == 1:
		var ratio := (stem.parent.length - stem.offset) / maxf(0.0001, stem.parent.length - _base_length)
		result = stem.parent.length * stem.parent.length_child_max * shape_ratio(_p.shape, ratio)
	else:
		result = stem.parent.length_child_max * (stem.parent.length - 0.7 * stem.offset)
	return maxf(0.0, result)


func _calc_stem_radius(stem: _Stem) -> float:
	if stem.depth == 0:
		return stem.length * _p.ratio
	var result: float = stem.parent.radius * pow(stem.length / maxf(0.0001, stem.parent.length), _p.ratio_power)
	result = maxf(0.005, result)
	if stem.radius_limit >= 0.0:
		result = minf(stem.radius_limit, result)
	return result


func _calc_curve_angle(depth: int, seg_ind: int) -> float:
	var cv: float = _p.curve[depth]
	var cb: float = _p.curve_back[depth]
	var cvv: float = _p.curve_v[depth]
	var cr: int = _cr(depth)
	var a := 0.0
	if cb == 0.0:
		a = cv / cr
	else:
		a = (cv / (cr / 2.0)) if seg_ind < cr / 2.0 else (cb / (cr / 2.0))
	a += _rng.randf_range(-1, 1) * (cvv / cr)
	return a


func _calc_down_angle(stem: _Stem, stem_offset: float) -> float:
	var dp1 := mini(stem.depth + 1, 3)
	if _p.down_angle_v[dp1] >= 0.0:
		return _p.down_angle[dp1] + _rng.randf_range(-1, 1) * _p.down_angle_v[dp1]
	var ratio := (stem.length - stem_offset) / maxf(0.0001, stem.length * (1.0 - _p.base_size[stem.depth]))
	var d := _p.down_angle[dp1] + _p.down_angle_v[dp1] * (1.0 - 2.0 * shape_ratio(0, ratio))
	d += _rng.randf_range(-1, 1) * absf(d * 0.1)
	return d


func _calc_rotate_angle(depth: int, prev: float) -> float:
	if _p.rotate[depth] >= 0.0:
		return fmod(prev + _p.rotate[depth] + _rng.randf_range(-1, 1) * _p.rotate_v[depth], 360.0)
	return prev * (180.0 + _p.rotate[depth] + _rng.randf_range(-1, 1) * _p.rotate_v[depth])


func _calc_branch_count(stem: _Stem) -> float:
	var dp1 := mini(stem.depth + 1, 3)
	var result := 0.0
	if stem.depth == 0:
		result = _p.branches[dp1] * (_rng.randf() * 0.2 + 0.9)
	elif _p.branches[dp1] < 0:
		result = _p.branches[dp1]
	elif stem.depth == 1:
		result = _p.branches[dp1] * (0.2 + 0.8 * (stem.length / maxf(0.0001, stem.parent.length)) / maxf(0.0001, stem.parent.length_child_max))
	else:
		result = _p.branches[dp1] * (1.0 - 0.5 * stem.offset / maxf(0.0001, stem.parent.length))
	# detail: presupuesto de juego (menos ramas en árboles de fondo)
	return result * _p.detail / maxf(0.0001, 1.0 - _p.base_size[stem.depth])


func _calc_leaf_count(stem: _Stem) -> float:
	if _p.leaf_count < 0:
		return _p.leaf_count
	var leaves := _p.leaf_count * _tree_scale / _p.g_scale
	# la copa se penaliza suave (maxf 0.7): las hojas dan el look y son baratas
	# vs las ramas; sin esto el árbol se ve pelado a detail bajo.
	return leaves * maxf(_p.detail, 0.7) * (stem.length / maxf(0.0001, stem.parent.length_child_max * stem.parent.length))


## Tropismo: dobla el turtle hacia el vector (Z-up). Port WP apply_tropism.
func _apply_tropism(turtle: _Turtle, trop: Vector3) -> void:
	var h_cross_t := turtle.dir.cross(trop)
	var mag := h_cross_t.length()
	if mag < 0.0001:
		return
	var alpha := 10.0 * mag
	h_cross_t = h_cross_t.normalized()
	var q := Quaternion(h_cross_t, deg_to_rad(alpha))
	turtle.dir = (q * turtle.dir).normalized()
	turtle.right = (q * turtle.right).normalized()


## Recursión principal: construye el stem y sus hijos/hojas. start>0 = clon.
## clone_prob decae en cada split para evitar la explosión exponencial de clones
## (port de Weber-Penn: clone_prob /= num_splits+1).
func _make_stem(turtle: _Turtle, stem: _Stem, start: int = 0, clone_prob: float = 1.0) -> void:
	if stem.radius_limit >= 0.0 and stem.radius_limit < 0.0001:
		return
	var depth := stem.depth
	var dp1 := mini(depth + 1, 3)

	if start == 0:
		stem.length_child_max = _p.length[dp1] + _rng.randf_range(-1, 1) * _p.length_v[dp1]
		stem.length = _calc_stem_length(stem)
		stem.radius = _calc_stem_radius(stem)
		if depth == 0:
			_base_length = stem.length * _p.base_size[0]

	if stem.length < 0.01 or stem.radius < 0.001:
		return

	var curve_res := _cr(depth)
	var seg_splits: float = _p.seg_splits[depth]
	var seg_length := stem.length / curve_res
	var base_seg_ind := int(ceil(_p.base_size[0] * _cr(0)))

	var is_leaf_level := depth == _p.levels - 1 and depth > 0 and _p.leaf_count != 0
	var branch_count := 0.0
	var leaf_count := 0.0
	if is_leaf_level:
		leaf_count = _calc_leaf_count(stem)
	else:
		branch_count = _calc_branch_count(stem)
	var f_per_seg := (leaf_count if is_leaf_level else branch_count) / curve_res

	var prev_rot := [0.0]
	if _p.rotate[dp1] >= 0.0:
		prev_rot[0] = _rng.randf_range(0, 360)
	else:
		prev_rot[0] = 1.0

	# Registrar el stem en la lista global y sembrar el primer punto.
	_branches.append(stem)
	stem.add_point(turtle.pos, _radius_at_offset(stem, float(start) / curve_res))

	var num_error := 0.0
	for seg_ind in range(start + 1, curve_res + 1):
		turtle.move(seg_length)
		stem.add_point(turtle.pos, _radius_at_offset(stem, float(seg_ind) / curve_res))

		# splits del propio stem (clone_prob gatea y decae → sin explosión)
		var num_splits := 0
		if _p.base_splits > 0 and depth == 0 and seg_ind == base_seg_ind:
			num_splits = _p.base_splits
		elif seg_splits > 0.0 and seg_ind < curve_res and (depth > 0 or seg_ind > base_seg_ind):
			if _rng.randf() <= clone_prob:
				num_splits = int(seg_splits + _split_error[depth])
				_split_error[depth] -= num_splits - seg_splits
				if num_splits > 0:
					clone_prob /= float(num_splits + 1)

		# hijos (ramas o hojas) — RNG protegido para no perturbar el stream del padre
		var r_state := _rng.state
		if branch_count > 0.0 and depth < _p.levels - 1:
			var n := int(f_per_seg + num_error)
			num_error -= n - f_per_seg
			for _bi in maxi(0, n):
				_spawn_child(turtle, stem, seg_ind, prev_rot, false)
		elif leaf_count > 0.0:
			var n := int(f_per_seg + num_error)
			num_error -= n - f_per_seg
			for _li in maxi(0, n):
				_spawn_child(turtle, stem, seg_ind, prev_rot, true)
		_rng.state = r_state

		# aplicar split o curvatura
		if num_splits > 0:
			var decl := declination(turtle.dir)
			var spl := maxf(0.0, _p.split_angle[depth] + _rng.randf_range(-1, 1) * _p.split_angle_v[depth] - decl)
			var cs := _rng.state
			_make_clones(turtle, stem, seg_ind, num_splits, spl, clone_prob)
			_rng.state = cs
			turtle.pitch_down(spl / 2.0)
		else:
			turtle.turn_left(_rng.randf_range(-1, 1) * _p.bend_v[depth] / curve_res)
			turtle.pitch_down(_calc_curve_angle(depth, seg_ind))

		# Tropismo: el TRONCO (depth 0) solo recibe el componente horizontal (queda
		# vertical); las RAMAS (depth 1+) reciben el tropismo COMPLETO, incluido el
		# vertical → las especies lloronas (tropism.z<0, ej. maiten/sauce) cuelgan
		# de verdad y las que buscan luz (z>0) suben. Antes el z se anulaba hasta
		# depth 2 y las ramas principales quedaban rectas (copa redonda genérica).
		if depth > 0:
			_apply_tropism(turtle, _p.tropism)
		else:
			_apply_tropism(turtle, Vector3(_p.tropism.x, _p.tropism.y, 0.0))


## Crea una rama hija (o una hoja si is_leaf) a partir del turtle actual.
func _spawn_child(turtle: _Turtle, stem: _Stem, seg_ind: int, prev_rot: Array, is_leaf: bool) -> void:
	var dp1 := mini(stem.depth + 1, 3)
	var curve_res := _cr(stem.depth)
	var stem_offset := (float(seg_ind) - 1.0) / curve_res * stem.length
	var base_length := stem.length * _p.base_size[stem.depth]
	if stem_offset <= base_length:
		return  # zona base pelada

	var child_turtle := turtle.clone()
	var r_angle := _calc_rotate_angle(dp1, prev_rot[0])
	if _p.rotate[dp1] >= 0.0:
		prev_rot[0] = r_angle
	else:
		prev_rot[0] = -prev_rot[0]
	child_turtle.roll_right(r_angle)
	var d_angle := _calc_down_angle(stem, stem_offset)
	child_turtle.pitch_down(d_angle)
	# posicionar en la circunferencia del padre
	var r_lim := _radius_at_offset(stem, float(seg_ind) / curve_res)
	# Las HOJAS nacen en la superficie (no se hunden).
	if is_leaf:
		child_turtle.pos = turtle.pos + child_turtle.right * r_lim
		_leaves.append({"pos": child_turtle.pos, "dir": child_turtle.dir, "right": child_turtle.right})
		return

	# Las RAMAS nacen DENTRO del padre (penetración ~0.75×radio): la base cerca
	# del eje → el tubo hijo cruza la pared del padre en TODO el contorno y no
	# quedan gaps en el ángulo agudo. La base va abierta y enterrada (invisible).
	# Receta confluente de tree-gen/proctree/SpeedTree. INSET es el knob visual.
	const INSET := 0.25
	child_turtle.pos = turtle.pos + child_turtle.right * (r_lim * INSET)

	var child := _Stem.new(dp1, stem)
	child.offset = stem_offset
	child.radius_limit = r_lim
	child.is_branch_base = true   # marca para el collar-flare en _build_bark
	_make_stem(child_turtle, child)


## Clona el stem en `num_splits` ramas nuevas del mismo depth (bifurcación).
func _make_clones(turtle: _Turtle, stem: _Stem, seg_ind: int, num_splits: int,
		spl_angle: float, clone_prob: float) -> void:
	var spr_base := 360.0 / (num_splits + 1)
	for split_index in num_splits:
		var n_turtle := turtle.clone()
		n_turtle.pitch_down(spl_angle / 2.0)
		var eff_spr := (split_index + 1) * spr_base + _rng.randf_range(-1, 1) * _p.split_angle_v[stem.depth]
		n_turtle.roll_right(eff_spr)
		var clone := _Stem.new(stem.depth, stem.parent)
		clone.offset = stem.offset
		clone.radius_limit = stem.radius_limit
		clone.length = stem.length
		clone.radius = stem.radius
		clone.length_child_max = stem.length_child_max
		_make_stem(n_turtle, clone, seg_ind, clone_prob)


## Punto de entrada del esqueleto: siembra RNG, arma el tronco y recursa.
func build_skeleton(params: TreeParams, seed_val: int) -> void:
	_p = params
	_rng.seed = seed_val
	_branches.clear()
	_leaves.clear()
	_split_error = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	_tree_scale = _p.g_scale + _rng.randf_range(-1, 1) * _p.g_scale_v
	var turtle := _Turtle.new()  # pos 0, dir +Z, right +X
	turtle.roll_right(_rng.randf_range(0, 360))
	_make_stem(turtle, _Stem.new(0, null))


## Material de corteza: color por vértice + VIENTO (TreeSway → el tronco/ramas se
## mecen con la copa). Fallback a StandardMaterial si falta el shader (headless).
static func _bark_mat(tree_height: float = 8.0, bark_type: String = "fissured",
		tex_override: Texture2D = null, normal_override: Texture2D = null) -> Material:
	var sh: Shader = load("res://shaders/TreeSway.gdshader")
	if sh != null:
		var sm := ShaderMaterial.new()
		sm.shader = sh
		sm.set_shader_parameter("tree_height", tree_height)
		var bsz := VegetationQuality.bark_texture_size
		# Corteza por imagen externa (FloraConfig) gana sobre la procedural.
		if tex_override != null:
			sm.set_shader_parameter("bark_tex", tex_override)
			sm.set_shader_parameter("bark_normal", normal_override \
					if normal_override != null else BarkTexture.normal(bark_type, bsz))
		else:
			sm.set_shader_parameter("bark_tex", BarkTexture.grayscale(bark_type, bsz))
			sm.set_shader_parameter("bark_normal", BarkTexture.normal(bark_type, bsz))
		sm.set_shader_parameter("use_bark", true)
		return sm
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.95
	return m


## Barre un anillo de N lados por cada segmento de cada rama (Z-up → Y-up).
func _build_bark(st: SurfaceTool) -> void:
	const V_TILING := 0.55   # repeticiones de textura de corteza por metro (largo)
	# Umbral RELATIVO al tronco (2026-07-18): el absoluto (2 cm) no escala — en un
	# emergente de 45 m las ramas "finas" miden 5-10 cm y la corteza se iba a 21k
	# verts (Rust: árbol ENTERO 5-15k). Ramas < 8% del radio base quedan tapadas
	# por el follaje a cualquier escala del árbol.
	var base_r := 0.0
	if not _branches.is_empty():
		var trunk: _Stem = _branches[0]
		if trunk.radii.size() > 0:
			base_r = trunk.radii[0]
	# En los pools LOD (detail<1) el umbral sube: de lejos solo importan tronco y
	# ramas madre (0.08 full → 0.18 far → 0.27 far2).
	var rel := 0.08 / clampf(_p.detail, 0.3, 1.0)
	var min_r := maxf(_p.min_bark_radius, base_r * rel)
	for stem_any in _branches:
		var stem: _Stem = stem_any
		if stem.points.size() < 2:
			continue
		# Optimización: las ramitas finas (radio base < umbral) NO se mallan — las
		# tapa el follaje, su tubo sería geometría invisible. El tronco (depth 0)
		# siempre se malla. Recorta MUCHOS vértices sin pérdida visual.
		if stem.depth > 0 and stem.radii.size() > 0 and stem.radii[0] < min_r:
			continue
		# lados decrecen con la profundidad: tronco 6, ramitas 3 (ahorro grande)
		var sides := maxi(3, _p.trunk_sides - stem.depth)
		var vdist := 0.0   # distancia acumulada a lo largo del stem (para UV.v)
		for i in range(stem.points.size() - 1):
			var p0 := _to_godot(stem.points[i])
			var p1 := _to_godot(stem.points[i + 1])
			var r0: float = stem.radii[i]
			var r1: float = stem.radii[i + 1]
			# Collar-flare: engrosa los primeros anillos de la rama hija (branch
			# collar biológico) → esconde la unión con el padre y se ve "nacida"
			# del tronco, no pegada. Decae rápido a lo largo de la rama.
			if stem.is_branch_base:
				r0 *= 1.6 if i == 0 else (1.28 if i == 1 else 1.0)
				r1 *= 1.28 if i == 0 else (1.1 if i == 1 else 1.0)
			var seg_len := p0.distance_to(p1)
			var v0 := vdist * V_TILING
			var v1 := (vdist + seg_len) * V_TILING
			vdist += seg_len
			var axis := (p1 - p0)
			if axis.length() < 0.0001:
				continue
			axis = axis.normalized()
			var up := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
			var t0v := axis.cross(up).normalized()
			var t1v := axis.cross(t0v).normalized()
			var shade := clampf(p1.y / maxf(1.0, _tree_scale), 0.0, 1.0)
			var col := _p.trunk_color.lerp(_p.trunk_color.lightened(0.18), shade)
			for s in sides:
				var u0 := float(s) / float(sides)
				var u1 := float(s + 1) / float(sides)
				var a0 := TAU * u0
				var a1 := TAU * u1
				var d0 := t0v * cos(a0) + t1v * sin(a0)
				var d1 := t0v * cos(a1) + t1v * sin(a1)
				# quad = 6 vértices con su UV (u alrededor, v a lo largo). CCW afuera.
				var quad: Array = [
						[p0 + d0 * r0, Vector2(u0, v0)],
						[p1 + d1 * r1, Vector2(u1, v1)],
						[p0 + d1 * r0, Vector2(u1, v0)],
						[p0 + d0 * r0, Vector2(u0, v0)],
						[p1 + d0 * r1, Vector2(u0, v1)],
						[p1 + d1 * r1, Vector2(u1, v1)]]
				for pair: Array in quad:
					st.set_color(col)
					st.set_uv(pair[1])
					st.add_vertex(pair[0])


## Copa: un SPRAY de ramita por hoja registrada (twig cards estilo gdTree3D).
## El spray crece AFUERA+ARRIBA siguiendo la dirección de la rama → la copa se
## lee con estructura (ramitas), no como un disco. Cada spray son 2 quads
## cruzados grandes: reemplaza las 3 cards chatas previas (mejor look + menos
## tris = optimización). El atlas ya trae el detalle de hoja/aguja/flor.
func _build_canopy(into: ArrayMesh) -> ArrayMesh:
	if _leaves.is_empty() or _p.leaf_count == 0:
		return into
	if _p.leaf_mesh_override != null:
		return _build_canopy_mesh_model(into)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(FloraFactory._leaf_mat(_p.leaf_texture, _tree_scale, _p.leaf_texture_override))
	# Cada spray es una ramita entera → hacen falta MENOS que hojas sueltas.
	# Adelgazo la lista para no saturar (y ahorrar tris) sin perder densidad visual.
	# Knobs de FloraConfig (0 = defaults): menos sprays + más grandes = menos quads
	# con la misma cobertura visual (palanca de FPS por categoría, inspector).
	var keep := _p.canopy_density_override if _p.canopy_density_override > 0.0 else 0.7
	var spray_scale := _p.spray_scale_override if _p.spray_scale_override > 0.0 else 1.55
	# PRESUPUESTO ABSOLUTO de copa (raíz del lag, 2026-07-18): leaf_count de
	# Weber-Penn es POR RAMA — un roble con ~180 ramas terminales juntaba ~7.800
	# sprays = 65k verts de copa (Rust usa 5-15k por árbol ENTERO). Tope duro de
	# sprays con compensación de tamaño (√ratio): misma cobertura visual, verts
	# de juego profesional. 1400 sprays × 12 verts ≈ 17k de copa máx.
	const MAX_CANOPY_SPRAYS := 1250   # tope ≈15k verts de copa (banda pro 5-15k)
	# Presupuesto por POOL (señal explícita de build_tree_lod_pool): full 1400,
	# far 300, far2 120 sprays — el far cuesta una fracción del full real.
	var budget := _p.canopy_budget_override if _p.canopy_budget_override > 0 \
			else MAX_CANOPY_SPRAYS
	var expected := int(float(_leaves.size()) * keep)
	var budget_step := 1
	if expected > budget:
		var ratio := float(expected) / float(budget)
		budget_step = ceili(ratio)
		spray_scale *= minf(sqrt(ratio), 1.9)   # menos sprays → más grandes (tope: no bolas)
	# AO vertical de copa: el follaje de ABAJO/adentro recibe menos luz (sombra),
	# el de arriba es el que ve el sol. Se ve mucho más realista y con volumen
	# (pedido del usuario: "sombra abajo, verde claro arriba"). Rango real de la copa.
	var ymin := INF
	var ymax := -INF
	for leaf: Dictionary in _leaves:
		var ly: float = _to_godot(leaf["pos"]).y
		ymin = minf(ymin, ly)
		ymax = maxf(ymax, ly)
	var yspan := maxf(ymax - ymin, 0.001)
	# Sesgo vertical del follaje según el TROPISMO de la especie: las que buscan
	# luz (tropism.z>0) crecen hacia arriba; las LLORONAS (z<0, maiten/sauce/
	# quebracho blanco) cuelgan hacia abajo. Sin esto la copa salía redonda igual.
	var up_bias := clampf(0.55 + _p.tropism.z * 0.3, -0.45, 0.7)
	var li := -1
	for leaf: Dictionary in _leaves:
		li += 1
		if budget_step > 1 and li % budget_step != 0:
			continue   # presupuesto de copa: submuestreo uniforme
		if _rng.randf() > keep:
			continue
		var pos: Vector3 = _to_godot(leaf["pos"])
		var dir: Vector3 = _to_godot(leaf["dir"]).normalized()
		# El spray crece siguiendo la rama, sesgado vertical según la especie.
		# Jitter chico para que no queden todos paralelos.
		var grow := (dir * 0.8 + Vector3.UP * up_bias
				+ Vector3(_rng.randf_range(-0.25, 0.25), _rng.randf_range(-0.1, 0.25),
						_rng.randf_range(-0.25, 0.25))).normalized()
		var jit := _p.leaf_card_size * 0.3
		pos += Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-0.4, 0.6),
				_rng.randf_range(-1, 1)) * jit
		var v := _rng.randf_range(0.8, 1.05)
		var tint := Color(v, v, v).lerp(_p.leaf_color.lightened(0.3), 0.22)
		# AO vertical MUY suave: el 0.5× de antes oscurecía feo la base de la copa
		# (pedido del usuario). 0.86× abajo → 1.08× arriba = apenas un toque de
		# volumen, sin "abajo negro". La sombra real la da la luz/sombra del sol.
		# AO vertical MUY suave (0.95→1.05): antes 0.86 daba un underside oscuro que
		# el usuario leía como "sombra en la copa". Casi plano = sin look de sombra.
		var ao := lerpf(0.95, 1.05, clampf((pos.y - ymin) / yspan, 0.0, 1.0))
		tint = Color(tint.r * ao, tint.g * ao, tint.b * ao, 1.0)
		var sz := _p.leaf_card_size * spray_scale * _rng.randf_range(0.82, 1.2)
		FloraFactory._add_leaf_spray(st, pos, grow, sz, tint)
	return st.commit(into)


## Copa con MODELO DE HOJA propio (FloraConfig method MESH): instancia el Mesh del
## usuario en cada punto de hoja (yaw aleatorio + escala por leaf_card_size), en vez
## de las cards procedurales. Cap de instancias: un modelo puede tener muchos polys.
func _build_canopy_mesh_model(into: ArrayMesh) -> ArrayMesh:
	var model := _p.leaf_mesh_override
	const MAX_INSTANCES := 90   # tope: modelo del usuario × puntos = polys reales
	var step := maxi(1, ceili(float(_leaves.size()) / float(MAX_INSTANCES)))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# El modelo conserva SU material (superficie 0); las demás superficies se
	# fusionan con la misma base — suficiente para hojas/ramitas simples.
	if model.get_surface_count() > 0 and model.surface_get_material(0) != null:
		st.set_material(model.surface_get_material(0))
	var scl := _p.leaf_card_size
	var idx := 0
	for leaf: Dictionary in _leaves:
		idx += 1
		if idx % step != 0:
			continue
		var pos: Vector3 = _to_godot(leaf["pos"])
		var yaw := _rng.randf() * TAU
		var s := scl * _rng.randf_range(0.8, 1.25)
		var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s)), pos)
		for surf in model.get_surface_count():
			st.append_from(model, surf, xf)
	return st.commit(into)


## Genera el árbol completo: corteza (superficie 0) + copa (superficie 1).
func generate(params: TreeParams, seed_val: int) -> ArrayMesh:
	build_skeleton(params, seed_val)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_bark_mat(_tree_scale, _p.bark_type,
			_p.bark_tex_override, _p.bark_normal_override))
	_build_bark(st)
	st.generate_normals()
	st.generate_tangents()   # relieve real: el normal map de corteza necesita tangentes
	var mesh := st.commit()
	return _build_canopy(mesh)
