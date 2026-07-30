class_name BarkTexture
extends RefCounted

## ============================================================================
## BarkTexture · Corteza procedural por TIPO: altura (gris) + normal map
## ============================================================================
## GRIS de detalle (no color): la corteza se tiñe con el color de especie por
## COLOR del vértice en el shader → una textura por tipo sirve para todas las
## especies de ese patrón. Además genera un NORMAL MAP (derivado de la altura por
## Sobel) para relieve real con luz (necesita tangentes en la malla — TreeGenerator
## las genera). Todo procedural, determinista, cacheado. Cero assets externos.
##
## Tipos: fissured (fisuras verticales, roble/lapacho/quebracho), smooth (lisa,
## arrayán/guatambú), scaly (escamas, araucaria/pino), lenticel (lenticelas
## horizontales, abedul/ceibo), stringy (fibras largas, palo borracho/eucalipto).
## ============================================================================

static var _gray: Dictionary = {}
static var _norm: Dictionary = {}
## Los pools de mallas se generan en WorkerThreadPool (PERF-CARGA): la caché
## estática necesita candado — dos hilos generando la misma corteza a la vez
## corrompían el Dictionary. El peor caso ahora es generar dos veces y pisar.
static var _mtx := Mutex.new()


static func grayscale(type: String = "fissured", size: int = 256) -> ImageTexture:
	var key := "%s_%d" % [type, size]
	_mtx.lock()
	var hit: Variant = _gray.get(key)
	_mtx.unlock()
	if hit != null:
		return hit
	var h := _height(type, size)
	var img := Image.create(size, size, true, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var v: float = h[y * size + x]
			img.set_pixel(x, y, Color(v, v, v))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_mtx.lock()
	_gray[key] = tex
	_mtx.unlock()
	return tex


## Normal map (tangent-space, RGB 0..1) derivado de la altura por Sobel. strength
## controla el relieve. Envuelve en X/Y (corteza tileable alrededor del tronco).
static func normal(type: String = "fissured", size: int = 256, strength: float = 11.0) -> ImageTexture:
	var key := "%s_%d_%d" % [type, size, int(strength * 10.0)]
	_mtx.lock()
	var hit: Variant = _norm.get(key)
	_mtx.unlock()
	if hit != null:
		return hit
	var h := _height(type, size)
	var img := Image.create(size, size, true, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var xl := (x - 1 + size) % size
			var xr := (x + 1) % size
			var yd := (y - 1 + size) % size
			var yu := (y + 1) % size
			var dx: float = (h[y * size + xl] - h[y * size + xr]) * strength
			var dy: float = (h[yd * size + x] - h[yu * size + x]) * strength
			var n := Vector3(dx, dy, 1.0).normalized()
			img.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_mtx.lock()
	_norm[key] = tex
	_mtx.unlock()
	return tex


## Campo de altura [0..1] del tipo pedido (row-major size*size).
static func _height(type: String, size: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(size * size)
	var coarse := FastNoiseLite.new()
	coarse.seed = 4242
	coarse.noise_type = FastNoiseLite.TYPE_VALUE
	var fine := FastNoiseLite.new()
	fine.seed = 99
	fine.noise_type = FastNoiseLite.TYPE_SIMPLEX
	var cell := FastNoiseLite.new()
	cell.seed = 707
	cell.noise_type = FastNoiseLite.TYPE_CELLULAR
	cell.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_DIV
	cell.frequency = 0.05
	for y in size:
		for x in size:
			var fx := float(x)
			var fy := float(y)
			var v := 0.5
			match type:
				"smooth":
					v = 0.6 + 0.14 * fine.get_noise_2d(fx * 0.08, fy * 0.05)
					# bandas de peladura horizontales muy suaves (arrayán)
					v += 0.06 * sin(fy * 0.05 + fine.get_noise_2d(fx * 0.02, fy * 0.02) * 3.0)
				"scaly":
					# escamas: celdas cerradas oscuras en los bordes (araucaria/pino)
					var c := cell.get_noise_2d(fx, fy)
					v = 0.35 + 0.6 * clampf(c, 0.0, 1.0)
					v += 0.08 * fine.get_noise_2d(fx * 0.2, fy * 0.2)
				"lenticel":
					# lisa clara + rayas horizontales cortas oscuras (abedul/ceibo)
					v = 0.7 + 0.1 * fine.get_noise_2d(fx * 0.1, fy * 0.06)
					var dash := fine.get_noise_2d(fx * 0.03, fy * 0.5)
					if dash > 0.55:
						v -= 0.4 * smoothstep(0.55, 0.8, dash)
				"stringy":
					# fibras verticales largas (palo borracho/eucalipto)
					var s := coarse.get_noise_2d(fx * 0.16, fy * 0.006)
					v = 0.5 + 0.34 * s
					v += 0.1 * fine.get_noise_2d(fx * 0.5, fy * 0.03)
				_:  # fissured: surcos verticales anchos y profundos (roble/lapacho)
					var g := coarse.get_noise_2d(fx * 0.06, fy * 0.006)
					v = 0.5 + 0.46 * g                       # más contraste = surcos hondos
					v += 0.14 * fine.get_noise_2d(fx * 0.16, fy * 0.16)
					var plate := fine.get_noise_2d(fx * 0.02, fy * 0.28)
					if plate > 0.6:
						v -= 0.34                            # placas horizontales marcadas
			# Micro-relieve de alta frecuencia: le da "mordida" fina al normal map.
			v += 0.06 * fine.get_noise_2d(fx * 0.55, fy * 0.55)
			out[y * size + x] = clampf(v, 0.03, 1.0)
	return out
