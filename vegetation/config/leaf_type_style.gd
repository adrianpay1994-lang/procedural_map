@tool
class_name LeafTypeStyle
extends Resource

## ============================================================================
## LeafTypeStyle · UNA entrada por TIPO DE HOJA en el inspector (FloraConfig)
## ============================================================================
## Aparece como fila colapsable con el NOMBRE del tipo de hoja. `usada_por`
## muestra qué especies la usan (informativo, para diseñadores de assets).
## Todo vacío = hoja procedural actual. Costo: cada spray = 2 quads = 12 verts;
## el total lo manda el leaf_count de la especie.
## ============================================================================

## Nombre del tipo de hoja (broadleaf, laurel, pine, palmate…). Lo llena el
## catálogo; también nombra la fila en el inspector.
@export var leaf_type: String = "":
	set(v):
		leaf_type = v
		resource_name = v          # la fila del inspector muestra el nombre

## Especies que usan esta hoja (informativo — lo llena FloraCatalog).
@export var usada_por: String = ""

@export_group("Reemplazos")
## Cambiar la TEXTURA de esta hoja por una imagen propia (PNG con alpha).
@export var textura: Texture2D = null
## Cambiar la hoja por TU MODELO 3D (Mesh): se instancia en cada punto de hoja
## de las especies que usan este tipo.
@export var modelo: Mesh = null
## Si hay `modelo`: en vez de dibujarlo en 3D, HORNEARLO a imagen una vez y usar
## esa imagen en las cards (tu modelo vuelto imagen = más FPS). La imagen ya
## entra al LOD normal (lejos = menos sprays + impostor del árbol entero).
@export var modelo_a_imagen: bool = false

@export_group("Ajustes")
## Tinte (alpha 0 = sin cambio).
@export var tinte: Color = Color(0, 0, 0, 0)
## Tamaño de card (0 = el de cada especie).
@export var tamano_card: float = 0.0


func has_override() -> bool:
	return textura != null or modelo != null or tinte.a > 0.0 or tamano_card > 0.0


func state_hash() -> int:
	var t := textura.resource_path if textura != null else ""
	var m := modelo.resource_path if modelo != null else ""
	return hash([leaf_type, t, m, modelo_a_imagen, tinte, tamano_card])
