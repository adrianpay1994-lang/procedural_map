class_name HeightLayer
extends Resource

## ============================================================================
## HeightLayer · Una capa de la pila de altura (docs/PROCEDURAL_MAP_PLAN.md §3.3)
## ============================================================================
## Subclases implementan _value(). El Inspector muestra la pila como
## Array[HeightLayer]: crear/reordenar/activar capas sin tocar código.
## Las capas deben ser PURAS respecto a (pos, ctx): mismo input ⇒ mismo output
## (invariante de determinismo). Nada de randf() global.
## ============================================================================

enum BlendMode { ADD, SUBTRACT, MULTIPLY, MIN, MAX, REPLACE }

@export var enabled: bool = true
@export var layer_name: StringName = &""
@export var blend: BlendMode = BlendMode.ADD
@export_range(0.0, 4.0, 0.01) var strength: float = 1.0
## null = capa global (toda la isla).
@export var mask: HeightMask


## Prepara estado interno (noise, grids, imágenes) ANTES del bake.
## Se llama una vez, single-thread. _value/apply deben ser thread-safe (solo lectura).
func prepare(_ctx: HeightContext) -> void:
	pass


## AABB (metros) que la capa puede AFECTAR. `size == 0` ⇒ GLOBAL (toda la isla):
## el bake nunca la saltea. Las capas con footprint acotado (ríos/caminos/vías)
## devuelven su rectángulo real → en celdas lejanas el bake las SALTA (ahí
## `apply()` devolvería `h` sin cambio igual): mismo resultado, mucho menos costo
## en mapas grandes con muchas polilíneas. Debe estar listo tras `prepare()`.
func affect_bounds() -> Rect2:
	return Rect2()


## Aplica la capa sobre la altura acumulada h (en metros).
func apply(pos: Vector2, h: float, ctx: HeightContext) -> float:
	var w := strength * (1.0 if mask == null else mask.weight(pos, ctx))
	if w <= 0.0001:
		return h
	var v := _value(pos, ctx)
	match blend:
		BlendMode.ADD:
			return h + v * w
		BlendMode.SUBTRACT:
			return h - v * w
		BlendMode.MULTIPLY:
			return lerpf(h, h * v, w)
		BlendMode.MIN:
			return lerpf(h, minf(h, v), w)
		BlendMode.MAX:
			return lerpf(h, maxf(h, v), w)
		BlendMode.REPLACE:
			return lerpf(h, v, w)
	return h


## Valor de la capa en metros (o factor para MULTIPLY). Override obligatorio.
func _value(_pos: Vector2, _ctx: HeightContext) -> float:
	push_error("HeightLayer._value() sin implementar en %s" % [get_script().resource_path])
	return 0.0
