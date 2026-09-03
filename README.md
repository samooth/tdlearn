# tdlearn

A codebase structural quality sensor written in Zig.

## Overview

tdlearn computes five root cause metrics from your source code and produces a single quality signal (0–10000):

- **Modularity** — Newman's Q on the import graph
- **Acyclicity** — Tarjan's SCC cycle detection
- **Depth** — BFS longest path from entry points
- **Equality** — Gini coefficient on file complexity
- **Redundancy** — Shannon entropy on dead code

## Build

```bash
zig build
```

## Usage

```bash
tdlearn scan [path]     # Scan a project and print quality signal
tdlearn check [path]    # Check rules (exits 0 or 1)
tdlearn gate [path]     # Quality gate for CI
tdlearn --help          # Show help
tdlearn --version       # Show version
```

## Example Output

```
Scanning ....
Found 19 files, 2931 lines

Quality Signal: 9262/10000
Bottleneck: equality

Root Causes:
  Modularity:  1.000 (raw Q=1.000)
  Acyclicity:  1.000 (cycles=0)
  Depth:       1.000 (max=0)
  Equality:    0.682 (gini=0.318)
  Redundancy:  1.000 (ratio=0.000)
```

## Architecture

```
src/
├── core/           # Shared types, path utils, settings, heat tracker, snapshot
├── analysis/       # File walker, language registry
├── metrics/        # 5 root cause metrics + aggregation
└── main.zig        # CLI entry point
```

## Testing

```bash
zig build test
```

## License

MIT
