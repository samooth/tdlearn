# tdlearn

[![CI](https://github.com/samooth/tdlearning/actions/workflows/ci.yml/badge.svg)](https://github.com/samooth/tdlearning/actions/workflows/ci.yml)
[![Zig 0.16.0](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Idiomas / Languages:** [English](README.md) · **Español** (este archivo)

> Traducción de [README.md](README.md). Las cifras son una instantánea de una
> ejecución real; para los valores actuales ejecuta `tdlearn scan .`. Si
> corriges algo en esta versión, replica el cambio en la otra: los dos
> documentos se mantienen en paralelo y cualquier divergencia es un error.

Un sensor de calidad estructural de código escrito en Zig.

## Resumen

tdlearn calcula cinco métricas de causa raíz sobre tu código y produce una
única señal de calidad (0–10000):

- **Modularidad** — Q de Newman usando una partición preasignada por directorio
  (módulo); las aristas de importación, llamada y herencia se conservan como
  multigrafo ponderado
- **Aciclicidad** — detección de ciclos por SCC de Tarjan sobre la unión de las
  aristas de importación, llamada y herencia; los bucles propios se excluyen
- **Profundidad** — camino simple más largo desde los puntos de entrada del
  grafo de importaciones (archivos de entrada convencionales: `main.*`,
  `index.*`, `build.zig`, `__main__.py`, …; si no hay, archivos sin
  importaciones entrantes)
- **Igualdad** — coeficiente de Gini sobre la complejidad de las funciones,
  con respaldo por tamaño de archivo cuando no hay datos de funciones
- **Redundancia** — código muerto alcanzable + detección exacta de duplicados
  normalizados; sin datos de funciones se trata de forma conservadora como
  ratio `1.0`

Todas las rutas del grafo y de las reglas son rutas canónicas relativas a la
raíz con `/`; las raíces nativas del sistema de archivos se mantienen separadas
durante el recorrido y no se siguen symlinks ni junctions.

Solo los archivos cuyo lenguaje se reconoce participan en las métricas:
`README.md`, `LICENSE`, JSON y extensiones desconocidas se recorren pero se
filtran antes de construir el grafo, así que nunca pueden convertirse en nodos
estructurales por accidente. El filtrado ocurre antes de cada agregado, así que
`files` y `lines` de la salida cuentan solo archivos fuente: un árbol con un
`README.md` de 500 líneas y un `.txt` de 400 junto a un `.zig` de 10 líneas
informa `Found 1 files, 11 lines`.

Las importaciones, funciones, llamadas y herencias se extraen línea a línea para
Zig, Rust, Python, JavaScript/TypeScript, Go y C/C++ — sin tree-sitter y sin
dependencias externas. El parser es deliberadamente conservador: las macros no
soportadas, el despacho dinámico y la sintaxis que no puede identificarse línea a
línea pueden omitirse en lugar de adivinarse.

## Requisitos

Zig `0.16.0` (estable), y nada más. `build.zig.zon` declara
`.minimum_zig_version = "0.16.0"` y el paquete no tiene dependencias.

## Compilar e instalar

```bash
git clone https://github.com/samooth/tdlearning.git
cd tdlearning
zig build
```

`zig build` instala dos artefactos:

| Ruta | Qué es |
| --- | --- |
| `zig-out/bin/tdlearn` | la CLI |
| `zig-out/lib/libtdlearn-core.a` | el módulo reutilizable `tdlearn-core` (`tdlearn-core.lib` en Windows) |

Pon `zig-out/bin` en el `PATH` para llamar a `tdlearn` directamente, o ejecútalo
a través del runner de compilación. El paso `run` depende del paso de
instalación, así que recompila primero y no hace falta ejecutar `zig build` por
separado:

```bash
zig build run -- scan .
```

Flags de compilación útiles: `-Doptimize=ReleaseSafe` (lo que prueba CI),
`--summary all` (muestra el grafo de pasos) y `--prefix <dir>` para instalar en
otro sitio que no sea `zig-out`.

## Uso

```bash
tdlearn scan [path] [--json]   # Escanea e imprime la señal de calidad
tdlearn check [path] [--json]  # Verifica las reglas de .tdlearn/rules.toml
tdlearn gate [path] [--save] [--json]  # Puerta de calidad contra el baseline guardado
tdlearn --help
tdlearn --version
```

`path` vale `.` por defecto y debe ser un directorio existente y legible. Solo
se acepta un path posicional; usa `--` para terminar el análisis de opciones.
`--json` lo aceptan `scan`, `check` y `gate`; `--save`, solo `gate`. `--help` y
`--version` no aceptan ningún otro argumento.

### Códigos de salida

El código de salida es el contrato — no parsees stdout para detectar fallos.

| Código | Significado |
| --- | --- |
| `0` | Éxito. También lo devuelven `--help` y `--version`. |
| `1` | `check` encontró al menos una violación de severidad Error, o `gate` encontró al menos una regresión. El informe se imprime completo igualmente. |
| `2` | Todo lo demás: errores de uso (comando ausente o desconocido, flag desconocido o duplicado, argumento extra), errores de configuración (`rules.toml` ausente o inválido, `baseline.json` ausente o inválido) y errores de análisis (raíz ilegible, fallo de E/S, memoria agotada). |

Con `--json`, el código `1` emite el payload normal con `"ok": false` y el array
`violations` poblado. El código `2` emite en su lugar un envelope de error:

```json
{
  "schema_version": 2,
  "tool_version": "0.1.0",
  "ok": false,
  "error_info": {
    "code": "NoRulesFile",
    "category": "configuration",
    "message": "NoRulesFile"
  }
}
```

`error_info.category` es uno de `usage`, `configuration`, `baseline`,
`analysis`. Sin `--json`, los errores son una única línea `tdlearn: <ErrorName>`
en stderr, y los informes legibles también van a stderr para que el output de
`--json` en stdout siga siendo parseable por máquina.

## Escala de la señal de calidad

**Dos escalas, un número.** Internamente cada puntuación de calidad y de causa
raíz es un float en `[0, 1]`. La terminal y los campos JSON `quality_signal` y
`root_causes` imprimen el mismo valor multiplicado por 10000 y truncado, así que
`0.7111` se muestra como `7111/10000`. Los archivos de configuración y de
baseline usan siempre la escala `0–1`:

| Dónde | Escala | Ejemplo |
| --- | --- | --- |
| `min_*` de `.tdlearn/rules.toml` | `0–1` | `min_quality = 0.7` significa `7000/10000` |
| `quality_signal` de `.tdlearn/baseline.json` | `0–1` | `0.7111` |
| Terminal, JSON `quality_signal`, JSON `root_causes` | `0–10000` | `7111` |

Las cinco causas raíz se normalizan antes de agregarse:

| Causa raíz | Normalización |
| --- | --- |
| Modularidad | `(Q + 0.5) / 1.5`, que mapea el Q de Newman `∈ [-0.5, 1]` a `[0, 1]` |
| Aciclicidad | `1 / (1 + ciclos)` — ciclos sin techo, decaimiento sigmoide |
| Profundidad | `1 / (1 + max_profundidad / 8)` — punto medio en un camino de 8 |
| Igualdad | `1 - gini` |
| Redundancia | `1 - ratio`, donde `ratio` es la proporción de funciones muertas **o** duplicados exactos (marcadas una vez, unión y no suma) |

Un proyecto sin funciones extraíbles no tiene datos de redundancia, así que el
ratio se fija en `1.0` — la ausencia de datos puntúa como maximally redundante
y no como maximally limpio.

La señal de calidad es la **media geométrica** de las cinco, con un suelo de
`0.01` por métrica. Dos consecuencias que conviene conocer antes de perseguir un
número:

- Es **multiplicativa, no aditiva**. Bajar una causa raíz de `1.0` a `0.5`
  reduce la señal a la mitad; mover una sola causa raíz un 1% mueve la señal
  alrededor del 0.2%. Un movimiento de 10 puntos en la presentación por 10000 es
  ruido normal, no una regresión — por eso la puerta usa una tolerancia en vez de
  "cualquier cambio".
- El suelo significa que **una única causa raíz colapsada tampoco puede dar 0**.
  Con una métrica en el suelo de `0.01` y las otras cuatro perfectas, la señal es
  `0.01^(1/5) = 0.398107…`, es decir `3981/10000`. Un proyecto degenerado llega
  ahí de verdad: un árbol con un único archivo sin funciones se escanea como
  `Quality Signal: 3981/10000`. En cambio `10000` exige las cinco causas raíz en
  `1.0`, cosa que ningún proyecto real alcanza.

`bottleneck` es simplemente la causa raíz con la puntuación más baja — la que
toca atacar a continuación.

## Ejemplo de salida

Salida real de este repositorio (una instantánea; los números se mueven con el
árbol):

```
$ tdlearn scan .
Scanning ....
Found 33 files, 14160 lines

Quality Signal: 7116/10000
Bottleneck: depth
Import edges: 62, call edges: 44, inherit edges: 0
Functions: 403 (dead: 0, duplicated: 5)

Root Causes:
  Modularity:  0.650 (raw Q=0.474)
  Acyclicity:  1.000 (cycles=0)
  Depth:       0.500 (max=8)
  Equality:    0.569 (gini=0.431)
  Redundancy:  0.987 (ratio=0.013)
Longest path: src/main.zig -> src/analysis/mod.zig -> ... -> src/core/toml.zig
Function hotspots:
  src/main.zig:main lines=62 cyclomatic=20 cognitive=34
  ...
```

Un escaneo que omitió archivos lo dice, en vez de informar de un proyecto
menor en silencio — ver [Archivos omitidos](#archivos-omitidos).

## Reglas — `.tdlearn/rules.toml`

### Restricciones

| Clave | Tipo | Significado |
| --- | --- | --- |
| `min_quality` | score `0–1` | suelo de la señal de calidad |
| `min_modularity` | score `0–1` | suelo de la causa raíz modularidad |
| `min_acyclicity` | score `0–1` | suelo de la causa raíz aciclicidad |
| `min_depth` | score `0–1` | suelo de la causa raíz profundidad |
| `min_equality` | score `0–1` | suelo de la causa raíz igualdad |
| `min_redundancy` | score `0–1` | suelo de la causa raíz redundancia |
| `max_cycles` | entero sin signo | ciclos SCC permitidos en el grafo unión |
| `max_file_lines` | entero sin signo | archivo más grande permitido |
| `max_fn_lines` | entero sin signo | función más grande permitida |
| `max_cyclomatic` | entero sin signo | techo de complejidad ciclomática, **por función** |
| `max_cognitive` | entero sin signo | techo de complejidad cognitiva, **por función** |

Toda clave es opcional; una clave ausente no se verifica, y `tdlearn check`
informa de cuántas reglas evaluó realmente — la configuración de este repositorio
informa `tdlearn check — 9 rules checked`. Las claves desconocidas, los valores no
enteros en `max_*` y los scores fuera de `[0, 1]` se rechazan: una configuración
malformada nunca puede hacer que `check` pase.

`max_file_lines` y `max_fn_lines` comparan contra el archivo y la función **más
grandes** del árbol, así que informan un número y tú localizas al culpable en los
`hotspots` de `scan`. Los dos techos de complejidad son distintos a propósito:
informan **cada** función que supera la línea, con su archivo, línea y nombre,
así que la salida es una lista de trabajo:

```
x [Error] max_cyclomatic: src/core/toml.zig:192: parseValue has cyclomatic complexity 31 > allowed 20
```

`scan` ordena sus 10 mejores `hotspots` por complejidad ciclomática primero, así
que una función puede ser invisible ahí y aun así violar un techo — por eso los
techos se aplican en `check`. Ningún techo tiene override por archivo o por capa;
si necesitas uno más alto para un directorio, el único recurso hoy es el valor
global.

### Capas y fronteras

```toml
[constraints]
min_quality = 0.7          # suelo de la señal de calidad
min_modularity = 0.5       # suelos por causa raíz (opcionales)
max_cycles = 0             # ciclos de dependencia permitidos
max_file_lines = 400       # archivo más grande permitido
max_fn_lines = 80          # función más grande permitida
max_cyclomatic = 20        # techos por función, reportados por función
max_cognitive = 45

# Orden de capas — MAYOR order = más fundamental.
# Un archivo que importa una capa con order MENOR que el suyo es una violación.
[[layers]]
name = "core"
paths = ["src/core/**"]
order = 3

[[layers]]
name = "cli"
paths = ["src/main.zig"]
order = 0

# Aristas de importación denegadas (patrones glob)
[[boundaries]]
from = "src/metrics/**"
to = "src/main.zig"
reason = "metrics must not import the CLI"
```

Las rutas de capas y fronteras son relativas a la raíz, UTF-8 y usan `/` como
separador canónico; los `\` ordinarios de Windows en las reglas se normalizan.
`*` y `?` no salen de un segmento de ruta, `**` cruza segmentos y `\` escapa un
metacarácter del patrón. Las rutas absolutas, el recorrido `..`, las capas
duplicadas y las coincidencias ambiguas de archivo se rechazan. Las violaciones
se deduplican y se ordenan de forma determinista.

### Las reglas de este repositorio

tdlearn se aplica a sí mismo sus reglas mediante `.tdlearn/rules.toml`, y donde
difiere del ejemplo de arriba la diferencia es deliberada y está anotada tanto
aquí como dentro del propio archivo:

- **`max_file_lines = 1200`, no 400.** El archivo de implementación más grande es
  `src/main.zig` con 1152 líneas. Este techo solía ser 1400 con una excepción
  documentada, porque `src/core/rules.zig` todavía llevaba dentro sus 388
  renglones de tests; esos tests viven ahora en `src/core/rules_test.zig` y los
  de la CLI en `src/main_test.zig`, así que ningún archivo bajo `src/` mezcla
  implementación con tests y la excepción desapareció.
- **`max_cyclomatic = 20` y `max_cognitive = 45`.** Contienen la cola que mide la
  causa raíz `equality` (un Gini sobre la complejidad de las funciones), para
  que la puntuación no se pudra en silencio mientras la señal de calidad sigue
  pareciendo buena. Once funciones superaban uno de los dos techos cuando se
  añadieron las reglas; cada una se partió en helpers con nombre en lugar de
  silenciarla subiendo el valor.
- `max_cycles = 0` es redundante con la causa raíz de aciclicidad a propósito.
  `gate` solo falla ante un *aumento* de ciclos respecto al baseline, así que una
  regresión de ciclos introducida junto a una ganancia de calidad no haría falta
  la puerta; la restricción explícita `max_cycles = 0` es la que la detecta.

## Puerta de calidad — detección de regresiones en CI

```bash
tdlearn gate --save          # registra el baseline en .tdlearn/baseline.json
tdlearn gate                 # compara el estado actual; sale 1 si hay regresión
```

`--save` crea `.tdlearn/` si hace falta y escribe el baseline de forma atómica
(archivo temporal + renombrado), así que una save interrumpida nunca puede
truncar un baseline válido. `gate` sin `--save` nunca escribe — solo `--save`
escribe.

`gate` falla (código 1) ante cualquiera de estos casos:

| Métrica | Regresión |
| --- | --- |
| `quality_signal` | baja más de **0.02** (200 puntos en la presentación 0–10000) |
| `cycle_count` | aumenta |
| `max_depth` | aumenta |
| `dead_functions` | aumenta |
| `duplicate_functions` | aumenta |

Una mejora nunca hace fallar la puerta. La tolerancia `0.02` es un delta absoluto
en la escala `0–1`, no un porcentaje, y es una constante fija en lugar de un
ajuste configurable.

`total_functions` se **registra pero no se compara** — solo participa en la
validación del baseline (`dead_functions` y `duplicate_functions` deben quedar
por debajo). Así que añadir o quitar funciones nunca puede hacer fallar la puerta
por sí solo; los otros cinco números tienen que moverse para que ella se entere.

`baseline.json` lleva `schema_version: 1` y se valida al leerse:
`quality_signal` debe ser finito y estar en `[0, 1]`, los contadores deben ser
consistentes entre sí y cualquier otro `schema_version` se rechaza con
`UnsupportedBaselineSchema` en vez de reinterpretarse en silencio.

## Salida JSON

`scan`, `check` y `gate` aceptan `--json` para salida legible por máquina en
stdout:

```json
{
  "schema_version": 2,
  "tool_version": "0.1.0",
  "ok": true,
  "root": ".",
  "units": { "quality_signal": "0-10000", "line_counts": "lines", "edge_counts": "edges" },
  "quality_signal": 7116,
  "bottleneck": "depth",
  "files": 33,
  "lines": 14160,
  "import_edges": 62,
  "call_edges": 44,
  "inherit_edges": 0,
  "functions": 403,
  "dead_functions": 0,
  "duplicate_functions": 5,
  "root_causes": {
    "modularity": 6495,
    "acyclicity": 10000,
    "depth": 5000,
    "equality": 5694,
    "redundancy": 9872
  },
  "depth_path": [
    "src/main.zig",
    "src/analysis/mod.zig",
    "src/analysis/graph_builder.zig",
    "src/analysis/resolver.zig",
    "src/analysis/manifests.zig",
    "src/core/mod.zig",
    "src/core/rules_test.zig",
    "src/core/rules.zig",
    "src/core/toml.zig"
  ],
  "hotspots": [
    {
      "file": "src/main.zig",
      "name": "main",
      "lines": 62,
      "cyclomatic": 20,
      "cognitive": 34,
      "score": 20034062
    }
  ],
  "skipped_files": []
}
```

`scan --json` incluye `depth_path` con el camino de dependencias más largo y
`hotspots` con las diez funciones más complejas. Los errores JSON usan el mismo
schema y un envelope `ok: false` con `error_info.code`, `category` y `message`.
`gate` añade las métricas `baseline` y `current`.

Una violación de `check` es un objeto JSON con:

| Campo | Significado |
| --- | --- |
| `rule` | la clave de configuración que se violó |
| `severity` | `Error` (hace fallar el código de salida) o `Warning` |
| `message` | el hallazgo en una línea, suficiente para actuar sin los demás campos |
| `from` | el archivo del que trata la violación, o `null` en reglas agregadas |
| `to` | el otro extremo de una violación de arista, o `null` si no lo hay |
| `subject` | el nombre de la función culpable, o `null` en reglas que no son por función |
| `line` | línea (base 1) de `subject`, para anotar en CI, o `null` |

Las violaciones de complejidad por función llevan los tres campos `from`,
`subject` y `line`, así que un consumidor puede agruparlas o anotarlas sin
parsear `message`.

`hotspots[].score` es `ciclomática × 1_000_000 + cognitiva × 1_000 + líneas` —
una clave de orden lexicográfica, así que debe leerse como "primero ciclomática",
no como una magnitud. `depth_path` es el camino simple más largo que produjo
`max_depth`.

### Archivos omitidos

Todo resultado lleva un array `skipped_files` (vacío en el caso común) para que
un escaneo parcial sea visible en lugar de silenciosamente más pequeño:

```json
"skipped_files": [{ "path": "src/generated/big.zig", "reason": "parse_too_large" }]
```

Dos límites producen entradas, ambos configurables en
[`src/core/settings.zig`](src/core/settings.zig):

| Límite | Por defecto | Motivo | Efecto |
| --- | --- | --- | --- |
| `max_file_size_kb` | 512 | `file_too_large` | El archivo ni siquiera se cuenta en líneas: sin nodo, sin líneas, sin aristas. |
| `max_parse_size_kb` | 100 | `parse_too_large` | El archivo se recorre y se cuenta como nodo, pero su contenido no se parsea, así que no aporta importaciones, funciones ni clases. |

Cualquier otra cosa — un archivo inexistente, un error de permisos, una
asignación de memoria agotada — **no** es una omisión. Aborta la ejecución con
un error tipado, porque un escaneo que no puede leer un archivo que se le dijo
que lea no tiene una puntuación de calidad honesta.

## Arquitectura

```
src/
├── core/           # tipos, utilidades de path, settings, lexer compartido, parser
│                   #   de TOML, reglas, baseline
├── analysis/       # walker, registro de lenguajes, extracción y resolución de
│                   #   importaciones, extracción de funciones/clases, grafos de
│                   #   llamadas y herencia
├── metrics/        # 5 métricas de causa raíz, análisis de código muerto, agregación
├── main.zig        # CLI: scan / check / gate
└── *_test.zig      # tests, uno por módulo que es lo bastante grande para sacarlos
```

Las capas las impone `.tdlearn/rules.toml`: `core` es la más fundamental
(order 3), `metrics` y `analysis` se apoyan en ella (order 2) y la CLI está
encima (order 0). Un archivo solo puede importar capas con un order mayor o igual
que el suyo.

Los tests viven en su propio `*_test.zig` junto al módulo que cubren
(`rules_test.zig`, `dead_code_test.zig`, `oom_test.zig`, `main_test.zig`), lo que
permite que `max_file_lines` acote la implementación en vez de mezclarla con los
tests. `rules_test.zig` y `dead_code_test.zig` manejan el módulo solo a través de
su API pública; `main_test.zig` importa `main.zig` para ejecutar los pasos
internos del pipeline, y `build.zig` enraíza ese artefacto de test en el archivo
de test para que la dependencia siga siendo de una sola dirección.

La extracción de funciones, clases e importaciones comparte un único
`core/source_lexer.zig`, así que los comentarios y los literales de cadena,
template o raw se enmascaran una vez, de forma coherente, para todos los
lenguajes y todos los extractores.

## Pruebas

Los comandos de verificación siguientes son exactamente los que ejecuta CI, en el
mismo orden, con Zig `0.16.0` en Linux, macOS y Windows:

```bash
zig fmt --check src build.zig build.zig.zon
zig build
zig build test
zig build -Doptimize=ReleaseSafe test
zig build run -- scan . --json
zig build run -- check . --json
zig build run -- gate . --json
```

`zig fmt --check` incluye `build.zig.zon` porque también es un archivo fuente de
Zig que editan tanto CI como quienes contribuyen.

CI ejecuta la misma matriz con Zig `0.16.0` en Linux, macOS y Windows. El
workflow solo valida este repositorio: no publica releases ni reescribe baselines.

Los finales de línea los gobierna `.gitattributes` (`* text=auto eol=lf`, con los
tipos binarios que produce este proyecto fijados a `-text`), así que el checkout
es idéntico byte a byte en las tres plataformas y `zig fmt --check` nunca ve un
diff dependiente de la plataforma.

## Documentación

| Documento | English | Español |
| --- | --- | --- |
| Descripción del proyecto, uso, reglas, JSON | [README.md](README.md) | [README.es.md](README.es.md) (este archivo) |
| Lista de trabajo pendiente, con referencias al código | [TODO.md](TODO.md) | [TODO.es.md](TODO.es.md) |
| Licencia | [LICENSE](LICENSE) | [LICENSE](LICENSE) (idéntico, no se traduce) |
| Configuración de las reglas que se aplican a este repositorio | [`.tdlearn/rules.toml`](.tdlearn/rules.toml) (comentarios en inglés) | — |
| Verificación en CI | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) (comentarios en inglés) | — |

Reglas de este repositorio sobre la documentación:

- La documentación de usuario (`.md`) existe en inglés y en español, y los dos
  archivos se mantienen en paralelo con la misma información.
- El código, los comentarios del código, los comentarios de `rules.toml` y los
  del workflow de CI están **en inglés**: es el idioma compartido del proyecto y
  duplicarlos dentro del código haría más difícil mantenerlo.
- Cada referencia a un archivo o a una sección de este README es un enlace
  relativo, para que se pueda navegar hasta la implementación.

## Licencia

MIT — ver [LICENSE](LICENSE).
