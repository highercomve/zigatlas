//! Duplicate code: whole functions with the same body, long runs of the same
//! tokens inside different functions (copy, paste, rename), and functions
//! with the same name and similar bodies in different files.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const Body = @import("scan.zig").Body;
const Config = @import("config.zig").Config;

/// Windows shared by more than this many places are boilerplate everyone
/// repeats (formatting, error mapping); comparing them all is slow and says
/// little.
const max_bucket = 48;
/// Fragments reported, longest first.
const max_fragments = 200;
/// Same-name functions compared per name; more are listed by count only.
const max_same_name = 32;
/// Bodies shorter than this are too small to call "the same job".
const min_same_name_tokens = 20;
/// Bodies at least this similar (Jaccard of token bigrams) count as the same
/// job done twice when the functions also share a name.
const same_name_similarity = 0.5;
/// Matches between the same two places closer than this many tokens are one match.
const merge_gap = 4;
/// Rolling hash base for token windows.
const window_base: u64 = 1_000_003;

pub fn detect(
    arena: Allocator,
    cfg: *const Config,
    bodies: []const Body,
    functions: []const model.Function,
    findings: *std.ArrayList(model.Finding),
) !void {
    for (bodies) |body| {
        std.debug.assert(body.function < functions.len);
        std.debug.assert(body.hashes.len == body.lines.len);
    }
    const group = try wholeFunctions(arena, cfg, bodies, functions, findings);
    try fragments(arena, cfg, bodies, functions, group, findings);
    try sameName(arena, bodies, functions, group, findings);
}

/// Groups functions by the hash of their whole normalized body. Returns, per
/// body, the group it was reported in (0 = none) so the other checks do not
/// report the same copies again.
fn wholeFunctions(
    arena: Allocator,
    cfg: *const Config,
    bodies: []const Body,
    functions: []const model.Function,
    findings: *std.ArrayList(model.Finding),
) ![]u32 {
    const group = try arena.alloc(u32, bodies.len);
    @memset(group, 0);

    var by_hash: std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(u32)) = .empty;
    for (bodies, 0..) |body, i| {
        if (body.hashes.len < cfg.min_fn_tokens) continue;
        if (functions[body.function].allowed != null) continue;
        const h = std.hash.Wyhash.hash(body.hashes.len, std.mem.sliceAsBytes(body.hashes));
        const gop = try by_hash.getOrPut(arena, h);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, @intCast(i));
    }

    var next_group: u32 = 1;
    for (by_hash.values()) |members| {
        if (members.items.len < 2) continue;
        var locations: std.ArrayList(model.Location) = .empty;
        for (members.items) |bi| {
            group[bi] = next_group;
            const f = functions[bodies[bi].function];
            try locations.append(arena, .{ .file = f.file, .line = f.line, .end_line = f.end_line, .symbol = f.id });
        }
        next_group += 1;
        const f = functions[bodies[members.items[0]].function];
        try findings.append(arena, .{
            .kind = .duplicate_function,
            .severity = .warn,
            .message = try std.fmt.allocPrint(arena, "{d} functions have the same body ({d} lines, {d} tokens) apart from local names and literals; keep one and call it", .{ members.items.len, f.lines, bodies[members.items[0]].hashes.len }),
            .locations = locations.items,
        });
    }
    return group;
}

const Pos = struct { body: u32, at: u32 };
const Match = struct { a: Pos, b: Pos, len: u32 };
const Window = struct { hash: u64, pos: Pos };

/// CPD-style detection: hash every window of `min_clone_tokens` tokens, sort
/// them so equal windows sit together, then grow each colliding pair to its
/// longest common run.
fn fragments(
    arena: Allocator,
    cfg: *const Config,
    bodies: []const Body,
    functions: []const model.Function,
    group: []const u32,
    findings: *std.ArrayList(model.Finding),
) !void {
    const k = cfg.min_clone_tokens;
    const windows = try collectWindows(arena, k, bodies, functions);
    const matches = try mergeMatches(arena, try findMatches(arena, k, bodies, group, windows));
    try reportFragments(arena, k, bodies, functions, matches, findings);
}

/// Every window's hash and position, sorted by hash (then position, so the
/// result does not depend on sort stability).
fn collectWindows(arena: Allocator, k: u32, bodies: []const Body, functions: []const model.Function) ![]Window {
    var total: usize = 0;
    for (bodies) |body| {
        if (body.hashes.len >= k) total += body.hashes.len - k + 1;
    }
    var windows: std.ArrayList(Window) = try .initCapacity(arena, total);

    var base_k: u64 = 1; // base^(k-1)
    for (1..k) |_| base_k *%= window_base;

    for (bodies, 0..) |body, bi| {
        if (body.hashes.len < k or functions[body.function].allowed != null) continue;
        var h: u64 = 0;
        for (body.hashes[0..k]) |t| h = h *% window_base +% t;
        var at: usize = 0;
        while (true) {
            windows.appendAssumeCapacity(.{ .hash = h, .pos = .{ .body = @intCast(bi), .at = @intCast(at) } });
            if (at + k >= body.hashes.len) break;
            h = (h -% body.hashes[at] *% base_k) *% window_base +% body.hashes[at + k];
            at += 1;
        }
    }
    std.mem.sort(Window, windows.items, {}, windowLess);
    return windows.items;
}

fn windowLess(_: void, a: Window, b: Window) bool {
    if (a.hash != b.hash) return a.hash < b.hash;
    if (a.pos.body != b.pos.body) return a.pos.body < b.pos.body;
    return a.pos.at < b.pos.at;
}

/// How many windows share `hash`.
fn bucketSize(windows: []const Window, hash: u64) usize {
    const lo = std.sort.lowerBound(Window, windows, hash, hashOrder);
    const hi = std.sort.upperBound(Window, windows, hash, hashOrder);
    return hi - lo;
}

fn hashOrder(key: u64, w: Window) std.math.Order {
    return std.math.order(key, w.hash);
}

fn findMatches(arena: Allocator, k: u32, bodies: []const Body, group: []const u32, windows: []const Window) ![]Match {
    var matches: std.ArrayList(Match) = .empty;
    var i: usize = 0;
    while (i < windows.len) {
        var j = i;
        while (j < windows.len and windows[j].hash == windows[i].hash) j += 1;
        const bucket = windows[i..j];
        i = j;
        if (bucket.len < 2 or bucket.len > max_bucket) continue;
        for (bucket, 0..) |wa, x| {
            for (bucket[x + 1 ..]) |wb| {
                if (try pairMatch(bodies, group, windows, bucket, k, wa.pos, wb.pos)) |m| try matches.append(arena, m);
            }
        }
    }
    std.mem.sort(Match, matches.items, {}, longerFirst);
    return matches.items;
}

fn pairMatch(bodies: []const Body, group: []const u32, windows: []const Window, bucket: []const Window, k: u32, pa: Pos, pb: Pos) !?Match {
    const a = bodies[pa.body].hashes;
    const b = bodies[pb.body].hashes;
    if (pa.body != pb.body and group[pa.body] != 0 and group[pa.body] == group[pb.body]) {
        return null; // already reported as whole-function duplicates
    }
    if (!std.mem.eql(u64, a[pa.at..][0..k], b[pb.at..][0..k])) return null; // hash collision

    // Report each run once, from its first window. If the previous tokens
    // match too, the previous window covers this pair, unless that window's
    // bucket was too common to compare: then this one has to report it.
    if (pa.at > 0 and pb.at > 0 and a[pa.at - 1] == b[pb.at - 1]) {
        if (bucketSize(windows, windowHash(a[pa.at - 1 ..][0..k])) <= max_bucket) return null;
    }

    var len: u32 = k;
    while (pa.at + len < a.len and pb.at + len < b.len and a[pa.at + len] == b[pb.at + len]) len += 1;
    if (pa.body == pb.body) {
        // In one function, a run longer than the distance between its copies,
        // or a start that repeats three times or more, is a repeating pattern
        // (the rows of one if/else or switch chain), not two copies.
        const period = @max(pa.at, pb.at) - @min(pa.at, pb.at);
        if (len >= period or sameBodyCount(bucket, pa.body) >= 3) return null;
    }
    return .{ .a = pa, .b = pb, .len = len };
}

fn sameBodyCount(bucket: []const Window, body: u32) usize {
    var n: usize = 0;
    for (bucket) |w| {
        if (w.pos.body == body) n += 1;
    }
    return n;
}

fn windowHash(tokens: []const u64) u64 {
    var h: u64 = 0;
    for (tokens) |t| h = h *% window_base +% t;
    return h;
}

/// One copied region between two places can match at several alignments
/// (repeating rows shift against each other) or as runs split by a token
/// that differs. Keeps the longest match per pair of regions: a match
/// overlapping a kept one on both sides is dropped, and one continuing it at
/// the same alignment, within `merge_gap` tokens, extends it.
fn mergeMatches(arena: Allocator, matches: []const Match) ![]Match {
    var kept: std.ArrayList(Match) = .empty;
    var by_pair: std.AutoHashMapUnmanaged([2]u32, std.ArrayList(usize)) = .empty;
    for (matches) |m| {
        const gop = try by_pair.getOrPut(arena, .{ m.a.body, m.b.body });
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const absorbed = for (gop.value_ptr.items) |ki| {
            const k = &kept.items[ki];
            if (!near(k.a.at, k.len, m.a.at, m.len) or !near(k.b.at, k.len, m.b.at, m.len)) continue;
            if (@as(i64, k.b.at) - k.a.at == @as(i64, m.b.at) - m.a.at) {
                const lo = @min(k.a.at, m.a.at);
                const hi = @max(k.a.at + k.len, m.a.at + m.len);
                k.b.at = k.b.at - (k.a.at - lo);
                k.a.at = lo;
                k.len = hi - lo;
            }
            break true;
        } else false;
        if (absorbed) continue;
        try gop.value_ptr.append(arena, kept.items.len);
        try kept.append(arena, m);
    }
    std.mem.sort(Match, kept.items, {}, longerFirst);
    return kept.items;
}

/// Whether two token ranges overlap or sit within `merge_gap` of each other.
fn near(a_at: u32, a_len: u32, b_at: u32, b_len: u32) bool {
    return a_at <= b_at + b_len + merge_gap and b_at <= a_at + a_len + merge_gap;
}

/// Several copies of one fragment show up as pairs (A,B) (A,C) (B,C):
/// report each copy set once, keyed by its first location.
fn reportFragments(
    arena: Allocator,
    k: u32,
    bodies: []const Body,
    functions: []const model.Function,
    matches: []const Match,
    findings: *std.ArrayList(model.Finding),
) !void {
    var covered: std.AutoHashMapUnmanaged(Pos, void) = .empty;
    var reported: usize = 0;
    var i: usize = 0;
    while (i < matches.len and reported < max_fragments) {
        const lead = matches[i];
        var j = i;
        var locations: std.ArrayList(model.Location) = .empty;
        const skip = covered.contains(lead.a);
        if (!skip) try locations.append(arena, location(bodies, functions, lead.a, lead.len));
        while (j < matches.len and matches[j].len == lead.len and std.meta.eql(matches[j].a, lead.a)) : (j += 1) {
            const m = matches[j];
            if (skip or covered.contains(m.b)) continue;
            try covered.put(arena, m.b, {});
            try locations.append(arena, location(bodies, functions, m.b, m.len));
        }
        i = j;
        if (locations.items.len < 2) continue;
        // Tables and initializers repeat by nature; only report repeated logic.
        if (controlTokens(bodies[lead.a.body].hashes[lead.a.at..][0..lead.len]) < 2) continue;
        try covered.put(arena, lead.a, {});
        const lines = locations.items[0].end_line - locations.items[0].line + 1;
        try findings.append(arena, .{
            .kind = .duplicate_fragment,
            .severity = if (lead.len >= 2 * k) .warn else .info,
            .message = try std.fmt.allocPrint(arena, "{d} tokens (~{d} lines) repeated in {d} places; extract a shared helper or move it to the layer that owns it", .{ lead.len, lines, locations.items.len }),
            .locations = locations.items,
        });
        reported += 1;
    }
}

/// Control-flow keywords in a normalized token run.
fn controlTokens(hashes: []const u64) u32 {
    const control = [_]std.zig.Token.Tag{ .keyword_if, .keyword_while, .keyword_for, .keyword_switch, .keyword_try, .keyword_return, .keyword_catch, .keyword_orelse };
    var n: u32 = 0;
    for (hashes) |h| {
        for (control) |tag| {
            if (h == @as(u64, @intFromEnum(tag)) + 0x100) n += 1;
        }
    }
    return n;
}

/// The same top-level function name in several files, with bodies that look
/// alike and neither calling the other: one job implemented twice.
fn sameName(
    arena: Allocator,
    bodies: []const Body,
    functions: []const model.Function,
    group: []const u32,
    findings: *std.ArrayList(model.Finding),
) !void {
    var by_name: std.StringArrayHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    for (bodies, 0..) |body, bi| {
        const f = functions[body.function];
        if (f.owner.len != 0 or body.hashes.len < min_same_name_tokens or f.allowed != null) continue;
        const gop = try by_name.getOrPut(arena, f.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, @intCast(bi));
    }
    var scratch: std.AutoHashMapUnmanaged(u64, u2) = .empty;
    for (by_name.keys(), by_name.values()) |name, list| {
        if (list.items.len < 2) continue;
        const items = list.items[0..@min(list.items.len, max_same_name)];
        const keep = try arena.alloc(bool, items.len);
        @memset(keep, false);
        var best: f64 = 0;
        for (items, 0..) |a, i| {
            for (items[i + 1 ..], i + 1..) |b, j| {
                const fa = functions[bodies[a].function];
                const fb = functions[bodies[b].function];
                if (std.mem.eql(u8, fa.file, fb.file) or calls(fa, fb.id) or calls(fb, fa.id)) continue;
                // Whole-function copies count, without comparing again.
                const sim = if (group[a] != 0 and group[a] == group[b]) 1.0 else try similarity(arena, &scratch, bodies[a].hashes, bodies[b].hashes);
                if (sim < same_name_similarity) continue;
                keep[i] = true;
                keep[j] = true;
                best = @max(best, sim);
            }
        }
        try reportSameName(arena, bodies, functions, group, name, items, keep, best, list.items.len, findings);
    }
}

fn reportSameName(
    arena: Allocator,
    bodies: []const Body,
    functions: []const model.Function,
    group: []const u32,
    name: []const u8,
    items: []const u32,
    keep: []const bool,
    best: f64,
    total: usize,
    findings: *std.ArrayList(model.Finding),
) !void {
    // Copies that are all one whole-function duplicate are reported there already.
    var first_group: ?u32 = null;
    var all_one_group = true;
    for (items, keep) |bi, k| {
        if (!k) continue;
        if (first_group == null) first_group = group[bi];
        if (group[bi] == 0 or group[bi] != first_group.?) all_one_group = false;
    }
    if (all_one_group) return;

    var locations: std.ArrayList(model.Location) = .empty;
    var public: ?[]const u8 = null;
    for (items, keep) |bi, k| {
        if (!k) continue;
        const f = functions[bodies[bi].function];
        if (f.is_pub and public == null) public = f.file;
        try locations.append(arena, .{ .file = f.file, .line = f.line, .end_line = f.end_line, .symbol = f.id });
    }
    if (locations.items.len < 2) return;
    const keep_hint = if (public) |file| try std.fmt.allocPrint(arena, "; the public one in {s} is the natural one to keep", .{file}) else "";
    const more = if (total > items.len) try std.fmt.allocPrint(arena, " ({d} same-named functions in all, first {d} compared)", .{ total, items.len }) else "";
    try findings.append(arena, .{
        .kind = .parallel_implementation,
        .severity = .info,
        .message = try std.fmt.allocPrint(arena, "{s}() is written separately in {d} files with similar bodies ({d}% alike){s}{s}", .{
            name, locations.items.len, @as(u32, @intFromFloat(best * 100)), more, keep_hint,
        }),
        .locations = locations.items,
    });
}

fn calls(f: model.Function, id: []const u8) bool {
    for (f.calls) |c| {
        if (std.mem.eql(u8, c, id)) return true;
    }
    return false;
}

/// Jaccard similarity of the sets of adjacent token pairs. `set` is reused
/// between calls.
fn similarity(arena: Allocator, set: *std.AutoHashMapUnmanaged(u64, u2), a: []const u64, b: []const u64) !f64 {
    if (a.len < 2 or b.len < 2) return 0;
    set.clearRetainingCapacity();
    for (a[0 .. a.len - 1], a[1..]) |x, y| try set.put(arena, x *% 31 +% y, 1);
    for (b[0 .. b.len - 1], b[1..]) |x, y| {
        const gop = try set.getOrPut(arena, x *% 31 +% y);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* | 2 else 2;
    }
    var both: u32 = 0;
    var it = set.valueIterator();
    while (it.next()) |v| {
        if (v.* == 3) both += 1;
    }
    return @as(f64, @floatFromInt(both)) / @as(f64, @floatFromInt(set.count()));
}

fn location(bodies: []const Body, functions: []const model.Function, p: Pos, len: u32) model.Location {
    const body = bodies[p.body];
    const f = functions[body.function];
    const loc: model.Location = .{ .file = f.file, .line = body.lines[p.at], .end_line = body.lines[p.at + len - 1], .symbol = f.id };
    std.debug.assert(loc.line <= loc.end_line);
    return loc;
}

fn longerFirst(_: void, x: Match, y: Match) bool {
    if (x.len != y.len) return x.len > y.len;
    if (x.a.body != y.a.body) return x.a.body < y.a.body;
    if (x.a.at != y.a.at) return x.a.at < y.a.at;
    if (x.b.body != y.b.body) return x.b.body < y.b.body;
    return x.b.at < y.b.at;
}

// ---- tests ------------------------------------------------------------------

const scan = @import("scan.zig");

fn run(arena: Allocator, cfg: *const Config, files: []const [2][]const u8) ![]const model.Finding {
    var b = scan.Builder.init(arena, cfg);
    for (files) |f| try b.addFile(f[0], try arena.dupeZ(u8, f[1]));
    try detect(arena, cfg, b.bodies.items, b.functions.items, &b.findings);
    return b.findings.items;
}

fn count(findings: []const model.Finding, kind: model.FindingKind) usize {
    var n: usize = 0;
    for (findings) |f| {
        if (f.kind == kind) n += 1;
    }
    return n;
}

const sum_body =
    \\    var total: u32 = 0;
    \\    for (items) |item| {
    \\        if (item > 10) total += item * 2 else total += item;
    \\    }
    \\    return total;
    \\}
;

test "duplicate_function: renamed copies are found, different code is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{ .min_clone_tokens = 20, .min_fn_tokens = 20 };
    const findings = try run(arena_state.allocator(), &cfg, &.{
        .{ "a.zig", "fn sumA(items: []const u32) u32 {\n" ++ sum_body ++ "\nfn other(x: u32) u32 {\n    return x + 1;\n}\n" },
        .{ "b.zig", "fn sumB(values: []const u32) u32 {\n" ++ sum_body },
    });
    try std.testing.expectEqual(@as(usize, 1), count(findings, .duplicate_function));
    try std.testing.expectEqual(@as(usize, 2), findings[0].locations.len);
}

test "duplicate_function: bodies calling different file-scope functions differ" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{ .min_clone_tokens = 20, .min_fn_tokens = 10 };
    const findings = try run(arena_state.allocator(), &cfg, &.{.{
        "a.zig",
        \\fn stepA(x: u32) u32 { return x; }
        \\fn stepB(x: u32) u32 { return x; }
        \\fn logged(n: u32) u32 { const v = stepA(n); if (v > 1) return stepA(v + 1); return v; }
        \\fn sent(n: u32) u32 { const v = stepB(n); if (v > 1) return stepB(v + 1); return v; }
    }});
    try std.testing.expectEqual(@as(usize, 0), count(findings, .duplicate_function));
}

const long_logic =
    \\    var t: u32 = 0;
    \\    if (a > 1) t += a * 3;
    \\    if (a > 2) t += a * 5;
    \\    if (a > 3) t += a * 7;
    \\    while (t > 100) t -= 9;
    \\    if (t == 4) return t + 11;
    \\    for (0..a) |i| t += @intCast(i);
    \\    return t;
;

test "duplicate_fragment: found even when it starts with boilerplate many functions share" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg: Config = .{ .min_clone_tokens = 20, .min_fn_tokens = 1000 };
    const setup = "    var list: [8]u32 = undefined;\n    list[0] = a;\n    list[1] = a + 1;\n    _ = &list;\n";
    var others: std.ArrayList(u8) = .empty;
    for (0..60) |i| try others.print(arena, "fn other{d}(a: u32) u32 {{\n{s}    return {d};\n}}\n", .{ i, setup, i });
    const findings = try run(arena, &cfg, &.{
        .{ "a.zig", "fn ca(a: u32) u32 {\n" ++ setup ++ long_logic ++ "\n}\n" },
        .{ "b.zig", "fn cb(a: u32) u32 {\n" ++ setup ++ long_logic ++ "\n}\n" },
        .{ "c.zig", others.items },
    });
    try std.testing.expect(count(findings, .duplicate_fragment) >= 1);
}

test "duplicate_fragment: the rows of one if/else chain are not copies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{ .min_clone_tokens = 20, .min_fn_tokens = 1000 };
    const findings = try run(arena_state.allocator(), &cfg, &.{.{
        "a.zig",
        \\fn flags(a: []const u8) u32 {
        \\    var f: u32 = 0;
        \\    if (eql(a, "-a")) { f |= 1; return f; } else if (eql(a, "-b")) { f |= 2; return f; }
        \\    else if (eql(a, "-c")) { f |= 4; return f; } else if (eql(a, "-d")) { f |= 8; return f; }
        \\    else if (eql(a, "-e")) { f |= 16; return f; } else if (eql(a, "-f")) { f |= 32; return f; }
        \\    return f;
        \\}
        \\fn eql(a: []const u8, b: []const u8) bool { return a.len == b.len; }
    }});
    try std.testing.expectEqual(@as(usize, 0), count(findings, .duplicate_fragment));
}

test "parallel_implementation: similar same-named bodies are reported once, unrelated ones are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{ .min_clone_tokens = 60, .min_fn_tokens = 1000 };
    const findings = try run(arena_state.allocator(), &cfg, &.{
        .{ "a.zig", "pub fn parseHex(t: []const u8) ![32]u8 {\n    if (t.len != 64) return error.Bad;\n    var out: [32]u8 = undefined;\n    _ = try std.fmt.hexToBytes(&out, t);\n    return out;\n}\n" },
        .{ "b.zig", "fn parseHex(t: []const u8) ![32]u8 {\n    if (t.len != 64) return error.Invalid;\n    var o: [32]u8 = undefined;\n    _ = try std.fmt.hexToBytes(&o, t);\n    return o;\n}\n" },
        .{ "c.zig", "fn message(a: u32, b: u32) u64 {\n    var x: u64 = a;\n    x <<= 32;\n    x |= b;\n    return x ^ 0xff;\n}\n" },
        .{ "d.zig", "fn message(list: []const u8) usize {\n    var n: usize = 0;\n    for (list) |c| {\n        if (c == ' ') n += 1;\n    }\n    return n;\n}\n" },
    });
    try std.testing.expectEqual(@as(usize, 1), count(findings, .parallel_implementation));
    for (findings) |f| {
        if (f.kind == .parallel_implementation) try std.testing.expect(std.mem.indexOf(u8, f.message, "a.zig is the natural one") != null);
    }
}

test "duplicate_fragment: one copied region is reported once, however its rows align" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{ .min_clone_tokens = 20, .min_fn_tokens = 1000 };
    const rows =
        \\        if (eql(u8, a, "x1")) { show("one", false); } else if (eql(u8, a, "x2")) { show("two", false); }
        \\        else if (eql(u8, a, "x3")) { show("three", false); } else if (eql(u8, a, "x4")) { show("four", false); }
        \\        else if (eql(u8, a, "x5")) { show("five", false); } else if (eql(u8, a, "x6")) { show("six", false); }
    ;
    const findings = try run(arena_state.allocator(), &cfg, &.{.{
        "a.zig",
        "fn onMenu(a: []const u8) void {\n    for (0..1) |_| {\n" ++ rows ++ "\n    }\n}\n" ++
            "fn onArgs(a: []const u8) void {\n    for (0..1) |_| {\n" ++ rows ++ "\n    }\n}\n" ++
            "fn eql(comptime T: type, a: []const T, b: []const T) bool { return a.len == b.len; }\n" ++
            "fn show(n: []const u8, b: bool) void { _ = n; _ = b; }\n",
    }});
    try std.testing.expectEqual(@as(usize, 1), count(findings, .duplicate_fragment));
}
