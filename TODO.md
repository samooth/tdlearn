# TODO — tdlearn

Estado actual: implementación parcial. El build y la suite principal ya pasan; todavía quedan bloqueadores de robustez, contratos y distribución.

Última auditoría: 2026-09-23

## Definición de terminado

- [x] `zig build`, `zig build test` y `zig build -Doptimize=ReleaseSafe test` terminan con código 0.
- [x] `zig fmt --check` termina con código 0.
- [ ] `scan`, `check` y `gate` tienen contratos de argumentos, streams y códigos de salida estables.
- [ ] Un path inexistente, un error de permisos o una configuración inválida producen un error explícito, nunca una calidad artificialmente perfecta.
- [ ] El escaneo es determinista, distingue archivos fuente de archivos omitidos y reporta diagnósticos de I/O.
- [ ] Las métricas tienen una semántica documentada y tests para ciclos, componentes desconectados, datos ausentes y falsos positivos.
- [ ] Existen pruebas de integración del pipeline completo y de la CLI.
- [ ] README, licencia, empaquetado, CI y releases reflejan el comportamiento real.

Prioridades:

- **P0**: bloquea compilar, ejecutar o evitar resultados incorrectos graves.
- **P1**: necesario para que el análisis y los contratos públicos sean fiables.
- **P2**: robustez, mantenibilidad, rendimiento y experiencia de distribución.

## P0 — bloqueadores

### [x] BUILD-001 — Restaurar la compilación de los módulos

- Referencias: `src/analysis/manifests.zig:5`, `src/analysis/resolver.zig:119`, `build.zig:28-34`.
- [x] Resolver el conflicto de propiedad de `src/core/toml.zig`; los módulos no deben importar el mismo archivo mediante rutas relativas cruzadas.
- [x] Implementar `expandAlias` o eliminar la llamada incompleta.
- [x] Corregir el formato del resolver.
- [x] Mantener cambios locales existentes en `resolver.zig` y `manifests.zig` de forma explícita, sin descartarlos accidentalmente.
- [x] Verificar que `zig build` y `zig build test` compilan todos los módulos.

### [x] BUILD-002 — Completar la integración de manifests y aliases

- Referencias: `src/analysis/manifests.zig`, `src/analysis/graph_builder.zig:24`, `src/analysis/resolver.zig`.
- [x] Leer manifests una vez durante el análisis.
- [x] Pasar los aliases a `Resolver.initWithAliases`.
- [x] Resolver aliases de Cargo/workspaces y subpaths de paquetes npm.
- [x] Conservar nombres npm con guiones y registrar aparte las normalizaciones de Rust.
- [x] Resolver correctamente `@scope/package`, `main` e `index`.
- [x] Añadir pruebas de aliases válidos, conflictos, roots fuera del scan y manifests malformados.

### [ ] IO-001 — Hacer que los errores de filesystem no produzcan falsos éxitos

- Referencias: `src/main.zig:72-80`, `src/analysis/walker.zig:65-75`.
- [x] Validar que el path raíz existe, es un directorio y es legible antes de comenzar.
- [ ] Diferenciar `NotFound`, permisos, errores de lectura, archivos demasiado grandes, UTF-8 inválido y `OutOfMemory`.
- [x] No convertir OOM o errores de lectura en “archivo ausente”.
- [ ] Definir una política explícita para escaneos parciales; incluir `--allow-partial` solo si es necesario.
- [ ] Reportar archivos escaneados, omitidos y fallidos con su motivo.
- [ ] Añadir pruebas de integración para paths inexistentes, no legibles y archivos corruptos.

### [ ] CLI-001 — Hacer estricto el contrato de argumentos

- Referencias: `src/main.zig:17-50`.
- [x] Rechazar comando ausente, flags desconocidos, flags repetidos y argumentos extra.
- [x] Validar que `--save` solo sea válido para `gate` y que las combinaciones de flags sean coherentes.
- [x] Soportar `--` y un único path posicional.
- [x] Definir códigos de salida: éxito, violación/gate fallido y error de uso/configuración/I/O.
- [x] Enviar help/version a stdout y errores a stderr.
- [ ] Añadir una matriz de tests para cada comando, flag y combinación inválida.

### [ ] CONFIG-001 — Hacer estricto y seguro el parser de reglas

- Referencias: `src/core/toml.zig:137-232`, `src/core/rules.zig:105-163`.
- [ ] Reportar errores con línea y columna en vez de ignorar líneas o claves desconocidas.
- [x] Rechazar claves duplicadas, valores vacíos, comillas sin cerrar, arrays y secciones malformadas.
- [ ] Validar escapes no soportados y reportar línea/columna.
- [x] Rechazar tipos incorrectos y enteros fuera de rango sin truncamientos.
- [x] Validar scores finitos dentro de `[0, 1]`.
- [x] Exigir los campos obligatorios de layers y boundaries.
- [ ] Añadir tests de configs malformadas y garantizar que ninguna config inválida hace pasar `check`.

## P1 — análisis y métricas fiables

### [ ] ANALYSIS-001 — Separar archivos fuente de archivos recorrido

- Referencias: `src/analysis/walker.zig:117-186`, `src/analysis/lang_registry.zig`, `src/main.zig:162-177`.
- [x] Definir el conjunto exacto de archivos que participa en cada métrica.
- [x] No contar README, JSON, binarios o extensiones desconocidas como nodos estructurales por accidente.
- [x] Definir el tratamiento de archivos vacíos, binarios, symlinks y archivos grandes.
- [x] Hacer que graphs, `file_count`, líneas y Gini usen el mismo universo de datos.
- [ ] Añadir fixtures end-to-end con archivos no fuente.

### [x] ANALYSIS-002 — Corregir la extracción de funciones Python

- Referencias: `src/analysis/functions.zig:150-167,316-361`.
- [x] Calcular `start_line`, `end_line` y `line_count` mediante indentación y declaraciones siguientes.
- [x] Detectar correctamente métodos y conservar su alcance.
- [x] Evitar solapamientos entre funciones consecutivas y soporte para defs anidados, docstrings y funciones de una línea.
- [x] Verificar que llamadas, duplicados y `max_fn_lines` reciben el cuerpo correcto.

### [ ] ANALYSIS-003 — Completar extractores de imports

- Referencias: `src/analysis/imports.zig:19-167`.
- [x] Filtrar comentarios, strings y template literals antes de extraer dependencias.
- [x] Soportar comillas simples/dobles, aliases y `import()`/`require()`.
- [x] Soportar imports agrupados de Python y la forma multilínea común de JS.
- [ ] Completar formas multilínea de Python/JS y bloques más complejos.
- [ ] Resolver correctamente imports relativos de Python, `self`/`super` de Rust y variantes de Rust/Go.
- [x] No interpretar strings balanceados como imports fuera de un bloque válido.
- [x] Añadir fixtures por lenguaje con casos positivos y negativos.

### [ ] ANALYSIS-004 — Completar resolución de módulos multi-lenguaje

- Referencias: `src/analysis/resolver.zig:107-256`, `src/analysis/graph_builder.zig:67`.
- [x] Añadir extensiones soportadas por el registry, como `.mjs`, `.mts`, `.hpp`, `.cc`, `.cxx`, `.hxx`, `.m` y `.mm`.
- [x] Resolver rutas relativas anidadas y `self::`/`super::`.
- [x] Evitar que sufijos ambiguos se resuelvan al primer archivo según el orden del filesystem.
- [x] Aumentar el buffer para paths largos y probar paths anidados.
- [x] Probar Unicode y separadores nativos.
- [ ] Probar traversal y normalización de rutas.
- [x] Hacer el resultado independiente del orden de recorrido.

### [ ] ANALYSIS-005 — Completar funciones, clases y herencia

- Referencias: `src/analysis/functions.zig:74-287`, `src/analysis/classes.zig:50-253`, `src/analysis/inherit_graph.zig:101-128`.
- [ ] Soportar arrow functions, métodos, modificadores, genéricos, declaraciones multilínea y constructors C++ relevantes.
- [ ] Detectar `export default class`, interfaces/type aliases de TypeScript, traits/impl de Rust y embedding de Go.
- [ ] Resolver bases cualificadas, namespaces, headers C++ y ambigüedades entre paquetes.
- [ ] Corregir el fallback de herencia para que se use solo cuando no exista base importada.
- [ ] Añadir tests de alcance, solapamientos y relaciones ambiguas.

### [ ] GRAPH-001 — Hacer conservador el grafo de llamadas

- Referencias: `src/analysis/call_graph.zig:90-292`.
- [ ] Resolver llamadas por símbolo, import, receiver y visibilidad; no solo por nombre global.
- [ ] Manejar `obj.run()`, `obj->run()`, métodos, aliases y dispatch sin crear edges falsos.
- [ ] Ignorar comentarios, strings y declaraciones inline correctamente.
- [ ] Dejar las llamadas no resolubles como ambiguas, no como aristas inventadas.
- [ ] Cubrir funciones privadas, nombres duplicados, comentarios y strings con tests negativos.

### [x] METRIC-001 — Definir y corregir la profundidad

- Referencias: `src/metrics/depth.zig:5-70`, `src/metrics/mod.zig:78-125`.
- [x] Decidir si la métrica representa camino más largo o distancia mínima.
- [x] Hacer explícita la política para ciclos, nodos inalcanzables y componentes desconectados.
- [x] Eliminar el límite fijo de 32 entry points o documentarlo y probarlo.
- [x] Añadir tests con rutas de distinta longitud, saltos, ciclos, raíces múltiples y archivos sin entry point.

### [x] METRIC-002 — Alinear Equality con la complejidad declarada

- Referencias: `src/analysis/functions.zig:40-47`, `src/core/types.zig:88-95`, `src/metrics/equality.zig:39-50`.
- [x] Implementar complejidad ciclomática/cognitiva o renombrar la métrica a igualdad de tamaño de archivo.
- [x] Poblar los campos de complejidad o eliminar los que no se puedan calcular.
- [x] Añadir tests que demuestren que branches, y no solo líneas, afectan al resultado cuando aplique.

### [x] METRIC-003 — Corregir redundancia, dead code y duplicados

- Referencias: `src/metrics/dead_code.zig:65-575`, `src/metrics/mod.zig:134-145`.
- [x] Resolver llamadas por símbolo y alcanzar desde entry points/API pública.
- [x] No clasificar como test cualquier ruta que contenga la cadena `test`.
- [x] Eliminar el límite de declaraciones de 64 y validar exclusiones.
- [x] Comparar cuerpos normalizados con verificación secundaria para evitar colisiones de hash.
- [x] Manejar comentarios, strings, cuerpos grandes, funciones anidadas y solapamientos.
- [x] No premiar la ausencia de datos como si fuera cero redundancia; definir una política para proyectos sin funciones.

### [x] METRIC-004 — Validar ciclos y aristas de modularidad

- Referencias: `src/metrics/acyclicity.zig:5-225`, `src/metrics/modularity.zig:5-260`, `src/metrics/mod.zig:57-100`.
- [x] Decidir y probar si self-loops cuentan como ciclos.
- [x] Definir si acyclicity usa imports o la unión de imports, llamadas y herencia.
- [x] Rechazar o contabilizar aristas con endpoints desconocidos.
- [x] Documentar la partición usada por Newman y comportamiento de multigraphs, duplicados y grafo vacío.
- [x] Hacer las métricas deterministas y evitar sesgos por orden de archivos.

## P1 — configuración, CLI y persistencia

### [x] RULES-001 — Completar semántica de reglas y globs

- Referencias: `src/core/rules.zig:188-290`, `src/core/rules.zig:560-930`.
- [x] Validar nombres, paths, órdenes y solapamientos ambiguos entre layers.
- [x] Implementar una gramática de glob documentada para `*`, `**` y separadores.
- [x] Soportar escapes y definir el comportamiento Unicode/Windows.
- [x] Separar paths absolutos de paths relativos al root.
- [x] Deduplicar violaciones y hacer estable su orden.
- [x] Añadir tests de patrones conflictivos, `**` y límites de segmentos.

### [x] CORE-001 — Normalizar rutas y definir portabilidad

- Referencias: `src/core/path_utils.zig:5-190`, `src/analysis/walker.zig:49-120`, `src/analysis/resolver.zig:328-335`.
- [x] Usar basename/extensión correctos.
- [x] Separar paths del filesystem de paths canónicos.
- [x] Convertir a relativas las aristas y paths usados por rules.
- [x] Definir symlinks, junctions, dotfiles, case sensitivity, UNC y paths con puntos.
- [x] Implementar o corregir la convención de `mod.rs` y entry points.
- [x] Añadir tests portables de Unicode, traversal y separadores; la ejecución multi-OS queda en TEST-001.

### [x] JSON-001 — Versionar y estabilizar la salida JSON

- Referencias: `src/main.zig:6-360,545-790`, `README.md:103-130`.
- [x] Añadir `schema_version` y versión de herramienta.
- [x] Añadir root y unidades.
- [x] Incluir archivos asociados, rule, severidad, `from` y `to` donde existan.
- [x] Incluir métricas anterior/nueva donde existan.
- [x] Definir un envelope único para errores de uso, configuración, I/O y baseline.
- [x] Emitir JSON para `gate --save --json`.
- [x] Emitir JSON para fallos de configuración.
- [x] Añadir golden tests y asegurar que el JSON exitoso no escribe diagnósticos en stdout.

### [ ] BASELINE-001 — Hacer robusto el baseline y su persistencia

- Referencias: `src/core/baseline.zig:8-100`, `src/main.zig:654-748`.
- [x] Añadir versión de schema y compatibilidad con el formato existente.
- [x] Validar scores finitos dentro de `[0, 1]`.
- [x] Validar contadores y tolerancias; definir la semántica de `total_functions`.
- [x] Escribir mediante archivo temporal y renombrado atómico, sin truncar un baseline válido.
- [x] Manejar baseline ausente, truncado, corrupto, de versión futura y escritura fallida.
- [ ] Actualizar `.tdlearn/baseline.json` solo después de estabilizar el análisis y sus tests.

### [ ] CORE-002 — Integrar configuración, ownership y errores tipados

- Referencias: `src/core/settings.zig`, `src/core/snapshot.zig`, `src/core/heat.zig`, `src/core/rules.zig:123-185`.
- [ ] Integrar `Settings` o retirar campos que no tienen efecto.
- [ ] Unificar límites, exclusiones y thresholds con el walker y el parser.
- [ ] Añadir `deinit`/ownership explícito y `errdefer` para resultados parciales.
- [ ] Comprobar el estado del allocator y propagar errores de dominio con contexto.
- [ ] Añadir tests con `FailingAllocator` y errores de cada API pública.

## P2 — pruebas, rendimiento y entrega

### [ ] TEST-001 — Crear pruebas de integración end-to-end

- Referencias: `build.zig:61-80`, `src/main.zig`.
- [x] Cubrir el pipeline `Walker → GraphBuilder → extractores → grafos → computeHealth`.
- [x] Probar `scan`, `check`, `gate` y `gate --save` sobre proyectos temporales.
- [ ] Cubrir stdout, stderr, JSON, códigos de salida, paths inválidos, archivos grandes, Unicode y symlinks.
- [ ] Ejecutar Debug y ReleaseSafe en Linux, macOS y Windows.
- [ ] Añadir benchmarks para repositorios grandes y verificar que no hay crecimiento cuadrático.

### [x] TEST-002 — Completar la matriz de lenguajes

- [x] Mantener fixtures para Zig, Rust, Python, JavaScript/TypeScript, Go y C/C++.
- [x] Añadir casos de comentarios, strings, imports agrupados/multilínea, aliases, métodos, genéricos y macros.
- [x] Ejecutar tests positivos y negativos para evitar edges, funciones o ciclos inventados.
- [x] Documentar explícitamente cualquier constructo no soportado por el parser line-based.

### [ ] PERF-001 — Eliminar límites y cuellos de botella

- Referencias: `src/metrics/mod.zig:157-189`, `src/analysis/call_graph.zig:157-167`, `src/analysis/walker.zig:182-249`.
- [x] Indexar cada archivo una sola vez y evitar releerlo.
- [x] Reemplazar deduplicación O(E²) por sets hash.
- [ ] Eliminar límites arbitrarios de entry points, statements y tamaños, o hacerlos configurables y seguros.
- [x] Proteger índices y conteos contra overflow y entradas inválidas.

### [ ] CLEANUP-001 — Conectar o retirar APIs incompletas

- Referencias: `src/core/snapshot.zig`, `src/core/heat.zig`, `src/core/settings.zig`, `src/metrics/redundancy.zig`, `src/core/types.zig`.
- [ ] Integrar `Snapshot`, `HeatTracker` y los módulos de métricas o retirar su API pública.
- [ ] Eliminar helpers duplicados, estados muertos y cálculos de score no usados.
- [ ] Documentar ownership, invariantes y seguridad de hilos de las APIs públicas.
- [ ] Añadir smoke tests del paquete `tdlearn-core` instalado.

### [ ] CI-001 — Automatizar verificación y releases

- [x] Añadir workflow para `zig fmt --check`, `zig build`, `zig build test` y ReleaseSafe.
- [ ] Ejecutar `tdlearn check .` y `tdlearn gate .` sobre un baseline estable.
- [ ] Validar contra una versión estable soportada de Zig y la matriz de sistemas objetivo.
- [ ] Publicar artefactos, checksums y tags de release de forma reproducible.

### [ ] DOC-001 — Alinear documentación y empaquetado

- Referencias: `README.md:19-129`, `build.zig.zon:7-13`.
- [ ] Documentar instalación, `zig build run --`, rutas soportadas, límites y limitaciones del parser.
- [x] Corregir el ejemplo JSON para que sea JSON válido.
- [ ] Añadir el archivo `LICENSE` declarado por el README.
- [ ] Derivar la versión de una única fuente.
- [x] Corregir `paths` que referencian directorios inexistentes.
- [x] Documentar esquema de TOML, JSON y baseline, compatibilidad y política de migraciones.

### [ ] QA-001 — Cerrar los controles del propio proyecto

- Referencias: `.tdlearn/rules.toml:5-34`, `.tdlearn/baseline.json`.
- [ ] Hacer que `tdlearn check .` pase sin desactivar límites relevantes.
- [ ] Resolver o justificar las violaciones actuales de tamaño de archivo/función.
- [ ] Recalcular el baseline solo después de corregir el análisis y ejecutar la suite completa.
- [ ] Verificar que `tdlearn gate .` falla solo por regresiones reales.
