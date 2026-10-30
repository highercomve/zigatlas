//! Architecture and design checks over the scanned atlas: layers, forbidden
//! imports, cycles, fat front ends, hotspots, unused API and look-alike types.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const config = @import("config.zig");
const Config = config.Config;

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

    fn parseErrors(c: *Checker) !void {
        for (c.files) |f| {
            if (f.parse_errors == 0) continue;
            try c.add(.parse_error, .@"error", try c.one(.{ .file = f.path, .line = 1 }), "{d} parse errors; the file was only partly analysed", .{f.parse_errors});
        }
    }

    // ---- layers -------------------------------------------------------

    fn layers(c: *Checker) !void {
        for (c.files) |f| {
            for (f.imports) |imp| {
                const target_path = imp.resolved orelse continue;
                if (imp.allowed != null) continue;
                const target = c.files[c.index.get(target_path).?];
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

                const from_layer = f.layer orelse continue;
                const to_layer = target.layer orelse continue;
                const from_i = c.cfg.layerIndex(from_layer) orelse continue;
                const to_i = c.cfg.layerIndex(to_layer) orelse continue;
                if (to_i < from_i) {
                    try c.add(.layer_violation, .@"error", loc, "{s} (layer {s}) imports {s} (layer {s}), which sits above it; move the shared code down or invert the dependency", .{ f.path, from_layer, target.path, to_layer });
                }
            }
        }
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

    fn dirCycles(c: *Checker) !void {
        var dirs: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (c.files) |f| try dirs.put(c.arena, f.dir, {});
        const n = dirs.count();
        var edges = try c.arena.alloc(std.ArrayList(u32), n);
        for (edges) |*e| e.* = .empty;
        // An example import of each directory edge, to point at.
        var example: std.AutoHashMapUnmanaged([2]u32, model.Location) = .empty;
        for (c.files) |f| {
            const from: u32 = @intCast(dirs.getIndex(f.dir).?);
            for (f.imports) |imp| {
                if (imp.allowed != null) continue;
                const target = c.files[c.index.get(imp.resolved orelse continue).?];
                const to: u32 = @intCast(dirs.getIndex(target.dir).?);
                if (from == to) continue;
                const gop = try example.getOrPut(c.arena, .{ from, to });
                if (gop.found_existing) continue;
                gop.value_ptr.* = .{ .file = f.path, .line = imp.line, .symbol = target.path };
                try edges[from].append(c.arena, to);
            }
        }
        const sccs = try tarjan(c.arena, edges);
        const names = dirs.keys();
        for (sccs) |scc| {
            var locs: std.ArrayList(model.Location) = .empty;
            var list: std.ArrayList(u8) = .empty;
            for (scc) |v| {
                if (list.items.len > 0) try list.appendSlice(c.arena, ", ");
                try list.appendSlice(c.arena, names[v]);
                for (scc) |w| {
                    if (example.get(.{ v, w })) |loc| try locs.append(c.arena, loc);
                }
            }
            try c.add(.import_cycle, .warn, locs.items, "directories depend on each other in a loop ({s}); pick which one is lower and make the edges point down", .{list.items});
        }
    }

    // ---- functions ----------------------------------------------------

    fn hotspots(c: *Checker, functions: []const model.Function) !void {
        const cfg = c.cfg;
        for (c.files) |f| {
            if (f.lines > cfg.max_file_lines) {
                try c.add(.large_file, sev(f.lines, cfg.max_file_lines), try c.one(.{ .file = f.path, .line = 1 }), "{d} lines; split it by responsibility", .{f.lines});
            }
        }
        for (functions) |f| {
            if (f.allowed != null) continue;
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
            const file = c.files[c.index.get(f.file).?];
            const layer_name = file.layer orelse continue;
            const li = cfg.layerIndex(layer_name) orelse continue;
            // Branchy code that only parses or formats is a front end's job;
            // branchy code that also drives the core is logic that belongs there.
            if (!cfg.layers[li].thin or f.complexity <= cfg.thin_max_complexity) continue;
            const core = c.coreCalls(f, layer_name);
            if (core == 0) continue;
            try c.add(.thick_frontend, .warn, loc, "{s} in front-end layer {s} has complexity {d} and makes {d} calls into the core; move the decisions into a shared service the other front ends can call", .{ f.id, layer_name, f.complexity, core });
        }
    }

    /// Calls from `f` into files outside its own layer.
    fn coreCalls(c: *Checker, f: model.Function, layer: []const u8) u32 {
        var n: u32 = 0;
        for (f.calls) |call| {
            const colon = std.mem.indexOfScalar(u8, call, ':') orelse continue;
            const ti = c.index.get(call[0..colon]) orelse continue;
            const to = c.files[ti].layer orelse continue;
            if (!std.mem.eql(u8, to, layer)) n += 1;
        }
        return n;
    }

    fn unusedPub(c: *Checker, functions: []const model.Function, ident_counts: *const std.StringHashMapUnmanaged(u32)) !void {
        // Public functions of module roots are the package's API for others.
        var roots: std.StringHashMapUnmanaged(void) = .empty;
        for (c.cfg.modules) |m| try roots.put(c.arena, m.path, {});
        for (functions) |f| {
            if (!f.is_pub or f.is_export or f.allowed != null or roots.contains(f.file)) continue;
            if (std.mem.eql(u8, f.name, "main") or std.mem.eql(u8, f.name, "format")) continue;
            if ((ident_counts.get(f.name) orelse 0) > 1) continue;
            try c.add(.unused_pub, .info, try c.one(.{ .file = f.file, .line = f.line, .end_line = f.end_line, .symbol = f.id }), "{s} is public but its name appears nowhere else; delete it or make it private", .{f.id});
        }
    }

    fn duplicateShapes(c: *Checker, containers: []const model.Container) !void {
        const Shape = struct { index: u32, names: []const []const u8 };
        var shapes: std.ArrayList(Shape) = .empty;
        for (containers, 0..) |ct, i| {
            if (!std.mem.eql(u8, ct.kind, "struct") or ct.fields.len < 3 or ct.allowed != null) continue;
            const names = try c.arena.alloc([]const u8, ct.fields.len);
            for (ct.fields, names) |field, *n| n.* = field.name;
            std.mem.sort([]const u8, names, {}, lessString);
            try shapes.append(c.arena, .{ .index = @intCast(i), .names = names });
        }
        // Link look-alikes (Jaccard similarity of field names >= 0.8) and
        // report each linked group once.
        const parent = try c.arena.alloc(u32, shapes.items.len);
        for (parent, 0..) |*p, i| p.* = @intCast(i);
        const exact = try c.arena.alloc(bool, shapes.items.len);
        @memset(exact, true);
        var linked = false;
        for (shapes.items, 0..) |a, i| {
            for (shapes.items[i + 1 ..], i + 1..) |b, j| {
                const common = intersection(a.names, b.names);
                const all = a.names.len + b.names.len - common;
                if (common * 5 < all * 4) continue;
                const ri = find(parent, @intCast(i));
                const rj = find(parent, @intCast(j));
                if (ri != rj) {
                    parent[rj] = ri;
                    exact[ri] = exact[ri] and exact[rj];
                }
                if (common != all) exact[ri] = false;
                linked = true;
            }
        }
        if (!linked) return;

        for (0..shapes.items.len) |root| {
            if (find(parent, @intCast(root)) != root) continue;
            var locs: std.ArrayList(model.Location) = .empty;
            for (shapes.items, 0..) |s, i| {
                if (find(parent, @intCast(i)) != root) continue;
                const ct = containers[s.index];
                try locs.append(c.arena, .{ .file = ct.file, .line = ct.line, .symbol = ct.id });
            }
            if (locs.items.len < 2) continue;
            const names = shapes.items[root].names;
            const joined = try std.mem.join(c.arena, ", ", names[0..@min(names.len, 8)]);
            try c.add(.duplicate_shape, if (exact[root]) .warn else .info, locs.items, "{d} structs have {s} the same fields ({s}{s}); one type, or one embedded in the others, may do", .{
                locs.items.len, if (exact[root]) "exactly" else "nearly", joined,
                if (names.len > 8) ", …" else "",
            });
        }
    }
};

fn find(parent: []u32, x: u32) u32 {
    var r = x;
    while (parent[r] != r) r = parent[r];
    var y = x;
    while (parent[y] != r) {
        const next = parent[y];
        parent[y] = r;
        y = next;
    }
    return r;
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

/// Strongly connected components with more than one member (Tarjan, iterative).
fn tarjan(arena: Allocator, edges: []const std.ArrayList(u32)) ![]const []const u32 {
    const n = edges.len;
    const unvisited = std.math.maxInt(u32);
    const idx = try arena.alloc(u32, n);
    const low = try arena.alloc(u32, n);
    const on_stack = try arena.alloc(bool, n);
    @memset(idx, unvisited);
    @memset(on_stack, false);
    var stack: std.ArrayList(u32) = .empty;
    var out: std.ArrayList([]const u32) = .empty;
    const Frame = struct { v: u32, edge: u32 };
    var call: std.ArrayList(Frame) = .empty;
    var counter: u32 = 0;

    for (0..n) |root| {
        if (idx[root] != unvisited) continue;
        try call.append(arena, .{ .v = @intCast(root), .edge = 0 });
        idx[root] = counter;
        low[root] = counter;
        counter += 1;
        try stack.append(arena, @intCast(root));
        on_stack[root] = true;

        while (call.items.len > 0) {
            const top = &call.items[call.items.len - 1];
            const v = top.v;
            if (top.edge < edges[v].items.len) {
                const w = edges[v].items[top.edge];
                top.edge += 1;
                if (idx[w] == unvisited) {
                    idx[w] = counter;
                    low[w] = counter;
                    counter += 1;
                    try stack.append(arena, w);
                    on_stack[w] = true;
                    try call.append(arena, .{ .v = w, .edge = 0 });
                } else if (on_stack[w]) {
                    low[v] = @min(low[v], idx[w]);
                }
                continue;
            }
            _ = call.pop();
            if (call.items.len > 0) {
                const parent = call.items[call.items.len - 1].v;
                low[parent] = @min(low[parent], low[v]);
            }
            if (low[v] != idx[v]) continue;
            var scc: std.ArrayList(u32) = .empty;
            while (true) {
                const w = stack.pop().?;
                on_stack[w] = false;
                try scc.append(arena, w);
                if (w == v) break;
            }
            if (scc.items.len > 1) {
                std.mem.sort(u32, scc.items, {}, std.sort.asc(u32));
                try out.append(arena, scc.items);
            }
        }
    }
    return out.items;
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

test "upward and forbidden imports are reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg: Config = .{
        .layers = &.{
            .{ .name = "fs", .paths = &.{"src/fs"} },
            .{ .name = "cluster", .paths = &.{"src/cluster"} },
            .{ .name = "net", .paths = &.{"src/net"} },
        },
        .forbid = &.{.{ .from = "fs", .to = "net", .reason = "go through cluster" }},
    };
    const scan = @import("scan.zig");
    var b = scan.Builder.init(arena, &cfg);
    try b.addFile("src/fs/share.zig", "const net = @import(\"../net/peer.zig\");\nconst cl = @import(\"../cluster/fetch.zig\");\n");
    try b.addFile("src/cluster/fetch.zig", "const share = @import(\"../fs/share.zig\");\n");
    try b.addFile("src/net/peer.zig", "");
    try run(arena, &cfg, b.files.items, b.functions.items, b.containers.items, &b.ident_counts, &b.findings);

    var forbidden: usize = 0;
    var upward: usize = 0;
    var cycles: usize = 0;
    for (b.findings.items) |f| switch (f.kind) {
        .forbidden_import => forbidden += 1,
        .layer_violation => upward += 1,
        .import_cycle => cycles += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), forbidden);
    try std.testing.expectEqual(@as(usize, 1), upward);
    try std.testing.expectEqual(@as(usize, 2), cycles); // file loop and directory loop
}
