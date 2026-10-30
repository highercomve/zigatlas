# zigatlas

A `zig build atlas` step for any Zig project. It parses the sources with
`std.zig.Ast` and writes a map of the code (files, imports, types, functions,
calls), plus a list of places that look duplicated or break the architecture.
The output is written for LLM agents and reviewers to read quickly.

Comments steer it the way swag's comments steer Swagger output: annotations
in comments set layers and mute findings you have accepted.

## Output (`zig-out/atlas/`)

| file | what |
|---|---|
| `ATLAS.md` | Overview: stats, layer table, directory dependencies, findings (most severe first), hotspots |
| `api.md` | Every file with its doc line, public types (with fields) and public function signatures, by directory. Search it before writing a new helper |
| `atlas.json` | Everything: files, imports, functions (metrics, cross-file calls), types, findings |
| `deps.mmd` | Directory dependency graph (Mermaid), grouped by layer |
| `files.dot` | File import graph (Graphviz) |

## Findings

| kind | meaning |
|---|---|
| `duplicate_function` | Function bodies that are the same apart from local names, type names and literal values. The functions they call must match |
| `duplicate_fragment` | A long run of identical tokens (default 60), in different functions or far apart in one. Local names are ignored; field, method and called function names are kept. Runs with no control flow (tables, initializers) and the repeating rows of one if/else or switch chain are skipped |
| `duplicate_shape` | Structs with the same (or ≥80% the same) field names. Tuple structs are skipped |
| `parallel_implementation` | The same top-level function name in several files with similar bodies (≥50% of token pairs), where neither calls the other. Copies already reported as `duplicate_function` are not repeated |
| `layer_violation` | An import from a lower layer up into a higher one |
| `forbidden_import` | An import an explicit rule forbids (e.g. skipping a layer) |
| `import_cycle` | Files that import each other in a loop, or directories whose loop includes an import that goes up a layer (or leaves the layers) |
| `thick_frontend` | A function in a `thin` layer that branches a lot (complexity above 10) and calls into a lower layer other than the lowest one (the lowest holds helpers). Calls through import aliases, local imports and typed parameters (`svc: *core.Service`) count. Pure parsing is not reported |
| `long_function`, `complex_function`, `many_params`, `large_file` | Hotspots over the thresholds. Generic types (`fn List(T) type { return struct {...} }`) are measured as types: their methods one by one |
| `unused_pub` | A public function whose name appears nowhere else in the project. Every `.zig` file under the build root counts (tests, tools), not only the roots. `export`/`extern` functions, module roots and std hook names (`format`, `jsonStringify`, `hash`, `eql`, …) are skipped |
| `parse_error` | A file that doesn't parse, at the first error's line |
| `unknown_layer` | An `@atlas layer` annotation naming a layer the configuration doesn't have |

## Use it in a project

Add the dependency (this writes the URL and hash into `build.zig.zon`):

```sh
zig fetch --save git+https://github.com/highercomve/zigatlas
```

Or, while working on zigatlas next to your project:

```zig
.dependencies = .{
    .zigatlas = .{ .path = "../zigatlas" },
},
```

`build.zig`:

```zig
const zigatlas = @import("zigatlas");

pub fn build(b: *std.Build) void {
    // ...
    _ = zigatlas.addAtlasStep(b, .{
        .roots = &.{ "src" },
        // Top (front ends) to bottom (foundations). A layer may import
        // itself and the layers below it.
        .layers = &.{
            .{ .name = "cli", .paths = &.{"src/main.zig"}, .thin = true },
            .{ .name = "fs", .paths = &.{"src/fs"} },
            .{ .name = "cluster", .paths = &.{"src/cluster"} },
            .{ .name = "net", .paths = &.{"src/net"} },
        },
        .forbid = &.{
            .{ .from = "fs", .to = "net", .reason = "fs reaches the network through cluster" },
        },
    });
}
```

Call `addAtlasStep` at the end of `build()`: it reads the `@import` names
from the modules and compile steps defined so far. Then:

```sh
zig build atlas               # write zig-out/atlas
zig build atlas -- --check    # also fail when error findings exist (CI gate)
zig build atlas -- --check warn
```

`@import` names are taken from the build graph: public modules
(`b.addModule`) everywhere, and each module's imports (`addImport`, on
`createModule` modules and compile steps too) inside that module's directory.
Add others with `Options.modules`. See `Options` in `build.zig` for the
thresholds. Paths can be written as `src`, `./src/` or absolute; `.roots =
&.{"."}` scans the whole project.

`--check` prints each failing finding as `file:line: severity: kind: message`.
Exit codes: 0 done, 1 `--check` failed, 2 bad arguments, a root that can't be
opened, or no `.zig` files.

`atlas.json` carries `"schema": 1` and the layers it checked; fields are only
added, and the schema number goes up when one changes.

## Annotations

```zig
//! @atlas layer: storage        file header: put this file in a layer (overrides paths)

// @atlas allow: C ABI exports live here
const mobile_api = @import("mobile/api.zig");   // mutes findings on this import

/// @atlas allow: called from the webview by name
pub const Commands = struct { ... };            // mutes the type and everything in it
```

`@atlas allow` goes on the line of the declaration or import, or in the comment
block directly above it. In the `//!` header it mutes the file's `large_file`
finding. Parse errors can't be muted.

## Run it directly

```sh
zig build
zig-out/bin/zigatlas --root src --layer fs=src/fs --layer net=src/net --out /tmp/atlas
zig-out/bin/zigatlas --help
```

## Limits

It reads syntax, not semantic analysis. Calls are resolved through import
aliases (`alias.fn(`, `alias.Type.fn(`), the re-exports behind them, local
imports and parameters typed `alias.Type`; method calls on other values
(`self.store.get()`) are not followed. `unused_pub` only counts names, so
functions called by reflection need an `@atlas allow`, and a function with a
common name (`get`, `init`) is never reported. Files nested more than 200
levels deep are reported, not parsed. Requires Zig 0.16 (it parses with 0.16's
parser, so removed syntax such as `usingnamespace` shows as a parse error).

## Develop

```sh
zig build test          # unit tests
zig build atlas         # zigatlas maps itself (layers in build.zig)
zig fmt --check src build.zig
```

Reviews follow `.agents/skills/review/SKILL.md` (also linked as a Claude Code
skill in `.claude/skills/review`). It reviews in four lenses: Zig correctness,
memory and resources, Power of 10, and the tool's design. That last lens covers
the scan → analysis → render pipeline, the `build.zig` API other projects call,
and how far each finding kind can be trusted. Reviews are written to
`.agents/review/<scope>/review.md`.
