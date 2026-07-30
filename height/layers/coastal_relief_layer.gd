class_name CoastalReliefLayer
extends HeightLayer

## ============================================================================
## CoastalReliefLayer · Relieve que CAMBIA según cuán adentro de la isla estás
## ============================================================================
## Misma idea que el suelo oceánico (tres capas de FastNoiseLite con semillas
## separadas), pero con el aporte clave: la amplitud y el carácter del ruido se
## MODULAN por la posición costa→centro, que `HeightContext.get_graph_elevation()`
## ya entrega como 0..1 (0 = costa/mar, 1 = interior alto).
##
## Por qué importa: un ruido uniforme da una isla que se ve igual en todos lados.
## La costa tiene que ser suave y baja, el interior accidentado, y el borde entre
## los dos es donde aparecen los acantilados. Eso no se logra con una sola capa:
## se logra pesando las capas según dónde estás.
##
##   capa            frecuencia   tipo               qué aporta
##   cuencas/relieve  0.0006      SIMPLEX_SMOOTH     forma general, valles amplios
##   base             0.006       SIMPLEX_SMOOTH     cerros y ondulación media
##   detalle          0.05        PERLIN             rugosidad fina
##
## Se compone con las demás capas del pipeline (blend/strength/mask de HeightLayer),
## así que se puede limitar a una zona con una máscara para hacer una región de
## acantilados o de montañas sin tocar el resto de la isla.
## ============================================================================

## Altura máxima que aporta esta capa en el interior (m, antes de `strength`).
@export var relief_m: float = 55.0
## Cuánto de ese relieve queda en la COSTA (0 = costa plana, 1 = igual que el
## interior). Bajo = playas y planicies costeras limpias.
@export_range(0.0, 1.0) var coast_amount: float = 0.12
## Dónde empieza a crecer el relieve (en elevación 0..1 del grafo). Subirlo empuja
## las montañas hacia el centro y agranda la planicie costera.
@export_range(0.0, 1.0) var inland_start: float = 0.25
## Dureza de la transición costa→interior. Alto = ACANTILADOS (el relieve entra de
## golpe); bajo = subida gradual.
@export_range(1.0, 6.0) var cliff_sharpness: float = 2.2
## Amplitud RELATIVA de cada capa. OJO — corregido: la primera versión NORMALIZABA
## por la suma, y en la referencia (`ocean_floor_system`) cada capa tiene su
## amplitud propia y la de gran escala es la DOMINANTE. Normalizar aplastaba el
## relieve. `relief_m` escala el conjunto; estos son la FORMA.
@export var w_broad: float = 1.0
@export var w_base: float = 0.5
@export var w_detail: float = 0.1
## INVERTIR el relieve donde el ruido es alto: genera cuencas y depresiones en vez
## de picos (las "montañas invertidas"). 0 = solo relieve normal.
@export_range(0.0, 1.0) var invert_amount: float = 0.0
## --- PSEUDO-EROSIÓN (técnica que usa Rust: "pseudo-erosion + noise distortion") ---
## RIDGED: convierte el ruido en CRESTAS afiladas con valles en V, en vez de lomas
## redondeadas. Es lo que hace que una montaña parezca erosionada y no un bulto.
@export_range(0.0, 1.0) var ridged_amount: float = 0.0
## DOMAIN WARP: distorsiona las coordenadas con otro ruido ANTES de muestrear. Las
## crestas dejan de ser simétricas y aparecen quebradas, como talladas por el agua.
## 0 = sin distorsión. Valores útiles: 20-120 m.
@export var warp_strength_m: float = 0.0
@export var warp_frequency: float = 0.002
@export var noise_seed: int = 0

var _broad: FastNoiseLite
var _base: FastNoiseLite
var _detail: FastNoiseLite
var _warp: FastNoiseLite


func _init() -> void:
	layer_name = &"coastal_relief"


func prepare(ctx: HeightContext) -> void:
	var s := noise_seed if noise_seed != 0 else ctx.global_seed
	_broad = _make(s, 0.0006, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	_base = _make(s + 1000, 0.006, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	_detail = _make(s + 2000, 0.05, FastNoiseLite.TYPE_PERLIN)
	_warp = _make(s + 3000, warp_frequency, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)


func _make(sd: int, freq: float, t: FastNoiseLite.NoiseType) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = sd
	n.frequency = freq
	n.noise_type = t
	return n


func _value(pos: Vector2, ctx: HeightContext) -> float:
	if _broad == null:
		prepare(ctx)
	# 0 = costa/mar, 1 = interior. Es la "distancia a la costa" que ya calcula el
	# grafo de polígonos: no hace falta un campo de distancia aparte.
	return relief_at(pos, ctx.get_graph_elevation(pos))


## La matemática, separada del contexto: dada la posición y cuán adentro estás
## (0 = costa, 1 = interior), cuánto relieve aporta. Público para poder probarlo
## sin levantar un mapa entero.
func relief_at(pos: Vector2, elev01: float) -> float:
	if _broad == null:
		var s := noise_seed if noise_seed != 0 else 0
		_broad = _make(s, 0.0006, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
		_base = _make(s + 1000, 0.006, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
		_detail = _make(s + 2000, 0.05, FastNoiseLite.TYPE_PERLIN)
		_warp = _make(s + 3000, warp_frequency, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	var e := clampf(elev01, 0.0, 1.0)
	# Rampa costa→interior con dureza configurable (alto = acantilado).
	var t := clampf((e - inland_start) / maxf(1.0 - inland_start, 0.001), 0.0, 1.0)
	var ramp := pow(t, cliff_sharpness)
	var amount := lerpf(coast_amount, 1.0, ramp)

	# DOMAIN WARP: se muestrea en coordenadas DISTORSIONADAS. Es la mitad barata de
	# la "pseudo-erosión": rompe la simetría del ruido y da cauces quebrados.
	var p := pos
	if warp_strength_m > 0.0 and _warp != null:
		p = pos + Vector2(
				_warp.get_noise_2d(pos.x, pos.y),
				_warp.get_noise_2d(pos.x + 517.0, pos.y - 331.0)) * warp_strength_m

	var n := _ridge(_broad.get_noise_2d(p.x, p.y)) * w_broad
	n += _ridge(_base.get_noise_2d(p.x, p.y)) * w_base
	n += _ridge(_detail.get_noise_2d(p.x, p.y)) * w_detail
	# SIN normalizar (ver nota de los pesos): las capas SUMAN, como en la
	# referencia. Normalizar dejaba el relieve chato.

	if invert_amount > 0.0:
		# Donde el ruido es ALTO, hundir en vez de levantar: cuencas, hoyas,
		# formaciones "al revés" sin tocar el resto de la isla.
		n = lerpf(n, -absf(n), invert_amount)
	return n * relief_m * amount


## RIDGED: 1-|n| convierte las lomas en CRESTAS con valles en V. Se mezcla con el
## ruido original para poder graduarlo (0 = suave, 1 = montaña erosionada).
func _ridge(n: float) -> float:
	if ridged_amount <= 0.0:
		return n
	# 1-|n| va de 0 a 1; se recentra a -1..1 para no desplazar la altura media.
	var r := (1.0 - absf(n)) * 2.0 - 1.0
	return lerpf(n, r, ridged_amount)
