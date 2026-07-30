extends Node3D

## ============================================================================
## test_region_height_tex.gd · Guardián F1b.2/F1b.3 (tile RF + material por región)
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_region_height_tex.tscn
##   1. RF roundtrip: la imagen del tile (RF, metros) coincide con get_height.
##   2. material_for setea los uniforms del tile correctos (use_region_tile,
##      region_tile, tile_origin/size).
##   3. region_of mapea world→región.
##   4. LRU: residentes ≤ max_resident.
## ============================================================================

const RegionHeightTex := preload("res://systems/procedural_map/terrain/region_height_textures.gd")
const TERRAIN_SHADER := preload("res://shaders/TerrainPBRBiomeMap.gdshader")

var _results: Array = []


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_run()


func _check(n: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": n, "ok": ok, "detail": detail})


func _run() -> void:
	var layer := ConstHeightLayer.new()
	layer.value_m = 12.0
	layer.enabled = true
	var layers: Array[HeightLayer] = [layer]
	var rs := RegionStreamSampler.new()
	rs.setup(layers, Rect2(0.0, 0.0, 2048.0, 2048.0), 40.0, 123, null, null)

	# --- 1. RF roundtrip (altura constante 12 m) ---
	var h := rs.get_height(Vector2(300.0, 300.0))
	_check("get_height", absf(h - 12.0) < 0.01, "h=%.3f" % h)
	var img := rs.get_tile_image(Vector2i(0, 0))
	_check("tile_rf_formato", img != null and img.get_format() == Image.FORMAT_RF)
	var px := img.get_pixel(10, 10).r if img != null else -999.0
	_check("tile_rf_roundtrip", absf(px - 12.0) < 0.01, "px=%.3f (esperado 12)" % px)

	# --- 2/3/4. RegionHeightTextures ---
	var base := ShaderMaterial.new()
	base.shader = TERRAIN_SHADER
	var rht := RegionHeightTex.new()
	rht.setup(rs, base)
	rht.max_resident = 4

	var m: ShaderMaterial = rht.material_for(Vector2i(0, 0))
	_check("uni_use_region_tile", bool(m.get_shader_parameter(&"use_region_tile")) == true)
	_check("uni_region_tile_tex", m.get_shader_parameter(&"region_tile") is Texture2D)
	_check("uni_tile_size", absf(float(m.get_shader_parameter(&"tile_size_m")) - rs.region_m) < 0.01,
			"tile_size=%s region_m=%.0f" % [str(m.get_shader_parameter(&"tile_size_m")), rs.region_m])
	var torig: Vector2 = m.get_shader_parameter(&"tile_origin")
	_check("uni_tile_origin", torig.is_equal_approx(Vector2(0.0, 0.0)), "origin=%s" % str(torig))

	# region_of: 600 m con region_m 512 → columna 1.
	_check("region_of", rht.region_of(Vector2(600.0, 100.0)) == Vector2i(1, 0),
			"got %s" % str(rht.region_of(Vector2(600.0, 100.0))))

	# LRU: pedir 6 regiones distintas con tope 4 → residentes ≤ 4.
	for i in 6:
		rht.material_for(Vector2i(i, 0))
	_check("lru_acotado", rht.resident() <= 4, "residentes=%d (tope 4)" % rht.resident())

	_report()


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
		else:
			print("  FAIL: %s %s" % [r.name, r.detail])
	var all_ok := passed == _results.size()
	print("REGION_HEIGHT_TEX_TEST: %s (%d/%d)" % ["PASS" if all_ok else "FAIL", passed, _results.size()])
	get_tree().quit(0 if all_ok else 1)
