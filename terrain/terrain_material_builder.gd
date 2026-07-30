class_name TerrainMaterialBuilder
extends RefCounted

## ============================================================================
## TerrainMaterialBuilder · Texture2DArrays + uniforms del shader v2 (§5.2)
## ============================================================================
## Homogeneiza las 8 capas (tamaño/formato) — patrón Clipmap3D. Slots null →
## plano de color (albedo=color debug del material, normal neutra, ORM neutro).
## ============================================================================

const TERRAIN_SHADER := preload("res://shaders/TerrainPBRBiomeMap.gdshader")

const FALLBACK_ALBEDO: Array[Color] = [
	Color(0.35, 0.65, 0.25),  # grass
	Color(0.45, 0.33, 0.22),  # dirt
	Color(0.88, 0.80, 0.55),  # sand
	Color(0.45, 0.45, 0.48),  # rock
	Color(0.95, 0.96, 1.00),  # snow
	Color(0.22, 0.38, 0.18),  # forest_floor
	Color(0.62, 0.60, 0.58),  # gravel
	Color(0.30, 0.24, 0.18),  # mud
]


static func build(sampler: HeightSampler, splat: SplatMapBuilder,
		biome_image: Image, texture_set: TerrainTextureSet,
		map_origin_world: Vector2, sea_level: float,
		debug_mode: bool) -> ShaderMaterial:
	if texture_set == null:
		texture_set = TerrainTextureSet.make_default()
	var size := texture_set.layer_size
	var mat := ShaderMaterial.new()
	mat.shader = TERRAIN_SHADER
	mat.set_shader_parameter("albedo_array",
			_build_array(texture_set.albedo, size, _albedo_fallbacks(), false))
	mat.set_shader_parameter("normal_array",
			_build_array(texture_set.normal, size,
					_flat_fallbacks(Color(0.5, 0.5, 1.0)), false))
	mat.set_shader_parameter("orm_array",
			_build_array(texture_set.orm, size,
					_flat_fallbacks(Color(1.0, 0.8, 0.0, 0.5)), true))
	mat.set_shader_parameter("splat_0", ImageTexture.create_from_image(splat.splat_0))
	mat.set_shader_parameter("splat_1", ImageTexture.create_from_image(splat.splat_1))
	mat.set_shader_parameter("biome_map", ImageTexture.create_from_image(biome_image))
	mat.set_shader_parameter("global_normalmap",
			ImageTexture.create_from_image(sampler.bake_normalmap_image()))
	mat.set_shader_parameter("heightfield",
			ImageTexture.create_from_image(sampler.bake_to_image()))
	var b := sampler.bounds
	mat.set_shader_parameter("map_origin", map_origin_world + b.get_center())
	mat.set_shader_parameter("map_size_m", maxf(b.size.x, b.size.y))
	mat.set_shader_parameter("sea_level_m", sea_level)
	mat.set_shader_parameter("debug_mode", debug_mode)
	mat.set_shader_parameter("debug_colors", FALLBACK_ALBEDO)
	return mat


static func _albedo_fallbacks() -> Array[Color]:
	return FALLBACK_ALBEDO.duplicate()


static func _flat_fallbacks(c: Color) -> Array[Color]:
	var out: Array[Color] = []
	for i in 8:
		out.append(c)
	return out


## Texture2DArray de 8 capas homogéneas (RGBA8, mismo tamaño, con mipmaps).
static func _build_array(textures: Array[Texture2D], size: int,
		fallbacks: Array[Color], keep_alpha: bool) -> Texture2DArray:
	var images: Array[Image] = []
	for i in 8:
		var img: Image = null
		if i < textures.size() and textures[i] != null:
			img = textures[i].get_image()
		if img == null:
			img = Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
			img.fill(fallbacks[i])
		else:
			img = img.duplicate()
			if img.is_compressed():
				img.decompress()
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			if img.get_width() != size or img.get_height() != size:
				img.resize(size, size, Image.INTERPOLATE_LANCZOS)
			if not keep_alpha:
				pass  # el alpha sobrante no molesta (el shader lee .rgb)
		img.generate_mipmaps()
		images.append(img)
	var arr := Texture2DArray.new()
	arr.create_from_images(images)
	return arr
