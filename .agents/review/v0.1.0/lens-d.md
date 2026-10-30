# Lens D: design, the build API and trust in findings (zigatlas v0.1.0)

Scope: the whole project at `46c1751` (`main`): `build.zig`, `src/*.zig`, README.md.
Each finding was checked by running `zig-out/bin/zigatlas` on a fixture under
`/tmp/za-lens-d/<case>/`, by a consumer project that uses `addAtlasStep`
(`/tmp/za-lens-d/consumer`), or against nomadfs's `zig-out/atlas/` and the nomadfs source.

Self-atlas (`zig-out/atlas/ATLAS.md`): 7 files, 85 functions; 0 errors, 1 warn
(`thick_frontend` on `src/main.zig:main`), 8 info (1 duplicate_fragment, 1 long_function,
5 complex_function, 1 many_params). No layer breaks. `zig build test` passes;
`zig fmt --check src build.zig` is clean.

Verdict for this lens: **approve with changes**. The pipeline layers are sound. But two
inputs that real projects use (a private or renamed module, `--root .`) silently turn off
layer checking. Several finding kinds also produce false positives often enough to mislead
an agent that acts on them.

---

### [high] Module auto-detection misses private modules and renamed imports, so their layer breaks are never reported (Lens D)
- Where: build.zig:99-104 (and src/scan.zig:222-231 `resolveImport`)
- What goes wrong: `addAtlasStep` passes `--module` only for `b.modules`, the modules created with `b.addModule`, and uses the registry key as the import name. Consumer `/tmp/za-lens-d/consumer`: `const core = b.addModule("consumer", …src/core/root.zig)`, `const app = b.createModule(…src/app/main.zig)`, `app.addImport("core", core)`, `core.addImport("app", app)`, layers `app` (thin) above `core`. In `src/core/root.zig`, `@import("app")` is an upward import, and `@import("core")` in main.zig is an ordinary edge. atlas.json shows `{"target":"app","resolved":null}` and `{"target":"core","resolved":null}`, and the run reports **0 errors**. `createModule` plus `addImport` under another name is the usual way to wire an executable (nomadfs uses `createModule` for `test_helpers`, `lib_mod` and the exe root module). The README says only "public modules (`b.addModule`) are passed automatically".
- Fix: walk the build graph. Start from every module owned by `b`: `b.modules`, plus the `root_module` of each `Compile` step reachable from `b.top_level_steps`. Emit one `--module NAME=PATH` for each entry of each module's `import_table` whose root source file is a `src_path` owned by `b`. Then `@import` names resolve the way the compiler resolves them. If one name maps to two files, pass the importing module's root as well (`--module FROM:NAME=PATH`). Add a `modules: []const Module = &.{}` field to `Options` for manual cases.

### [high] `--root .`, `--root ./` or an absolute root silently disables layers and import resolution (Lens D)
- Where: src/main.zig:106 (path = `root/entry`), src/config.zig:188-191 `trimSlash`, src/config.zig:72 `pathHasPrefix`, src/scan.zig:229 `resolvePosix`
- What goes wrong: fixture `/tmp/za-lens-d/dotroot` has `src/core/store.zig` and `src/ui/view.zig` importing each other, with layers `ui=src/ui` and `core=src/core`.
  - `--root src`: 1 error (layer_violation) and 2 warnings (cycles). Correct.
  - `--root .`: file paths become `./src/core/store.zig`, which no layer matches (`layer: null`). Imports resolve to `src/ui/view.zig` (resolvePosix drops `./`), which is not in the file index, so `resolved` is set to null. Result: **0 errors, 0 warnings**, and `--check` exits 0.
  - `--root ./`: `trimSlash` turns it into `""`. The tool prints "cannot open root : FileNotFound" and scans 0 files.
  - An absolute `--root /tmp/…/src` gives absolute file paths, so relative `--layer` paths never match.
  - A root that does not exist (`--root nosuch --check`) also exits **0**, so a typo in CI passes the gate.
  - `.roots = &.{"."}` (to include `build.zig` or `tools/`) is a natural `Options` value.
- Fix: normalise every path once, in one helper in config.zig: make it relative to the cwd, drop `./`, collapse `.`, use `/` separators. Apply it to roots, file paths (main.zig:106), layer paths, excludes, forbid paths and module paths. A root that cannot be opened, or a run that finds 0 files, should be an error (exit 2).

### [high] Methods of generic types (`fn T(comptime …) type { return struct {…} }`) are invisible; the whole type is reported as one function (Lens D)
- Where: src/scan.zig:134-148 `walkMembers` (only container members are walked), src/scan.zig:257 `addFunction`
- What goes wrong: nomadfs `src/fs/inode_table.zig:7` `pub fn Table(comptime T: type) type { return struct { … pub fn init … pub fn deinit … } }` is reported as `long_function` warn "Table is 195 lines" and `complex_function` warn "Table has complexity 41, nesting 5". Its methods have no metrics, no api.md entries and no unused_pub check. Fixture `kinds/src/core/service.zig`: `Pool(T)` with `unusedA` and `unusedB` produces one function `Pool c=3 lines=14`, and the methods do not appear. Generic containers are common in Zig, so every one of them yields a wrong hotspot and hides its own API.
- Fix: in `addFunction`, when the body's `return` operand is a container declaration (or the function returns `type`), walk that container's members with owner `Name(T)` the way `varDecl` does. Compute the outer function's metrics without those members.

### [high] `unused_pub` says "delete it" for functions used by tests, by std reflection and by consumers (Lens D)
- Where: src/checks.zig:211-221 `unusedPub` (name count over scanned roots only)
- What goes wrong:
  - On nomadfs, 6 of the 19 `unused_pub` findings are used from `tests/`, which is outside `roots`: `SwarmFolder.backupRound`, `Node.lookupValue`, `Node.sendRevoke`, `NodeID.fromData`, `ConnectionManager.getConnection`, `UPnP.initForTest` (`grep -rw` finds each in `tests/**`). Deleting them breaks the integration tests.
  - Fixture `kinds`: `pub fn jsonStringify` (called by `std.json`) and `Ctx.hash` (a `std.HashMap` context) are reported. `Ctx.eql` escapes only because `std.mem.eql` appears elsewhere.
  - False negatives: `Service.get`, which is never called, is not reported because `m.get(...)` exists. Any common name (`init`, `get`, `put`, `run`) can never be reported.
- Fix: count identifiers in every `.zig` file under the build root, including `tests/` and `build.zig`, not only the roots. Do this as a separate counting-only walk, or add an `Options.usage_roots`. Extend the `main`/`format` skip list to the std hooks (`jsonStringify`, `jsonParse`, `jsonParseFromValue`, `hash`, `eql`, `lessThan`, `panic`). Treat files reached from a module root through `pub const x = @import(…)` as public API. Reword the message: "its name appears nowhere else in the scanned files; if nothing outside calls it, delete it or make it private".

### [high] `thick_frontend` misses logic that reaches the core through values or function-local imports, and flags parsers that call a base helper (Lens D)
- Where: src/checks.zig:200-209 `coreCalls`, src/checks.zig:186-195, src/scan.zig:330-356 `calls` (only file- and container-scope aliases; `varDecl` is not run inside function bodies)
- What goes wrong:
  - Fixture `kinds/src/cli/main.zig`: `handle(svc: *core.Service, …)` has complexity 12 and makes its decisions by calling `svc.charge(n)` and `svc.refund(n)`. Not reported (`calls=[]`).
  - Fixture `misc/src/ui/view.zig`: `show` (complexity 12) does `const core = @import("../core/svc.zig"); core.decide(n)` inside the function. Not reported (`calls=[]`).
  - `parseArgs` is pure flag parsing whose only cross-file call is `util.trim` in the `base` layer. It **is** reported: "makes 1 calls into the core".
  - On nomadfs, `mountStart` and `benchReadCommand` count `sync.sleep` and `sync.monotonicMillis` (base) as "calls into the core".
  - The self-atlas lead on `src/main.zig:main` is the same false positive: SKILL.md says the CLI owns "running the stages … exit code", and its 9 calls are the stage calls.
- Fix: record function-local import aliases (run `aliasOf` on `simple_var_decl` inside bodies). Resolve `param.method(` when the parameter's type is `alias.Type` or `*alias.Type`. Count only calls into layers that are not the lowest (or that are not marked `base`/`util`), or let a layer opt out with a `Layer.utility` field. Say which calls in the message ("calls core.Service.charge, …"). Fix "1 calls".

### [medium] `duplicate_function` erases the names of called functions, so different code is "the same body" (Lens D)
- Where: src/scan.zig:369 (an identifier not after `.` hashes to `0x1d`)
- What goes wrong: fixture `kinds/src/core/service.zig`, with `--min-fn-tokens 20` because the bodies are 38 tokens and the default threshold is 40. `logged` calls `stepA` and `writeLog`; `sent` calls `stepB` and `sendPacket`. They are reported as "2 functions have the same body … apart from local names and literals; keep one and call it". `stepA`, `writeLog` and the other free-function names are not local names. Type names (`u32` vs `u64`) are erased the same way.
- Fix: keep the hash of an identifier that resolves to a file-scope declaration or an import alias (the scanner already knows `aliases` and could collect top-level decl names). Erase only parameters and locals. At the least, change the message to "same shape; the called functions may differ".

### [medium] `parallel_implementation` flags unrelated functions that share a name, and splits copies across findings (Lens D)
- Where: src/clones.zig:169-219 `sameName` (bigram Jaccard over normalised tokens ≥ 0.5)
- What goes wrong:
  - nomadfs reports `message()` in `src/device/policy.zig:78` and `src/device/rotation.zig:21` as "73% alike; keep one". They build two different signed-message layouts (different fields, different domains). After normalisation, `@memcpy` and `std.mem.writeInt` bigrams make any two serialisers look alike.
  - `nowSeconds` has 4 copies. Two (`device/invite.zig`, `root.zig`) are a `duplicate_function` group, so `group[bi] != 0` excludes them. The other two (`fs/shares.zig`, `main.zig`) are reported separately, and the message does not mention that `root.zig` already exports a public `nowSeconds`.
  - The "neither calls the other" check only sees alias calls.
- Fix: compare bodies with literal kinds and callee names kept (see the previous finding), and require a minimum size (≥ 20 tokens). Report a name once, listing the whole-function duplicates among its locations. Point at the `pub` copy, if there is one, as the one to keep.

### [medium] `duplicate_fragment` reports the repeating rows of a single dispatch chain as copies (Lens D)
- Where: src/clones.zig:247-267 `pairMatch` (same-body matches), src/clones.zig:142 (`controlTokens` filter)
- What goes wrong:
  - nomadfs `src/config.zig:294-298` vs `298-302` (the same `applyConfigEntry` else-if chain; the ranges share line 298).
  - nomadfs `src/fs/device_names.zig:78-80` vs `80-82` (`formatCand` switch prongs that differ only in a literal).
  - Fixture `kinds` `parseArgs` lines 25 vs 30 (`if (eql(a, "-x")) flags |= N` rows).
  - Each is reported as "extract a shared helper". The filter that skips "tables" counts `if`, `try` and `return`, so if-chains pass it.
- Fix: for matches inside one function, drop runs where `hi - lo` (the period) is shorter than the run (periodic repetition), or require the two ranges to be separated by at least one statement that does not match. Report table-like repetition as one finding ("N similar rows; consider a table").

### [medium] A failing `--check` does not say which findings failed (Lens D)
- Where: src/main.zig:71-81
- What goes wrong: `zig build atlas -- --check` in the consumer prints only "zigatlas: 1 findings at error or above" and the build failure. In CI the reader has to fetch `zig-out/atlas/ATLAS.md` to learn what broke.
- Fix: print each failing finding to stderr as `file:line: kind: message`. Cap it, for example at 50, with "… N more".

### [medium] Typos in layer names are accepted silently and switch checks off (Lens D)
- Where: src/config.zig:138-142 (`--forbid` not validated), src/scan.zig:119 (`@atlas layer:` not validated), src/render.zig:68-107
- What goes wrong: fixture `cfg`. `--forbid "botom:top"` is accepted and never matches. `//! @atlas layer: storge` gives `src/b/y.zig` the layer `storge`, so layer checks skip the file (`layerIndex` is null). The file also disappears from the ATLAS.md layer table: only `top` is listed, with "imports into storge 1". `--thin` with an unknown layer is already rejected (config.zig:175), so the other two are inconsistent with it.
- Fix: reject a `--forbid` side that is neither a layer name nor a path prefix of some root. Emit a finding (or a stderr error) for an `@atlas layer` value that is not a configured layer. Add an "(unknown)" row to the layer table.

### [medium] `parse_error` always points at line 1 (Lens D)
- Where: src/checks.zig:63-68
- What goes wrong: fixture `cfg/src/a/bad.zig` has `pub fn broken( void {` on line 6. The finding is "2 parse errors; the file was only partly analysed @ src/a/bad.zig:1". The reader cannot tell where the error is.
- Fix: carry the first error's token line from `tree.errors[0].token` into `File` (for example `parse_error_line`). Use `tree.renderError` for the message.

### [medium] deps.mmd puts a directory in the layer of its first file; layers come out empty (Lens D)
- Where: src/render.zig:285-289
- What goes wrong: in nomadfs `deps.mmd`, the `src` directory (which holds `main.zig` in frontend, `root.zig` and `node.zig` in node, and `config.zig` and `sync.zig` in base) is drawn inside `base`. `src/device` (device plus identity) is drawn inside `identity`. The `node` and `device` subgraphs are empty. README calls the graph "grouped by layer".
- Fix: group nodes by (directory, layer) pair, or draw a directory with more than one layer outside any subgraph and label it with its layers.

### [medium] The directory-level `import_cycle` is noise when layers are configured by file (Lens D)
- Where: src/checks.zig:129-160 `dirCycles`
- What goes wrong: nomadfs reports one 9-directory loop ("src/cluster, src, src/device, … pick which one is lower"). It exists because `src/` holds both the base files (`sync.zig`, `config.zig`, `errors.zig`) and the front end. Example edges are `src/cluster/fetcher.zig:20 → src/sync.zig` and `src/cluster/block_manager.zig:4 → src/net/id.zig` (layer base). The layers are respected; only directories loop, and no directory can be "picked as lower".
- Fix: when layers are configured, compute the cycle at the layer level, which `layer_violation` already covers, or skip directory cycles whose edges all go to layered files that point downward. Otherwise list only the edges that close the loop.

### [medium] Path normalisation lives in four places and is inconsistent (Lens D)
- Where: src/config.zig:188 `trimSlash` (roots, excludes, layer paths, forbid), src/config.zig:143-145 (modules: not trimmed), src/main.zig:107 (`\` → `/` for file paths only), src/scan.zig:229 `resolvePosix`
- What goes wrong: `--module core=./src/core/root.zig` leaves `@import("core")` unresolved (`resolved` is missing), while `core=src/core/root.zig` resolves. `b.path("./src/root.zig")` produces that form. Layer paths written with `\` (Windows) are never converted. This is the same root cause as the `--root .` finding. *(The Windows part is unverified on Windows.)*
- Fix: the single normaliser proposed in the `--root .` fix, used for every path that enters `Config`.

### [medium] No tests for most finding kinds, the CLI or the renderers (Lens D)
- Where: src/checks.zig (tests only tarjan and the layer and forbid checks), src/clones.zig:283 (one duplicate_function test), src/main.zig and src/render.zig (none)
- What goes wrong: `thick_frontend`, `unused_pub`, `duplicate_shape`, `parallel_implementation`, `duplicate_fragment`, the hotspot kinds, `parse_error` and `@atlas allow` on imports have no test that they report a case, and none that they skip a case. SKILL.md asks for both for each heuristic. Nothing runs the CLI on a fixture, which is how the `--root .` and missing-root bugs got through. `render.findingSection` silently depends on `main.findingOrder` having sorted the findings.
- Fix: one report case and one must-not case per kind in checks.zig and clones.zig (the fixtures above are ready-made). A `test` step that runs the built binary on `testdata/` and compares `atlas.json`. A render test with unsorted findings.

### [low] Defaults and the Layer and Rule types are written in four places (Lens D)
- Where: build.zig:37-71 (`Layer`, `Rule`, `Options` defaults), src/config.zig:6-48 (`Layer`, `Rule`, `Config` defaults), src/config.zig:79-97 (`usage` text), README ("default 60", "complexity above 10")
- What goes wrong: changing a threshold means editing four places, and nothing checks that they agree. Today they do.
- Fix: `build.zig` can `@import("src/config.zig")`. Alias `Layer` and `Rule` from it, and take the `Options` defaults from `config.Config{}`. Generate the numbers in `usage` with `std.fmt.comptimePrint` from the same defaults.

### [low] The CLI holds analysis logic: `findingOrder` and `stats` (Lens D)
- Where: src/main.zig:134-170
- What goes wrong: SKILL.md says the CLI must not "hold analysis logic". Finding order is a contract that `render.findingSection` depends on (it groups consecutive findings by kind and severity), and `stats` derives model data. Both live in main.zig. Severity counting is also repeated in main.zig:64-65 and render.zig:55-62.
- Fix: move `findingOrder` (as `sortFindings`) into checks.zig, and `stats` into model.zig or checks.zig. Then the self-atlas `thick_frontend` lead on `main` also loses most of its branches.

### [low] Overlapping roots scan files twice (Lens D)
- Where: src/main.zig:85-121 `collectFiles`
- What goes wrong: `--root src --root src/core` lists `src/core/store.zig` twice in `files`, which doubles its functions and creates fake duplicates.
- Fix: deduplicate after sorting.

### [low] Nesting depth counts the braces of struct literals (Lens D)
- Where: src/scan.zig:315-318
- What goes wrong: fixture `misc` `lit()`, `const a = .{ .x = .{ .y = .{ .z = 1 } } }`, has no control flow and reports `depth=3`. The depth appears in the `complex_function` message and the hotspot table.
- Fix: only count an `l_brace` that opens a block (the previous token is `)`, `else`, a capture `|…|`, or `:` of a labelled block). Skip `.{` and `Type{`.

### [low] `duplicate_shape` chains look-alikes transitively and lists the wrong fields (Lens D)
- Where: src/checks.zig:236-272
- What goes wrong: fixture `cfg/src/a/shapes.zig`. A{a..h} and C{c..j} share 6 of 10 names (Jaccard 0.6, below 0.8), but both link to B{a..j}. All three are reported as "nearly the same fields (a, b, c, d, e, f, g, h)", which are A's fields, not the common ones.
- Fix: report pairs or cliques, not union-find components, or list the intersection of the group.

### [low] Small doc and contract mismatches (Lens D)
- Where: build.zig:61 and build.zig:89; src/config.zig:94; src/checks.zig:195; README
- What goes wrong:
  - `Options.name` says "defaults to the root package name", but the code uses the directory's basename.
  - `usage` lists `--check [warn|error]`, but `info` is accepted too.
  - The message says "1 calls".
  - README says accepted findings can be muted with `@atlas allow`, but `large_file`, `parse_error` and the directory cycle cannot be muted.
  - README's `unused_pub` row omits the module-root, `main` and `format` exclusions.
  - atlas.json has no schema version and does not carry the layer configuration.
  - Calls through conditional re-exports stay as dangling ids. nomadfs has `src/fs/mod.zig:fuse.unmount` because `pub const fuse = if (…) @import("fuse.zig") else …` is not an alias.
- Fix: correct the doc comments and the README, add `"schema": 1` and a `layers` array to `Atlas` (additive), and accept `if (…) @import(…) else …` in `aliasOf`.

---

Checked and sound:
- Dependency direction: every import points down (cli → render, analysis, scan, base; analysis → scan for `Body` only; base imports nothing above). The self-atlas reports no layer break.
- `addAtlasStep` in a real consumer:
  - the `.name` default works;
  - `./src/app/` layer paths with a trailing slash work (trimmed);
  - `b.args` pass-through works (`-- --check`, `-- --check warn`, `-- --out DIR`; the last `--out` wins);
  - output goes to `zig-out/atlas` through `getInstallPath`;
  - `has_side_effects` makes the step re-run;
  - `--check` makes the build fail.
- The CLI flags in `build.zig` match the `config.parse` flags and `usage`.
- `layer_violation` and `forbidden_import` on relative imports.
- Imports inside function bodies count as edges; imports inside `test` blocks (also nested in structs) are skipped.
- The longest-prefix layer match (nomadfs `device` vs `identity`).
- The nomadfs `layer_violation` (`src/net/discovery/rpc.zig:10` → `src/node_info.zig`) and the 4 `forbidden_import` findings match the code.
- Spot-checked nomadfs `duplicate_function` groups (`createSocket`, `sendtoSocket`, `recvfromSocket` in mdns and nat) are real copies.
- The other 13 nomadfs `unused_pub` findings appear only in their own file.
- `zig build test` passes; `zig fmt --check src build.zig` is clean.

Not covered:
- Windows behaviour (the backslash handling was reasoned about, not run).
- The `large_file`, `long_function` and `many_params` thresholds beyond reading the code.
- `import_cycle` on files beyond the nomadfs output.
- Determinism and memory (Lenses A and B).
- The JSON field-by-field compatibility history (there is only one release).
- api.md content beyond the missing generic methods.
- Running zigatlas on a project other than nomadfs.
