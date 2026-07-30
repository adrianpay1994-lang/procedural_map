class_name NoiseHeightLayer
extends HeightLayer

## ============================================================================
## NoiseHeightLayer · Detalle FBM con atenuación por erosión
## ============================================================================
## erosion_weight (glacial-valley): atenúa el ruido por la pendiente MACRO del
## grafo → micro-detalle en valles y llanuras, laderas/acantilados limpios.
## (Aproximación: pendiente de la capa base en vez del gradiente FBM acumulado
## — 1 llamada de ruido por muestra en vez de 3×octava; visualmente equivalente.)
## Determinismo: el seed efectivo deriva de global_seed + noise_seed.
## ============================================================================

enum NoiseStyle { FBM, RIDGED, BILLOW }

@export var style: NoiseStyle = NoiseStyle.FBM
## 0 = deriva solo del seed global del mapa.
@export var noise_seed: int = 0
## Metros pico-a-pico.
@export var amplitude_m: float = 4.0
@export var frequency: float = 0.01
@export_range(1, 8) var octaves: int = 5
@export_range(0.0, 1.0, 0.05) var erosion_weight: float = 0.7

## Cap por eje de la imagen de ruido (memoria + tiempo de get_image).
const _IMG_MAX := 4097

var _noise: FastNoiseLite
var _img := PackedByteArray()   # L8 de get_image (F6.1: ruido por LOTE)
var _img_w: int = 0
var _img_h: int = 0
var _img_origin := Vector2.ZERO
var _img_step: float = 1.0


func _init() -> void:
	layer_name = &"noise_detail"


func prepare(ctx: HeightContext) -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = hash([ctx.global_seed, noise_seed, String(layer_name)])
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = frequency
	_noise.fractal_octaves = octaves
	match style:
		NoiseStyle.FBM:
			_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		NoiseStyle.RIDGED:
			_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
		NoiseStyle.BILLOW:
			_noise.fractal_type = FastNoiseLite.FRACTAL_PING_PONG
	_bake_image(ctx)


## F6.1 · Ruido por LOTE: una llamada get_image() (bucle C++) en vez de
## get_noise_2d() por celda. Con normalize=false la imagen trae (v+1)/2 en L8:
## _noise_at() remapea *2−1 para conservar amplitudes. Cuantización a 8 bits
## (amplitude_m=4 ⇒ pasos ~1.6 cm) — verificar en juego además de los tests.
## El área se acota al AABB de la máscara (lagos: imagen chica, no la isla).
func _bake_image(ctx: HeightContext) -> void:
	_img = PackedByteArray()
	_img_w = 0
	var area := ctx.bounds
	if mask != null:
		var mb := mask.aabb()
		if mb.size.x > 0.0:
			area = area.intersection(mb)
	if area.size.x <= 0.0 or area.size.y <= 0.0:
		return  # sin bounds útiles (sample suelto): fallback get_noise_2d
	# Paso: ≥3 px por longitud de onda de la octava más fina; el cap _IMG_MAX
	# puede subirlo (pierde la octava más alta en mapas enormes — asumido).
	var min_wl := 1.0 / maxf(frequency, 0.0001) / pow(2.0, octaves - 1)
	var step := maxf(min_wl / 3.0, 0.25)
	step = maxf(step, maxf(area.size.x, area.size.y) / float(_IMG_MAX - 1))
	_img_w = int(ceilf(area.size.x / step)) + 2
	_img_h = int(ceilf(area.size.y / step)) + 2
	_img_origin = area.position
	_img_step = step
	# Píxel (i,j) ⇒ mundo origin + (i,j)*step: se escala frequency y offset
	# (get_noise_2d(x,y) muestrea base((x+offset)*frequency)); se restauran
	# después para que el fallback siga muestreando coordenadas de mundo.
	_noise.frequency = frequency * step
	_noise.offset = Vector3(area.position.x / step, area.position.y / step, 0.0)
	var img := _noise.get_image(_img_w, _img_h, false, false, false)
	_img = img.get_data()
	_noise.frequency = frequency
	_noise.offset = Vector3.ZERO


func _value(pos: Vector2, ctx: HeightContext) -> float:
	if _noise == null:
		prepare(ctx)  # fallback para sample() suelto fuera del bake
	var n := _noise_at(pos)  # [-1, 1]
	var amp := amplitude_m * 0.5
	if erosion_weight > 0.0:
		amp *= 1.0 - erosion_weight * ctx.get_base_slope01(pos)
	return n * amp


## Lookup bilineal sobre la imagen precalculada — mismo rango que get_noise_2d.
## Fuera del área la coordenada se CLAMPEA (solo pasa en sample() suelto fuera
## de bounds o con peso de máscara ~0).
func _noise_at(pos: Vector2) -> float:
	if _img_w == 0:
		return _noise.get_noise_2d(pos.x, pos.y)
	var u := (pos.x - _img_origin.x) / _img_step
	var v := (pos.y - _img_origin.y) / _img_step
	var x0 := clampi(int(floorf(u)), 0, _img_w - 1)
	var y0 := clampi(int(floorf(v)), 0, _img_h - 1)
	var x1 := mini(x0 + 1, _img_w - 1)
	var y1 := mini(y0 + 1, _img_h - 1)
	var tx := clampf(u - float(x0), 0.0, 1.0)
	var ty := clampf(v - float(y0), 0.0, 1.0)
	var r0 := y0 * _img_w
	var r1 := y1 * _img_w
	var a := lerpf(float(_img[r0 + x0]), float(_img[r0 + x1]), tx)
	var b := lerpf(float(_img[r1 + x0]), float(_img[r1 + x1]), tx)
	return lerpf(a, b, ty) * (2.0 / 255.0) - 1.0
