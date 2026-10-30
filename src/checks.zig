//! Architecture and design checks over the scanned atlas: layers, forbidden
//! imports, cycles, fat front ends, hotspots, unused API and look-alike types.
//! Also owns the order findings are reported in.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const config = @import("config.zig");
const Config = config.Config;

/// Look-alike structs need at least this many fields to be worth comparing.
const min_shape_fields = 3;
/// A field name shared by more groups than this is too common to find look-alikes by.
const max_shape_candidates = 256;
/// Names std calls by convention (formatting, JSON, hash map contexts); a
/// public function with one of them is used even when nothing names it.
const std_hooks = [_][]const u8{ "main", "format", "jsonStringify", "jsonParse", "jsonParseFromValue", "hash", "eql", "lessThan", "panic" };

pub fn run(
    arena: Allocator,
    cfg: *const Config,
    files: []model.File,
    functions: []const model.Function,
    containers: []const model.Container,
    ident_counts: *const std.StringHashMapUnmanaged(u32),
    findings: *std.ArrayList(model.Finding),
) !void {
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    for (files, 0..) |f, i| try index.put(arena, f.path, @intCast(i));

    // Imports of files outside the scanned roots are not edges we can judge.
    for (files) |*f| {
        for (f.imports) |*imp| {
            const target = imp.resolved orelse continue;
            if (index.get(target)) |ti| {
                files[ti].fan_in += 1;
            } else imp.resolved = null;
        }
    }

    var c: Checker = .{ .arena = arena, .cfg = cfg, .files = files, .index = &index, .findings = findings };
    try c.parseErrors();
    try c.layers();
    try c.fileCycles();
    try c.dirCycles();
    try c.hotspots(functions);
    try c.unusedPub(functions, ident_counts);
    try c.duplicateShapes(containers);
}

/// Most severe first, then by kind, then the biggest groups, then by place.
/// The renderers group consecutive findings, so they rely on this order.
pub fn sortFindings(findings: []model.Finding) void {
    std.mem.sort(model.Finding, findings, {}, findingOrder);
}

fn findingOrder(_: void, a: model.Finding, b: model.Finding) bool {
    if (a.severity != b.severity) return a.severity.rank() > b.severity.rank();
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    if (a.locations.len != b.locations.len) return a.locations.len > b.locations.len;
    if (a.locations.len == 0) return false;
    const la = a.locations[0];
    const lb = b.locations[0];
    const o = std.mem.order(u8, la.file, lb.file);
    if (o != .eq) return o == .lt;
    return la.line < lb.line;
}

const Checker = struct {
    arena: Allocator,
    cfg: *const Config,
    files: []model.File,
    index: *const std.StringHashMapUnmanaged(u32),
    findings: *std.ArrayList(model.Finding),

    fn add(c: *Checker, kind: model.FindingKind, severity: model.Severity, locations: []model.Location, comptime fmt: []const u8, args: anytype) !void {
        try c.findings.append(c.arena, .{
            .kind = kind,
            .severity = severity,
            .message = try std.fmt.allocPrint(c.arena, fmt, args),
            .locations = locations,
        });
    }

    fn one(c: *Checker, loc: model.Location) ![]model.Location {
        const locs = try c.arena.alloc(model.Location, 1);
        locs[0] = loc;
        return locs;
    }

    fn fileOf(c: *Checker, path: []const u8) model.File {
        return c.files[c.index.get(path).?];
    }

    fn parseErrors(c: *Checker) !void {
        for (c.files) |f| {
            if (f.parse_errors == 0) continue;
            const loc = try c.one(.{ .file = f.path, .line = @max(f.parse_error_line, 1) });
            if (f.parse_note.len > 0) {
                try c.add(.parse_error, .@"error", loc, "{s}", .{f.parse_note});
            } else {
                try c.add(.parse_error, .@"error", loc, "{d} parse error{s}, the first here; the file was only partly analysed", .{ f.parse_errors, plural(f.parse_errors) });
            }
        }
    }

    // ---- layers -------------------------------------------------------

    fn layers(c: *Checker) !void {
        for (c.files) |f| {
            for (f.imports) |imp| {
                const target_path = imp.resolved orelse continue;
                if (imp.allowed != null) continue;
                const target = c.fileOf(target_path);
                const loc = try c.one(.{ .file = f.path, .line = imp.line, .symbol = target.path });

                for (c.cfg.forbid) |rule| {
                    if (matches(rule.from, f) and matches(rule.to, target)) {
                        try c.add(.forbidden_import, .@"error", loc, "{s} imports {s}: {s} must not import {s}{s}{s}", .{
                            f.path,      target.path, rule.from, rule.to,
                            if (rule.reason.len > 0) " — " else "",
                            rule.reason,
                        });
                    }
                }

                if (c.upward(f, target)) {
                    try c.add(.layer_violation, .@"error", loc, "{s} (layer {s}) imports {s} (layer {s}), which sits above it; move the shared code down or invert the dependency", .{ f.path, f.layer.?, target.path, target.layer.? });
                }
            }
        }
    }

    /// Whether an import from `from` to `to` goes up the configured layers.
    fn upward(c: *Checker, from: model.File, to: model.File) bool {
        const from_i = c.cfg.layerIndex(from.layer orelse return false) orelse return false;
        const to_i = c.cfg.layerIndex(to.layer orelse return false) orelse return false;
        return to_i < from_i;
    }

    /// Whether both files have a configured layer.
    fn layered(c: *Checker, f: model.File) bool {
        return c.cfg.layerIndex(f.layer orelse return false) != null;
    }

    fn matches(selector: []const u8, f: model.File) bool {
        if (f.layer) |l| {
            if (std.mem.eql(u8, l, selector)) return true;
        }
        return config.pathHasPrefix(f.path, selector);
    }

    // ---- cycles -------------------------------------------------------

    fn fileCycles(c: *Checker) !void {
        const n = c.files.len;
        var edges = try c.arena.alloc(std.ArrayList(u32), n);
        for (edges) |*e| e.* = .empty;
        for (c.files, 0..) |f, i| {
            for (f.imports) |imp| {
                if (imp.allowed != null) continue;
                const t = c.index.get(imp.resolved orelse continue).?;
                if (t != i) try edges[i].append(c.arena, t);
            }
        }
        const sccs = try tarjan(c.arena, edges);
        for (sccs) |scc| {
            var locs: std.ArrayList(model.Location) = .empty;
            for (scc) |v| try locs.append(c.arena, .{ .file = c.files[v].path, .line = 1 });
            try c.add(.import_cycle, .warn, locs.items, "{d} files import each other in a loop; nothing in it can be understood or reused alone", .{scc.len});
        }
    }

    /// Directories that import each other in a loop. A loop whose imports all
    /// point down (or sideways) the configured layers is only there because
    /// one directory holds files of several layers, so it is not reported.
    fn dirCycles(c: *Checker) !void {
        var dirs: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (c.files) |f| try dirs.put(c.arena, f.dir, {});
        const n = dirs.count();
        var edges = try c.arena.alloc(std.ArrayList(u32), n);
        for (edges) |*e| e.* = .empty;
        // An example import of each directory edge, to point at, and whether
        // any import on that edge goes up a layer or leaves the layers.
        const Edge = struct { example: model.Location, suspect: bool };
        var edge_info: std.AutoHashMapUnmanaged([2]u32, Edge) = .empty;
        for (c.files) |f| {
            const from: u32 = @intCast(dirs.getIndex(f.dir).?);
            for (f.imports) |imp| {
                if (imp.allowed != null) continue;
                const target = c.fileOf(imp.resolved orelse continue);
                const to: u32 = @intCast(dirs.getIndex(target.dir).?);
                if (from == to) continue;
                const suspect = c.upward(f, target) or !c.layered(f) or !c.layered(target);
                const gop = try edge_info.getOrPut(c.arena, .{ from, to });
                if (gop.found_existing) {
                    if (suspect and !gop.value_ptr.suspect) gop.value_ptr.* = .{ .example = .{ .file = f.path, .line = imp.line, .symbol = target.path }, .suspect = true };
                    continue;
                }
                gop.value_ptr.* = .{ .example = .{ .file = f.path, .line = imp.line, .symbol = target.path }, .suspect = suspect };
                try edges[from].append(c.arena, to);
            }
        }
        const sccs = try tarjan(c.arena, edges);
        const names = dirs.keys();
        for (sccs) |scc| {
            var locs: std.ArrayList(model.Location) = .empty;
            var list: std.ArrayList(u8) = .empty;
            var suspect = false;
            for (scc) |v| {
                if (list.items.len > 0) try list.appendSlice(c.arena, ", ");
                try list.appendSlice(c.arena, names[v]);
                for (scc) |w| {
                    const e = edge_info.get(.{ v, w }) orelse continue;
                    suspect = suspect or e.suspect;
                    // Point at the edges that close the loop the wrong way.
                    if (e.suspect) try locs.append(c.arena, e.example);
                }
            }
            if (!suspect) continue;
            try c.add(.import_cycle, .warn, locs.items, "directories depend on each other in a loop ({s}); the imports listed go up a layer or leave the layers, pick which side is lower and make them point down", .{list.items});
        }
    }

    // ---- functions ----------------------------------------------------

    fn hotspots(c: *Checker, functions: []const model.Function) !void {
        const cfg = c.cfg;
        for (c.files) |f| {
            if (f.lines > cfg.max_file_lines and f.allowed == null) {
                try c.add(.large_file, sev(f.lines, cfg.max_file_lines), try c.one(.{ .file = f.path, .line = 1 }), "{d} lines; split it by responsibility", .{f.lines});
            }
        }
        for (functions) |f| {
            if (f.allowed != null or f.is_extern) continue;
            const loc = try c.one(.{ .file = f.file, .line = f.line, .end_line = f.end_line, .symbol = f.id });
            if (f.lines > cfg.max_fn_lines) {
                try c.add(.long_function, sev(f.lines, cfg.max_fn_lines), loc, "{s} is {d} lines", .{ f.id, f.lines });
            }
            if (f.complexity > cfg.max_complexity) {
                try c.add(.complex_function, sev(f.complexity, cfg.max_complexity), loc, "{s} has complexity {d}, nesting {d}", .{ f.id, f.complexity, f.depth });
            }
            if (f.params > cfg.max_params) {
                try c.add(.many_params, .info, loc, "{s} takes {d} parameters; group them in an options struct", .{ f.id, f.params });
            }
            try c.thickFrontend(f, loc);
        }
    }

    /// Branchy code that only parses or formats is a front end's job; branchy
    /// code that also drives the core is logic that belongs there. Calls into
    /// the lowest layer (helpers, primitives) don't count as driving the core.
    fn thickFrontend(c: *Checker, f: model.Function, loc: []model.Location) !void {
        const cfg = c.cfg;
        const layer_name = c.fileOf(f.file).layer orelse return;
        const li = cfg.layerIndex(layer_name) orelse return;
        if (!cfg.layers[li].thin or f.complexity <= cfg.thin_max_complexity) return;

        var core: std.ArrayList([]const u8) = .empty;
        for (f.calls) |call| {
            const colon = std.mem.indexOfScalar(u8, call, ':') orelse continue;
            const ti = c.index.get(call[0..colon]) orelse continue;
            const to = c.files[ti].layer orelse continue;
            const to_i = cfg.layerIndex(to) orelse continue;
            if (to_i == li or to_i == cfg.layers.len - 1) continue;
            try core.append(c.arena, call);
        }
        if (core.items.len == 0) return;
        const shown = try std.mem.join(c.arena, ", ", core.items[0..@min(core.items.len, 3)]);
        try c.add(.thick_frontend, .warn, loc, "{s} in front-end layer {s} has complexity {d} and drives the core ({s}{s}); move the decisions into a shared service the other front ends can call", .{
            f.id, layer_name, f.complexity, shown,
            if (core.items.len > 3) ", …" else "",
        });
    }

    fn unusedPub(c: *Checker, functions: []const model.Function, ident_counts: *const std.StringHashMapUnmanaged(u32)) !void {
        // Public functions of module roots are the package's API for others.
        var roots: std.StringHashMapUnmanaged(void) = .empty;
        for (c.cfg.modules) |m| try roots.put(c.arena, m.path, {});
        for (functions) |f| {
            if (!f.is_pub or f.is_export or f.is_extern or f.allowed != null or roots.contains(f.file)) continue;
            if (isStdHook(f.name)) continue;
            if ((ident_counts.get(f.name) orelse 0) > 1) continue;
            try c.add(.unused_pub, .info, try c.one(.{ .file = f.file, .line = f.line, .end_line = f.end_line, .symbol = f.id }), "{s} is public but its name appears nowhere else in the project; if nothing outside calls it, delete it or make it private", .{f.id});
        }
    }

    /// Structs with (nearly) the same field names. Each struct joins the first
    /// group whose first member it resembles, so A~B and B~C don't make A~C.
    fn duplicateShapes(c: *Checker, containers: []const model.Container) !void {
        const Shape = struct { index: u32, names: []const []const u8 };
        var shapes: std.ArrayList(Shape) = .empty;
        for (containers, 0..) |ct, i| {
            if (!std.mem.eql(u8, ct.kind, "struct") or ct.tuple or ct.fields.len < min_shape_fields or ct.allowed != null) continue;
            const names = try c.arena.alloc([]const u8, ct.fields.len);
            for (ct.fields, names) |field, *n| n.* = field.name;
            std.mem.sort([]const u8, names, {}, lessString);
            try shapes.append(c.arena, .{ .index = @intCast(i), .names = names });
        }

        const Group = struct { seed: usize, members: std.ArrayList(usize), exact: bool };
        var groups: std.ArrayList(Group) = .empty;
        // Groups by their seed's field names: a look-alike shares most names,
        // so only groups sharing one are candidates. Names on very many
        // groups (`id`, `name`) say little and are skipped.
        var by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
        var checked: std.ArrayList(usize) = .empty;
        for (shapes.items, 0..) |shape, si| {
            var best: ?u32 = null;
            var best_exact = false;
            for (shape.names) |name| {
                const candidates = by_name.get(name) orelse continue;
                if (candidates.items.len > max_shape_candidates) continue;
                for (candidates.items) |gi| {
                    if (checked.items[gi] == si) continue;
                    checked.items[gi] = si;
                    if (best != null and gi > best.?) continue;
                    const seed = shapes.items[groups.items[gi].seed].names;
                    const common = intersection(seed, shape.names);
                    const all = seed.len + shape.names.len - common;
                    // Jaccard similarity of the field names, at least 0.8.
                    if (common * 5 < all * 4) continue;
                    best = gi;
                    best_exact = common == all;
                }
            }
            if (best) |gi| {
                const g = &groups.items[gi];
                try g.members.append(c.arena, si);
                g.exact = g.exact and best_exact;
                continue;
            }
            var members: std.ArrayList(usize) = .empty;
            try members.append(c.arena, si);
            const gi: u32 = @intCast(groups.items.len);
            try groups.append(c.arena, .{ .seed = si, .members = members, .exact = true });
            try checked.append(c.arena, std.math.maxInt(usize));
            for (shape.names) |name| {
                const gop = try by_name.getOrPut(c.arena, name);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(c.arena, gi);
            }
        }

        for (groups.items) |g| {
            if (g.members.items.len < 2) continue;
            var locs: std.ArrayList(model.Location) = .empty;
            var shared: []const []const u8 = shapes.items[g.seed].names;
            for (g.members.items) |si| {
                const ct = containers[shapes.items[si].index];
                try locs.append(c.arena, .{ .file = ct.file, .line = ct.line, .symbol = ct.id });
                shared = try sharedNames(c.arena, shared, shapes.items[si].names);
            }
            const joined = try std.mem.join(c.arena, ", ", shared[0..@min(shared.len, 8)]);
            try c.add(.duplicate_shape, if (g.exact) .warn else .info, locs.items, "{d} structs have {s} the same fields (shared: {s}{s}); one type, or one embedded in the others, may do", .{
                locs.items.len, if (g.exact) "exactly" else "nearly", joined,
                if (shared.len > 8) ", …" else "",
            });
        }
    }
};

fn isStdHook(name: []const u8) bool {
    for (std_hooks) |h| {
        if (std.mem.eql(u8, h, name)) return true;
    }
    return false;
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}

fn sev(value: u32, limit: u32) model.Severity {
    return if (value > 2 * limit) .warn else .info;
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn intersection(a: []const []const u8, b: []const []const u8) usize {
    var i: usize = 0;
    var j: usize = 0;
    var n: usize = 0;
    while (i < a.len and j < b.len) {
        switch (std.mem.order(u8, a[i], b[j])) {
            .lt => i += 1,
            .gt => j += 1,
            .eq => {
                n += 1;
                i += 1;
                j += 1;
            },
        }
    }
    return n;
}

/// The names in both sorted lists.
fn sharedNames(arena: Allocator, a: []const []const u8, b: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        switch (std.mem.order(u8, a[i], b[j])) {
            .lt => i += 1,
            .gt => j += 1,
            .eq => {
                try out.append(arena, a[i]);
                i += 1;
                j += 1;
            },
        }
    }
    return out.items;
}

/// Strongly connected components with more than one member (Tarjan, iterative).
fn tarjan(arena: Allocator, edges: []const std.ArrayList(u32)) ![]const []const u32 {
    var t: Tarjan = try .init(arena, edges);
    for (0..edges.len) |root| {
        if (t.index[root] == Tarjan.unvisited) try t.visit(@intCast(root));
    }
    return t.out.items;
}

const Tarjan = struct {
    const unvisited = std.math.maxInt(u32);
    const Frame = struct { v: u32, edge: u32 };

    arena: Allocator,
    edges: []const std.ArrayList(u32),
    index: []u32,
    low: []u32,
    on_stack: []bool,
    stack: std.ArrayList(u32) = .empty,
    call: std.ArrayList(Frame) = .empty,
    out: std.ArrayList([]const u32) = .empty,
    counter: u32 = 0,

    fn init(arena: Allocator, edges: []const std.ArrayList(u32)) !Tarjan {
        const t: Tarjan = .{
            .arena = arena,
            .edges = edges,
            .index = try arena.alloc(u32, edges.len),
            .low = try arena.alloc(u32, edges.len),
            .on_stack = try arena.alloc(bool, edges.len),
        };
        @memset(t.index, unvisited);
        @memset(t.on_stack, false);
        return t;
    }

    fn enter(t: *Tarjan, v: u32) !void {
        t.index[v] = t.counter;
        t.low[v] = t.counter;
        t.counter += 1;
        try t.stack.append(t.arena, v);
        t.on_stack[v] = true;
        try t.call.append(t.arena, .{ .v = v, .edge = 0 });
    }

    /// Depth-first from `root` with an explicit stack: every vertex is
    /// entered once and every edge followed once.
    fn visit(t: *Tarjan, root: u32) !void {
        try t.enter(root);
        while (t.call.items.len > 0) {
            const top = &t.call.items[t.call.items.len - 1];
            const v = top.v;
            if (top.edge < t.edges[v].items.len) {
                const w = t.edges[v].items[top.edge];
                top.edge += 1;
                if (t.index[w] == unvisited) {
                    try t.enter(w);
                } else if (t.on_stack[w]) {
                    t.low[v] = @min(t.low[v], t.index[w]);
                }
                continue;
            }
            _ = t.call.pop();
            if (t.call.items.len > 0) {
                const parent = t.call.items[t.call.items.len - 1].v;
                t.low[parent] = @min(t.low[parent], t.low[v]);
            }
            if (t.low[v] == t.index[v]) try t.popComponent(v);
        }
    }

    fn popComponent(t: *Tarjan, v: u32) !void {
        var scc: std.ArrayList(u32) = .empty;
        while (true) {
            const w = t.stack.pop().?;
            t.on_stack[w] = false;
            try scc.append(t.arena, w);
            if (w == v) break;
        }
        if (scc.items.len > 1) {
            std.mem.sort(u32, scc.items, {}, std.sort.asc(u32));
            try t.out.append(t.arena, scc.items);
        }
    }
};

// ---- tests ------------------------------------------------------------------

const scan = @import("scan.zig");

fn runOn(arena: Allocator, cfg: *const Config, files: []const [2][]const u8) ![]const model.Finding {
    var b = scan.Builder.init(arena, cfg);
    for (files) |f| try b.addFile(f[0], try arena.dupeZ(u8, f[1]));
    try b.resolveCalls();
    try run(arena, cfg, b.files.items, b.functions.items, b.containers.items, &b.ident_counts, &b.findings);
    return b.findings.items;
}

fn countKind(findings: []const model.Finding, kind: model.FindingKind) usize {
    var n: usize = 0;
    for (findings) |f| {
        if (f.kind == kind) n += 1;
    }
    return n;
}

test "tarjan finds loops only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var edges = try arena.alloc(std.ArrayList(u32), 4);
    for (edges) |*e| e.* = .empty;
    try edges[0].append(arena, 1);
    try edges[1].append(arena, 2);
    try edges[2].append(arena, 0);
    try edges[2].append(arena, 3);
    const sccs = try tarjan(arena, edges);
    try std.testing.expectEqual(@as(usize, 1), sccs.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, sccs[0]);
}

const three_layers: Config = .{
    .layers = &.{
        .{ .name = "fs", .paths = &.{"src/fs"} },
        .{ .name = "cluster", .paths = &.{"src/cluster"} },
        .{ .name = "net", .paths = &.{"src/net"} },
    },
    .forbid = &.{.{ .from = "fs", .to = "net", .reason = "go through cluster" }},
};

test "upward and forbidden imports are reported; allowed ones are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const findings = try runOn(arena_state.allocator(), &three_layers, &.{
        .{ "src/fs/share.zig", "const net = @import(\"../net/peer.zig\");\nconst cl = @import(\"../cluster/fetch.zig\");\n" },
        .{ "src/cluster/fetch.zig", "const share = @import(\"../fs/share.zig\");\n// @atlas allow: test only\nconst share2 = @import(\"../fs/other.zig\");\n" },
        .{ "src/fs/other.zig", "" },
        .{ "src/net/peer.zig", "" },
    });
    try std.testing.expectEqual(@as(usize, 1), countKind(findings, .forbidden_import));
    try std.testing.expectEqual(@as(usize, 1), countKind(findings, .layer_violation));
    try std.testing.expectEqual(@as(usize, 2), countKind(findings, .import_cycle)); // file loop and directory loop
}

test "a directory loop whose imports all point down the layers is not reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{ .layers = &.{
        .{ .name = "top", .paths = &.{ "src/main.zig", "src/app" } },
        .{ .name = "base", .paths = &.{"src/util.zig"} },
    } };
    // src/ holds a top file and a base file: src -> src/app -> src is a
    // directory loop, but every import points down.
    const findings = try runOn(arena_state.allocator(), &cfg, &.{
        .{ "src/main.zig", "const app = @import(\"app/run.zig\");\n" },
        .{ "src/app/run.zig", "const util = @import(\"../util.zig\");\n" },
        .{ "src/util.zig", "" },
    });
    try std.testing.expectEqual(@as(usize, 0), countKind(findings, .import_cycle));
}

const frontend: Config = .{
    .layers = &.{
        .{ .name = "cli", .paths = &.{"src/cli"}, .thin = true },
        .{ .name = "core", .paths = &.{"src/core"} },
        .{ .name = "base", .paths = &.{"src/util.zig"} },
    },
    .thin_max_complexity = 3,
};

const branchy = "if (a == 1) n += 1; if (a == 2) n += 2; if (a == 3) n += 3; if (a == 4) n += 4;";

test "thick_frontend: branchy code driving the core is reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const findings = try runOn(arena_state.allocator(), &frontend, &.{
        .{ "src/cli/main.zig", "const core = @import(\"../core/svc.zig\");\nfn handle(svc: *core.Service, a: u32) void {\n    var n: u32 = 0;\n    " ++ branchy ++ "\n    svc.charge(n);\n}\n" },
        .{ "src/core/svc.zig", "pub const Service = struct {\n    pub fn charge(self: *Service, n: u32) void { _ = self; _ = n; }\n};\n" },
    });
    try std.testing.expectEqual(@as(usize, 1), countKind(findings, .thick_frontend));
}

test "thick_frontend: a parser calling only a base helper is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const findings = try runOn(arena_state.allocator(), &frontend, &.{
        .{ "src/cli/main.zig", "const util = @import(\"../util.zig\");\nfn parseArgs(a: u32) u32 {\n    var n: u32 = 0;\n    " ++ branchy ++ "\n    return util.trim(n);\n}\n" },
        .{ "src/util.zig", "pub fn trim(n: u32) u32 { return n; }\n" },
    });
    try std.testing.expectEqual(@as(usize, 0), countKind(findings, .thick_frontend));
}

test "unused_pub: an unused function is reported; std hooks, uses elsewhere and extern are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg: Config = .{};
    var b = scan.Builder.init(arena, &cfg);
    try b.addFile("src/a.zig",
        \\pub fn neverCalled() void {}
        \\pub fn usedInTests() void {}
        \\pub const T = struct {
        \\    pub fn jsonStringify(self: T, w: anytype) !void { _ = self; _ = w; }
        \\};
        \\pub extern fn ext() void;
    );
    try b.countUsage("test { a.usedInTests(); }");
    try run(arena, &cfg, b.files.items, b.functions.items, b.containers.items, &b.ident_counts, &b.findings);
    try std.testing.expectEqual(@as(usize, 1), countKind(b.findings.items, .unused_pub));
    try std.testing.expectEqualStrings("src/a.zig:neverCalled", b.findings.items[0].locations[0].symbol);
}

test "duplicate_shape: same field names are reported; tuples and chains are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const findings = try runOn(arena_state.allocator(), &.{}, &.{
        .{
            "a.zig",
            \\const Info = struct { id: u32, name: []const u8, size: u64 };
            \\const Copy = struct { size: u64, id: u32, name: []const u8 };
            \\const T1 = struct { u32, u32, u8 };
            \\const T2 = struct { u32, u8, u32 };
            \\const A = struct { a: u8, b: u8, c: u8, d: u8, e: u8, f: u8, g: u8, h: u8 };
            \\const B = struct { a: u8, b: u8, c: u8, d: u8, e: u8, f: u8, g: u8, h: u8, i: u8, j: u8 };
            \\const C = struct { c: u8, d: u8, e: u8, f: u8, g: u8, h: u8, i: u8, j: u8 };
        },
    });
    var exact: usize = 0;
    var near: usize = 0;
    for (findings) |f| {
        if (f.kind != .duplicate_shape) continue;
        if (f.severity == .warn) exact += 1 else near += 1;
        // A~B and B~C, but A and C differ: no group has all three.
        try std.testing.expect(f.locations.len == 2);
    }
    try std.testing.expectEqual(@as(usize, 1), exact);
    try std.testing.expectEqual(@as(usize, 1), near);
}

test "hotspots: over the limits is reported, an allowed function is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{ .max_params = 2, .max_complexity = 2, .max_fn_lines = 2, .max_file_lines = 5 };
    const findings = try runOn(arena_state.allocator(), &cfg, &.{.{
        "a.zig",
        \\fn many(a: u8, b: u8, c: u8) u8 {
        \\    if (a > b) return c;
        \\    if (b > c) return a;
        \\    return b;
        \\}
        \\// @atlas allow: generated
        \\fn quiet(a: u8, b: u8, c: u8) u8 { if (a > b) return c; if (b > c) return a; return b; }
    }});
    try std.testing.expectEqual(@as(usize, 1), countKind(findings, .many_params));
    try std.testing.expectEqual(@as(usize, 1), countKind(findings, .complex_function));
    try std.testing.expectEqual(@as(usize, 1), countKind(findings, .long_function));
    try std.testing.expectEqual(@as(usize, 1), countKind(findings, .large_file));
}

test "parse errors are reported at their line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const findings = try runOn(arena_state.allocator(), &.{}, &.{.{ "bad.zig", "const a = 1;\n\npub fn broken( void {\n}\n" }});
    try std.testing.expectEqual(@as(usize, 1), countKind(findings, .parse_error));
    try std.testing.expectEqual(@as(u32, 3), findings[0].locations[0].line);
}

test "findings sort most severe first" {
    var locs = [_]model.Location{.{ .file = "a", .line = 1 }};
    var findings = [_]model.Finding{
        .{ .kind = .unused_pub, .severity = .info, .message = "", .locations = &locs },
        .{ .kind = .layer_violation, .severity = .@"error", .message = "", .locations = &locs },
        .{ .kind = .duplicate_function, .severity = .warn, .message = "", .locations = &locs },
    };
    sortFindings(&findings);
    try std.testing.expectEqual(model.Severity.@"error", findings[0].severity);
    try std.testing.expectEqual(model.Severity.info, findings[2].severity);
}
