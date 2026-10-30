# zigatlas f42c8f2 re-review: Lens A (Zig idioms and correctness)

Scope: `git diff 46c1751 f42c8f2 -- src build.zig` and the code around each change.
The working tree was being edited while I reviewed it (uncommitted changes to
`checks.zig`, `clones.zig`, `main.zig` and `scan.zig`), so I reviewed the commit
itself: I extracted it with `git archive f42c8f2` to `/tmp/za-r2-a/tree` and built
it in Debug (`/tmp/za-r2-a/bin-dbg`) and in ReleaseSafe (`/tmp/za-r2-a/bin-rs`).
I reproduced every finding below with fixtures under `/tmp/za-r2-a/<case>/`, on
both the committed build and the provided `zig-out/bin/zigatlas`. Each one gives
the same result on both builds unless the finding says otherwise.

Committed tree: `zig build test` passes (29/29 tests plus the two CLI
fixtures). `zig fmt --check src build.zig` is clean.

### [high] Enum tags and untyped union fields are now treated as tuple fields (Lens A)
- Where: src/scan.zig:309
- What goes wrong: `field.ast.tuple_like` is true for any field with no `:`. That covers every enum tag and every bare `union(enum)` tag, not only real tuple fields. With `pub const E = enum { alpha, beta, gamma };` the atlas.json output is `"tuple": true, "fields": [{"name":"0","type":"alpha"}, …]`, and api.md shows `tuple enum E { 0: alpha, 1: beta, 2: gamma }`. With `union(enum) { none, some: u32 }` the output is `{ 0: none, some: u32 }`. So every enum in every project now has its API listing and its JSON schema data wrong (fixture `enumt/`). This is a regression of the tuple fix.
- Fix: use the positional naming only when `tree.tokenTag(container.ast.main_token) == .keyword_struct`. Enum and union fields keep `identName(main_token)` as their name and an empty type. Add a test with an enum.

### [high] An unreadable directory anywhere under the cwd aborts every run (Lens A)
- Where: src/main.zig:67 (default `--usage-root .`) and src/main.zig:148 (`try walker.next`)
- What goes wrong: the new usage walk covers the whole build root by default. When it reaches any directory that can't be opened (for example a root-owned `data/pg/` Docker volume, mode 000), `walker.next` returns `error.AccessDenied` and `main` exits 1 with a stack trace, without writing any output. Exit 1 is also the code for "`--check` failed". The same happens for an unreadable subdirectory under `--root`. Fixture `perm/`: with `data/pg` set to mode 000, the run fails. Adding `--usage-root src` makes it pass.
- Fix: in `walkRoot`, catch errors from `walker.next`. For usage roots, warn and `leave()` the directory, or skip it. For scan roots, report it on stderr and exit 2, which is what a bad root already does.

### [medium] Non-UTF-8 text still turns atlas.json strings into integer arrays (Lens A, previous finding partly fixed)
- Where: src/scan.zig:318 and :447-449/:486-488 (names and ids), :427 (`.target`), :430/:462 and `annotationIn` (allow reasons), :578 (calls); main.zig:154 (paths)
- What goes wrong: `cleanText` only covers doc, signature and field types. Fixture `utf/x.zig` contains `// @atlas allow: na\xefve`, `@import("caf\xe9.zig")`, `pub fn @"g\xe9"()`, a field `@"f\xe9"` and the `//!` header `@atlas allow: caf\xe9`. All of it parses without errors. In the output, `functions[0].id`, `.name`, `.allowed`, `calls[0]`, `imports[0].target`, `imports[0].allowed`, `files[0].allowed` and `containers[0].fields[0].name` are written as integer arrays, and api.md is not valid UTF-8. A file whose name is not valid UTF-8 has the same problem.
- Fix: pass every source-derived string through one sanitiser before it goes into the model (identifier names when `identText` returns the raw `@"…"` form, import targets, annotation values, paths). Alternatively, sanitise centrally in `render.json` and `render.api`.

### [medium] Generic types: calls from the methods are still charged to the generic function (Lens A, previous finding partly fixed)
- Where: src/scan.zig:502 (`calls` ignores `p.exclude`) and :587 (`localAliases` likewise)
- What goes wrong: `metrics` and `addBody` skip the returned struct, but `calls` and `localAliases` scan the whole body. Fixture `gen/q.zig`: `Queue` gets `calls: ["net.zig:send"]`, which is the call made by `Queue.push`. Its methods' calls therefore still feed `thick_frontend` and `parallel_implementation` through the generic function. The opposite case is also wrong: `Stack` declares `const inner = @import("net.zig");` in the function body, before `return struct { pub fn pop() void { inner.recv(); } }`. Then `Stack.pop` gets `calls: []`, and `Stack` gets `["net.zig:recv"]`.
- Fix: pass `exclude` to `calls` and `localAliases` and skip the range there. Give the methods of a returned container the function-scope aliases of the generic function, collected from the tokens before the container.

### [medium] One clone is reported twice when a window inside the run sits in an over-cap bucket (Lens A)
- Where: src/clones.zig:182-184
- What goes wrong: the new rule is "report from here if the predecessor window's bucket was over `max_bucket`". It also fires in the middle of a run whose first window was compared and reported normally. Fixture `dupfrag/` (`--min-clone-tokens 10`): `ca` and `cb` share a body `a1(); p1(); p2(); p3(); if… ×5`. 50 other functions contain `q(); p1(); p2(); p3(); z();`. The output has two warnings for the same pair: "67 tokens repeated in 2 places (ca, cb)" and "59 tokens repeated in 2 places (ca, cb)". The second is a suffix of the first. `reportFragments` dedupes on exact start `Pos`, so it doesn't catch this.
- Fix: walk back through the run to its first token, and report from the predecessor only if it was itself skipped. Simpler: after extension, drop matches that lie inside an already accepted match for the same body pair (`a.at > m.a.at and a.at + len <= m.a.at + m.len`, the same for `b`).

### [medium] Excluded files no longer count as uses, so `--exclude` creates unused_pub findings (Lens A)
- Where: src/main.zig:156 (`isExcluded` also applies to the usage walk)
- What goes wrong: `walkRoot` is shared by scan roots and usage roots. A file under `--exclude` (generated or vendored code) is therefore also left out of the name counts. Fixture `excl/`: `src/gen/g.zig` calls `h.helper()`. With `--exclude src/gen`, the output says `src/core/h.zig:helper is public but its name appears nowhere else`.
- Fix: apply `isExcluded` only when collecting scan roots (pass `required` or a flag into `walkRoot`), so excluded files are still searched for uses.

### [medium] The `--forbid` typo check accepts anything when a root is `.` (Lens A)
- Where: src/config.zig:267
- What goes wrong: `pathHasPrefix(s, ".")` is always true, so with `--root .` (the form the new CLI fixture uses) a misspelt selector passes. Fixture `cfg/`: `--root . --layer ui=src/ui --layer core=src/core --forbid uii:core` exits 0 and the rule does nothing.
- Fix: treat a side with no `/` or `.` as a layer name only, and fail if no layer has that name. A path side must contain a separator. Alternatively, require that the path exists or that some scanned file has it as a prefix (check after `collectFiles`).

### [low] `--module NAME=PATH` with an `@` in PATH is split at that `@` (Lens A)
- Where: src/config.zig:227, together with build.zig:199 (`moduleArg` omits `@DIR` when the scope is empty)
- What goes wrong: `--module lib=v@2/root.zig` becomes path `v`, scope `2/root.zig`. `@import("lib")` stays unresolved, and `l.lib()` records no call (fixture `cfg/`). `addModuleArgs` passes unscoped public modules without the `@`, so a project with an `@` in a module path is affected.
- Fix: have `moduleArg` always write the separator (`NAME=PATH@` for an unscoped module), and treat an empty scope as unscoped in `parseOption` (today `normalizePath("")` turns it into `.`). Alternatively, use a separator that is not valid in paths.

### [low] Relative paths that leave the cwd and come back in are not canonical (Lens A)
- Where: src/config.zig:111
- What goes wrong: only absolute paths are made relative to the cwd. `resolvePosix(&.{"../src/ui"})` keeps `../src/ui`, while the absolute form `/…/src/ui` becomes `ui`. Run from `cfg/src` with `--root /abs/cfg/src/core --root ../src/ui --layer ui=/abs/cfg/src/ui --layer core=../src/core`, both layers, both imports and the cycle are lost: every file has `layer: null`, and `resolved` is null. The same tree with consistent spellings reports 1 error and 2 warnings.
- Fix: always use `relativePosix(arena, cwd, cwd, slashed)`, which resolves relative inputs against the cwd as well.

### [low] Parser stack overflow is still reachable without brackets (Lens A, previous finding partly fixed)
- Where: src/scan.zig:836 (`tooDeep` counts only `{ ( [`)
- What goes wrong: `std.zig.Parse` also recurses on an expression `if … else if …` chain, on prefix operators and on `?`/`*` type prefixes. All of these keep bracket depth at 1. Results: a `return if (a == 0) 0 else if (a == 1) 1 else …` chain with 5000 arms aborts the Debug build (exit 134, segfault in `parsePrimaryTypeExpr`), and with 50000 arms it also aborts ReleaseSafe. `const T = ` followed by 50000 `?` and `u8;` aborts both builds. `!` ×50000 aborts Debug. A statement-level `if {} else if {}` chain with 5000 arms is fine.
- Fix: also count `keyword_else` followed by `keyword_if`, and runs of prefix-operator tokens, in `tooDeep`. Alternatively, parse on a thread with a large explicit stack (for example 64 MiB) and keep `tooDeep` as a backstop.

### [low] Aliases under long container names are silently not found (Lens A)
- Where: src/scan.zig:396
- What goes wrong: `scopedKey` stores keys of any length, but `lookup` uses a 512-byte buffer and returns null when it overflows. Fixture `longk/`: for `const S<600 A's> = struct { const net = @import("n.zig"); pub fn f() void { net.send(); } }`, `f` gets `calls: []`. The same code in `Q` gets `n.zig:send`.
- Fix: allocate the key in `s.tmp`, or key the map by `(owner, name)` with a context instead of a joined string.

### [low] Containers nested deeper than 64 vanish without a note (Lens A)
- Where: src/scan.zig:242
- What goes wrong: 100 nested `const A = struct {` with `pub fn f` at the bottom gives `0 functions`, 0 findings, and nothing says the file was cut short (fixture `nest100/`). `tooDeep` says "not analysed" at 200 levels. Between 65 and 200 levels, the output is silent.
- Fix: when the depth cap is hit, record a `parse_note`-style finding on the file (an info finding is enough).

### [low] `zig build test` prints "failed command" although it passes (Lens A)
- Where: src/config.zig:272 (`fail` prints usage with `std.debug.print`) and the test at :314
- What goes wrong: the test "a misspelt rule is rejected" writes the usage text to stderr. The build runner then prints `failed command: …/test …` while reporting `29/29 tests passed`, which looks like a failure in CI logs.
- Fix: return the message instead of printing it inside `parse` (let `main` print it), or skip the print under `builtin.is_test`.

## Previous findings re-checked

| v0.1.0 Lens A finding | status | evidence |
|---|---|---|
| [critical] Non-UTF-8 / truncated text becomes integer arrays | partly fixed | doc, signature and field types are clean (truncation at 160 is valid UTF-8). Names, ids, targets, allow reasons and calls are not (see above). |
| [high] `--root .` disconnects imports | fixed | testdata fixture passes. Mixed absolute and `..` spellings still diverge (low, above). |
| [high] Tuple structs: type names as field names | fixed for structs | regression: enums and unions are now "tuples" (high, above) |
| [high] Generic type functions measured as one function | partly fixed | metrics, tokens, members and api are right. Calls are still attributed to the generic, and function-scope aliases are lost (medium, above). |
| [high] Clone dropped when its first window is boilerplate | fixed | `dupfrag/` reports it, but twice (medium, above) |
| [medium] Missing or empty root exits 0 | fixed | `--root nosuch` gives exit 2 (CLI fixture). `/` and `.` normalise. |
| [medium] Overlapping roots scan a file twice | fixed | `--root src --root src/scan.zig --root ./src/` gives 7 files, and the output is identical to `--root src` |
| [medium] Import aliases ignore order and scope | fixed | `order/`: `f` gets `net.zig:Peer.connect`. `g(other: anytype)` gets no call. |
| [low] Re-export resolution duplicates call edges | fixed | dedupe after `resolveCall` (test in scan.zig) |
| [low] `@"quoted"` names don't match plain uses | fixed | `misc/`: `b.hello()` resolves to `b.zig:hello` and is not unused_pub |
| [low] `@import("x.zig",)` not an alias | fixed | `misc/`: call recorded |
| [low] `extern fn` missing | fixed | listed with `is_extern`, and skipped by hotspots and unused_pub |
| [low] parse_error always line 1 | fixed | `pe/`: points to `x.zig:3` |
| [low] Empty file counts as 1 line | fixed | `pe/e.zig`: `lines: 0` |
| [low] Deep nesting crashes the run | partly fixed | bracket nesting is caught. Else-if chains and prefix runs still overflow (low, above). |

Not fully fixed: 3 (UTF-8, generics, deep nesting). The tuple fix introduced a new high regression.

## Checked and sound
- Scratch arena in `addFile`: nothing that outlives the file points into it. `aliases`, `file_names`, `pending`, `vars`, `test_ranges`, `allow_at` and `locals` are tmp-only. `file_aliases` (kept in `b.exports`) has arena keys, and its `Alias` values hold `file` (arena `resolvePosix`, config path, or source slice) and `member` (arena). Imports, functions and containers hold only source slices, config strings or arena copies. `allow_at` values are source slices. Debug and ReleaseSafe outputs of the self-atlas are byte-identical, with no garbage text.
- `cleanText` (for the strings it covers): it stops at a character boundary, writes `?` for bad bytes, and the `…` may exceed `max` by 3 bytes, which is harmless.
- `metrics`: exclude skip (`i = r[1]; continue`), `-|` on depth and prongs, and the `IntegerBitSet(256)` brace stack. `tooDeep` caps brackets at 200, so `open` stays below 256.
- `addFunction`: `tokens = body_last - body_first + 1 - excluded` cannot underflow (the container lies inside the body). The `line <= end_line` assert holds.
- `inTest` binary search: test ranges are sorted and don't overlap (tests are not walked inside function bodies). `lineOf` on an empty file gives 1. `indexAllows` and `lineText` are in bounds for empty files and files without a trailing newline.
- `identText` handles `@""`, `@"0x"` and escapes (it keeps the raw text). `isImportCall` and `closingParen` look-ahead is guarded by `t + 3 > last`.
- `resolveAliases` is bounded by 8 rounds. The `if` alias recursion is bounded by parse nesting.
- `numberField`: the length guard comes after the `--` check. `--check` with no value works.
- `collectFiles`: sorted, then deduped. A root that is a file is accepted. Walker paths are resolved like import targets.
- `clones`: `windowLess` is a total order, `longerFirst` is a total order, `bucketSize` runs on sorted windows, and `sameBodyCount`/`period` cannot underflow. Tarjan re-fetches `top` after `enter`. Two runs on nomadfs `src` and on zigatlas `src` (Debug against ReleaseSafe) gave byte-identical output.
- `checks`: `thickFrontend`'s `layers.len - 1` only runs when a layer matched. The `checked` trick in `duplicateShapes` is sound.

## Not covered
- Memory, Power of 10 and design (Lenses B to D).
- The uncommitted working-tree edits made during this review (`scan.Names`, and changes in clones and checks).
- `build.zig`'s `addModuleArgs` was not run on a real dependent project. Only the CLI side of `--module` was tested.
- The pre-existing `skip_dirs` entry `build` (it also skips a `src/build/` package), because it is outside the diff.
- Windows paths (drive letters in `normalizePath` and `--forbid` splitting on `:`).
- Symlinked `.zig` files and roots, and files larger than 64 MiB.
