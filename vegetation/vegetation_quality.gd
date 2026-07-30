class_name VegetationQuality
extends RefCounted

## ============================================================================
## VegetationQuality · Knobs GLOBALES de calidad de vegetación (opciones gráficas)
## ============================================================================
## El jugador optimiza a gusto desde el menú de opciones: densidad, agresividad
## del LOD y resolución de texturas de corteza. Valores globales (static) que el
## resto del sistema lee. La densidad y el LOD no rompen el determinismo del
## multiplayer (solo cambian CUÁNTO se dibuja y a qué distancia, no las semillas).
##
## Preset rápido: VegetationQuality.apply_preset("bajo"|"medio"|"alto"|"ultra").
## ============================================================================

## Multiplicador de cantidad de instancias (matas/árboles/arbustos). 1.0 = base.
static var density_scale: float = 1.0
## Escala las distancias de LOD/impostor. <1 = LOD más agresivo (más FPS, popping),
## >1 = detalle a más distancia (más lindo, más costo).
static var lod_bias: float = 1.0
## Lado en px de las texturas de corteza generadas (128/256/512). Menor = más FPS.
static var bark_texture_size: int = 256
## Sombras proyectadas por la vegetación (matas/copas). Apagar = FPS en móviles.
static var cast_shadows: bool = true
## Índice del preset actual (0 bajo · 1 medio · 2 alto · 3 ultra). Lo usa la
## PLANTILLA de LOD (lod_row) para dar distancias por preset y familia.
static var preset_index: int = 2

## ALCANCE de LOD0/LOD1 configurable por el jugador (opción de gráficos, %).
## lod0_reach estira dónde termina el 3D cercano (full_end): al subirlo, el LOD1
## (imagen cruzada) empieza más lejos. lod1_reach estira dónde termina la imagen
## cruzada (y empieza el impostor). 1.0 = plantilla; 1.5 = +50% de alcance. Mover
## estos corre la cadena secuencial completa sin tocar el mundo (solo el render).
static var lod0_reach: float = 1.0
static var lod1_reach: float = 1.0

## ============================================================================
## PLANTILLA DE LOD (docs/LOD_PLANTILLA.md) — distancias por PRESET y FAMILIA.
## `start`: nivel de arranque (0 full · 1 saltea a 45% · 2 saltea a 18%) — bajar
## calidad SALTEA el LOD0 caro. `full/far/far2` = FIN de cada nivel (m); `imp` =
## fin del impostor = cull. far2=0 → sin ese nivel. Ultra sube el 3D (full) más
## lejos, NO la densidad (regla de oro).
## ============================================================================
## REGLA DURA (bug "3 árboles a la vez", 2026-07-18): el LOD se mide contra el
## AABB de la CELDA (48 m) — TODA distancia de transición debe SUPERAR la
## diagonal de celda (~34 m + margen de fade), si no, parado al lado de un árbol
## en el borde de su celda se ven full+far+cruzadas fundidos (los "translúcidos").
## Con el presupuesto pro (full ≈ 15k) extender el full a 40-60 m es pagable.
## Familia A — ÁRBOLES (silueta lejana: impostor hasta cientos de m).
## Índice = preset: 0 potato · 1 bajo · 2 medio · 3 alto · 4 ultra.
const TREE_LOD := [
	{"start": 1, "full": 0.0,  "far": 45.0, "far2": 80.0,  "imp": 450.0},   # potato
	{"start": 1, "full": 0.0,  "far": 45.0, "far2": 85.0,  "imp": 700.0},   # bajo
	{"start": 0, "full": 40.0, "far": 75.0, "far2": 110.0, "imp": 1100.0},  # medio
	{"start": 0, "full": 45.0, "far": 85.0, "far2": 125.0, "imp": 1400.0},  # alto
	{"start": 0, "full": 60.0, "far": 100.0, "far2": 145.0, "imp": 1800.0}, # ultra
]
## Familia B — ARBUSTOS / ROCAS / PLANTAS (detalle cercano: cull corto). Misma
## regla: full ≥ ~38 m o el arbusto de al lado se ve doble.
const NEAR_LOD := [
	{"start": 1, "full": 0.0,  "far": 40.0, "far2": 0.0,  "imp": 55.0},   # potato
	{"start": 1, "full": 0.0,  "far": 42.0, "far2": 0.0,  "imp": 60.0},   # bajo
	{"start": 0, "full": 38.0, "far": 55.0, "far2": 0.0,  "imp": 70.0},   # medio
	{"start": 0, "full": 40.0, "far": 58.0, "far2": 0.0,  "imp": 80.0},   # alto
	{"start": 0, "full": 45.0, "far": 65.0, "far2": 0.0,  "imp": 100.0},  # ultra
]


## Fila de plantilla del preset actual. is_tree = familia A (árbol alto).
## DISTANCIA DE CULLEO pedida por el menú, en METROS, por familia. 0 = usar la
## fila del preset tal cual.
##
## Existe por dos motivos, y el segundo se descubrió con un test que falló:
##  1. El menú tiene DOS opciones separadas —"calidad de árboles" y "calidad de
##     decorado"— y las dos caían sobre `preset_index`: mover una pisaba a la
##     otra.
##  2. Guardarlo como MULTIPLICADOR no servía: el menú muestra "130 m" pero el
##     multiplicador se aplica sobre la fila del preset ACTUAL, así que con el
##     preset en medio entregaba 91 m. El número en pantalla habría MENTIDO, que
##     es justo lo que este sistema existe para impedir. Se guarda el metraje y
##     la escala se deriva de él.
static var tree_cull_m: float = 0.0
static var near_cull_m: float = 0.0


static func lod_row(is_tree: bool) -> Dictionary:
	var t: Array = TREE_LOD if is_tree else NEAR_LOD
	var base: Dictionary = t[clampi(preset_index, 0, 4)]
	var want := tree_cull_m if is_tree else near_cull_m
	if want <= 0.0:
		return base
	# La escala sale de comparar lo pedido contra ESTA fila: así el culleo queda
	# exactamente en los metros que dice el menú, y el resto de las distancias
	# (full/far/far2) acompañan en proporción.
	var k := want / maxf(float(base["imp"]), 0.001)
	# `start` NO se escala: es un índice de nivel, no una distancia.
	return {
		"start": base["start"],
		"full": float(base["full"]) * k,
		"far": float(base["far"]) * k,
		"far2": float(base["far2"]) * k,
		"imp": float(base["imp"]) * k,
	}


static func apply_preset(name: String) -> void:
	match name:
		# SEPARACIÓN MUNDO/RENDER (regla del usuario, 2026-07-18): la calidad NO
		# cambia CUÁNTOS árboles/arbustos/plantas EXISTEN (eso es el MUNDO, igual
		# para todos y para el server) — solo cambia la REPRESENTACIÓN: distancias
		# LOD, cuándo pasan a cruzadas/impostor, sombras y resolución de texturas.
		# density_scale = 1.0 SIEMPRE (el raleo visual lejano lo hace density-LOD,
		# que solo oculta instancias por distancia, sin tocar el mundo).
		"potato":  # todo al mínimo (hardware muy débil)
			preset_index = 0
			density_scale = 1.0
			lod_bias = 0.4
			bark_texture_size = 128
			cast_shadows = false
		"bajo":
			preset_index = 1
			density_scale = 1.0
			lod_bias = 0.55
			bark_texture_size = 128
			cast_shadows = false
		"medio":
			preset_index = 2
			density_scale = 1.0
			lod_bias = 0.75
			bark_texture_size = 256
			cast_shadows = true
		"ultra":
			# ULTRA = LO NORMAL (el look tal cual se diseñó, factor 1.0). Los demás
			# presets BAJAN desde acá — nunca "más gráficos que lo normal".
			preset_index = 4
			density_scale = 1.0
			lod_bias = 1.0
			bark_texture_size = 512
			cast_shadows = true
		_:  # "alto" (default)
			preset_index = 3
			density_scale = 1.0
			lod_bias = 0.85   # alto = un escalón bajo lo normal (ultra 1.0)
			bark_texture_size = 256
			cast_shadows = true
