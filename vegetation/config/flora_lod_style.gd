class_name FloraLodStyle
extends Resource

## ============================================================================
## FloraLodStyle · LOD y presupuestos de polígonos CONFIGURABLES (FloraConfig)
## ============================================================================
## Controla a qué distancia se ve 3D pleno, cuándo se pasa a mallas reducidas y
## cuándo a imagen (impostor), y pone TOPES de geometría por planta. Todo campo
## en 0 = default de la plantilla de calidad (docs/LOD_PLANTILLA.md). El tronco
## se mantiene 3D en todos los niveles de malla; el impostor final es el árbol
## completo horneado (como ahora).
## ============================================================================

@export_group("Distancias (m) — 0 = plantilla de calidad")
## Fin del 3D PLENO (todas las hojas). Bajarlo = más FPS.
@export var full_end_m: float = 0.0
## Fin del LOD reducido (45% del detalle).
@export var far_end_m: float = 0.0
## Fin del LOD mínimo (18%). Después de esto, IMAGEN (impostor).
@export var far2_end_m: float = 0.0
## Fin del impostor 2D = distancia de culling total.
@export var impostor_end_m: float = 0.0

@export_group("Límites de instancias 3D")
## Máximo de plantas 3D dibujadas por celda cercana (density-LOD). 0 = sin tope
## extra. Bajarlo = "cuántos árboles 3D se pueden ver" → más FPS en bosque denso.
@export var max_3d_per_cell: int = 0

@export_group("Presupuesto de polígonos — 0 = sin tope")
## Tope de sprays de hoja por árbol (leaf_count). Menos sprays = menos polys.
@export var max_leaf_count: int = 0
## Tope de lados del tubo del tronco/ramas (trunk_sides). 4-5 casi no se nota.
@export var max_trunk_sides: int = 0


func has_override() -> bool:
	return full_end_m > 0.0 or far_end_m > 0.0 or far2_end_m > 0.0 \
			or impostor_end_m > 0.0 or max_3d_per_cell > 0 \
			or max_leaf_count > 0 or max_trunk_sides > 0


func state_hash() -> int:
	return hash([full_end_m, far_end_m, far2_end_m, impostor_end_m,
			max_3d_per_cell, max_leaf_count, max_trunk_sides])
