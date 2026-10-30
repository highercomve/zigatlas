# zigatlas v0.1.0 review: Lens A (Zig idioms and correctness)

Scope: the whole project at `46c1751` (`src/*.zig`, `build.zig`). I checked every
finding by running `zig-out/bin/zigatlas` on fixtures under `/tmp/za-lens-a/<case>`.
Unless a finding says otherwise, each one below was reproduced.

### [critical] Truncated or non-UTF-8 text turns atlas.json strings into integer arrays (Lens A)
- Where: src/scan.zig:520 (`collapse` cuts at a byte count), src/scan.zig:400 and :412 (doc text taken raw), src/render.zig:16
- What goes wrong: `collapse` stops after `max` bytes, and that can split a multi-byte UTF-8 character. `std.json.Stringify` writes any `[]const u8` that is not valid UTF-8 as an array of numbers. Fixture `utf/x.zig` is `/// a` followed by 100 `é`, then `pub fn f() void {}`. The output has `"doc": [97, 195, 169, …]` (165 lines of integers) where a string should be, so the schema breaks for every consumer. `api.md` also becomes invalid UTF-8 (`0xc3` followed by `…`). Source that is already non-UTF-8 does the same: `/// caf\xe9` parses with 0 errors, and the result is `"doc": [99, 97, 102, …]`. The signature (200-byte cap) and field types (80-byte cap) take the same path.
- Fix: in `collapse`, step back to a UTF-8 boundary before appending `…`. Make every string headed for output valid UTF-8 (`std.unicode.utf8ValidateSlice`, replacing bad bytes with U+FFFD or `?`), in one helper that scan uses for doc, fileDoc, signature and field type.

### [high] `--root .` (or any un-normalised root) disconnects every import (Lens A)
- Where: src/main.zig:106 (path = `root ++ "/" ++ entry.path`, not normalised) against src/scan.zig:229 (`resolvePosix` normalises import targets), src/config.zig:188
- What goes wrong: with `--root .`, file paths are stored as `./src/core/a.zig`, but `@import("../ui/view.zig")` resolves to `src/ui/view.zig`. The lookup in `checks.run` misses, so every import is set to `resolved = null`. Fixture `rel/` has two layers and an upward import that forms a cycle. `--root src` gives `import_edges: 2`, 1 error and 2 warnings. `--root .` gives `import_edges: 0` and 0 findings: the layer violation and the import cycle are both missed. Layers stop matching too, because `src/ui` is not a prefix of `./src/ui/…`. Any root containing `./`, `//` or `..` in the middle hits the same mismatch.
- Fix: normalise each walked path the same way as import targets (`std.fs.path.resolvePosix(arena, &.{root, entry.path})`). Normalise `--root`, `--exclude`, `--layer`, `--forbid` and `--module` paths with that same function, instead of `trimSlash`.

### [high] Tuple structs get their types as field names, giving false duplicate_shape warnings (Lens A)
- Where: src/scan.zig:171-173
- What goes wrong: for a tuple-like field, `field.ast.main_token` is the type's token, so the field "name" is the type name. With `pub const T1 = struct { u32, u32, u8 };` and `pub const T2 = struct { u32, u8, u32 };`, the output is `warn: duplicate_shape: 2 structs have exactly the same fields (u32, u32, u8)`, although the two tuples have different layouts. `api.md` lists `T1 { u32: u32, u32: u32, u8: u8 }`.
- Fix: when `field.ast.tuple_like` is set, name the fields `0`, `1`, … (or skip tuples in `duplicateShapes`, since position is their identity).

### [high] Generic type functions are measured as one giant function, and their members are lost (Lens A)
- Where: src/scan.zig:134-191 (only `var_decl` containers are walked), src/scan.zig:257-299
- What goes wrong: `pub fn Queue(comptime T: type) type { return struct { items: []T, pub fn m1… m12 }; }` (12 three-line methods with 2 `if`s each) is reported as `complex_function: Queue has complexity 25`. `containers` is empty, so `api.md` shows no methods or fields for this std-style idiom. `long_function` and `thick_frontend` treat it the same way, and calls made by the methods are attributed to `Queue`. The clone finding in that fixture reports two "locations" of one function, `Queue` :4-33 and :34-63.
- Fix: in `addFunction`, when the return type is `type` and the body is `return <container_decl>;`, walk that container like `varDecl` does: name it after the function, collect its fields, and queue its `fn_decl`s with owner `Queue`. Then compute the generic's own metrics over its body without the container's tokens.

### [high] A clone is dropped when its first window is common boilerplate (Lens A)
- Where: src/clones.zig:99/112 (buckets over `max_bucket` are skipped) together with src/clones.zig:260 (a pair is skipped when its previous tokens match)
- What goes wrong: a pair is only reported from the window where the run starts. When that start window sits in a bucket of more than 48 entries, it is skipped, and every later window of the run is rejected by the "previous token matches" rule. Fixture `bucket2`: two functions `ca` and `cb` share a 209-token body. On their own, they give `warn: duplicate_fragment, 209 tokens`. Fixture `bucket` adds 50 unrelated functions that begin with the same ~100-token prefix, and then no duplicate_fragment is reported at all. In real code, any long copy that starts with common setup (allocator, `defer`, writer setup) is missed this way.
- Fix: apply the maximality skip only when the predecessor window was actually compared (its bucket is not over the cap). Alternatively, drop the skip, extend matches in both directions, and remove duplicates by (body, start) after extension.

### [medium] A missing or empty root still exits 0 with an empty atlas (Lens A)
- Where: src/main.zig:92-95, src/config.zig:188-191
- What goes wrong: `--root ./` and `--root /` are trimmed to `""`, and the run prints `cannot open root : FileNotFound`. A misspelt root prints a similar message. In both cases the run writes `0 files … 0 errors` over the previous outputs and exits 0, even with `--check`, so a broken `roots` entry in someone's `addAtlasStep` passes CI without anyone noticing.
- Fix: treat an unopenable root as a fatal error (exit 2), and keep `/` and `.` as they are when trimming.

### [medium] Overlapping roots scan a file twice and report it as a duplicate of itself (Lens A)
- Where: src/main.zig:86-117
- What goes wrong: with `--root src --root src/core`, every file under `src/core` is added twice. The output has `2 functions have the same body … src/core/s.zig:1-9 sum` listed twice. `index.put` overwrites the first entry, and ident counts double, which hides real `unused_pub` findings.
- Fix: after sorting, remove duplicate paths (once paths are normalised, see the `--root .` finding).

### [medium] The import-alias table ignores declaration order and scope (Lens A)
- Where: src/scan.zig:157-159 (one file-wide `aliases` map), :206-207, :338-339
- What goes wrong: (1) `const Peer = net.Peer;` placed before `const net = @import("net.zig");` is valid Zig, but `Peer` never becomes an alias, so `Peer.connect()` in `f` records no call. (2) An alias declared inside `const S = struct { const other = @import("other.zig"); };` is visible file-wide. `pub fn g(other: anytype) void { other.run(); }` then records a call to `other.zig:run` that does not exist. Both are reproduced in fixture `order/`. Wrong call edges feed `thick_frontend`, the "neither calls the other" test of `parallel_implementation`, and atlas.json.
- Fix: resolve aliases in two passes (collect the `@import` aliases first, then the dotted aliases, repeated until nothing changes, with a bound). Key aliases by owner container, and when scanning calls, ignore names that a parameter or local declaration shadows.

### [low] Re-export resolution produces duplicate call edges (Lens A)
- Where: src/scan.zig:53-57
- What goes wrong: `pkg.settings.info(); settings.info();` gives `calls: ["…/core/settings.zig:info", "…/core/settings.zig:info"]`. The deduplication runs before resolution, so `coreCalls` counts the same callee twice in the `thick_frontend` message.
- Fix: remove duplicates in `resolveCalls` after rewriting.

### [low] `@"quoted"` names do not match their plain uses (Lens A)
- Where: src/scan.zig:263 (name = raw token text), src/scan.zig:387
- What goes wrong: `pub fn @"hello"() void {}` in `b.zig`, called as `b.hello()`, is reported as `unused_pub`. The call edge `b.zig:hello` also does not match the function id `b.zig:@"hello"`.
- Fix: strip `@"…"` from identifier tokens whose content is a plain identifier, both in names and in `countIdents`.

### [low] `@import("x.zig",)` with a trailing comma is not an alias (Lens A)
- Where: src/scan.zig:203-213
- What goes wrong: `const t = @import("b.zig",);` is recorded as an import, but `aliasOf` lands on the comma and returns null, so `t.hello()` records no call.
- Fix: skip an optional `.comma` before the `)`.

### [low] `extern fn` prototypes are missing from the atlas and api.md (Lens A)
- Where: src/scan.zig:139 (only `.fn_decl` is collected)
- What goes wrong: `pub extern fn ext(a: c_int) c_int;` appears nowhere in `api.md` or in `functions`.
- Fix: list `fn_proto*` members as API entries (no body, metrics zero), or list them in api.md only.

### [low] The parse_error location is always line 1 (Lens A)
- Where: src/checks.zig:66, src/scan.zig:128
- What goes wrong: in a file whose first error is on line 3, the finding points to `x.zig:1`.
- Fix: store the line of `tree.errors[0].token` on the file and use it for the location.

### [low] An empty file counts as 1 line (Lens A)
- Where: src/scan.zig:490-497 with :125
- What goes wrong: an empty `x.zig` gives `"lines": 1`.
- Fix: `lines = if (source.len == 0) 0 else line_starts.len`.

### [low] Deeply nested containers crash the run (stack overflow in std.zig.Parse) (Lens A)
- Where: src/scan.zig:39
- What goes wrong: 1000 nested `const A = struct {` declarations abort the whole run (exit 134), and the stack overflows inside `std.zig.Parse`. The input is valid Zig but unrealistic. The run aborts without writing any output, and `walkMembers`/`varDecl` recurse without a bound as well.
- Fix: parse on a thread with a larger stack, or count `{` depth before parsing and report the file instead of parsing it.

## Checked and sound
- Files with parse errors (top-level and statement-level) give a partial atlas with the functions that survived, plus a `parse_error` finding, and no crash.
- `\r\n` line endings and missing trailing newlines give correct lines, end lines, docs and annotations.
- A multiline string containing `@import("ghost.zig")` is not taken as an import. `@import(name)` with a non-literal argument is ignored without error.
- `export fn`, `pub extern fn` and `fn` types in struct fields cause no crash and no bogus functions. `is_export` is set correctly.
- Token look-ahead is guarded in `aliasOf` (`t + 3 > last`, `t < last`), in `collectImports` (`i + 2 < len`, `i >= 3`) and in `calls` (`j + 2 <= last`, `j + 1 > last`).
- AST accessors are used on the right tags: `fullVarDecl`, `fullContainerDecl`, `fullContainerField`, `fullFnProto`, and `nodeData(fn_decl).node_and_node`.
- Integer subtraction is safe: `end_line - line + 1`, `body_last - body_first + 1`, the Jaccard `all`, the fragment `lines`, and the `-|` in `metrics`. Each `@intCast` operates on values bounded by the 64 MiB read limit or by list lengths.
- No pointer is held into a list that later grows: in tarjan, `top` is used before `call.append` and fetched again on each iteration. Exported alias maps are copied after they are complete.
- Output is deterministic: two runs on zigatlas `src` and two on nomadfs `src` (78 files, 1261 functions) produced byte-identical output. Grouping maps are array hash maps or are sorted afterwards, and `std.mem.sort` is stable.

## Not covered
- Memory, Power of 10 and design (Lens B, C and D), except where they overlap with the findings above.
- I did not run `zig build test` or `zig fmt --check`.
- No before/after finding counts on nomadfs, because nothing was changed.
- Not tested: unreadable files, symlinked `.zig` files (the walker skips them), `@atlas` text inside string literals, Mermaid/DOT escaping of odd paths, and files larger than 64 MiB.
