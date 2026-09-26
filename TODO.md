# TODO — tdlearn

**Languages / Idiomas:** **English** (this file) · [Español](TODO.es.md)

> Translation of `TODO.es.md`. The two files are kept in parallel: if you close
> or open an item, update both, or the list stops being useful as project state.

Current state: partial implementation. The build and the main suite already
pass; robustness, contracts and distribution work remain.

Last audit: 2026-09-26

The project's reference document is [README.md](README.md) (or
[README.es.md](README.es.md) in Spanish). Every "References:" line below links to
the source file it talks about, and the rules this repository applies to itself
live in [`.tdlearn/rules.toml`](.tdlearn/rules.toml).

## Definition of done

- [x] `zig build`, `zig build test` and `zig build -Doptimize=ReleaseSafe test` exit with code 0.
- [x] `zig fmt --check` exits with code 0.
- [ ] `scan`, `check` and `gate` have stable argument, stream and exit-code contracts.
- [ ] A non-existent path, a permission error or an invalid configuration produce an explicit error, never an artificially perfect score.
- [ ] The scan is deterministic, distinguishes source files from skipped ones and reports I/O diagnostics.
- [ ] The metrics have a documented semantics and tests for cycles, disconnected components, missing data and false positives.
- [ ] There are integration tests for the whole pipeline and for the CLI.
- [x] README, license, packaging and CI reflect real behaviour, in English and in Spanish.
- [ ] Releases are published reproducibly (see [CI-001](#p2--tests-performance-and-delivery)).

Priorities:

- **P0**: blocks compiling, running, or avoiding seriously wrong results.
- **P1**: needed for the analysis and the public contracts to be reliable.
- **P2**: robustness, maintainability, performance and distribution.

## P0 — blockers

### [x] BUILD-001 — Restore compilation of the modules

- References: [src/analysis/manifests.zig](src/analysis/manifests.zig), [src/analysis/resolver.zig](src/analysis/resolver.zig), [build.zig](build.zig) (`createModule`, `addTestStep`).
- [x] Resolve the ownership conflict in `src/core/toml.zig`; modules must not import the same file through cross relative paths.
- [x] Implement `expandAlias` or remove the incomplete call.
- [x] Fix the resolver formatting.
- [x] Keep the pre-existing local changes in `resolver.zig` and `manifests.zig` explicitly, without discarding them by accident.
- [x] Verify that `zig build` and `zig build test` compile every module.

### [x] BUILD-002 — Complete the integration of manifests and aliases

- References: [src/analysis/manifests.zig](src/analysis/manifests.zig) (`readPackageAliasesAtRoot`), [src/analysis/graph_builder.zig](src/analysis/graph_builder.zig) (`buildImportEdgesAtRootWithContents`), [src/analysis/resolver.zig](src/analysis/resolver.zig) (`initWithAliases`).
- [x] Read manifests once during the analysis.
- [x] Pass the aliases to `Resolver.initWithAliases`.
- [x] Resolve Cargo/workspace aliases and npm package subpaths.
- [x] Keep hyphenated npm names and record Rust normalizations separately.
- [x] Resolve `@scope/package`, `main` and `index` correctly.
- [x] Add tests for valid aliases, conflicts, roots outside the scan and malformed manifests.

### [ ] IO-001 — Make filesystem errors stop producing false successes

- References: [src/main.zig](src/main.zig) (`validateRoot`, `readFile`, `readOptionalFile`), [src/analysis/walker.zig](src/analysis/walker.zig) (`Walker.walk`, `Walker.appendFileNode`).
- [x] Validate that the root path exists, is a directory and is readable before starting.
- [x] Distinguish `NotFound`, permissions, read errors, oversized files, invalid UTF-8 and `OutOfMemory`: `readFile`/`readOptionalFile` (in `src/main.zig`) and `readSmallFile` (in [src/analysis/manifests.zig](src/analysis/manifests.zig)) return `error.FileNotFound` and the other typed errors, never `null`.
- [x] Stop turning OOM or read errors into "file absent": `Resolver.resolve` is `!?[]const u8` and `FunctionExtractor`/`ImportExtractor` propagate `error.OutOfMemory`; there are `FailingAllocator` tests in [src/analysis/oom_test.zig](src/analysis/oom_test.zig) and [src/metrics/equality.zig](src/metrics/equality.zig).
- [ ] Define an explicit policy for partial scans; add `--allow-partial` only if it turns out to be necessary.
- [x] Report scanned, skipped and failed files with their reason: `skipped_files` in the JSON and in the text output, with `file_too_large` (walker) and `parse_too_large` (content); an unreadable file aborts the scan with a typed error instead of disappearing from the count.
- [ ] Add integration tests for non-existent, unreadable and corrupt paths.

### [ ] CLI-001 — Make the argument contract strict

- References: [src/main.zig](src/main.zig) (`parseOptions`, `printUsage`).
- [x] Reject a missing command, unknown flags, repeated flags and extra arguments.
- [x] Validate that `--save` is only valid for `gate` and that flag combinations are coherent.
- [x] Support `--` and a single positional path.
- [x] Define exit codes: success, violation/gate failure, and usage/configuration/I/O error.
- [x] Send help/version to stdout and errors to stderr.
- [ ] Add a test matrix for every command, flag and invalid combination.

### [ ] CONFIG-001 — Make the rules parser strict and safe

- References: [src/core/toml.zig](src/core/toml.zig) (`parseValue`, `parse`), [src/core/rules.zig](src/core/rules.zig) (`parseRules`, `validateTomlSyntax`).
- [ ] Report errors with line and column instead of ignoring lines or unknown keys.
- [x] Reject duplicate keys, empty values, unclosed quotes, arrays and malformed sections.
- [ ] Validate unsupported escapes and report line/column.
- [x] Reject wrong types and out-of-range integers without truncation.
- [x] Validate finite scores within `[0, 1]`.
- [x] Require the mandatory fields of layers and boundaries.
- [ ] Add tests for malformed configurations and guarantee that no invalid configuration makes `check` pass.

## P1 — reliable analysis and metrics

### [ ] ANALYSIS-001 — Separate source files from walked files

- References: [src/analysis/walker.zig](src/analysis/walker.zig) (`walk`, `walkDir`, `flattenFiles`), [src/analysis/lang_registry.zig](src/analysis/lang_registry.zig), [src/main.zig](src/main.zig) (`filterSourcePaths`, `collectSourceNodes`).
- [x] Define the exact set of files that takes part in each metric.
- [x] Stop counting README, JSON, binaries or unknown extensions as structural nodes by accident.
- [x] Define the treatment of empty files, binaries, symlinks and large files.
- [x] Make graphs, `file_count`, lines and Gini use the same data universe.
- [ ] Add end-to-end fixtures with non-source files.

### [x] ANALYSIS-002 — Fix Python function extraction

- References: [src/analysis/functions.zig](src/analysis/functions.zig) (`detectDecl`, `findBodyEnd`).
- [x] Compute `start_line`, `end_line` and `line_count` through indentation and the following declarations.
- [x] Detect methods correctly and keep their scope.
- [x] Avoid overlaps between consecutive functions and support nested defs, docstrings and one-line functions.
- [x] Verify that calls, duplicates and `max_fn_lines` receive the right body.

### [ ] ANALYSIS-003 — Complete the import extractors

- References: [src/analysis/imports.zig](src/analysis/imports.zig).
- [x] Filter comments, strings and template literals before extracting dependencies.
- [x] Support single/double quotes, aliases and `import()`/`require()`.
- [x] Support grouped Python imports and the common multiline JS form.
- [ ] Complete the multiline forms of Python/JS and more complex blocks.
- [x] Resolve Python relative imports, Rust `self`/`super` and Rust/Go variants correctly: `resolveDotRelative` (`.helpers`, `..pkg.mod`), `resolveRustRelative` (`self::`, `super::`) and `normalizeSeparators` (`crate::`, `a::b`) have positive and negative tests.
- [x] Do not read balanced strings as imports outside a valid block.
- [x] Add per-language fixtures with positive and negative cases.

### [ ] ANALYSIS-004 — Complete multi-language module resolution

- References: [src/analysis/resolver.zig](src/analysis/resolver.zig), [src/analysis/graph_builder.zig](src/analysis/graph_builder.zig).
- [x] Add the extensions the registry supports, such as `.mjs`, `.mts`, `.hpp`, `.cc`, `.cxx`, `.hxx`, `.m` and `.mm`.
- [x] Resolve nested relative paths and `self::`/`super::`.
- [x] Stop ambiguous suffixes from resolving to whichever file the filesystem returned first.
- [x] Raise the buffer for long paths and test nested paths.
- [x] Test Unicode and native separators.
- [ ] Test path traversal and normalization.
- [x] Make the result independent of traversal order.
- [x] Propagate `error.OutOfMemory` instead of reporting "unresolved" (`resolve` is `!?[]const u8`, with a test in [src/analysis/oom_test.zig](src/analysis/oom_test.zig)).

### [ ] ANALYSIS-005 — Complete functions, classes and inheritance

- References: [src/analysis/functions.zig](src/analysis/functions.zig), [src/analysis/classes.zig](src/analysis/classes.zig), [src/analysis/inherit_graph.zig](src/analysis/inherit_graph.zig).
- [ ] Support arrow functions, methods, modifiers, generics, multiline declarations and the relevant C++ constructors. Modifiers, generics and C++ namespaces are already covered; arrow functions and multiline declarations are missing.
- [ ] Detect `export default class`, TypeScript interfaces/type aliases, Rust traits/impls and Go embedding. `export default class`, Rust `traits`/`impl` and qualified namespaces are already covered; TS `interface`/`type` and Go struct embedding are missing.
- [x] Resolve qualified bases, namespaces, C++ headers and ambiguities between packages: `leafName` reduces `ns::Base` to `Base`, with tests for qualified bases, namespaces and templates.
- [ ] Fix the inheritance fallback so it is only used when there is no imported base.
- [x] Add tests for scope, overlaps and ambiguous relations.
- [x] Count braces over lexer-sanitized code, including Zig multiline (`\\`) strings, so a brace inside a literal never truncates a function body.

### [ ] GRAPH-001 — Make the call graph conservative

- References: [src/analysis/call_graph.zig](src/analysis/call_graph.zig) (`buildCallEdgesWithLimit`, `scanLine`).
- [x] Ignore comments, strings and inline declarations correctly (the scanner used to count every call inside a `//` or `/* */` comment).
- [ ] Resolve calls by symbol, import, receiver and visibility; not only by global name.
- [ ] Handle `obj.run()`, `obj->run()`, methods, aliases and dispatch without inventing edges.
- [ ] Leave unresolvable calls as ambiguous rather than as invented edges.
- [ ] Cover private functions, duplicate names, comments and strings with negative tests.

### [x] METRIC-001 — Define and fix depth

- References: [src/metrics/depth.zig](src/metrics/depth.zig), [src/metrics/mod.zig](src/metrics/mod.zig) (`computeHealth`).
- [x] Decide whether the metric means longest path or shortest distance.
- [x] Make the policy for cycles, unreachable nodes and disconnected components explicit.
- [x] Remove the fixed 32-entry-point limit or document and test it.
- [x] Add tests with paths of different length, jumps, cycles, multiple roots and files with no entry point.

### [x] METRIC-002 — Align equality with declared complexity

- References: [src/analysis/functions.zig](src/analysis/functions.zig) (`computeComplexity`), [src/core/types.zig](src/core/types.zig) (`FuncInfo`), [src/metrics/equality.zig](src/metrics/equality.zig) (`giniCoefficient`, `computeFunctionComplexityGini`).
- [x] Implement cyclomatic/cognitive complexity or rename the metric to file-size equality.
- [x] Populate the complexity fields or delete the ones that cannot be computed.
- [x] Add tests showing that branches, and not only lines, affect the result where applicable.

### [x] METRIC-003 — Fix redundancy, dead code and duplicates

- References: [src/metrics/dead_code.zig](src/metrics/dead_code.zig) (`analyze`, `propagateReachability`, `collectDuplicateFlags`), [src/metrics/dead_code_test.zig](src/metrics/dead_code_test.zig).
- [x] Resolve calls by symbol and reach from entry points/public API.
- [x] Stop treating any path containing the string `test` as a test.
- [x] Remove the 64-declaration limit and validate the exclusions.
- [x] Compare normalized bodies with a secondary check to avoid hash collisions.
- [x] Handle comments, strings, large bodies, nested functions and overlaps.
- [x] Stop rewarding missing data as if it were zero redundancy; define a policy for projects with no functions.

### [x] METRIC-004 — Validate cycles and modularity edges

- References: [src/metrics/acyclicity.zig](src/metrics/acyclicity.zig), [src/metrics/modularity.zig](src/metrics/modularity.zig), [src/metrics/mod.zig](src/metrics/mod.zig) (`computeHealth`).
- [x] Decide and test whether self-loops count as cycles.
- [x] Define whether acyclicity uses imports or the union of import, call and inherit edges.
- [x] Reject or account for edges with unknown endpoints.
- [x] Document the partition used by Newman and the behaviour of multigraphs, duplicates and the empty graph.
- [x] Make the metrics deterministic and free of file-order bias.

### [ ] METRIC-005 — Decide whether test files belong to the import graph

- References: [src/metrics/depth.zig](src/metrics/depth.zig), [src/metrics/modularity.zig](src/metrics/modularity.zig), [src/metrics/dead_code.zig](src/metrics/dead_code.zig) (`isTestPath`).
- [ ] `depth` and `modularity` count test files as nodes and their edges as dependencies, but `dead_code` already excludes them from production. Today `main_test.zig` appears in `depth_path`, which raises `max_depth` from 7 to 8 purely because it exists.
- [ ] Decide on a single policy: either test files do not enter the structural graph (and it is documented), or they do and an artificially high depth is accepted for a tree with many tests.
- [ ] If one is chosen, the change is in `filterSourcePaths`/`computeHealth` and must be accompanied by a note in the README, because it changes the numbers for every user.

## P1 — configuration, CLI and persistence

### [x] RULES-001 — Complete rule and glob semantics

- References: [src/core/rules.zig](src/core/rules.zig) (`globMatch`, `validatePattern`, `checkRules`), tests in [src/core/rules_test.zig](src/core/rules_test.zig).
- [x] Validate names, paths, orders and ambiguous overlaps between layers.
- [x] Implement a documented glob grammar for `*`, `**` and separators.
- [x] Support escapes and define Unicode/Windows behaviour.
- [x] Separate absolute paths from paths relative to the root.
- [x] Deduplicate violations and make their order stable.
- [x] Add tests for conflicting patterns, `**` and segment boundaries.

### [x] RULES-002 — Per-function complexity ceilings

- References: [src/core/rules.zig](src/core/rules.zig) (`Constraints.max_cyclomatic`/`max_cognitive`, `checkComplexityCeiling`, `ComplexityKind`), [src/main.zig](src/main.zig) (`Analysis.functions`, `JsonViolation`), [src/core/types.zig](src/core/types.zig) (`FileFuncs.lang`), [`.tdlearn/rules.toml`](.tdlearn/rules.toml).
- [x] Add `max_cyclomatic` and `max_cognitive` to the schema, with validation (integer, non-negative, no overflow) and rejection of unknown keys.
- [x] Report **every** function over the line, with file, line, name and measured value, ordered by file and then by line; unlike `max_fn_lines`, which only reports the largest.
- [x] Expose `subject` and `line` on the violation (JSON and text) so a consumer can group or annotate without parsing the message, and fix `from`, which used to be `null` for single-file violations.
- [x] Count rules, not findings: `rules_checked` goes up by one per configured ceiling, not per violation.
- [x] Fix the deduplication: it compared only rule and files, which would have collapsed two different functions of the same file; it now compares the message and the subject too.
- [x] Validate function paths with the same `validateInputPath` as every other input (a test found that hole).
- [x] Refactor the eleven functions the new ceilings flagged, instead of raising them: `call_graph.appendResolvedEdges` (cognitive 81), `toml.parseValue` (31), `source_lexer.sanitizeLine` (26), `inherit_graph.appendResolvedEdges` (52), `rules.checkConstraintRules`, `dead_code.markLocalTargets`, `functions.detectCFn`, `functions.countParameters`, `rules.validatePattern`, `rules.validateTomlSyntax`.
- [x] Verify both ceilings fail a real `check` (exit 1) with a deliberately complex function.
- Useful side effect: refactoring `call_graph.scanLine` fixed a real bug — it ignored comments, so every call inside a `//` or `/* */` became an edge — and moved it onto the shared lexer.

### [x] CORE-001 — Normalize paths and define portability

- References: [src/core/path_utils.zig](src/core/path_utils.zig) (`canonicalRelative`, `isPackageIndexPath`), [src/analysis/walker.zig](src/analysis/walker.zig) (`normalizePaths`), [src/analysis/resolver.zig](src/analysis/resolver.zig) (`normalizeSeparators`).
- [x] Use the correct basename/extension.
- [x] Separate filesystem paths from canonical paths.
- [x] Make edges and rule paths relative.
- [x] Define symlinks, junctions, dotfiles, case sensitivity, UNC and dotted paths.
- [x] Implement or fix the `mod.rs` and entry-point conventions.
- [x] Add portable tests for Unicode, traversal and separators; the multi-OS run is in TEST-001.

### [x] JSON-001 — Version and stabilize the JSON output

- References: [src/main.zig](src/main.zig) (`JsonScan`, `JsonCheck`, `JsonGate`, `makeJsonScan`, `printHumanScan`), README ("JSON Output"), tests in [src/main_test.zig](src/main_test.zig).
- [x] Add `schema_version` and a tool version.
- [x] Add root and units.
- [x] Include the associated file, rule, severity, `from` and `to` where they exist.
- [x] Include previous/new metrics where they exist.
- [x] Define a single envelope for usage, configuration, I/O and baseline errors.
- [x] Emit JSON for `gate --save --json`.
- [x] Emit JSON for configuration failures.
- [x] Add golden tests and ensure a successful JSON run writes no diagnostics to stdout.

### [ ] BASELINE-001 — Make the baseline and its persistence robust

- References: [src/core/baseline.zig](src/core/baseline.zig) (`readBaseline`, `Baseline.validate`), [src/main.zig](src/main.zig) (`saveGate`, `compareGate`).
- [x] Add a schema version and compatibility with the existing format.
- [x] Validate finite scores within `[0, 1]`.
- [x] Validate counters and tolerances; define the semantics of `total_functions`.
- [x] Write through a temporary file and an atomic rename, without truncating a valid baseline.
- [x] Handle an absent, truncated, corrupt or future-version baseline and a failed write.
- [x] Update `.tdlearn/baseline.json` only after the analysis and its tests are stable.

### [ ] CORE-002 — Integrate configuration, ownership and typed errors

- References: [src/core/settings.zig](src/core/settings.zig), [src/core/rules.zig](src/core/rules.zig) (`parseRules`).
- [x] Integrate `Settings` or retire the fields that have no effect: `Settings` went from 244 to 88 lines and `core/types.zig` from 280 to 179; the fields with no consumer (and the `snapshot.zig`/`heat.zig` modules) were deleted instead of being left as dead code.
- [ ] Unify the size limits, exclusions and thresholds across the walker and the parser: there are three numbers written in two files — `max_file_size_kb = 512` (walker), `max_parse_size_kb = 100` (pipeline) and the 2 MiB hard backstop in `main.readFile`; all three are intentional, but none shares a constant and `readFile` does not receive the pipeline's limit.
- [x] Add explicit `deinit`/ownership and `errdefer` for partial results: the `dead_code.zig` rewrite frees flags, indices and `local_calls` with `defer`/`errdefer`, and `readFile` frees its buffer with `errdefer`.
- [x] Check the allocator state and propagate domain errors with context: no `catch return null` or `catch continue` left on error paths in `src/analysis` and `src/metrics`.
- [x] Add tests with `FailingAllocator` and the errors of each public API ([src/analysis/oom_test.zig](src/analysis/oom_test.zig), [src/metrics/equality.zig](src/metrics/equality.zig)).

## P2 — tests, performance and delivery

### [ ] TEST-001 — Create end-to-end integration tests

- References: [build.zig](build.zig) (`addTestStep`), [src/main_test.zig](src/main_test.zig) (`parseOptions`, `runScan`, `runCheck`, `runGate`).
- [x] Cover the `Walker → GraphBuilder → extractors → graphs → computeHealth` pipeline.
- [x] Test `scan`, `check`, `gate` and `gate --save` on temporary projects.
- [ ] Cover stdout, stderr, JSON, exit codes, invalid paths, large files, Unicode and symlinks.
- [ ] Run Debug and ReleaseSafe on Linux, macOS and Windows.
- [ ] Add benchmarks for large repositories and verify there is no quadratic growth.

### [x] TEST-002 — Complete the language matrix

- References: [src/analysis/functions.zig](src/analysis/functions.zig), [src/analysis/classes.zig](src/analysis/classes.zig), [src/analysis/imports.zig](src/analysis/imports.zig).
- [x] Keep fixtures for Zig, Rust, Python, JavaScript/TypeScript, Go and C/C++.
- [x] Add cases for comments, strings, grouped/multiline imports, aliases, methods, generics and macros.
- [x] Run positive and negative tests to avoid invented edges, functions or cycles.
- [x] Explicitly document any construct the line-based parser does not support.

### [ ] PERF-001 — Remove limits and bottlenecks

- References: [src/metrics/mod.zig](src/metrics/mod.zig) (`computeEquality`), [src/analysis/call_graph.zig](src/analysis/call_graph.zig) (`buildCallEdgesWithLimit`), [src/analysis/walker.zig](src/analysis/walker.zig) (`countLines`, `appendFileNode`).
- [x] Index each file once and avoid reading it again.
- [x] Replace O(E²) deduplication with hash sets.
- [ ] Remove the remaining arbitrary limits on entry points, statements and sizes, or make them configurable and safe.
- [x] Protect indices and counts against overflow and invalid input.

### [ ] CLEANUP-001 — Connect or retire incomplete APIs

- References: [src/metrics/mod.zig](src/metrics/mod.zig), [src/metrics/dead_code.zig](src/metrics/dead_code.zig), [src/core/settings.zig](src/core/settings.zig), [src/core/types.zig](src/core/types.zig).
- [x] Integrate `Snapshot`, `HeatTracker` and the metric modules or retire their public API: `snapshot.zig`, `heat.zig` and `redundancy.zig` were deleted (they had no consumer and their tests were not even running); redundancy is computed by `dead_code.analyze`.
- [x] Remove duplicate helpers, dead state and unused score calculations: no orphans, verified by walking `src/**/*.zig` against each module's imports.
- [ ] Document ownership, invariants and thread-safety of the public APIs.
- [ ] Add smoke tests for the installed `tdlearn-core` package.

### [ ] CLEANUP-002 — Make the reported duplicates actionable

- References: [src/metrics/dead_code.zig](src/metrics/dead_code.zig) (`collectDuplicateFlags`), the `scan` output in [src/main.zig](src/main.zig).
- [ ] `scan` only prints `duplicated: 5`; it does not say which functions or where they are, so the number is not actionable without instrumenting the code.
- [ ] Expose the duplicate groups (members, path, line and body size) in the text and JSON output, next to the count.
- [ ] Keep the JSON stable: it is an additive field, and `gate`/`check` must not start comparing the list.

### [ ] CI-001 — Automate verification and releases

- References: [.github/workflows/ci.yml](.github/workflows/ci.yml), [build.zig](build.zig) (`addRunCommand`).
- [x] Add a workflow for `zig fmt --check`, `zig build`, `zig build test` and ReleaseSafe.
- [x] Run `tdlearn check .` and `tdlearn gate .` against a stable baseline.
- [x] Include `build.zig.zon` in CI's `zig fmt --check` and in the README's list.
- [x] Add per-ref `concurrency` with `cancel-in-progress` to avoid accumulating obsolete runs.
- [x] Limit `push` to `main` and ignore tags, with the avoided cost documented inline in the workflow.
- [x] Delegate line endings to `.gitattributes` (`* text=auto eol=lf` plus pinned binaries).
- [ ] Validate against a supported stable Zig version and the target OS matrix.
- [ ] Publish artifacts, checksums and release tags reproducibly.
- [ ] Re-enable the tag run once a release workflow exists; today a tag push only repeats the 3-OS matrix.

### [ ] DOC-001 — Align documentation and packaging

- References: [README.md](README.md), [README.es.md](README.es.md), [TODO.md](TODO.md), [TODO.es.md](TODO.es.md), [build.zig.zon](build.zig.zon), [LICENSE](LICENSE), [.gitattributes](.gitattributes).
- [x] Document installation, `zig build run --`, supported paths, limits and parser limitations.
- [x] Fix the JSON example so it is valid JSON.
- [x] Add the `LICENSE` file the README links to.
- [x] Declare `README.md`, `README.es.md`, `TODO.md`, `TODO.es.md` and `LICENSE` in `paths` of [build.zig.zon](build.zig.zon).
- [x] Keep every document in English and Spanish in parallel, with a language switcher, links between the documents and links from each document to the code it describes.
- [x] Keep code, code comments, `rules.toml` comments and CI comments in English, and say so in both READMEs.
- [ ] Derive the version from a single source (`tool_version` in [src/main.zig](src/main.zig) and `.version` in [build.zig.zon](build.zig.zon) are still duplicated).
- [x] Fix `paths` entries that reference non-existent directories.
- [x] Document the TOML, JSON and baseline schemas, compatibility and the migration policy.
- [x] Document the quality scale: `0–1` in config and baseline, `0–10000` in the output, and why they differ.
- [x] Document the quality signal scale: geometric mean, the 0.01 floor and the 3981/10000 ceiling.
- [x] Document the exit codes 0/1/2 and the `error_info` envelope of `--json`.
- [x] Document what `gate` compares, with what tolerance, and that `total_functions` is not compared.
- [x] Refresh the output example with real numbers from the repository, labelled as a snapshot.

### [ ] QA-001 — Close the project's own controls

- References: [.tdlearn/rules.toml](.tdlearn/rules.toml), [.tdlearn/baseline.json](.tdlearn/baseline.json).
- [x] Make `tdlearn check .` pass without disabling relevant limits.
- [x] Resolve or justify the current file/function size violations.
- [x] Verify that `tdlearn gate .` only fails on real regressions.
- [x] Add `max_cycles = 0` so a cycle regression is not hidden by a quality gain.
- [x] Add `max_cyclomatic = 20` and `max_cognitive = 45` so the complexity tail — the one `equality` measures — cannot rot in silence (see RULES-002).
- [x] Regenerate `.tdlearn/baseline.json` once the changes that produce it are committed. `total_functions` does not take part in the gate ([src/core/baseline.zig](src/core/baseline.zig), `Baseline.compare`).
- [ ] Pin the GitHub Actions by SHA, so a moved upstream tag cannot change what CI runs.

### [x] QA-002 — Split `src/core/rules.zig` and lower `max_file_lines`

- References: [src/core/rules.zig](src/core/rules.zig) (1091 lines), [src/core/rules_test.zig](src/core/rules_test.zig) (608), [src/main.zig](src/main.zig) (1152), [src/main_test.zig](src/main_test.zig) (383), [`.tdlearn/rules.toml`](.tdlearn/rules.toml) (`max_file_lines = 1200`), README ("This repository's own rules").
- [x] Document the `max_file_lines = 1400` exception in `rules.toml` and in the README, instead of raising the limit silently.
- [x] Move the 388 lines of tests out of `rules.zig` into [src/core/rules_test.zig](src/core/rules_test.zig), which uses nothing but the public API (`parseRules`, `checkRules`, `globMatch`): that also proves the public surface is enough to configure and check a project. `rules.zig` drops to 1091 lines.
- [x] Move the CLI's tests to [src/main_test.zig](src/main_test.zig) and root the test artifact at that file ([build.zig](build.zig), `addTestStep`), so the dependency is one way (tests → implementation) and no file mixes implementation with tests.
- [x] Lower `max_file_lines` from 1400 to 1200 (the largest file is `main.zig` at 1152) and drop the documented exception: it no longer applies because no file under `src/` carries its tests inside.
- Note: adding `main_test.zig` to the graph took `max_depth` from 7 to 8 and the signal down by ~100 points. That is depth measuring what it claims to measure; see METRIC-005.
