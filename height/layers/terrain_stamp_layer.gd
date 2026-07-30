class_name TerrainStampLayer
extends HeightLayer

## ============================================================================
## TerrainStampLayer · Instancia colocada de un TerrainStamp (§F2)
## ============================================================================
## Coloca un perfil (TerrainStamp) en el mapa: posición + rotación + escala.
## base_ref: si el stamp es relative_to_terrain, HeightSampler.prepare_layers
## le pasa un sampler de la pila DEBAJO (mismo mecanismo que bake_targets) y
## el perfil se apoya en la altura local — el falloff de la máscara hace el
## lerp hacia el terreno vecino (la "polarización").
## Determinista: pura respecto a (pos); la colocación por seed la hace quien
## crea la instancia (FeatureLayerFactory / POIs) con MapPipeline.stage_seed.
## ============================================================================

@export var stamp: TerrainStamp
## Centro del stamp en metros (espacio de mapa centrado en el origen).
@export var position: Vector2 = Vector2.ZERO
@export_range(-180.0, 180.0, 1.0) var rotation_deg: float = 0.0
## Escala HORIZONTAL del footprint (radio y falloff escalan con esto).
@export_range(0.1, 8.0, 0.05) var scale: float = 1.0
## Multiplicador de amplitud por instancia (variedad procedural).
@export var amplitude_mult: float = 1.0

var _img: Image = null
var _base_ref: float = 0.0
var _rot: float = 0.0


func _init() -> void:
	layer_name = &"terrain_stamp"
	blend = BlendMode.REPLACE


func prepare(_ctx: HeightContext) -> void:
	_img = null
	_rot = deg_to_rad(rotation_deg)
	_base_ref = 0.0
	if stamp == null:
		return
	blend = stamp.op
	if stamp.heightmap != null:
		_img = stamp.heightmap.get_image()
		if _img != null and _img.is_compressed():
			_img.decompress()
	elif stamp.radial_profile != null:
		# Forzar el bake interno de la curva ACÁ (single-thread): sample_baked
		# bakea perezoso y en los workers sería una carrera.
		stamp.radial_profile.sample_baked(0.0)
	# Sin máscara del usuario ⇒ collar circular del propio stamp.
	if mask == null:
		var m := CircleMask.new()
		m.center = position
		m.radius_m = stamp.radius_m * scale
		m.falloff_m = stamp.falloff_m * scale
		mask = m


func needs_base_ref() -> bool:
	return stamp != null and stamp.relative_to_terrain


## Recibe el sampler de la pila DEBAJO (lo llama HeightSampler.prepare_layers).
func bake_base(sample_below: Callable) -> void:
	_base_ref = sample_below.call(position)


func affect_bounds() -> Rect2:
	if stamp == null:
		return Rect2()
	var r := (stamp.radius_m + stamp.falloff_m) * scale
	return Rect2(position - Vector2(r, r), Vector2(r, r) * 2.0)


func _value(pos: Vector2, _ctx: HeightContext) -> float:
	if stamp == null:
		return _base_ref
	var amp := stamp.amplitude_m * amplitude_mult
	var local := (pos - position).rotated(-_rot) / maxf(scale, 0.0001)
	if _img != null:
		return _base_ref + _sample_img(local) * amp
	if stamp.radial_profile != null:
		var r01 := clampf(local.length() / maxf(stamp.radius_m, 0.0001), 0.0, 1.0)
		return _base_ref + stamp.radial_profile.sample_baked(r01) * amp
	return _base_ref


## Muestreo bilineal del heightmap: local ∈ [-radius, radius]² → canal R.
func _sample_img(local: Vector2) -> float:
	var half := stamp.radius_m
	if absf(local.x) > half or absf(local.y) > half:
		return 0.0
	var u := (local.x / half) * 0.5 + 0.5
	var v := (local.y / half) * 0.5 + 0.5
	var w := _img.get_width()
	var h := _img.get_height()
	var fx := u * float(w - 1)
	var fy := v * float(h - 1)
	var x0 := int(floorf(fx))
	var y0 := int(floorf(fy))
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var a := lerpf(_img.get_pixel(x0, y0).r, _img.get_pixel(x1, y0).r, tx)
	var b := lerpf(_img.get_pixel(x0, y1).r, _img.get_pixel(x1, y1).r, tx)
	return lerpf(a, b, ty)
