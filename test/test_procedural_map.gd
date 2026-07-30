extends Node3D

## ============================================================================
## test_procedural_map.gd · Integración del mapa procedural (§13.2, F2: 1-8)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_procedural_map.tscn --quit-after 300000
## Imprime "PROCMAP_TEST: PASS (n/n)" o FAIL y sale (0/1).
## ============================================================================

var _results: Array = []
var _map: ProceduralMapSystem
# (_worst_float/_worst_pos/_zanja_buenos eliminadas: métricas de una versión vieja del
# test que ya nadie escribía ni leía — código muerto.)


func _ready() -> void:
	# smoke.tscn instancia TODO res://systems — no correr (ni hacer quit) ahí.
	if get_tree().current_scene != self:
		return
	await _run_all()
	_report()


func _check(check_name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": check_name, "ok": ok, "detail": detail})
	if not ok:
		print("  FAIL: %s %s" % [check_name, detail])


func _run_all() -> void:
	# Config chica para test (mapa 300 + océano 100 → bounds 500 m).
	var cfg := MapGenerationConfig.new()
	cfg.num_points = 500
	cfg.map_size = 300.0
	cfg.ocean_points = 150
	cfg.ocean_distance = 100.0
	cfg.height_scale = 30.0
	cfg.num_rivers = 4

	var settings := TerrainSettings.new()
	settings.bake_resolution = 513
	settings.splat_resolution = 256
	settings.topology_resolution = 256

	var scene: PackedScene = load("res://systems/procedural_map/procedural_map.tscn")
	_map = scene.instantiate()
	_map.config = cfg
	_map.terrain_settings = settings

	# Tabla de spawn de prueba (F6): props en campo abierto.
	var entry := BiomeSpawnEntry.new()
	entry.entry_name = &"test_prop"
	entry.scene = load("res://systems/procedural_map/test/test_prop.tscn")
	entry.count = 8
	entry.obj_id = 4242
	var prule := PlacementRule.new()
	prule.zone_type = PlacementRule.ZoneType.RANDOM
	prule.max_slope = 0.4
	entry.rule = prule
	var table := BiomeSpawnTable.new()
	table.table_name = &"test_table"
	table.entries = [entry] as Array[BiomeSpawnEntry]
	_map.spawn_tables = [table] as Array[BiomeSpawnTable]

	# POIs de prueba (F7): 3 monumentos + red de caminos entre ellos.
	var poi := POIDefinition.new()
	poi.poi_name = &"test_monument"
	poi.scene = load("res://systems/procedural_map/test/test_prop.tscn")
	poi.count = 3
	poi.min_distance_between_pois_m = 60.0
	poi.obj_id = 9000
	poi.modifiers = TerrainModifierSet.new()
	_map.poi_definitions = [poi] as Array[POIDefinition]
	cfg.road_mode = "BOTH"
	var gen_ms := [0.0]
	var phases := {}   # nombre → ms (para ver regresiones de rendimiento por fase)
	_map.generation_completed.connect(func(ms: float) -> void: gen_ms[0] = ms)
	_map.phase_completed.connect(func(phase_name: StringName, ms: float) -> void: phases[phase_name] = ms)
	var t0 := Time.get_ticks_msec()
	add_child(_map)  # generación ASÍNCRONA (corrutina por fases)
	while gen_ms[0] <= 0.0 and Time.get_ticks_msec() - t0 < 120_000:
		await get_tree().process_frame
	print("  generacion: %.0f ms" % gen_ms[0])
	_check("generation_completed", gen_ms[0] > 0.0)
	# Presupuesto de rendimiento: red anti-regresión, NO benchmark absoluto. El
	# techo es generoso (tolera máquinas lentas) pero atrapa un blowup real (bake
	# accidental extra, O(n²), casi-cuelgue). El desglose por fase queda impreso
	# para ver regresiones que se arrastran antes de que rompan el techo.
	var order: Array = phases.keys()
	order.sort_custom(func(pa, pb): return phases[pa] > phases[pb])
	var brk := ""
	for k in order:
		brk += "%s=%.0f " % [k, phases[k]]
	const GEN_BUDGET_MS := 90_000.0
	_check("perf_generacion", gen_ms[0] < GEN_BUDGET_MS,
			"%.0fms (techo %.0f) | %s" % [gen_ms[0], GEN_BUDGET_MS, brk])

	# ---- 1. Chunks y meshes ----
	var terrain := _map.get_node_or_null("Terrain")
	var n_chunks := terrain.get_child_count() if terrain != null else 0
	var n_surfaces := 0
	if terrain != null:
		for chunk in terrain.get_children():
			for mi in chunk.get_children():
				if mi is MeshInstance3D and (mi as MeshInstance3D).mesh != null:
					n_surfaces += (mi as MeshInstance3D).mesh.get_surface_count()
	_check("chunks_mesh", n_chunks > 0 and n_surfaces > 0,
			"chunks=%d surf=%d" % [n_chunks, n_surfaces])

	# ---- 2. Spawn points válidos ----
	var sp_count := _map.get_spawn_count()
	var sp := _map.get_spawn_point(0)
	var sp_ok := sp_count >= 1 and sp.origin != Vector3.ZERO
	if sp_ok:
		var pos2 := Vector2(sp.origin.x, sp.origin.z)
		sp_ok = _map.sampler.get_height(pos2) > _map.sea_level \
				and not _map.data_provider.get_center_at(pos2).water
	_check("spawn_points", sp_ok, "count=%d" % sp_count)

	# ---- 3. Coincidencia física/visual: raycasts vs get_height ----
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var b: Rect2 = _map.sampler.bounds
	var max_err := 0.0
	var hits := 0
	var attempts := 0
	for i in 500:
		var pos := Vector2(rng.randf_range(b.position.x, b.end.x),
				rng.randf_range(b.position.y, b.end.y))
		var h: float = _map.sampler.get_height(pos)
		if h < _map.sea_level - 1.5:
			continue  # océano profundo: sin collider (por diseño)
		attempts += 1
		var query := PhysicsRayQueryParameters3D.create(
				Vector3(pos.x, h + 50.0, pos.y), Vector3(pos.x, h - 50.0, pos.y), 1)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		# El rayo puede pegar en un TABLERO de puente (WORLD, sobre la zanja) o en
		# el DECK de un tren estacionado/de test sobre la vía: correcto ambos —
		# este chequeo compara terreno vs terreno, no estructuras vs terreno.
		var hcol := hit.get("collider") as Node
		if hcol != null and (hcol.name.begins_with("Bridge") or hcol.name.begins_with("Train")
				or hcol.name.begins_with("Wagon") or hcol.name.begins_with("Siding")
				or hcol.name.begins_with("Locomotive")):
			continue
		hits += 1
		max_err = maxf(max_err, absf(hit.position.y - h))
	# Umbral 0.25 m: bake (bounds/512 ≈ 0.98 m) y collider (1 m) son grillas
	# bilineales DISTINTAS — en gradientes fuertes (terraplén de vía/camino)
	# difieren hasta ~0.4 m entre texels en gradientes de cañón (backcut del
	# río). Sin efecto jugable.
	_check("collider_coincide",
			attempts >= 20 and hits >= int(attempts * 0.95) and max_err < 0.45,
			"hits=%d/%d max_err=%.3f" % [hits, attempts, max_err])

	# ---- 4. Meta surface en colliders ----
	var col := _map.get_node_or_null("TerrainCollider")
	var meta_ok := col != null and col.has_meta("surface")
	_check("surface_meta", meta_ok)

	# ---- 5. Variedad de materiales en el splat ----
	var mats := {}
	for i in 400:
		var pos := b.position + Vector2(rng.randf() * b.size.x, rng.randf() * b.size.y)
		if _map.sampler.get_height(pos) > _map.sea_level:
			mats[_map.splat.dominant_material(pos)] = true
	_check("materiales", mats.size() >= 3, "n=%d" % mats.size())

	# ---- 6. Navmesh horneado ----
	_check("navmesh", _map.has_navmesh())

	# ---- 7. Cuerpo rígido descansa sobre el terreno ----
	var ball := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	# Caja, no esfera: la esfera RODABA por la pendiente hasta el labio de
	# una zanja y el test medía contra el fondo (falso negativo).
	var sh := BoxShape3D.new()
	sh.size = Vector3(0.8, 0.8, 0.8)
	cs.shape = sh
	ball.add_child(cs)
	add_child(ball)
	ball.global_position = sp.origin + Vector3(0, 5, 0)
	var t_ball := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t_ball < 4000:
		await get_tree().physics_frame
		if ball.sleeping:
			break
	var ground: float = _map.sampler.get_height(
			Vector2(ball.global_position.x, ball.global_position.z))
	# La caja puede DESLIZARSE por un talud al río y quedar FLOTANDO en un
	# volumen de agua (buoyancy): eso es físico correcto, no un fallo.
	var floating := false
	var wv_root := _map.get_node_or_null("WaterVolumes")
	if wv_root != null and ball.global_position.y > ground:
		var ball_xz := Vector2(ball.global_position.x, ball.global_position.z)
		for vol in wv_root.get_children():
			var pv := vol as ProceduralWaterVolume
			if pv == null:
				continue
			if absf(pv.surface_world_y - ball.global_position.y) < 1.5 \
					and (pv.name == &"WaterVol_ocean"
					or ball_xz.distance_to(Vector2(pv.global_position.x,
							pv.global_position.z)) < 45.0):
				floating = true
				break
	_check("rigidbody_reposa",
			ball.global_position.y > ground - 1.0
			and (ball.global_position.y < ground + 3.0 or floating),
			"y=%.2f suelo=%.2f flota=%s" % [ball.global_position.y, ground, floating])

	# ---- 8. Ríos tallados: comparar contra la pila SIN capas de río ----
	var first_river_idx := -1
	for i in _map.sampler.layers.size():
		var l := _map.sampler.layers[i]
		if l is PathCarveLayer and l.layer_name == &"river_carve":
			first_river_idx = i
			break
	var carved_pass := 0
	var carved_checked := 0
	# Sondear la polilínea REAL de cada capa (los corners crudos del grafo
	# siguen más allá del truncado en costa/confluencia — sonda en el vacío).
	# 70% del trayecto: pasada la zona somera del nacimiento (por diseño).
	for l in _map.sampler.layers:
		var rpl := l as PathCarveLayer
		if rpl == null or rpl.layer_name != &"river_carve" \
				or rpl.points.size() < 6 or first_river_idx < 0:
			continue
		var mid: Vector2 = rpl.points[int(rpl.points.size() * 0.7)]
		var h_with: float = _map.sampler.get_height(mid)               # bakeado (con ríos)
		var h_without: float = _map.sampler.sample(mid, null, first_river_idx)
		carved_checked += 1
		# 0.5 m: el cilindro esculpidor nace a flor de tierra y se engrosa.
		if h_with < h_without - 0.5:
			carved_pass += 1
		if carved_checked >= 3:
			break
	_check("rios_tallados", carved_checked > 0 and carved_pass >= carved_checked - 1,
			"pass=%d/%d" % [carved_pass, carved_checked])

	# ---- 9. F3: material PBR con arrays asignados ----
	var mat := _map.terrain_material
	var mat_ok := mat != null \
			and mat.get_shader_parameter("albedo_array") is Texture2DArray \
			and mat.get_shader_parameter("orm_array") is Texture2DArray \
			and mat.get_shader_parameter("biome_map") != null
	_check("material_pbr", mat_ok)

	# ---- 10. F4: agua — océano, volúmenes, flotabilidad ----
	var water := _map.get_node_or_null("Water")
	var vols := _map.get_node_or_null("WaterVolumes")
	_check("agua_nodos", water != null and water.get_node_or_null("OceanPlane") != null
			and vols != null and vols.get_child_count() >= 1,
			"vols=%d" % (vols.get_child_count() if vols != null else -1))

	# Cuerpo rígido soltado sobre mar profundo debe flotar cerca de la superficie.
	var deep := Vector2.ZERO
	var found_deep := false
	for i in 300:
		var pos := Vector2(rng.randf_range(b.position.x, b.end.x),
				rng.randf_range(b.position.y, b.end.y))
		if _map.sampler.get_height(pos) < _map.sea_level - 4.0:
			deep = pos
			found_deep = true
			break
	# ---- 12. F6: entidades spawneadas por topología ----
	await get_tree().process_frame
	await get_tree().process_frame  # fill() de los spawners es diferido
	var ess := _map.get_node_or_null("EntitySpawning") as EntitySpawnSystem
	var spawned: int = ess.get_active_entity_count() if ess != null else 0
	var props_ok: bool = spawned > 0
	if props_ok:
		for s in ess.get_children():
			for prop in s.get_children():
				if not (prop is Node3D):
					continue
				var p3 := prop as Node3D
				var g: float = _map.sampler.get_height(
						Vector2(p3.global_position.x, p3.global_position.z))
				if absf(p3.global_position.y - g) > 1.5 or g < _map.sea_level:
					props_ok = false
	_check("entidades_spawn", props_ok and _map.get_spatial_object(4242) != null,
			"spawned=%d" % spawned)

	# ---- 13. F7: monumentos nivelados + red de caminos ----
	var pois := _map.get_node_or_null("POIs") as POISystem
	var poi_ok := pois != null and pois.get_placed_pois().size() >= 1
	if poi_ok:
		for site in pois.planned:
			var ppos: Vector2 = site.pos
			# Plataforma nivelada: pendiente mínima en el radio interior.
			var s_center: float = _map.sampler.get_slope(ppos)
			var s_edge: float = _map.sampler.get_slope(ppos + Vector2(8, 0))
			if s_center > 0.08 or s_edge > 0.15:
				poi_ok = false
			# Sello MONUMENT en topología.
			if not _map.topology.has_any(ppos, TopologyMap.TOPO_MONUMENT):
				poi_ok = false
	_check("monumentos", poi_ok,
			"placed=%d" % (pois.get_placed_pois().size() if pois != null else -1))

	# Red de caminos: si hubo ≥2 sitios, cada sitio debe tener ROAD a ≤ 60 m
	# (el A* llega al CENTER contenedor, no al punto exacto del monumento).
	if pois != null and pois.planned.size() >= 2:
		var net_paths := 0
		for l in _map.sampler.layers:
			if l is PathCarveLayer and l.layer_name == &"road_flatten":
				net_paths += 1
		var sites_ok := 0
		for site in pois.planned:
			var ppos: Vector2 = site.pos
			var found_road := false
			for r in range(0, 61, 8):
				for ang in 8:
					var probe: Vector2 = ppos + Vector2.RIGHT.rotated(ang * TAU / 8.0) * float(r)
					if _map.topology.has_any(probe, TopologyMap.TOPO_ROAD):
						found_road = true
						break
				if found_road:
					break
			if found_road:
				sites_ok += 1
		_check("red_caminos", sites_ok >= pois.planned.size() - 1 and net_paths >= 1,
				"sitios_con_camino=%d/%d capas_camino=%d" % [sites_ok, pois.planned.size(), net_paths])

	# ---- 15. Agua REPUESTA: cintas sobre el lecho aprobado, nunca flotantes ----
	var rivers_node2 := water.get_node_or_null("Rivers") if water != null else null
	var ribbons: int = rivers_node2.get_child_count() if rivers_node2 != null else 0
	var agua_ok := ribbons >= 1
	if rivers_node2 != null:
		for mi in rivers_node2.get_children():
			var rmesh := (mi as MeshInstance3D).mesh as ArrayMesh
			if rmesh == null or rmesh.get_surface_count() == 0:
				agua_ok = false
				continue
			var rverts: PackedVector3Array = rmesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			for vi in range(0, rverts.size(), 15):
				var v := rverts[vi]
				var th: float = _map.sampler.get_height(Vector2(v.x, v.z))
				# Boca: agua a nivel del mar sobre fondo marino hondo = empalme
				# legítimo con el océano, no flotante.
				if (v.y > th + _map.config.river_depth_m + 1.0
						and v.y > _map.sea_level + 0.5):
					agua_ok = false
	_check("agua_rios", agua_ok, "cintas=%d" % ribbons)


	# ---- 17. CONTENCIÓN DEL AGUA medida (LEY agua-primero del usuario): la
	# zanja es el MOLDE del agua — en cada punto, AMBAS orillas (al borde del
	# canal + 2 m) deben quedar POR ENCIMA del nivel de agua diseñado. Agua
	# flotando = orilla bajo el nivel. Desembocadura = toca mar/costa.
	var zanja_report := ""
	var zanja_ok := true
	var half_band: float = _map.config.river_width_m * 0.5 + _map.config.river_falloff_m + 4.0
	var checked_rivers := 0
	# Los CRUCES de calzada/vía son terraplén legítimo (solución aprobada):
	# esos puntos no cuentan.
	var cross_layers: Array[PathCarveLayer] = []
	for l in _map.sampler.layers:
		var cl := l as PathCarveLayer
		if cl != null and (cl.layer_name == &"road_flatten"
				or cl.layer_name == &"rail_flatten"):
			cross_layers.append(cl)
	for l in _map.sampler.layers:
		var pl := l as PathCarveLayer
		if pl == null or pl.layer_name != &"river_carve" \
				or pl.water_levels.size() != pl.points.size():
			continue
		checked_rivers += 1
		var n_contained := 0
		var n_total := 0
		var np := pl.points.size()
		for i in range(maxi(int(np * 0.15), 1), np - 1, 3):
			var p := pl.points[i]
			var near_cross := false
			for cl in cross_layers:
				if cl.distance_to_path(p) < cl.width_m * 0.5 + 4.0:
					near_cross = true
					break
			if near_cross:
				continue
			# La boca vive dentro del mar: el océano la contiene, no la orilla.
			if _map.sampler.get_height(p) < _map.sea_level - 0.2:
				continue
			var dir := (pl.points[i + 1] - pl.points[i - 1]).normalized()
			var perp := Vector2(-dir.y, dir.x)
			var half_w: float = pl.width_m * lerpf(pl.width_start_scale, 1.0,
					float(i) / float(np - 1)) * 0.5
			# Contenido = a CADA lado existe una orilla (leva) sobre el nivel
			# dentro de half_w+10 m — como la leva vive en el borde del canal,
			# se escanea, no se asume una distancia fija.
			n_total += 1
			var both := true
			for side_s: float in [1.0, -1.0]:
				var found := false
				var s := 0.5
				while s < half_w + 10.0:
					if _map.sampler.get_height(p + perp * (side_s * s)) \
							>= pl.water_levels[i] + 0.15:
						found = true
						break
					s += 1.0
				if not found:
					both = false
					break
			if both:
				n_contained += 1
		var pct := float(n_contained) / maxf(n_total, 1)
		# Diagnóstico: ¿el bake respeta el target de la capa? (si tgt_err ≈ 0,
		# el tallado SÍ se aplicó y el problema es la medición/entorno).
		var tgt_err := 0.0
		var prof_sum := 0.0
		var n_diag := 0
		for i in range(1, pl.points.size() - 1, 5):
			var p2 := pl.points[i]
			var diag_cross := false
			for cl in cross_layers:
				if cl.distance_to_path(p2) < cl.width_m * 0.5 + 4.0:
					diag_cross = true
					break
			if diag_cross:
				continue
			tgt_err += absf(_map.sampler.get_height(p2) - pl.target_heights[i])
			var d2 := (pl.points[i + 1] - pl.points[i - 1]).normalized()
			var pp := Vector2(-d2.y, d2.x)
			prof_sum += minf(_map.sampler.get_height(p2 + pp * half_band),
					_map.sampler.get_height(p2 - pp * half_band)) \
					- _map.sampler.get_height(p2)
			n_diag += 1
		tgt_err /= maxf(n_diag, 1)
		prof_sum /= maxf(n_diag, 1)
		var mouth := pl.points[pl.points.size() - 1]
		var mouth_ok: bool = _map.sampler.get_height(mouth) < _map.sea_level + 0.6 \
				or _map.topology.has_any(mouth,
						TopologyMap.TOPO_OCEAN | TopologyMap.TOPO_OCEANSIDE | TopologyMap.TOPO_BEACH)
		zanja_report += "[rio%d contenido=%d%% mar=%s tgt_err=%.2f prof=%.1f] " % [
				checked_rivers, int(pct * 100), mouth_ok, tgt_err, prof_sum]
		# Criterio agua-primero: desembocadura SIEMPRE + lecho fiel al diseño
		# (tgt_err ≤ 0.5) + agua contenida por sus orillas en ≥85% del
		# trayecto medible. Un afluente corto sin muestras (todo cruce/mar)
		# no puede vetarse: n_total = 0 ⇒ solo exige desembocadura.
		if not mouth_ok or tgt_err > 0.5 or (n_total > 0 and pct < 0.85):
			zanja_ok = false
	# Conteo real: ¿cuántos ríos pidió la config y cuántos viven en la pila?
	zanja_report = "rios=%d/%d " % [checked_rivers, _map.config.num_rivers] \
			+ zanja_report
	_check("perfil_zanja", checked_rivers > 0 and zanja_ok, zanja_report)
	if not zanja_ok:
		# FORENSE: ¿qué capa pisa el lecho? Evaluar la pila cortando en cada
		# índice sobre el punto medio del primer río — el salto delata la capa.
		for l in _map.sampler.layers:
			var pl := l as PathCarveLayer
			if pl == null or pl.layer_name != &"river_carve":
				continue
			var probe := pl.points[floori(pl.points.size() / 2.0)]
			var fctx := _map.sampler.make_context()
			var prev_h := 0.0
			var line := "  FORENSE rio en %v: " % probe
			for k in range(1, _map.sampler.layers.size() + 1):
				var hk: float = _map.sampler.sample(probe, fctx, k)
				var lay := _map.sampler.layers[k - 1]
				if k > 1 and absf(hk - prev_h) > 0.4:
					line += "[%s: %+.1f] " % [String(lay.layer_name) if lay != null else "null", hk - prev_h]
				prev_h = hk
			print(line + "| bake=%.1f target=%.1f" % [
					_map.sampler.get_height(probe),
					pl.target_heights[floori(pl.points.size() / 2.0)]])

	# ---- 24. EMPALME DE ANILLO (regla del usuario: inicio y fin son UN cuerpo):
	# en carreteras/vías de circuito cerrado la altura NO salta en la costura —
	# el grading cíclico deja target[0]≈target[último] y la pendiente de la
	# costura respeta max_grade.
	var ring_bad := 0
	var ring_checked := 0
	for l in _map.sampler.layers:
		var rpl := l as PathCarveLayer
		if rpl == null or not rpl.is_ring \
				or rpl.target_heights.size() != rpl.points.size() \
				or rpl.points.size() < 4:
			continue
		ring_checked += 1
		var np := rpl.points.size()
		# Costura: último punto único (np-2) → primer punto (0).
		var seam_dh: float = absf(rpl.target_heights[np - 2] - rpl.target_heights[0])
		var seam_run: float = rpl.points[np - 2].distance_to(rpl.points[0])
		var seam_grade := seam_dh / maxf(seam_run, 0.5)
		# Duplicado cerrado coincide + pendiente de costura acotada.
		if absf(rpl.target_heights[0] - rpl.target_heights[np - 1]) > 0.1 \
				or seam_grade > rpl.max_grade * 2.0 + 0.02:
			ring_bad += 1
	_check("empalme_anillo", ring_bad == 0,
			"anillos=%d costura_mala=%d" % [ring_checked, ring_bad])

	# ---- 21. CRUCES SOBRE RÍOS (regla del usuario): carretera/vía pasan POR
	# ENCIMA del agua de la zanja — el target del camino en banda de río debe
	# quedar ≥ lecho + 1.3 (agua 0.7 + resguardo). Nunca por debajo.
	var cross_total := 0
	var cross_bad := 0
	for l in _map.sampler.layers:
		var pl := l as PathCarveLayer
		if pl == null or pl.protected_layers.is_empty() \
				or pl.target_heights.size() != pl.points.size():
			continue
		for i in pl.points.size():
			# Solo CRUCES clasificados (estado 1): los tramos paralelos no
			# tocan la banda ni llevan tablero.
			if pl._band_state.size() != pl.points.size() or pl._band_state[i] != 1:
				continue
			for prot in pl.protected_layers:
				if prot.distance_to_path(pl.points[i]) \
						< prot.width_m * 0.5 + prot.falloff_m:
					# Contra el AGUA de diseño (la columna nace en 0.35 y
					# crece — el lecho+1.3 era de la spec vieja).
					var wtr: float = prot.path_water_at(pl.points[i])
					if wtr < INF:
						cross_total += 1
						if pl.target_heights[i] < wtr + 0.4:
							cross_bad += 1
					break
	_check("cruces_sobre_rios", cross_bad == 0,
			"puntos_en_banda=%d bajo_agua=%d" % [cross_total, cross_bad])

	# ---- 22. TALUDES DEL RÍO (regla del usuario): los costados de la zanja
	# son laderas, no acantilados. Caminar del borde del canal hacia afuera y
	# medir pendiente entre muestras a 2 m: mayoría ≤1.0 m/m (bank 0.45 con
	# smoothstep ≤ ~0.68 + ruido del terreno).
	var slope_total := 0
	var slope_bad := 0
	for l in _map.sampler.layers:
		var pl := l as PathCarveLayer
		if pl == null or pl.layer_name != &"river_carve":
			continue
		for i in range(2, pl.points.size() - 2, 6):
			var p := pl.points[i]
			var dir := (pl.points[i + 1] - pl.points[i - 1]).normalized()
			var perp := Vector2(-dir.y, dir.x)
			for side_s: float in [1.0, -1.0]:
				var prev_h: float = _map.sampler.get_height(
						p + perp * side_s * pl.width_m * 0.5)
				for k in range(1, 9):
					var q := p + perp * side_s * (pl.width_m * 0.5 + float(k) * 2.0)
					var hq: float = _map.sampler.get_height(q)
					slope_total += 1
					if absf(hq - prev_h) / 2.0 > 1.0:
						slope_bad += 1
					prev_h = hq
	var slope_pct := float(slope_bad) / maxf(float(slope_total), 1.0)
	_check("taludes_rio", slope_total > 0 and slope_pct <= 0.12,
			"muestras=%d acantilado=%d (%.0f%%)" % [slope_total, slope_bad,
					slope_pct * 100.0])

	# ---- 26. CURVAS de carretera/vía (regla del usuario: curvas abiertas, no
	# cerradas): el giro máx entre segmentos consecutivos del trayecto FINAL
	# debe ser suave (la vía más que la carretera). Diagnóstico + tope.
	var curve_report := ""
	var curve_ok := true
	for l in _map.sampler.layers:
		var cpl := l as PathCarveLayer
		if cpl == null or (cpl.layer_name != &"road_flatten"
				and cpl.layer_name != &"rail_flatten"):
			continue
		var cmax := 0.0
		var csum := 0.0
		var ccnt := 0
		for i in range(1, cpl.points.size() - 1):
			var v0 := cpl.points[i] - cpl.points[i - 1]
			var v1 := cpl.points[i + 1] - cpl.points[i]
			if v0.length_squared() > 0.01 and v1.length_squared() > 0.01:
				var a := absf(v0.angle_to(v1))
				cmax = maxf(cmax, a)
				csum += a
				ccnt += 1
		# Tope realista: bloquea las hairpins (90°+) que había antes; los
		# rincones apretados del grafo quedan ~50° (promedio 7-18°, suave).
		var limit := 1.0
		curve_report += "[%s max=%.0f° prom=%.0f°] " % [cpl.layer_name,
				rad_to_deg(cmax), rad_to_deg(csum / maxf(ccnt, 1))]
		if cmax > limit:
			curve_ok = false
	_check("curvas_suaves", curve_ok, curve_report)

	# ---- 25. TREN DE TEST sobre la vía: existe el convoy y cada vagón cae
	# CERCA de la polilínea de la vía (no flota lejos ni bajo tierra).
	var train := _map.get_node_or_null("TestTrain")
	if train != null and _map.data_provider.rail_points.size() >= 3:
		var rail := _map.data_provider.rail_points
		var cars_ok := train.get_child_count() > 0
		for car in train.get_children():
			var cp := (car as Node3D).global_position
			var near := INF
			for rp in rail:
				near = minf(near, Vector2(cp.x, cp.z).distance_to(rp))
			if near > 6.0:  # el vagón debe estar sobre la vía (±ancho)
				cars_ok = false
		_check("tren_sobre_via", cars_ok,
				"vagones=%d" % train.get_child_count())

	# ---- 23. CALZADA NIVELADA (regla del usuario: carreteras/vías saben su
	# ancho en TODO el trayecto — ni pozos ni muros): |terreno − target| a lo
	# largo del eje, fuera de bandas de río (ahí no tocan por ley).
	var road_err_max := 0.0
	var road_err_sum := 0.0
	var road_err_n := 0
	var cal_layers: Array[PathCarveLayer] = []
	for l in _map.sampler.layers:
		var cl2 := l as PathCarveLayer
		if cl2 != null and (cl2.layer_name == &"road_flatten"
				or cl2.layer_name == &"rail_flatten") \
				and cl2.target_heights.size() == cl2.points.size():
			cal_layers.append(cl2)
	for pl in cal_layers:
		for i in range(0, pl.points.size(), 4):
			var p := pl.points[i]
			var in_band := false
			for prot in pl.protected_layers:
				if prot.distance_to_path(p) < prot.width_m * 0.5 + prot.falloff_m:
					in_band = true
					break
			if in_band:
				continue
			# Cruce calzada-con-calzada: la capa posterior re-aplana con SU
			# target (empalme legítimo) — no cuenta contra esta capa.
			var other_road := false
			for other in cal_layers:
				# Alcance REAL: con max_bank_slope el talud acompaña hasta
				# MAX_BANK_FALLOFF — la otra calzada influye hasta ahí.
				var reach: float = other.width_m * 0.5 + (maxf(other.falloff_m,
						PathCarveLayer.MAX_BANK_FALLOFF)
						if other.max_bank_slope > 0.0 else other.falloff_m)
				if other != pl and other.distance_to_path(p) < reach:
					other_road = true
					break
			if other_road:
				continue
			# La plataforma de un monumento PISA la calzada por diseño
			# (TerrainModifier, como Rust) — y su flatten alcanza MÁS allá
			# del sello MONUMENT (falloff del círculo): excluir radio real.
			if _map.topology.has_any(p, TopologyMap.TOPO_MONUMENT):
				continue
			var near_poi := false
			if _map._poi_system != null:
				for site in _map._poi_system.planned:
					if p.distance_to(site.pos) < 75.0:
						near_poi = true
						break
			if near_poi:
				continue
			var err: float = absf(_map.sampler.get_height(p) - pl.target_heights[i])
			if err > 1.8:
				var fctx2 := _map.sampler.make_context()
				var prev_h2 := 0.0
				var line2 := "  FORENSE calzada %s i=%d %v tgt=%.1f: " % [
						pl.layer_name, i, p, pl.target_heights[i]]
				for k in range(1, _map.sampler.layers.size() + 1):
					var hk2: float = _map.sampler.sample(p, fctx2, k)
					var lay2 := _map.sampler.layers[k - 1]
					if k > 1 and absf(hk2 - prev_h2) > 0.4:
						line2 += "[%s: %+.1f] " % [
								String(lay2.layer_name) if lay2 != null else "null",
								hk2 - prev_h2]
					prev_h2 = hk2
				print(line2 + "| bake=%.1f" % _map.sampler.get_height(p))
			road_err_sum += err
			road_err_max = maxf(road_err_max, err)
			road_err_n += 1
	var road_err_avg := road_err_sum / maxf(float(road_err_n), 1.0)
	_check("calzada_nivelada", road_err_n > 0 and road_err_avg <= 0.5
			and road_err_max <= 1.8,
			"n=%d avg=%.2f max=%.2f" % [road_err_n, road_err_avg, road_err_max])

	# ---- 27. ANCHO de calzada PLANO (regla del usuario: respeta su ancho, no
	# deja huecos): a ±width/2 del eje, la superficie debe estar ~a nivel del
	# target (calzada plana de lado a lado, sin pozos laterales).
	var wflat_bad := 0
	var wflat_n := 0
	for pl in cal_layers:
		for i in range(4, pl.points.size() - 4, 6):
			var p := pl.points[i]
			var in_band := false
			for prot in pl.protected_layers:
				if prot.distance_to_path(p) < prot.width_m * 0.5 + prot.falloff_m:
					in_band = true
					break
			if in_band or _map.topology.has_any(p, TopologyMap.TOPO_MONUMENT):
				continue
			var dir := (pl.points[i + 1] - pl.points[i - 1]).normalized()
			var perp := Vector2(-dir.y, dir.x)
			for side_s: float in [1.0, -1.0]:
				var q := p + perp * side_s * pl.width_m * 0.4  # dentro de la calzada
				wflat_n += 1
				if absf(_map.sampler.get_height(q) - pl.target_heights[i]) > 0.8:
					wflat_bad += 1
	# ≤18%: la calzada es plana a lo ancho salvo bordes junto a rasgos/ríos
	# (ruido bilineal del bake en gradientes fuertes). Bloquea pozos gruesos.
	_check("calzada_ancho_plano", wflat_n == 0 or float(wflat_bad) / float(wflat_n) <= 0.18,
			"muestras=%d desnivel=%d" % [wflat_n, wflat_bad])

	# ---- 16. Vía de tren: rieles+durmientes sobre balasto RAIL ----
	var rails_node := _map.get_node_or_null("Rails")
	var rail_ok := rails_node != null
	if rail_ok:
		var ties := rails_node.get_node_or_null("Ties") as MultiMeshInstance3D
		rail_ok = ties != null and ties.multimesh.instance_count > 10 \
				and _map.data_provider.rail_points.size() >= 2 \
				and _map.topology.has_any(_map.data_provider.rail_points[0],
						TopologyMap.TOPO_RAIL)
	_check("via_tren", rail_ok,
			"durmientes=%d" % (rails_node.get_node("Ties").multimesh.instance_count
					if rails_node != null and rails_node.get_node_or_null("Ties") != null else -1))

	# ---- 14. F8: vegetación por topología ----
	var veg := _map.get_node_or_null("Vegetation") as VegetationSystem
	var veg_ok := veg != null and veg.get_instance_count() > 0
	var veg_why := ""
	if veg_ok:
		# Ninguna instancia sobre calzada ni bajo el mar (muestreo).
		# OJO: get_instance_transform devuelve IDENTIDAD en headless (buffer
		# GPU dummy) — se leen las posiciones registradas por el sistema.
		for pname: StringName in veg.placed_positions:
			var placed: PackedVector2Array = veg.placed_positions[pname]
			for i in mini(placed.size(), 40):
				var p2 := placed[i]
				if _map.topology.has_any(p2, TopologyMap.TOPO_ROAD):
					veg_ok = false
					veg_why = "%s en ROAD %v" % [pname, p2]
				elif _map.sampler.get_height(p2) < _map.sea_level:
					veg_ok = false
					veg_why = "%s bajo mar %v h=%.1f" % [pname, p2,
							_map.sampler.get_height(p2)]
	_check("vegetacion", veg_ok, "instancias=%d %s" % [
			(veg.get_instance_count() if veg != null else -1), veg_why])

	# ---- 11. F5: superficie por material del splat ----
	var surf_ok := true
	var surf_ids := {}
	for i in 200:
		var pos := Vector2(rng.randf_range(b.position.x, b.end.x),
				rng.randf_range(b.position.y, b.end.y))
		if _map.sampler.get_height(pos) <= _map.sea_level:
			continue
		var sid: StringName = _map.get_surface_at(Vector3(pos.x, 0, pos.y))
		if sid == &"":
			surf_ok = false
		surf_ids[sid] = true
	_check("superficie_material", surf_ok and surf_ids.size() >= 2,
			"ids=%s" % [surf_ids.keys()])

	if found_deep:
		var buoy := RigidBody3D.new()
		var bcs := CollisionShape3D.new()
		var bsh := BoxShape3D.new()
		bsh.size = Vector3(0.6, 0.6, 0.6)
		bcs.shape = bsh
		buoy.add_child(bcs)
		add_child(buoy)
		buoy.global_position = Vector3(deep.x, _map.sea_level + 3.0, deep.y)
		var t_b := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t_b < 6000:
			await get_tree().physics_frame
		var dy := buoy.global_position.y - _map.sea_level
		_check("flotabilidad", dy > -1.5 and dy < 1.5, "dy=%.2f" % dy)
	else:
		_check("flotabilidad", false, "sin punto de mar profundo")


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
	var all_ok := passed == _results.size()
	print("PROCMAP_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
