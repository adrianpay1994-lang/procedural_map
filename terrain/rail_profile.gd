class_name RailProfile
extends Resource

## ============================================================================
## RailProfile · Config SWAPPEABLE de la vía de tren (pedido del usuario:
## cambiar distancia de rieles, tablones, tamaños; hacer coincidir con el tren)
## ============================================================================
## Todo lo que define la vía en un solo recurso asignable por Inspector. El
## `gauge_m` (distancia entre rieles) es el que DEBE coincidir con el ancho de
## ejes del tren — TrainFactory lo lee para construir un modelo compatible.
## ============================================================================

## Distancia entre los DOS rieles (centro a centro). El tren usa el mismo valor.
@export var gauge_m: float = 1.5
## Perfil del riel (semiancho, altura de cabeza, altura de base).
@export var rail_half_w: float = 0.05
@export var rail_top: float = 0.16
@export var rail_base: float = 0.06
@export var rail_color: Color = Color(0.35, 0.36, 0.4)
@export var rail_metallic: float = 0.8
@export var rail_roughness: float = 0.35

## Durmientes (tablones): tamaño, separación y color.
@export var tie_size: Vector3 = Vector3(2.2, 0.09, 0.26)
@export var tie_spacing_m: float = 1.3
@export var tie_color: Color = Color(0.3, 0.22, 0.15)
## Mesh propia para el durmiente (null = caja con tie_size). Swappeable.
@export var tie_mesh_override: Mesh
## Material propio de los rieles (null = generado con rail_color). Swappeable.
@export var rail_material_override: Material


static func make_default() -> RailProfile:
	return RailProfile.new()
