# tdlearn

A codebase structural quality sensor written in Zig.

## Overview

tdlearn computes five root cause metrics from your source code and produces a single quality signal (0–10000):

- **Modularity** — Newman's Q on the import graph
- **Acyclicity** — Tarjan's SCC cycle detection
- **Depth** — BFS longest path from entry points
- **Equality** — Gini coefficient on file complexity
- **Redundancy** — dead code + duplicate function detection

Imports are extracted line-based for Zig, Rust, Python, JavaScript/TypeScript, Go, and C/C++ — no tree-sitter, no external dependencies.

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
Import edges: 40
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
  "quality_signal": 7684,
  "bottleneck": "equality",
  "files": 31,
  "lines": 6300,
  "import_edges": 40,
  "root_causes": { "modularity": 5870, "acyclicity": 10000, ... }
}
```

## Architecture

```
src/
├── core/           # types, path utils, settings, TOML parser, rules, baseline
├── analysis/       # walker, language registry, import extraction + resolution,
│                   #   function extraction, graph builder
├── metrics/        # 5 root cause metrics, dead-code analysis, aggregation
└── main.zig        # CLI: scan / check / gate
```

## Testing

```bash
zig build test
```

## License

MIT
