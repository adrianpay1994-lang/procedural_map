extends Node
## TEST · Ramales que salen del circuito y RECONECTAN en otro punto del circuito.
## Criterios: nacen y mueren SOBRE el anillo, se meten hacia el centro, y no son
## todos iguales (variedad de recorrido).

func _ready() -> void:
	var n := 240
	var spine := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU
		spine.append(Vector2(cos(a), sin(a)) * 500.0)
	spine.append(spine[0])
	var center := Vector2.ZERO

	var branches: Array = CorridorPlanner.plan_branches(spine, center, 4, 0.18, 7)
	var ok_count := branches.size() == 4
	if not ok_count:
		print("FAIL: se esperaban 4 ramales y hubo %d" % branches.size())

	var ok_ends := true
	var ok_inland := true
	var depths := PackedFloat32Array()
	for b_any in branches:
		var b: PackedVector2Array = b_any
		# Nace y muere SOBRE el anillo (radio ~500).
		if absf(b[0].length() - 500.0) > 12.0 or absf(b[b.size() - 1].length() - 500.0) > 12.0:
			ok_ends = false
		# Se mete hacia el centro: algún punto queda claramente más adentro.
		var closest := INF
		for p in b:
			closest = minf(closest, p.length())
		depths.append(closest)
		if closest > 460.0:
			ok_inland = false
	if not ok_ends:
		print("FAIL: algun ramal no nace/muere sobre el anillo")
	if not ok_inland:
		print("FAIL: algun ramal no se adentra hacia el centro")

	# Variedad: no todos se meten lo mismo.
	var dmin := INF
	var dmax := 0.0
	for d in depths:
		dmin = minf(dmin, d)
		dmax = maxf(dmax, d)
	var ok_var := (dmax - dmin) > 30.0
	if not ok_var:
		print("FAIL: todos los ramales se adentran igual (%.0f..%.0f)" % [dmin, dmax])

	print("BRANCHES: %d ramales · se adentran hasta radio %.0f..%.0f (anillo 500)" % [
			branches.size(), dmin, dmax])
	var p := int(ok_count) + int(ok_ends) + int(ok_inland) + int(ok_var)
	print("BRANCHES_TEST: %s (%d/4)" % ["PASS" if p == 4 else "FAIL", p])
	get_tree().quit(0 if p == 4 else 1)
