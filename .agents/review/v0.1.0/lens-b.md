# zigatlas v0.1.0 review: Lens B (memory and resources)

Verdict for this lens: approve with changes. Every handle is closed and the tests
are leak-free, and the real trees run fast. But peak memory is about 1 KiB per
scanned line, and 60% of it is the clone-window hash map. Two analyses blow up
quadratically on synthetic input (`sameName`, `annotation()`), and one of them
also leaks memory per pair.

How it was measured: the ReleaseSafe build (what `addAtlasStep` uses), built to
`/tmp/za-lens-b/rs`. The checked-in `zig-out/bin/zigatlas` is a Debug build,
about 7x slower. Peak RSS comes from `getrusage(RUSAGE_CHILDREN)`, because
`/usr/bin/time` is not installed. For the per-phase numbers, a copy of `src/` in
`/tmp/za-lens-b/inst` prints rusage and arena capacity after each stage. The
fixes proposed below were also tried on a copy (`/tmp/za-lens-b/fix`), and their
output was byte-identical to the original on std, nomadfs and the synthetic
trees. The synthetic generators are in `/tmp/za-lens-b/scripts/gen.py` and
`run.sh`, run with an 8 GB `ulimit -v` and a 300 s timeout.

## Findings

### [medium] Clone-window hash map costs about 170-250 bytes per body token and dominates peak memory (Lens B)
- Where: src/clones.zig:85-103 (`windows: AutoHashMapUnmanaged(u64, ArrayList(Pos))`), together with the arena
- What goes wrong: every distinct 60-token window gets a map slot (8 B key, 24 B
  ArrayList, metadata, at 80% load) and its own ArrayList. The list's first
  append reserves 8 `Pos` (64 B). Each rehash and each list growth leaves the old
  buffer behind in the arena. Most windows are singletons that are never compared.
  - Zig std (550 files, 434k lines, 1.54M body tokens, 912k distinct windows):
    RSS is 155 MiB after scanning and 411 MiB after building windows. Peak is
    430 MiB, so the map accounts for 256 MiB.
  - Synthetic `segs-1600` (48 near-copies, 77k lines, 6.9M body tokens, 4.65M
    windows): 476 MiB to 1653 MiB. Peak is 1.69 GB.
  - Extrapolated: about 100 MiB per 100k lines of real code. A 2M-line tree would
    need about 2 GB.
- Fix: replace the map with one flat array of `{hash, Pos}` (16 B per window,
  exact size known from the body lengths). Sort it by (hash, body, at) and walk
  the runs, skipping runs shorter than 2 or longer than `max_bucket`. This keeps
  the current semantics, and the output is identical.
  - Tried on the copy: std window phase went from +256 MiB to +20 MiB and peak
    from 430 to 105 MiB (with the AST fix below). Time was unchanged (0.60 s to
    0.55 s).
  - `segs-1600`: peak from 1.69 GB to 240 MiB.
  - nomadfs: peak from 39.7 to 15.6 MiB.

### [medium] `parallel_implementation` is quadratic in time and memory for one function name, and `similarity` leaks per pair (Lens B)
- Where: src/clones.zig:192-205 (pairwise loop over `by_name` groups), src/clones.zig:229-233 (`similarity`)
- What goes wrong: every pair of same-named top-level functions builds a new
  bigram hash set from the arena. `defer set.deinit(arena)` returns only the last
  buffer; every growth buffer before it stays allocated, about 600 B per pair.
  The input was N files, each with `pub fn run(x: u32, s: anytype) u32` of about
  17 lines, all bodies distinct:

  | N | Time | Peak RSS |
  |---:|---:|---:|
  | 500 | 0.33 s | 84 MiB |
  | 1000 | 1.24 s | 317 MiB |
  | 2000 | 4.8 s | 1.24 GB |
  | 4000 (68k lines) | 19.2 s | 4.88 GB |

  At N = 8000 it would need about 20 GB and be killed for running out of memory.
  Real trees are far from this: the largest groups are 42 for `init` in std and 4
  in nomadfs. It is still an unbounded allocation on valid input.
- Fix:
  - Compute each body's bigram set once, as a sorted unique `[]u64`, and
    intersect pairs by merging, with no allocation per pair.
  - Cap the group size like `max_bucket`, or skip and report groups above it.
  - Tried on the copy with one set reused across pairs: N = 4000 drops to 34 MiB
    peak, with identical output. Time is still quadratic (11.9 s), so the cap is
    also needed.

### [medium] `annotation()` walks the whole comment block above a line once per declaration on that line (Lens B)
- Where: src/scan.zig:426, called per function (src/scan.zig:297), per container (src/scan.zig:177) and per import (src/scan.zig:250)
- What goes wrong: the walk up through the comment block is redone for every
  declaration, and nothing is remembered between them. When many declarations
  share one line under a long comment block (for example generated or minified
  code under a license header), the cost is (declarations x block length). The
  input was N lines of `// header comment line`, then one line holding N
  `fn fK() void {}`:

  | N | Time |
  |---:|---:|
  | 5000 | 1.7 s |
  | 10000 | 6.4 s |
  | 20000 (20k-line file) | 26 s |

  Ordinary files are linear, because each block is walked once by the
  declaration below it.
- Fix: compute `block_top[line]` once per file in a single linear pass over
  `line_starts`, or cache the last (line, result) pair. `annotation` then reads
  the block start in O(1).

### [low] Every file's AST and its parser scratch live until exit in the run arena (Lens B)
- Where: src/scan.zig:39 (`Ast.parse(b.arena, ...)`), src/scan.zig:362-378 (`hashes`/`lines` grown one append at a time in the arena)
- What goes wrong: nothing kept after `addFile` points into the `Ast`. Names are
  slices of `source`, which stays alive, and everything else is copied. All
  tokens, nodes, extra data and parser scratch are kept anyway. Each body's two
  lists also grow geometrically, and the arena keeps the outgrown buffers.
  Scanning std uses 155 MiB of RSS for 15 MiB of source.
- Fix: parse into a per-file scratch arena (`ArenaAllocator` over
  `page_allocator`, `defer deinit`), and create `hashes`/`lines` with
  `initCapacity(arena, last - first + 1)`. Tried on the copy: std after scanning
  went from 155 to 63 MiB, with identical output.

### [low] `duplicate_shape` is O(S²) in structs, and the grouping pass is O(S²) again once any pair links (Lens B)
- Where: src/checks.zig:240-254 (pairwise intersection), src/checks.zig:257-264 (for each root, scan every shape)
- What goes wrong: the input was N structs with 3 fields each, all different:

  | N | Time |
  |---:|---:|
  | 10k | 0.42 s |
  | 20k | 1.67 s |
  | 40k | 6.5 s |

  Adding one duplicate pair at 40k adds 0.9 s for the second pass. Real trees
  are small: std has 1345 such structs and nomadfs has 206.
- Fix: group the roots in one pass (`root -> list` after the union-find) rather
  than running `for root { for shapes }`. For the pairwise step, index the shapes
  by field name, or by a sorted field-set hash for exact matches, and compare
  only shapes that share at least ceil(0.8·min) names.

### [low] `api.md` rendering is O(files × (functions + containers)) (Lens B)
- Where: src/render.zig:245 and src/render.zig:264
- What goes wrong: for every file, `api()` scans every container and every
  function with `std.mem.eql` on the path. The input was N files of 10 functions
  each:

  | Files | Functions | Time |
  |---:|---:|---:|
  | 2000 | 20k | 0.18 s |
  | 4000 | 40k | 0.56 s |
  | 8000 | 80k | 1.94 s |

  At 8000 files, the render phase accounts for 1.65 s of the 1.78 s user time.
  For a realistic 1M-line tree, expect about 1 s.
- Fix: functions and containers are appended file by file, in the same sorted
  order as `files`. Walk both with a cursor (or record each file's
  `[start, end)` index ranges during the scan), so the pass is linear.

### [low] `inTest` is a linear scan per `@import` (Lens B)
- Where: src/scan.zig:451, called from src/scan.zig:240
- What goes wrong: the cost is O(imports × tests) per file. The input was one
  file with N tests, each containing an `@import`: N = 10k took 0.03 s, 20k took
  0.11 s, and 40k took 0.36 s. It is quadratic but harmless at realistic sizes.
- Fix: `test_ranges` is already sorted by token, so use a binary search
  (`upperBound` on the range start).

## Checked and sound

- Handles:
  - `collectFiles` (src/main.zig:87-110) closes `dir` with `defer`, which is
    registered before `walk`, so it is also closed if `walk` or `next` fails. It
    `defer`s `walker.deinit()`.
  - `out_dir` is created and opened once and closed with `defer` (src/main.zig:53-54).
  - `readFileAllocOptions` closes its own file and is capped at 64 MiB per file.
  - `std.process.exit` after `out_dir` skips the `defer`, but the process is ending.
- Tests: all 7 use an `ArenaAllocator` over `std.testing.allocator` with
  `defer deinit`. `zig build test` passes 7/7 in both Debug and ReleaseSafe, with
  no leak reports. Wrapping everything in an arena hides leaks inside a single
  call, such as the `similarity` leak above, which no test can catch.
- `fragments` pair work is bounded by `max_bucket`: at most 1128 pairs per
  bucket, and the maximal-run check prunes most of them early.
  - Worst case `segs-1600` (every bucket full): 1.8M matches, 0.2 s for pairs
    and sorting.
  - `copies-1000` (48 near-copies, 48k lines): 0.12 s.
- Linear:
  - `lineOf` (binary search), `countIdents`, `metrics`, `calls`, the whole-file
    `annotation`, `fileDoc` and `docBefore`.
  - Re-export resolution, which is capped at 8 hops.
  - Tarjan (iterative), `dirEdges`, and `layerSection` (layers × files).
- Big single file: 180k lines in one file (20k functions) took 0.18 s and 118 MiB.

Measurements (ReleaseSafe):

| Tree | Lines | Files | Functions | Wall | Peak RSS |
|---|---:|---:|---:|---:|---:|
| nomadfs (src + nomadfs-gui/src) | 33k | 84 | 1436 | 0.05 s | 39.7 MiB |
| nomadfs, with the window and AST fixes | 33k | 84 | 1436 | 0.05 s | 15.6 MiB |
| Zig std | 434k | 550 | 9721 | 0.60 s | 430 MiB |
| Zig std, with the window and AST fixes | 434k | 550 | 9721 | 0.55 s | 105 MiB |

- Debug build on the same trees: nomadfs 0.37 s / 44.7 MiB, std 4.26 s / 436 MiB.
- Phases on std, as RSS: scanning 155 MiB, windows 411 MiB, render outputs held
  in memory 430 MiB.

## Not covered

- Lenses A, C and D.
- I did not run the self-atlas (`zig build atlas`), so that nothing would be
  written into the repository.
- Peak memory on macOS and Windows.
- A lead for Lens A/D (*unverified*): on std, functions inside type-returning
  generics (`fn ArrayList(T) type { return struct {...} }`) appear not to be
  walked. Only 9721 functions are reported for 434k lines. This makes my std
  numbers lower than a tool that walks generics would see.
- nomadfs was being edited during the review. One run changed from 1436 to 1438
  functions between measurements, which is not a determinism issue: on the same
  source, the baseline and fixed binaries gave identical output.
