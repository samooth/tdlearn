# TODO — tdlearn

Estado actual: implementación parcial. El build y la suite principal ya pasan; todavía quedan bloqueadores de robustez, contratos y distribución.

Última auditoría: 2026-09-26

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

- Referencias: `src/analysis/manifests.zig`, `src/analysis/resolver.zig`, `build.zig` (`createModule`, `addTestStep`).
- [x] Resolver el conflicto de propiedad de `src/core/toml.zig`; los módulos no deben importar el mismo archivo mediante rutas relativas cruzadas.
- [x] Implementar `expandAlias` o eliminar la llamada incompleta.
- [x] Corregir el formato del resolver.
- [x] Mantener cambios locales existentes en `resolver.zig` y `manifests.zig` de forma explícita, sin descartarlos accidentalmente.
- [x] Verificar que `zig build` y `zig build test` compilan todos los módulos.

### [x] BUILD-002 — Completar la integración de manifests y aliases

- Referencias: `src/analysis/manifests.zig` (`readPackageAliasesAtRoot`), `src/analysis/graph_builder.zig` (`buildImportEdgesAtRootWithContents`), `src/analysis/resolver.zig` (`initWithAliases`).
- [x] Leer manifests una vez durante el análisis.
- [x] Pasar los aliases a `Resolver.initWithAliases`.
- [x] Resolver aliases de Cargo/workspaces y subpaths de paquetes npm.
- [x] Conservar nombres npm con guiones y registrar aparte las normalizaciones de Rust.
- [x] Resolver correctamente `@scope/package`, `main` e `index`.
- [x] Añadir pruebas de aliases válidos, conflictos, roots fuera del scan y manifests malformados.

### [ ] IO-001 — Hacer que los errores de filesystem no produzcan falsos éxitos

- Referencias: `src/main.zig` (`validateRoot`, `readFile`, `readOptionalFile`), `src/analysis/walker.zig` (`Walker.walk`, `Walker.appendFileNode`).
- [x] Validar que el path raíz existe, es un directorio y es legible antes de comenzar.
- [x] Diferenciar `NotFound`, permisos, errores de lectura, archivos demasiado grandes, UTF-8 inválido y `OutOfMemory`: `readFile`/`readOptionalFile` (`src/main.zig`) y `readSmallFile` (`src/analysis/manifests.zig`) devuelven `error.FileNotFound` y el resto de errores tipados, nunca `null`.
- [x] No convertir OOM o errores de lectura en “archivo ausente”: `Resolver.resolve` es `!?[]const u8` y `FunctionExtractor`/`ImportExtractor` propagan `error.OutOfMemory`; hay tests con `FailingAllocator` en `src/analysis/oom_test.zig` y `src/metrics/equality.zig`.
- [ ] Definir una política explícita para escaneos parciales; incluir `--allow-partial` solo si es necesario.
- [x] Reportar archivos escaneados, omitidos y fallidos con su motivo: `skipped_files` en el JSON y en el texto, con `file_too_large` (walker) y `parse_too_large` (contenido); un archivo ilegible aborta el escaneo con error tipado en vez de desaparecer del recuento.
- [ ] Añadir pruebas de integración para paths inexistentes, no legibles y archivos corruptos.

### [ ] CLI-001 — Hacer estricto el contrato de argumentos

- Referencias: `src/main.zig` (`parseOptions`, `printUsage`).
- [x] Rechazar comando ausente, flags desconocidos, flags repetidos y argumentos extra.
- [x] Validar que `--save` solo sea válido para `gate` y que las combinaciones de flags sean coherentes.
- [x] Soportar `--` y un único path posicional.
- [x] Definir códigos de salida: éxito, violación/gate fallido y error de uso/configuración/I/O.
- [x] Enviar help/version a stdout y errores a stderr.
- [ ] Añadir una matriz de tests para cada comando, flag y combinación inválida.

### [ ] CONFIG-001 — Hacer estricto y seguro el parser de reglas

- Referencias: `src/core/toml.zig` (`parseValue`, `parse`), `src/core/rules.zig` (`parseRules`, `validateTomlSyntax`).
- [ ] Reportar errores con línea y columna en vez de ignorar líneas o claves desconocidas.
- [x] Rechazar claves duplicadas, valores vacíos, comillas sin cerrar, arrays y secciones malformadas.
- [ ] Validar escapes no soportados y reportar línea/columna.
- [x] Rechazar tipos incorrectos y enteros fuera de rango sin truncamientos.
- [x] Validar scores finitos dentro de `[0, 1]`.
- [x] Exigir los campos obligatorios de layers y boundaries.
- [ ] Añadir tests de configs malformadas y garantizar que ninguna config inválida hace pasar `check`.

## P1 — análisis y métricas fiables

### [ ] ANALYSIS-001 — Separar archivos fuente de archivos recorrido

- Referencias: `src/analysis/walker.zig` (`walk`, `walkDir`, `flattenFiles`), `src/analysis/lang_registry.zig`, `src/main.zig` (`filterSourcePaths`, `collectSourceNodes`).
- [x] Definir el conjunto exacto de archivos que participa en cada métrica.
- [x] No contar README, JSON, binarios o extensiones desconocidas como nodos estructurales por accidente.
- [x] Definir el tratamiento de archivos vacíos, binarios, symlinks y archivos grandes.
- [x] Hacer que graphs, `file_count`, líneas y Gini usen el mismo universo de datos.
- [ ] Añadir fixtures end-to-end con archivos no fuente.

### [x] ANALYSIS-002 — Corregir la extracción de funciones Python

- Referencias: `src/analysis/functions.zig` (`detectDecl`, `findBodyEnd`).
- [x] Calcular `start_line`, `end_line` y `line_count` mediante indentación y declaraciones siguientes.
- [x] Detectar correctamente métodos y conservar su alcance.
- [x] Evitar solapamientos entre funciones consecutivas y soporte para defs anidados, docstrings y funciones de una línea.
- [x] Verificar que llamadas, duplicados y `max_fn_lines` reciben el cuerpo correcto.

### [ ] ANALYSIS-003 — Completar extractores de imports

- Referencias: `src/analysis/imports.zig`.
- [x] Filtrar comentarios, strings y template literals antes de extraer dependencias.
- [x] Soportar comillas simples/dobles, aliases y `import()`/`require()`.
- [x] Soportar imports agrupados de Python y la forma multilínea común de JS.
- [ ] Completar formas multilínea de Python/JS y bloques más complejos.
- [x] Resolver correctamente imports relativos de Python, `self`/`super` de Rust y variantes de Rust/Go: `resolveDotRelative` (`.helpers`, `..pkg.mod`), `resolveRustRelative` (`self::`, `super::`) y `normalizeSeparators` (`crate::`, `a::b`) tienen tests positivos y negativos.
- [x] No interpretar strings balanceados como imports fuera de un bloque válido.
- [x] Añadir fixtures por lenguaje con casos positivos y negativos.

### [ ] ANALYSIS-004 — Completar resolución de módulos multi-lenguaje

- Referencias: `src/analysis/resolver.zig`, `src/analysis/graph_builder.zig`.
- [x] Añadir extensiones soportadas por el registry, como `.mjs`, `.mts`, `.hpp`, `.cc`, `.cxx`, `.hxx`, `.m` y `.mm`.
- [x] Resolver rutas relativas anidadas y `self::`/`super::`.
- [x] Evitar que sufijos ambiguos se resuelvan al primer archivo según el orden del filesystem.
- [x] Aumentar el buffer para paths largos y probar paths anidados.
- [x] Probar Unicode y separadores nativos.
- [ ] Probar traversal y normalización de rutas.
- [x] Hacer el resultado independiente del orden de recorrido.
- [x] Propagar `error.OutOfMemory` en vez de devolver “no resuelto” (`resolve` es `!?[]const u8`, con test en `src/analysis/oom_test.zig`).

### [ ] ANALYSIS-005 — Completar funciones, clases y herencia

- Referencias: `src/analysis/functions.zig`, `src/analysis/classes.zig`, `src/analysis/inherit_graph.zig`.
- [ ] Soportar arrow functions, métodos, modificadores, genéricos, declaraciones multilínea y constructores C++ relevantes. Los modificadores, genéricos y namespaces C++ ya están cubiertos; faltan arrow functions y declaraciones multilínea.
- [ ] Detectar `export default class`, interfaces/type aliases de TypeScript, traits/impl de Rust y embedding de Go. `export default class`, `traits`/`impl` de Rust y namespaces cualificados ya están cubiertos; faltan `interface`/`type` de TS y el embedding de structs Go.
- [x] Resolver bases cualificadas, namespaces, headers C++ y ambigüedades entre paquetes: `leafName` reduce `ns::Base` a `Base` y hay tests de bases cualificadas, namespaces y plantillas.
- [ ] Corregir el fallback de herencia para que se use solo cuando no exista base importada.
- [x] Añadir tests de alcance, solapamientos y relaciones ambiguas.
- [x] Contar llaves sobre código saneado con el lexer compartido, incluidas las cadenas multilínea de Zig (`\\`), para que una llave dentro de un literal no corte el cuerpo de una función.

### [ ] GRAPH-001 — Hacer conservador el grafo de llamadas

- Referencias: `src/analysis/call_graph.zig` (`buildCallEdgesWithLimit`, `scanLine`).
- [ ] Resolver llamadas por símbolo, import, receiver y visibilidad; no solo por nombre global.
- [ ] Manejar `obj.run()`, `obj->run()`, métodos, aliases y dispatch sin crear edges falsos.
- [ ] Ignorar comentarios, strings y declaraciones inline correctamente.
- [ ] Dejar las llamadas no resolubles como ambiguas, no como aristas inventadas.
- [ ] Cubrir funciones privadas, nombres duplicados, comentarios y strings con tests negativos.

### [x] METRIC-001 — Definir y corregir la profundidad

- Referencias: `src/metrics/depth.zig`, `src/metrics/mod.zig` (`computeHealth`).
- [x] Decidir si la métrica representa camino más largo o distancia mínima.
- [x] Hacer explícita la política para ciclos, nodos inalcanzables y componentes desconectados.
- [x] Eliminar el límite fijo de 32 entry points o documentarlo y probarlo.
- [x] Añadir tests con rutas de distinta longitud, saltos, ciclos, raíces múltiples y archivos sin entry point.

### [x] METRIC-002 — Alinear Equality con la complejidad declarada

- Referencias: `src/analysis/functions.zig` (`computeComplexity`), `src/core/types.zig` (`FuncInfo`), `src/metrics/equality.zig` (`giniCoefficient`, `computeFunctionComplexityGini`).
- [x] Implementar complejidad ciclomática/cognitiva o renombrar la métrica a igualdad de tamaño de archivo.
- [x] Poblar los campos de complejidad o eliminar los que no se puedan calcular.
- [x] Añadir tests que demuestren que branches, y no solo líneas, afectan al resultado cuando aplique.

### [x] METRIC-003 — Corregir redundancia, dead code y duplicados

- Referencias: `src/metrics/dead_code.zig` (`analyze`, `propagateReachability`, `collectDuplicateFlags`), `src/metrics/dead_code_test.zig`.
- [x] Resolver llamadas por símbolo y alcanzar desde entry points/API pública.
- [x] No clasificar como test cualquier ruta que contenga la cadena `test`.
- [x] Eliminar el límite de declaraciones de 64 y validar exclusiones.
- [x] Comparar cuerpos normalizados con verificación secundaria para evitar colisiones de hash.
- [x] Manejar comentarios, strings, cuerpos grandes, funciones anidadas y solapamientos.
- [x] No premiar la ausencia de datos como si fuera cero redundancia; definir una política para proyectos sin funciones.

### [x] METRIC-004 — Validar ciclos y aristas de modularidad

- Referencias: `src/metrics/acyclicity.zig`, `src/metrics/modularity.zig`, `src/metrics/mod.zig` (`computeHealth`).
- [x] Decidir y probar si self-loops cuentan como ciclos.
- [x] Definir si acyclicity usa imports o la unión de imports, llamadas y herencia.
- [x] Rechazar o contabilizar aristas con endpoints desconocidos.
- [x] Documentar la partición usada por Newman y comportamiento de multigraphs, duplicados y grafo vacío.
- [x] Hacer las métricas deterministas y evitar sesgos por orden de archivos.

## P1 — configuración, CLI y persistencia

### [x] RULES-001 — Completar semántica de reglas y globs

- Referencias: `src/core/rules.zig` (`globMatch`, `validatePattern`, `checkRules`).
- [x] Validar nombres, paths, órdenes y solapamientos ambiguos entre layers.
- [x] Implementar una gramática de glob documentada para `*`, `**` y separadores.
- [x] Soportar escapes y definir el comportamiento Unicode/Windows.
- [x] Separar paths absolutos de paths relativos al root.
- [x] Deduplicar violaciones y hacer estable su orden.
- [x] Añadir tests de patrones conflictivos, `**` y límites de segmentos.

### [x] CORE-001 — Normalizar rutas y definir portabilidad

- Referencias: `src/core/path_utils.zig` (`canonicalRelative`, `isPackageIndexPath`), `src/analysis/walker.zig` (`normalizePaths`), `src/analysis/resolver.zig` (`normalizeSeparators`).
- [x] Usar basename/extensión correctos.
- [x] Separar paths del filesystem de paths canónicos.
- [x] Convertir a relativas las aristas y paths usados por rules.
- [x] Definir symlinks, junctions, dotfiles, case sensitivity, UNC y paths con puntos.
- [x] Implementar o corregir la convención de `mod.rs` y entry points.
- [x] Añadir tests portables de Unicode, traversal y separadores; la ejecución multi-OS queda en TEST-001.

### [x] JSON-001 — Versionar y estabilizar la salida JSON

- Referencias: `src/main.zig` (`JsonScan`, `JsonCheck`, `JsonGate`, `makeJsonScan`, `printHumanScan`), `README.md` ("JSON Output").
- [x] Añadir `schema_version` y versión de herramienta.
- [x] Añadir root y unidades.
- [x] Incluir archivos asociados, rule, severidad, `from` y `to` donde existan.
- [x] Incluir métricas anterior/nueva donde existan.
- [x] Definir un envelope único para errores de uso, configuración, I/O y baseline.
- [x] Emitir JSON para `gate --save --json`.
- [x] Emitir JSON para fallos de configuración.
- [x] Añadir golden tests y asegurar que el JSON exitoso no escribe diagnósticos en stdout.

### [ ] BASELINE-001 — Hacer robusto el baseline y su persistencia

- Referencias: `src/core/baseline.zig` (`readBaseline`, `Baseline.validate`), `src/main.zig` (`saveGate`, `compareGate`).
- [x] Añadir versión de schema y compatibilidad con el formato existente.
- [x] Validar scores finitos dentro de `[0, 1]`.
- [x] Validar contadores y tolerancias; definir la semántica de `total_functions`.
- [x] Escribir mediante archivo temporal y renombrado atómico, sin truncar un baseline válido.
- [x] Manejar baseline ausente, truncado, corrupto, de versión futura y escritura fallida.
- [x] Actualizar `.tdlearn/baseline.json` solo después de estabilizar el análisis y sus tests.

### [ ] CORE-002 — Integrar configuración, ownership y errores tipados

- Referencias: `src/core/settings.zig`, `src/core/rules.zig` (`parseRules`).
- [x] Integrar `Settings` o retirar campos que no tienen efecto: `Settings` pasó de 244 a 88 líneas y `core/types.zig` de 280 a 179; los campos sin consumidor (y los módulos `snapshot.zig`/`heat.zig`) se eliminaron en lugar de quedar como código muerto.
- [ ] Unificar límites, exclusiones y thresholds con el walker y el parser: hoy hay tres números escritos en dos archivos — `max_file_size_kb = 512` (walker), `max_parse_size_kb = 100` (pipeline) y el backstop duro de 2 MiB en `main.readFile`; los tres son intencionales, pero ninguno comparte constante y `readFile` no recibe el límite del pipeline.
- [x] Añadir `deinit`/ownership explícito y `errdefer` para resultados parciales: el rewrite de `dead_code.zig` libera flags, índices y `local_calls` con `defer`/`errdefer`, y `readFile` libera el buffer con `errdefer`.
- [x] Comprobar el estado del allocator y propagar errores de dominio con contexto: sin `catch return null` ni `catch continue` sobre rutas de error en `src/analysis` y `src/metrics`.
- [x] Añadir tests con `FailingAllocator` y errores de cada API pública (`src/analysis/oom_test.zig`, `src/metrics/equality.zig`).

## P2 — pruebas, rendimiento y entrega

### [ ] TEST-001 — Crear pruebas de integración end-to-end

- Referencias: `build.zig` (`addTestStep`), `src/main.zig` (`parseOptions`, `runScan`, `runCheck`, `runGate`).
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

- Referencias: `src/metrics/mod.zig` (`computeEquality`), `src/analysis/call_graph.zig` (`buildCallEdgesWithLimit`), `src/analysis/walker.zig` (`countLines`, `appendFileNode`).
- [x] Indexar cada archivo una sola vez y evitar releerlo.
- [x] Reemplazar deduplicación O(E²) por sets hash.
- [ ] Eliminar límites arbitrarios de entry points, statements y tamaños, o hacerlos configurables y seguros.
- [x] Proteger índices y conteos contra overflow y entradas inválidas.

### [ ] CLEANUP-001 — Conectar o retirar APIs incompletas

- Referencias: `src/metrics/mod.zig`, `src/metrics/dead_code.zig`, `src/core/settings.zig`, `src/core/types.zig`.
- [x] Integrar `Snapshot`, `HeatTracker` y los módulos de métricas o retirar su API pública: `snapshot.zig`, `heat.zig` y `redundancy.zig` se eliminaron (no tenían consumidor y sus tests ni siquiera se ejecutaban); la redundancia la calcula `dead_code.analyze`.
- [x] Eliminar helpers duplicados, estados muertos y cálculos de score no usados: sin huérfanos, verificado recorriendo `src/**/*.zig` contra los imports de cada módulo.
- [ ] Documentar ownership, invariantes y seguridad de hilos de las APIs públicas.
- [ ] Añadir smoke tests del paquete `tdlearn-core` instalado.

### [ ] CLEANUP-002 — Poder actuar sobre los duplicados que se reportan

- Referencias: `src/metrics/dead_code.zig:739-806` (`collectDuplicateFlags`), `src/main.zig` (salida de `scan`).
- [ ] `scan` solo imprime `duplicated: 5`; no dice qué funciones son ni dónde están, así que el número no es accionable sin instrumentar el código.
- [ ] Exponer los grupos duplicados (miembros, path, línea y tamaño del cuerpo) en la salida de texto y en el JSON, junto al conteo.
- [ ] Mantener el JSON estable: es un campo aditivo, y `gate`/`check` no deben empezar a comparar la lista.

### [ ] CI-001 — Automatizar verificación y releases

- Referencias: `.github/workflows/ci.yml`, `build.zig` (`addRunCommand`).
- [x] Añadir workflow para `zig fmt --check`, `zig build`, `zig build test` y ReleaseSafe.
- [x] Ejecutar `tdlearn check .` y `tdlearn gate .` sobre un baseline estable.
- [x] Incluir `build.zig.zon` en el `zig fmt --check` de CI y en la lista del README.
- [x] Añadir `concurrency` por ref con `cancel-in-progress` para no acumular runs obsoletos.
- [x] Limitar `push` a `main` e ignorar tags, con el coste evitado documentado inline en el workflow.
- [x] Delegar los finales de línea a `.gitattributes` (`* text=auto eol=lf` más binarios fijados).
- [ ] Validar contra una versión estable soportada de Zig y la matriz de sistemas objetivo.
- [ ] Publicar artefactos, checksums y tags de release de forma reproducible.
- [ ] Reactivar la ejecución en tags cuando exista un workflow de release; hoy un push de tag solo repite la matriz de 3 SO.

### [ ] DOC-001 — Alinear documentación y empaquetado

- Referencias: `README.md`, `build.zig.zon`, `LICENSE`, `.gitattributes`.
- [x] Documentar instalación, `zig build run --`, rutas soportadas, límites y limitaciones del parser.
- [x] Corregir el ejemplo JSON para que sea JSON válido.
- [x] Añadir el archivo `LICENSE` declarado por el README.
- [x] Declarar `README.md` y `LICENSE` en `paths` de `build.zig.zon`.
- [ ] Derivar la versión de una única fuente (`tool_version` en `src/main.zig` y `.version` en `build.zig.zon` siguen duplicadas).
- [x] Corregir `paths` que referencian directorios inexistentes.
- [x] Documentar esquema de TOML, JSON y baseline, compatibilidad y política de migraciones.
- [x] Documentar la escala de calidad: `0–1` en config y baseline, `0–10000` en salida, y por qué difieren.
- [x] Documentar la escala del quality signal: media geométrica, suelo 0.01 y techo 3981/10000.
- [x] Documentar los códigos de salida 0/1/2 y el envelope `error_info` de `--json`.
- [x] Documentar qué compara `gate`, con qué tolerancia, y que `total_functions` no se compara.
- [x] Refrescar el ejemplo de salida con números reales del repositorio, etiquetados como snapshot.

### [ ] QA-001 — Cerrar los controles del propio proyecto

- Referencias: `.tdlearn/rules.toml`, `.tdlearn/baseline.json`.
- [x] Hacer que `tdlearn check .` pase sin desactivar límites relevantes.
- [x] Resolver o justificar las violaciones actuales de tamaño de archivo/función.
- [x] Verificar que `tdlearn gate .` falla solo por regresiones reales.
- [x] Añadir `max_cycles = 0` para que una regresión de ciclos no quede tapada por una ganancia de calidad.
- [x] Añadir `max_cyclomatic = 20` y `max_cognitive = 45` para que la cola de complejidad —la que mide `equality`— no pueda pudrirse en silencio (ver RULES-002).
- [x] Regenerar `.tdlearn/baseline.json` una vez commitados los cambios que lo producían. `total_functions` no participa en el gate (`src/core/baseline.zig`, `Baseline.compare`).
- [ ] Fijar las GitHub Actions por SHA, para que un tag upstream movido no cambie lo que ejecuta CI.

### [x] QA-002 — Partir `src/core/rules.zig` y bajar `max_file_lines`

- Referencias: `src/core/rules.zig` (1091 líneas), `src/core/rules_test.zig` (608), `src/main.zig` (1152), `src/main_test.zig` (383), `.tdlearn/rules.toml` (`max_file_lines = 1200`), `README.md` ("This repository's own rules").
- [x] Documentar la excepción de `max_file_lines = 1400` en `rules.toml` y en el README, en vez de subir el límite en silencio.
- [x] Sacar los 388 renglones de tests de `rules.zig` a `src/core/rules_test.zig`, que solo usa la API pública (`parseRules`, `checkRules`, `globMatch`): de paso demuestra que la superficie pública basta para configurar y verificar un proyecto. `rules.zig` baja a 1091.
- [x] Sacar los tests del CLI a `src/main_test.zig` y enraizar el artefacto de test en ese archivo (`build.zig`, `addTestStep`), para que la dependencia sea de una sola dirección (tests → implementación) y ningún archivo mezcle implementación con tests.
- [x] Bajar `max_file_lines` de 1400 a 1200 (el archivo mayor es `main.zig` con 1152) y quitar la excepción documentada: ya no aplica porque ningún archivo bajo `src/` lleva sus tests dentro.
- Nota: al añadir `main_test.zig` al grafo, `max_depth` pasó de 7 a 8 y la señal bajó ~100 puntos. Es el comportamiento correcto del depth (la cadena de imports más larga ahora incluye un archivo de test); ver METRIC-005.

### [x] RULES-002 — Techos de complejidad por función

- Referencias: `src/core/rules.zig` (`Constraints.max_cyclomatic`/`max_cognitive`, `checkComplexityCeiling`, `ComplexityKind`), `src/main.zig` (`Analysis.functions`, `JsonViolation`), `src/core/types.zig` (`FileFuncs.lang`), `.tdlearn/rules.toml`.
- [x] Añadir `max_cyclomatic` y `max_cognitive` al esquema, con validación (entero, sin negativos, sin desbordamiento) y rechazo de claves desconocidas.
- [x] Reportar **cada** función que excede el techo, con archivo, línea, nombre y valor medido, ordenadas por archivo y línea; a diferencia de `max_fn_lines`, que solo da el mayor.
- [x] Exponer `subject` y `line` en la violación (JSON y texto) para que un consumidor pueda agrupar o anotar sin parsear el mensaje, y arreglar `from`, que antes salía `null` en violaciones de un solo archivo.
- [x] Contar reglas, no hallazgos: `rules_checked` sube 1 por techo configurado, no por violación.
- [x] Corregir la deduplicación: comparaba solo regla y archivos, lo que habría colapsado dos funciones distintas del mismo archivo; ahora compara también mensaje y sujeto.
- [x] Validar las rutas de las funciones con la misma `validateInputPath` que el resto de entradas (lo encontró un test).
- [x] Refactorizar las 11 funciones que el techo nuevo señalaba, sin subirlas: `call_graph.appendResolvedEdges` (cognitivo 81), `toml.parseValue` (31), `source_lexer.sanitizeLine` (26), `inherit_graph.appendResolvedEdges` (52), `rules.checkConstraintRules`, `dead_code.markLocalTargets`, `functions.detectCFn`, `functions.countParameters`, `rules.validatePattern`, `rules.validateTomlSyntax`.
- Costecolateral útil: al refactorizar `call_graph.scanLine` se corrigió un bug real — no ignoraba comentarios, así que toda llamada dentro de un `//` o `/* */` contaba como arista — y se pasó al lexer compartido.

### [ ] METRIC-005 — Decidir si los archivos de test pertenecen al grafo de imports

- Referencias: `src/metrics/depth.zig`, `src/metrics/modularity.zig`, `src/metrics/dead_code.zig` (`isTestPath`).
- [ ] `depth` y `modularity` cuentan los archivos de test como nodos y sus aristas como dependencias, pero `dead_code` ya los excluye de la producción. Hoy `main_test.zig` aparece en `depth_path` y eso sube `max_depth` de 7 a 8 solo por existir.
- [ ] Decidir una sola política: o los tests no entran en el grafo estructural (y se documenta), o entran y se acepta que un árbol con muchos tests tiene un depth artificialmente alto.
- [ ] Si se eligen, el cambio es en `filterSourcePaths`/`computeHealth` y debe ir acompañado de una nota en el README, porque cambia los números de todos los usuarios.
