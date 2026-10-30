//! zigatlas: maps a Zig code base (files, imports, types, functions, calls)
//! and points at duplication and architecture problems, in forms an LLM agent
//! or a reviewer can read quickly. Run it through `zig build atlas`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const config = @import("config.zig");
const scan = @import("scan.zig");
const clones = @import("clones.zig");
const checks = @import("checks.zig");
const render = @import("render.zig");

/// Directories never scanned: build output, caches, vendored packages.
const skip_dirs = [_][]const u8{ "zig-out", "zig-cache", "zig-pkg", "node_modules", "build" };

pub fn main(init: std.process.Init) !void {
    // One short run: everything lives until exit.
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try Io.File.stdout().writeStreamingAll(io, config.usage);
            return;
        }
    }
    const cfg = config.parse(arena, args[1..]) catch std.process.exit(2);

    const paths = try collectFiles(arena, io, &cfg);
    var b = scan.Builder.init(arena, &cfg);
    for (paths) |path| {
        const source = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(64 << 20), .of(u8), 0) catch |err| {
            std.debug.print("zigatlas: cannot read {s}: {t}\n", .{ path, err });
            continue;
        };
        try b.addFile(path, source);
    }

    try b.resolveCalls();
    try checks.run(arena, &cfg, b.files.items, b.functions.items, b.containers.items, &b.ident_counts, &b.findings);
    try clones.detect(arena, &cfg, b.bodies.items, b.functions.items, &b.findings);
    std.mem.sort(model.Finding, b.findings.items, {}, findingOrder);

    const atlas: model.Atlas = .{
        .files = b.files.items,
        .functions = b.functions.items,
        .containers = b.containers.items,
        .findings = b.findings.items,
        .stats = stats(b.files.items, b.functions.items, b.containers.items),
    };

    var out_dir = try Io.Dir.cwd().createDirPathOpen(io, cfg.out_dir, .{});
    defer out_dir.close(io);
    const outputs = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "ATLAS.md", .data = try render.overview(arena, &cfg, atlas) },
        .{ .name = "api.md", .data = try render.api(arena, &cfg, atlas) },
        .{ .name = "atlas.json", .data = try render.json(arena, atlas) },
        .{ .name = "deps.mmd", .data = try render.mermaid(arena, &cfg, atlas) },
        .{ .name = "files.dot", .data = try render.dot(arena, atlas) },
    };
    for (outputs) |o| try out_dir.writeFile(io, .{ .sub_path = o.name, .data = o.data });

    var counts = [_]u32{ 0, 0, 0 };
    for (atlas.findings) |f| counts[f.severity.rank()] += 1;
    const summary = try std.fmt.allocPrint(arena, "zigatlas: {d} files, {d} functions; {d} errors, {d} warnings, {d} notes → {s}/ATLAS.md\n", .{
        atlas.stats.files, atlas.stats.functions, counts[2], counts[1], counts[0], cfg.out_dir,
    });
    try Io.File.stdout().writeStreamingAll(io, summary);

    if (cfg.check) |level| {
        var failing: u32 = 0;
        for (atlas.findings) |f| {
            if (f.severity.rank() >= level.rank()) failing += 1;
        }
        if (failing > 0) {
            std.debug.print("zigatlas: {d} findings at {t} or above\n", .{ failing, level });
            std.process.exit(1);
        }
    }
}

/// Every .zig file under the roots, sorted, with '/' separators.
fn collectFiles(arena: Allocator, io: Io, cfg: *const config.Config) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (cfg.roots) |root| {
        var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => {
                try out.append(arena, root);
                continue;
            },
            else => {
                std.debug.print("zigatlas: cannot open root {s}: {t}\n", .{ root, err });
                continue;
            },
        };
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                if (entry.basename[0] == '.' or isSkipped(entry.basename)) walker.leave(io);
                continue;
            }
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.path });
            std.mem.replaceScalar(u8, path, '\\', '/');
            if (isExcluded(cfg, path)) continue;
            try out.append(arena, path);
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return out.items;
}

fn isSkipped(name: []const u8) bool {
    for (skip_dirs) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

fn isExcluded(cfg: *const config.Config, path: []const u8) bool {
    for (cfg.exclude) |prefix| {
        if (config.pathHasPrefix(path, prefix)) return true;
    }
    return false;
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

fn stats(files: []const model.File, functions: []const model.Function, containers: []const model.Container) model.Stats {
    var s: model.Stats = .{
        .files = @intCast(files.len),
        .functions = @intCast(functions.len),
        .containers = @intCast(containers.len),
    };
    for (files) |f| {
        s.lines += f.lines;
        s.tests += f.tests;
        for (f.imports) |imp| {
            if (imp.resolved != null) s.import_edges += 1;
        }
    }
    for (functions) |f| {
        if (f.is_pub) s.pub_functions += 1;
    }
    return s;
}

test {
    _ = config;
    _ = scan;
    _ = clones;
    _ = checks;
    _ = render;
}
