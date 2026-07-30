class_name ImageHeightLayer
extends HeightLayer

## ============================================================================
## ImageHeightLayer · "Stamp" de heightmap externo (estilo Rust Edit)
## ============================================================================
## Estampa un heightmap (EXR/PNG16/PNG) en una región del mapa, con rotación.
## Fuera de region devuelve 0. El falloff de bordes lo pone la mask
## (normalmente RectMask) — esta capa no lo duplica.
## ============================================================================

@export var heightmap: Texture2D
## Región destino en metros, en espacio de mapa (mapa centrado en el origen).
@export var region: Rect2 = Rect2(-100, -100, 200, 200)
@export_range(-180.0, 180.0, 1.0) var rotation_deg: float = 0.0
## Altura en metros del blanco puro (canal R = 1.0).
@export var amplitude_m: float = 30.0
@export var bilinear: bool = true

var _img: Image


func _init() -> void:
	layer_name = &"image_stamp"


func prepare(_ctx: HeightContext) -> void:
	_img = null
	if heightmap == null:
		return
	_img = heightmap.get_image()
	if _img == null:
		return
	if _img.is_compressed():
		_img.decompress()


func _value(pos: Vector2, _ctx: HeightContext) -> float:
	if _img == null:
		return 0.0
	var c := region.get_center()
	var local := (pos - c).rotated(-deg_to_rad(rotation_deg)) + region.size * 0.5
	if local.x < 0.0 or local.y < 0.0 or local.x > region.size.x or local.y > region.size.y:
		return 0.0
	var u := local.x / region.size.x
	var v := local.y / region.size.y
	var w := _img.get_width()
	var h := _img.get_height()
	var fx := u * float(w - 1)
	var fy := v * float(h - 1)
	if not bilinear:
		return _img.get_pixel(int(roundf(fx)), int(roundf(fy))).r * amplitude_m
	var x0 := int(floorf(fx))
	var y0 := int(floorf(fy))
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var a := lerpf(_img.get_pixel(x0, y0).r, _img.get_pixel(x1, y0).r, tx)
	var b := lerpf(_img.get_pixel(x0, y1).r, _img.get_pixel(x1, y1).r, tx)
	return lerpf(a, b, ty) * amplitude_m
