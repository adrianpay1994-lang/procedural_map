class_name ProceduralWaterVolume
extends WaterVolume

## ============================================================================
## ProceduralWaterVolume · WaterVolume + flotabilidad para RigidBody3D (§6)
## ============================================================================
## Hereda del WaterVolume del juego (nado del Player intacto) y suma buoyancy
## física (threejs-water): F = m·g·factor·fracción_sumergida + drag.
## Presupuesto PortalSDK: procesa como máximo max_bodies rígidos por frame.
## ============================================================================

## Multiplicador de la gravedad para el empuje (>1 ⇒ flota).
@export var buoyancy_strength: float = 1.6
@export var linear_drag: float = 2.0
@export var angular_drag: float = 1.0
## Semialtura usada para estimar la fracción sumergida del cuerpo.
@export var body_half_height_m: float = 0.4
@export var max_bodies: int = 40

const GRAVITY := 9.8


func _ready() -> void:
	super._ready()
	# Detectar también cuerpos rígidos del mundo (items, arrojables, loot).
	collision_mask |= PhysicsLayers.WORLD | PhysicsLayers.ITEM \
			| PhysicsLayers.THROWABLE | PhysicsLayers.LOOT


func _physics_process(delta: float) -> void:
	super._physics_process(delta)  # informa superficie a los personajes (nado)
	var processed := 0
	for body in get_overlapping_bodies():
		if not (body is RigidBody3D):
			continue
		if processed >= max_bodies:
			break
		processed += 1
		var rb := body as RigidBody3D
		var submerged := clampf(
				(surface_world_y - rb.global_position.y + body_half_height_m)
				/ (body_half_height_m * 2.0), 0.0, 1.0)
		if submerged <= 0.0:
			continue
		rb.apply_central_force(Vector3.UP * rb.mass * GRAVITY * buoyancy_strength * submerged)
		rb.apply_central_force(-rb.linear_velocity * linear_drag * rb.mass * submerged)
		rb.apply_torque(-rb.angular_velocity * angular_drag * rb.mass * submerged)
