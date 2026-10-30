# zigatlas v0.1.0 review: Lens C (Power of 10, adapted to Zig)

Scope: whole project (`src/*.zig`, `build.zig`) at 46c1751. Fixtures under
`/tmp/za-lens-c/<case>/`, run with `zig-out/bin/zigatlas` (Debug) and a
ReleaseSafe build at `/tmp/za-lens-c/rs/bin/zigatlas`.

### [medium] Deep container nesting overflows the stack in the Debug build, on code `zig ast-check` accepts (Lens C)
- Where: src/scan.zig:39 (`Ast.parse`), src/scan.zig:134 and :150 (`walkMembers` → `varDecl` → `walkMembers`)
- What goes wrong: `/tmp/za-lens-c/nest<N>/a.zig` with N nested `pub const S<i> = struct {`. Debug zigatlas:
  depth 700 is fine, 850 aborts (stack overflow, exit 134). `zig ast-check` accepts 1000 and 1500, and segfaults
  at 2000. ReleaseSafe (what `addAtlasStep` builds) survives 2000 and aborts at 10000. The frames that overflow
  are std's recursive parser (`parseContainerMembers` → … → `parseTypeExpr`, 667 frames deep at depth 2000),
  not zigatlas's own recursion: the parser always gives out first. `walkMembers`/`varDecl` still recurse with
  no depth bound, so they will be the limit once the parse runs with a bigger stack.
  Debug-only and pathological input, so ranked medium, although it is a crash on Zig the compiler accepts.
- Fix: run `addFile` (parse plus walk) on a worker thread with a large explicit stack (`std.Thread.spawn(.{ .stack_size = 64 << 20 }, …)`),
  and bound the walk: add a `depth` parameter to `walkMembers` with a named `max_nesting` (e.g. 256). Past it,
  stop descending and record a finding instead of recursing.

### [medium] Import aliases share one map across sibling scopes, so a call resolves to the wrong file (Lens C)
- Where: src/scan.zig:101 (`aliases`), :158 (`s.aliases.put` for every scope), :339 (`calls` looks up the flat map)
- What goes wrong: rule 6, data kept in a wider scope than it needs. `/tmp/za-lens-c/scope/src/m.zig` (valid, `ast-check` ok):
  ```zig
  pub const A = struct { const io = @import("a.zig"); pub fn f() void { io.g(); } };
  pub const B = struct { const io = @import("b.zig"); pub fn h() void { io.g(); } };
  ```
  Result: `A.f` calls `scope/src/b.zig:g` (it should be `a.zig:g`). Functions are scanned after the walk ends
  (`pending`), so the last `io` defined anywhere in the file wins for every function. A wrong call edge feeds
  `thick_frontend` (core call count) and the "neither calls the other" check in `parallel_implementation`.
- Fix: key aliases by scope. Store `owner` with each alias, or keep a map per container. In `calls`, look the
  name up from the function's owner chain outward to the file scope.

### [medium] Nothing enforces that file paths are unique: overlapping roots scan a file twice and report false duplicates (Lens C)
- Where: src/main.zig:84-118 (`collectFiles`), src/checks.zig:19 (`index.put` silently overwrites)
- What goes wrong: rule 5, an invariant that crosses modules but is never checked. In `/tmp/za-lens-c/dup`,
  `zigatlas --root src --root src/core` lists `src/core/x.zig` twice. The output has 3 files, 3 functions and a
  **warn `duplicate_function`** naming `src/core/x.zig:work` against itself. `fan_in` and stats are also counted
  twice. In `addAtlasStep` this needs only `.roots = &.{ "src", "src/core" }`.
- Fix: deduplicate after the sort in `collectFiles` (adjacent equal paths). In `checks.run`, assert that
  `index.put` never finds an existing key.

### [low] No assertions anywhere in the code base (Lens C)
- Where: all of src/. `grep assert` finds nothing. The invariants live only in `.?` unwraps (src/checks.zig:77,117,141,187; src/render.zig:87,117).
- What goes wrong: rule 5. These invariants cross module boundaries and are never stated:
  (a) each `Body.function` indexes the `Function` scanned with it (src/scan.zig:277/299, used in src/clones.zig:43,56,92,182);
  (b) `1 <= line <= end_line` (src/scan.zig:287 subtracts with no guard);
  (c) `render.findingSection` (src/render.zig:153-169) groups by contiguous `(kind, severity)` and silently
  splits groups if `main` did not sort first;
  (d) `render.layerSection`/`dirEdges` `.?` on `imp.resolved` only holds because `checks.run` has already
  nulled unknown targets (render crashes if a caller skips checks).
  No input breaks them today. The dup-roots bug above shows the kind of break they would catch.
- Fix: `std.debug.assert` at each hand-off: in `addFunction` (`line >= 1`, `end_line >= line`,
  `index == b.bodies.items.len`); in `clones.detect` (`bodies.len == functions.len`); a sortedness check at the
  start of `findingSection`. Also make the "resolved implies scanned" guarantee explicit, either a doc comment
  plus an assert in render or an `orelse continue`.

### [low] Alias resolution depends on declaration order, so forward references lose their calls (Lens C)
- Where: src/scan.zig:206-207 (`aliasOf` only follows aliases already seen)
- What goes wrong: this order dependence is what keeps the alias walk loop-free (`const a = b.x; const b = a.y;`
  terminates and produces no alias, verified in `/tmp/za-lens-c/alias`). The cost is that valid, order-independent Zig
  is missed. In `/tmp/za-lens-c/order`, `const Peer = net.Peer; const net = @import("net.zig");` followed by `Peer.connect()`
  gives `f` no calls (expected `net.zig:Peer.connect`).
- Fix: collect the raw alias expressions first, then resolve them to a fixpoint. Bound the passes by the
  number of alias declarations (each pass resolves at least one or stops), so cycles still terminate.

### [low] Re-export hop limit is an unnamed `8`, and hitting it returns a half-resolved target (Lens C)
- Where: src/scan.zig:64
- What goes wrong: the loop is bounded, which is good. The 2-file re-export cycle `x = @import("b.zig").y` /
  `y = @import("a.zig").x` ends after 8 hops with no hang (`/tmp/za-lens-c/reexp`). But reaching the limit
  isn't treated as failure. In valid Zig, `/tmp/za-lens-c/selfalias` (`const me = @import("a.zig"); pub const loop = me;`
  then `me.loop` ×10 `.go()`) resolves to `a.zig:loop.loop.go`, a target that names no function.
- Fix: `const max_reexport_hops = 8; // re-export chains in real packages are 1-3 deep`. When the loop
  exits because it hit the limit, return the original `call` unchanged.

### [low] Qualified names make output grow quadratically with nesting depth (Lens C)
- Where: src/scan.zig:165 and :278-281 (`owner.name` strings rebuilt per level, copied into `id`, `name`, `owner`)
- What goes wrong: rule 3, allocation that should be linear in the input. A 57.5 KB file (`nest2000`) produces
  `api.md` 9.9 MB and `atlas.json` 20 MB (ReleaseSafe run). Memory use grows the same way.
- Fix: the `max_nesting` bound from the first finding caps this too. Alternatively store the parent container
  index and build qualified names only when rendering.

### [low] Functions over the ~60-line budget (Lens C)
- Where (from `zig-out/atlas/atlas.json`):
  - src/config.zig:101 `parse`: 86 lines, complexity 33. Split out a table of the seven numeric flags
    (`{ "--max-params", "max_params" }` with `@field`), and a `finishLayers` for the `--thin` resolution and defaults.
  - src/clones.zig:76 `fragments`: 78 lines, complexity 27. Split into `indexWindows` (rolling hash →
    buckets), `collectMatches` (bucket pairs → `pairMatch`) and `reportFragments` (cover/report loop).
  - src/main.zig:17 `main`: 65 lines. Split out `writeOutputs` (lines 53-62) and `checkExit` (lines 64-80).
  - src/checks.zig:315 `tarjan`: 62 lines. Split out `popScc`.
  - Next in line, at 48-51 lines: `Checker.duplicateShapes` (separate the union-find linking from the
    reporting), `render.api` (move the container and function rows into helpers), `clones.sameName`.
- Fix: as listed.

### [low] Caps and limits that are bare numbers (Lens C)
- Where: src/render.zig:193 (`15`), :204/:212 (`10`), :254/:258 (`10` fields); src/scan.zig:172/293/413
  (`80`/`200`/`160` collapse widths), :64 (`8`); src/main.zig:33 (`64 << 20` read limit); src/render.zig:12
  `max_locations` (named, but no reason given). `max_bucket`, `max_fragments` and `max_per_kind` are named and explained.
- What goes wrong: rule 3. The limits are invisible to readers and duplicated (`10` twice in hotspots).
  A file over 64 MiB gets a stderr line and is missing from the atlas.
- Fix: name them next to `max_per_kind`, each with a one-line reason.

## Checked and sound

- `zig build test --summary all`: 3/3 steps, 7/7 tests passed. The same under `-Doptimize=ReleaseSafe`.
- `zig fmt --check src build.zig`: clean (exit 0).
- `zig build -Doptimize=ReleaseSafe --prefix /tmp/za-lens-c/rs`: builds with no warnings (output went to /tmp to leave `zig-out/` alone).
- Alias chains: `const a = b.x; const b = a.y; const c = c.z;` terminates and produces no alias (aliases are resolved once, at definition).
- Re-export loop between two files: terminates (bounded at 8 hops). The `import_cycle` finding is reported.
- Token look-ahead: `aliasOf` (`t + 3 > last`, `t + 2 > last`), `collectImports` (`i + 2 < len`, `i >= 3`), `calls` (`j + 2 <= last`, `j + 1 > last`),
  `docBefore`/`annotation` backward walks (`t > 0`, `line > 1`): all stay in range. Five files with parse errors
  (`/tmp/za-lens-c/broken`) give a partial atlas and 4 `parse_error` findings, no crash.
- Union-find `find` (src/checks.zig:276): links only root to root, so `parent` stays a forest and the loop is bounded, with path compression.
- Tarjan (src/checks.zig:315): iterative with an explicit stack. Each vertex is pushed once and each edge visited once. The `stack.pop().?` loop ends at `v`.
- Clone extension (src/clones.zig:264): bounded by both body lengths, and overlap within a single body is trimmed. The rolling-hash `while (true)` ends at `at + k >= len`.
  `min_clone_tokens` is clamped to at least 10, so `for (1..k)` never gets an inverted range. A huge value (4e9) finishes in 0.3 s.
- Return values: every fallible call is `try`'d or handled. The only `_ =` is `call.pop()` (the value is unused on purpose).
- Comptime/reflection: one `inline for` over `FindingKind` fields (render.zig:55) and `std.json.Stringify` of plain model structs; both simple.

## Not covered

- Scanning the reference project (`../nomadfs`) and comparing finding counts (Lens D's job).
- Memory and time on a 100k-line tree: the pairwise `duplicateShapes`/`sameName` loops and bucket pair counts (Lens B).
- How accurate the heuristic metrics are, e.g. `.{` counted as nesting in `metrics` (Lens A/D).
- Windows paths and `--root .`.
