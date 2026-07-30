@tool
class_name FloraConfig
extends Resource

## ============================================================================
## FloraConfig · Configuración data-driven de la flora por Inspector
## ============================================================================
## Un solo Resource que el VIVERO y el MAPA comparten (@export). Overridea, por
## CATEGORÍA, cómo se ven la hoja y la corteza — sin tocar el pipeline procedural:
## cada campo vacío = comportamiento actual. `FloraConfig.active == null` = nada
## cambia (fallback total, cero regresión).
##
## Categorías P1: ÁRBOLES y ARBUSTOS (mismo sistema TreeParams). Pasto/plantas
## (codepath aparte de PlantGenerator) y overrides por especie llegan en fases
## posteriores. Ver docs/superpowers/specs/2026-07-17-flora-config-inspector-design.md.
## ============================================================================

@export_group("Hojas de flora")
## UNA fila por TIPO DE HOJA (nombrada, colapsable): qué especies la usan, cambiar
## textura, poner TU modelo, o volver ese modelo IMAGEN. Se llena SOLO del catálogo.
@export var hojas: Array[LeafTypeStyle] = []
@export_group("Troncos")
## UNA fila por TIPO DE CORTEZA: quién la usa + textura/normal propias.
@export var troncos: Array[BarkTypeStyle] = []
@export_group("Plantas y pasto")
## UNA fila por PLANTA/PASTO (fern, palmito, bamboo, cactus, pampas…): en qué
## biomas sale, apagarla, teñirla o reemplazarla por tu modelo.
@export var plantas: Array[PlantTypeStyle] = []
@export_group("LOD y presupuestos")
@export var lod: FloraLodStyle            ## distancias LOD + topes de polys/instancias
@export_group("Avanzado (por categoría)")
@export var tree_leaf: LeafStyle          ## hoja de la categoría ÁRBOLES (global)
@export var bush_leaf: LeafStyle          ## hoja de la categoría ARBUSTOS (global)
@export var bark: BarkStyle               ## corteza (todas, global)

@export_group("Acciones (tildar = ejecutar)")
## Tildar para GUARDAR esta config como la GLOBAL del jugador (vale en todo mapa).
@export var guardar_como_global: bool = false:
	set(v):
		guardar_como_global = false
		if v:
			save_global()
			print("FloraConfig: guardada como GLOBAL (el player la ve en todo mapa)")
## Tildar para BORRAR la config global (look por defecto en todos los mapas).
@export var borrar_global: bool = false:
	set(v):
		borrar_global = false
		if v:
			FloraConfig.clear_global()
			print("FloraConfig: global borrada")
## Nombre para guardar esta config como PERFIL de juego (abajo, tildar guardar).
@export var nombre_perfil: String = ""
## Tildar para guardar el perfil con el nombre de arriba (user://flora_profiles/).
@export var guardar_perfil: bool = false:
	set(v):
		guardar_perfil = false
		if v and nombre_perfil != "":
			save_profile(nombre_perfil)
			print("FloraConfig: perfil '%s' guardado" % nombre_perfil)
@export_group("Modelos propios (reemplazo TOTAL)")
## TU modelo para TODOS los árboles de la categoría (reemplaza el procedural
## entero, tronco incluido). Con method IMPOSTOR_OCTA se hornea a imagen de lejos.
@export var tree_model: Mesh = null
## TU modelo para todos los arbustos.
@export var bush_model: Mesh = null

## Config global activa (la setean el mapa/vivero en _ready). null = sin override.
## Estática y no-determinista-safe: sólo cambia CÓMO se ve la flora, no las semillas
## ni las posiciones (no afecta el multiplayer).
static var active: FloraConfig = null

## Config GLOBAL persistida: lo que configurás en el vivero (o donde sea) se guarda
## acá y CUALQUIER mapa donde entre el player la lee (procedural_map la carga si su
## @export está vacío). "Configuro una vez, vale en todo."
const GLOBAL_PATH := "user://flora_config.tres"


## Guarda esta config como la global del jugador.
func save_global() -> void:
	var err := ResourceSaver.save(self, GLOBAL_PATH)
	if err != OK:
		push_warning("FloraConfig: no se pudo guardar la config global (%d)" % err)


## Carga la config global del jugador, o null si no hay.
static func load_global() -> FloraConfig:
	if not ResourceLoader.exists(GLOBAL_PATH):
		return null
	return load(GLOBAL_PATH) as FloraConfig


## Borra la config global (volver al look por defecto en todos los mapas).
static func clear_global() -> void:
	if FileAccess.file_exists(GLOBAL_PATH):
		var d := DirAccess.open("user://")
		if d != null:
			d.remove(GLOBAL_PATH.get_file())


## Auto-poblar del catálogo al crear la config: el usuario ABRE el inspector y YA
## ve todas las hojas y troncos nombrados con quién los usa (no crea nada a mano).
func _init() -> void:
	_populate_from_catalog()


## Agrega las entradas que falten (no pisa lo configurado). Idempotente.
func _populate_from_catalog() -> void:
	var have := {}
	for h in hojas:
		if h != null:
			have[h.leaf_type] = true
	var lt := FloraCatalog.leaf_types()
	var names := lt.keys()
	names.sort()
	for n: String in names:
		if not have.has(n):
			var s := LeafTypeStyle.new()
			s.leaf_type = n
			s.usada_por = ", ".join(lt[n] as PackedStringArray)
			hojas.append(s)
	have.clear()
	for t in troncos:
		if t != null:
			have[t.bark_type] = true
	var bt := FloraCatalog.bark_types()
	names = bt.keys()
	names.sort()
	for n: String in names:
		if not have.has(n):
			var s := BarkTypeStyle.new()
			s.bark_type = n
			s.usada_por = ", ".join(bt[n] as PackedStringArray)
			troncos.append(s)
	have.clear()
	for p in plantas:
		if p != null:
			have[p.plant_type] = true
	var pt := FloraCatalog.plant_types()
	names = pt.keys()
	names.sort()
	for n: String in names:
		if not have.has(n):
			var s := PlantTypeStyle.new()
			s.plant_type = n
			s.usada_por = ", ".join(pt[n] as PackedStringArray)
			plantas.append(s)


## Fila de hoja por tipo, o null.
func _leaf_type_style(leaf_type: String) -> LeafTypeStyle:
	for h in hojas:
		if h != null and h.leaf_type == leaf_type:
			return h
	return null


## Fila de tronco por tipo, o null.
func _bark_type_style(bark_type: String) -> BarkTypeStyle:
	for t in troncos:
		if t != null and t.bark_type == bark_type:
			return t
	return null


## Fila de planta por tipo, o null.
func _plant_type_style(plant_type: String) -> PlantTypeStyle:
	for p in plantas:
		if p != null and p.plant_type == plant_type:
			return p
	return null


## ¿La planta está habilitada en la config ACTIVA? (sin config = sí).
static func plant_enabled(plant_type: String) -> bool:
	if active == null:
		return true
	var s := active._plant_type_style(plant_type)
	return s == null or s.habilitada


## Tinte activo para una planta (Color(0,0,0,0) = sin tinte) y modelo propio.
static func plant_tint(plant_type: String) -> Color:
	if active == null:
		return Color(0, 0, 0, 0)
	var s := active._plant_type_style(plant_type)
	return s.tinte if s != null else Color(0, 0, 0, 0)


static func plant_model(plant_type: String) -> Mesh:
	if active == null:
		return null
	var s := active._plant_type_style(plant_type)
	return s.modelo if s != null else null


## LeafStyle de una categoría ("tree"/"bush"), o null si no hay.
func _leaf_for(category: String) -> LeafStyle:
	match category:
		"bush": return bush_leaf
		_: return tree_leaf


## Devuelve un TreeParams con los overrides de la config aplicados, o el MISMO
## params si no hay nada que cambiar (no duplica de gusto). category = "tree"|"bush".
func apply(params: TreeParams, category: String) -> TreeParams:
	if params == null:
		return params
	var leaf := _leaf_for(category)
	var leaf_ov: bool = leaf != null and leaf.has_override()
	var bark_ov: bool = bark != null and bark.has_override()
	var lod_ov: bool = lod != null and (lod.max_leaf_count > 0 or lod.max_trunk_sides > 0)
	# Por TIPO (las filas nombradas del inspector) — gana sobre la categoría.
	var lts := _leaf_type_style(params.leaf_texture)
	var bts := _bark_type_style(params.bark_type)
	var lts_ov: bool = lts != null and lts.has_override()
	var bts_ov: bool = bts != null and bts.has_override()
	if not leaf_ov and not bark_ov and not lod_ov and not lts_ov and not bts_ov:
		return params
	var p := params.duplicate() as TreeParams
	if lod_ov:
		# Presupuesto de polígonos: topes duros sobre el preset.
		if lod.max_leaf_count > 0:
			p.leaf_count = mini(p.leaf_count, lod.max_leaf_count)
		if lod.max_trunk_sides > 0:
			p.trunk_sides = mini(p.trunk_sides, lod.max_trunk_sides)
	if leaf_ov:
		if leaf.source == LeafStyle.Source.EXTERNAL_IMAGE and leaf.external_image != null:
			p.leaf_texture_override = leaf.external_image
		elif leaf._shape_override():
			p.leaf_texture = leaf.procedural_shape
		if leaf.tint.a > 0.0:
			p.leaf_color = Color(leaf.tint.r, leaf.tint.g, leaf.tint.b)
		if leaf.card_size > 0.0:
			p.leaf_card_size = leaf.card_size
		if leaf.method == LeafStyle.Method.MESH and leaf.leaf_model != null:
			p.leaf_mesh_override = leaf.leaf_model
		p.canopy_density_override = leaf.canopy_density
		p.spray_scale_override = leaf.spray_scale
	if bark_ov:
		if bark._type_override():
			p.bark_type = bark.bark_type
		p.bark_tex_override = bark.albedo_texture
		p.bark_normal_override = bark.normal_texture
	# --- Por TIPO DE HOJA (fila del inspector): gana sobre la categoría ---
	if lts_ov:
		if lts.textura != null:
			p.leaf_texture_override = lts.textura
		if lts.modelo != null:
			if lts.modelo_a_imagen and _baked.has(lts.leaf_type):
				# Tu modelo VUELTO IMAGEN (horneado 1 vez): cards baratas con esa imagen.
				p.leaf_texture_override = _baked[lts.leaf_type]
				p.leaf_mesh_override = null
			else:
				p.leaf_mesh_override = lts.modelo
		if lts.tinte.a > 0.0:
			p.leaf_color = Color(lts.tinte.r, lts.tinte.g, lts.tinte.b)
		if lts.tamano_card > 0.0:
			p.leaf_card_size = lts.tamano_card
	# --- Por TIPO DE TRONCO ---
	if bts_ov:
		p.bark_tex_override = bts.textura
		p.bark_normal_override = bts.normal
	return p


## Texturas horneadas de "modelo→imagen" por tipo de hoja (leaf_type → Texture2D).
static var _baked: Dictionary = {}


## Pre-pasada de HORNEADO (async, requiere render): por cada fila de hoja con
## `modelo` + `modelo_a_imagen`, renderiza el modelo a imagen UNA vez. Llamar
## antes de generar los pools (vivero / mapa). En headless no hace nada.
func prepare_bakes(host: Node) -> void:
	if not ImpostorBaker.available():
		return
	for h in hojas:
		if h == null or h.modelo == null or not h.modelo_a_imagen:
			continue
		if _baked.has(h.leaf_type):
			continue
		var r: Dictionary = await ImpostorBaker.bake(host, h.modelo, 256)
		if r.get("ok", false):
			var qm := r["mesh"] as QuadMesh
			var mat := qm.material as StandardMaterial3D
			if mat != null and mat.albedo_texture != null:
				_baked[h.leaf_type] = mat.albedo_texture


## Aplica la config ACTIVA (o devuelve params intacto si no hay). Lo usan los pools.
static func apply_active(params: TreeParams, category: String) -> TreeParams:
	if active == null:
		return params
	return active.apply(params, category)


## Hash del estado activo, para que los cachés de malla invaliden si cambia la config.
static func state_hash() -> int:
	if active == null:
		return 0
	var h := 0
	if active.tree_leaf != null: h = hash([h, "t", active.tree_leaf.state_hash()])
	if active.bush_leaf != null: h = hash([h, "b", active.bush_leaf.state_hash()])
	if active.bark != null: h = hash([h, "k", active.bark.state_hash()])
	if active.lod != null: h = hash([h, "l", active.lod.state_hash()])
	for s in active.hojas:
		if s != null and s.has_override(): h = hash([h, s.state_hash()])
	for s in active.troncos:
		if s != null and s.has_override(): h = hash([h, s.state_hash()])
	for s in active.plantas:
		if s != null and s.has_override(): h = hash([h, s.state_hash()])
	h = hash([h, _baked.keys()])
	return h


# === Perfiles por JUEGO ======================================================
# Toda la config guardada con NOMBRE: cada juego/proyecto puede tener su perfil
# de flora ("selva realista", "low-poly", "cartoon") y cargarlo entero.
const PROFILES_DIR := "user://flora_profiles/"


## Guarda esta config como perfil nombrado.
func save_profile(profile_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PROFILES_DIR))
	var err := ResourceSaver.save(self, PROFILES_DIR + profile_name + ".tres")
	if err != OK:
		push_warning("FloraConfig: no se pudo guardar el perfil '%s' (%d)" % [profile_name, err])


## Carga un perfil por nombre, o null.
static func load_profile(profile_name: String) -> FloraConfig:
	var path := PROFILES_DIR + profile_name + ".tres"
	if not ResourceLoader.exists(path):
		return null
	return load(path) as FloraConfig


## Nombres de perfiles guardados.
static func list_profiles() -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(PROFILES_DIR)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".tres"):
			out.append(f.trim_suffix(".tres"))
	return out
