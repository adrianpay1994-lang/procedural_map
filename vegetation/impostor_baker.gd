class_name ImpostorBaker
extends RefCounted

## ============================================================================
## ImpostorBaker · Hornea un billboard FIEL de un mesh de árbol (LOD lejano)
## ============================================================================
## Renderiza el árbol a un SubViewport (cámara ortográfica de frente, fondo
## transparente) → textura → quad camera-facing. 2 triángulos con la imagen real
## del modelo = ver a miles de metros por casi nada (técnica clásica, ver
## docs/INVESTIGACION_VEGETACION_REALISMO.md §1/§4.2).
## En headless (renderer dummy) devuelve {ok:false} → el llamador usa la malla
## LOD reducida como respaldo. bake() es async (espera frames de render).
## ============================================================================


static func available() -> bool:
	return DisplayServer.get_name() != "headless"


## ---- Impostor OCTAÉDRICO (§F8 T0) ----------------------------------------
## Atlas de frames×frames vistas hemi-octaédricas por ESPECIE (no por variante),
## cacheado a disco (user://impostor_cache) — el bake de 64 vistas corre solo la
## primera vez. El shader OctahedralImpostor mezcla las 3 vistas más cercanas a
## la dirección de cámara: la silueta cambia al orbitar (adiós "cartón girando").

const OCTA_VERSION := 4   # 4: dilatación RGB del atlas (sin halo negro en bordes)


## Dirección del hemisferio para el punto de grilla (u,v) ∈ [0,1]².
## INVERSA EXACTA de hemi_oct_encode del shader (deben coincidir siempre).
static func _hemi_oct_dir(u: float, v: float) -> Vector3:
	var e := Vector2(u, v) * 2.0 - Vector2.ONE
	var px := (e.x + e.y) * 0.5
	var pz := (e.x - e.y) * 0.5
	var py := 1.0 - absf(px) - absf(pz)
	return Vector3(px, maxf(py, 0.0), pz).normalized()


## Hornea (o carga del caché) el impostor octaédrico. cache_key = id estable de
## la especie (profile_name). Devuelve {ok, mesh(QuadMesh+ShaderMaterial)}.
static func bake_octahedral(host: Node, mesh: Mesh, cache_key: String,
		frames: int = 8, tile: int = 128) -> Dictionary:
	if not available() or mesh == null or host == null or host.get_tree() == null:
		return {"ok": false}
	var sh: Shader = load("res://shaders/OctahedralImpostor.gdshader")
	if sh == null:
		return {"ok": false}
	var aabb := mesh.get_aabb()
	var h := maxf(0.2, aabb.size.y)
	var w := maxf(0.2, maxf(aabb.size.x, aabb.size.z))
	var span := maxf(h, w)
	var center := aabb.position + aabb.size * 0.5

	# Caché a disco: clave = especie + versión + tamaño + huella del AABB (si la
	# especie cambia de porte, el atlas viejo no sirve y se rehornea).
	var fingerprint := hash([int(aabb.size.x * 50.0), int(aabb.size.y * 50.0)])
	var cache_dir := "user://impostor_cache"
	var cache_path := "%s/%s_v%d_f%d_t%d_%d.png" % [cache_dir, cache_key,
			OCTA_VERSION, frames, tile, fingerprint]
	var atlas: Image = null
	if FileAccess.file_exists(cache_path):
		atlas = Image.load_from_file(ProjectSettings.globalize_path(cache_path))
		if atlas != null and atlas.is_empty():
			atlas = null
	if atlas == null:
		atlas = await _render_octa_atlas(host, mesh, frames, tile, span, center)
		if atlas == null:
			return {"ok": false}
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cache_dir))
		atlas.save_png(ProjectSettings.globalize_path(cache_path))
	atlas.generate_mipmaps()
	var tex := ImageTexture.create_from_image(atlas)

	# FIDELIDAD (reporte del usuario "cambia de tamaño"): el atlas se hornea con
	# cámara CUADRADA (span×span, el árbol centrado). El quad DEBE ser cuadrado
	# span×span y estar centrado en el CENTRO del AABB real — así la imagen sale
	# con el tamaño/forma exactos del árbol (un quad w×h estiraba la imagen). El
	# árbol está centrado en el tile → base en y≈0 cuando center_y = h/2.
	var qm := QuadMesh.new()
	qm.size = Vector2(span, span)
	qm.center_offset = Vector3(0.0, center.y, 0.0)
	var sm := ShaderMaterial.new()
	sm.shader = sh
	sm.set_shader_parameter(&"atlas", tex)
	sm.set_shader_parameter(&"frames", float(frames))
	qm.material = sm
	return {"ok": true, "mesh": qm, "size": Vector2(span, span),
			"span": span, "center_y": center.y}


## Renderiza las frames×frames vistas al atlas (UNA SubViewport reutilizada,
## cámara reposicionada por vista; luz FIJA en mundo → iluminación coherente
## entre frames al orbitar).
static func _render_octa_atlas(host: Node, mesh: Mesh, frames: int, tile: int,
		span: float, center: Vector3) -> Image:
	var vp := SubViewport.new()
	vp.size = Vector2i(tile, tile)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	host.add_child(vp)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	vp.add_child(mi)
	# Luz del bake PLANA (pedido del usuario: sin sombra en la copa). La imagen es
	# unshaded en juego → lo horneado es lo visto: si la direccional pinta un lado
	# oscuro, ese "sombreado" viaja a la imagen y parece sombra fija. Casi todo
	# AMBIENTAL + direccional suave SIN cast shadow = copa uniforme, sin lado oscuro.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	sun.light_energy = 0.35
	sun.shadow_enabled = false
	vp.add_child(sun)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.82, 0.85, 0.88)
	env.ambient_light_energy = 1.15   # mid: sin lado oscuro PERO sin aclarar de más
	                                  # (la imagen se veía más brillante que el full 3D)
	we.environment = env
	vp.add_child(we)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = span * 1.06
	cam.near = 0.01
	cam.far = span * 6.0
	vp.add_child(cam)

	var atlas := Image.create_empty(frames * tile, frames * tile, false, Image.FORMAT_RGBA8)
	for j in frames:
		for i in frames:
			var u := float(i) / float(frames - 1)
			var v := float(j) / float(frames - 1)
			var dir := _hemi_oct_dir(u, v)
			var up := Vector3.UP if absf(dir.y) < 0.95 else Vector3.FORWARD
			cam.look_at_from_position(center + dir * span * 2.5, center, up)
			await host.get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := vp.get_texture().get_image()
			if img == null or img.is_empty():
				vp.queue_free()
				return null
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			atlas.blit_rect(img, Rect2i(0, 0, tile, tile), Vector2i(i * tile, j * tile))
	vp.queue_free()
	# DILATACIÓN RGB (técnica fable5 Impostors.ts): los píxeles transparentes tienen
	# RGB=0 (negro) del fondo → con mipmaps/bilinear sangran un HALO NEGRO en el
	# borde del billboard. fix_alpha_edges() sangra el color de los píxeles opacos
	# hacia los transparentes → borde limpio, sin aureola oscura.
	atlas.fix_alpha_edges()
	return atlas


## Hornea el billboard. host = nodo vivo en el árbol de escena (para colgar el
## SubViewport temporal). Devuelve {ok, mesh(QuadMesh billboard), size(Vector2)}.
static func bake(host: Node, mesh: Mesh, resolution: int = 256) -> Dictionary:
	if not available() or mesh == null or host == null or host.get_tree() == null:
		return {"ok": false}
	var aabb := mesh.get_aabb()
	var h := maxf(0.2, aabb.size.y)
	var w := maxf(0.2, maxf(aabb.size.x, aabb.size.z))
	var span := maxf(h, w)
	var center := aabb.position + aabb.size * 0.5

	var vp := SubViewport.new()
	vp.size = Vector2i(resolution, resolution)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	host.add_child(vp)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	vp.add_child(mi)
	# Luz del bake PLANA (pedido del usuario: sin sombra en la copa). La imagen es
	# unshaded en juego → lo horneado es lo visto: si la direccional pinta un lado
	# oscuro, ese "sombreado" viaja a la imagen y parece sombra fija. Casi todo
	# AMBIENTAL + direccional suave SIN cast shadow = copa uniforme, sin lado oscuro.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	sun.light_energy = 0.35
	sun.shadow_enabled = false
	vp.add_child(sun)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.82, 0.85, 0.88)
	env.ambient_light_energy = 1.15   # mid: sin lado oscuro PERO sin aclarar de más
	                                  # (la imagen se veía más brillante que el full 3D)
	we.environment = env
	vp.add_child(we)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = span * 1.06
	cam.near = 0.01
	cam.far = span * 6.0
	cam.position = center + Vector3(0.0, 0.0, span * 2.5)
	vp.add_child(cam)
	cam.look_at(center, Vector3.UP)

	# Esperar a que el SubViewport renderice (2 frames + post-draw).
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	if img == null or img.is_empty():
		return {"ok": false}
	var tex := ImageTexture.create_from_image(img)

	# Billboard: quad vertical, base en y=0 del instance, camera-facing Y-fijo.
	var qm := QuadMesh.new()
	qm.size = Vector2(w, h)
	qm.center_offset = Vector3(0.0, h * 0.5, 0.0)
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.33
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	m.billboard_keep_scale = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # ya viene iluminado del bake
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	qm.material = m
	return {"ok": true, "mesh": qm, "size": Vector2(w, h)}


## CROSSED BILLBOARDS (X-billboards, estándar de industria para MEDIA distancia):
## 2 quads ESTÁTICOS cruzados a 90°, cada uno con una vista HORIZONTAL del árbol
## recortada del ATLAS octaédrico ya horneado/cacheado (tiles de esquina (0,0) =
## vista -X y (f-1,0) = vista +Z) → CERO bakes extra, construcción síncrona.
## Con paralaje real al orbitar (mejor de cerca que el billboard a cámara), 12 verts.
static func make_crossed_from_octa(octa: Dictionary) -> ArrayMesh:
	var qm := octa.get("mesh") as QuadMesh
	if qm == null:
		return null
	var sm := qm.material as ShaderMaterial
	if sm == null:
		return null
	var tex: Texture2D = sm.get_shader_parameter(&"atlas")
	var frames := maxf(float(sm.get_shader_parameter(&"frames")), 2.0)
	if tex == null:
		return null
	# Cuadrado span×span centrado en el centro del AABB (mismo encuadre que el
	# bake) → tamaño/forma FIELES al árbol real (fix "cambia de tamaño").
	var span: float = octa.get("span", octa.get("size", Vector2(6, 10)).y)
	var cy: float = octa.get("center_y", span * 0.5)
	var inv := 1.0 / frames
	# Con VIENTO sutil (CrossedWind: dobla la parte alta del quad, misma familia
	# de fase que TreeSway) — pedido del usuario: la flora-imagen también se mece.
	var m: Material
	var sh: Shader = load("res://shaders/CrossedWind.gdshader")
	if sh != null:
		var wsm := ShaderMaterial.new()
		wsm.shader = sh
		wsm.set_shader_parameter(&"atlas_tex", tex)
		wsm.set_shader_parameter(&"mesh_height", cy + span * 0.5)
		m = wsm
	else:
		var std := StandardMaterial3D.new()
		std.albedo_texture = tex
		std.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		std.alpha_scissor_threshold = 0.33
		std.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		std.cull_mode = BaseMaterial3D.CULL_DISABLED
		m = std
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(m)
	var hw := span * 0.5
	var y0 := cy - span * 0.5   # base del cuadrado (el árbol queda centrado)
	var y1 := cy + span * 0.5
	# [eje del plano, rect UV del tile]: plano en Z = vista desde -X (tile 0,0);
	# plano en X = vista desde +Z (tile f-1,0).
	var planes: Array = [
		[Vector3(0, 0, 1), Rect2(0.0, 0.0, inv, inv)],
		[Vector3(1, 0, 0), Rect2(1.0 - inv, 0.0, inv, inv)],
	]
	for pl: Array in planes:
		var side: Vector3 = pl[0]
		var r: Rect2 = pl[1]
		var a := -side * hw + Vector3(0, y0, 0)
		var b := side * hw + Vector3(0, y0, 0)
		var c := side * hw + Vector3(0, y1, 0)
		var d := -side * hw + Vector3(0, y1, 0)
		for pair: Array in [
				[a, Vector2(r.position.x, r.end.y)], [b, Vector2(r.end.x, r.end.y)],
				[c, Vector2(r.end.x, r.position.y)], [a, Vector2(r.position.x, r.end.y)],
				[c, Vector2(r.end.x, r.position.y)], [d, Vector2(r.position.x, r.position.y)]]:
			st.set_uv(pair[1])
			st.add_vertex(pair[0])
	st.generate_normals()
	return st.commit()
