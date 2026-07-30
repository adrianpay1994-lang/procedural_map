@tool
class_name BarkTypeStyle
extends Resource

## ============================================================================
## BarkTypeStyle · UNA entrada por TIPO DE TRONCO/CORTEZA en el inspector
## ============================================================================
## Fila colapsable con el nombre del tipo (fissured, smooth, scaly, lenticel,
## stringy) y qué especies lo usan. Vacío = corteza procedural actual (BarkTexture
## con normal map; su resolución ya se optimiza por calidad y de lejos el LOD
## lejano la quita — _cheapen_far_lod).
## ============================================================================

## Tipo de corteza (nombra la fila del inspector).
@export var bark_type: String = "":
	set(v):
		bark_type = v
		resource_name = v

## Especies que usan este tronco (informativo — lo llena FloraCatalog).
@export var usada_por: String = ""

@export_group("Reemplazos")
## Textura propia de corteza (albedo). Reemplaza la procedural de este tipo.
@export var textura: Texture2D = null
## Normal map propio (opcional, solo con `textura`).
@export var normal: Texture2D = null


func has_override() -> bool:
	return textura != null


func state_hash() -> int:
	var t := textura.resource_path if textura != null else ""
	var n := normal.resource_path if normal != null else ""
	return hash([bark_type, t, n])
