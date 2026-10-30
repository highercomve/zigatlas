# zigatlas review: whole project (v0.1.0, 46c1751)

**Verdict: approve with changes.** Before tagging v0.1.0 or pointing nomadfs at
the URL, fix the critical finding (atlas.json strings become integer arrays) and
the first three high ones. Those three are path normalisation, module
detection, and generic types; each makes real projects lose layer checks or get
wrong hotspots without any warning. The pipeline layering is sound, output is
deterministic, every handle is closed, and nothing crashes on ordinary code.

Scope: `src/*.zig`, `build.zig`, README.md. The review followed
`.agents/skills/review/SKILL.md` with one reviewer per lens. Their full reports,
each with "checked and sound" and "not covered", are next to this file:
`lens-a.md` (Zig correctness), `lens-b.md` (memory and resources, with
measurements), `lens-c.md` (Power of 10) and `lens-d.md` (design, build API,
trust in findings). Every finding was proven by running the tool on a fixture,
on a consumer project, or on nomadfs. I reproduced the critical finding, the
`--root .` finding and the overlapping-roots finding myself.

Checks: `zig build test` 7/7 (Debug and ReleaseSafe), `zig fmt --check` clean,
two runs give byte-identical output. Self-atlas: 0 errors, 1 warning
(`thick_frontend` on `main`, a false positive, see below), 8 notes.
Performance (ReleaseSafe): nomadfs 33k lines in 0.05 s / 40 MiB; Zig std 434k
lines in 0.60 s / 430 MiB.

---

### [critical] Strings cut mid-character, or non-UTF-8 source, become integer arrays in atlas.json (A)
- Where: src/scan.zig:520 (`collapse` caps at a byte count), :400, :412 (doc text taken raw); src/render.zig:16
- What goes wrong: `/// a` followed by 100 `é` above a function gives
  `"doc": [97, 195, 169, …]`, because the 160-byte cap splits a two-byte
  character and `std.json` writes invalid UTF-8 as a byte array. Signatures
  (200-byte cap) and field types (80) behave the same, as does a non-UTF-8
  comment. Every tool reading the schema breaks, and api.md is invalid UTF-8.
- Fix: back up to a UTF-8 boundary in `collapse`, and pass every output string
  through one helper that replaces invalid bytes (`std.unicode.utf8ValidateSlice`).

### [high] `--root .`, an absolute root, or a missing root silently switches checking off (A, D)
- Where: src/main.zig:106 (file path = `root/entry`, not normalised), src/config.zig:188 (`trimSlash`), src/scan.zig:229 (`resolvePosix` normalises imports), src/main.zig:92-95
- What goes wrong: with `--root .` files are `./fs/s.zig` but imports resolve
  to `net/p.zig`, so no import resolves and no layer matches. A forbidden import
  gives 1 error with `--root fs --root net` and 0 with `--root .`. `--root ./`
  trims to `""` and scans nothing; an absolute root never matches relative
  layer paths; a misspelt root exits 0 even with `--check`. `--module x=./a.zig`
  never resolves either: path cleanup is done in four places that disagree.
- Fix: one path normaliser in config.zig (relative to the cwd, no `./`, `.`
  collapsed, `/` separators) for roots, walked files, layers, excludes, forbid
  rules and modules. A root that can't be opened, or a run with 0 files, exits 2.

### [high] Modules made with `createModule` or imported under another name aren't resolved (D)
- Where: build.zig:99-104 (only `b.modules`), src/scan.zig:222-231
- What goes wrong: an executable's module wired with `createModule` +
  `addImport("core", core)` (the usual pattern; nomadfs does it) leaves
  `@import("core")` and `@import("app")` unresolved, so an upward import between
  them reports 0 errors.
- Fix: walk the build graph: `b.modules` plus each compile step's root module,
  and emit `--module NAME=PATH` from every module's `import_table` entry whose
  root file belongs to `b`. Add `Options.modules` for manual cases.

### [high] Generic types (`fn T(comptime …) type { return struct {…} }`) are one giant function and their API is lost (A, D, B)
- Where: src/scan.zig:134-191 (only `var_decl` containers are walked), :257 `addFunction`
- What goes wrong: nomadfs `inode_table.Table` is reported as a 195-line
  function with complexity 41; its methods have no metrics, no api.md entries,
  no unused_pub, and their calls are credited to `Table`. On Zig std only 9.7k
  functions are found in 434k lines for the same reason.
- Fix: when a function returns `type` and returns a container, walk that
  container with owner `Table`, and measure the outer function without it.

### [high] A copied block is missed when it starts with common boilerplate (A)
- Where: src/clones.zig:99, 112 (buckets over `max_bucket` skipped) with :260 (skip when the previous token matches)
- What goes wrong: two functions sharing a 209-token body are reported, until 50
  other functions start with the same ~100-token setup. Then the start window's
  bucket is skipped and every later window is rejected as "not maximal", so
  nothing is reported. Long copies that begin with allocator/defer/writer setup
  are exactly the ones this misses.
- Fix: apply the maximality skip only when the previous window was compared, or
  extend matches both ways and deduplicate by (body, start) afterwards.

### [high] Tuple structs get their types as field names (A)
- Where: src/scan.zig:171-173
- What goes wrong: `struct { u32, u32, u8 }` and `struct { u32, u8, u32 }` are
  "exactly the same fields (u32, u32, u8)", a false duplicate_shape warning;
  api.md shows `u32: u32`.
- Fix: name tuple fields `0`, `1`, … (`tuple_like`), or skip tuples in duplicateShapes.

### [high] `unused_pub` tells you to delete functions that tests or std use (D)
- Where: src/checks.zig:211-221
- What goes wrong: on nomadfs, 6 of the 19 reported functions are called from
  `tests/` (outside the roots). `jsonStringify` and hash-map context `hash` are
  reported though std calls them. Common names (`get`, `init`) are never
  reported because any other `x.get(` counts.
- Fix: count names in every `.zig` file under the build root (a count-only
  walk), skip std hook names (`jsonStringify`, `jsonParse`, `hash`, `eql`,
  `lessThan`, `format`, `panic`), and soften the message ("…appears nowhere else
  in the scanned files; if nothing outside calls it, delete it or make it private").

### [high] `thick_frontend` misses calls through values and flags plain parsers (D)
- Where: src/checks.zig:186-209, src/scan.zig:330-356
- What goes wrong: `handle(svc: *core.Service)` deciding through `svc.charge()`,
  or a function with a local `const core = @import(...)`, is not reported.
  `parseArgs` calling one base helper is ("makes 1 calls into the core"), as are
  nomadfs's `sync.sleep` calls and the self-atlas lead on zigatlas's `main`,
  whose calls are the pipeline stages.
- Fix: record function-local import aliases; resolve `param.method(` when the
  parameter's type is `alias.Type`; don't count calls into the lowest layer (or
  a `Layer.utility` flag); name the calls in the message.

### [medium] The same-name check is quadratic and noisy (B, D)
- Where: src/clones.zig:169-235 (`sameName`, `similarity`)
- What goes wrong: 4000 same-named functions take 19 s and 4.9 GB (a new set
  per pair, ~600 B leaked each). It also reports unrelated serialisers
  (nomadfs `message()` in policy and rotation, "73% alike") and splits one
  name's copies across two findings.
- Fix: reuse one set, cap the group size, keep callee names and literal kinds in
  the comparison, require ≥ 20 tokens, report a name once and point at the `pub` copy.

### [medium] `duplicate_function` ignores which functions are called (D)
- Where: src/scan.zig:369 (every identifier not after `.` hashes the same)
- What goes wrong: `logged` calling `stepA`/`writeLog` and `sent` calling
  `stepB`/`sendPacket` are "the same body … keep one".
- Fix: keep the hash of names that resolve to file-scope declarations or
  aliases; erase only parameters and locals. Or say "same shape; the called
  functions may differ".

### [medium] `duplicate_fragment` reports the rows of one if/else or switch chain (D)
- Where: src/clones.zig:247-267, :142
- What goes wrong: nomadfs `config.zig:294-298` vs `298-302` (one else-if chain,
  overlapping lines), `device_names.zig:78-80` vs `80-82`.
- Fix: inside one function, drop periodic repetition (period shorter than the
  run); report it once as "N similar rows; consider a table".

### [medium] Memory use: the clone window map is ~60% of peak (B)
- Where: src/clones.zig:85; src/scan.zig:39, :362
- What goes wrong: 170-250 bytes per body token; Zig std peaks at 430 MiB,
  48 near-copies of one function at 1.69 GB. Every AST stays alive to exit.
- Fix (tested by the reviewer, byte-identical output): sort a flat array of
  window hashes instead of the map, and parse each file in a scratch arena.
  Std drops to 105 MiB, nomadfs to 16 MiB, the near-copies case to 240 MiB.

### [medium] Import aliases ignore declaration order and scope (A, C)
- Where: src/scan.zig:157-159, :206, :338
- What goes wrong: `const Peer = net.Peer;` before `const net = @import(...)`
  loses its calls; an alias declared inside struct `A` resolves calls in struct
  `B` and in functions with a parameter of the same name, inventing call edges.
- Fix: two passes for aliases (imports, then dotted aliases until stable, with a
  bound), keyed by owner container; ignore names shadowed by parameters or locals.

### [medium] Overlapping roots scan files twice, reported as duplicates of themselves (A, C, D)
- Where: src/main.zig:85-121
- What goes wrong: `--root src --root src/core` lists `src/core/*.zig` twice:
  each function is "a duplicate" of itself and identifier counts double.
- Fix: deduplicate paths after normalising and sorting.

### [medium] `annotation()` is quadratic when many declarations share a line (B)
- Where: src/scan.zig:426
- What goes wrong: it walks the comment block above the line once per
  declaration; 20k declarations under 20k comment lines take 26 s.
- Fix: precompute, per line, the start of its comment block (or the annotation) once.

### [medium] Typos in layer names switch checks off silently (D)
- Where: src/config.zig:138-142, src/scan.zig:119, src/render.zig:68-107
- What goes wrong: `--forbid botom:top` never matches; `//! @atlas layer: storge`
  puts the file in no known layer, so its imports aren't checked and it
  disappears from the layer table. (`--thin` already rejects unknown names.)
- Fix: reject an unknown `--forbid` side; report an unknown `@atlas layer` value.

### [medium] Configuration and reporting gaps (D, A, C)
- `--check` failures don't list the failing findings (src/main.zig:71-81): print
  `file:line: kind: message` to stderr, capped.
- `parse_error` always points at line 1 (src/checks.zig:63-68): carry the first
  error's line.
- deps.mmd puts a directory in its first file's layer, leaving nomadfs's `node`
  and `device` subgraphs empty (src/render.zig:285-289).
- The directory-level `import_cycle` is noise when layers are set per file
  (nomadfs's 9-directory loop exists only because `src/` holds files of several
  layers) (src/checks.zig:129-160): skip it when every edge in it points down a layer.
- Deeply nested containers (850+ levels in Debug) crash the run inside
  `std.zig.Parse`, and `walkMembers` recurses without a bound (src/scan.zig:39):
  report the file instead of parsing it when brace depth is extreme.

### [medium] Most finding kinds, the CLI and the renderers have no tests (D, C)
- Where: src/checks.zig, src/clones.zig, src/main.zig, src/render.zig; no assertions anywhere
- What goes wrong: `thick_frontend`, `unused_pub`, `duplicate_shape`,
  `parallel_implementation`, `duplicate_fragment`, hotspots, `parse_error` and
  `@atlas allow` on imports have no report case and no must-not case, which the
  skill requires. Nothing runs the CLI on a fixture, which is how the path bugs
  got through.
- Fix: one report case and one must-not case per kind (the reviewers' fixtures
  are ready-made); a test step that runs the binary on `testdata/` and compares
  atlas.json; asserts at module boundaries (body index, `line <= end_line`).

### [low] Smaller issues
- Re-export resolution leaves duplicate call edges (src/scan.zig:53-57); a hop
  limit hit leaves a half-resolved target, and the limit is a bare `8` (:64).
- `@"quoted"` function names don't match their plain uses (src/scan.zig:263, :387).
- `@import("x.zig",)` with a trailing comma isn't an alias (src/scan.zig:203-213).
- `extern fn` prototypes are missing from api.md (src/scan.zig:139).
- An empty file counts as 1 line (src/scan.zig:490-497).
- Nesting depth counts struct-literal braces (src/scan.zig:315-318).
- `duplicate_shape` groups through a third struct and lists the first struct's
  fields, not the shared ones (src/checks.zig:236-272).
- Qualified names grow quadratically with nesting depth: a 57 KB input produced
  30 MB of output (src/scan.zig:165, :278).
- O(n²) passes that are fine today but unbounded: duplicate_shape grouping,
  api.md rendering (files × functions), `inTest` per import (B).
- Functions over ~60 lines: `config.parse` (86), `clones.fragments` (78),
  `main` (65), `tarjan` (62); caps written as bare numbers in render, scan and main.
- The CLI holds analysis logic: `findingOrder` and `stats` belong in
  checks/model (src/main.zig:134-170); render silently depends on that order.
- Defaults and the `Layer`/`Rule` types are written in four places (build.zig,
  config.zig, `usage`, README); `build.zig` can import `src/config.zig`.
- Doc mismatches: `Options.name` default, `--check` accepts `info`, "1 calls",
  README's `@atlas allow` and `unused_pub` rows, no `schema` version or layer
  config in atlas.json, conditional re-exports (`if (…) @import(…) else …`) not followed.

---

## Checked and sound
- Dependency direction: every import points down; no layer break in the self-atlas.
- AST accessors on the right node tags; token look-ahead bounded; integer
  subtraction safe; no pointer into a growing list.
- Files with parse errors give a partial atlas; `\r\n`, no trailing newline,
  multiline strings, non-literal `@import`, `export fn`, `fn` types in fields.
- Deterministic output (two runs on zigatlas and nomadfs, byte-identical).
- Every directory, walker and file closed on every path; tests leak nothing.
- Loops bounded: alias chains, re-export loops between files, union-find,
  Tarjan, clone extension.
- The build API in a real consumer: `.name` default, trailing-slash layers,
  `b.args` (`-- --check`, `-- --check warn`, `-- --out`), output under the install
  prefix, re-run on every build, `--check` failing the build; CLI flags match `usage`.
- nomadfs results spot-checked against the code: the layer violation, the 4
  forbidden imports, the mdns/nat duplicates, 13 of 19 unused_pub.

## Not covered
- Windows (backslash handling reasoned about, not run).
- Symlinked `.zig` files, unreadable files, files over 64 MiB, `@atlas` text in
  string literals, Mermaid/DOT escaping of odd paths.
- Projects other than nomadfs, zigatlas and Zig std.

---

## Fixed

Every finding above is fixed. Each finding kind now has a test it must report
and one it must not, plus `zig build test` runs the CLI on `testdata/layered`
(`--root .` must catch a forbidden import; a missing root must exit 2).
Tests: 29 unit tests and 2 CLI fixtures pass; `zig fmt` clean; two runs give
byte-identical output.

How some were fixed, where it differs from the suggestion:
- Clone hashes keep the names of file-scope functions, constants, imports and
  primitive types, and erase type names, so the same logic on two types still
  matches (relay/tcp `retain`) while bodies calling different functions don't.
- Repeating rows of one chain: dropped when the run is longer than the
  distance between copies, or when its start repeats 3+ times in one function.
- `thick_frontend` ignores calls into the lowest layer instead of a new
  `Layer.utility` field.
- Methods of generic types are owned by the function's name (`Table.init`).
- `unused_pub` counts names in every `.zig` file under the build root
  (`--usage-root`, default `.`; `Options.usage_roots`).
- Modules come from the build graph (`b.modules`, compile steps' root modules
  and every `import_table`), scoped to the importing module's directory
  (`--module NAME=PATH@DIR`); `addAtlasStep` must be called at the end of `build()`.
- `@atlas allow` in a file's `//!` header mutes `large_file`; parse errors stay.
- The reviewer's `Node.lookupValue` "used in tests" turned out to be a comment
  only; it is still (correctly) reported.

Reference project, nomadfs (`zig build atlas`), before → after:

| finding | before | after |
|---|---:|---:|
| functions found | 1433 | 1471 (generic-type methods) |
| complex_function warn (`Table`) | 1 | 0 |
| unused_pub | 19 | 14 (tests count) |
| thick_frontend | 4 | 3 (`benchReadCommand` only calls base helpers) |
| parallel_implementation | 6 | 6, none repeating a duplicate_function |
| duplicate_fragment | 41 | 35 (chain rows gone) |
| directory import_cycle | points at `sync.zig`, `net/id.zig` (base, fine) | points at `src/node_info.zig`, the real upward import |

Performance (ReleaseSafe), before → after:

| input | before | after |
|---|---|---|
| Zig std, 434k lines | 0.60 s, 430 MiB, 9.7k functions | 0.58 s, 107 MiB, 12.1k functions |
| nomadfs | 0.05 s, 40 MiB | 0.06 s, 16 MiB |
| 4000 same-named functions | 19 s, 4.9 GB | 0.17 s, 35 MiB |
| 20k declarations on one line | 26 s | 0.05 s |
| 48 near-copies of one function | 1.69 GB | 16 MiB |
| 40k structs | 6.5 s | 0.22 s |

Self-atlas after: 0 errors, 0 warnings, 8 notes (the main `thick_frontend`
lead is gone; a `model.LayerInfo` copy of `config.Layer` it found was merged).
