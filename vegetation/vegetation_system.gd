class_name VegetationSystem
extends Node3D

## ============================================================================
## VegetationSystem · Bosques, arbustos y rocas por topología (F8)
## ============================================================================
## Un MultiMeshInstance3D por perfil (1 draw call por estrato). Posiciones
## deterministas vía TopologyMap.find_positions + filtros de la PlacementRule.
## Respeta MONUMENT/ROAD/RIVER solo (los excluye la regla por defecto).
## ============================================================================

@export var profiles: Array[VegetationProfile] = []

## Cámara que MANDA el density-LOD (null = la activa del viewport). Para
## espectador/debug (frustum_spy_test fija la cámara del jugador).
var camera_override: Camera3D = null
## Contenedor espacial (el QuadtreeMeshLOD del terreno): decide qué parcelas EXISTEN.
## Con él seteado y frustum_cull activo, un chunk de vegetación fuera del cono del
## player se apaga entero (un test descarta cientos de árboles/rocas). null = off.
var spatial_gate = null
## Lado de la parcela que se prueba por chunk de vegetación (m). Debe cubrir el chunk
## para no apagar de más en el borde.
var spatial_gate_cell_m: float = 64.0

## Lado de celda del troceo espacial (m). Cada celda = un MultiMesh chico que
## Godot descarta por frustum + distancia. CLAVE: sin esto el visibility_range
## se evalúa contra el AABB de un MultiMesh que abarca todo el mapa y la LOD
## falla (árboles desaparecen al acercarse).
## Lado de celda del troceo (m). 48→64 (2026-07-18): con ~4 árboles por celda-
## especie, 48 m daba 799 MMIs de tronco (ratio instancias/draw pésimo → RX570
## ahogada en draw calls, NO en vértices: solo 950k prims). Celdas más grandes =
## menos MMIs = menos draws, a costa de culling algo más grueso (aceptable: los
## draws eran el cuello). Ver breakdown en mini_world.
const CHUNK := 64.0

## Lado (en celdas CHUNK) de la REGIÓN de merge de impostores (4 = 192 m, 1 draw
## lejano en vez de ~16). El bug A0 de la auditoría (el range regional se mide
## contra el AABB de TODA la región → árboles invisibles/duplicados en la banda
## far2..far2+diagonal) NO se arregla achicando la región (probado: REGION_CELLS=1
## = 2180 MMIs y FPS<1 en Ultra) sino con REGION_PAD: las imágenes CRUZADAS por
## celda (12 verts, baratísimas) cubren hasta far2+diagonal de región, y el
## impostor regional arranca recién ahí — sin hueco, sin solape, pocos draws.
const REGION_CELLS := 2
## Diagonal de la región de merge (m) = hasta dónde deben llegar las cruzadas para
## que el impostor regional pueda arrancar SIN hueco (fix A0).
const REGION_PAD := REGION_CELLS * CHUNK * 1.4143
## Fin del proxy de sombra (m): hasta dónde los árboles lejanos proyectan sombra
## barata (≈ directional_shadow_max_distance típico; más allá no hay shadow map).
const SHADOW_PROXY_END := 160.0

## Density-LOD (técnica forest-demo): a partir de DENSITY_START la copa de cada
## chunk lejano muestra cada vez MENOS árboles (visible_instance_count), hasta
## DENSITY_MIN en DENSITY_END. Es un entero por chunk por tick → gratis. El
## troceo estático NO se reconstruye nunca (no es el streaming que lageaba).
const DENSITY_START := 55.0
const DENSITY_END := 240.0
const DENSITY_MIN := 0.22
const DENSITY_TICK := 0.18   # recalcular cada ~0.18 s (no hace falta por frame)

var _total_instances: int = 0
var _total_mmis: int = 0     # métrica de draw calls potenciales (F7 del usuario)
var _dlods: Array = []       # [{mmi, center, full}] registrados para density-LOD
var _dlod_accum := 0.0
## A4: preset con el que se POBLÓ esta vegetación + mapa dueño. Si el preset
## cambia en vivo, se pide al mapa un rebuild estructural (start_lod/densidad).
var _built_preset := -1
var _map_ref: ProceduralMapSystem = null


func _ready() -> void:
	# §6.4: gráficos EN VIVO — al cambiar la calidad en opciones se re-escalan
	# los rangos de visibilidad de todos los chunks SIN regenerar el mapa.
	if typeof(GameEvents) != TYPE_NIL and GameEvents != null:
		GameEvents.settings_changed.connect(_on_settings_changed)


func _on_settings_changed(section: StringName) -> void:
	if section != &"graphics":
		return
	var q := 2
	if typeof(Settings) != TYPE_NIL and Settings != null:
		q = int(Settings.get_value(&"graphics", &"world_quality", 3))
	VegetationQuality.apply_preset(["potato", "bajo", "medio", "alto", "ultra"][clampi(q, 0, 4)])
	# Distancia de detalle (AUDITORÍA_LOD A1): el gate veg_lod_auto no tenía control
	# visible → el slider era una perilla MUERTA. Ahora SIEMPRE multiplica al bias
	# del preset (1.0 = neutro): preset manda, el slider afina.
	var preset_bias: float = [0.4, 0.55, 0.75, 0.85, 1.0][clampi(VegetationQuality.preset_index, 0, 4)]
	var slider := clampf(float(Settings.get_value(&"graphics", &"veg_lod_bias", 1.0)), 0.1, 2.0)
	VegetationQuality.lod_bias = preset_bias * slider
	VegetationQuality.cast_shadows = VegetationQuality.cast_shadows \
			and bool(Settings.get_value(&"graphics", &"veg_shadows", true))
	# Alcance de LOD0/LOD1 por % (opción de gráficos). Mueve la cadena → repoblar.
	var new_r0 := clampf(float(Settings.get_value(&"graphics", &"veg_lod0_pct", 100.0)) / 100.0, 0.4, 3.0)
	var new_r1 := clampf(float(Settings.get_value(&"graphics", &"veg_lod1_pct", 100.0)) / 100.0, 0.4, 3.0)
	var reach_changed := not is_equal_approx(new_r0, VegetationQuality.lod0_reach) \
			or not is_equal_approx(new_r1, VegetationQuality.lod1_reach)
	VegetationQuality.lod0_reach = new_r0
	VegetationQuality.lod1_reach = new_r1
	apply_quality_live()
	# A4: cambios ESTRUCTURALES (preset, o alcance LOD0/LOD1) requieren REPOBLAR
	# (los rangos de visibilidad están horneados en los MMIs) → al mapa con debounce.
	if _built_preset >= 0 and _map_ref != null and is_instance_valid(_map_ref) \
			and (VegetationQuality.preset_index != _built_preset or reach_changed):
		_map_ref.request_vegetation_rebuild()


## Re-escala visibilidad y sombras de TODOS los chunks al lod_bias actual —
## el density-LOD ya lee lod_bias por tick, así que la CADENA completa
## (anillos + raleo) responde al instante. La DENSIDAD de instancias plantadas
## sí requiere regenerar (se anota en el menú).
func apply_quality_live() -> void:
	var lb: float = maxf(VegetationQuality.lod_bias, 0.1)
	for c in get_children():
		var mmi := c as MultiMeshInstance3D
		if mmi == null or not mmi.has_meta(&"vr_base"):
			continue
		var base: Vector2 = mmi.get_meta(&"vr_base")
		var vmin: float = mmi.get_meta(&"vr_min", 0.0)
		if base.x > 0.0:
			mmi.visibility_range_begin = maxf(base.x * lb, vmin)
		if base.y > 0.0:
			mmi.visibility_range_end = maxf(base.y * lb, vmin)
		if bool(mmi.get_meta(&"vr_proxy", false)):
			# Proxies de sombra: encender/apagar EN VIVO con el toggle de sombras.
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY \
					if VegetationQuality.cast_shadows \
					else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## count_scale: multiplicador de densidad (calidad gráfica, backlog #29).
## Posiciones XZ colocadas por perfil (StringName → PackedVector2Array).
## Los tests las leen de acá: get_instance_transform devuelve identidad en
## headless (renderer dummy — buffer GPU ilegible), medido en 4.7-beta2.
var placed_positions: Dictionary = {}


func populate(map: ProceduralMapSystem, frame_yield: Callable = Callable(),
		count_scale: float = 1.0) -> void:
	# FloraConfig: hornear "modelo de hoja → imagen" ANTES de generar los pools
	# (las filas del inspector con modelo_a_imagen). Headless: no-op.
	if FloraConfig.active != null:
		await FloraConfig.active.prepare_bakes(self)
	_built_preset = VegetationQuality.preset_index   # A4: preset de esta población
	_map_ref = map
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([map.config.seed_variant, "vegetation"])
	for profile in profiles:
		if profile == null:
			continue
		# Pool de variantes: si el perfil trae varias, las instancias se reparten
		# entre ellas (variedad); si no, una sola mesh (comportamiento previo).
		var pool: Array[Mesh] = []
		if not profile.meshes.is_empty():
			pool = profile.meshes
		else:
			var m := profile.resolve_mesh()
			if m == null:
				push_warning("VegetationSystem: perfil '%s' sin mesh." % profile.profile_name)
				continue
			pool = [m] as Array[Mesh]
		if frame_yield.is_valid():
			await frame_yield.call()
		var rule := profile.rule if profile.rule != null else PlacementRule.new()
		var masks := rule.get_masks()
		# Densidad = escala del llamador × calidad global (opciones del jugador).
		var want := maxi(int(profile.count * count_scale * VegetationQuality.density_scale), 1)
		# Con stands, el gate rechaza ~(N-1)/N → pedir más candidatos para alcanzar
		# `want` DENTRO de los rodales (mancha densa de una especie).
		var over := 2
		if profile.stand_count > 1:
			over = 2 * mini(profile.stand_count, 8)
		var raw := map.topology.find_positions(masks.all, masks.any, masks["not"],
				want * over, rule.min_spacing_m, rng)
		var transforms: Array[Transform3D] = []
		for pos in raw:
			if transforms.size() >= want:
				break
			var h: float = map.sampler.get_height(pos)
			if h < rule.min_height_m or h > rule.max_height_m:
				continue
			# Nada crece bajo el mar: las bandas RIVERSIDE/LAKESIDE pueden
			# pisar terreno excavado bajo cota 0 cerca de bocas y cuencos.
			if h < map.sea_level + 0.3:
				continue
			var slope: float = map.sampler.get_slope(pos)
			if slope < rule.min_slope or slope > rule.max_slope:
				continue
			if not rule.biome_filter.is_empty() \
					and not rule.biome_filter.has(map.data_provider.get_biome_at(pos)):
				continue
			# STANDS: sólo plantar donde ESTA especie es la dominante del rodal (o la
			# 2ª, para bordes mezclados) → manchas de una especie, menos MMIs/celda.
			if profile.stand_count > 1 and not _in_stand(pos, profile):
				continue
			var yaw := rng.randf() * TAU if profile.random_yaw else 0.0
			var t := TerrainPlacer.get_placement_transform(
					map.sampler, pos, profile.align_to_terrain, yaw)
			t.origin.y -= profile.sink_m
			var s := rng.randf_range(profile.scale_min, profile.scale_max)
			t.basis = t.basis.scaled(Vector3(s, s, s))
			transforms.append(t)
		if transforms.is_empty():
			continue
		# Troceo espacial + reparto de variantes por celda. Cada celda CHUNK×CHUNK
		# es un MultiMesh chico (AABB local) → Godot lo descarta por frustum y por
		# distancia (visibility_range REAL por celda). Arregla el bug de "árboles
		# desaparecen al acercarse" y optimiza SIN quitar instancias ni detalle.
		var k := pool.size()
		var has_far := profile.meshes_far.size() == k and k > 0
		var has_far2 := profile.meshes_far2.size() == k and k > 0
		# Impostores: solo mallas ALTAS (árboles) y con render real (headless los
		# saltea → cae al LOD reducido). OCTAÉDRICO (§F8 T0): UN atlas por especie
		# (8×8 vistas hemi-octaédricas, caché a disco) — la silueta cambia al
		# orbitar (sin "cartón girando"); las variantes comparten atlas (a esa
		# distancia no se distinguen).
		var impostor_mesh: Mesh = null
		var crossed_mesh: Mesh = null
		var pool_h: float = (pool[0] as Mesh).get_aabb().size.y if not pool.is_empty() else 0.0
		# Umbral BAJO (1.4 m): ARBUSTOS también se hornean a imagen (cruzadas +
		# impostor) = MISMO método que árboles → ninguna copa 3D reducida en
		# distancia para arbustos. Plantitas/pasto (<1.4 m) siguen single-mesh
		# barato (cull corto, no vale el bake). Atlas cacheado a disco.
		if ImpostorBaker.available() and pool_h >= 1.4:
			var r := await ImpostorBaker.bake_octahedral(self, pool[0],
					String(profile.profile_name))
			if r.get("ok", false):
				impostor_mesh = r["mesh"]
				# CADENA PRO (pedido del usuario + estándar Rust/PUBG): a MEDIA
				# distancia 2 IMÁGENES CRUZADAS estáticas (12 verts, paralaje real)
				# en vez de la malla far2 (~18% del 3D). Se recortan del MISMO atlas
				# octaédrico ya cacheado → cero bakes extra. El impostor a-cámara
				# queda solo para LEJOS.
				crossed_mesh = ImpostorBaker.make_crossed_from_octa(r)
		var has_impostor := impostor_mesh != null
		# COLAPSO DE VARIANTES POR CELDA (hallazgo F7 del usuario: 3506 draws
		# @29 FPS): antes cada celda tenía K=5 buckets (uno por variante) →
		# hasta 5 MMIs por LOD por especie-celda, muchos con 2-3 instancias =
		# draw calls regalados. Ahora UNA variante por celda (hash de celda; la
		# VARIEDAD vive entre celdas vecinas): hasta 5× menos draws de
		# vegetación con exactamente las mismas instancias.
		var chunks := {}   # Vector2i → Array[Transform3D]
		var placed := PackedVector2Array()
		for i in transforms.size():
			var t := transforms[i]
			var cell := Vector2i(floori(t.origin.x / CHUNK), floori(t.origin.z / CHUNK))
			if not chunks.has(cell):
				chunks[cell] = [] as Array[Transform3D]
			(chunks[cell] as Array[Transform3D]).append(t)
			placed.append(Vector2(t.origin.x, t.origin.z))
		placed_positions[profile.profile_name] = placed
		# PLANTILLA de LOD (docs/LOD_PLANTILLA.md): distancias por PRESET y FAMILIA
		# — reemplaza el multiplicador único. FAMILIA A = árboles (silueta lejana,
		# pool_h alto → impostor a cientos de m); B = arbustos/rocas/plantas (cull
		# corto). `start_lod` SALTEA los primeros niveles caros en calidad baja.
		var is_tree := pool_h >= 4.0
		var row := VegetationQuality.lod_row(is_tree)
		var start_lod := int(row["start"])
		# FloraConfig P3: modo TODO-2D por categoría (method BILLBOARD/IMPOSTOR_OCTA)
		# → se tira TODA la malla 3D y queda solo el impostor octaédrico desde 0 m
		# (la copa "horneada a imagen": ultra barato). Si el bake no está disponible
		# (headless) cae al pipeline normal.
		var all_2d := false
		if FloraConfig.active != null:
			var cat := "bush" if String(profile.profile_name).begins_with("bush_") else "tree"
			var ls := FloraConfig.active._leaf_for(cat)
			all_2d = ls != null and (ls.method == LeafStyle.Method.BILLBOARD
					or ls.method == LeafStyle.Method.IMPOSTOR_OCTA)
		var lod_floor := 38.0  # piso = diagonal de celda + margen: ninguna transición
							   # puede caer DENTRO de la celda (bug "3 árboles")
		# Alcance de LOD0/LOD1 por opción de gráficos (%): estira dónde termina el
		# 3D cercano y dónde termina la imagen cruzada → corre la cadena entera.
		var r0 := clampf(VegetationQuality.lod0_reach, 0.4, 3.0)
		var r1 := clampf(VegetationQuality.lod1_reach, 0.4, 3.0)
		var full_end: float = maxf(float(row["full"]) * r0, lod_floor)
		var far_end: float = float(row["far"]) * r0
		var far2_end: float = float(row["far2"]) * r1   # 0 = sin far2
		var imp_end: float = float(row["imp"])      # fin del impostor = cull
		# FloraConfig.lod (inspector): distancias EXPLÍCITAS del jugador ganan sobre
		# la plantilla de calidad ("de cerca 3D hasta X m, después imagen").
		var flod: FloraLodStyle = FloraConfig.active.lod if FloraConfig.active != null else null
		if flod != null:
			if flod.full_end_m > 0.0: full_end = maxf(flod.full_end_m, lod_floor)
			if flod.far_end_m > 0.0: far_end = flod.far_end_m
			if flod.far2_end_m > 0.0: far2_end = flod.far2_end_m
			if flod.impostor_end_m > 0.0: imp_end = flod.impostor_end_m
		# Single-mesh (pasto/flores/rocas sin pool reducido): cull por su propia
		# visibilidad; los perfiles especiales (reeds 130 m) se respetan.
		var vis_m: float = profile.visibility_range_m if profile.visibility_range_m > 0.0 else imp_end
		var use_density := pool_h >= 2.0
		# Sombra: SOLO lo alto (árboles/arbustos) proyecta el contorno. Pasto,
		# flores y plantitas NO (sombra por-hoja cara y ruidosa).
		var casts_shadow := pool_h >= 1.8
		# Proxy de sombra (fable5): tronco+elipsoide baratos que proyectan por los
		# árboles lejanos (el mesh real solo proyecta en el nivel full cercano).
		var shadow_proxy: Mesh = null
		if casts_shadow and pool_h >= 4.0 and VegetationQuality.cast_shadows:
			shadow_proxy = _shadow_proxy_mesh(pool[0])
		# MERGE de impostores por REGIÓN (join_at_lod de MTerrain): las instancias
		# de impostor 2D de todas las celdas de una región (REGION_CELLS²) de esta
		# especie se juntan en UN MMI → 1 draw lejano en vez de ~16. Las mallas 3D
		# cercanas siguen por celda (culling fino + density-LOD).
		var imp_regions: Dictionary = {}   # Vector2i(región) → Array[Transform3D]
		var imp_begin := -1.0
		var shadow_regions: Dictionary = {}   # sombras fusionadas por región (draws)
		for cell: Vector2i in chunks:
			var bucket: Array[Transform3D] = chunks[cell]
			if bucket.is_empty():
				continue
			# UNA variante por celda (determinista): variedad entre celdas.
			var bi := absi(hash(cell) + k) % k
			var center := Vector3((float(cell.x) + 0.5) * CHUNK, 0.0, (float(cell.y) + 0.5) * CHUNK)
			if use_density:
				bucket.sort_custom(_density_priority)
			# Lista de niveles CONTIGUOS a renderizar (mesh + fin). start_lod tira
			# los primeros niveles de MALLA (no el impostor); el ÚLTIMO cullea en
			# imp_end/vis_m. Contiguos = sin solape → no se ven 2D y 3D juntos.
			var cand: Array = []
			if has_far:
				cand.append({"m": pool[bi], "end": full_end, "imp": false})          # FULL (cards densas cerca)
				if crossed_mesh != null:
					# LOD1 = IMAGEN de la copa (billboard cruzado) DIRECTO desde
					# full_end. NO existe el mesh de copa 3D reducido (meshes_far):
					# ESE era "el modelo 3D que aparecía al alejarse y cambiaba de
					# tamaño" (reporte del usuario). Ahora: cards densas → imagen.
					var mid_end := far2_end if far2_end > 0.0 else far_end
					if has_impostor:
						# BUG corregido (2026-07-18): era far2_end + REGION_PAD = 507 m
						# → el impostor barato NUNCA arrancaba en la isla (todo cruzada
						# per-celda = 392 draws). Debe ser MAX (la cruzada llega hasta
						# la diagonal de región y ahí toma el impostor fusionado), no
						# suma. Ahora impostor arranca a ~REGION_PAD (~181 m).
						mid_end = maxf(mid_end, REGION_PAD)
					cand.append({"m": crossed_mesh, "end": mid_end, "imp": false, "cross": true})
				elif is_tree:
					# Sólo ÁRBOLES sin bake (headless): sprays reducidos como fallback.
					# NUNCA en juego (los árboles siempre tienen bake → cruzadas).
					cand.append({"m": profile.meshes_far[bi], "end": far_end, "imp": false})
					if has_far2 and far2_end > 0.0:
						cand.append({"m": profile.meshes_far2[bi], "end": far2_end, "imp": false})
				# ARBUSTOS/plantas (no is_tree, sin impostor): NADA de copa 3D reducida
				# — el mesh FULL (barato ~10k) va directo a su cull (rango corto).
				if has_impostor:
					cand.append({"m": impostor_mesh, "end": imp_end, "imp": true})   # 2D
				# all_2d (FloraConfig): drop 99 = tirar TODOS los niveles de malla;
				# el while frena cuando cand[0] es el impostor → 2D desde 0 m.
				var drop := 99 if (all_2d and has_impostor) else start_lod
				while drop > 0 and cand.size() > 1 and not cand[0]["imp"]:
					cand.pop_front()
					drop -= 1
				# CULL del último nivel: con impostor 2D, hasta imp_end (cientos de m,
				# barato). SIN impostor (bake falló o pool bajo), NUNCA extender la
				# MALLA 3D hasta vis_m (900 m = "árboles 3D muy lejos", bug del
				# usuario): cortar apenas pasado donde iría el impostor.
				var no_imp_cull: float = minf(vis_m, (far2_end if (has_far2 and far2_end > 0.0) else far_end) + 60.0)
				cand[cand.size() - 1]["end"] = imp_end if has_impostor else no_imp_cull
			else:
				cand.append({"m": pool[bi], "end": vis_m, "imp": false})   # single-mesh
			var begin := 0.0
			for ci in cand.size():
				var lv: Dictionary = cand[ci]
				# Impostor: NO un MMI por celda — acumular por región (192 m).
				if lv["imp"]:
					var reg := Vector2i(floori(float(cell.x) / REGION_CELLS),
							floori(float(cell.y) / REGION_CELLS))
					if not imp_regions.has(reg):
						imp_regions[reg] = [] as Array[Transform3D]
					(imp_regions[reg] as Array[Transform3D]).append_array(bucket)
					imp_begin = begin
					begin = lv["end"]
					continue
				var nm_prefix := "VegCross_" if lv.get("cross", false) else "Veg_"
				var mmi := _make_mmi("%s%s_%d_%d_%d" % [nm_prefix, profile.profile_name, cell.x, cell.y, ci],
						lv["m"], bucket, begin, lv["end"], lod_floor)
				# El mesh REAL nunca proyecta sombra (miles de cards con alpha en la
				# pasada de sombras + moteado feo DENTRO de la propia copa — reporte
				# del usuario). La sombra AL SUELO la da el proxy (abajo).
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				add_child(mmi)
				_total_mmis += 1
				if use_density and not lv["imp"]:
					_dlods.append({"mmi": mmi, "center": center, "full": bucket.size()})
				begin = lv["end"]
			# PROXY DE SOMBRA (técnica fable5-world-demo): tronco+elipsoide (~66
			# tris) SHADOWS_ONLY desde 0 m — TODA la sombra de árboles al suelo
			# sale de acá (continua hasta SHADOW_PROXY_END, baratísima). Las hojas
			# no la reciben (shadows_disabled en LeafWind) → sin moteado interno.
			if casts_shadow and is_tree and shadow_proxy != null:
				# Acumular por REGIÓN (no 1 MMI de sombra por celda = 382 draws): las
				# sombras son gruesas, no necesitan culling fino → 1 draw por región.
				var sreg := Vector2i(floori(float(cell.x) / REGION_CELLS),
						floori(float(cell.y) / REGION_CELLS))
				if not shadow_regions.has(sreg):
					shadow_regions[sreg] = [] as Array[Transform3D]
				(shadow_regions[sreg] as Array[Transform3D]).append_array(bucket)
		# UN MMI de impostor por región (todas las instancias 2D de esta especie
		# en 192 m → 1 draw en vez de ~16). AABB de región = culling correcto.
		if has_impostor and imp_begin >= 0.0:
			for reg: Vector2i in imp_regions:
				var rbucket: Array[Transform3D] = imp_regions[reg]
				if rbucket.is_empty():
					continue
				add_child(_make_mmi("VegImp_%s_%d_%d" % [profile.profile_name, reg.x, reg.y],
						impostor_mesh, rbucket, imp_begin, imp_end))
				_total_mmis += 1
		# UN MMI de SOMBRA por región (antes 1 por celda = 382 draws → ~24). Proxy
		# tronco+elipsoide SHADOWS_ONLY, 0→SHADOW_PROXY_END.
		if shadow_proxy != null:
			for sreg: Vector2i in shadow_regions:
				var sbucket: Array[Transform3D] = shadow_regions[sreg]
				if sbucket.is_empty():
					continue
				var smmi := _make_mmi("VegShadow_%s_%d_%d" % [profile.profile_name, sreg.x, sreg.y],
						shadow_proxy, sbucket, 0.0, SHADOW_PROXY_END)
				smmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
				smmi.set_meta(&"vr_proxy", true)   # toggle en vivo de sombras
				add_child(smmi)
				_total_mmis += 1
		_total_instances += transforms.size()
	if OS.is_debug_build():
		print("VegetationSystem: %d instancias en %d MMIs (draws de vegetación ≈ MMIs visibles)"
				% [_total_instances, _total_mmis])
	set_process(not _dlods.is_empty())


## Ruido de rodales por bioma (cacheado por seed): baja frecuencia → manchas.
static var _stand_noise: Dictionary = {}   # seed → FastNoiseLite


static func _stand_noise_for(seed_val: int, size_m: float) -> FastNoiseLite:
	var n: FastNoiseLite = _stand_noise.get(seed_val)
	if n == null:
		n = FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.seed = seed_val
		n.frequency = 1.0 / maxf(size_m, 20.0)   # 1 mancha ≈ size_m
		_stand_noise[seed_val] = n
	return n


## ¿La posición pertenece al rodal de esta especie? Dominante por índice del
## ruido; además acepta la 2ª especie más cercana (bordes mezclados, 25%).
func _in_stand(pos: Vector2, profile: VegetationProfile) -> bool:
	var n := _stand_noise_for(profile.stand_seed, profile.stand_size_m)
	# 2 muestras descorrelacionadas → cada rodal tiene dominante + minoritaria.
	var a := n.get_noise_2d(pos.x, pos.y) * 0.5 + 0.5           # 0..1
	var b := n.get_noise_2d(pos.x + 9137.0, pos.y - 4211.0) * 0.5 + 0.5
	var dom := int(a * profile.stand_count) % profile.stand_count
	if dom == profile.stand_index:
		return true
	# 2ª especie (minoritaria) sólo en el 25% del rodal donde b es alto.
	var minor := int(b * profile.stand_count) % profile.stand_count
	return minor == profile.stand_index and b > 0.75


## Cámara que MANDA el LOD: la del player local (PlayerRegistry) o, si no hay
## registro (bancos/editor), la activa del viewport. Un solo lugar de verdad.
func _lod_camera() -> Camera3D:
	# Por `get_node_or_null`, no por el identificador global: en modo `--script`
	# los autoloads no existen como identificador y este archivo no compilaba.
	var reg := get_node_or_null(^"/root/PlayerRegistry")
	if reg != null and reg.has_method(&"active_camera"):
		var c := reg.call(&"active_camera") as Camera3D
		if c != null:
			return c
	return get_viewport().get_camera_3d() if get_viewport() != null else null


## Density-LOD por frame (throttleado): baja visible_instance_count de cada chunk
## registrado según su distancia a la cámara activa. LOD por distancia de cámara
## REAL, sin reconstruir geometría. lod_bias escala las distancias (calidad).
func _process(delta: float) -> void:
	_dlod_accum += delta
	if _dlod_accum < DENSITY_TICK:
		return
	_dlod_accum = 0.0
	var cam := camera_override if camera_override != null else _lod_camera()
	if cam == null:
		return
	var cp := cam.global_position
	var lb: float = maxf(VegetationQuality.lod_bias, 0.1)
	var start := DENSITY_START * lb
	var span := maxf((DENSITY_END - DENSITY_START) * lb, 1.0)
	for e: Dictionary in _dlods:
		var mmi: MultiMeshInstance3D = e["mmi"]
		if not is_instance_valid(mmi) or mmi.multimesh == null:
			continue
		# CONO del player (hoja del quadtree como contenedor espacial): si la parcela
		# de este chunk no entra en el cono, se apaga ENTERO — un test descarta todos
		# sus árboles/rocas, en vez de que el motor pruebe instancia por instancia.
		if spatial_gate != null:
			var c3: Vector3 = e["center"]
			var vis: bool = spatial_gate.area_in_frustum(
					Vector2(c3.x, c3.z), spatial_gate_cell_m)
			if mmi.visible != vis:
				mmi.visible = vis
			if not vis:
				continue
		var full: int = e["full"]
		var d := cp.distance_to(e["center"])
		var frac := 1.0
		if d > start:
			var t := clampf((d - start) / span, 0.0, 1.0)
			frac = lerpf(1.0, DENSITY_MIN, t * t * (3.0 - 2.0 * t))
		# Tope del jugador (FloraConfig.lod.max_3d_per_cell): "cuántas plantas 3D
		# se pueden ver por celda" — cap duro incluso de cerca.
		var cap := full
		if FloraConfig.active != null and FloraConfig.active.lod != null \
				and FloraConfig.active.lod.max_3d_per_cell > 0:
			cap = mini(full, FloraConfig.active.lod.max_3d_per_cell)
		var vc := clampi(int(round(float(full) * frac)), 1, cap)
		var cur := mmi.multimesh.visible_instance_count
		if cur < 0:
			cur = full
		# HISTÉRESIS (§6.2): en el umbral, ±1-2 instancias por tick hacían
		# PARPADEAR árboles individuales. Solo aplicar saltos significativos
		# (>~3% del chunk) o los extremos (full/mínimo).
		if vc != cur and (absi(vc - cur) > maxi(1, full >> 5) or vc == full or vc == 1):
			mmi.multimesh.visible_instance_count = vc


## Prioridad determinista de una transform (para ralear uniforme al bajar el
## conteo visible). Hash de la posición cuantizada.
func _density_priority(a: Transform3D, b: Transform3D) -> bool:
	return _pos_hash(a.origin) < _pos_hash(b.origin)


func _pos_hash(p: Vector3) -> int:
	return hash([int(p.x * 7.0), int(p.z * 7.0)])


## Margen extra del AABB (§6.1): los shaders de viento (LeafWind/TreeSway)
## mueven vértices EN GPU y el AABB automático no lo sabe — en el borde del
## frustum la celda se descartaba con hojas aún visibles ("invisible al lado").
## También cubre el billboard del impostor (el quad gira hacia la cámara).
const WIND_AABB_MARGIN := 2.5


## Margen de crossfade CORTO (Rust: el cambio de LOD casi no se percibe, no se
## ven 2-3 niveles juntos por mucho tiempo). Banda de dither fina = handoff casi
## instantáneo. Antes era ~20% (2-10 m) → se veían dos niveles fundidos demasiado
## tiempo (reporte del usuario). Ahora ~8%, tope 1.5-4 m: transición breve, sin pop.
func _lod_margin(vis_begin: float, vis_end: float) -> float:
	var span := (maxf(vis_end - vis_begin, 1.0) if vis_end > 0.0 else 40.0)
	return clampf(span * 0.08, 1.5, 4.0)


## Proxy de SOMBRA de un árbol (técnica fable5-world-demo): tronco cilindro de 5
## lados + copa elipsoide 8×4 (~66 tris), dimensionados del AABB del mesh real.
## Solo se dibuja en la pasada de sombras (SHADOWS_ONLY): la silueta al suelo es
## indistinguible a >30 m y cuesta nada vs las miles de cards con alpha.
static func _shadow_proxy_mesh(src: Mesh) -> ArrayMesh:
	var bb := src.get_aabb()
	var h := bb.size.y
	var rx := bb.size.x * 0.36
	var rz := bb.size.z * 0.36
	var cy := bb.position.y + h * 0.66      # centro de la copa
	var ry := h * 0.30
	var trunk_r := maxf(bb.size.x, bb.size.z) * 0.035
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(StandardMaterial3D.new())   # irrelevante: solo pasa de sombras
	var sides := 5
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var d0 := Vector3(cos(a0), 0, sin(a0)) * trunk_r
		var d1 := Vector3(cos(a1), 0, sin(a1)) * trunk_r
		var top := cy - ry * 0.6
		for v: Vector3 in [d0, d1, d1 + Vector3(0, top, 0),
				d0, d1 + Vector3(0, top, 0), d0 + Vector3(0, top, 0)]:
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)
	var segs := 8
	var rings := 4
	for j in rings:
		var t0 := PI * float(j) / float(rings) - PI * 0.5
		var t1 := PI * float(j + 1) / float(rings) - PI * 0.5
		for i in segs:
			var a0 := TAU * float(i) / float(segs)
			var a1 := TAU * float(i + 1) / float(segs)
			var p00 := Vector3(cos(a0) * cos(t0) * rx, sin(t0) * ry + cy, sin(a0) * cos(t0) * rz)
			var p10 := Vector3(cos(a1) * cos(t0) * rx, sin(t0) * ry + cy, sin(a1) * cos(t0) * rz)
			var p01 := Vector3(cos(a0) * cos(t1) * rx, sin(t1) * ry + cy, sin(a0) * cos(t1) * rz)
			var p11 := Vector3(cos(a1) * cos(t1) * rx, sin(t1) * ry + cy, sin(a1) * cos(t1) * rz)
			for v: Vector3 in [p00, p10, p11, p00, p11, p01]:
				st.set_uv(Vector2.ZERO)
				st.add_vertex(v)
	st.generate_normals()
	return st.commit()


## Construye un MultiMeshInstance3D con las transforms del bucket y un rango de
## visibilidad [vis_begin, vis_end] (0 = sin límite en ese extremo).
func _make_mmi(nm: String, mesh: Mesh, bucket: Array[Transform3D],
		vis_begin: float, vis_end: float, range_min: float = 0.0) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = bucket.size()
	var bb := AABB(bucket[0].origin, Vector3.ZERO)
	var max_scale := 1.0
	for j in bucket.size():
		mm.set_instance_transform(j, bucket[j])
		bb = bb.expand(bucket[j].origin)
		max_scale = maxf(max_scale, bucket[j].basis.get_scale().x)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	mmi.multimesh = mm
	# AABB real de la celda: orígenes + porte del mesh escalado + margen viento.
	var mesh_aabb := mesh.get_aabb()
	var grow := maxf(mesh_aabb.size.x, mesh_aabb.size.z) * 0.5 * max_scale \
			+ WIND_AABB_MARGIN
	bb = bb.grow(grow)
	bb.size.y += mesh_aabb.size.y * max_scale
	mmi.custom_aabb = bb
	# Base sin lod_bias para re-escalar EN VIVO al cambiar gráficos (§6.4).
	var lb0 := maxf(VegetationQuality.lod_bias, 0.1)
	mmi.set_meta(&"vr_base", Vector2(vis_begin, vis_end) / lb0)
	mmi.set_meta(&"vr_shadow", vis_begin <= 0.0)
	mmi.set_meta(&"vr_min", range_min)  # piso anti-fade-dentro-de-la-celda
	# Sombras: SOLO el LOD cercano (vis_begin 0). Los LOD lejanos/impostores no
	# proyectan — a esa distancia la sombra no se distingue y cuesta ~la mitad
	# del render de vegetación (técnica estándar; forest-demo igual).
	if not VegetationQuality.cast_shadows or vis_begin > 0.0:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Crossfade dithered nativo (Forward+): FADE_SELF funde con dither en los
	# bordes del rango — la técnica del "video de impostors" (Michael Jared).
	# Márgenes amplios = transición lenta que no se percibe.
	if vis_begin > 0.0:
		mmi.visibility_range_begin = vis_begin
	if vis_end > 0.0:
		mmi.visibility_range_end = vis_end
	# SWITCH INSTANTÁNEO (FADE_DISABLED) — pedido del usuario: NADA de crossfade
	# dithered. El dither dibujaba DOS niveles a la vez en la banda (translúcido =
	# overdraw = caída de FPS a media distancia, "veo la copa 3D translúcida y
	# consume más"). Las mallas ya están precargadas en sus MMIs → el cambio es
	# solo prender/apagar visibilidad = 0 overdraw, instantáneo. Niveles CONTIGUOS
	# (fin de uno = inicio del otro) → sin hueco ni solape; con imágenes FIELES al
	# tamaño el corte casi no se nota.
	if vis_begin > 0.0 or vis_end > 0.0:
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	return mmi


func get_instance_count() -> int:
	return _total_instances


## ---- Perfiles de fábrica ----

static func make_default_profiles() -> Array[VegetationProfile]:
	var out: Array[VegetationProfile] = []

	# Bosques por bioma: árboles Weber-Penn (TreeGenerator) con POOL de variantes
	# — cada especie por bioma, cada instancia distinta. Reemplaza el frondoso
	# único clonado. Incluye taiga (coníferas), así que ya no hace falta el
	# perfil de pinos aparte.
	out.append_array(_biome_tree_profiles())

	# Sabana/pradera: copa achatada estilo acacia, DISPERSAS (no bosque denso).
	# §6.3: la acacia legacy (make_acacia) era el "árbol viejo" que reportó el
	# usuario — fuera de la cadena LOD y sin estética Misiones. Ahora algarrobo
	# Weber-Penn (silueta achatada equivalente) con pool + LOD lejano + impostor.
	var acacias := VegetationProfile.new()
	acacias.profile_name = &"acacia_savanna"
	acacias.meshes = BiomeFloraLibrary.build_tree_pool(TreeParams.algarrobo(), 707, 5)
	acacias.meshes_far = BiomeFloraLibrary.build_tree_lod_pool(TreeParams.algarrobo(), 707, 5)
	acacias.meshes_far2 = BiomeFloraLibrary.build_tree_lod_pool(TreeParams.algarrobo(), 707, 5, 0.18)
	acacias.lod_distance = 55.0
	acacias.impostor_distance = 150.0
	acacias.far_view_m = 1500.0
	acacias.count = 420
	acacias.scale_min = 0.85
	acacias.scale_max = 1.7
	acacias.sink_m = 0.15
	var ac := PlacementRule.new()
	ac.zone_type = PlacementRule.ZoneType.FIELD
	ac.max_slope = 0.35
	ac.min_spacing_m = 18.0  # dispersas: la sabana no es bosque cerrado
	ac.biome_filter.assign(["GRASSLAND", "SUBTROPICAL_DESERT", "SAVANNA",
			"TEMPERATE_DESERT", "TROPICAL_SEASONAL_FOREST"])
	acacias.rule = ac
	out.append(acacias)

	# (Taiga y árboles sueltos ahora salen de _biome_tree_profiles.)

	# Palmeras de OASIS (regla del usuario): rodean los lagos de biomas
	# cálidos/áridos — el lago del desierto es un oasis con palmeras.
	var palms := VegetationProfile.new()
	palms.profile_name = &"palms_oasis"
	palms.meshes = BiomeFloraLibrary.build_legacy_pool(
			Callable(FloraFactory, "make_palm"), 505, 5)
	palms.count = 260
	palms.scale_min = 0.85
	palms.scale_max = 1.5
	palms.sink_m = 0.2
	var pa := PlacementRule.new()
	pa.zone_type = PlacementRule.ZoneType.CUSTOM
	pa.topology_all = TopologyMap.TOPO_LAKESIDE
	pa.max_slope = 0.5
	pa.min_spacing_m = 5.0
	pa.biome_filter.assign(["SUBTROPICAL_DESERT", "TEMPERATE_DESERT",
			"GRASSLAND", "TROPICAL_SEASONAL_FOREST"])
	palms.rule = pa
	out.append(palms)

	# Juncos / totora en la ORILLA de lagos y ríos (biomas húmedos, no desierto).
	var reeds := VegetationProfile.new()
	reeds.profile_name = &"reeds_shore"
	reeds.meshes = BiomeFloraLibrary.build_plant_pool("reed", 909, 5)
	reeds.count = 700
	reeds.scale_min = 0.8
	reeds.scale_max = 1.5
	reeds.sink_m = 0.1
	reeds.visibility_range_m = 130.0
	var re := PlacementRule.new()
	re.zone_type = PlacementRule.ZoneType.CUSTOM
	re.topology_any = TopologyMap.TOPO_LAKESIDE | TopologyMap.TOPO_RIVERSIDE
	re.max_slope = 0.4
	re.min_spacing_m = 2.5
	re.biome_filter.assign(["TROPICAL_RAIN_FOREST", "TROPICAL_SEASONAL_FOREST",
			"TEMPERATE_RAIN_FOREST", "TEMPERATE_DECIDUOUS_FOREST", "GRASSLAND", "SAVANNA"])
	reeds.rule = re
	if FloraConfig.plant_enabled("reed"):   # apagable desde el inspector
		out.append(reeds)

	# Sotobosque por bioma (arbustos + helechos/cactus + flores) con pool.
	out.append_array(_biome_understory_profiles())

	# Pasto global ELIMINADO (AUDITORÍA_LOD A3): eran 9.000 matas 3D SIN cadena LOD
	# hasta 140 m, superpuestas al pasto por parches (GrassPatchSystem) que ya cubre
	# denso hasta su radio por preset — doble estrato = el foco más probable de
	# sobrecoste GPU en vegetación cercana. El pasto ahora es SOLO GrassPatchSystem
	# (3D cerca + billboard, radios por preset de la plantilla).

	# (Flores ahora salen por bioma de _biome_understory_profiles.)

	var rocks := VegetationProfile.new()
	rocks.profile_name = &"rocks"
	rocks.mesh = make_rock_mesh(7331)
	rocks.count = 500
	rocks.scale_min = 0.5
	# Cap 2.6→1.8: las rocas 2.6× en SUMMIT/CLIFFSIDE se veían como "blobs oscuros
	# grandes" en lomas lejanas (reporte del usuario). 1.8 mantiene variedad sin
	# gigantes. (Pendiente: confirmar visualmente que eran ESTO y no otra cosa.)
	rocks.scale_max = 1.8
	rocks.align_to_terrain = true
	rocks.sink_m = 0.35
	var rr := PlacementRule.new()
	rr.zone_type = PlacementRule.ZoneType.CUSTOM
	rr.topology_any = TopologyMap.TOPO_CLIFFSIDE | TopologyMap.TOPO_SUMMIT \
			| TopologyMap.TOPO_RIVERSIDE | TopologyMap.TOPO_BEACHSIDE
	rr.max_slope = 0.7
	rr.min_spacing_m = 14.0
	rocks.rule = rr
	out.append(rocks)
	return out


## Perfiles de árbol por bioma (Weber-Penn + pool de variantes). Un perfil por
## especie de bioma; las instancias se reparten entre K meshes distintos.
static func _biome_tree_profiles() -> Array[VegetationProfile]:
	var out: Array[VegetationProfile] = []
	# bioma → [count total, spacing m, escala min, escala max]
	var specs := {
		"TEMPERATE_DECIDUOUS_FOREST": [1200, 7.0, 0.85, 1.5],
		"TEMPERATE_RAIN_FOREST": [1000, 6.5, 0.9, 1.6],
		"TAIGA": [1100, 6.0, 0.9, 1.7],
		"TROPICAL_RAIN_FOREST": [1200, 6.0, 0.9, 1.7],
		"TROPICAL_SEASONAL_FOREST": [500, 12.0, 0.9, 1.6],
	}
	for biome: String in specs:
		var species := BiomeFloraLibrary.trees_for(biome)
		if species.is_empty():
			continue
		var cfg: Array = specs[biome]
		var per := floori(float(int(cfg[0])) / species.size())   # reparto ENTERO: N árboles entre especies
		for si in species.size():
			var prof := VegetationProfile.new()
			prof.profile_name = StringName("tree_%s_%d" % [biome, si])
			# STANDS: cada especie domina sus manchas (rodales) en vez de mezclarse
			# pareja → pocas especies por celda = MUCHOS menos MMIs/draws (y bosque
			# más realista: rodales). Semilla compartida por bioma (mismos rodales).
			prof.stand_count = species.size()
			prof.stand_index = si
			prof.stand_seed = hash([biome, "stand"])
			prof.stand_size_m = 110.0
			# Pool de 5 variantes por especie (determinista por bioma+índice) +
			# pool LOD lejano barato (mismos seeds → misma silueta a distancia).
			var pool_seed := hash([biome, si, "veg"])
			prof.meshes = BiomeFloraLibrary.build_tree_pool(species[si], pool_seed, 5)
			prof.meshes_far = BiomeFloraLibrary.build_tree_lod_pool(species[si], pool_seed, 5)
			prof.meshes_far2 = BiomeFloraLibrary.build_tree_lod_pool(species[si], pool_seed, 5, 0.18)
			prof.lod_distance = 55.0       # full → reducido
			prof.impostor_distance = 150.0 # reducido → impostor billboard
			prof.far_view_m = 1800.0       # impostor → cull (miles de metros)
			prof.count = per
			prof.scale_min = cfg[2]
			prof.scale_max = cfg[3]
			prof.sink_m = 0.2
			var rule := PlacementRule.new()
			rule.zone_type = PlacementRule.ZoneType.CUSTOM
			rule.topology_all = TopologyMap.TOPO_FOREST
			rule.max_slope = 0.5
			rule.min_spacing_m = float(cfg[1])
			rule.biome_filter.assign([biome])
			prof.rule = rule
			out.append(prof)
	return out


## Perfiles de sotobosque por bioma: arbusto (pool+LOD) + planta (helecho/cactus)
## + flores (paleta del bioma). Cada bioma distinto; variedad por pool.
static func _biome_understory_profiles() -> Array[VegetationProfile]:
	var out: Array[VegetationProfile] = []
	var biomes := ["TEMPERATE_DECIDUOUS_FOREST", "TEMPERATE_RAIN_FOREST", "TAIGA",
			"TROPICAL_RAIN_FOREST", "TROPICAL_SEASONAL_FOREST", "GRASSLAND",
			"SUBTROPICAL_DESERT", "TEMPERATE_DESERT", "SHRUBLAND", "TUNDRA"]
	for biome: String in biomes:
		# --- Arbustos (TreeParams → pool + LOD) ---
		var bp := BiomeFloraLibrary.bush_for(biome)
		if bp != null:
			var prof := VegetationProfile.new()
			prof.profile_name = StringName("bush_%s" % biome)
			var pseed := hash([biome, "bush"])
			prof.meshes = BiomeFloraLibrary.build_tree_pool(bp, pseed, 5, "bush")
			prof.meshes_far = BiomeFloraLibrary.build_tree_lod_pool(bp, pseed, 5, 0.45, "bush")
			prof.meshes_far2 = BiomeFloraLibrary.build_tree_lod_pool(bp, pseed, 5, 0.18, "bush")
			prof.lod_distance = 55.0
			prof.visibility_range_m = 180.0
			prof.count = 700
			prof.scale_min = 0.7
			prof.scale_max = 1.4
			prof.sink_m = 0.1
			var rule := PlacementRule.new()
			rule.zone_type = PlacementRule.ZoneType.CUSTOM
			rule.topology_any = TopologyMap.TOPO_FIELD | TopologyMap.TOPO_FOREST \
					| TopologyMap.TOPO_FORESTSIDE
			rule.max_slope = 0.45
			rule.min_spacing_m = 6.0
			rule.biome_filter.assign([biome])
			prof.rule = rule
			out.append(prof)
		# --- Arbustos-ESCONDITE grandes y densos (tapan al jugador) ---
		var tp := BiomeFloraLibrary.thicket_for(biome)
		if tp != null:
			var prof := VegetationProfile.new()
			prof.profile_name = StringName("thicket_%s" % biome)
			var tseed := hash([biome, "thicket"])
			prof.meshes = BiomeFloraLibrary.build_tree_pool(tp, tseed, 5)
			prof.meshes_far = BiomeFloraLibrary.build_tree_lod_pool(tp, tseed, 5)
			prof.meshes_far2 = BiomeFloraLibrary.build_tree_lod_pool(tp, tseed, 5, 0.18)
			prof.lod_distance = 45.0
			prof.visibility_range_m = 160.0
			prof.count = 320                    # escondites, no maleza total
			prof.scale_min = 0.85
			prof.scale_max = 1.3
			prof.sink_m = 0.1
			var rule := PlacementRule.new()
			rule.zone_type = PlacementRule.ZoneType.CUSTOM
			rule.topology_any = TopologyMap.TOPO_FIELD | TopologyMap.TOPO_FOREST \
					| TopologyMap.TOPO_FORESTSIDE
			rule.max_slope = 0.45
			rule.min_spacing_m = 9.0
			rule.biome_filter.assign([biome])
			prof.rule = rule
			out.append(prof)
		# --- Plantas (helecho / helecho arborescente / bambú / cactus) ---
		for kind: String in BiomeFloraLibrary.plants_for(biome):
			if not FloraConfig.plant_enabled(kind):   # apagada en el inspector
				continue
			var prof := VegetationProfile.new()
			prof.profile_name = StringName("plant_%s_%s" % [biome, kind])
			prof.meshes = BiomeFloraLibrary.build_plant_pool(kind, hash([biome, "plant", kind]), 5)
			var cnt := 600
			var spc := 2.5
			match kind:
				"cactus":
					cnt = 220
					spc = 10.0
				"tree_fern":
					cnt = 320
					spc = 5.0
				"bamboo":
					cnt = 260
					spc = 6.0
				"pampas":
					cnt = 300
					spc = 7.0
			prof.count = cnt
			prof.scale_min = 0.7
			prof.scale_max = 1.5
			prof.sink_m = 0.05
			prof.visibility_range_m = 150.0
			var rule := PlacementRule.new()
			rule.zone_type = PlacementRule.ZoneType.CUSTOM
			rule.topology_any = TopologyMap.TOPO_FOREST | TopologyMap.TOPO_FIELD \
					| TopologyMap.TOPO_FORESTSIDE
			rule.max_slope = 0.4
			rule.min_spacing_m = spc
			rule.biome_filter.assign([biome])
			prof.rule = rule
			out.append(prof)
		# --- Flores (paleta del bioma) ---
		var palette := BiomeFloraLibrary.flowers_for(biome)
		for fi in palette.size():
			var col := palette[fi]
			var prof := VegetationProfile.new()
			prof.profile_name = StringName("flower_%s_%d" % [biome, fi])
			prof.meshes = BiomeFloraLibrary.build_legacy_pool(
					func(s: int) -> ArrayMesh: return FloraFactory.make_flower(s, col),
					hash([biome, "flower", fi]), 3)
			prof.count = 500
			prof.scale_min = 0.8
			prof.scale_max = 1.4
			prof.sink_m = 0.02
			prof.visibility_range_m = 100.0
			var rule := PlacementRule.new()
			rule.zone_type = PlacementRule.ZoneType.CUSTOM
			rule.topology_any = TopologyMap.TOPO_FIELD
			rule.max_slope = 0.35
			rule.min_spacing_m = 0.0
			rule.biome_filter.assign([biome])
			prof.rule = rule
			out.append(prof)
	return out


## Roca low-poly procedural (técnica Retopology 2.0: esfera-cubo desplazada,
## caras facetadas). Determinista por seed.
static func make_rock_mesh(rock_seed: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = rock_seed
	var sphere := SphereMesh.new()
	sphere.radial_segments = 8
	sphere.rings = 5
	sphere.radius = 1.0
	sphere.height = 1.6
	var arrays := sphere.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	# Desplazar vértices coherentemente (mismo hash por posición → sin grietas).
	for i in verts.size():
		var v := verts[i]
		var k := Vector3i((v * 10.0).round())
		var h := float(hash([rock_seed, k.x, k.y, k.z]) % 1000) / 1000.0
		verts[i] = v * (0.72 + h * 0.55)
		verts[i].y = maxf(verts[i].y, -0.15)  # base achatada (asienta en el suelo)
	# Re-armar SIN índices → normales planas (look facetado de roca).
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.41, 0.40)
	mat.roughness = 0.95
	st.set_material(mat)
	for i in range(0, indices.size(), 3):
		for j in 3:
			st.set_uv(Vector2.ZERO)
			st.add_vertex(verts[indices[i + j]])
	st.generate_normals()
	return st.commit()
