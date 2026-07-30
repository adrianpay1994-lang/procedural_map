@tool
class_name PlantTypeStyle
extends Resource

## ============================================================================
## PlantTypeStyle · UNA entrada por PLANTA/PASTO en el inspector (FloraConfig)
## ============================================================================
## Fila colapsable nombrada (fern, palmito, guembe, bamboo, cactus, pampas…) con
## los BIOMAS que la usan. Configurable: apagarla, teñirla o reemplazarla por TU
## modelo. Vacío = planta procedural actual.
## ============================================================================

## Nombre del tipo de planta (nombra la fila del inspector).
@export var plant_type: String = "":
	set(v):
		plant_type = v
		resource_name = v

## Biomas que la usan (informativo — lo llena FloraCatalog).
@export var usada_por: String = ""

@export_group("Configuración")
## Destildar = esta planta NO se genera en el mapa (quitarla del juego).
@export var habilitada: bool = true
## Tinte del follaje (alpha 0 = color por defecto).
@export var tinte: Color = Color(0, 0, 0, 0)
## Reemplazo TOTAL: tu modelo (Mesh) en vez de la planta procedural.
@export var modelo: Mesh = null


func has_override() -> bool:
	return not habilitada or tinte.a > 0.0 or modelo != null


func state_hash() -> int:
	var m := modelo.resource_path if modelo != null else ""
	return hash([plant_type, habilitada, tinte, m])
