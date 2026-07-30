class_name BarkStyle
extends Resource

## ============================================================================
## BarkStyle · Cómo se dibuja el TRONCO/corteza de la flora (config Inspector)
## ============================================================================
## Parte de FloraConfig. Vacío = comportamiento actual. En P1 sólo swap del tipo
## de corteza procedural; corteza por imagen externa llega en P2 (ver spec).
## ============================================================================

## Tipo de corteza generada a elegir. "(preset)" = NO override (usa el de cada especie).
@export_enum("(preset)", "fissured", "smooth", "scaly", "lenticel", "stringy")
var bark_type: String = "(preset)"
## Corteza por IMAGEN externa: albedo (gana sobre bark_type). El shader la modula
## con el color del tronco del preset.
@export var albedo_texture: Texture2D = null
## Normal map externo (opcional; sólo se usa si hay albedo_texture).
@export var normal_texture: Texture2D = null


## ¿bark_type es un override real? ("" legado y "(preset)" = no).
func _type_override() -> bool:
	return bark_type != "" and bark_type != "(preset)"


func has_override() -> bool:
	return _type_override() or albedo_texture != null


func state_hash() -> int:
	var a := albedo_texture.resource_path if albedo_texture != null else ""
	var n := normal_texture.resource_path if normal_texture != null else ""
	return hash([bark_type, a, n])
