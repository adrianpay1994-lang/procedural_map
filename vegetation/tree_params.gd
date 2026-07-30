class_name TreeParams
extends Resource

## ============================================================================
## TreeParams · Parámetros Weber & Penn para TreeGenerator (config por Inspector)
## ============================================================================
## Arrays de 4 = un valor por nivel de ramificación (0=tronco, 1, 2, 3+).
## Portados de tree-gen/parametric/tree_params/*.py. Defaults = quaking_aspen.
## ============================================================================

@export var shape: int = 7            ## silueta global (0-8, ver shape_ratio)
@export var g_scale: float = 13.0     ## altura objetivo del tronco (m)
@export var g_scale_v: float = 3.0    ## varianza de g_scale
@export_range(1, 4) var levels: int = 3
@export var ratio: float = 0.015      ## radio tronco = length * ratio
@export var ratio_power: float = 1.2
@export var flare: float = 0.6        ## ensanche de la base del tronco
@export var base_splits: int = 0
@export var base_size: PackedFloat32Array = PackedFloat32Array([0.3, 0.02, 0.02, 0.02])
@export var down_angle: PackedFloat32Array = PackedFloat32Array([0.0, 60.0, 45.0, 45.0])
@export var down_angle_v: PackedFloat32Array = PackedFloat32Array([0.0, -50.0, 10.0, 10.0])
@export var rotate: PackedFloat32Array = PackedFloat32Array([0.0, 140.0, 140.0, 77.0])
@export var rotate_v: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
@export var branches: PackedInt32Array = PackedInt32Array([1, 50, 30, 10])
@export var length: PackedFloat32Array = PackedFloat32Array([1.0, 0.3, 0.6, 0.0])
@export var length_v: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
@export var taper: PackedFloat32Array = PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
@export var seg_splits: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
@export var split_angle: PackedFloat32Array = PackedFloat32Array([40.0, 0.0, 0.0, 0.0])
@export var split_angle_v: PackedFloat32Array = PackedFloat32Array([5.0, 0.0, 0.0, 0.0])
@export var curve_res: PackedInt32Array = PackedInt32Array([5, 5, 3, 1])
@export var curve: PackedFloat32Array = PackedFloat32Array([0.0, -40.0, -40.0, 0.0])
@export var curve_back: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
@export var curve_v: PackedFloat32Array = PackedFloat32Array([20.0, 50.0, 75.0, 0.0])
@export var bend_v: PackedFloat32Array = PackedFloat32Array([0.0, 50.0, 0.0, 0.0])
## Tropismo en espacio Weber-Penn Z-up (z = arriba). Pull de gravedad/luz.
@export var tropism: Vector3 = Vector3(0.0, 0.0, 0.5)

## ---- Presupuesto de tiempo real (juego, propios) ----
## Escala ramas/hojas hacia abajo para árboles de fondo instanciados. 1.0 = fiel
## a Weber-Penn (hero render); ~0.5 = juego de mundo abierto.
@export_range(0.1, 1.0) var detail: float = 0.5
## Tope de segmentos por rama (los presets usan hasta 10; 4 alcanza para fondo).
@export_range(1, 12) var max_curve_res: int = 4

## ---- Geometría/estética (propios, no Weber-Penn) ----
@export_range(3, 8) var trunk_sides: int = 6   ## lados del anillo de corteza
@export var leaf_count: int = 55               ## hojas objetivo (0 = sin copa)
@export var leaf_card_size: float = 0.9
@export var leaf_texture: String = "broadleaf" ## assets/vegetation/leaves/<x>.png
## Override de textura de hoja por IMAGEN (FloraConfig, inspector). NO @export:
## es runtime — lo setea FloraConfig.apply() para una imagen externa. null = usar
## `leaf_texture` (nombre procedural). Ver flora_config.gd.
var leaf_texture_override: Texture2D = null
## Corteza por imagen externa (FloraConfig): albedo + normal. null = BarkTexture.
var bark_tex_override: Texture2D = null
var bark_normal_override: Texture2D = null
## Modelo de HOJA propio (FloraConfig method MESH): se instancia en cada punto de
## hoja en vez de las cards. null = cards/sprays normales.
var leaf_mesh_override: Mesh = null
## Knobs de copa (FloraConfig): 0 = defaults del generador (keep 0.7, scale 1.55).
var canopy_density_override: float = 0.0
var spray_scale_override: float = 0.0
## Presupuesto de sprays de copa (0 = default 1400). Lo bajan los pools LOD
## lejanos (far 300 / far2 120) — señal explícita, no inferida del detail.
var canopy_budget_override: int = 0
@export var leaf_color: Color = Color(0.28, 0.5, 0.2)
@export var trunk_color: Color = Color(0.38, 0.28, 0.18)
## Patrón de corteza: fissured · smooth · scaly · lenticel · stringy (BarkTexture).
@export var bark_type: String = "fissured"
## Radio (m) por debajo del cual NO se malla la corteza de la ramita: las ramitas
## finas quedan tapadas por el follaje, así que su tubo es geometría desperdiciada.
## Subirlo = menos vértices (más FPS); bajarlo = ramitas visibles sin hojas.
@export var min_bark_radius: float = 0.02


## Preset por defecto = quaking_aspen (los defaults ya lo son).
static func aspen() -> TreeParams:
	var p := TreeParams.new()
	p.ratio = 0.022  # tronco algo más grueso (el 0.015 se veía flaco)
	p.leaf_color = Color(0.42, 0.55, 0.22)  # álamo temblón, verde claro
	p.trunk_color = Color(0.72, 0.72, 0.66)  # corteza pálida
	return p


## Roble negro de California (tree-gen black_oak): copa hemisférica ancha.
static func black_oak() -> TreeParams:
	var p := TreeParams.new()
	p.shape = 2
	p.g_scale = 10.0
	p.g_scale_v = 2.0
	p.levels = 3
	p.ratio = 0.018
	p.ratio_power = 1.25
	p.flare = 1.2
	p.base_size = PackedFloat32Array([0.05, 0.02, 0.02, 0.02])
	p.down_angle = PackedFloat32Array([0.0, 30.0, 45.0, 45.0])
	p.down_angle_v = PackedFloat32Array([0.0, -30.0, 10.0, 10.0])
	p.rotate = PackedFloat32Array([0.0, 80.0, 140.0, 140.0])
	p.rotate_v = PackedFloat32Array([0.0, 20.0, 20.0, 20.0])
	p.branches = PackedInt32Array([1, 30, 120, 0])
	p.length = PackedFloat32Array([1.0, 0.8, 0.3, 0.4])
	p.length_v = PackedFloat32Array([0.0, 0.1, 0.05, 0.0])
	p.taper = PackedFloat32Array([0.95, 1.0, 1.0, 1.0])
	p.seg_splits = PackedFloat32Array([0.1, 0.1, 0.1, 0.0])
	p.split_angle = PackedFloat32Array([10.0, 10.0, 10.0, 0.0])
	p.split_angle_v = PackedFloat32Array([0.0, 10.0, 10.0, 0.0])
	p.curve_res = PackedInt32Array([8, 10, 3, 1])
	p.curve = PackedFloat32Array([0.0, 40.0, 0.0, 0.0])
	p.curve_back = PackedFloat32Array([0.0, -70.0, 0.0, 0.0])
	p.curve_v = PackedFloat32Array([90.0, 150.0, 30.0, 0.0])
	p.bend_v = PackedFloat32Array([0.0, 100.0, 0.0, 0.0])
	p.tropism = Vector3(0.0, 0.0, 0.8)
	p.leaf_count = 60
	p.leaf_color = Color(0.26, 0.42, 0.16)
	p.trunk_color = Color(0.32, 0.24, 0.16)
	return p


## Abedul plateado (tree-gen silver_birch): tronco alto cilíndrico, corteza clara.
static func silver_birch() -> TreeParams:
	var p := TreeParams.new()
	p.shape = 3
	p.g_scale = 16.0  # 20 lo hacía un poste gigante junto a los demás
	p.g_scale_v = 4.0
	p.levels = 3
	p.ratio = 0.018
	p.ratio_power = 1.5
	p.flare = 0.5
	p.base_size = PackedFloat32Array([0.3, 0.1, 0.02, 0.02])
	p.down_angle = PackedFloat32Array([0.0, 50.0, 40.0, 45.0])
	p.down_angle_v = PackedFloat32Array([0.0, -20.0, 10.0, 10.0])
	p.rotate = PackedFloat32Array([0.0, 140.0, 140.0, 140.0])
	p.rotate_v = PackedFloat32Array([0.0, 60.0, 50.0, 0.0])
	p.branches = PackedInt32Array([1, 30, 60, 0])
	p.length = PackedFloat32Array([1.0, 0.3, 0.4, 0.0])
	p.length_v = PackedFloat32Array([0.0, 0.05, 0.2, 0.0])
	p.taper = PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
	p.seg_splits = PackedFloat32Array([0.0, 0.3, 0.0, 0.0])
	p.split_angle = PackedFloat32Array([15.0, 10.0, 0.0, 0.0])
	p.curve_res = PackedInt32Array([10, 10, 10, 0])
	p.curve = PackedFloat32Array([0.0, 0.0, -10.0, 0.0])
	p.curve_v = PackedFloat32Array([50.0, 150.0, 200.0, 0.0])
	p.bend_v = PackedFloat32Array([0.0, 100.0, 0.0, 0.0])
	p.tropism = Vector3(0.0, 0.0, -2.0)  # ramas colgantes (abedul llorón leve)
	p.leaf_count = 80
	p.bark_type = "lenticel"                 # abedul: lenticelas horizontales
	p.leaf_color = Color(0.34, 0.52, 0.2)
	p.trunk_color = Color(0.85, 0.84, 0.8)  # corteza plateada
	return p


## Abeto balsámico (tree-gen balsam_fir): conífera cónica alta, aguja.
static func balsam_fir() -> TreeParams:
	var p := TreeParams.new()
	p.shape = 0
	p.g_scale = 12.0
	p.g_scale_v = 2.0
	p.levels = 3
	p.ratio = 0.015
	p.ratio_power = 1.7
	p.flare = 0.2
	p.base_size = PackedFloat32Array([0.05, 0.02, 0.02, 0.02])
	p.down_angle = PackedFloat32Array([0.0, 50.0, 60.0, 45.0])
	p.down_angle_v = PackedFloat32Array([0.0, -45.0, 20.0, 30.0])
	p.rotate = PackedFloat32Array([0.0, 140.0, -125.0, -90.0])
	p.rotate_v = PackedFloat32Array([0.0, 0.0, 20.0, 20.0])
	p.branches = PackedInt32Array([1, 100, 75, 10])
	p.length = PackedFloat32Array([1.0, 0.5, 0.25, 0.0])
	p.length_v = PackedFloat32Array([0.2, 0.0, 0.1, 0.0])
	p.taper = PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
	p.curve_res = PackedInt32Array([5, 5, 2, 0])
	p.curve = PackedFloat32Array([0.0, -40.0, 0.0, 0.0])
	p.curve_v = PackedFloat32Array([20.0, 10.0, 40.0, 0.0])
	p.bend_v = PackedFloat32Array([0.0, 10.0, 0.0, 0.0])
	p.leaf_count = 100
	p.leaf_texture = "pine"
	p.bark_type = "scaly"
	p.leaf_color = Color(0.16, 0.34, 0.2)
	p.trunk_color = Color(0.33, 0.24, 0.16)
	return p


## Pino chico (tree-gen small_pine): 2 niveles, silueta cónica joven.
static func small_pine() -> TreeParams:
	var p := TreeParams.new()
	p.shape = 0
	p.g_scale = 9.0
	p.g_scale_v = 1.5
	p.levels = 2
	p.ratio = 0.02
	p.ratio_power = 1.3
	p.flare = 0.3
	p.base_size = PackedFloat32Array([0.05, 0.02, 0.02, 0.02])
	p.down_angle = PackedFloat32Array([0.0, 30.0, 30.0, 0.0])
	p.down_angle_v = PackedFloat32Array([0.0, -60.0, 10.0, 0.0])
	p.rotate = PackedFloat32Array([0.0, 140.0, 140.0, 0.0])
	p.rotate_v = PackedFloat32Array([0.0, 30.0, 20.0, 0.0])
	p.branches = PackedInt32Array([1, 70, 0, 0])
	p.length = PackedFloat32Array([1.0, 0.35, 0.0, 0.0])
	p.length_v = PackedFloat32Array([0.0, 0.05, 0.0, 0.0])
	p.taper = PackedFloat32Array([1.0, 1.0, 0.0, 0.0])
	p.seg_splits = PackedFloat32Array([0.0, 2.0, 0.0, 0.0])
	p.split_angle = PackedFloat32Array([0.0, 80.0, 0.0, 0.0])
	p.split_angle_v = PackedFloat32Array([0.0, 30.0, 0.0, 0.0])
	p.curve_res = PackedInt32Array([5, 6, 0, 0])
	p.curve = PackedFloat32Array([0.0, -20.0, 0.0, 0.0])
	p.curve_v = PackedFloat32Array([10.0, 90.0, 0.0, 0.0])
	p.bend_v = PackedFloat32Array([0.0, 70.0, 0.0, 0.0])
	p.tropism = Vector3(0.0, 0.0, 0.0)
	p.leaf_count = 150
	p.leaf_texture = "pine"
	p.bark_type = "scaly"
	p.leaf_color = Color(0.18, 0.36, 0.22)
	p.trunk_color = Color(0.34, 0.25, 0.17)
	return p


## ---- Arbustos (árboles chicos de 2 niveles, copa densa al ras) ----

## Arbusto frondoso redondo (bosque templado / selva).
static func leafy_bush() -> TreeParams:
	var p := TreeParams.new()
	p.shape = 1  # esférico
	p.g_scale = 1.4
	p.g_scale_v = 0.4
	p.levels = 2
	p.ratio = 0.045
	p.ratio_power = 1.2
	p.flare = 0.0
	# base_size chico + ramas desde muy abajo = mata densa, poco tronco visible.
	p.base_size = PackedFloat32Array([0.02, 0.03, 0.02, 0.02])
	p.down_angle = PackedFloat32Array([0.0, 60.0, 0.0, 0.0])   # ramas barren hacia afuera
	p.down_angle_v = PackedFloat32Array([0.0, 30.0, 0.0, 0.0])
	p.rotate = PackedFloat32Array([0.0, 130.0, 0.0, 0.0])
	p.rotate_v = PackedFloat32Array([0.0, 40.0, 0.0, 0.0])
	p.branches = PackedInt32Array([1, 55, 0, 0])
	p.length = PackedFloat32Array([1.0, 0.62, 0.0, 0.0])
	p.length_v = PackedFloat32Array([0.0, 0.1, 0.0, 0.0])
	p.taper = PackedFloat32Array([1.0, 1.0, 0.0, 0.0])
	p.curve_res = PackedInt32Array([3, 3, 0, 0])
	p.curve = PackedFloat32Array([0.0, 30.0, 0.0, 0.0])
	p.curve_v = PackedFloat32Array([40.0, 80.0, 0.0, 0.0])
	p.tropism = Vector3(0.0, 0.0, -0.3)
	p.leaf_count = 60
	p.leaf_card_size = 0.42
	p.leaf_color = Color(0.3, 0.46, 0.2)
	p.trunk_color = Color(0.34, 0.28, 0.18)
	p.detail = 0.6
	p.trunk_sides = 4
	return p


## Matorral seco disperso (sabana / desierto): ramas abiertas, verde-marrón.
static func dry_bush() -> TreeParams:
	var p := leafy_bush()
	p.g_scale = 1.1
	p.branches = PackedInt32Array([1, 28, 0, 0])
	p.leaf_count = 26
	p.leaf_card_size = 0.36
	p.leaf_color = Color(0.42, 0.44, 0.22)  # verde amarillento seco
	p.leaf_texture = "acacia"
	p.tropism = Vector3(0.0, 0.0, 0.2)  # ramas más rígidas hacia arriba
	return p


## Enebro bajo (taiga / matorral frío): compacto, verde azulado, aguja.
static func juniper() -> TreeParams:
	var p := leafy_bush()
	p.shape = 2  # hemisférico
	p.g_scale = 1.0
	p.branches = PackedInt32Array([1, 55, 0, 0])
	p.leaf_count = 70
	p.leaf_card_size = 0.34
	p.leaf_texture = "pine"
	p.leaf_color = Color(0.2, 0.36, 0.26)
	p.tropism = Vector3(0.0, 0.0, -0.6)
	return p


## ============================================================================
## ESPECIES ARGENTINAS (por ecorregión — ver INVESTIGACION_VEGETACION_REALISMO §3)
## ============================================================================

## Araucaria angustifolia / pino Paraná / curí (Selva Misionera de altura). Tronco
## alto y recto, PELADO abajo, copa en candelabro/sombrilla arriba, aguja oscura.
static func araucaria() -> TreeParams:
	var p := TreeParams.new()
	p.g_scale = 22.0
	p.g_scale_v = 4.0
	p.levels = 3
	p.ratio = 0.021                                            # tronco grueso (no palo)
	p.ratio_power = 1.4
	p.flare = 0.4
	# shape 4 (cónico truncado): ramas MÁS LARGAS arriba → copa en parasol/candelabro
	# sobre tronco largo pelado (base_size 0.7 = foliaje solo en el tercio superior).
	p.shape = 4
	# Copa PARASOL (la investigación confirma: araucaria = parasol sobre fuste
	# largo pelado). base_size[0] alto = tronco desnudo abajo; ramas arriba
	# horizontales que se curvan arriba y foliaje que forma el domo aparasolado.
	# max_curve_res alto: el tronco necesita MUCHOS segmentos para que, con el
	# fuste desnudo (base_size 0.55), queden varios segmentos ARRIBA donde nacen
	# las ramas. Con el default (4) el tronco tenía 4 segmentos y no cabía ninguna
	# rama sobre la zona pelada → salía un palo. (bug encontrado con debug_tree.)
	p.max_curve_res = 8
	p.detail = 0.85
	p.base_size = PackedFloat32Array([0.46, 0.05, 0.02, 0.02])  # fuste desnudo ~mitad → parasol lleno
	p.down_angle = PackedFloat32Array([0.0, 72.0, 35.0, 25.0])  # ramas suben a formar el domo
	p.down_angle_v = PackedFloat32Array([0.0, 10.0, 10.0, 10.0])
	p.rotate = PackedFloat32Array([0.0, 130.0, 130.0, 120.0])   # verticilos
	p.branches = PackedInt32Array([1, 34, 22, 0])              # copa DENSA de parasol
	p.length = PackedFloat32Array([1.0, 0.44, 0.34, 0.0])
	p.taper = PackedFloat32Array([0.88, 1.0, 1.0, 1.0])        # tronco menos afinado (grueso arriba)
	p.curve_res = PackedInt32Array([6, 5, 3, 1])
	p.curve = PackedFloat32Array([0.0, -60.0, -30.0, 0.0])     # ramas se curvan ARRIBA
	p.curve_v = PackedFloat32Array([20.0, 25.0, 30.0, 0.0])
	p.tropism = Vector3(0.0, 0.0, 0.75)                         # hacia arriba
	p.leaf_count = 150                                          # copa densa (parasol lleno)
	p.leaf_card_size = 0.66                                     # escamas rígidas
	p.leaf_texture = "araucaria"                                # agujas/escamas rígidas
	p.bark_type = "scaly"                                       # corteza escamosa gruesa
	p.leaf_card_size = 1.25                                     # cards grandes en pisos
	p.leaf_color = Color(0.1, 0.24, 0.13)                       # verde muy oscuro
	p.trunk_color = Color(0.3, 0.22, 0.16)
	return p


## Lapacho (Selva/Yungas): frondoso alto de dosel, corteza gris. FLORECE en
## rosa (icónico): el dosel se cubre de campanas rosadas casi sin hoja.
static func lapacho() -> TreeParams:
	var p := black_oak()
	p.g_scale = 18.0
	p.g_scale_v = 3.0
	p.leaf_texture = "blossom_pink"
	p.leaf_card_size = 1.05
	p.leaf_color = Color(0.5, 0.35, 0.42)   # sesgo rosado (modula la tinta de card)
	p.trunk_color = Color(0.42, 0.36, 0.3)
	return p


## Lapacho amarillo (variante): mismo porte, dosel de campanas amarillas.
static func lapacho_amarillo() -> TreeParams:
	var p := lapacho()
	p.leaf_texture = "blossom_yellow"
	p.leaf_color = Color(0.5, 0.46, 0.3)
	return p


## Ceibo (flor nacional de Argentina): dosel con racimos rojos intensos.
static func ceibo() -> TreeParams:
	var p := black_oak()
	p.g_scale = 11.0
	p.g_scale_v = 2.0
	p.leaf_texture = "blossom_red"
	p.leaf_card_size = 1.0
	p.leaf_color = Color(0.45, 0.4, 0.28)
	p.trunk_color = Color(0.38, 0.32, 0.24)
	return p


## Palo rosa (Selva Misionera): EMERGENTE gigante (hasta 45 m), tronco alto pelado,
## corteza rosada.
static func palo_rosa() -> TreeParams:
	var p := black_oak()
	p.g_scale = 27.0
	p.g_scale_v = 4.0
	p.ratio = 0.03                                             # fuste GRUESO de emergente
	p.flare = 1.6                                              # base ensanchada (aletones)
	p.base_size = PackedFloat32Array([0.44, 0.02, 0.02, 0.02]) # fuste alto pero con copa amplia
	p.leaf_count = 90                                          # copa densa arriba (no pelado)
	p.leaf_card_size = 1.15
	p.leaf_color = Color(0.2, 0.42, 0.16)
	p.trunk_color = Color(0.5, 0.4, 0.36)                       # rosado
	return p


## Ombú (Pampa): tronco MUY grueso con base ensanchada, copa ancha y baja.
static func ombu() -> TreeParams:
	var p := TreeParams.new()
	p.shape = 2
	p.g_scale = 12.0
	p.g_scale_v = 2.0
	p.levels = 3
	p.ratio = 0.04                                             # tronco grueso
	p.ratio_power = 1.2
	p.flare = 2.0                                              # base enorme
	p.base_size = PackedFloat32Array([0.12, 0.02, 0.02, 0.02])
	p.down_angle = PackedFloat32Array([0.0, 55.0, 45.0, 45.0])
	p.down_angle_v = PackedFloat32Array([0.0, 25.0, 20.0, 20.0])
	p.rotate = PackedFloat32Array([0.0, 120.0, 130.0, 130.0])
	p.branches = PackedInt32Array([1, 24, 45, 0])
	p.length = PackedFloat32Array([1.0, 0.9, 0.4, 0.0])
	p.curve_res = PackedInt32Array([5, 5, 3, 1])
	p.curve = PackedFloat32Array([0.0, 30.0, 0.0, 0.0])
	p.curve_v = PackedFloat32Array([40.0, 90.0, 60.0, 0.0])
	p.tropism = Vector3(0.0, 0.0, -0.35)                       # ramas caen (copa baja ancha)
	p.leaf_count = 70
	p.leaf_card_size = 1.05
	p.leaf_color = Color(0.36, 0.56, 0.24)                     # verde claro brillante
	p.trunk_color = Color(0.46, 0.4, 0.32)
	return p


## Algarrobo (Chaco/Monte): árbol seco retorcido, copa achatada ancha, nudoso.
static func algarrobo() -> TreeParams:
	var p := TreeParams.new()
	p.shape = 4
	p.g_scale = 8.0
	p.g_scale_v = 1.5
	p.levels = 3
	p.ratio = 0.026
	p.ratio_power = 1.2
	p.flare = 0.8
	p.base_size = PackedFloat32Array([0.1, 0.02, 0.02, 0.02])
	p.down_angle = PackedFloat32Array([0.0, 60.0, 50.0, 50.0])
	p.down_angle_v = PackedFloat32Array([0.0, 40.0, 30.0, 30.0])
	p.rotate = PackedFloat32Array([0.0, 130.0, 130.0, 130.0])
	p.rotate_v = PackedFloat32Array([0.0, 60.0, 60.0, 0.0])
	p.branches = PackedInt32Array([1, 20, 30, 0])
	p.length = PackedFloat32Array([1.0, 0.6, 0.4, 0.0])
	p.curve_res = PackedInt32Array([5, 5, 3, 1])
	p.curve = PackedFloat32Array([0.0, 40.0, -35.0, 0.0])
	p.curve_v = PackedFloat32Array([60.0, 120.0, 100.0, 0.0])  # ramas nudosas
	p.tropism = Vector3(0.0, 0.0, 0.2)
	p.leaf_count = 52
	p.leaf_texture = "feathery"                 # foliolos compuestos (leguminosa)
	p.leaf_color = Color(0.4, 0.46, 0.22)       # verde amarillento seco
	p.trunk_color = Color(0.33, 0.26, 0.18)
	return p


## Coihue / lenga (Bosque Andino-Patagónico, Nothofagus): alto, hoja chica densa.
static func coihue() -> TreeParams:
	var p := silver_birch()
	p.g_scale = 18.0
	p.g_scale_v = 3.0
	p.leaf_texture = "small_round"
	p.leaf_color = Color(0.18, 0.38, 0.17)
	p.trunk_color = Color(0.34, 0.3, 0.26)
	p.tropism = Vector3(0.0, 0.0, 0.3)
	return p


## ---- Más especies argentinas (Selva, Yungas, Chaco/Monte, Patagonia) ----

## Cedro misionero (Cedrela fissilis): dosel alto, fuste recto, hoja pinnada.
static func cedro() -> TreeParams:
	var p := black_oak()
	p.g_scale = 20.0
	p.g_scale_v = 3.0
	p.base_size = PackedFloat32Array([0.42, 0.02, 0.02, 0.02])
	p.leaf_texture = "feathery"
	p.leaf_color = Color(0.24, 0.42, 0.18)
	p.trunk_color = Color(0.36, 0.28, 0.2)
	return p


## Anchico colorado (Parapiptadenia rigida): 18-30 m, fuste erecto algo tortuoso,
## corteza PARDO ROJIZA escamosa en placas verticales, copa CORIMBIFORME (aplanada
## arriba), hoja bipinnada discolor plumosa brillante. Ver FLORA_ARGENTINA_CATALOGO.
static func anchico() -> TreeParams:
	var p := cedro()
	p.shape = 4                                  # cónico-truncado = copa aplanada arriba
	p.g_scale = 24.0
	p.g_scale_v = 4.0
	p.ratio = 0.02
	p.base_size = PackedFloat32Array([0.5, 0.02, 0.02, 0.02])  # fuste alto (emergente)
	p.curve = PackedFloat32Array([12.0, 30.0, 20.0, 0.0])      # fuste algo tortuoso
	p.tropism = Vector3(0.0, 0.0, -0.35)         # ramas superiores se abren (corimbo)
	p.leaf_color = Color(0.28, 0.46, 0.2)        # folíolos brillantes
	p.bark_type = "scaly"                        # placas escamosas
	p.trunk_color = Color(0.44, 0.26, 0.2)       # pardo rojizo
	return p


## Timbó / oreja de negro (Enterolobium): copa PARASOL enorme y baja, bipinnada.
static func timbo() -> TreeParams:
	var p := black_oak()
	p.shape = 2                                                # hemisférico ancho
	p.g_scale = 16.0
	p.g_scale_v = 2.5
	p.ratio = 0.03
	p.flare = 1.2
	p.base_size = PackedFloat32Array([0.26, 0.02, 0.02, 0.02])
	p.down_angle = PackedFloat32Array([0.0, 68.0, 50.0, 45.0])  # ramas muy abiertas
	p.branches = PackedInt32Array([1, 45, 90, 0])
	p.length = PackedFloat32Array([1.0, 1.15, 0.4, 0.0])       # ramas largas = copa ancha
	p.curve = PackedFloat32Array([0.0, 25.0, 0.0, 0.0])
	p.tropism = Vector3(0.0, 0.0, -0.5)                         # ramas caen (parasol)
	p.leaf_texture = "feathery"
	p.leaf_color = Color(0.26, 0.44, 0.2)
	p.trunk_color = Color(0.4, 0.32, 0.24)
	return p


## Guatambú (Balfourodendron): fuste recto claro, copa densa redonda, hoja simple.
static func guatambu() -> TreeParams:
	var p := black_oak()
	p.g_scale = 18.0
	p.base_size = PackedFloat32Array([0.45, 0.02, 0.02, 0.02])
	p.leaf_texture = "laurel"
	p.leaf_color = Color(0.2, 0.42, 0.18)
	p.trunk_color = Color(0.72, 0.7, 0.62)                      # corteza clara
	p.bark_type = "smooth"
	return p


## Laurel (Nectandra/Ocotea): dosel, hoja lanceolada lustrosa oscura.
static func laurel() -> TreeParams:
	var p := black_oak()
	p.g_scale = 17.0
	p.leaf_texture = "laurel"
	p.leaf_color = Color(0.15, 0.37, 0.18)
	p.trunk_color = Color(0.34, 0.3, 0.24)
	return p


## Incienso / palo trébol (Myrocarpus frondosus): dosel alto de hoja pinnada,
## fuste recto cilíndrico, corteza ceniza (Selva Misionera). Ver FLORA_MISIONES §6.
static func incienso() -> TreeParams:
	var p := cedro()
	p.g_scale = 24.0
	p.g_scale_v = 3.0
	p.shape = 2
	p.ratio = 0.026
	p.flare = 0.6
	p.base_size = PackedFloat32Array([0.42, 0.02, 0.02, 0.02])
	p.tropism = Vector3(0.0, 0.0, 0.4)
	p.leaf_texture = "feathery"                  # hoja pinnada (leguminosa)
	p.leaf_color = Color(0.24, 0.44, 0.18)
	p.trunk_color = Color(0.5, 0.48, 0.42)       # corteza ceniza parduzca
	return p


## Peteribí / loro negro (Cordia trichotoma): dosel de copa redonda, hoja simple
## áspera, corteza gris rugosa surcada (Selva Misionera). Ver FLORA_MISIONES §6.
static func peteribi() -> TreeParams:
	var p := guatambu()
	p.g_scale = 22.0
	p.g_scale_v = 3.0
	p.ratio = 0.022
	p.flare = 0.5
	p.base_size = PackedFloat32Array([0.40, 0.02, 0.02, 0.02])
	p.tropism = Vector3(0.0, 0.0, 0.3)
	p.leaf_texture = "broadleaf"                 # hoja simple ovada
	p.bark_type = "fissured"                     # corteza rugosa con surcos
	p.leaf_color = Color(0.27, 0.48, 0.21)
	p.trunk_color = Color(0.4, 0.38, 0.34)       # gris rugosa
	return p


## Ambay (Cecropia pachystachya): PIONERO de claros/riberas, silueta única —
## aparasolada RALA, POCAS ramas, hojas ENORMES palmatilobadas, tronco delgado
## anillado. Ver FLORA_MISIONES §6 (#15).
static func ambay() -> TreeParams:
	var p := black_oak()
	p.shape = 4                                  # parasol rala
	p.g_scale = 12.0
	p.g_scale_v = 2.0
	p.levels = 2
	p.ratio = 0.028                              # tronco medio (no palito): Cecropia real Ø15-25cm
	p.ratio_power = 1.1                          # ramas gruesas (pocas y robustas)
	p.flare = 0.3
	p.base_size = PackedFloat32Array([0.45, 0.02, 0.02, 0.02])  # fuste desnudo, copa arriba
	p.down_angle = PackedFloat32Array([0.0, 45.0, 0.0, 0.0])   # ramas suben en Y (candelabro ralo)
	p.down_angle_v = PackedFloat32Array([0.0, 12.0, 0.0, 0.0])
	p.branches = PackedInt32Array([1, 7, 0, 0])  # POCAS ramas gruesas (silueta rala)
	p.length = PackedFloat32Array([1.0, 0.55, 0.0, 0.0])
	p.curve = PackedFloat32Array([0.0, -25.0, 0.0, 0.0])       # ramas se enderezan (candelabro)
	p.tropism = Vector3(0.0, 0.0, 0.5)
	p.leaf_count = 30                            # pocas hojas...
	p.leaf_card_size = 2.0                       # ...pero ENORMES (hoja palmada de hasta 50cm)
	p.leaf_texture = "palmate"                   # HOJA PALMADA/peltada (rasgo icónico)
	p.leaf_color = Color(0.24, 0.42, 0.17)       # verde brillante
	p.trunk_color = Color(0.58, 0.57, 0.5)       # tronco claro anillado
	p.bark_type = "smooth"
	return p


## Yerba mate silvestre (Ilex paraguariensis): árbol de SOTOBOSQUE de Misiones,
## copa densa perenne, hoja coriácea lustrosa oscura, corteza gris-parda con
## lenticelas. Bajo el dosel: chico (8-12 m). Ver FLORA_MISIONES §6.
static func yerba_mate() -> TreeParams:
	var p := guatambu()
	p.g_scale = 10.0
	p.g_scale_v = 2.0
	p.base_size = PackedFloat32Array([0.06, 0.02, 0.02, 0.02])  # copa densa desde abajo
	p.branches = PackedInt32Array([1, 40, 90, 0])
	p.leaf_count = 90                            # follaje denso perenne
	p.leaf_texture = "laurel"                    # hoja coriácea lustrosa
	p.bark_type = "lenticel"                     # corteza con lenticelas
	p.leaf_color = Color(0.16, 0.36, 0.17)       # verde oscuro brillante
	p.trunk_color = Color(0.42, 0.38, 0.32)      # gris-parda
	return p


## Ibirá-pitá / árbol de Artigas (Peltophorum): copa aparasolada, FLOR amarilla.
static func ibira_pita() -> TreeParams:
	var p := timbo()
	p.leaf_texture = "blossom_yellow"
	p.leaf_color = Color(0.3, 0.44, 0.2)
	p.trunk_color = Color(0.42, 0.34, 0.24)
	return p


## Quebracho colorado (Schinopsis): Chaco, madera dura, copa irregular oscura.
static func quebracho() -> TreeParams:
	var p := algarrobo()
	p.g_scale = 13.0
	p.ratio = 0.03
	p.leaf_texture = "acacia"
	p.leaf_color = Color(0.19, 0.33, 0.15)
	p.trunk_color = Color(0.3, 0.19, 0.13)                      # oscuro rojizo
	return p


## Chañar (Geoffroea): Monte, tronco verde-amarillo que se descascara, copa rala.
static func chanar() -> TreeParams:
	var p := algarrobo()
	p.g_scale = 7.0
	p.leaf_texture = "acacia"
	p.leaf_color = Color(0.34, 0.44, 0.2)
	p.trunk_color = Color(0.5, 0.5, 0.28)                       # verdoso amarillento
	p.bark_type = "smooth"
	return p


## Palo borracho (Ceiba speciosa): tronco PANZÓN verdoso espinoso, FLOR rosa.
static func palo_borracho() -> TreeParams:
	var p := black_oak()
	p.shape = 2
	p.g_scale = 13.0
	p.g_scale_v = 2.0
	p.ratio = 0.055                                            # tronco muy grueso
	p.flare = 3.4                                              # base panzona (botella aprox.)
	p.base_size = PackedFloat32Array([0.34, 0.02, 0.02, 0.02])
	p.leaf_texture = "blossom_pink"
	p.leaf_color = Color(0.28, 0.46, 0.2)
	p.trunk_color = Color(0.42, 0.5, 0.3)                       # verdoso
	p.bark_type = "smooth"
	return p


## Espinillo / aromo (Vachellia caven): acacia chica, copa abierta, flor amarilla.
static func espinillo() -> TreeParams:
	var p := algarrobo()
	p.g_scale = 5.0
	p.g_scale_v = 1.0
	p.leaf_texture = "acacia"
	p.leaf_color = Color(0.3, 0.42, 0.2)
	p.trunk_color = Color(0.3, 0.24, 0.18)
	return p


## Tala (Celtis ehrenbergiana): Pampa/Espinal, arbolito retorcido, hoja chica.
static func tala() -> TreeParams:
	var p := algarrobo()
	p.g_scale = 6.0
	p.leaf_texture = "small_round"
	p.leaf_color = Color(0.28, 0.44, 0.18)
	p.trunk_color = Color(0.36, 0.3, 0.22)
	return p


## Arrayán (Luma apiculata): corteza CANELA lisa icónica, copa densa, hoja chica.
static func arrayan() -> TreeParams:
	var p := coihue()
	p.g_scale = 10.0
	p.g_scale_v = 2.0
	p.leaf_texture = "small_round"
	p.leaf_color = Color(0.2, 0.43, 0.2)
	p.trunk_color = Color(0.74, 0.42, 0.3)                      # canela/anaranjado
	p.bark_type = "smooth"
	return p


## Ñire (Nothofagus antarctica): Patagonia, chico y tortuoso, hoja chica.
static func nire() -> TreeParams:
	var p := coihue()
	p.g_scale = 9.0
	p.g_scale_v = 2.0
	p.leaf_color = Color(0.26, 0.4, 0.18)
	p.trunk_color = Color(0.32, 0.28, 0.24)
	return p


## Notro / ciruelillo (Embothrium coccineum): Patagonia, FLOR roja intensa, esbelto.
static func notro() -> TreeParams:
	var p := silver_birch()
	p.g_scale = 7.0
	p.g_scale_v = 1.5
	p.tropism = Vector3(0.0, 0.0, 0.4)
	p.leaf_texture = "blossom_red"
	p.leaf_color = Color(0.24, 0.42, 0.2)
	p.trunk_color = Color(0.36, 0.32, 0.26)
	return p


## Quebracho blanco (Aspidosperma quebracho-blanco): Chaco, copa PÉNDULA
## (ramas colgantes), hoja lineal punzante gris-verde.
static func quebracho_blanco() -> TreeParams:
	var p := silver_birch()
	p.g_scale = 13.0
	p.g_scale_v = 2.5
	p.tropism = Vector3(0.0, 0.0, -1.6)                        # ramas COLGANTES
	p.curve_v = PackedFloat32Array([40.0, 130.0, 180.0, 0.0])  # ramas laxas
	p.leaf_texture = "small_round"
	p.leaf_color = Color(0.3, 0.42, 0.26)                      # gris-verde seco
	p.trunk_color = Color(0.4, 0.36, 0.28)
	return p


## Maitén (Maytenus boaria): Patagonia, follaje LLORÓN colgante, verde claro.
static func maiten() -> TreeParams:
	var p := silver_birch()
	p.g_scale = 12.0
	p.g_scale_v = 2.0
	p.tropism = Vector3(0.0, 0.0, -2.2)                        # llorón marcado
	p.leaf_texture = "small_round"
	p.leaf_color = Color(0.32, 0.5, 0.24)                      # verde claro
	p.trunk_color = Color(0.36, 0.32, 0.26)
	return p


## Ciprés de la cordillera (Austrocedrus chilensis): conífera CÓNICA columnar,
## escama verde-glauca, tronco recto.
static func cipres_cordillera() -> TreeParams:
	var p := balsam_fir()
	p.g_scale = 15.0
	p.g_scale_v = 3.0
	p.leaf_texture = "pine"
	p.leaf_color = Color(0.24, 0.4, 0.3)                       # verde glauco
	p.trunk_color = Color(0.36, 0.3, 0.26)
	return p


## Tipa (Tipuana tipu): Yungas, copa APARASOLADA ancha, flor amarilla, bipinnada.
static func tipa() -> TreeParams:
	var p := black_oak()
	p.shape = 2                                               # hemisférico ancho
	p.g_scale = 16.0
	p.g_scale_v = 3.0
	p.flare = 1.0
	p.leaf_texture = "feathery"
	p.leaf_color = Color(0.3, 0.48, 0.2)
	p.trunk_color = Color(0.42, 0.36, 0.28)
	return p


## Calafate (Berberis microphylla): arbusto espinoso patagónico, FLOR amarilla,
## bajo y compacto.
static func calafate() -> TreeParams:
	var p := dry_bush()
	p.g_scale = 1.3
	p.g_scale_v = 0.3
	p.branches = PackedInt32Array([1, 40, 0, 0])
	p.leaf_texture = "blossom_yellow"
	p.leaf_color = Color(0.26, 0.4, 0.2)
	p.trunk_color = Color(0.35, 0.3, 0.2)
	return p


## Neneo (Mulinum spinosum): estepa, arbusto en COJÍN semiesférico espinoso.
static func neneo() -> TreeParams:
	var p := juniper()
	p.shape = 2                                               # hemisférico (cojín)
	p.g_scale = 0.8
	p.branches = PackedInt32Array([1, 60, 0, 0])
	p.leaf_card_size = 0.28
	p.leaf_color = Color(0.4, 0.44, 0.24)                     # verde-amarillo seco
	p.tropism = Vector3(0.0, 0.0, 0.3)
	return p


## ---- Arbustos-ESCONDITE (grandes y densos, ~2-2.6 m: tapan al jugador) ----

## Matorral frondoso denso (bosque/selva): copa opaca a la altura del jugador.
static func hideout_bush() -> TreeParams:
	var p := leafy_bush()
	p.g_scale = 2.4
	p.g_scale_v = 0.5
	p.ratio = 0.05
	p.base_size = PackedFloat32Array([0.02, 0.02, 0.02, 0.02])  # ramas desde el suelo
	p.branches = PackedInt32Array([1, 95, 0, 0])               # MUCHAS ramas = tupido
	p.length = PackedFloat32Array([1.0, 0.7, 0.0, 0.0])
	p.leaf_count = 150                                         # follaje opaco
	p.leaf_card_size = 0.52
	p.leaf_color = Color(0.2, 0.4, 0.16)
	p.detail = 0.85
	p.min_bark_radius = 0.03                                   # casi sin corteza visible
	return p


## Matorral seco denso (Chaco/Monte/estepa): jarilla-like, verde-amarillo, espeso.
static func hideout_bush_dry() -> TreeParams:
	var p := hideout_bush()
	p.g_scale = 2.0
	p.branches = PackedInt32Array([1, 80, 0, 0])
	p.leaf_count = 120
	p.leaf_card_size = 0.46
	p.leaf_texture = "acacia"
	p.leaf_color = Color(0.34, 0.42, 0.2)
	p.tropism = Vector3(0.0, 0.0, 0.1)
	return p
