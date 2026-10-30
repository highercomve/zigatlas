# f42c8f2 re-review: Lens C (Power of 10, adapted to Zig)

Scope: `git diff 46c1751 f42c8f2 -- src build.zig` and the code around each change.
The working tree had uncommitted edits to `src/checks.zig`, `src/main.zig` and `src/scan.zig`
(a `scan.Names` / reflected-namespace change to `unused_pub`), so the review used a clean export of
f42c8f2 in `/tmp/za-r2-c/f42` (`git archive f42c8f2`). Line numbers are f42c8f2's. Fixtures are under
`/tmp/za-r2-c/<case>/src` and were run with `/tmp/za-r2-c/f42/zig-out/bin/zigatlas --root src` (Debug) and
`/tmp/za-r2-c/rs/bin/zigatlas` (ReleaseSafe). Generators: `/tmp/za-r2-c/scripts/gen.py`, `gen1.py`.

Verdict: approve with changes. Nothing here hangs, and the new loops all have bounds. But two of the new
caps throw away input without saying so, and the old Debug stack overflow can still be reached.

### [medium] Containers nested 65 or more levels deep: their functions and types disappear with no finding (Lens C)
- Where: src/scan.zig:242 (`if (depth > max_container_depth) return;`), src/scan.zig:16
- What goes wrong: `/tmp/za-r2-c/cnest65/src/a.zig` has 65 nested `pub const S<i> = struct {` with
  `pub fn deep() void {}` in the innermost one, which is 65 braces, well under `max_nesting = 200`.
  The result is `1 files, 0 functions; 0 errors, 0 warnings, 0 notes`, `parse_errors: 0`, `parse_note: ""`.
  The function is gone and nothing in ATLAS.md or atlas.json says so. With 64 levels (`cnest64`)
  it is found. A file nested past 200 brackets is reported (`parse_error`, "not analysed"), so the
  smaller cap is the only one that fails silently. The cap also isn't needed for safety: `tooDeep`
  already rejects files with more than 200 brackets, so `walkMembers` → `varDecl`/`fnDecl` → `walkMembers` can
  never go more than 200 levels deep.
- Fix: drop `max_container_depth` and rely on `max_nesting`, with a
  `comptime` comment that the walk depth is at most `max_nesting`. If the cap stays, the first skip
  should set the file's `parse_note` (for example "containers nested more than 64 deep were not analysed") so
  it shows up as a finding, the same way `tooDeep` does.

### [medium] The Debug stack overflow is only partly fixed: nesting without brackets still crashes the parser (Lens C)
- Where: src/scan.zig:836 (`tooDeep` counts only `{ ( [`), src/scan.zig:76 (`Ast.parse` on the main thread's stack)
- What goes wrong: `/tmp/za-r2-c/elseif/src/a.zig` is a function that returns a 5000-arm
  `if (v == 0) 0 else if (v == 1) 1 else ... 0` chain. That is the shape of generated lookup code, and
  `zig ast-check` accepts it (exit 0). The Debug zigatlas aborts (exit 134, stack overflow in
  `std.zig.Parse.parseIfExpr`/`expectExpr`). The bracket depth there is only 2, so `tooDeep` lets it through.
  The same happens with `const b = if (c) if (c) ... @import("b.zig")`: Debug survives 3500 levels and aborts at 4500
  (`ifn4500`), while ast-check accepts 8000. ReleaseSafe (what `addAtlasStep` builds) survives both
  (`elseif`, `ifn8000`: exit 0). `zig build atlas` in this repository and `zig build run` use Debug.
- Fix: do what the v0.1.0 review suggested and was not done: run `addFile` (parse plus walk) on a
  `std.Thread` with an explicit large stack (for example `.stack_size = 256 << 20`). Keep `tooDeep` for
  what it does well. Without a bigger stack, a token count can't bound the parser's recursion,
  because `if`/`else`, prefix operators and `try`/`comptime` chains all recurse without brackets.

### [low] Alias resolution stops after 8 rounds with no sign that it did (Lens C)
- Where: src/scan.zig:20 (`max_alias_rounds = 8`), src/scan.zig:347
- What goes wrong: `order<N>/src/a.zig` is `const a0 = a1; const a1 = a2; ... const aN = @import("b.zig");`
  followed by `pub fn f() void { a0.g(); }`. With N=7, `f` calls `src/b.zig:g`. With N=8, 9 and 100, `f` has
  no calls, and nothing reports that. Each round resolves one more link of a chain declared backwards,
  so a chain of 9 or more needs more than 8 rounds. The loop already ends by itself when a round changes nothing
  (`if (!changed) break;`), so it terminates after at most `vars.len + 1` rounds. The fixed cap is only a cost
  limit, and it trades a quadratic worst case (a chain of n backward aliases) for a silent false negative.
  The v0.1.0 review asked for a bound "by the number of alias declarations", so that finding is partly fixed.
- Fix: resolve on demand instead of in rounds. When `lookup` misses a name that is a not-yet-done `PendingVar`
  in scope, resolve that one first, guarded by an "in progress" mark so cycles stop. That is linear, and
  it is bounded by `vars.len` with an explicit stack. Or keep the cap, and when the last round still
  `changed`, add an info finding ("alias chain longer than 8; calls through it are not resolved").

### [low] A re-export chain longer than 8 hops leaves a call to a function that does not exist, with no finding (Lens C)
- Where: src/scan.zig:135
- What goes wrong: `chain9`: `main.zig` calls `f0.x.go()`, and `f<i>.zig` has `pub const x = @import("f<i+1>.zig").x;`
  for i = 0..8, with `x` defined in `f9.zig`. The call is kept as `src/f0.zig:x.go`, which names no function.
  `chain8` resolves to `src/f8.zig:x.go`. `selfalias` (`pub const loop = me;` followed by `me.loop` ×10 `.go()`) gives
  `src/a.zig:loop.loop.loop.loop.loop.loop.loop.loop.loop.loop.go`. This is better than v0.1.0's half-resolved
  target, and real chains are 1-3 hops. But this target still feeds `thick_frontend` (the layer of `f0.zig`) and the
  "neither calls the other" test in `parallel_implementation`, and nothing records that it was given up on.
- Fix: when the hop cap is hit, drop the call (or keep it with a marker that checks skip) instead of
  keeping a target that isn't a function. Optionally count these and put the count in the stats.

### [low] `lookup` and `typeAlias` treat a failure as "not an alias" (Lens C)
- Where: src/scan.zig:396-398 (`var key_buf: [512]u8`, `bufPrint(...) catch return null`), and `typeAlias`'s
  `member.append... catch return null` (three places, added in this commit)
- What goes wrong: rule 7, return values. `/tmp/za-r2-c/longscope/src/a.zig` has a file-scope
  `const io = @import("b.zig");` and ten nested structs with 61-character names, with
  `pub fn f() void { io.g(); }` inside. The owner string is about 620 bytes, so `bufPrint` fails at the
  first scope, `lookup` returns null without walking out to file scope, and `f` has `calls: []`
  (it should be `src/b.zig:g`). In `typeAlias`, an out-of-memory error becomes "this parameter is
  not typed by an alias" instead of an error. Both are unlikely, but both give a silent wrong answer, and the
  512 is a bare number.
- Fix: avoid the concatenated key. Key the alias map by `owner`, holding a small map per scope, or build
  the key in `s.tmp` with `try`. Make `typeAlias` return `Allocator.Error!?Alias` and `try` it in `localAliases`.

### [low] `Checker.duplicateShapes` grew to 71 lines, complexity 26 (Lens C)
- Where: src/checks.zig:289 (self-atlas: 71 lines, complexity 26, nesting 3. It is the only function over
  ~60 lines in the changed code. The next longest are `dirCycles` at 47, `render.api` at 47 and `config.parse` at 46.)
- What goes wrong: rule 4. The candidate index, the `checked` stamps, group selection and reporting
  are all in one body. The self-atlas only lists it as `complex_function` (info), because the default
  `max_fn_lines` is 80.
- Fix: split it into three. `shapesOf(containers)` builds the sorted field-name lists (289-298).
  `bestGroup(shape, si, by_name, checked, groups, shapes) ?struct { gi: u32, exact: bool }` holds the candidate
  loop (308-325). `reportShapes(groups, shapes, containers)` does the reporting (344-358).

### [low] Recursion that could be a loop: `aliasOf` through `if`, and `collectCompileModules` (Lens C)
- Where: src/scan.zig:367, build.zig:172-183
- What goes wrong: rule 1. `aliasOf` calls itself once per nested `if`. Its depth is bounded by the AST the
  parser already built, and the parser always overflows first (`ifn4500`: the frames are all `Parse.*`).
  `collectCompileModules` visits each step once (the `steps` set), but its stack depth is the longest
  step-dependency chain. std's build runner recurses over the same graph, so it isn't reachable first.
  *Unverified*, because no build graph deep enough was constructed. Neither is a bug today, but both are
  tail or graph walks that are as short written as loops.
- Fix: `var node = init_node; while (tree.fullIf(node)) |fi| node = fi.ast.then_expr;` in `aliasOf`.
  In build.zig, push step pointers onto a worklist the same way the module `queue` beside it already works.

### [low] Bare numbers left over, and one limit stated twice (Lens C)
- Where: src/scan.zig:68 (`"nested more than 200 levels deep; not analysed"` repeats `max_nesting`);
  src/scan.zig:514/531/540 (`IntegerBitSet(256)` and `open < 256` in `metrics`, which is correct only because
  `max_nesting = 200 < 256`, and that coupling isn't stated); src/checks.zig:353/356 (`8` shared field
  names shown, twice); src/scan.zig:396 (`512`); src/config.zig:249 (`[32]u8`).
- What goes wrong: rule 3. If `max_nesting` is raised past 256, `metrics` silently stops tracking
  which braces are blocks, and the parse note goes on saying 200.
- Fix: `std.fmt.comptimePrint("nested more than {d} levels deep; not analysed", .{max_nesting})`.
  Use `IntegerBitSet(max_nesting + 1)`, or add `comptime std.debug.assert(max_nesting < 256)`. Add
  `const max_shared_names = 8;` next to `max_shape_candidates`.

### [low] The new assertions are right, but the important cross-module invariants still aren't asserted (Lens C)
- Where: src/clones.zig:34-35, :378; src/scan.zig:479; src/checks.zig:28; src/render.zig:93, :123
- What goes wrong: rule 5. The added asserts hold and are worth having (`body.function < functions.len`,
  `hashes.len == lines.len`, `line <= end_line`). Three invariants that cross modules are still only implied:
  (a) one `Body` per function: `scan` appends each body right after its function, so `body.function` is
  strictly increasing, but `detect` only checks that it is in range, so two bodies pointing at one function would
  pass; (b) unique file paths: `checks.run` does `index.put` and a duplicate silently overwrites
  (`collectFiles` now deduplicates, verified with `--root src --root ./src/core/x.zig`, but `checks.run`
  doesn't state the precondition); (c) `render.layerSection`/`dirEdges` still `.?` on `imp.resolved`,
  which holds only because `checks.run` has nulled unknown targets first, and no comment or assert says so.
- Fix: in `detect`, assert that `body.function` is strictly greater than the previous one. In `checks.run`, use
  `getOrPut` plus `std.debug.assert(!gop.found_existing)`. In render, use `orelse continue` or add a doc comment
  "requires checks.run".

## Previous findings re-checked (v0.1.0 lens-c.md)

| Finding | Status |
|---|---|
| Deep nesting overflows the stack in Debug | **Partly fixed.** Bracket nesting over 200 is reported (`brk200` analysed, `brk201` gives "nested more than 200 levels deep; not analysed"). Nesting without brackets still crashes Debug: a 5000-arm `else if` chain, and `if` nested 4500 deep. No thread with a big stack. `walkMembers` has a depth bound, but it fails silently (new finding above). |
| Import aliases share one map across sibling scopes | **Fixed.** Scoped keys plus `lookup` from the owner outward: `/tmp/za-r2-c/scope` gives `A.f → a.zig:g`, `B.h → b.zig:g`. New issue: the 512-byte key buffer (above). |
| File paths not unique, so overlapping roots give false duplicates | **Mostly fixed.** `collectFiles` deduplicates after sorting, and roots are normalised (`--root src --root ./src/core/x.zig` gives 1 file, no `duplicate_function`). The assert in `checks.run` was not added. |
| No assertions anywhere | **Partly fixed.** Asserts were added in `clones.detect`, `clones.location` and `addFunction`. `findingSection` now sorts its own copy, which fixes (c). Still missing: one body per function, unique paths, and the `.?` contract in render. |
| Alias resolution depends on declaration order | **Partly fixed.** Out-of-order aliases resolve, but only up to 8 rounds. A backward chain of 9 or more silently loses its calls (`order8`). |
| Re-export hop limit is a bare `8` and returns a half-resolved target | **Fixed as suggested** (`max_reexport_hops`, returns the original call). What's left is low: the kept target names no function and isn't reported (`chain9`). |
| Qualified names grow quadratically with nesting | **Fixed (bounded).** Container depth is at most 64 and nesting at most 200, so name size is at most about 64 times the input. |
| Functions over the ~60-line budget | **Fixed for the four listed.** `config.parse` is 46 lines (`numberField`), `fragments` is split into `collectWindows`/`findMatches`/`reportFragments`, `main` uses `buildAtlas`/`writeOutputs`/`passesCheck`, and `tarjan` uses `Tarjan.popComponent`. **New:** `duplicateShapes` is 71 lines. |
| Bare-number caps | **Mostly fixed.** `top_functions`, `top_files`, `max_fields`, `max_file_bytes`, `max_check_lines`, `doc_max`/`signature_max`/`field_type_max` and the scan caps are all named with reasons. Still bare: the `200` in the parse note, `256` in `metrics`, `8` in `duplicateShapes`, `512` in `lookup`. |

Previous findings not fully fixed: 5 of 9 (nesting overflow, unique-path assert, assertions, alias order, bare numbers).

## Checked and sound

- `zig build test --summary all` on f42c8f2: 6/6 steps, 29/29 tests passed, in Debug and with `-Doptimize=ReleaseSafe`.
  The output also contains two `failed command:` blocks with usage text. These come from the expected-failure
  cases (`--root nosuch`, `--forbid ... botom`) printing to stderr, so the log looks like it is failing when it isn't.
- `zig fmt --check src build.zig`: clean (exit 0).
- `zig build -Doptimize=ReleaseSafe -p /tmp/za-r2-c/rs`: builds with no warnings.
- Self-atlas (f42c8f2): 7 files, 145 functions; 0 errors, 0 warnings, 9 notes.
- `resolveCall` hops: bounded, and a chain of exactly 8 resolves (`chain8`). The cap check sits before the move, so there is no off-by-one.
- `lookup` scope walk: the scope gets strictly shorter on each step, and the loop ends at `""`.
- `tooDeep`: one tokenizer pass, linear. `depth -|= 1` on stray closers. The boundary is exact (200 analysed, 201 reported).
- `duplicateShapes` `checked` stamps: one stamp per group per shape, so each group is compared at most once
  per shape. Candidates are capped at `max_shape_candidates` per name. It picks the lowest-index qualifying group whatever order
  the names come in. Bounded by about fields × 256 per shape.
- `aliasOf` through `if`: terminates (it follows `then_expr` down a finite AST). `ifn3000` resolves `b.g()` to `src/b.zig:g`.
- `numberField` + `inline else` + `@field`: simple. A mismatch between `NumberField` and the `Config` fields is a
  compile error. Names longer than the buffer are rejected before the copy.
- `usage` via `comptimePrint`: the defaults come from `Config{}`, so they can't drift.
- Clone extension and the rolling hash: unchanged bounds. `min_clone_tokens` is still clamped to ≥ 10.
- Return values: every new fallible call is `try`'d, apart from the `catch return null` cases above and
  `collectCompileModules`/`enqueue` `catch @panic("OOM")`, which is the build-script convention.

## Not covered

- Scanning nomadfs and comparing counts (Lens D).
- Memory and time of the new structures at scale (`by_name` in `duplicateShapes`, per-function `seen` maps in
  `resolveCalls`), which is Lens B.
- Whether picking `then_expr` for `if` aliases is correct (the `else` branch may import another file), which is Lens D.
- A build graph deep enough to stress `collectCompileModules`.
- The uncommitted working-tree changes (`scan.Names`, reflected namespaces in `unused_pub`).
