class_name MapGenerationConfig
extends Resource

## ============================================================================
## MapGenerationConfig · Identidad completa de un mapa procedural
## ============================================================================
## Mismo config (semillas incluidas) ⇒ mismo mundo, bit a bit (invariante de
## determinismo, docs/PROCEDURAL_MAP_PLAN.md §3.6). Se consume por
## MapDataProvider (grafo Voronoi) y HeightSampler (escala vertical).
## ============================================================================

@export_group("Semillas")
@export var seed_shape: int = 85882
@export var seed_variant: int = 8

@export_group("Isla")
@export_enum("radial", "perlin", "square", "blob", "circle") var island_shape: String = "radial"
@export_enum("random", "relaxed", "square", "hexagon") var point_mode: String = "relaxed"
## Puntos del grafo (celdas Voronoi). MÁS puntos = isla más detallada. Para una
## isla GRANDE hay que subir esto proporcional al map_size o queda dispersa.
@export_range(500, 80000, 100) var num_points: int = 2000
## Lado de la isla en metros. Libre hasta 65 km (objetivo). El heightfield GLOBAL es
## de resolución FIJA (bake_resolution²) → no crece con el tamaño ni da OOM; el
## detalle fino cerca lo aporta el streaming por regiones (terrain_region_stream).
## Para que la DENSIDAD de rasgos se mantenga, subí num_points junto con esto.
## Caveat: el navmesh full sí crece con el área (ver known-issues); a 65 km usar
## navmesh por región o desactivarlo.
@export_range(200.0, 65000.0, 50.0) var map_size: float = 600.0

## --- RELIEVE COSTERO (CoastalReliefLayer) ---
## Altura del relieve que crece de la COSTA hacia el INTERIOR (m). 0 = apagado
## (silueta actual sin cambios). Es la capa que hace que la isla NO se vea igual
## en todos lados: costa suave, interior accidentado.
@export var coastal_relief_m: float = 0.0
## Cuánto de ese relieve queda en la costa (bajo = playas y planicies limpias).
@export_range(0.0, 1.0) var coastal_relief_coast: float = 0.12
## Dureza de la transición costa→interior. Alto = ACANTILADOS.
@export_range(1.0, 6.0) var coastal_relief_cliffs: float = 2.2
## PSEUDO-EROSIÓN (técnica de Rust): crestas afiladas con valles en V.
@export_range(0.0, 1.0) var coastal_relief_ridged: float = 0.5
## PSEUDO-EROSIÓN: distorsión de coordenadas (m). Da cauces quebrados.
@export var coastal_relief_warp_m: float = 60.0
## Metros de altura de la elevación 1.0 del grafo.
@export var height_scale: float = 40.0
## Relieve base (pipeline Fase B1): la costa sube a una MESETA de esta altura y
## el interior queda plano ahí — los rasgos (montañas/acantilados) son lo único
## alto encima. 0 = usar la silueta cruda del grafo (alto en el centro, viejo).
@export var plateau_height_m: float = 12.0
## Largo de la rampa costera: fracción de elevación del grafo donde la rampa MÁS
## CORTA alcanza la meseta (menor = la isla se levanta más cerca de la costa). El
## ruido de la capa la alarga random (más suave). 0.12 ≈ rampa corta tipo Rust.
@export_range(0.02, 1.0, 0.01) var plateau_ramp: float = 0.12

@export_group("Océano")
@export_range(0, 8000, 50) var ocean_points: int = 500
@export var ocean_distance: float = 300.0
## Vacío = usa point_mode.
@export_enum(" ", "random", "relaxed", "square", "hexagon") var ocean_point_mode: String = " "

@export_group("Ríos")
@export_range(0, 32) var num_rivers: int = 8
## Cómo se TRAZAN los ríos (TERRAIN_PIPELINE_V2_PLAN §F4):
## GRAPH = downslope del grafo Voronoi (comportamiento actual).
## RASTER = hidrología sobre el heightfield base (Priority-Flood + D8):
## garantía matemática de llegar al mar, confluencias por acumulación.
@export_enum("GRAPH", "RASTER") var hydrology_mode: String = "GRAPH"
## Ancho MÁXIMO del canal. Objetivo del usuario ~2.5 m; HOY 6.0 porque acotarlo
## a 2.5 destapa que el ruteo cruza terreno alto (rio corta 6 m, no contiene) —
## necesita el rework de trayectoria (que siga el terreno) antes de bajar esto.
## Ver backlog #143/#146.
# ENGROSADOS (pedido del usuario, y es lo que hizo Rust: "make rivers wider").
# 6 m era un arroyo; 14 m es un rio en el que se nada y se navega en bote.
@export var river_width_m: float = 10.0
## Zanja estilo Rust: profundidad CASI CONSTANTE (el río empieza angosto y se
## ensancha; lo que cambia es el ancho, no el pozo). Objetivo del usuario ~1.5 m;
## ver nota de river_width_m.
@export var river_depth_m: float = 3.8
# El falloff es la ORILLA: cuanto tarda la zanja en fundirse con el terreno. Si
# queda corto respecto al ancho, el rio parece un canal cavado a pico.
@export var river_falloff_m: float = 11.0
## Metros de trayecto para que el río alcance su ancho pleno (CRECIMIENTO por
## trayecto, regla del usuario): río corto = angosto, largo = ancho pleno.
@export var river_grow_length_m: float = 220.0

@export_group("Lagos")
## Cantidad deseada de lagos: si el grafo no da suficientes celdas LAKE, se
## eligen celdas de tierra adentro aptas (determinista por semilla).
@export_range(0, 12) var num_lakes: int = 3

@export_group("Carreteras")
## §F3: SPLIT = carretera y vía como circuitos independientes (actual).
## CORRIDOR = UN corredor por el contorno de la isla: carretera y vía paralelas
## del MISMO spine — el terreno se esculpe UNA sola vez para ambas.
@export_enum("SPLIT", "CORRIDOR") var corridor_mode: String = "SPLIT"
## CORRIDOR: distancia del eje del corredor a la costa (m).
@export var corridor_coast_dist_m: float = 46.0
## CORRIDOR: separación lateral entre eje de carretera y eje de vía (m).
@export var corridor_gap_m: float = 9.0
@export_enum("CIRCUIT", "NETWORK", "BOTH") var road_mode: String = "CIRCUIT"
@export_range(0.0, 1.0, 0.01) var road_shape_scale: float = 0.92
@export var road_width_m: float = 9.0
@export var road_falloff_m: float = 11.0

@export_group("Vía de Tren")
@export var rail_enabled: bool = true
## Anillo de la vía (método pcg-terrain_1): 1.0 = costa, 0.0 = centro.
## La carretera usa road_shape_scale (default 0.92) — la vía va más adentro.
@export_range(0.0, 1.0, 0.01) var rail_shape_scale: float = 0.55
@export var rail_width_m: float = 5.0
@export var rail_falloff_m: float = 8.0

@export_group("Clima")
@export_range(-1.0, 1.0, 0.1) var north_temperature_bias: float = 0.0
@export_range(-1.0, 1.0, 0.1) var south_temperature_bias: float = 0.0

## --- CIRCUITO: carretera y vía que se INTERCAMBIAN de lado ---
## Cuántas veces, en una vuelta completa al anillo, la carretera y la vía cambian
## cuál va del lado de la costa y cuál del lado del centro. 0 = paralelas fijas
## (comportamiento anterior). Donde se cruzan queda el punto de CRUCE natural.
@export_range(0, 12) var corridor_swaps: int = 0
## Separación mínima en el punto de cruce, como fracción del hueco normal.
## 0 = se tocan; 0.12 deja luz para el paso a distinto nivel.
@export_range(0.0, 0.5) var corridor_swap_min: float = 0.12

## RAMALES: caminos que SALEN del circuito y RECONECTAN en otro punto, metiendose
## hacia el interior. Sin ellos el anillo es una pista cerrada y nada lleva al
## centro de la isla. 0 = sin ramales.
@export_range(0, 8) var corridor_branches: int = 0
## Cuánto del anillo abarca cada ramal (fracción de la vuelta).
@export_range(0.05, 0.4) var corridor_branch_span: float = 0.18
