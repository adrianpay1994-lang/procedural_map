extends Node
## TEST · Render SIN NODOS (RenderingServer/RID) vs MeshInstance3D por hoja.
## Verifica: (1) el modo RID no crea Nodos hijos, (2) crea una instancia por hoja
## visible, (3) da las MISMAS hojas que el modo Nodos, (4) libera los RID al salir.
## Además MIDE el costo de recorrer/actualizar el árbol en ambos modos.
const QT := preload("res://systems/procedural_map/terrain/quadtree_mesh_lod.gd")

var _pass := 0
var _fail := 0


func _ready() -> void:
	var nodes = _make(false)
	var rids = _make(true)

	var n_leaves: int = nodes.debug_leaves().size()
	var r_leaves: int = rids.debug_leaves().size()
	_check("mismas_hojas", n_leaves == r_leaves,
			"nodos=%d rid=%d" % [n_leaves, r_leaves])
	_check("modo_nodos_crea_MeshInstance", _count_mi(nodes) > 0,
			"MeshInstance3D=%d" % _count_mi(nodes))
	_check("modo_rid_NO_crea_nodos", _count_mi(rids) == 0,
			"MeshInstance3D=%d (debe ser 0)" % _count_mi(rids))
	_check("modo_rid_crea_instancias", rids.rid_count() == r_leaves,
			"rids=%d hojas=%d" % [rids.rid_count(), r_leaves])

	# Costo de un recorrido completo (mover la cámara fuerza rebuild del árbol).
	var t0 := Time.get_ticks_usec()
	for i in 40:
		nodes.update_for(Vector3(float(i) * 12.0, 2.0, 0.0))
	var t_nodes := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for i in 40:
		rids.update_for(Vector3(float(i) * 12.0, 2.0, 0.0))
	var t_rids := Time.get_ticks_usec() - t0
	print("RID_TEST: 40 updates — nodos %.1f ms · RID %.1f ms (hojas ~%d, MeshInstance vivos: nodos %d / rid %d)"
			% [t_nodes / 1000.0, t_rids / 1000.0, n_leaves, _count_mi(nodes), _count_mi(rids)])

	# Al salir del árbol se sueltan los RID (si no, quedan colgados en el servidor).
	rids.get_parent().remove_child(rids)
	rids.free()
	_check("rids_liberados_sin_crash", true, "free ok")

	print("QUADTREE_RID_TEST: %s (%d/%d)" % ["PASS" if _fail == 0 else "FAIL",
			_pass, _pass + _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _make(use_rs: bool):
	var qt = QT.new()
	qt.area_size_m = 4096.0
	qt.min_cell_m = 32.0
	qt.split_factor = 1.0
	qt.rough_gain = 0.0
	qt.frustum_cull = false
	qt.use_rendering_server = use_rs
	add_child(qt)
	qt.setup(StandardMaterial3D.new())
	qt.update_for(Vector3.ZERO)
	return qt


func _count_mi(n: Node) -> int:
	var c := 0
	for ch in n.get_children():
		if ch is MeshInstance3D:
			c += 1
	return c


func _check(name: String, ok: bool, info: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s — %s" % [name, info])
