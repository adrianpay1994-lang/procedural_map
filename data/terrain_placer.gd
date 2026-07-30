class_name TerrainPlacer
extends RefCounted

## ============================================================================
## TerrainPlacer · Colocar objetos sobre el terreno (post-bake) — §7.3
## ============================================================================
## Y = sampler.get_height(), UP = sampler.get_normal(): los objetos asientan
## exactamente sobre el collider (misma fuente de datos).
## ============================================================================


static func get_placement_transform(sampler: HeightSampler, world_xz: Vector2,
		align_to_normal: bool = true, yaw_rad: float = 0.0) -> Transform3D:
	var origin := Vector3(world_xz.x, sampler.get_height(world_xz), world_xz.y)
	var up := sampler.get_normal(world_xz) if align_to_normal else Vector3.UP
	return _align_transform(origin, up, yaw_rad)


static func _align_transform(origin: Vector3, up: Vector3, yaw_rad: float) -> Transform3D:
	var basis := Basis()
	var fwd := Vector3.FORWARD.rotated(Vector3.UP, yaw_rad)
	var x_axis := up.cross(fwd).normalized()
	if x_axis.length_squared() < 0.001:
		x_axis = Vector3.RIGHT
	var z_axis := x_axis.cross(up).normalized()
	basis.x = x_axis
	basis.y = up.normalized()
	basis.z = z_axis
	return Transform3D(basis, origin)
