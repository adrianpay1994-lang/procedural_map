class_name MapPipeline
extends RefCounted

## ============================================================================
## MapPipeline · Etapas explícitas de generación (TERRAIN_PIPELINE_V2_PLAN §F1)
## ============================================================================
## Orden canónico estilo Rust: Seed → Ruido → Heightmap → Biomas → Ríos →
## Corredores → Monumentos → Vegetación → Recursos → Chunks → Meshes.
## Mapeo actual (los nombres alimentan la pantalla de carga vía phase_completed):
##   graph        = Seed + ruido + grafo Voronoi + biomas (plano semántico)
##   plan_routes  = RUTAS de ríos/carreteras/vías + lagos (Fase A, sin altura)
##   height_bake  = heightmap base + esculpido (Fases B+C)
##   topology     = TopologyMap hidrológico
##   pois_plan    = monumentos: plan + red de caminos + re-bake
##   splat        = SplatMap + BiomeMap
##   terrain_mesh = chunks + meshes (+ SeaMask)
##   colliders / water / topology_full / entities / rails / vegetation /
##   pois_place / navmesh / spawn_points
## Contrato por etapa: función async (puede await), condición de habilitación
## evaluada AL LLEGAR (no al armar la lista — p. ej. rails depende de lo que
## dejó plan_routes), timing propio y un frame cedido después por el runner.
## ============================================================================

class Stage:
	var stage_name: StringName
	var fn: Callable          ## async: el runner la ejecuta con await
	var enabled: Callable     ## -> bool, evaluada justo antes de correr

	func _init(p_name: StringName, p_fn: Callable, p_enabled: Callable) -> void:
		stage_name = p_name
		fn = p_fn
		enabled = p_enabled


var stages: Array[Stage] = []


## Agrega una etapa. enabled: Callable -> bool (omitida = siempre corre).
func add(stage_name: StringName, fn: Callable, enabled: Callable = Callable()) -> void:
	var en := enabled if enabled.is_valid() else func() -> bool: return true
	stages.append(Stage.new(stage_name, fn, en))


## Semilla determinista de una etapa (requisito MP): mismo seed_variant +
## mismo nombre ⇒ misma semilla, independiente de qué otras etapas corran.
## Usar para TODO RNG de etapas nuevas (las existentes conservan sus hashes).
static func stage_seed(seed_variant: int, stage_name: StringName) -> int:
	return hash([seed_variant, stage_name])


## Corre las etapas en orden. on_phase_done: Callable(StringName, ms) al TERMINAR;
## on_phase_start: Callable(StringName) al EMPEZAR (para mostrar la fase REAL en
## curso en la carga); frame_yield: async que cede un frame entre etapas.
func run(on_phase_done: Callable, frame_yield: Callable,
		on_phase_start: Callable = Callable()) -> void:
	for st in stages:
		if not st.enabled.call():
			continue
		if on_phase_start.is_valid():
			on_phase_start.call(st.stage_name)
		var t0 := Time.get_ticks_msec()
		await st.fn.call()
		if on_phase_done.is_valid():
			on_phase_done.call(st.stage_name, float(Time.get_ticks_msec() - t0))
		if frame_yield.is_valid():
			await frame_yield.call()
