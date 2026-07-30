@tool
class_name OceanWaveGPU extends Node
## ============================================================================
## PORTADO de GodotOceanWaves — MIT, Copyright (c) 2024 Ethan Truong
## https://github.com/2Retr0/GodotOceanWaves · licencia en shaders/ocean_fft/
## ----------------------------------------------------------------------------
## OceanWaveGPU · Genera el oleaje por FFT sobre un ESPECTRO (TMA = JONSWAP +
## atenuacion por profundidad). De ahi sale el caos SIN direccion dominante: no
## son N olas sumadas a mano, son miles de componentes con dispersion direccional.
## Salida: displacement_map (desplazamiento 3D, crestas afiladas) + normal_map
## (normales + ESPUMA por Jacobiano = espuma donde la ola realmente rompe).
##
## CAMBIOS sobre el original:
##  - class_name/rutas del proyecto (res://shaders/ocean_fft/).
##  - `depth_m` deja de ser const 20.0: lo manda el SUELO OCEANICO configurable
##    del OceanSystem (mar poco profundo => olas mas cortas, como en la realidad).
##  - displacement_map con CAN_COPY_FROM: habilita leer altura en CPU para la
##    flotabilidad (fisica == visual). El original no lo permite.
## ============================================================================

const G := 9.81

## Profundidad del mar (m, positiva) que usa el espectro TMA y la relacion de
## dispersion. La setea OceanSystem desde `floor_depth_m`.
var depth_m: float = 40.0

var map_size : int
var context : OceanRenderContext
var pipelines : Dictionary
var descriptors : Dictionary

# Generator state per invocation of `update()`.
var pass_parameters : Array[OceanCascade]
var pass_num_cascades_remaining : int

## true si este entorno NO puede correr el FFT (headless/Compatibility: el
## RenderingDevice es dummy). Sin esta guarda, los tests headless CRASHEAN
## (shader_create_from_spirv sobre null -> segfault). Medido.
var gpu_unavailable := false


func init_gpu(num_cascades : int) -> void:
	if RenderingServer.get_rendering_device() == null:
		gpu_unavailable = true
		push_warning("OceanWaveGPU: sin RenderingDevice (headless o Compatibility) — el mar queda sin oleaje.")
		return
	# --- DEVICE/SHADER CREATION ---
	if not context: context = OceanRenderContext.create(RenderingServer.get_rendering_device())
	var spectrum_compute_shader := context.load_shader('res://shaders/ocean_fft/spectrum_compute.glsl')
	var fft_butterfly_shader := context.load_shader('res://shaders/ocean_fft/fft_butterfly.glsl')
	var spectrum_modulate_shader := context.load_shader('res://shaders/ocean_fft/spectrum_modulate.glsl')
	var fft_compute_shader := context.load_shader('res://shaders/ocean_fft/fft_compute.glsl')
	var transpose_shader := context.load_shader('res://shaders/ocean_fft/transpose.glsl')
	var fft_unpack_shader := context.load_shader('res://shaders/ocean_fft/fft_unpack.glsl')

	# --- DESCRIPTOR PREPARATION ---
	var dims := Vector2i(map_size, map_size)
	var num_fft_stages := int(log(map_size) / log(2))

	descriptors[&'spectrum'] = context.create_texture(dims, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT, num_cascades)
	descriptors[&'butterfly_factors'] = context.create_storage_buffer(num_fft_stages*map_size * 4 * 4)         # Size: (#FFT stages * map size * sizeof(vec4))
	descriptors[&'fft_buffer'] = context.create_storage_buffer(num_cascades * map_size*map_size * 4*2 * 2 * 4) # Size: (map size^2 * 4 FFTs * 2 temp buffers (for Stockham FFT) * sizeof(vec2))
	# CAN_COPY_FROM: sin este bit no se puede leer la altura en CPU (flotabilidad).
	descriptors[&'displacement_map'] = context.create_texture(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT, num_cascades)
	descriptors[&'normal_map'] = context.create_texture(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT, num_cascades)

	# UN SET POR SHADER. Godot 4.7 valida que los flags de escritura del set
	# coincidan con los que declara el shader del pipeline; el original reusaba el
	# mismo set entre shaders y en 4.7 falla con:
	#   "Uniforms supplied for set (0) ... are not the same format as required by
	#    the pipeline shader" (spectrum es writable en _compute y readonly en
	#   _modulate) -> ningun dispatch de FFT corria. Medido.
	var spectrum_set := context.create_descriptor_set([descriptors[&'spectrum']], spectrum_compute_shader, 0)
	var spectrum_set_ro := context.create_descriptor_set([descriptors[&'spectrum']], spectrum_modulate_shader, 0)
	var fft_butterfly_set := context.create_descriptor_set([descriptors[&'butterfly_factors']], fft_butterfly_shader, 0)
	var fft_compute_set := context.create_descriptor_set([descriptors[&'butterfly_factors'], descriptors[&'fft_buffer']], fft_compute_shader, 0)
	var transpose_set := context.create_descriptor_set([descriptors[&'butterfly_factors'], descriptors[&'fft_buffer']], transpose_shader, 0)
	var fft_buffer_set := context.create_descriptor_set([descriptors[&'fft_buffer']], spectrum_modulate_shader, 1)
	var fft_buffer_set_unpack := context.create_descriptor_set([descriptors[&'fft_buffer']], fft_unpack_shader, 1)
	var unpack_set := context.create_descriptor_set([descriptors[&'displacement_map'], descriptors[&'normal_map']], fft_unpack_shader, 0)

	# --- COMPUTE PIPELINE CREATION ---
	# Grupos de trabajo: la division es ENTERA a proposito (map_size siempre es
	# potencia de 2 >= 128, asi que divide exacto). Se escribe con @() para que
	# quede explicito y Godot no avise por "parte decimal descartada".
	var g16 := map_size / 16      # 16x16 hilos por grupo
	var g32 := map_size / 32      # transpuesta: bloques de 32x32
	var g_butterfly := map_size / 2 / 64
	pipelines[&'spectrum_compute'] = context.create_pipeline([g16, g16, 1], [spectrum_set], spectrum_compute_shader)
	pipelines[&'spectrum_modulate'] = context.create_pipeline([g16, g16, 1], [spectrum_set_ro, fft_buffer_set], spectrum_modulate_shader)
	pipelines[&'fft_butterfly'] = context.create_pipeline([g_butterfly, num_fft_stages, 1], [fft_butterfly_set], fft_butterfly_shader)
	pipelines[&'fft_compute'] = context.create_pipeline([1, map_size, 4], [fft_compute_set], fft_compute_shader)
	pipelines[&'transpose'] = context.create_pipeline([g32, g32, 4], [transpose_set], transpose_shader)
	pipelines[&'fft_unpack'] = context.create_pipeline([g16, g16, 1], [unpack_set, fft_buffer_set_unpack], fft_unpack_shader)

	# Los factores butterfly se generan UNA vez por map_size (tambien en el hilo
	# de render, ver nota de _process).
	RenderingServer.call_on_render_thread(func() -> void:
		var compute_list := context.compute_list_begin()
		pipelines[&'fft_butterfly'].call(context, compute_list)
		context.compute_list_end())

func _process(_delta: float) -> void:
	# Update one cascade each frame for load balancing.
	if gpu_unavailable or context == null: return
	if pass_num_cascades_remaining == 0: return
	pass_num_cascades_remaining -= 1

	# Godot 4.4+: el trabajo de compute sobre el RenderingDevice PRINCIPAL debe
	# enviarse desde el HILO DE RENDER. Sin esto los comandos se graban desde el
	# hilo equivocado y las texturas quedan en cero (mar plano) — medido.
	var idx := pass_num_cascades_remaining
	RenderingServer.call_on_render_thread(func() -> void:
		var compute_list := context.compute_list_begin()
		_update(compute_list, idx, pass_parameters)
		context.compute_list_end())

func _update(compute_list : int, cascade_index : int, parameters : Array[OceanCascade]) -> void:
	var params: OceanCascade = parameters[cascade_index]
	## --- WAVE SPECTRA UPDATE ---
	if params.should_generate_spectrum:
		var alpha := JONSWAP_alpha(params.wind_speed, params.fetch_length*1e3)
		var omega := JONSWAP_peak_angular_frequency(params.wind_speed, params.fetch_length*1e3)
		pipelines[&'spectrum_compute'].call(context, compute_list, OceanRenderContext.create_push_constant([params.spectrum_seed.x, params.spectrum_seed.y, params.tile_length.x, params.tile_length.y, alpha, omega, params.wind_speed, deg_to_rad(params.wind_direction), depth_m, params.swell, params.detail, params.spread, cascade_index]))
		params.should_generate_spectrum = false
	pipelines[&'spectrum_modulate'].call(context, compute_list, OceanRenderContext.create_push_constant([params.tile_length.x, params.tile_length.y, depth_m, params.time, cascade_index]))

	## --- WAVE SPECTRA INVERSE FOURIER TRANSFORM ---
	var fft_push_constant := OceanRenderContext.create_push_constant([cascade_index])
	# Note: We need not do a second transpose after computing FFT on rows since rotating the wave by
	#       PI/2 doesn't affect it visually.
	pipelines[&'fft_compute'].call(context, compute_list, fft_push_constant)
	pipelines[&'transpose'].call(context, compute_list, fft_push_constant)
	context.compute_list_add_barrier(compute_list) # FIXME: Why is a barrier only needed here?!
	pipelines[&'fft_compute'].call(context, compute_list, fft_push_constant)

	## --- DISPLACEMENT/NORMAL MAP UPDATE ---
	pipelines[&'fft_unpack'].call(context, compute_list, OceanRenderContext.create_push_constant([cascade_index, params.whitecap, params.foam_grow_rate, params.foam_decay_rate]))

## Begins updating wave cascades based on the provided parameters. To balance stutter,
## the generator will schedule one cascade update per frame. All cascades from the
## previous invocation that have not been processed yet will be updated.
func update(delta : float, parameters : Array[OceanCascade]) -> void:
	assert(parameters.size() != 0)
	if gpu_unavailable:
		return
	if not context:
		init_gpu(maxi(2, len(parameters))) # FIXME: This is needed because my RenderContext API sucks...
	elif pass_num_cascades_remaining != 0: # Cascadas de la pasada anterior sin procesar
		var n := pass_num_cascades_remaining
		var prev := pass_parameters
		RenderingServer.call_on_render_thread(func() -> void:
			var compute_list := context.compute_list_begin()
			for i in range(n):
				_update(compute_list, i, prev)
			context.compute_list_end())

	# Update each cascade's parameters that rely on time delta
	for i in len(parameters):
		var params: OceanCascade = parameters[i]
		params.time += delta
		# Note: The constants are used to normalize parameters between 0 and 10.
		params.foam_grow_rate = delta * params.foam_amount*7.5
		params.foam_decay_rate = delta * maxf(0.5, 10.0 - params.foam_amount)*1.15

	pass_parameters = parameters
	pass_num_cascades_remaining = len(parameters)

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if context: context.free()

# Source: https://wikiwaves.org/Ocean-Wave_Spectra#JONSWAP_Spectrum
static func JONSWAP_alpha(wind_speed:=20.0, fetch_length:=550e3) -> float:
	return 0.076 * pow(wind_speed**2 / (fetch_length*G), 0.22)

# Source: https://wikiwaves.org/Ocean-Wave_Spectra#JONSWAP_Spectrum
static func JONSWAP_peak_angular_frequency(wind_speed:=20.0, fetch_length:=550e3) -> float:
	return 22.0 * pow(G*G / (wind_speed*fetch_length), 1.0/3.0)
