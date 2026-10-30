//! Duplicate code: whole functions with the same body, and long runs of the
//! same tokens inside different functions (copy, paste, rename).
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const Body = @import("scan.zig").Body;
const Config = @import("config.zig").Config;

/// Buckets holding more windows than this are boilerplate everyone repeats
/// (formatting, error mapping); comparing them all is slow and says little.
const max_bucket = 48;
/// Fragments reported, longest first.
const max_fragments = 200;

pub fn detect(
    arena: Allocator,
    cfg: *const Config,
    bodies: []const Body,
    functions: []const model.Function,
    findings: *std.ArrayList(model.Finding),
) !void {
    const group = try wholeFunctions(arena, cfg, bodies, functions, findings);
    try fragments(arena, cfg, bodies, functions, group, findings);
    try sameName(arena, bodies, functions, group, findings);
}

/// Groups functions by the hash of their whole normalized body. Returns, per
/// body, the group it was reported in (0 = none) so fragment detection does
/// not report the same copies again.
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

/// CPD-style detection: hash every window of `min_clone_tokens` tokens, then
/// grow each colliding pair to its longest common run.
fn fragments(
    arena: Allocator,
    cfg: *const Config,
    bodies: []const Body,
    functions: []const model.Function,
    group: []const u32,
    findings: *std.ArrayList(model.Finding),
) !void {
    const k = cfg.min_clone_tokens;
    var windows: std.AutoHashMapUnmanaged(u64, std.ArrayList(Pos)) = .empty;

    const base: u64 = 1_000_003;
    var base_k: u64 = 1; // base^(k-1)
    for (1..k) |_| base_k *%= base;

    for (bodies, 0..) |body, bi| {
        if (body.hashes.len < k or functions[body.function].allowed != null) continue;
        var h: u64 = 0;
        for (body.hashes[0..k]) |t| h = h *% base +% t;
        var at: usize = 0;
        while (true) {
            const gop = try windows.getOrPut(arena, h);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            if (gop.value_ptr.items.len <= max_bucket) {
                try gop.value_ptr.append(arena, .{ .body = @intCast(bi), .at = @intCast(at) });
            }
            if (at + k >= body.hashes.len) break;
            h = (h -% body.hashes[at] *% base_k) *% base +% body.hashes[at + k];
            at += 1;
        }
    }

    var matches: std.ArrayList(Match) = .empty;
    var it = windows.valueIterator();
    while (it.next()) |list| {
        const items = list.items;
        if (items.len < 2 or items.len > max_bucket) continue;
        for (items, 0..) |pa, i| {
            for (items[i + 1 ..]) |pb| {
                if (try pairMatch(bodies, group, k, pa, pb)) |m| try matches.append(arena, m);
            }
        }
    }

    std.mem.sort(Match, matches.items, {}, longerFirst);

    // Several copies of one fragment show up as pairs (A,B) (A,C) (B,C):
    // report each copy set once, keyed by its first location.
    var covered: std.AutoHashMapUnmanaged(Pos, void) = .empty;
    var reported: usize = 0;
    var i: usize = 0;
    while (i < matches.items.len and reported < max_fragments) {
        const lead = matches.items[i];
        var j = i;
        var locations: std.ArrayList(model.Location) = .empty;
        const skip = covered.contains(lead.a);
        if (!skip) try locations.append(arena, location(bodies, functions, lead.a, lead.len));
        while (j < matches.items.len and matches.items[j].len == lead.len and std.meta.eql(matches.items[j].a, lead.a)) : (j += 1) {
            const m = matches.items[j];
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

/// Bodies at least this similar (Jaccard of token bigrams) count as the same
/// job done twice when the functions also share a name.
const same_name_similarity = 0.5;

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
        if (f.owner.len != 0 or f.lines < 4 or f.allowed != null or group[bi] != 0) continue;
        const gop = try by_name.getOrPut(arena, f.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, @intCast(bi));
    }
    for (by_name.keys(), by_name.values()) |name, list| {
        if (list.items.len < 2) continue;
        const items = list.items;
        const keep = try arena.alloc(bool, items.len);
        @memset(keep, false);
        var best: f64 = 0;
        for (items, 0..) |a, i| {
            for (items[i + 1 ..], i + 1..) |b, j| {
                const fa = functions[bodies[a].function];
                const fb = functions[bodies[b].function];
                if (std.mem.eql(u8, fa.file, fb.file) or calls(fa, fb.id) or calls(fb, fa.id)) continue;
                const sim = try similarity(arena, bodies[a].hashes, bodies[b].hashes);
                if (sim < same_name_similarity) continue;
                keep[i] = true;
                keep[j] = true;
                best = @max(best, sim);
            }
        }
        var locations: std.ArrayList(model.Location) = .empty;
        for (items, keep) |bi, k| {
            if (!k) continue;
            const f = functions[bodies[bi].function];
            try locations.append(arena, .{ .file = f.file, .line = f.line, .end_line = f.end_line, .symbol = f.id });
        }
        if (locations.items.len < 2) continue;
        try findings.append(arena, .{
            .kind = .parallel_implementation,
            .severity = .info,
            .message = try std.fmt.allocPrint(arena, "{s}() is written separately in {d} files with similar bodies ({d}% alike); keep one where the layers allow it", .{ name, locations.items.len, @as(u32, @intFromFloat(best * 100)) }),
            .locations = locations.items,
        });
    }
}

fn calls(f: model.Function, id: []const u8) bool {
    for (f.calls) |c| {
        if (std.mem.eql(u8, c, id)) return true;
    }
    return false;
}

/// Jaccard similarity of the sets of adjacent token pairs.
fn similarity(arena: Allocator, a: []const u64, b: []const u64) !f64 {
    if (a.len < 2 or b.len < 2) return 0;
    var set: std.AutoHashMapUnmanaged(u64, u2) = .empty;
    defer set.deinit(arena);
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

fn pairMatch(bodies: []const Body, group: []const u32, k: u32, pa: Pos, pb: Pos) !?Match {
    const a = bodies[pa.body].hashes;
    const b = bodies[pb.body].hashes;
    if (pa.body == pb.body) {
        // Overlapping windows of one function are repetition, not copies.
        const lo = @min(pa.at, pb.at);
        const hi = @max(pa.at, pb.at);
        if (hi - lo < k) return null;
    } else if (group[pa.body] != 0 and group[pa.body] == group[pb.body]) {
        return null; // already reported as whole-function duplicates
    }
    // Only report maximal runs: if the previous tokens match too, an earlier
    // window covers this pair.
    if (pa.at > 0 and pb.at > 0 and a[pa.at - 1] == b[pb.at - 1]) return null;
    if (!std.mem.eql(u64, a[pa.at..][0..k], b[pb.at..][0..k])) return null; // hash collision

    var len: u32 = k;
    while (pa.at + len < a.len and pb.at + len < b.len and a[pa.at + len] == b[pb.at + len]) len += 1;
    if (pa.body == pb.body and @min(pa.at, pb.at) + len > @max(pa.at, pb.at)) {
        len = @max(pa.at, pb.at) - @min(pa.at, pb.at);
    }
    return .{ .a = pa, .b = pb, .len = len };
}

fn location(bodies: []const Body, functions: []const model.Function, p: Pos, len: u32) model.Location {
    const body = bodies[p.body];
    const f = functions[body.function];
    return .{ .file = f.file, .line = body.lines[p.at], .end_line = body.lines[p.at + len - 1], .symbol = f.id };
}

fn longerFirst(_: void, x: Match, y: Match) bool {
    if (x.len != y.len) return x.len > y.len;
    if (x.a.body != y.a.body) return x.a.body < y.a.body;
    return x.a.at < y.a.at;
}

test "renamed copies are found, different code is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scan = @import("scan.zig");
    const cfg: Config = .{ .min_clone_tokens = 20, .min_fn_tokens = 20 };
    var b = scan.Builder.init(arena, &cfg);
    try b.addFile("a.zig",
        \\fn sumA(items: []const u32) u32 {
        \\    var total: u32 = 0;
        \\    for (items) |item| {
        \\        if (item > 10) total += item * 2 else total += item;
        \\    }
        \\    return total;
        \\}
        \\fn other(x: u32) u32 {
        \\    return x + 1;
        \\}
    );
    try b.addFile("b.zig",
        \\fn sumB(values: []const u32) u32 {
        \\    var acc: u32 = 0;
        \\    for (values) |v| {
        \\        if (v > 99) acc += v * 3 else acc += v;
        \\    }
        \\    return acc;
        \\}
    );
    try detect(arena, &cfg, b.bodies.items, b.functions.items, &b.findings);
    try std.testing.expectEqual(@as(usize, 1), b.findings.items.len);
    try std.testing.expectEqual(model.FindingKind.duplicate_function, b.findings.items[0].kind);
    try std.testing.expectEqual(@as(usize, 2), b.findings.items[0].locations.len);
}
