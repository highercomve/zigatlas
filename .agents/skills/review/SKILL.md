---
name: review
description: Review zigatlas code (a diff, a branch, files or the whole tree) in four lenses — Zig idioms and correctness, memory and resources, NASA/JPL Power of 10 adapted to Zig, and the tool's own design (the scan → analysis → render pipeline, the build.zig API other projects call, and how far each finding can be trusted). Use for any code review, before merging or tagging a release, or when asked whether a finding kind is accurate.
---

# zigatlas code review

Works for any coding agent. Read the code, judge it against the four lenses
below, **verify every finding against the code** before reporting it, and write
the review as one file. Do not modify source files during a review.

zigatlas is a command-line tool plus a `build.zig` API: other projects add it as
a dependency and call `addAtlasStep`. It parses Zig with `std.zig.Ast`, collects
an atlas (`src/model.zig`), judges it, and writes ATLAS.md, api.md, atlas.json,
deps.mmd and files.dot. Its users are people and LLM agents who act on its
findings, so **a wrong finding is a bug**, the same as a crash.

## 1. Scope

- Default: the change under review, `git diff <base>...HEAD` (base: `main`, or
  the last tag `git describe --tags --abbrev=0`). Also read the code around each
  change: a finding about a call needs its callee.
- A path, a branch or "the whole project" when asked.
- Note what you did **not** read, so the reader knows the review's reach.
- Run `zig build atlas` first: zigatlas maps itself (layers in `build.zig`), and
  writes `zig-out/atlas/`. Treat its findings as leads, not as the review.
- For changes to scanning or checks, also run the tool on a real project (for
  example `../nomadfs`: `zig build atlas` there) and compare the finding counts
  before and after. A change that moves counts needs an explanation.

## 2. Lens A: Zig idioms and correctness (Zig 0.16)

- **Errors**: every fallible call handled; `errdefer` where a function acquires
  something; `catch {}` / `catch continue` / `_ =` only where dropping the error
  is right, with a comment saying why. A file that can't be read or parsed is
  reported, not silently skipped.
- **AST handling**: every `Ast` accessor is used on the node tags it supports
  (`fullFnProto`, `fullVarDecl`, `fullContainerDecl`, `nodeData` unions);
  optional nodes unwrapped; token indexes stay inside `[first, last]` of the
  node and inside the token list (`i + 2 < len` style checks before
  look-ahead). Source with parse errors still produces a partial atlas, never
  a crash.
- **Slices and pointers**: nothing points into an `ArrayList` that later grows
  (`&list.items[i]` kept across an `append`); map keys outlive the map.
- **Integers**: `@intCast` only on values proven in range (line counts, token
  counts, file counts); subtraction that can go below zero uses `-|` or is
  guarded.
- **Determinism**: the same tree gives byte-identical output. Hash map
  iteration order must not reach the output unsorted (files are sorted; check
  findings, groups, edges and member lists).
- **Untrusted input**: the scanned source is untrusted text. Odd but valid Zig
  (multiline strings, `@"quoted"` identifiers, unicode, `\r\n`, empty files,
  files without a trailing newline, huge files) must not crash or mis-count.

## 3. Lens B: memory and resources

- The tool is one short run on an arena (`main.zig`). Check that nothing
  outside the arena is leaked (directory handles, walkers, files) and that tests
  free what they allocate with `std.testing.allocator`.
- Memory grows with the scanned tree: per-file and per-function structures, the
  token hash windows in `clones.zig`, pairwise comparisons in `checks.zig`.
  Look for anything quadratic in the number of functions, types or windows
  without a cap, and estimate it for a 100k-line project.
- Files and directories opened are closed on every path; the output directory
  is created once and closed.

## 4. Lens C: Power of 10, adapted to Zig

1. Simple control flow; no recursion without a bound (container nesting in
   scanned code is attacker-free but can be deep).
2. Every loop has an upper bound (alias chains, re-export resolution, token
   look-ahead, union-find, clone extension).
3. Allocation bounded by the input size; caps like `max_bucket`,
   `max_fragments`, `max_per_kind` are named constants with a reason.
4. Functions short enough to read (about 60 lines); list the longest new ones.
5. Invariants asserted where data crosses modules (a `Body` per function, line
   numbers 1-based and `line <= end_line`).
6. Data in the smallest scope.
7. Every return value checked.
8. Comptime and reflection (`inline for` over enum fields, JSON) kept simple.
9. Pointer discipline (see Lens A).
10. Builds clean in Debug and ReleaseSafe; `zig build test` passes; `zig fmt
    --check src build.zig` is clean.

## 5. Lens D: design, the build API and trust in findings

The pipeline is layered, top to bottom (checked by the self-atlas):

| Layer | Code | Owns | Must not |
| :--- | :--- | :--- | :--- |
| CLI | `src/main.zig` | arguments, walking the roots, running the stages, writing files, exit code | hold analysis logic |
| Render | `src/render.zig` | turning the atlas into files | change the atlas or decide findings |
| Analysis | `src/checks.zig`, `src/clones.zig` | findings: layers, cycles, hotspots, duplication | parse source, or format output |
| Scan | `src/scan.zig` | one file's syntax → atlas entries, token streams, call resolution | judge anything |
| Base | `src/model.zig`, `src/config.zig` | the atlas types (also the JSON schema) and the configuration | import anything above |

Check:

- **Dependency direction**: imports point down (the self-atlas reports breaks).
- **Trust in findings**: for every finding kind a change touches, ask what it
  reports wrongly (false positives) and what it misses (false negatives). Name
  a concrete Zig snippet for each. Kinds known to be heuristic: `unused_pub`
  (name counts), `parallel_implementation` (name plus body similarity),
  `thick_frontend` (complexity plus calls into other layers), cross-file calls
  (only through import aliases and re-exports). A new heuristic needs a test
  with a case it must report and a case it must not.
- **Messages are actionable**: each finding says what is wrong and what to do,
  with locations precise enough to open (`file:line`, a symbol).
- **The build API is a contract**: `Options`, `Layer`, `Rule` and
  `addAtlasStep` in `build.zig` are used by other projects' build scripts.
  Renaming or removing a field breaks them; adding a field needs a default.
  The CLI flags they turn into stay in sync with `config.zig` (`usage` too).
- **The JSON is a contract**: `model.zig` field names are the atlas.json schema
  that tools read. Changes are additive, or called out.
- **One place per concept**: a threshold, a skip list or a normalisation rule
  lives in one place (config, a named constant), not repeated across stages.
- **Docs match behaviour**: README's findings table, annotations and options
  describe what the code does.
- **Tests at the right layer**: scanning tested with small sources in
  `scan.zig`, checks with built atlases, the CLI by running it on a fixture.

### Leads from the atlas

| Atlas finding | Check here |
| :--- | :--- |
| `layer_violation`, `import_cycle` | Dependency direction |
| `duplicate_function`, `duplicate_fragment`, `parallel_implementation` | One place per concept |
| `long_function`, `complex_function`, `many_params` | Power of 10 rule 4 |
| `unused_pub` | Cleanups (low); module-root API is excluded |

An accepted exception is muted with `// @atlas allow: <reason>` above the
declaration or import. Suggest it when a lead is intentional.

## 6. How to run it

- Run `zig build atlas`, read `zig-out/atlas/ATLAS.md`, and give the lenses its
  path.
- Read the scope, then go lens by lens. If the agent can run sub-agents, one per
  lens in parallel is a good split; keep each at medium effort or below and give
  each this file and the scope. Otherwise do the lenses in order.
- For every candidate finding, open the code and confirm it: a concrete Zig
  input that crashes, mis-counts or produces a wrong finding, or the exact lines.
  Writing that input to a temporary file and running `zig-out/bin/zigatlas
  --root <dir> --out <tmp>` on it is the best proof. Drop what you can't
  confirm, or mark it *unverified*.
- Run `zig build test` and `zig fmt --check src build.zig`; report the result.

## 7. The report

Write it to `.agents/review/<scope>/review.md` (e.g. `.agents/review/v0.1.0/`,
`.agents/review/whole-project/`). Start with a one-line verdict (approve /
approve with changes / rework), then the findings ranked by severity:

```
### [severity] Short title (lens)
- Where: src/file.zig:123
- What goes wrong: the concrete input and the wrong result
- Fix: the change
```

Severity: **critical** (crash or hang on valid Zig, corrupt or missing output),
**high** (wrong findings in normal use: false errors, missed layer breaks,
wrong locations), **medium** (latent bug, missing bound, misleading message,
an API or schema break), **low** (clarity, small cleanups). End with what was
checked and found sound, and what was not covered. Give the self-atlas counts,
and for scanning or check changes the counts on the reference project, before
and after.
