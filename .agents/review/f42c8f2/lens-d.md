# Lens D: design, the build API and trust in findings (re-review of f42c8f2)

Scope: `git diff 46c1751 f42c8f2 -- src build.zig README.md` and the code around each change.
f42c8f2 was built on its own from `git archive` (`/tmp/za-r2-d/new`), because the working tree
has uncommitted edits to `src/checks.zig`, `clones.zig`, `main.zig` and `scan.zig` that are not
part of this review. Every finding below was reproduced with that binary
(`/tmp/za-r2-d/new/zig-out/bin/zigatlas`) on fixtures under `/tmp/za-r2-d/<case>/`. The build-API
findings use consumer projects with a path dependency on the repository. Its `build.zig` and
`config.zig` match f42c8f2.

f42c8f2: `zig build test` exits 0. The "a misspelt rule is rejected" test prints the usage text
to stderr, so the log shows `failed command:` lines even though the run passes.
`zig fmt --check src build.zig` is clean. Self-atlas: 7 files, 145 functions, 0 errors,
0 warnings, 9 notes.

Verdict for this lens: **approve with changes**. Most v0.1.0 findings are fixed. Two new
behaviours give wrong results in ordinary setups:
- module scoping by directory resolves an import to the wrong module's file;
- the "ignore the lowest layer" rule turns `thick_frontend` off for any two-layer project.

---

### [high] Two modules whose roots share a directory: an `@import` name resolves to the first module's file (Lens D)
- Where: build.zig:149-156 (`addModuleArgs`: scope = `dirname(root)`), src/config.zig:79-93 (`moduleFor`: on equal scope length, the first match wins)
- What goes wrong: fixture `/tmp/za-r2-d/modscope`. Two executables have their roots in `src/`: `server` (`src/server.zig`) does `addImport("backend", impl_a)`, and `tool` (`src/tool.zig`) does `addImport("backend", impl_b)`. `addAtlasStep` passes `--module backend=src/impl_a/root.zig@src --module backend=src/impl_b/root.zig@src`. Both files' `@import("backend")` resolve to `src/impl_a/root.zig`. The rule `src/tool.zig` must not import `a` then fails `--check` with `forbidden_import: src/tool.zig imports src/impl_a/root.zig`, which is false. The real edge `tool → impl_b` is missing. Several executables, benches and test roots sitting side by side in `src/` is the normal layout (nomadfs has `src/main.zig`, `src/root.zig` and its test roots there). Nothing warns that the two scopes are ambiguous.
- Fix: scope by module, not by directory. Pass the importing module's root file (`--module NAME=PATH@ROOTFILE`), and in the scanner give each module root's import table to the files that root reaches through relative imports. At the least, when two `--module` entries share a name and a scope but point to different files, print a warning and leave the import unresolved instead of picking the first. Add a test for this case.

### [high] `thick_frontend` can never fire in a project with two layers (Lens D)
- Where: src/checks.zig:262-266 (`if (to_i == li or to_i == cfg.layers.len - 1) continue;`)
- What goes wrong: fixture `/tmp/za-r2-d/thick`. `src/cli/main.zig:handle(svc: *core.Service, …)` has complexity 12 and calls `svc.charge` and `svc.refund`.
  - With `--layer cli=src/cli --thin cli --layer core=src/core --layer base=src/base` it is reported.
  - With the two-layer setup `--layer cli=src/cli --thin cli --layer core=src/core,src/base`, `core` is the lowest layer, so every call is skipped and 0 `thick_frontend` findings appear.

  "Front end over core" is the smallest useful layering, and the case this check exists for. Nothing tells the user the check is off. README's row ("the lowest holds helpers") does not say so either.
- Fix: skip the lowest layer only when there are at least three layers, or better, mark helper layers explicitly (`Layer.utility`, as v0.1.0 suggested) and skip only those. Add a must-report test with two layers.

### [medium] `thick_frontend` counts std calls on a field of a typed parameter as "driving the core", and misses an optional parameter after unwrapping (Lens D)
- Where: src/scan.zig:560-586 (`calls`: any `param.a.b(` chain becomes `file:Type.a.b`), src/scan.zig:620-641 (`typeAlias`)
- What goes wrong (fixture `/tmp/za-r2-d/thick`):
  - `src/cli/parse.zig:parseArgs(gpa, cfg: *core.Config, args)` only parses flags. Its one call through `cfg` is `try cfg.names.append(gpa, a)`, where `names` is a `std.ArrayList` field. That call is recorded as `src/core/svc.zig:Config.names.append`, an id that is not a function in the atlas. The finding reads "parseArgs … has complexity 11 and drives the core (src/core/svc.zig:Config.names.append)". Front ends that fill a core-typed options struct are exactly what "pure parsing is not reported" promises not to flag.
  - `handleOpt(maybe: ?*core.Service, …)` with `const svc = maybe orelse return; svc.charge(1)` records no calls and is not reported. The same happens with `var svc = core.Config.make(); svc.charge(…)` and `var svc: core.Service = …`, because a typed local is treated as a shadow.
- Fix: through a typed parameter, count only `param.method(` (one segment), and only when `Type.method` exists in the atlas's functions. Check that in `resolveCalls` and drop call ids that resolve to nothing. Track one level of `const x = param orelse …` / `param.?`, and typed locals (`var x: alias.Type`).

### [medium] `duplicate_fragment` hides real in-function copies: adjacent copies and three or more copies (Lens D)
- Where: src/clones.zig:188-194 (`len >= period or sameBodyCount(bucket, pa.body) >= 3`)
- What goes wrong: fixtures `/tmp/za-r2-d/frag/one_*`, each one function in its own run, `--min-clone-tokens 30`:
  - `one_two`: two copies of a 9-line `for` block with one statement between them. Reported (lines 4 and 13). Correct.
  - `one_adjacent`: the same two blocks placed back to back. 0 findings. The second copy starts where the first ends, so the run length equals the period.
  - `one_three`: three copies separated by `std.debug.print` lines. 0 findings, because the start window occurs 3 times in the body.

  Copy-pasting a block for `xs`, `ys` and `zs` in one function is the most direct form of duplication, and it is now invisible. README says the rule skips "the repeating rows of one if/else or switch chain", but these copies are not chain rows. The only test added is the must-not case.
- Fix: decide "chain rows" from the syntax, not from the period. Drop a same-function pair only when both ranges lie inside the same `if`/`else if` chain or the same `switch` (scan.zig can record those token ranges per body), or when the period is shorter than about one statement (`period < k / 2`). Add must-report tests for adjacent and triple copies.

### [medium] `duplicate_function` still merges methods that call different helpers, and merges callers of same-named helpers that do different things (Lens D)
- Where: src/scan.zig:248-251 and 286-288 (`file_names` is filled only when `owner.len == 0`), src/scan.zig:670-676 `identHash`
- What goes wrong:
  - Fixture `/tmp/za-r2-d/clonehash/src/svc.zig`: the v0.1.0 `logged`/`sent` case, moved into `pub const Service = struct { … }`. `logged` calls the container's `stepA` and `writeLog`, and `sent` calls `stepB` and `sendPacket`. They are still reported as "2 functions have the same body … keep one and call it". Container-scope helpers are erased like locals, and most Zig code lives in containers. The previous finding is fixed only at file scope. README says "The functions they call must match".
  - Fixture `/tmp/za-r2-d/samename`: `src/p/a.zig` has `fn ok(v) bool { return v > 10 and v < 500; }` and `src/q/b.zig` has `fn ok(v) bool { return v % 2 == 0; }`. Their callers `countGood` and `countEven` loop the same way and are reported as the same body: "keep one and call it". Keeping one changes behaviour. Names are kept as text, but a file-local name means a different function in each file.
  - The opposite case, fixture `/tmp/za-r2-d/clonehash/src/{x,y}`: `total` is the same in both files except that it calls `clampA` or `clampValue`, whose bodies are identical. It is no longer a `duplicate_function`. It still shows as `parallel_implementation` only because the callers share a name, and as a 26-token fragment that is below the default threshold of 60.
- Fix: record container-scope declaration names per owner and keep them in hashes as well. For calls to non-`pub` file-local functions, hash the callee by its normalised body (one level), not by its name. Then renamed identical helpers match and same-named different helpers don't. The `duplicate_function` message still says "apart from local names and literals". Make it say what is erased ("local names, type names and literals").

### [medium] With layers configured, directory loops inside one layer are no longer reported (Lens D)
- Where: src/checks.zig:197 (`suspect = upward or !layered(f) or !layered(target)`)
- What goes wrong: fixture `/tmp/za-r2-d/dircycle`. `src/net/a/x.zig` imports `../b/y.zig`, and `src/net/b/y.zig` imports `../a/w.zig`. With no layers, the loop is reported (good: the "no layers" case still works). With `--layer app=src/app --layer net=src/net`, it disappears, because every edge is same-layer, so not "up". The v0.1.0 noise came from edges that point down between layers. Same-layer edges are a real tangle. In nomadfs, `src/storage/engine.zig → src/storage/dag/codec.zig` and `src/storage/dag/builder.zig → src/storage/engine.zig` form a storage ↔ storage/dag loop inside one layer. It is hidden today inside the 9-directory loop, and it would vanish once `rpc.zig → node_info.zig` is fixed. With no layers, the message says the imports "go up a layer or leave the layers", which is confusing when there are no layers.
- Fix: count an edge as suspect unless it goes strictly down a layer (`to_i > from_i`). A parent `mod.zig` that only re-exports its children can be skipped to keep the loop down to real tangles. Give the no-layer case its own message. Add a must-report test for a same-layer loop.

### [medium] `addAtlasStep` called before the modules are defined silently drops all module imports, and `--check` passes (Lens D)
- Where: build.zig:103-109 (doc comment), build.zig:143-158 (`addModuleArgs` runs at configure time)
- What goes wrong: fixture `/tmp/za-r2-d/early` is the v0.1.0 consumer with `addAtlasStep` moved to the top of `build()`. `zig build atlas -- --check` reports "0 errors, 0 warnings" and exits 0. Both `@import("app")` and `@import("core")` are unresolved (`resolved` is absent in atlas.json), so the upward import goes unreported. When it is called last, the same project gives 1 `layer_violation`. README says to call it last, but the failure is silent and looks like a clean architecture. A helper function, a conditional `if (b.option(…))` module or a later `addTest` hits the same problem.
- Fix: collect the modules at make time. Add a small custom step that `run` depends on, whose `makeFn` walks the graph and appends the `--module` arguments to `run` before it executes (*unverified that `Run` accepts arguments added then*). Failing that, have the tool print the bare `@import` names it could not resolve (not `std`, `builtin`, `root`, `build_options`), so a missing module is visible.

### [medium] `unused_pub` counts declarations in vendored code and fixtures as uses (Lens D)
- Where: src/main.zig:66-71 (usage walk of `.`), src/scan.zig:91-101 `countUsage` (every identifier, including declaration names), src/main.zig:19 (only `zig-out`, `zig-cache`, `zig-pkg`, `node_modules`, `build` and dot-directories are skipped)
- What goes wrong: fixture `/tmp/za-r2-d/usage`. `src/a.zig` has `parseHeader`, `checksum` and `neverUsed`, none of them called anywhere. `vendor/zlib/inflate.zig` declares its own `pub fn parseHeader`, and `testdata/fx/input.zig` declares `pub fn checksum`. Only `neverUsed` is reported; with `--exclude vendor --exclude testdata` all three are. Before f42c8f2, usage was counted only inside the roots. Now any `.zig` under the build root counts: `vendor/`, `third_party/`, `deps/`, `testdata/`, generated files and sibling projects (nomadfs counts `nomadfs-gui/`). A declaration of the same name counts as a use. README says only "Every `.zig` file under the build root counts (tests, tools)", without the skipped directories or that `--exclude` also limits counting.
- Fix: in `countUsage` (and `countIdents`), skip identifiers right after `fn`, `const` and `var` and field names in declarations, so only references count. Document the skip list and that `exclude` applies to counting. Consider skipping `testdata`, `vendor` and `third_party` by default.

### [low] deps.mmd labels a directory with only its first two layers, and still draws empty layer groups (Lens D)
- Where: src/render.zig:313-323
- What goes wrong: once a directory is marked mixed (`gop.value_ptr.* = ""`), the `gop.value_ptr.len > 0` test stops any further layer from being added to its label. nomadfs `src/` holds frontend (`main.zig`), node and base files and is drawn as `src (base, node)`, so `frontend` is missing. Layers are matched by substring (`indexOf(label, layer)`), so a layer named `net` is never added after `network`. A directory whose first file has no layer never becomes mixed. The `node`, `device`, `identity` and `base` subgraphs are still drawn empty in nomadfs.
- Fix: keep a set of layers per directory and join it at the end. Skip subgraphs with no nodes.

### [low] `--module` paths containing `@` are split wrongly (Lens D)
- Where: src/config.zig:217-223 (`lastIndexOfScalar(rest, '@')`), build.zig:174-177
- What goes wrong: `--module 'lib=src/v@2/root.zig'` (fixture `/tmp/za-r2-d/at`), which `addAtlasStep` emits for a public module, parses as path `src/v` with scope `2/root.zig`. `@import("lib")` is left unresolved.
- Fix: put the scope in its own argument (`--module NAME=PATH --module-scope DIR`), or always emit a scope and split on the first `@` after the last `/` of the path.

### [low] A `//!` inside a nested container sets the whole file's layer and its `allow` (Lens D)
- Where: src/scan.zig:757-765 `headerAnnotation` (scans every line starting with `//!`, not only the file header)
- What goes wrong: fixture `/tmp/za-r2-d/hdr`. `src/b/low.zig` (layer `low`) imports `../a/top.zig` (layer `top`). Inside `pub const Inner = struct { //! @atlas layer: top … }`, the struct's own doc moves the whole file to layer `top`, so the upward import is not reported. `//! @atlas allow:` inside a struct likewise mutes the file's `large_file`, which README describes as a header annotation.
- Fix: read only the leading run of `container_doc_comment` tokens at the start of the token list, as `fileDoc` does.

---

## Previous findings re-checked (v0.1.0 lens-d.md)

| v0.1.0 finding | status | evidence |
|---|---|---|
| Module auto-detection misses private and renamed modules | **partly fixed** | The consumer now gets 2 `layer_violation` (`/tmp/za-lens-d/consumer`). Modules that share a directory resolve to the wrong file (new high), and a call made too early is silent (new medium) |
| `--root .`, `./`, absolute, missing root | fixed | `/tmp/za-lens-d/dotroot`: `.`, `./`, absolute and `src` all give 1 error and 2 warnings; `nosuch` exits 2. Windows not run |
| Methods of generic types invisible | fixed | `kinds`: `Pool.unusedA` and `Pool.unusedB` are listed and measured |
| `unused_pub` false positives (tests, std hooks) | fixed | nomadfs: all 14 checked by `grep -rw`; only `lookupValue` appears elsewhere, in a comment in `tests/dht/store_test.zig`. Common names are now documented as never reported. Widening the search added false negatives (new medium) |
| `thick_frontend` misses values and local imports, flags base helpers | fixed | `kinds` `handle` and `misc` `show` are reported; a call into base is no longer counted; the message lists the calls. New problems: two layers (high) and field calls (medium) |
| `duplicate_function` erases called function names | **partly fixed** | Fixed at file scope. Methods calling different container helpers still merge, and same-named different helpers merge (new medium) |
| `parallel_implementation` unrelated same names, split copies | **partly fixed** | `nowSeconds` is one finding pointing at the `pub` copy in `src/root.zig`. nomadfs `message()` (`device/policy.zig:78`, `device/rotation.zig:21`), which v0.1.0 showed are different layouts, is still reported at 67% |
| `duplicate_fragment` reports rows of a dispatch chain | fixed, over-corrected | Chain rows are gone. Adjacent and triple real copies are now hidden too (new medium) |
| Failing `--check` does not say what failed | fixed | Consumer prints `file:line: error: layer_violation: …` |
| Typos in layer names accepted silently | fixed | `--forbid botom:top` exits 2; `@atlas layer: storge` gives `unknown_layer` and falls back to the path's layer |
| `parse_error` always line 1 | fixed | `cfg/src/a/bad.zig:6` |
| deps.mmd puts a directory in its first file's layer | **partly fixed** | Mixed directories are drawn outside the groups. The label drops a third layer and empty groups remain (new low) |
| Directory `import_cycle` noise with file-level layers | fixed, over-corrected | nomadfs now points at `rpc.zig:10`. Same-layer loops are hidden (new medium) |
| Path normalisation in four places | fixed | `--module core=./src/core/root.zig@./src/app` resolves; one `normalizePath`. Windows not run |
| No tests for most kinds, the CLI and renderers | **partly fixed** | 28 unit tests and 2 CLI fixtures; each kind has a report and a must-not test. Still no must-report test for in-function fragments, two-layer `thick_frontend`, same-layer directory loops, or `addModuleArgs` / module scoping |
| Defaults and Layer/Rule written in four places | fixed | `build.zig` aliases `config.Layer`/`Rule`/`Module` and takes its defaults from `config.Config{}`; `usage` uses `comptimePrint`. README still writes "60" and "10" by hand |
| CLI holds `findingOrder` and `stats` | fixed | `checks.sortFindings`, `model.Stats.compute`, `model.countBySeverity` |
| Overlapping roots scanned twice | fixed | `collectFiles` deduplicates |
| Nesting depth counts struct literals | fixed | `misc` `lit` depth 0 |
| `duplicate_shape` chains transitively and lists wrong fields | fixed | `cfg/shapes.zig`: one pair with the shared fields; C is not chained |
| Small doc and contract mismatches | fixed | `name` doc, `--check [info|warn|error]`, plural, allow scope in README, `schema` and `layers` in JSON, conditional re-exports (`fuse.unmount` now resolves to `src/fs/fuse.zig`) |

Previous findings not fully fixed: **5** (module detection, `duplicate_function`,
`parallel_implementation`, deps.mmd, tests). Two more were fixed but over-corrected into new
false negatives (`duplicate_fragment`, directory `import_cycle`).

## Checked and sound

- Build API compatibility: `Layer` (= `model.Layer`: `name`, `paths`, `thin = false`) and `Rule` keep the v0.1.0 fields and defaults. `Options` only gained `usage_roots` and `modules`, both defaulted. `Module.scope` defaults to `""`. The v0.1.0 consumer `/tmp/za-lens-d/consumer` compiles unchanged; `zig build atlas` and `zig build atlas -- --check` work (exit 1 with 2 printed findings). `build.zig` importing `src/config.zig` compiles inside a consumer's build runner.
- Module discovery from compile steps reached from `b.top_level_steps` (install and test), `createModule` plus `addImport` under another name, and imports in both directions. Modules that are not this build's source files (dependencies, generated roots, `build_options`) are skipped.
- JSON: comparing every key path of atlas.json between 46c1751 and f42c8f2 (fixture `kinds`) shows nothing removed. Added: `schema`, `layers`, `files[].parse_error_line`, `files[].parse_note`, `functions[].is_extern`, `containers[].tuple`; `files[].allowed` appears only when set (`emit_null_optional_fields = false`). The new `unknown_layer` kind is additive. `calls` ids can now be dangling (see the field-call finding).
- `import_cycle` with no layers configured still reports directory loops.
- The usage walk skips `zig-pkg` and dot-directories (nomadfs `.claude/worktrees` copies are not counted).
- Spot-checked nomadfs `thick_frontend` (`remoteDevices`, `fileDetails`, `mountStart`) call into `src/fs`, a non-lowest layer, as reported. The 14 `unused_pub` match `grep -rw`.
- README: the Output, Annotations, exit codes, path spellings and `--check` output match the code, apart from the points raised above.

## Not covered

- Windows paths (`\` handling was reasoned about, not run).
- A full before/after count comparison on nomadfs. Its `zig-out/atlas` was produced by its own `zig build atlas` while nomadfs is being edited. My CLI run on nomadfs (into `/tmp/za-r2-d/nfs`) used hand-written module arguments, so its counts are not comparable.
- Whether `Run` accepts arguments appended at make time (the suggested fix for the call-order finding).
- Lenses A, B and C, and the uncommitted working-tree changes in `src/`.
- Side effect: I ran `zig build atlas` and `zig build test` once in the repository, before noticing the uncommitted changes. That regenerated `zig-out/atlas/` (build output) from the working tree. No source file was touched.
