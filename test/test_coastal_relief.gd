extends Node
## TEST · CoastalReliefLayer: el relieve debe CRECER de la costa hacia el interior
## y responder a los knobs (acantilado, inversión). Sin esto la isla se ve igual
## en todos lados.

var _pass := 0
var _fail := 0


func _ready() -> void:
	var layer := CoastalReliefLayer.new()
	layer.relief_m = 50.0
	layer.coast_amount = 0.1
	layer.inland_start = 0.25
	layer.noise_seed = 4242

	# Muestreo en la COSTA (elevación baja) vs INTERIOR (elevación alta).
	var coast := _amplitude(layer, 0.05)
	var inland := _amplitude(layer, 0.95)
	_check("el_interior_tiene_MAS_relieve", inland > coast * 2.0,
			"costa=%.2f m · interior=%.2f m" % [coast, inland])
	_check("la_costa_queda_suave", coast < 8.0, "costa=%.2f m (debe ser baja)" % coast)

	# ACANTILADO: con más dureza, a media isla el relieve entra más tarde.
	layer.cliff_sharpness = 1.0
	var suave := _amplitude(layer, 0.5)
	layer.cliff_sharpness = 5.0
	var duro := _amplitude(layer, 0.5)
	_check("cliff_sharpness_endurece_la_transicion", duro < suave,
			"suave=%.2f m · duro=%.2f m a media isla" % [suave, duro])

	# INVERSIÓN: genera hundimientos (valor medio se va para abajo).
	layer.cliff_sharpness = 2.2
	var normal := _mean(layer, 0.9)
	layer.invert_amount = 1.0
	var invertido := _mean(layer, 0.9)
	_check("invert_amount_hunde_el_terreno", invertido < normal,
			"normal=%.2f m · invertido=%.2f m" % [normal, invertido])

	# PSEUDO-EROSIÓN (lo que hace Rust): ridged + domain warp deben CAMBIAR LA FORMA
	# del relieve, no solo su escala. Se compara el perfil punto a punto.
	layer.invert_amount = 0.0
	var base_profile := _profile(layer, 0.9)
	layer.ridged_amount = 1.0
	var ridge_profile := _profile(layer, 0.9)
	_check("ridged_cambia_la_forma", _diff(base_profile, ridge_profile) > 1.0,
			"diferencia media = %.3f m" % _diff(base_profile, ridge_profile))
	layer.ridged_amount = 0.0
	layer.warp_strength_m = 80.0
	layer._broad = null   # forzar reconstrucción con el warp
	var warp_profile := _profile(layer, 0.9)
	_check("domain_warp_cambia_la_forma", _diff(base_profile, warp_profile) > 0.5,
			"diferencia media = %.3f m" % _diff(base_profile, warp_profile))

	print("COASTAL_RELIEF: costa=%.2f m interior=%.2f m" % [coast, inland])
	print("COASTAL_RELIEF_TEST: %s (%d/%d)" % ["PASS" if _fail == 0 else "FAIL",
			_pass, _pass + _fail])
	get_tree().quit(0 if _fail == 0 else 1)


## Amplitud (máximo |valor|) sobre una grilla de muestras.
func _amplitude(layer: CoastalReliefLayer, elev: float) -> float:
	var m := 0.0
	for i in 400:
		var p := Vector2(float(i % 20) * 37.0, float(i / 20) * 41.0)
		m = maxf(m, absf(layer.relief_at(p, elev)))
	return m


func _mean(layer: CoastalReliefLayer, elev: float) -> float:
	var acc := 0.0
	for i in 400:
		var p := Vector2(float(i % 20) * 37.0, float(i / 20) * 41.0)
		acc += layer.relief_at(p, elev)
	return acc / 400.0


## Perfil de alturas sobre una línea, para comparar FORMAS.
func _profile(layer: CoastalReliefLayer, elev: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in 200:
		out.append(layer.relief_at(Vector2(float(i) * 23.0, 0.0), elev))
	return out


## Diferencia media absoluta entre dos perfiles (m).
func _diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var acc := 0.0
	for i in a.size():
		acc += absf(a[i] - b[i])
	return acc / maxf(float(a.size()), 1.0)


func _check(name: String, ok: bool, info: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s — %s" % [name, info])
