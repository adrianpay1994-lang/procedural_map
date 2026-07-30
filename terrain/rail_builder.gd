class_name RailBuilder
extends RefCounted

## ============================================================================
## RailBuilder · Vía de tren CONTINUA (backlog #14, corregido)
## ============================================================================
## Los rieles son DOS CINTAS CONTINUAS que siguen la trayectoria completa
## (una línea → una mesh), no cajas por tramo (se veían trozos y tablones
## gigantes en curvas/cierres — reporte del usuario). SurfaceTool: indexa y
## valida él. Durmientes: MultiMesh (correctos como piezas sueltas).
## ============================================================================

static func build(sampler: HeightSampler, points: PackedVector2Array,
		path_layer: PathCarveLayer = null, profile: RailProfile = null) -> Node3D:
	var root := Node3D.new()
	root.name = "Rails"
	if points.size() < 2:
		return root
	if profile == null:
		profile = RailProfile.make_default()
	var TIE_SPACING: float = profile.tie_spacing_m

	# ---- Estaciones a paso fijo sobre la trayectoria completa ----
	# Altura: el TARGET bakeado de la capa manda cuando existe — sobre la
	# zanja protegida del río el terreno es el LECHO y los rieles se
	# zambullían en él (capturas); con el target son puente sobre el agua.
	var use_targets: bool = path_layer != null \
			and path_layer.target_heights.size() == points.size()
	var origins: Array[Vector3] = []
	var laterals: Array[Vector3] = []
	var acc := 0.0
	for i in points.size() - 1:
		var a := points[i]
		var b := points[i + 1]
		var seg_len := a.distance_to(b)
		if seg_len < 0.01:
			continue  # puntos duplicados (Chaikin en cierres): saltar, no dividir por ~0
		var dir := (b - a) / seg_len
		var lat := Vector3(-dir.y, 0.0, dir.x)
		while acc < seg_len:
			var p := a + dir * acc
			var y := sampler.get_height(p)
			if use_targets:
				y = maxf(y, lerpf(path_layer.target_heights[i],
						path_layer.target_heights[i + 1], acc / seg_len))
			origins.append(Vector3(p.x, y + 0.05, p.y))
			laterals.append(lat)
			acc += TIE_SPACING
		acc -= seg_len

	if origins.size() < 2:
		return root

	# PARALELISMO REAL (regla del usuario: los rieles mantienen su distancia
	# SIEMPRE): laterales promediados en ventana ±2 — sin esto un quiebre
	# giraba el gauge de golpe y los rieles se cruzaban (capturas).
	var smoothed: Array[Vector3] = []
	for i in laterals.size():
		var lat_acc := Vector3.ZERO
		for k in range(maxi(i - 2, 0), mini(i + 3, laterals.size())):
			lat_acc += laterals[k]
		smoothed.append(lat_acc.normalized() if lat_acc.length() > 0.01 else laterals[i])
	laterals = smoothed

	# ---- Durmientes (MultiMesh — piezas sueltas es lo correcto acá) ----
	var tie_mesh: Mesh = profile.tie_mesh_override
	if tie_mesh == null:
		var bm := BoxMesh.new()
		bm.size = profile.tie_size
		var tie_mat := StandardMaterial3D.new()
		tie_mat.albedo_color = profile.tie_color
		tie_mat.roughness = 0.9
		bm.material = tie_mat
		tie_mesh = bm
	var ties := MultiMesh.new()
	ties.transform_format = MultiMesh.TRANSFORM_3D
	ties.mesh = tie_mesh
	ties.instance_count = origins.size()
	for i in origins.size():
		var z_axis := laterals[i].cross(Vector3.UP)
		ties.set_instance_transform(i,
				Transform3D(Basis(laterals[i], Vector3.UP, z_axis), origins[i]))
	var ties_mmi := MultiMeshInstance3D.new()
	ties_mmi.name = "Ties"
	ties_mmi.multimesh = ties
	root.add_child(ties_mmi)

	# ---- Rieles: cinta continua por lado (perfil: cara superior + 2 laterales) ----
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rail_mat: Material = profile.rail_material_override
	if rail_mat == null:
		var rm := StandardMaterial3D.new()
		rm.albedo_color = profile.rail_color
		rm.metallic = profile.rail_metallic
		rm.roughness = profile.rail_roughness
		rail_mat = rm
	st.set_material(rail_mat)
	# ¿Anillo cerrado? (el provider cierra la vía: primer punto ≈ último). Si lo
	# es, SOLDAR la costura uniendo la última estación con la primera → los
	# rieles no muestran el corte inicio/fin (regla del usuario).
	var closed: bool = points[0].distance_to(points[points.size() - 1]) \
			< profile.tie_spacing_m * 2.0
	for side in [-1.0, 1.0]:
		for i in origins.size() - 1:
			_rail_segment(st, origins[i], laterals[i],
					origins[i + 1], laterals[i + 1], side, profile)
		if closed and origins.size() > 2:
			_rail_segment(st, origins[origins.size() - 1],
					laterals[origins.size() - 1], origins[0], laterals[0],
					side, profile)
	st.generate_normals()
	st.index()
	var rails_mi := MeshInstance3D.new()
	rails_mi.name = "RailBars"
	rails_mi.mesh = st.commit()
	root.add_child(rails_mi)
	return root


## Un tramo de riel entre dos estaciones: 3 caras (superior + 2 laterales),
## continuas porque comparten los mismos bordes por estación.
static func _rail_segment(st: SurfaceTool, oa: Vector3, la: Vector3,
		ob: Vector3, lb: Vector3, side: float, profile: RailProfile) -> void:
	var hw: float = profile.rail_half_w
	var top: float = profile.rail_top
	var base: float = profile.rail_base
	var ca := oa + la * (profile.gauge_m * 0.5 * side)
	var cb := ob + lb * (profile.gauge_m * 0.5 * side)
	# 4 bordes por estación: top-izq, top-der, base-izq, base-der.
	var a_ti := ca + la * -hw + Vector3.UP * top
	var a_td := ca + la * hw + Vector3.UP * top
	var a_bi := ca + la * -hw + Vector3.UP * base
	var a_bd := ca + la * hw + Vector3.UP * base
	var b_ti := cb + lb * -hw + Vector3.UP * top
	var b_td := cb + lb * hw + Vector3.UP * top
	var b_bi := cb + lb * -hw + Vector3.UP * base
	var b_bd := cb + lb * hw + Vector3.UP * base
	_quad(st, a_ti, a_td, b_ti, b_td)   # cara superior
	_quad(st, a_bi, a_ti, b_bi, b_ti)   # lateral interior
	_quad(st, a_td, a_bd, b_td, b_bd)   # lateral exterior


static func _quad(st: SurfaceTool, a0: Vector3, a1: Vector3,
		b0: Vector3, b1: Vector3) -> void:
	for v: Vector3 in [a0, a1, b0, a1, b1, b0]:
		st.set_uv(Vector2.ZERO)
		st.add_vertex(v)
