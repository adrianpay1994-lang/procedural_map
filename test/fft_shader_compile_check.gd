extends Node
## ¿Los compute shaders FFT de GodotOceanWaves (escritos para Godot 4.3) COMPILAN
## en Godot 4.7? Es la única incógnita bloqueante del plan de océano W2 (no se
## puede saber leyendo: hay que compilarlos). Necesita VENTANA (en headless el
## RenderingDevice es dummy). Corre y sale.
##   godot --path . res://systems/procedural_map/test/fft_shader_compile_check.tscn

const DIR := "res://shaders/ocean_fft/"
const FILES := ["spectrum_compute.glsl", "spectrum_modulate.glsl", "fft_butterfly.glsl",
		"fft_compute.glsl", "transpose.glsl", "fft_unpack.glsl"]


func _ready() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		print("FFTC: SIN RenderingDevice (¿headless o Compatibility?) — no se puede probar")
		get_tree().quit(2)
		return
	print("FFTC: Godot %s · driver %s" % [
			Engine.get_version_info().string,
			ProjectSettings.get_setting("rendering/renderer/rendering_method", "?")])
	var ok := 0
	var bad := 0
	for f in FILES:
		var src: RDShaderFile = load(DIR + f)
		if src == null:
			print("FFTC  %-24s NO CARGA (import fallido)" % f)
			bad += 1
			continue
		var spirv := src.get_spirv()
		var err := ""
		for stage in [RenderingDevice.SHADER_STAGE_COMPUTE]:
			var e := spirv.get_stage_compile_error(stage)
			if e != "":
				err = e
		if err != "":
			print("FFTC  %-24s ERROR: %s" % [f, err.substr(0, 200)])
			bad += 1
			continue
		var rid := rd.shader_create_from_spirv(spirv)
		if rid.is_valid():
			print("FFTC  %-24s OK" % f)
			rd.free_rid(rid)
			ok += 1
		else:
			print("FFTC  %-24s SPIR-V ok pero shader_create fallo" % f)
			bad += 1
	print("FFTC RESULTADO: %d OK · %d con problemas" % [ok, bad])
	print("FFTC_DONE")
	get_tree().quit(0 if bad == 0 else 1)
