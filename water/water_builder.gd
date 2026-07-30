class_name WaterBuilder
extends RefCounted

## ============================================================================
## WaterBuilder · Océano + agua FLUIDA de ríos y lagos (§6, doctrina §17.5)
## ============================================================================
## Ríos y lagos son FLUIDO por celdas (FluidWaterBuilder): el agua llena la
## zanja real y choca contra el terreno — nada de cintas dibujadas a mano
## (doctrina definitiva del usuario tras iterar en juego).
## ============================================================================

const OCEAN_SHADER := preload("res://shaders/OceanWater.gdshader")
const RIVER_SHADER := preload("res://shaders/RiverWater.gdshader")

## Profundidad del agua sobre el lecho: la zanja se REPLANTEA desde el agua
## (regla del usuario) — 1.2 m de columna dentro de la U de 3 m.
const WATER_DEPTH_M := 1.2


static func build(sampler: HeightSampler, provider: MapDataProvider,
		_config: MapGenerationConfig, sea_level: float,
		sea_mask: SeaMask = null) -> Node3D:
	var root := Node3D.new()
	root.name = "Water"

	# ---- Océano por CELDAS del SeaMask (backlog #49): agua SOLO donde hay
	# mar conectado al borde — las depresiones interiores quedan secas. ----
	var ocean_mat := ShaderMaterial.new()
	ocean_mat.shader = OCEAN_SHADER
	if sea_mask != null:
		root.add_child(sea_mask.build_ocean_mesh(sea_level, ocean_mat))
	else:
		var plane := PlaneMesh.new()
		var b := sampler.bounds
		plane.size = b.size * 1.05
		plane.subdivide_width = 128
		plane.subdivide_depth = 128
		var ocean := MeshInstance3D.new()
		ocean.name = "OceanPlane"
		ocean.mesh = plane
		ocean.material_override = ocean_mat
		ocean.position = Vector3(b.get_center().x, sea_level, b.get_center().y)
		ocean.extra_cull_margin = 4.0
		root.add_child(ocean)

	# ---- Ríos: agua REPUESTA sobre la zanja aprobada (flowmap procedural:
	# el trayecto define la dirección — UV.y longitudinal + dual-scroll v3,
	# angosta→ancha como Waterways, pegada al lecho medido tgt_err 0). ----
	var river_mat := ShaderMaterial.new()
	river_mat.shader = RIVER_SHADER
	# UN SOLO CUERPO con el océano (regla del usuario, como Rust): misma
	# paleta que OceanWater — en la boca no se distingue dónde termina uno
	# y empieza el otro.
	river_mat.set_shader_parameter("shallow_color", Color(0.20, 0.65, 0.75))
	river_mat.set_shader_parameter("foam_color", Color(0.95, 0.98, 1.0))
	# El OCEANO manda bajo el nivel del mar: el rio se recorta ahi (si no, en la
	# desembocadura hay dos superficies de agua superpuestas).
	river_mat.set_shader_parameter("clip_below_y", sea_level)
	var rivers := Node3D.new()
	rivers.name = "Rivers"
	root.add_child(rivers)
	var ri := 0
	for l in _river_layers_of(sampler):
		var mesh := _river_surface(sampler, l, sea_level)
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = "River_%d" % ri
		mi.mesh = mesh
		mi.material_override = river_mat
		rivers.add_child(mi)
		ri += 1

	# ---- Lagos: superficie + FALDA perimetral (agua volumétrica — de costado
	# se ve pared de agua, no un papel flotando). ICE: hielo sólido caminable.
	var lake_mat := ShaderMaterial.new()
	lake_mat.shader = RIVER_SHADER
	lake_mat.set_shader_parameter("flow_speed", 0.12)
	lake_mat.set_shader_parameter("clip_below_y", sea_level)
	var ice_mat := StandardMaterial3D.new()
	ice_mat.albedo_color = Color(0.78, 0.86, 0.93)
	ice_mat.roughness = 0.22
	ice_mat.metallic = 0.05
	var lakes := Node3D.new()
	lakes.name = "Lakes"
	root.add_child(lakes)
	var li := 0
	for lake in provider.lakes:
		var poly: PackedVector2Array = lake.polygon
		if poly.size() < 3:
			continue
		var frozen: bool = lake.get("frozen", false)
		var mi := MeshInstance3D.new()
		mi.name = ("IceLake_%d" if frozen else "Lake_%d") % li
		mi.mesh = _polygon_fan_mesh(_chaikin_closed(poly, 2), lake.water_y, 2.5)
		# Sin ternario: los materiales son subtipos distintos (tipos incompatibles).
		if frozen:
			mi.material_override = ice_mat
		else:
			mi.material_override = lake_mat
		lakes.add_child(mi)
		if frozen:
			# Hielo: se CAMINA encima (regla del usuario: suelo a nivel).
			var body := StaticBody3D.new()
			var cs := CollisionShape3D.new()
			cs.shape = mi.mesh.create_trimesh_shape()
			body.add_child(cs)
			mi.add_child(body)
		li += 1
	return root


## Chaikin para polígono CERRADO (contorno suave del lago).
static func _chaikin_closed(poly: PackedVector2Array, passes: int) -> PackedVector2Array:
	var cur := poly
	for _p in passes:
		var next := PackedVector2Array()
		for i in cur.size():
			var a := cur[i]
			var b := cur[(i + 1) % cur.size()]
			next.append(a.lerp(b, 0.25))
			next.append(a.lerp(b, 0.75))
		cur = next
	return cur


## Mesh con la forma del polígono (fan desde el centroide) + falda perimetral
## hacia abajo (skirt_m): el agua es un VOLUMEN, no un papel (regla del usuario).
static func _polygon_fan_mesh(poly: PackedVector2Array, y: float,
		skirt_m: float = 0.0) -> ArrayMesh:
	var centroid := Vector2.ZERO
	for p in poly:
		centroid += p
	centroid /= float(poly.size())
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		for p in [centroid, a, b]:
			st.set_uv(Vector2(p.x, p.y) * 0.1)
			st.set_uv2(Vector2.ZERO)
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(p.x, y, p.y))
		if skirt_m > 0.0:
			var out_n := ((a + b) * 0.5 - centroid).normalized()
			var wall_n := Vector3(out_n.x, 0.0, out_n.y)
			var at := Vector3(a.x, y, a.y)
			var bt := Vector3(b.x, y, b.y)
			var ab := Vector3(a.x, y - skirt_m, a.y)
			var bb := Vector3(b.x, y - skirt_m, b.y)
			for v: Vector3 in [at, bt, ab, bt, bb, ab]:
				st.set_uv(Vector2(v.x + v.z, v.y) * 0.1)
				st.set_uv2(Vector2.ZERO)
				st.set_normal(wall_n)
				st.add_vertex(v)
	st.index()
	return st.commit()


## Distancia lateral a la ORILLA real: primer punto (paso 0.6 m) donde el
## terreno FINAL supera el nivel del agua. Sin orilla en half_w+14 m (boca
## dentro del mar) → ancho de diseño.
static func _bank_dist(sampler: HeightSampler, origin: Vector2, dir: Vector2,
		level: float, half_w: float, fallback: float) -> float:
	var s := maxf(half_w * 0.5, 0.6)
	while s < half_w + 14.0:
		if sampler.get_height(origin + dir * s) >= level + 0.05:
			return maxf(s - 0.25, 0.5)
		s += 0.6
	return fallback


static func _river_layers_of(sampler: HeightSampler) -> Array[PathCarveLayer]:
	var out: Array[PathCarveLayer] = []
	for l in sampler.layers:
		var pl := l as PathCarveLayer
		if pl != null and pl.layer_name == &"river_carve" \
				and pl.target_heights.size() == pl.points.size():
			out.append(pl)
	return out


## Agua del río VOLUMÉTRICA (regla del usuario: 3D con paredes, no un plano):
## superficie sobre el LECHO bakeado (+0.7 m) monotónica y clampeada al mar,
## metida DENTRO de la "U" de la zanja (ancho 0.9× del canal), con PAREDES
## laterales que bajan al lecho y TAPAS en nacimiento y boca — mirada de
## costado tiene cuerpo, como en Rust. Flujo: el propio trayecto (UV.y).
static func _river_surface(sampler: HeightSampler, pl: PathCarveLayer,
		sea_level: float) -> ArrayMesh:
	var n := pl.points.size()
	if n < 2:
		return null
	# AGUA PRIMERO: la mesh usa el DISEÑO exacto de la capa (water_levels) —
	# la zanja ya es su contenedor a medida. Fallback: lecho + columna.
	var levels := PackedFloat32Array()
	levels.resize(n)
	var designed: bool = pl.water_levels.size() == n
	for i in n:
		levels[i] = pl.water_levels[i] if designed \
				else pl.target_heights[i] + WATER_DEPTH_M
	for i in range(1, n):
		levels[i] = minf(levels[i], levels[i - 1])
	for i in n:
		levels[i] = maxf(levels[i], sea_level - 0.15)
	# El río CHOCA con el mar (regla del usuario): la cinta TERMINA en el
	# primer punto donde el nivel ya es el del océano Y el fondo es mar
	# hondo — nada de cause metido adentro del mar.
	var n_eff := n
	for i in n:
		if levels[i] <= sea_level - 0.14 \
				and sampler.get_height(pl.points[i]) < sea_level - 0.6:
			n_eff = i + 1
			break
	if n_eff < 2:
		return null

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dist := 0.0
	# Fila: [Ltop, Rtop, Lbot, Rbot, slope, dist]
	var rows: Array[Array] = []
	for i in n_eff:
		var dir: Vector2
		if i == 0:
			dir = (pl.points[1] - pl.points[0]).normalized()
		elif i == n - 1:
			dir = (pl.points[n - 1] - pl.points[n - 2]).normalized()
		else:
			dir = (pl.points[i + 1] - pl.points[i - 1]).normalized()
		# ANCHO REAL: la orilla es donde el TERRENO FINAL cruza el nivel del
		# agua (escaneo lateral sobre el bake) — el agua toma la forma exacta
		# de su contenedor, ni flota ni deja trinchera seca al lado.
		var half_w := pl.width_m * pl.width_scale_at(i) * 0.5
		var fallback := half_w * 0.9 + 0.3
		# BOCA-ABANICO: en el último 12% el río se ABRE dentro del mar — un
		# solo cuerpo con el océano, sin costura visible (como Rust).
		if pl.mouth_from_layer == null:
			fallback *= 1.0 + 1.4 * clampf(
					(float(i) / float(n - 1) - 0.88) / 0.12, 0.0, 1.0)
		var perp_u := Vector2(-dir.y, dir.x)
		var w_l := _bank_dist(sampler, pl.points[i], perp_u, levels[i],
				half_w, fallback)
		var w_r := _bank_dist(sampler, pl.points[i], -perp_u, levels[i],
				half_w, fallback)
		if i > 0:
			dist += pl.points[i].distance_to(pl.points[i - 1])
		var slope := 0.0
		if i > 0 and i < n - 1:
			var run := pl.points[i - 1].distance_to(pl.points[i + 1])
			slope = absf(levels[i - 1] - levels[i + 1]) / maxf(run, 0.1)
		var lft := pl.points[i] + perp_u * w_l
		var rgt := pl.points[i] - perp_u * w_r
		var bot := pl.target_heights[i] - 0.4  # bajo el lecho: sin ranuras
		rows.append([Vector3(lft.x, levels[i], lft.y),
				Vector3(rgt.x, levels[i], rgt.y),
				Vector3(lft.x * 0.85 + pl.points[i].x * 0.15, bot,
						lft.y * 0.85 + pl.points[i].y * 0.15),
				Vector3(rgt.x * 0.85 + pl.points[i].x * 0.15, bot,
						rgt.y * 0.85 + pl.points[i].y * 0.15),
				slope, dist])
	for i in n_eff - 1:
		var a: Array = rows[i]
		var b: Array = rows[i + 1]
		# Superficie + pared izquierda + pared derecha (shader cull_disabled).
		var quads: Array = [
			[a[0], a[1], b[0], b[1], Vector3.UP],
			[a[2], a[0], b[2], b[0], Vector3.LEFT],
			[a[1], a[3], b[1], b[3], Vector3.RIGHT],
		]
		for q: Array in quads:
			var nrm: Vector3 = q[4]
			var tris: Array = [
				[q[0], a, 0.0], [q[1], a, 1.0], [q[2], b, 0.0],
				[q[1], a, 1.0], [q[3], b, 1.0], [q[2], b, 0.0],
			]
			for tv: Array in tris:
				var src: Array = tv[1]
				st.set_uv(Vector2(tv[2], src[5]))
				st.set_uv2(Vector2(src[4], 0.0))
				st.set_normal(nrm)
				st.add_vertex(tv[0])
	# Tapas: nacimiento y boca (el agua tiene cuerpo visto de frente).
	for cap: Array in [[rows[0], Vector3.BACK], [rows[n_eff - 1], Vector3.FORWARD]]:
		var r: Array = cap[0]
		var tris2: Array = [r[0], r[1], r[2], r[1], r[3], r[2]]
		for v: Vector3 in tris2:
			st.set_uv(Vector2(0.5, r[5]))
			st.set_uv2(Vector2(r[4], 0.0))
			st.set_normal(cap[1])
			st.add_vertex(v)
	st.index()
	return st.commit()
