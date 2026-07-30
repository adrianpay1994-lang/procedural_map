class_name PathCarveLayer
extends HeightLayer

## ============================================================================
## PathCarveLayer · Talla (ríos) o aplana (carreteras) a lo largo de una polilínea
## ============================================================================
## CARVE:         h' = h - depth_m · perfil(distancia lateral)   [relativo]
## FLATTEN_ALONG: h' = lerp(h, target del segmento, perfil)      [absoluto]
##   Los targets por punto los llena el orquestador con bake_targets()
##   (muestreando la pila SIN esta capa) — ver PROCEDURAL_MAP_PLAN.md §3.4.
##
## Distancia punto-polilínea con grid hash de segmentos: O(1) amortizado por
## muestra (crítico: el bake evalúa resolution² posiciones).
## ============================================================================

enum PathMode { CARVE, FLATTEN_ALONG }

@export var path_mode: PathMode = PathMode.CARVE
## Polilínea en metros (espacio de mapa).
@export var points: PackedVector2Array = PackedVector2Array()
@export var width_m: float = 6.0
@export var depth_m: float = 2.5
@export var falloff_m: float = 8.0
## Sección transversal: x = 0 centro → 1 borde exterior; y = factor de efecto.
## null = 1 en el canal, smoothstep→0 en el falloff.
@export var profile: Curve
## FLATTEN_ALONG: altura objetivo por punto (paralelo a points). Lo llena bake_targets().
@export var target_heights: PackedFloat32Array = PackedFloat32Array()
## true ⇒ target_heights viene PRE-calculado — bake_targets no lo pisa.
@export var use_precomputed_targets: bool = false
## Río: altura OBLIGADA de llegada (desembocadura bajo el mar). Tras la
## monotonía, una pasada HACIA ATRÁS garantiza llegar con pendiente acotada
## (max_backcut_per_m): el lecho baja gradualmente lo necesario, sin crestas
## ni caídas absurdas. INF = sin garantía (caminos).
@export var mouth_target_m: float = INF
@export var max_backcut_per_m: float = 0.15
## PENDIENTE MÁXIMA del trayecto (m por m): los trenes reales no superan ~3%,
## las carreteras ~8%. El clamp bilateral produce el comportamiento real:
## TERRAPLÉN que rellena valles y DESMONTE que corta lomas — nada de vías en
## "U" ni trepadas imposibles (capturas del usuario). 0 = sin límite (ríos).
@export var max_grade: float = 0.0
## Escala del ancho en el punto 0 (río: nace angosto ~0.35 y se ensancha a 1.0
## en la desembocadura, como el corte triangular de pcg-terrain_1).
@export_range(0.1, 1.0, 0.05) var width_start_scale: float = 1.0
## PUENTES (caminos/vías): si el terreno bajo el trayecto queda a más de esta
## distancia bajo el target (zanja de río, hondonada), ese tramo es un VANO:
## la capa NO rellena con terraplén (deja la zanja abierta) y BridgeBuilder
## construye tablero+pilotes ahí. 0 = sin detección (ríos).
@export var bridge_clearance_m: float = 0.0
## Vanos detectados por bake_targets(): pares [índice_inicio, índice_fin].
var bridge_spans: Array[Vector2i] = []
## Estado por punto respecto a las bandas protegidas (lo llena bake_targets):
## 0 = libre · 1 = CRUCE transversal corto (calzada angosta sobre el agua) ·
## 2 = PARALELO largo (la zanja es sagrada — el camino no toca nada ahí).
var _band_state := PackedByteArray()
## ZANJAS PROTEGIDAS (regla del usuario): caminos/vías tienen PROHIBIDO
## modificar el terreno dentro de la banda de estas capas (los ríos van
## primero y su zanja es sagrada — el camino solo pasa por arriba en puente).
var protected_layers: Array[PathCarveLayer] = []
## FLATTEN_ALONG: el objetivo desciende SIEMPRE aguas abajo (ríos: el agua
## nunca sube — Minecraft/Rust tallan el lecho monotónico).
@export var monotonic_descent: bool = false
## FLATTEN_ALONG: pases de suavizado longitudinal del trayecto. Carreteras y
## vías usan MÁS pases → menos % de pendiente: el terraplén se eleva en las
## zanjas y el desmonte corta las lomas, como hace Rust con sus caminos.
@export_range(1, 12) var target_smooth_passes: int = 2
## FLATTEN_ALONG (carreteras/vías): ventana de PROMEDIO por longitud de arco
## (m). La calzada se apoya en la MEDIA del terreno de ±window a lo largo del
## trayecto — promedia varios centers (regla del usuario), así no quedan pozos
## ni muros de tierra. 0 = usa el suavizado 3-tap. El grado máx se aplica igual.
@export var smooth_window_m: float = 0.0
## Sesgo a CORTAR (0 = media pura; 1 = piso más bajo de la ventana). Corre el
## objetivo del camino/vía hacia el terreno BAJO → prefiere DESMONTE (bajar las
## lomas) antes que TERRAPLÉN (rellenar valles): mejor detalle, menos muros.
@export_range(0.0, 1.0, 0.05) var cut_bias: float = 0.0
## CIRCUITO CERRADO (anillo): el grading trata inicio y fin como el MISMO cuerpo
## (cíclico) — el empalme de la vía/carretera no tiene escalón (regla del
## usuario: "no conoce inicio y fin"). El provider lo marca en anillos.
@export var is_ring: bool = false
## FLATTEN_ALONG: offset sobre el terreno muestreado (río: -profundidad ⇒ zanja).
@export var target_offset_m: float = 0.0
## PENDIENTE MÁXIMA DE TALUD (m/m). Los cortes/rellenos profundos ABREN el
## falloff lo necesario para que el banco jamás sea un acantilado: el valle
## se ensancha con la profundidad, como los ríos de Rust (capturas del
## usuario: paredes verticales a los costados de la zanja). 0 = falloff fijo.
@export var max_bank_slope: float = 0.0
## Perfil en "U" del lecho: los bordes del canal suben este extra sobre el
## centro (parábola). El agua queda CONTENIDA en la U. 0 = lecho plano.
@export var bed_u_m: float = 0.0
## Confluencia: la desembocadura empalma con el AGUA de esta capa receptora
## (bake_targets lee su nivel en el punto de unión — el afluente entra al
## cuerpo de agua del río mayor, no corta en el aire).
var mouth_from_layer: PathCarveLayer = null
## Confluencia: desde este índice el cauce CARGA DOS FLUJOS y se ensancha
## (regla del usuario: dos ríos se unen y sale un cilindro más grande al mar).
## −1 = sin confluencia. Lo setea el provider en el RECEPTOR.
var confluence_index: int = -1
var confluence_scale: float = 1.0


## Metros de trayecto para alcanzar el ancho pleno (1.0). El río ENGROSA con la
## LONGITUD recorrida (regla del usuario: "va engrosando, cálculo de crecimiento";
## en su máximo ~2.5 m de ancho): un río corto queda angosto, uno largo llega al
## tope. 0 = crecimiento por índice (viejo comportamiento, no metros).
@export var grow_length_m: float = 0.0
var _arc := PackedFloat32Array()   # longitud acumulada por punto (lo llena prepare)


## Escala de ancho por punto: nace angosto (width_start_scale) → 1.0 al alcanzar
## grow_length_m de TRAYECTO (o en la boca si grow_length_m=0), × ensanche de
## confluencia aguas abajo de la unión.
func width_scale_at(i: int) -> float:
	var frac: float
	if grow_length_m > 0.0 and _arc.size() == points.size():
		frac = clampf(_arc[i] / grow_length_m, 0.0, 1.0)
	else:
		frac = float(i) / maxf(float(points.size() - 1), 1.0)
	var s := lerpf(width_start_scale, 1.0, frac)
	if confluence_index >= 0 and i >= confluence_index:
		s *= confluence_scale
	return s
## AGUA PRIMERO (ríos): bake_targets diseña el nivel de agua monotónico hasta
## el mar y deriva el lecho como agua − WATER_DEPTH_M. water_levels queda
## paralelo a points — WaterBuilder construye la mesh EXACTA de ese diseño.
@export var water_first: bool = false
var water_levels := PackedFloat32Array()
## Columna de agua POR PUNTO (crece del nacimiento a la boca — el cilindro
## esculpidor del usuario: un solo trazado define zanja Y agua a medida).
var water_depths := PackedFloat32Array()

# ---- grid hash de segmentos (solo lectura tras prepare) ----
var _cells: Dictionary = {}     # Vector2i -> PackedInt32Array (índices de segmento)
var _cell_size: float = 32.0
var _bbox: Rect2 = Rect2()      # footprint (points + reach); size 0 = sin puntos


func _init() -> void:
	layer_name = &"path_carve"


func affect_bounds() -> Rect2:
	return _bbox


## Tope del ensanche de falloff por talud (evita celdas de grid infinitas).
const MAX_BANK_FALLOFF := 30.0
## AGUA PRIMERO (regla del usuario, es LEY): el cuerpo de agua volumétrica se
## diseña ANTES y la zanja/isla se ADAPTA a él — el agua es el molde, el
## terreno su contenedor. Nunca al revés, nunca agua flotando.
const WATER_DEPTH_M := 1.2      # columna de agua dentro de la U
## Cuánto libra el camino/vía por encima del agua al cruzar un río (regla del
## usuario: discreto, no 2 m). 0.7 m: 40 cm inundaba los bordes de la banda (el
## grade_clamp baja el cruce hacia los vecinos); 0.7 es el mínimo que no moja.
const ROAD_RIVER_CLEARANCE := 0.7
const WATER_BELOW_GROUND := 1.3 # la superficie del agua vive bajo el terreno
const WATER_FREEBOARD := 0.4    # el terreno original SIEMPRE la contiene


func prepare(_ctx: HeightContext) -> void:
	_cells.clear()
	var reach := width_m * 0.5 + falloff_m
	if max_bank_slope > 0.0:
		reach = width_m * 0.5 + maxf(falloff_m, MAX_BANK_FALLOFF)
	_cell_size = maxf(reach * 2.0, 8.0)
	# Footprint = AABB de la polilínea + reach (mitad de ancho + falloff, ya
	# expandido por talud). Fuera de acá la capa no toca el terreno → el bake la
	# saltea. Margen extra de 1 celda por seguridad numérica.
	if points.size() >= 2:
		var lo := points[0]
		var hi := points[0]
		for p in points:
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		var m := reach + _cell_size
		_bbox = Rect2(lo - Vector2(m, m), (hi - lo) + Vector2(m, m) * 2.0)
	else:
		_bbox = Rect2()
	# Longitud de arco acumulada por punto (crecimiento del ancho por trayecto).
	_arc.resize(points.size())
	if points.size() > 0:
		_arc[0] = 0.0
		for i in range(1, points.size()):
			_arc[i] = _arc[i - 1] + points[i].distance_to(points[i - 1])
	for i in points.size() - 1:
		var a := points[i]
		var b := points[i + 1]
		var lo := Vector2(minf(a.x, b.x) - reach, minf(a.y, b.y) - reach)
		var hi := Vector2(maxf(a.x, b.x) + reach, maxf(a.y, b.y) + reach)
		var k0 := Vector2i(int(floorf(lo.x / _cell_size)), int(floorf(lo.y / _cell_size)))
		var k1 := Vector2i(int(floorf(hi.x / _cell_size)), int(floorf(hi.y / _cell_size)))
		for cy in range(k0.y, k1.y + 1):
			for cx in range(k0.x, k1.x + 1):
				var key := Vector2i(cx, cy)
				if not _cells.has(key):
					_cells[key] = PackedInt32Array()
				var arr: PackedInt32Array = _cells[key]
				arr.append(i)
				_cells[key] = arr


## Llena target_heights muestreando la pila previa a esta capa (lo llama el
## orquestador antes del bake) + suavizado longitudinal (media móvil ×2).
func bake_targets(sample_below: Callable) -> void:
	if use_precomputed_targets and target_heights.size() == points.size():
		return  # lecho definido por el diseño (río interpolado): no re-muestrear
	target_heights.resize(points.size())
	for i in points.size():
		target_heights[i] = sample_below.call(points[i])
	if water_first:
		_bake_water_first(sample_below)
	else:
		if smooth_window_m > 0.0 and points.size() >= 3:
			_window_average()   # media del terreno por ventana (anti-pozo/muro)
		else:
			for _pass in target_smooth_passes:
				var prev := target_heights.duplicate()
				for i in range(1, points.size() - 1):
					target_heights[i] = (prev[i - 1] + prev[i] + prev[i + 1]) / 3.0
		if monotonic_descent:
			# Pendiente mínima POR METRO (0.5%), no por punto: con polilíneas
			# densas (Chaikin) el drop por-punto sobre-excavaba el lecho 10+ m.
			for i in range(1, points.size()):
				var drop := points[i].distance_to(points[i - 1]) * 0.005
				target_heights[i] = minf(target_heights[i], target_heights[i - 1] - drop)
		if max_grade > 0.0 and points.size() >= 2:
			_grade_clamp(4)     # pendiente máx/metro, CÍCLICO si es anillo
		if target_offset_m != 0.0:
			for i in points.size():
				target_heights[i] += target_offset_m
	# CRUCE SOBRE RÍOS (regla del usuario): dentro de la banda protegida el
	# camino pasa POR ENCIMA del agua (lecho + 0.7 de agua + resguardo) —
	# jamás por debajo. Solo vale para cruces TRANSVERSALES cortos: un tramo
	# largo dentro de la banda es un camino PARALELO al río (el suavizado
	# post-desvío puede devolverlo encima) y ahí la zanja es sagrada — se
	# bloquea del todo (forense: road_flatten rellenaba ríos enteros).
	bridge_spans.clear()
	_band_state = PackedByteArray()
	if not protected_layers.is_empty():
		_band_state.resize(points.size())
		for i in points.size():
			for prot in protected_layers:
				if prot.distance_to_path(points[i]) \
						< prot.width_m * 0.5 + prot.falloff_m:
					_band_state[i] = 1
					break
		# Clasificar corridas consecutivas en banda: arco ≤ 55 m = cruce (1);
		# más largo = paralelo (2, bloqueado).
		var run_start := -1
		for i in points.size() + 1:
			var in_band := i < points.size() and _band_state[i] == 1
			if in_band and run_start < 0:
				run_start = i
			elif not in_band and run_start >= 0:
				var arc := 0.0
				for j in range(run_start, i - 1):
					arc += points[j].distance_to(points[j + 1])
				if arc > 55.0:
					for j in range(run_start, i):
						_band_state[j] = 2
				run_start = -1
		# Piso por punto de cruce: la calzada LEVANTA el terreno con su franja
		# angosta y pasa SOBRE el agua del río (solución original aprobada por
		# el usuario — nada de puentes de tablones ni alcantarillas de mesh).
		var floors := {}
		for i in points.size():
			if _band_state[i] != 1:
				continue
			for prot in protected_layers:
				if prot.distance_to_path(points[i]) \
						< prot.width_m * 0.5 + prot.falloff_m:
					var wtr := prot.path_water_at(points[i])
					if wtr < INF:
						# Solo +0.4 m SOBRE el agua (regla del usuario: el cruce NO
						# debe subir 2 m — apenas librar el agua). El max_grade
						# reparte esta subidita en la aproximación → cruce discreto.
						floors[i] = wtr + ROAD_RIVER_CLEARANCE
					else:
						var bed := prot.path_height_at(points[i])
						if bed < INF:
							floors[i] = bed + WATER_DEPTH_M + ROAD_RIVER_CLEARANCE
					break
		if not floors.is_empty() and max_grade > 0.0:
			# El piso del cruce (agua+2) es un pico; el clamp de pendiente CÍCLICO
			# lo reparte en una RAMPA de aproximación de varios centers a cada lado
			# (regla del usuario: sube de a poco antes del río, sin muro), y el
			# piso se re-aplica cada pasada para no perderlo. 6 pasadas convergen.
			for _pass in 6:
				for i: int in floors:
					target_heights[i] = maxf(target_heights[i], floors[i])
				_grade_clamp(1)
			for i: int in floors:
				target_heights[i] = maxf(target_heights[i], floors[i])
	# Confluencia/desembocadura del pipeline VIEJO (no water_first): el
	# empalme y la garantía de llegada ya los resuelve _bake_water_first().
	if not water_first and mouth_from_layer != null and points.size() >= 2:
		var join_bed := mouth_from_layer.path_height_at(points[points.size() - 1])
		if join_bed < INF:
			mouth_target_m = join_bed - 0.2  # cae DENTRO de la zanja receptora
			target_heights[points.size() - 1] = maxf(
					target_heights[points.size() - 1], mouth_target_m)
	if not water_first and mouth_target_m < INF and points.size() >= 2:
		var last := points.size() - 1
		target_heights[last] = minf(target_heights[last], mouth_target_m)
		for i in range(last - 1, -1, -1):
			var d := points[i].distance_to(points[i + 1])
			target_heights[i] = minf(target_heights[i],
					target_heights[i + 1] + d * max_backcut_per_m)
	# Detección de VANOS (puentes) — dos causas, unificadas por punto:
	#  a) el terreno real queda muy por debajo del trayecto (hondonada/zanja);
	#  b) el punto cae sobre la BANDA PROTEGIDA de un río (la zanja es
	#     intocable: el puente cruza orilla a orilla COMPLETO, no solo el hueco).
	# (Los cruces clasificados arriba ya agregaron sus vanos — no borrar acá.)
	if bridge_clearance_m > 0.0:
		var is_span := PackedByteArray()
		is_span.resize(points.size())
		for i in points.size():
			var gap: float = target_heights[i] - float(sample_below.call(points[i]))
			var flagged := gap > bridge_clearance_m
			if not flagged:
				for prot in protected_layers:
					if prot.distance_to_path(points[i]) \
							< prot.width_m * 0.5 + prot.falloff_m:
						flagged = true
						break
			is_span[i] = 1 if flagged else 0
		var span_start := -1
		for i in points.size():
			if is_span[i] == 1:
				if span_start < 0:
					span_start = i
			elif span_start >= 0:
				bridge_spans.append(Vector2i(span_start, i - 1))
				span_start = -1
		if span_start >= 0:
			bridge_spans.append(Vector2i(span_start, points.size() - 1))


## Cantidad de puntos ÚNICOS: en un anillo el último == el primero (duplicado),
## así que se gradúa sobre n-1 y el duplicado se copia al final.
func _seg_count() -> int:
	return (points.size() - 1) if (is_ring and points.size() > 2) else points.size()


## Índice vecino (dir = +1 siguiente, -1 anterior). Envuelve si es anillo; -1 si
## se sale del trayecto abierto.
func _neighbor(i: int, dir: int, m: int) -> int:
	if is_ring and m > 0:
		return (i + dir + m) % m
	var j := i + dir
	return j if (j >= 0 and j < m) else -1


## Media del terreno por VENTANA de arco (triangular). Cíclica si is_ring: la
## ventana envuelve el anillo → el empalme inicio=fin queda liso. Mata pozos/muros.
## Con cut_bias > 0 el objetivo se corre hacia el terreno BAJO de la ventana
## (regla del usuario: cruzando entre montañas es mejor CORTAR la montaña que
## rellenar el valle — desmonte con pendiente suave, no un terraplén enorme).
func _window_average() -> void:
	var n := points.size()
	var m := _seg_count()
	var raw := target_heights.duplicate()
	for i in m:
		var sum := raw[i]
		var wsum := 1.0
		var wmin := raw[i]
		for dir in [1, -1]:
			var acc := 0.0
			var cur := i
			while true:
				var nb := _neighbor(cur, dir, m)
				if nb < 0 or nb == i:
					break
				acc += points[cur].distance_to(points[nb])
				if acc > smooth_window_m:
					break
				var w := 1.0 - acc / smooth_window_m
				sum += raw[nb] * w
				wsum += w
				wmin = minf(wmin, raw[nb])
				cur = nb
		var mean := sum / maxf(wsum, 0.001)
		target_heights[i] = lerpf(mean, wmin, clampf(cut_bias, 0.0, 1.0))
	if is_ring and n > 2:
		target_heights[n - 1] = target_heights[0]


## Clamp de PENDIENTE máxima por metro, CÍCLICO si es anillo (el empalme se
## gradúa como cualquier tramo). El trayecto queda tendido: rellena valles y
## corta lomas hasta respetar max_grade.
func _grade_clamp(passes: int) -> void:
	var n := points.size()
	var m := _seg_count()
	for _p in passes:
		for i in m:  # forward (vecino anterior)
			var prev := _neighbor(i, -1, m)
			if prev < 0:
				continue
			var d := points[i].distance_to(points[prev]) * max_grade
			target_heights[i] = clampf(target_heights[i],
					target_heights[prev] - d, target_heights[prev] + d)
		for i in range(m - 1, -1, -1):  # backward (vecino siguiente)
			var nxt := _neighbor(i, 1, m)
			if nxt < 0:
				continue
			var d2 := points[i].distance_to(points[nxt]) * max_grade
			target_heights[i] = clampf(target_heights[i],
					target_heights[nxt] - d2, target_heights[nxt] + d2)
	if is_ring and n > 2:
		target_heights[n - 1] = target_heights[0]


## AGUA PRIMERO: diseña el NIVEL DE AGUA (bajo el terreno original siempre,
## monotónico aguas abajo, anclado al mar o al agua del receptor) y deriva el
## lecho como agua − WATER_DEPTH_M. La zanja es el molde EXACTO del agua
## volumétrica — la isla se adapta al agua, no al revés (regla del usuario).
func _bake_water_first(sample_below: Callable) -> void:
	var n := points.size()
	if n < 2:
		return
	var t_raw := target_heights.duplicate()
	for _pass in target_smooth_passes:
		var prev := target_heights.duplicate()
		for i in range(1, n - 1):
			target_heights[i] = (prev[i - 1] + prev[i] + prev[i + 1]) / 3.0
	water_levels.resize(n)
	water_depths.resize(n)
	var n1 := float(maxi(n - 1, 1))
	for i in n:
		# NACIMIENTO INTACTO (regla del usuario: "el punto más alto no
		# debería ni moverse"): el río nace A FLOR DE TIERRA — hundimiento y
		# columna crecen del nacimiento (0.35 m) a los valores plenos al 33%
		# del trayecto. El cilindro esculpidor se engrosa río abajo.
		var grow := clampf(float(i) / n1 * 3.0, 0.0, 1.0)
		water_depths[i] = lerpf(0.35, WATER_DEPTH_M, grow)
		# CONTENCIÓN REAL: el agua vive bajo el terreno del eje Y de AMBAS
		# orillas (muestreo lateral al borde del canal). En ladera cruzada,
		# la orilla baja queda POR ENCIMA del agua — y donde el terreno está
		# más bajo que el lecho, el flatten lo LEVANTA como leva natural
		# (Rust: el río "prepara el terreno disimuladamente" a su paso).
		var dirv := (points[mini(i + 1, n - 1)] - points[maxi(i - 1, 0)]).normalized()
		var perp := Vector2(-dirv.y, dirv.x)
		var half_w := width_m * width_scale_at(i) * 0.5
		var side_l: float = sample_below.call(points[i] + perp * (half_w + 1.5))
		var side_r: float = sample_below.call(points[i] - perp * (half_w + 1.5))
		var contain := minf(t_raw[i], minf(side_l, side_r))
		water_levels[i] = minf(
				target_heights[i] - lerpf(0.35, WATER_BELOW_GROUND, grow),
				contain - lerpf(0.15, WATER_FREEBOARD, grow))
	# El agua solo BAJA aguas abajo (0.3% por metro mínimo).
	for i in range(1, n):
		var drop := points[i].distance_to(points[i - 1]) * 0.003
		water_levels[i] = minf(water_levels[i], water_levels[i - 1] - drop)
	# Boca: el nivel EMPALMA con el mar (mismo cuerpo que el océano, como
	# Rust) o con el AGUA del río receptor (confluencia). Hacia atrás sube
	# con pendiente acotada — sin crestas ni caídas absurdas.
	var mouth_w := mouth_target_m
	if mouth_from_layer != null:
		var jw := mouth_from_layer.path_water_at(points[n - 1])
		if jw < INF:
			mouth_w = jw
	if mouth_w < INF:
		water_levels[n - 1] = mouth_w
		for i in range(n - 2, -1, -1):
			var d := points[i].distance_to(points[i + 1])
			water_levels[i] = minf(water_levels[i],
					water_levels[i + 1] + d * max_backcut_per_m)
	# El lecho es el contenedor a medida: superficie − columna del cilindro.
	# ENTIERRO MÍNIMO (regla del usuario: el cilindro se entierra al menos a
	# casi la mitad del cuerpo): pasado el nacimiento, el lecho baja SIEMPRE
	# ≥1.8 m bajo el terreno original — el molde se nota en toda la zanja.
	for i in n:
		var grow2 := clampf(float(i) / n1 * 3.0, 0.0, 1.0)
		target_heights[i] = minf(water_levels[i] - water_depths[i],
				t_raw[i] - lerpf(0.5, 1.8, grow2))


## Nivel de AGUA del trayecto en el punto más cercano a pos (INF si lejos).
func path_water_at(pos: Vector2) -> float:
	return _path_value_at(pos, water_levels)


## Distancia de pos al eje de esta polilínea (INF si lejos del grid).
func distance_to_path(pos: Vector2) -> float:
	var key := Vector2i(int(floorf(pos.x / _cell_size)), int(floorf(pos.y / _cell_size)))
	var best := INF
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var segs: PackedInt32Array = _cells.get(key + Vector2i(dx, dy), PackedInt32Array())
			for si in segs:
				var a := points[si]
				var b := points[si + 1]
				var ab := b - a
				var len2 := ab.length_squared()
				var t := clampf((pos - a).dot(ab) / len2, 0.0, 1.0) if len2 > 0.000001 else 0.0
				best = minf(best, pos.distance_to(a + ab * t))
	return best


## Altura del trayecto (target interpolado) en el punto más cercano a pos.
## INF si pos queda fuera del grid o los targets no están bakeados.
func path_height_at(pos: Vector2) -> float:
	return _path_value_at(pos, target_heights)


func _path_value_at(pos: Vector2, values: PackedFloat32Array) -> float:
	if values.size() != points.size():
		return INF
	var key := Vector2i(int(floorf(pos.x / _cell_size)), int(floorf(pos.y / _cell_size)))
	var best_d := INF
	var best_i := -1
	var best_t := 0.0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var segs: PackedInt32Array = _cells.get(key + Vector2i(dx, dy), PackedInt32Array())
			for si in segs:
				var a := points[si]
				var b := points[si + 1]
				var ab := b - a
				var len2 := ab.length_squared()
				var t := clampf((pos - a).dot(ab) / len2, 0.0, 1.0) if len2 > 0.000001 else 0.0
				var d := pos.distance_to(a + ab * t)
				if d < best_d:
					best_d = d
					best_i = si
					best_t = t
	if best_i < 0:
		return INF
	return lerpf(values[best_i], values[best_i + 1], best_t)


func apply(pos: Vector2, h: float, ctx: HeightContext) -> float:
	if points.size() < 2:
		return h
	var w := strength * (1.0 if mask == null else mask.weight(pos, ctx))
	if w <= 0.0001:
		return h
	var key := Vector2i(int(floorf(pos.x / _cell_size)), int(floorf(pos.y / _cell_size)))
	var best_d := INF
	var best_i := -1
	var best_t := 0.0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var segs: PackedInt32Array = _cells.get(key + Vector2i(dx, dy), PackedInt32Array())
			for si in segs:
				var a := points[si]
				var b := points[si + 1]
				var ab := b - a
				var len2 := ab.length_squared()
				var t := 0.0
				if len2 > 0.000001:
					t = clampf((pos - a).dot(ab) / len2, 0.0, 1.0)
				var d := pos.distance_to(a + ab * t)
				if d < best_d:
					best_d = d
					best_i = si
					best_t = t
	if best_i < 0:
		return h
	# Ancho efectivo por punto: la zanja se ABRE a lo largo del trayecto (y más
	# tras una confluencia).
	var w_eff := width_m * width_scale_at(best_i)
	var half := w_eff * 0.5
	if path_mode == PathMode.CARVE:
		var lat_c := clampf((best_d - half) / maxf(falloff_m, 0.001), 0.0, 1.0)
		if lat_c >= 1.0:
			return h
		var fc: float
		if profile != null:
			fc = profile.sample_baked(lat_c)
		else:
			fc = 1.0 - smoothstep(0.0, 1.0, lat_c)
		return h - depth_m * fc * w
	# ---- FLATTEN_ALONG ----
	if target_heights.size() != points.size():
		return h  # bake_targets no corrió — no tocar
	# Tramo en VANO de puente: el terreno queda intacto (la zanja del río
	# pasa por debajo); el tablero lo pone BridgeBuilder.
	for span in bridge_spans:
		if best_i >= span.x and best_i <= span.y:
			return h
	var target := lerpf(target_heights[best_i], target_heights[best_i + 1], best_t)
	# Sección de CILINDRO (regla del usuario): un cilindro acostado enterrado en
	# la arena deja una zanja de fondo casi plano al centro y paredes que suben en
	# ARCO DE CÍRCULO hacia la orilla — no una "U" parabólica. `bed_u_m` = cuánto
	# sube el lecho del centro al borde del canal (el % del cilindro enterrado).
	if bed_u_m > 0.0 and best_d < half:
		var frac := best_d / maxf(half, 0.001)
		target += bed_u_m * (1.0 - sqrt(maxf(1.0 - frac * frac, 0.0)))
	# LEVA DE ORILLA (agua-primero): del 70% del canal hacia afuera el
	# objetivo nunca baja de agua + 0.35 — la orilla queda SIEMPRE sobre el
	# nivel, también en el lado bajo de una ladera (el lerp solo no puede
	# levantar por encima de sus dos extremos → el agua se derramaba).
	# Es la orilla "preparada disimuladamente" de Rust.
	if water_first and water_levels.size() == points.size() \
			and best_d >= half * 0.7:
		var wlev := lerpf(water_levels[best_i], water_levels[best_i + 1], best_t)
		target = maxf(target, wlev + 0.35)
	# Cruce/paralelo de río: la calzada SIEMPRE aplana su ancho y LEVANTA el
	# terreno por encima del agua — NUNCA deja la zanja cruda (regla del usuario:
	# "el camino no puede partirse y formar un hueco; si el río está 2 m abajo, se
	# levanta el terreno y el río queda enterrado"). Antes, en tramo paralelo se
	# hacía `return h` y la vía/camino quedaba flotando sobre la zanja (hueco de
	# las capturas). Ahora siempre aplana; hombros de 4 m (terraplén real, no
	# cuchilla). El ruteo (_deflect_from_rivers) evita correr paralelo a un río.
	var eff_falloff := falloff_m
	var in_protected := false
	for prot in protected_layers:
		if prot.distance_to_path(pos) < prot.width_m * 0.5 + prot.falloff_m:
			in_protected = true
			break
	if in_protected:
		eff_falloff = 4.0
	# Talud con pendiente máxima: el corte/relleno profundo ensancha el
	# falloff — el banco del río es una ladera subible, nunca un acantilado.
	if max_bank_slope > 0.0 and not in_protected:
		eff_falloff = clampf(absf(h - target) / max_bank_slope,
				eff_falloff, MAX_BANK_FALLOFF)
	var lateral := clampf((best_d - half) / maxf(eff_falloff, 0.001), 0.0, 1.0)
	if lateral >= 1.0:
		return h
	var factor: float
	if profile != null:
		factor = profile.sample_baked(lateral)
	else:
		factor = 1.0 - smoothstep(0.0, 1.0, lateral)
	factor *= w
	return lerpf(h, target, minf(factor, 1.0))
