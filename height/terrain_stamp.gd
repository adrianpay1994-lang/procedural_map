class_name TerrainStamp
extends Resource

## ============================================================================
## TerrainStamp · Perfil de heightmap reubicable (TERRAIN_PIPELINE_V2_PLAN §F2)
## ============================================================================
## El PERFIL reutilizable: qué forma de terreno impone un stamp. Se coloca en
## el mapa con TerrainStampLayer (posición/rotación/escala por instancia).
## Mismo contrato que los monumentos de Rust y que PathData generalizado a 2D:
## zona interior = el perfil manda; collar de falloff = lerp hacia el terreno.
## Fuente de altura: heightmap (canal R) O radial_profile (r normalizado 0..1
## → altura 0..1). Si están los dos, gana el heightmap.
## .tres solo como plantilla/perfil (regla del usuario: config por Inspector).
## ============================================================================

## Heightmap del perfil (EXR/PNG16/PNG, canal R). null ⇒ usar radial_profile.
@export var heightmap: Texture2D
## Perfil radial: x = distancia normalizada al centro (0 centro, 1 borde),
## y = altura normalizada (×amplitude_m). Ignorado si hay heightmap.
@export var radial_profile: Curve
## Altura en metros del blanco puro / del valor 1.0 de la curva.
@export var amplitude_m: float = 20.0
## Radio del footprint en metros (mitad del lado para heightmaps cuadrados).
@export var radius_m: float = 60.0
## Collar de mezcla hacia el terreno original (metros, fuera del radio).
@export var falloff_m: float = 25.0
## Operación de mezcla sugerida (la instancia la copia al colocarse):
## REPLACE = el perfil manda (monumento/meseta) · MAX = solo sube (montaña)
## · MIN = solo baja (cráter/cauce) · ADD = apila relieve.
@export var op: HeightLayer.BlendMode = HeightLayer.BlendMode.REPLACE
## true ⇒ el perfil se asienta sobre la altura LOCAL del terreno (base_ref en
## el centro del stamp): "polariza" el entorno. false ⇒ metros absolutos.
@export var relative_to_terrain: bool = true
