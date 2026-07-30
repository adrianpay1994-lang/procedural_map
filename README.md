# Mapa Procedural (v7 — Heightfield por Capas)

Sistema de mapa procedural estilo Rust para ModuleSystem. **Plan completo:**
[docs/PROCEDURAL_MAP_PLAN.md](../../docs/PROCEDURAL_MAP_PLAN.md) — leer §0-§3 antes de tocar nada.

## Estado de fases

| Fase | Estado | Qué entrega |
|---|---|---|
| F0 Librería + esqueleto | ✅ | pcg-terrain_1 importado (subset, sin modificar), estructura de carpetas |
| F1 Núcleo de altura | ✅ | HeightSampler + 6 capas + 4 máscaras + bake paralelo determinista |
| F2 Terreno caminable | ✅ | Chunks 4-LOD + skirts, HeightMapShape3D por chunk, topología hidro, splat 8 materiales, shader v2 (debug), spawns, navmesh |
| F3 Material PBR | ✅ | TerrainTextureSet + Texture2DArrays + BiomeMap con tints climáticos; texturas en assets/terrain/ |
| F4 Agua | ✅ | Océano Gerstner+Beer-Lambert+Fresnel, lagos excavados, cintas de río con rapids, ProceduralWaterVolume con buoyancy |
| F5 Superficies | ✅ | ProceduralSurfaceOverride: pasos por material dominante del splat (override en SurfaceComponent) |
| F6 Spawning | ✅ | TopologyMap completo (FIELD/FOREST/SUMMIT/MAINLAND/DECOR…) + PlacementRule + ProceduralSpawner |
| F7 Monumentos + caminos | ✅ | Doble bake: plan de sitios → flatten + red Prim/A* → re-bake; TerrainModifierSet (splat+MONUMENT+limpieza) |
| F8–F11 | ⏳ | Vegetación GPU, audio ambiental, integración+presets+serialización, tooling de editor |

## Uso rápido

1. Instanciar `procedural_map.tscn` (o heredarla).
2. Asignar un `MapGenerationConfig` (.tres) en el Inspector — **sin config no genera**
   (así smoke.tscn puede instanciarla barata).
3. La pila `height_layers` vacía usa [VoronoiBaseLayer, NoiseHeightLayer].
   Ríos/carreteras se inyectan solos desde el grafo.

## Tests (headless, Godot 4.7-beta2 — no está en PATH)

```
"D:/godot/instal motor/Godot_v4.7-beta2_win64_console.exe" --headless --path . res://systems/procedural_map/test/test_height_layers.tscn --quit-after 120000
"D:/godot/instal motor/Godot_v4.7-beta2_win64_console.exe" --headless --path . res://systems/procedural_map/test/test_procedural_map.tscn --quit-after 300000
"D:/godot/instal motor/Godot_v4.7-beta2_win64_console.exe" --headless --path . res://tests/smoke.tscn --quit-after 30000
```

Esperado: `HEIGHT_TEST: PASS (9/9)` · `PROCMAP_TEST: PASS (9/9)` · `SMOKE: PASS (10/10)`.

## Trampas conocidas (no re-descubrir)

- **smoke.tscn instancia TODO res://systems** → las escenas de test tienen guardia
  `current_scene != self` y `procedural_map.tscn` no genera sin config.
- **El grafo pcg fuga por ciclos RefCounted** (Center↔Edge↔Corner) →
  `MapDataProvider.clear_graph()` los rompe en `_exit_tree`. No quitar.
- `enum Material` sombrea la clase nativa → el enum de materiales es `SplatRule.Ground`.
- `TerraceHeightLayer.sharpness`: banda de transición = `1 - sharpness` (1 = escalón duro).
- El bake corre por filas en WorkerThreadPool con un `HeightContext` por fila
  (caché de localización mutable — nunca compartir ctx entre threads).
