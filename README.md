# tdlearn

A codebase structural quality sensor written in Zig.

## Overview

tdlearn computes five root cause metrics from your source code and produces a single quality signal (0–10000):

- **Modularity** — Newman's Q using a preassigned directory-module partition;
  import, call, and inheritance edges are retained as a weighted multigraph
- **Acyclicity** — Tarjan's SCC cycle detection on the union of import, call,
  and inheritance edges; self-loops are excluded
- **Depth** — longest simple path from entry points in the import graph
  (conventional entry files: `main.*`, `index.*`, `build.zig`, `__main__.py`,
  ...; falls back to files with no incoming imports)
- **Equality** — Gini coefficient on function complexity, with file-size
  fallback when no function data exists
- **Redundancy** — reachable dead code + exact normalized duplicate detection;
  no function data is treated conservatively as ratio `1.0`

All graph and rule paths are canonical root-relative `/` paths; native filesystem roots are kept separate during walking, and symlinks/junctions are not followed.

Imports, functions, calls, and inheritance are extracted line-based for Zig, Rust, Python, JavaScript/TypeScript, Go, and C/C++ — no tree-sitter, no external dependencies. The parser is intentionally conservative: unsupported macros, dynamic dispatch, and syntax that cannot be identified line-by-line may be omitted rather than guessed.

## Build

```bash
zig build
```

## Usage

```bash
tdlearn scan [path] [--json]   # Scan and print quality signal
tdlearn check [path] [--json]  # Check rules from .tdlearn/rules.toml (exit 0/1)
tdlearn gate [path] [--save] [--json]  # Quality gate against saved baseline
tdlearn --help
tdlearn --version
```

## Example Output

```
$ tdlearn scan .
Scanning ....
Found 31 files, 6300 lines

Quality Signal: 7684/10000
Bottleneck: equality
Import edges: 48, call edges: 24, inherit edges: 0
Functions: 147 (dead: 0, duplicated: 1)

Root Causes:
  Modularity:  0.587 (raw Q=0.359)
  Acyclicity:  1.000 (cycles=0)
  Depth:       0.800 (max=2)
  Equality:    0.575 (gini=0.425)
  Redundancy:  0.993 (ratio=0.007)
```

## Rules — `.tdlearn/rules.toml`

```toml
[constraints]
min_quality = 0.7          # quality signal floor
min_modularity = 0.5       # per-root-cause floors (optional)
max_cycles = 0             # allowed dependency cycles
max_file_lines = 400       # largest allowed file
max_fn_lines = 80          # largest allowed function

# Layer ordering — HIGHER order = more foundational.
# A file importing a layer with LOWER order than its own is a violation.
[[layers]]
name = "core"
paths = ["src/core/**"]
order = 3

[[layers]]
name = "cli"
paths = ["src/main.zig"]
order = 0

# Denied import edges (glob patterns)
[[boundaries]]
from = "src/metrics/**"
to = "src/main.zig"
reason = "metrics must not import the CLI"
```

Layer and boundary paths are root-relative, UTF-8, and use `/` as the canonical separator; ordinary Windows `\` separators in rules are normalized. `*` and `?` stay within a path segment, `**` crosses segments, and `\` escapes a pattern metacharacter. Absolute paths, `..` traversal, duplicate layers, and ambiguous file matches are rejected. Violations are deduplicated and sorted deterministically.

`tdlearn check` exits 1 on any Error-severity violation.

## Quality Gate — CI regression detection

```bash
tdlearn gate --save          # record baseline to .tdlearn/baseline.json
tdlearn gate                 # compare current state; exit 1 on regression
```

Regressions: quality drop > 0.02, or any increase in cycles, max depth, dead functions, or duplicates.

## JSON Output

All commands accept `--json` for machine-readable output on stdout:

```json
{
  "schema_version": 2,
  "tool_version": "0.1.0",
  "ok": true,
  "root": ".",
  "units": { "quality_signal": "0-10000", "line_counts": "lines", "edge_counts": "edges" },
  "quality_signal": 7684,
  "bottleneck": "equality",
  "files": 31,
  "lines": 6300,
  "import_edges": 48,
  "call_edges": 24,
  "root_causes": {
    "modularity": 5870,
    "acyclicity": 10000,
    "depth": 8000,
    "equality": 5750,
    "redundancy": 9930
  },
  "depth_path": ["src/main.zig", "src/analysis/mod.zig"],
  "hotspots": [
    {
      "file": "src/analysis/imports.zig",
      "name": "extract",
      "lines": 78,
      "cyclomatic": 33,
      "cognitive": 58,
      "score": 33058078
    }
  ]
}
```

`scan --json` incluye `depth_path` con la ruta de dependencia más larga y
`hotspots` con las diez funciones de mayor complejidad. Errores JSON usan el
mismo schema y un envelope `ok: false` con `error_info.code`, `category` y
`message`. `gate` incluye las métricas `baseline` y `current`.

## Architecture

```
src/
├── core/           # types, path utils, settings, TOML parser, rules, baseline
├── analysis/       # walker, language registry, import extraction + resolution,
│                   #   function/class extraction, call + inherit graphs
├── metrics/        # 5 root cause metrics, dead-code analysis, aggregation
└── main.zig        # CLI: scan / check / gate
```

## Testing

```bash
zig fmt --check src build.zig
zig build
zig build test
zig build -Doptimize=ReleaseSafe test
```

CI ejecuta la misma matriz con Zig `0.16.0` en Linux, macOS y Windows.
El workflow solo valida el repositorio; no publica releases ni modifica baselines.

## License

MIT
