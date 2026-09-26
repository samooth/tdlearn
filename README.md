# tdlearn

[![CI](https://github.com/samooth/tdlearning/actions/workflows/ci.yml/badge.svg)](https://github.com/samooth/tdlearning/actions/workflows/ci.yml)
[![Zig 0.16.0](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Languages / Idiomas:** **English** (this file) · [Español](README.es.md)

> Translation of `README.es.md`. The numbers are a snapshot of a real run; run
> `tdlearn scan .` for the current values. If you fix something here, mirror it
> there: the two documents are kept in parallel, and any divergence is a bug.

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

Only files whose language is recognized participate in the metrics: `README.md`, `LICENSE`, JSON, and unknown extensions are walked but filtered out before the graph is built, so they can never become structural nodes by accident. Filtering happens before every aggregate, so `files` and `lines` in the output count source files only — a tree containing a 500-line `README.md` and a 400-line `.txt` next to one 10-line `.zig` file reports `Found 1 files, 11 lines`.

Imports, functions, calls, and inheritance are extracted line-based for Zig, Rust, Python, JavaScript/TypeScript, Go, and C/C++ — no tree-sitter, no external dependencies. The parser is intentionally conservative: unsupported macros, dynamic dispatch, and syntax that cannot be identified line-by-line may be omitted rather than guessed.

## Requirements

Zig `0.16.0` (stable), and nothing else. `build.zig.zon` declares
`.minimum_zig_version = "0.16.0"` and the package has no dependencies.

## Build and Install

```bash
git clone https://github.com/samooth/tdlearning.git
cd tdlearning
zig build
```

`zig build` installs two artifacts:

| Path | What it is |
| --- | --- |
| `zig-out/bin/tdlearn` | the CLI |
| `zig-out/lib/libtdlearn-core.a` | the reusable `tdlearn-core` module (`tdlearn-core.lib` on Windows) |

Put `zig-out/bin` on `PATH` to call `tdlearn` directly, or run it through the
build runner. The `run` step depends on the install step, so it rebuilds first
and there is no need to run `zig build` separately:

```bash
zig build run -- scan .
```

Useful build flags: `-Doptimize=ReleaseSafe` (what CI tests),
`--summary all` (see the graph of build steps), and `--prefix <dir>` to
install somewhere other than `zig-out`.

## Usage

```bash
tdlearn scan [path] [--json]   # Scan and print quality signal
tdlearn check [path] [--json]  # Check rules from .tdlearn/rules.toml
tdlearn gate [path] [--save] [--json]  # Quality gate against saved baseline
tdlearn --help
tdlearn --version
```

`path` defaults to `.` and must be an existing, readable directory. Only one
positional path is accepted; use `--` to end option parsing. `--json` is
accepted by `scan`, `check` and `gate`; `--save` only by `gate`. `--help` and
`--version` take no other argument at all.

### Exit codes

The exit code is the contract — do not parse stdout to detect failure.

| Code | Meaning |
| --- | --- |
| `0` | Success. Also returned by `--help` and `--version`. |
| `1` | `check` found at least one Error-severity violation, or `gate` found at least one regression. The report is still printed in full. |
| `2` | Everything else: usage errors (missing/unknown command, unknown/duplicate flag, extra argument), configuration errors (missing or invalid `rules.toml`, missing or invalid `baseline.json`), and analysis errors (unreadable root, I/O failure, out of memory). |

With `--json`, code `1` still emits the normal payload with `"ok": false` and a
populated `violations` array. Code `2` emits an error envelope instead:

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

`error_info.category` is one of `usage`, `configuration`, `baseline`,
`analysis`. Without `--json`, errors are a single `tdlearn: <ErrorName>` line on
stderr, and human-readable reports go to stderr so that `--json` output on
stdout stays machine-parseable.

## Quality Signal Scale

**Two scales, one number.** Every quality and root-cause score is a float in
`[0, 1]` internally. The terminal and the JSON `quality_signal` /
`root_causes` fields print the same value multiplied by 10000 and truncated, so
`0.7111` displays as `7111/10000`. Configuration and baseline files always use
the `0–1` scale:

| Where | Scale | Example |
| --- | --- | --- |
| `.tdlearn/rules.toml` `min_*` | `0–1` | `min_quality = 0.7` means `7000/10000` |
| `.tdlearn/baseline.json` `quality_signal` | `0–1` | `0.7111` |
| Terminal, JSON `quality_signal`, JSON `root_causes` | `0–10000` | `7111` |

The five root causes are normalized before aggregation:

| Root cause | Normalization |
| --- | --- |
| Modularity | `(Q + 0.5) / 1.5`, mapping Newman's `Q ∈ [-0.5, 1]` to `[0, 1]` |
| Acyclicity | `1 / (1 + cycles)` — unbounded cycles, sigmoid decay |
| Depth | `1 / (1 + max_depth / 8)` — midpoint at a longest path of 8 |
| Equality | `1 - gini` |
| Redundancy | `1 - ratio`, where `ratio` is the share of functions that are dead **or** an exact duplicate (flagged once, union not sum) |

A project with no extractable functions has no redundancy data, so the ratio is
set to `1.0` — missing data scores as maximally redundant rather than
maximally clean.

The quality signal is the **geometric mean** of the five, each floored at
`0.01`. Two consequences worth knowing before you chase a number:

- It is **multiplicative, not additive**. Dropping one root cause from `1.0` to
  `0.5` halves the signal; moving a single root cause by 1% moves the signal by
  roughly 0.2%. A 10-point move in the per-10000 display is normal churn, not
  a regression — which is why the gate uses a tolerance instead of "any change".
- The floor means a **single collapsed root cause still cannot report 0**.
  With one metric pinned at the `0.01` floor and the other four perfect, the
  signal is `0.01^(1/5) = 0.398107…`, i.e. it prints as `3981/10000`. A
  degenerate project really does land there: a tree of one function-less file
  scans as `Quality Signal: 3981/10000`. Conversely `10000` requires all five
  root causes at `1.0`, which no real project reaches.

`bottleneck` is simply the lowest-scoring root cause — the one to work on next.

## Example Output

Real output from this repository (a snapshot; the numbers move as the tree
changes):

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

A scan that skipped files says so, rather than quietly reporting a smaller
project — see [Skipped files](#skipped-files).

## Rules — `.tdlearn/rules.toml`

### Constraints

| Key | Type | Meaning |
| --- | --- | --- |
| `min_quality` | score `0–1` | quality signal floor |
| `min_modularity` | score `0–1` | modularity root-cause floor |
| `min_acyclicity` | score `0–1` | acyclicity root-cause floor |
| `min_depth` | score `0–1` | depth root-cause floor |
| `min_equality` | score `0–1` | equality root-cause floor |
| `min_redundancy` | score `0–1` | redundancy root-cause floor |
| `max_cycles` | unsigned int | allowed SCC cycles in the union graph |
| `max_file_lines` | unsigned int | largest allowed file |
| `max_fn_lines` | unsigned int | largest allowed function |
| `max_cyclomatic` | unsigned int | cyclomatic complexity ceiling, **per function** |
| `max_cognitive` | unsigned int | cognitive complexity ceiling, **per function** |

Every key is optional; a key that is absent is not checked, and `tdlearn check`
reports how many rules it actually evaluated — this repository's own config
below reports `tdlearn check — 9 rules checked`. Unknown keys, non-integer
values for `max_*`, and scores outside `[0, 1]` are rejected — a malformed
config can never make `check` pass.

`max_file_lines` and `max_fn_lines` compare against the **largest** file and
function in the tree, so they report one number and you look up the culprit in
`scan`'s `hotspots`. The two complexity ceilings are different on purpose: they
report **every** function over the line, each with its file, line and name, so
the output is a work list:

```
x [Error] max_cyclomatic: src/core/toml.zig:192: parseValue has cyclomatic complexity 31 > allowed 20
```

`scan` sorts its top-10 `hotspots` by cyclomatic first, so a function can be
invisible there while breaching a ceiling — which is why `check` is the place
that enforces them. There is no per-file or per-layer override for any ceiling;
if you need a higher one for a directory, the only lever today is the global
value.

### Layers and boundaries

```toml
[constraints]
min_quality = 0.7          # quality signal floor
min_modularity = 0.5       # per-root-cause floors (optional)
max_cycles = 0             # allowed dependency cycles
max_file_lines = 400       # largest allowed file
max_fn_lines = 80          # largest allowed function
max_cyclomatic = 20        # per-function ceilings, reported per function
max_cognitive = 45

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

### This repository's own rules

tdlearn dogfoods its rules through `.tdlearn/rules.toml`, and where it differs
from the example above the difference is deliberate and recorded both here and
inline in the file:

- **`max_file_lines = 1200`, not 400.** The largest implementation file is
  `src/main.zig` at 1152 lines. This ceiling used to be 1400 with a documented
  exception, because `src/core/rules.zig` still carried its own 388 lines of
  tests; those tests now live in `src/core/rules_test.zig`, and the CLI's in
  `src/main_test.zig`, so no file under `src/` mixes implementation and tests
  any more and the exception is gone.
- **`max_cyclomatic = 20` and `max_cognitive = 45`.** These hold down the tail
  that the `equality` root cause measures (a Gini over function complexity), so
  the score cannot quietly rot while the quality signal still looks fine. Eleven
  functions were over one ceiling or the other when the rules were added; each
  was split into named helpers rather than silenced by raising the value.
- `max_cycles = 0` is redundant with the acyclicity root cause on purpose.
  `gate` only fails on a cycle *increase* against the baseline, so a cycle
  regression introduced alongside an unrelated quality gain would slip through
  the gate; the explicit `max_cycles = 0` constraint is what catches it.

## Quality Gate — CI regression detection

```bash
tdlearn gate --save          # record baseline to .tdlearn/baseline.json
tdlearn gate                 # compare current state; exit 1 on regression
```

`--save` creates `.tdlearn/` if needed and writes the baseline atomically
(temp file + rename), so an interrupted save can never truncate a valid
baseline. `gate` without `--save` never writes — only `--save` does.

`gate` fails (exit 1) on any of these:

| Metric | Regression |
| --- | --- |
| `quality_signal` | drops by more than **0.02** (200 points on the 0–10000 display) |
| `cycle_count` | increases |
| `max_depth` | increases |
| `dead_functions` | increases |
| `duplicate_functions` | increases |

Improvements never fail the gate. The `0.02` tolerance is an absolute delta on
the `0–1` scale, not a percentage, and it is a flat constant rather than a
configurable setting.

`total_functions` is **recorded but not compared** — it only participates in
baseline validation (`dead_functions` and `duplicate_functions` must stay below
it). So adding or removing functions can never fail the gate on its own; the
other five metrics have to move for it to notice.

`baseline.json` carries `schema_version: 1` and is validated on read:
`quality_signal` must be finite and within `[0, 1]`, counters must be
self-consistent, and any other `schema_version` is rejected with
`UnsupportedBaselineSchema` rather than silently reinterpreted.

## JSON Output

`scan`, `check` and `gate` accept `--json` for machine-readable output on stdout:

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

`scan --json` includes `depth_path` with the longest dependency path and
`hotspots` with the ten most complex functions. JSON errors use the same schema
and an `ok: false` envelope with `error_info.code`, `category` and `message`.
`gate` adds the `baseline` and `current` metrics.

A `check` violation is a JSON object with:

| Field | Meaning |
| --- | --- |
| `rule` | the configuration key that was violated |
| `severity` | `Error` (fails the exit code) or `Warning` |
| `message` | the finding in one line, enough to act on without the other fields |
| `from` | the file the violation is about, or `null` for aggregate rules |
| `to` | the other end of an edge violation, or `null` when there is none |
| `subject` | the offending function name, or `null` for non-per-function rules |
| `line` | 1-based line of `subject`, for a CI annotation, or `null` |

Per-function complexity violations carry all three of `from`, `subject` and
`line`, so a consumer can group or annotate them without parsing `message`.

`hotspots[].score` is `cyclomatic × 1_000_000 + cognitive × 1_000 + lines` —
a lexicographic sort key, so it should be read as "cyclomatic first", not as
a magnitude. `depth_path` is the longest simple path that produced `max_depth`.

### Skipped files

Every result carries a `skipped_files` array (empty in the common case) so a
partial scan is visible instead of silently smaller:

```json
"skipped_files": [{ "path": "src/generated/big.zig", "reason": "parse_too_large" }]
```

Two limits produce entries, both configurable in `core/settings.zig`:

| Limit | Default | Reason | Effect |
| --- | --- | --- | --- |
| `max_file_size_kb` | 512 | `file_too_large` | The file is not even line-counted: no node, no lines, no edges. |
| `max_parse_size_kb` | 100 | `parse_too_large` | The file is walked and counted as a node, but its contents are not parsed, so it contributes no imports, functions or classes. |

Anything else — a missing file, a permission error, an out-of-memory
allocation — is **not** a skip. It aborts the run with a typed error, because a
scan that cannot read a file it was told to read has no honest quality score.

## Architecture

```
src/
├── core/           # types, path utils, settings, shared source lexer, TOML
│                   #   parser, rules, baseline
├── analysis/       # walker, language registry, import extraction + resolution,
│                   #   function/class extraction, call + inherit graphs
├── metrics/        # 5 root cause metrics, dead-code analysis, aggregation
├── main.zig        # CLI: scan / check / gate
└── *_test.zig      # tests, one per module that is big enough to want them out
```

Layering is enforced by `.tdlearn/rules.toml`: `core` is the most foundational
(order 3), `metrics` and `analysis` sit on it (order 2), and the CLI is on top
(order 0). A file may only import layers with an order greater than or equal to
its own.

Tests live in their own `*_test.zig` next to the module they cover
(`rules_test.zig`, `dead_code_test.zig`, `oom_test.zig`, `main_test.zig`), which
is what lets `max_file_lines` bound implementation instead of mixing it with
tests. `rules_test.zig` and `dead_code_test.zig` drive the module through its
public API only; `main_test.zig` imports `main.zig` to drive the pipeline's
internal steps, and `build.zig` roots that test artifact at the test file so the
dependency stays one way.

Function, class and import extraction share one `core/source_lexer.zig`, so
comments and string/template/raw literals are masked once, consistently, for
every language and every extractor.

## Testing

The verification commands below are exactly what CI runs, in the same order,
on Zig `0.16.0` across Linux, macOS and Windows:

```bash
zig fmt --check src build.zig build.zig.zon
zig build
zig build test
zig build -Doptimize=ReleaseSafe test
zig build run -- scan . --json
zig build run -- check . --json
zig build run -- gate . --json
```

`zig fmt --check` covers `build.zig.zon` too, since it is a Zig source file
that CI and contributors both edit.

CI runs the same matrix with Zig `0.16.0` on Linux, macOS and Windows. The
workflow only validates this repository: it publishes no releases and never
rewrites a baseline.

Line endings are owned by `.gitattributes` (`* text=auto eol=lf`, with the
binary types this project produces pinned to `-text`), so the checkout is
byte-identical on all three platforms and `zig fmt --check` never sees a
platform-dependent diff.

## Documentation

| Document | English | Español |
| --- | --- | --- |
| Project description, usage, rules, JSON | README.md (this file) | [README.es.md](README.es.md) |
| Outstanding work list, with links to the code | [TODO.md](TODO.md) | [TODO.es.md](TODO.es.md) |
| License | [LICENSE](LICENSE) | [LICENSE](LICENSE) (same file, not translated) |
| The rules this repository applies to itself | [`.tdlearn/rules.toml`](.tdlearn/rules.toml) (comments in English) | — |
| CI verification | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) (comments in English) | — |

This repository's rules for its own documentation:

- User documentation (`.md`) exists in English and in Spanish, and the two files
  are kept in parallel with the same information in both.
- Code, code comments, and the comments in `rules.toml` and the CI workflow are
  **in English**: it is the project's shared language, and duplicating them
  inside the code would make it harder to maintain, not easier.
- Every reference to a file or a section of this README is a relative link, so
  the reader can navigate from the documentation to the implementation.

## License

MIT — see [LICENSE](LICENSE).
