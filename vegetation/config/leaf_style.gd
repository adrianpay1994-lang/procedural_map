class_name LeafStyle
extends Resource

## ============================================================================
## LeafStyle · Cómo se dibuja la HOJA de una categoría de flora (config Inspector)
## ============================================================================
## Parte de FloraConfig. Cada campo vacío = comportamiento actual (fallback total).
## En P1 sólo se honra `source` (PROCEDURAL/EXTERNAL_IMAGE) con método CARDS; los
## demás métodos (billboard/crossed/impostor/mesh) llegan en P2-P4 (ver spec
## docs/superpowers/specs/2026-07-17-flora-config-inspector-design.md).
## ============================================================================

## Método de render de la hoja. Sólo CARDS implementado en P1.
enum Method { CARDS, CROSSED, BILLBOARD, IMPOSTOR_OCTA, MESH }
## De dónde sale la imagen de la hoja.
enum Source { PROCEDURAL, EXTERNAL_IMAGE }

@export var method: Method = Method.CARDS
@export var source: Source = Source.PROCEDURAL
## Si PROCEDURAL: textura de hoja generada a elegir (assets/vegetation/leaves/).
## "(preset)" = sin override (usa la de cada especie).
@export_enum("(preset)", "broadleaf", "laurel", "pine", "araucaria", "feathery",
		"acacia", "palm", "fern_frond", "palmate", "digitate", "cordate",
		"broad_blade", "small_round", "blossom_pink", "blossom_yellow", "blossom_red")
var procedural_shape: String = "(preset)"


## ¿procedural_shape es un override real? ("" legado y "(preset)" = no).
func _shape_override() -> bool:
	return procedural_shape != "" and procedural_shape != "(preset)"
## Si EXTERNAL_IMAGE: imagen propia (PNG con alpha). Reemplaza la textura de hoja.
@export var external_image: Texture2D = null
## Si method = MESH: TU modelo de hoja/ramita (Mesh). Se instancia en cada punto
## de hoja de la copa (en vez de las cards). Con method IMPOSTOR_OCTA el árbol
## entero (incluido tu modelo) se hornea a imagen — "mi modelo vuelto imagen".
@export var leaf_model: Mesh = null
## Tinte de la hoja. alpha 0 = NO override (usa el color del preset).
@export var tint: Color = Color(0, 0, 0, 0)
## Tamaño de card de hoja. 0 = NO override (usa el del preset).
@export var card_size: float = 0.0
## Fracción de sprays de copa que se dibujan (0 = default 0.7). Bajarla = MENOS
## quads (más FPS); combinar con spray_scale para no perder densidad visual.
@export_range(0.0, 1.0) var canopy_density: float = 0.0
## Multiplicador del tamaño de spray (0 = default). Subirlo compensa una
## canopy_density baja: menos quads pero más grandes (el knob de optimización).
@export var spray_scale: float = 0.0


## ¿Este estilo cambia algo? (si no, el caller ni duplica el TreeParams).
func has_override() -> bool:
	if source == Source.EXTERNAL_IMAGE and external_image != null:
		return true
	if method == Method.MESH and leaf_model != null:
		return true
	return _shape_override() or tint.a > 0.0 or card_size > 0.0 \
			or canopy_density > 0.0 or spray_scale > 0.0


## Hash estable del estilo, para invalidar cachés de malla cuando cambia.
func state_hash() -> int:
	var img_id := external_image.resource_path if external_image != null else ""
	var mdl_id := leaf_model.resource_path if leaf_model != null else ""
	return hash([method, source, procedural_shape, img_id, mdl_id, tint, card_size,
			canopy_density, spray_scale])
