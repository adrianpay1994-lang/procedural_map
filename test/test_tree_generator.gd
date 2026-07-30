extends Node3D

## ============================================================================
## test_tree_generator.gd · Fase 0 del sistema de árboles Weber-Penn
## ============================================================================
## Headless:
##   godot --headless --path . res://systems/procedural_map/test/test_tree_generator.tscn --quit-after 20000
## Imprime "TREEGEN_TEST: PASS (n/n)" o FAIL y sale (0/1).
## ============================================================================

var _results: Array = []


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	_run_all()
	_report()


func _check(check_name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": check_name, "ok": ok, "detail": detail})
	if not ok:
		print("  FAIL: %s %s" % [check_name, detail])


func _run_all() -> void:
	# --- Task 1: TreeParams ---
	var p := TreeParams.aspen()
	_check("params_is_resource", p is Resource)
	_check("params_levels", p.levels == 3, str(p.levels))
	_check("params_base_size4", p.base_size.size() == 4, str(p.base_size.size()))

	# --- Task 2: turtle + math ---
	var t := TreeGenerator._Turtle.new()
	t.pitch_down(90.0)  # dir Z-up → apunta a -Y (WP)
	_check("turtle_pitch", t.dir.z < 0.01 and absf(t.dir.y) > 0.9, str(t.dir))
	var t2 := TreeGenerator._Turtle.new()
	t2.move(2.0)
	_check("turtle_move", t2.pos.is_equal_approx(Vector3(0, 0, 2)), str(t2.pos))
	_check("shape_cyl", is_equal_approx(TreeGenerator.shape_ratio(3, 0.5), 1.0))
	_check("declin_up", is_equal_approx(TreeGenerator.declination(Vector3(0, 0, 1)), 0.0))
	_check("declin_side", is_equal_approx(TreeGenerator.declination(Vector3(1, 0, 0)), 90.0))
	_check("to_godot_up", TreeGenerator._to_godot(Vector3(0, 0, 1)).is_equal_approx(Vector3(0, 1, 0)))

	# --- Task 3: esqueleto ---
	var g := TreeGenerator.new()
	g.build_skeleton(TreeParams.aspen(), 12345)
	_check("skel_has_trunk", g._branches.size() >= 1, str(g._branches.size()))
	var trunk: TreeGenerator._Stem = g._branches[0]
	_check("skel_trunk_depth0", trunk.depth == 0)
	_check("skel_trunk_points", trunk.points.size() >= 2, str(trunk.points.size()))
	_check("skel_many_branches", g._branches.size() > 10, str(g._branches.size()))
	var top_z := 0.0
	for pt in trunk.points:
		top_z = maxf(top_z, pt.z)
	_check("skel_trunk_height", top_z > 5.0, str(top_z))
	var g2 := TreeGenerator.new()
	g2.build_skeleton(TreeParams.aspen(), 12345)
	_check("skel_determinism", g2._branches.size() == g._branches.size()
			and (g2._branches[0] as TreeGenerator._Stem).points[-1].is_equal_approx(trunk.points[-1]))
	var g3 := TreeGenerator.new()
	g3.build_skeleton(TreeParams.aspen(), 999)
	_check("skel_seed_varies", g3._branches.size() != g._branches.size()
			or not (g3._branches[0] as TreeGenerator._Stem).points[-1].is_equal_approx(trunk.points[-1]))

	# --- Task 4: mallado corteza ---
	var gm := TreeGenerator.new()
	var mesh := gm.generate(TreeParams.aspen(), 12345)
	_check("mesh_surfaces_bark", mesh.get_surface_count() >= 1, str(mesh.get_surface_count()))
	var aabb := mesh.get_aabb()
	_check("mesh_nonempty", aabb.size.length() > 1.0, str(aabb.size))
	_check("mesh_yup_height", aabb.size.y > 3.0 and aabb.end.y > 3.0, str(aabb))
	var gm2 := TreeGenerator.new()
	var mesh2 := gm2.generate(TreeParams.aspen(), 12345)
	_check("mesh_determinism", mesh2.get_aabb().is_equal_approx(aabb))

	# --- Task 5: copa ---
	var gc := TreeGenerator.new()
	var meshc := gc.generate(TreeParams.aspen(), 12345)
	_check("mesh_has_canopy", meshc.get_surface_count() == 2, str(meshc.get_surface_count()))
	var noleaf := TreeParams.aspen()
	noleaf.leaf_count = 0
	var gnl := TreeGenerator.new()
	var meshnl := gnl.generate(noleaf, 12345)
	_check("mesh_no_canopy", meshnl.get_surface_count() == 1, str(meshnl.get_surface_count()))

	# --- Task 6: entrada pública + variedad ---
	var a := FloraFactory.make_tree(TreeParams.aspen(), 1)
	var b := FloraFactory.make_tree(TreeParams.aspen(), 2)
	_check("make_tree_nonempty", a.get_surface_count() >= 1 and a.get_aabb().size.y > 3.0)
	_check("make_tree_variety", not a.get_aabb().is_equal_approx(b.get_aabb()),
			"%s vs %s" % [a.get_aabb(), b.get_aabb()])
	var a2 := FloraFactory.make_tree(TreeParams.aspen(), 1)
	_check("make_tree_determinism", a.get_aabb().is_equal_approx(a2.get_aabb()))

	# --- Fase 1: presets de especie + BiomeFloraLibrary + pool ---
	var oak := TreeParams.black_oak()
	_check("oak_shape", oak.shape == 2)
	var fir := TreeParams.balsam_fir()
	_check("fir_pine", fir.leaf_texture == "pine" and fir.levels == 3)
	# Cada bioma con árboles tiene al menos una especie (catálogo puede crecer).
	_check("biome_taiga", BiomeFloraLibrary.trees_for("TAIGA").size() >= 3)
	_check("biome_selva_variada", BiomeFloraLibrary.trees_for("TROPICAL_RAIN_FOREST").size() >= 5)
	_check("biome_ocean_empty", BiomeFloraLibrary.trees_for("OCEAN").is_empty())
	# Costo de generación por especie (info, no assert): el más pesado es el roble.
	for sp: Array in [["aspen", TreeParams.aspen()], ["oak", oak], ["fir", fir],
			["birch", TreeParams.silver_birch()], ["pine", TreeParams.small_pine()]]:
		var t0 := Time.get_ticks_msec()
		var msh: ArrayMesh = FloraFactory.make_tree(sp[1], 7)
		print("  [info] %s gen=%d ms verts=%d" % [sp[0], Time.get_ticks_msec() - t0, _verts(msh)])
	var pool := BiomeFloraLibrary.build_tree_pool(TreeParams.aspen(), 500, 4)
	_check("pool_size4", pool.size() == 4, str(pool.size()))
	_check("pool_variety", not pool[0].get_aabb().is_equal_approx(pool[1].get_aabb()))
	_check("pool_meshes", pool[0] is ArrayMesh and (pool[0] as ArrayMesh).get_surface_count() >= 1)

	# --- Fase 5: LOD lejano ---
	var full_pool := BiomeFloraLibrary.build_tree_pool(TreeParams.black_oak(), 300, 2)
	var lod_pool := BiomeFloraLibrary.build_tree_lod_pool(TreeParams.black_oak(), 300, 2)
	_check("lod_pool_size", lod_pool.size() == 2, str(lod_pool.size()))
	var full_v := _verts(full_pool[0])
	var lod_v := _verts(lod_pool[0])
	print("  [info] oak full=%d LOD=%d (%.0f%%)" % [full_v, lod_v, 100.0 * lod_v / maxf(1.0, full_v)])
	_check("lod_much_cheaper", lod_v < full_v / 3, "%d vs %d" % [lod_v, full_v])
	_check("lod_nonempty", lod_v > 100, str(lod_v))

	# --- Fase 2: sotobosque (arbustos, plantas, flores) ---
	var fern := PlantGenerator.make_fern(5)
	_check("fern_nonempty", fern.get_surface_count() >= 1 and fern.get_aabb().size.length() > 0.3)
	var cactus := PlantGenerator.make_cactus(5)
	_check("cactus_tall", cactus.get_aabb().size.y > 0.8, str(cactus.get_aabb().size))
	_check("cactus_determinism", PlantGenerator.make_cactus(5).get_aabb().is_equal_approx(cactus.get_aabb()))
	_check("bush_forest", BiomeFloraLibrary.bush_for("TEMPERATE_DECIDUOUS_FOREST") != null)
	_check("bush_ocean_null", BiomeFloraLibrary.bush_for("OCEAN") == null)
	_check("plant_desert", "cactus" in BiomeFloraLibrary.plants_for("SUBTROPICAL_DESERT"))
	_check("plant_jungle", "fern" in BiomeFloraLibrary.plants_for("TROPICAL_RAIN_FOREST"))
	# especies argentinas
	_check("araucaria_tall", TreeParams.araucaria().g_scale > 18.0)
	_check("palo_rosa_emergent", TreeParams.palo_rosa().g_scale > 24.0)
	_check("selva_species", BiomeFloraLibrary.trees_for("TROPICAL_RAIN_FOREST").size() >= 3,
			str(BiomeFloraLibrary.trees_for("TROPICAL_RAIN_FOREST").size()))
	_check("tree_fern_tall", PlantGenerator.make_tree_fern(3).get_aabb().size.y > 1.5,
			str(PlantGenerator.make_tree_fern(3).get_aabb().size.y))
	_check("bamboo_tall", PlantGenerator.make_bamboo(3).get_aabb().size.y > 2.0)
	_check("selva_plants", BiomeFloraLibrary.plants_for("TROPICAL_RAIN_FOREST").size() == 6)  # +palmito +guembe 2026-07-17
	_check("flowers_grassland", BiomeFloraLibrary.flowers_for("GRASSLAND").size() >= 3)
	var bush_pool := BiomeFloraLibrary.build_tree_pool(BiomeFloraLibrary.bush_for("TAIGA"), 5, 2)
	_check("bush_pool", bush_pool.size() == 2 and (bush_pool[0] as ArrayMesh).get_aabb().size.y > 0.4)
	print("  [info] fern=%d cactus=%d bush=%d verts" % [_verts(fern), _verts(cactus),
			_verts(bush_pool[0])])

	# --- Fase 3: pasto por bioma ---
	_check("grass_grassland_tall", BiomeFloraLibrary.grass_for("GRASSLAND")["height"] > 0.8)
	_check("grass_taiga_sparse", BiomeFloraLibrary.grass_for("TAIGA")["density"] < 0.8)
	var blade_gr := BiomeFloraLibrary.build_grass_blade("GRASSLAND") as ArrayMesh
	var blade_ta := BiomeFloraLibrary.build_grass_blade("TAIGA") as ArrayMesh
	_check("grass_blade_nonempty", blade_gr.get_aabb().size.y > 0.4, str(blade_gr.get_aabb().size))
	_check("grass_blade_biome_differs", blade_gr.get_aabb().size.y > blade_ta.get_aabb().size.y)

	# --- Gaps de Misiones (FLORA_MISIONES §7): 4 especies nuevas de la selva ---
	for sp: Array in [["incienso", TreeParams.incienso()], ["peteribi", TreeParams.peteribi()],
			["ambay", TreeParams.ambay()], ["yerba_mate", TreeParams.yerba_mate()]]:
		var mg: ArrayMesh = FloraFactory.make_tree(sp[1], 42)
		_check("misiones_%s_mesh" % sp[0],
				mg.get_surface_count() >= 1 and mg.get_aabb().size.y > 3.0,
				"%s aabb=%s" % [sp[0], str(mg.get_aabb().size)])
	_check("ambay_sparse", TreeParams.ambay().branches[1] <= 12, str(TreeParams.ambay().branches))
	_check("selva_has_gaps", BiomeFloraLibrary.trees_for("TROPICAL_RAIN_FOREST").size() >= 11,
			str(BiomeFloraLibrary.trees_for("TROPICAL_RAIN_FOREST").size()))


func _verts(m: ArrayMesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		n += (m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return n


func _report() -> void:
	var passed := 0
	for r in _results:
		if r.ok:
			passed += 1
	var total := _results.size()
	if passed == total:
		print("TREEGEN_TEST: PASS (%d/%d)" % [passed, total])
	else:
		print("TREEGEN_TEST: FAIL (%d/%d)" % [passed, total])
	get_tree().quit(0 if passed == total else 1)
